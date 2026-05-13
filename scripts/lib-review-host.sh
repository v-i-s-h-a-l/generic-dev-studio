#!/usr/bin/env bash
# lib-review-host.sh - shared review-host resolver and reviewer launch helper.
#
# Sourced by the PR review, phase review, pre-commit review, and reviewer
# eligibility wrappers. It centralizes the family/default selection rules,
# reviewer auth-home resolution, and the env-scrubbed noninteractive launch
# shape so the wrappers do not drift apart.

# No set -e here; this file is sourced into scripts with their own shell policy.

_review_host_is_codex_profile() {
  case "${1:-}" in
    codex*|*codex*) return 0 ;;
    *) return 1 ;;
  esac
}

_review_host_is_claude_profile() {
  case "${1:-}" in
    claude*|*claude*) return 0 ;;
    *) return 1 ;;
  esac
}

review_host_family() {
  local host="${1:-}" family repo_root
  repo_root="${REPO_ROOT:-}"
  if [ -z "$repo_root" ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  if command -v yq >/dev/null 2>&1 && [ -f "$repo_root/_shared/schemas/model-catalog.yaml" ]; then
    # shellcheck disable=SC2016
    family=$(HOST_NAME="$host" yq -r '
      (.adapter_profiles[strenv(HOST_NAME)].provider_family // "") as $direct
      | if $direct != "" then $direct
        else ((.provider_families | to_entries | map(select((.value.adapters // []) | contains([strenv(HOST_NAME)])) | .key) | .[0]) // "")
        end
    ' "$repo_root/_shared/schemas/model-catalog.yaml" 2>/dev/null || true)
    [ -n "$family" ] && [ "$family" != "null" ] && { printf '%s\n' "$family"; return 0; }
  fi
  if _review_host_is_codex_profile "$host"; then
    printf 'openai\n'
    return 0
  fi
  if _review_host_is_claude_profile "$host"; then
    printf 'anthropic\n'
    return 0
  fi
  case "$host" in
    unknown|"") printf 'unknown\n' ;;
    *) printf '%s\n' "$host" ;;
  esac
}

review_host_is_cross_family() {
  local parent="$1" reviewer="$2" parent_family reviewer_family
  [ -n "$parent" ] && [ "$parent" != "unknown" ] || return 1
  parent_family=$(review_host_family "$parent")
  reviewer_family=$(review_host_family "$reviewer")
  [ "$parent_family" != "$reviewer_family" ]
}

review_host_default_for_parent_host() {
  case "${1:-}" in
    codex*|*codex*) printf 'claude-reviewer\n' ;;
    claude-code|claude|claude-*|*claude*) printf 'codex-reviewer\n' ;;
    *) printf '%s\n' "${STUDIO_REVIEW_HOST:-claude-reviewer}" ;;
  esac
}

review_host_same_family_reviewer_for_parent() {
  case "${1:-}" in
    codex*|*codex*) printf 'codex-reviewer\n' ;;
    claude-code|claude|claude-*|*claude*) printf 'claude-reviewer\n' ;;
    *) return 1 ;;
  esac
}

review_host_resolve_context() {
  local host="${1:?usage: review_host_resolve_context <host> [operation]}" operation="${2:-delegated-host-spawn}"

  export STUDIO_CONTEXT_HOST_PROFILE="$host"
  studio_context_resolve "$operation" || return 1

  # shellcheck disable=SC2034
  REVIEW_HOST_PROFILE="$STUDIO_CONTEXT_HOST_PROFILE"
  # shellcheck disable=SC2034
  REVIEW_HOST_AUTH_HOME="$STUDIO_CONTEXT_AUTH_HOME"
  # shellcheck disable=SC2034
  REVIEW_HOST_GITHUB_HOME="$STUDIO_CONTEXT_GITHUB_HOME"
  # shellcheck disable=SC2034
  REVIEW_HOST_STUDIO_HOME="$STUDIO_CONTEXT_STUDIO_HOME"
  # shellcheck disable=SC2034
  REVIEW_HOST_RUNTIME_OWNER="$STUDIO_CONTEXT_RUNTIME_OWNER"
  # shellcheck disable=SC2034
  REVIEW_HOST_DATA_VISIBILITY="$STUDIO_CONTEXT_DATA_VISIBILITY"
  REVIEW_HOST_KIND=""
  REVIEW_HOST_CLAUDE_CONFIG_DIR=""
  REVIEW_HOST_CODEX_HOME=""

  case "$host" in
    codex*|*codex*)
      REVIEW_HOST_KIND="codex"
      REVIEW_HOST_CODEX_HOME="$REVIEW_HOST_AUTH_HOME"
      ;;
    claude*|*claude*)
      REVIEW_HOST_KIND="claude"
      REVIEW_HOST_CLAUDE_CONFIG_DIR="${CLAUDE_REVIEWER_CONFIG_DIR:-$REVIEW_HOST_AUTH_HOME/.claude-reviewer}"
      mkdir -p "$REVIEW_HOST_CLAUDE_CONFIG_DIR" || return 1
      ;;
  esac
}

review_host_run_command() {
  local host="${1:?usage: review_host_run_command <host> <scratch-home> [--stdin=open|closed] [--env KEY VALUE]... -- <command...>}"
  local scratch_home="${2:?usage: review_host_run_command <host> <scratch-home> [--stdin=open|closed] [--env KEY VALUE]... -- <command...>}"
  local stdin_mode="closed"
  local -a env_pairs=()
  local -a command=()
  local repo_root

  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stdin=open|--stdin=closed)
        stdin_mode="${1#--stdin=}"
        shift
        ;;
      --env)
        [ "$#" -ge 3 ] || return 2
        env_pairs+=("$2=$3")
        shift 3
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  command=("$@")

  review_host_resolve_context "$host" delegated-host-spawn || return 1

  repo_root="${REPO_ROOT:-}"
  if [ -z "$repo_root" ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi

  local -a run_env=(
    env -i
    PATH="$PATH"
    LANG="${LANG:-C.UTF-8}"
    USER="${USER:-}"
    STUDIO_HOST="$host"
  )

  case "$REVIEW_HOST_KIND" in
    codex)
      if [ "$REVIEW_HOST_CODEX_HOME" = "$HOME/.codex" ]; then
        run_env+=(HOME="$HOME")
      else
        run_env+=(HOME="$scratch_home")
        [ -n "$REVIEW_HOST_CODEX_HOME" ] && run_env+=(CODEX_HOME="$REVIEW_HOST_CODEX_HOME")
      fi
      ;;
    claude)
      run_env+=(HOME="$REVIEW_HOST_AUTH_HOME")
      [ -n "$REVIEW_HOST_CLAUDE_CONFIG_DIR" ] && run_env+=(CLAUDE_CONFIG_DIR="$REVIEW_HOST_CLAUDE_CONFIG_DIR")
      [ -n "$REVIEW_HOST_AUTH_HOME" ] && run_env+=(CLAUDE_REVIEWER_HOME="$REVIEW_HOST_AUTH_HOME")
      ;;
  esac

  local pair
  for pair in "${env_pairs[@]}"; do
    run_env+=("$pair")
  done

  if [ "$stdin_mode" = "open" ]; then
    ( cd "$repo_root" && "${run_env[@]}" "${command[@]}" )
  else
    ( cd "$repo_root" && "${run_env[@]}" "${command[@]}" </dev/null )
  fi
}
