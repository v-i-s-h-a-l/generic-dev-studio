#!/usr/bin/env bash
# lib-github-transport.sh — shared gh-backed Git transport helper.
#
# Studio-owned GitHub Git network transport (fetch, push, ls-remote) routes
# through a normalized github_home credential root with `gh auth git-credential`
# as the credential helper, so chain runs do not depend on stale ambient
# credential helpers or host-specific SSH setup. Implements the contract
# documented in _shared/contracts/studio-git-transport.md (#876).
#
# Sourceable:
#   . "$SCRIPT_DIR/lib-github-transport.sh"
#
# Public functions:
#   studio_git_transport_fetch <git-fetch-args...>
#   studio_git_transport_push <git-push-args...>
#   studio_git_transport_ls_remote <git-ls-remote-args...>
#   studio_git_transport_preflight [remote-url]
#   studio_git_transport_run <op> [--ssh|--anonymous|--default] -- <git-args...>
#   studio_git_transport_last_error
#   studio_git_transport_last_diagnostic
#
# Modes:
#   default    HTTPS GitHub remote; HOME normalized via with_login_home_for_github;
#              credential.helper overridden to `!gh auth git-credential`;
#              `gh auth status` proved up-front under that HOME.
#   anonymous  HTTPS, no credential helper (recipe fetches against third-party
#              repos). HOME is NOT flipped; credential.helper is explicitly
#              emptied so a stale system helper cannot intercept.
#   ssh        Skip credential normalization entirely; transport runs under
#              ambient HOME / SSH config. Used for deliberate SSH origins or
#              isolated-auth testing. Emits a loud `ssh_mode_explicit` audit
#              line on every call.
#
# User-controlled overrides (assistants must not set these silently):
#   STUDIO_GIT_TRANSPORT_FORCE_SSH=1   force `ssh` mode for every call.
#   STUDIO_GIT_TRANSPORT_ANONYMOUS=1   force `anonymous` mode (unless SSH is
#                                      also forced, in which case SSH wins).
#   STUDIO_BYPASS_PARENT_HOME_FLIP=1   inherited from lib-studio-context;
#                                      forces github_home to caller HOME.
#
# Diagnostic IDs (emitted to stderr and recorded in
# STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC; STUDIO_GIT_TRANSPORT_LAST_ERROR
# carries the human-readable detail):
#   gh_missing               `command -v gh` failed on PATH.
#   gh_auth_missing          `gh auth status` failed under normalized
#                            github_home.
#   credential_helper_stale  Configured `credential.helper` (global, system,
#                            local, or per-URL) points at a missing binary or
#                            non-executable path. Non-fatal: the helper still
#                            overrides via `-c credential.helper=...`, but the
#                            stale entry is surfaced for operator review.
#   network_partition        Git transport ran but failed with no auth signal.
#   ssh_mode_explicit        Explicit SSH/isolated-auth mode active; ambient
#                            credential and SSH config were used unchanged.
#
# Return codes:
#   0                Success.
#   2                Bad usage (missing op or git args).
#   127              gh CLI not on PATH.
#   <git rc>         Underlying `git` exit code on transport failure.
#
# No `set -e` here — sourced into scripts that choose their own shell policy.

STUDIO_GIT_TRANSPORT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$STUDIO_GIT_TRANSPORT_LIB_DIR/lib-paths.sh"

: "${STUDIO_GIT_TRANSPORT_LAST_ERROR:=}"
: "${STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC:=}"

_sgt_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_sgt_emit_diag() {
  STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC="$1"
  STUDIO_GIT_TRANSPORT_LAST_ERROR="$2"
  printf 'lib-github-transport: %s: %s\n' "$1" "$2" >&2
}

# True (return 0) when a configured credential.helper value points at a
# missing/unreachable backend. Shell-command helpers (prefix `!`) and built-in
# `cache`/`store` style names that resolve via PATH are considered fresh.
_sgt_helper_value_is_stale() {
  local value="$1" first git_exec_path
  [ -n "$value" ] || return 1
  case "$value" in
    "!"*) return 1 ;;
  esac
  first="${value%% *}"
  case "$first" in
    /*)
      [ -x "$first" ] && return 1
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      command -v "git-credential-$first" >/dev/null 2>&1 && return 1
      git_exec_path=$(git --exec-path 2>/dev/null || true)
      if [ -n "$git_exec_path" ] && [ -x "$git_exec_path/git-credential-$first" ]; then
        return 1
      fi
      return 0
      ;;
  esac
}

# Inspect every credential.helper configured for the current shell (global,
# system, local, and GitHub-scoped URL match). Emit the credential_helper_stale
# diagnostic if any entry is unreachable; return 0 if stale found, 1 if clean.
_sgt_check_stale_helpers() {
  local helpers helper stale=""
  helpers=$( {
    git config --get-all credential.helper 2>/dev/null || true
    git config --get-all credential.https://github.com.helper 2>/dev/null || true
    git config --get-all credential.https://gist.github.com.helper 2>/dev/null || true
  })
  while IFS= read -r helper; do
    [ -n "$helper" ] || continue
    if _sgt_helper_value_is_stale "$helper"; then
      stale="${stale:+$stale; }$helper"
    fi
  done <<EOF
$helpers
EOF
  if [ -n "$stale" ]; then
    _sgt_emit_diag "credential_helper_stale" \
      "configured credential.helper unreachable: $stale; overriding via the gh credential helper"
    return 0
  fi
  return 1
}

_sgt_verify_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    _sgt_emit_diag "gh_missing" "gh CLI not on PATH; cannot route Git transport through gh auth git-credential"
    return 127
  fi
  return 0
}

_sgt_verify_gh_auth() {
  if ! with_login_home_for_github gh auth status >/dev/null 2>&1; then
    _sgt_emit_diag "gh_auth_missing" \
      "gh auth status failed under normalized github_home; transport would fall back to ambient credentials"
    return 1
  fi
  return 0
}

studio_git_transport_run() {
  local op="${1:-}"
  if [ -z "$op" ]; then
    _sgt_emit_diag "usage" "studio_git_transport_run requires an <op> label"
    return 2
  fi
  shift
  local mode="default"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ssh) mode="ssh"; shift ;;
      --anonymous) mode="anonymous"; shift ;;
      --default) mode="default"; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if _sgt_truthy "${STUDIO_GIT_TRANSPORT_FORCE_SSH:-0}"; then
    mode="ssh"
  elif [ "$mode" != "ssh" ] && _sgt_truthy "${STUDIO_GIT_TRANSPORT_ANONYMOUS:-0}"; then
    mode="anonymous"
  fi

  if [ "$#" -eq 0 ]; then
    _sgt_emit_diag "usage" "studio_git_transport_run requires git arguments after --"
    return 2
  fi

  STUDIO_GIT_TRANSPORT_LAST_ERROR=""
  STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC=""

  local rc=0
  case "$mode" in
    ssh)
      _sgt_emit_diag "ssh_mode_explicit" \
        "explicit SSH/isolated-auth mode active for op=$op; ambient credential and SSH config used unchanged"
      GIT_TERMINAL_PROMPT=0 git "$@"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        _sgt_emit_diag "ssh_mode_explicit" "git transport failed under explicit SSH mode (op=$op rc=$rc)"
      fi
      return "$rc"
      ;;
    anonymous)
      _sgt_check_stale_helpers || true
      GIT_TERMINAL_PROMPT=0 git \
        -c "credential.helper=" \
        -c "credential.https://github.com.helper=" \
        -c "credential.https://gist.github.com.helper=" \
        "$@"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        _sgt_emit_diag "network_partition" "anonymous git transport failed (op=$op rc=$rc)"
      fi
      return "$rc"
      ;;
    default)
      _sgt_verify_gh || return $?
      _sgt_verify_gh_auth || return 1
      with_login_home_for_github _sgt_check_stale_helpers || true
      with_login_home_for_github env GIT_TERMINAL_PROMPT=0 git \
        -c "credential.helper=" \
        -c "credential.https://github.com.helper=" \
        -c "credential.https://github.com.helper=!gh auth git-credential" \
        -c "credential.https://gist.github.com.helper=" \
        -c "credential.https://gist.github.com.helper=!gh auth git-credential" \
        "$@"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        _sgt_emit_diag "network_partition" "git transport failed without auth signal (op=$op rc=$rc)"
      fi
      return "$rc"
      ;;
    *)
      _sgt_emit_diag "usage" "unsupported mode: $mode"
      return 2
      ;;
  esac
}

studio_git_transport_fetch() {
  studio_git_transport_run fetch -- fetch "$@"
}

studio_git_transport_push() {
  studio_git_transport_run push -- push "$@"
}

studio_git_transport_ls_remote() {
  studio_git_transport_run ls-remote -- ls-remote "$@"
}

# Proof-point preflight: probes a remote's HEAD via ls-remote --exit-code.
# Used by host-preflight.sh once it migrates onto this helper.
studio_git_transport_preflight() {
  local remote="${1:-origin}"
  shift || true
  studio_git_transport_run preflight -- ls-remote --exit-code "$remote" HEAD "$@"
}

studio_git_transport_last_error() {
  printf '%s\n' "$STUDIO_GIT_TRANSPORT_LAST_ERROR"
}

studio_git_transport_last_diagnostic() {
  printf '%s\n' "$STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC"
}
