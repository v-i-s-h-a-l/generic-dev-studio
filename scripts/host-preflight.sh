#!/usr/bin/env bash
# host-preflight.sh — load-bearing host assumptions before task work starts.
#
# Usage:
#   scripts/host-preflight.sh <host> <repo-root>
#
# Verifies the GitHub auth surface used by studio worker hosts. This is a
# pre-edit gate: if gh or git cannot reach the project remote, host-backed
# sessions must fail here instead of discovering the problem after work has
# started.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"

HOST="${1:?usage: host-preflight.sh <host> <repo-root>}"
REPO="${2:?repo-root required}"

case "${STUDIO_BYPASS_GITHUB_AUTH_PREFLIGHT:-0}" in
  1|true|TRUE|yes|YES)
    printf 'host-preflight: bypassed GitHub auth preflight for host=%s via STUDIO_BYPASS_GITHUB_AUTH_PREFLIGHT\n' "$HOST" >&2
    exit 0
    ;;
esac

[ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'host-preflight: repo root is not a git checkout: %s\n' "$REPO" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || {
  printf 'host-preflight: gh is required for host=%s GitHub auth parity\n' "$HOST" >&2
  exit 2
}

_lp_load_project_env 2>/dev/null || true
: "${STUDIO_CONTEXT_HOST_PROFILE:=$HOST}"

if ! studio_context_resolve github-operation; then
  printf 'host-preflight: GitHub context unavailable for host=%s before auth probes.\n' "$HOST" >&2
  exit 1
fi

github_home=$(studio_context_get_cached github_home)
if [ -n "$github_home" ] && [ "$github_home" != "${HOME:-}" ]; then
  printf 'host-preflight: normalized GitHub HOME for host=%s via context github_home before auth probes\n' "$HOST" >&2
fi

if ! HOME="$github_home" gh auth status >/dev/null 2>&1; then
  printf 'host-preflight: GitHub auth unavailable for host=%s; gh auth status failed before task work.\n' "$HOST" >&2
  printf 'host-preflight: repair the context github_home used by studio-gh, then rerun: scripts/studio-gh.sh auth login\n' >&2
  exit 1
fi

remote_url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
[ -n "$remote_url" ] || {
  printf 'host-preflight: git remote origin is missing in %s\n' "$REPO" >&2
  exit 1
}

# `git ls-remote` is the credential-helper proof. It exercises the exact
# git credential path that later fetch/commit-resolution steps rely on,
# including gh's credential helper for HTTPS remotes and ssh-agent/keychain
# access for SSH remotes.
ls_remote_err=$(mktemp 2>/dev/null || printf '/tmp/host-preflight-ls-remote-%s.err' "$$")
if ! HOME="$github_home" git -C "$REPO" ls-remote --exit-code "$remote_url" HEAD > /dev/null 2>"$ls_remote_err"; then
  detail=$(tail -n 5 "$ls_remote_err" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g')
  rm -f "$ls_remote_err" 2>/dev/null || true
  printf 'host-preflight: git credential access failed for host=%s remote=%s; git ls-remote ... HEAD failed before task work.\n' "$HOST" "$remote_url" >&2
  [ -n "$detail" ] && printf 'host-preflight: git detail: %s\n' "$detail" >&2
  printf 'host-preflight: ensure the host launches with the same HOME/keychain/ssh-agent or gh credential helper surface as Claude sessions.\n' >&2
  exit 1
fi
rm -f "$ls_remote_err" 2>/dev/null || true

helper_count=$(git -C "$REPO" config --get-all credential.helper 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
case "$remote_url" in
  http://*|https://*)
    if [ "${helper_count:-0}" = "0" ]; then
      printf 'host-preflight: warning: HTTPS remote has no explicit credential.helper; ls-remote passed, but setup may depend on ambient git config.\n' >&2
    fi
    ;;
esac

printf 'host-preflight: PASS host=%s remote=%s\n' "$HOST" "$remote_url" >&2
exit 0
