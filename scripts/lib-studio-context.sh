#!/usr/bin/env bash
# lib-studio-context.sh - canonical Studio context envelope resolver.
#
# This library is intentionally sourceable and side-effect-light. It does not
# migrate existing callers by itself; it gives later migration issues one place
# to resolve durable Studio state, host auth roots, GitHub auth roots, repo
# roots, and visibility/ownership metadata.
#
# Public functions:
#   studio_context_resolve [operation]
#   studio_context_validate [operation]
#   studio_context_get <field> [operation]
#   studio_context_<field> [operation]
#   studio_context_emit_env [operation]
#   studio_context_emit_json [operation]
#   studio_context_run <operation> -- <command...>
#
# Supported operations:
#   read-only
#   runtime-mutation
#   repo-mutation
#   github-operation
#   delegated-host-spawn
#   release-action
#   test-debug-fixture

# No `set -e` here - sourced into scripts that choose their own shell policy.

STUDIO_CONTEXT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$STUDIO_CONTEXT_LIB_DIR/lib-paths.sh"

STUDIO_CONTEXT_FIELD_NAMES=$(cat <<'EOF'
studio_home
project_slug
repo_root
host_profile
auth_home
github_home
runtime_owner
data_visibility
EOF
)
: "${STUDIO_CONTEXT_OPERATION:=}"
: "${STUDIO_CONTEXT_STUDIO_HOME:=}"
: "${STUDIO_CONTEXT_PROJECT_SLUG:=}"
: "${STUDIO_CONTEXT_REPO_ROOT:=}"
: "${STUDIO_CONTEXT_HOST_PROFILE:=}"
: "${STUDIO_CONTEXT_AUTH_HOME:=}"
: "${STUDIO_CONTEXT_GITHUB_HOME:=}"
: "${STUDIO_CONTEXT_RUNTIME_OWNER:=}"
: "${STUDIO_CONTEXT_DATA_VISIBILITY:=}"
: "${STUDIO_CONTEXT_LAST_ERROR:=}"

_studio_context_fail() {
  STUDIO_CONTEXT_LAST_ERROR="$*"
  printf 'lib-studio-context: %s\n' "$*" >&2
  return 1
}

_studio_context_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_studio_context_normalize_operation() {
  local operation="${1:-read-only}"
  operation="${operation//_/-}"
  case "$operation" in
    read|readonly) operation="read-only" ;;
    runtime|runtime-write|runtime-mutation) operation="runtime-mutation" ;;
    repo|repo-write|repo-mutation) operation="repo-mutation" ;;
    github|github-op|github-operation) operation="github-operation" ;;
    delegated-host|delegated-host-spawn|host-spawn) operation="delegated-host-spawn" ;;
    release|release-action) operation="release-action" ;;
    test|debug|test-debug-fixture) operation="test-debug-fixture" ;;
  esac
  printf '%s\n' "$operation"
}

_studio_context_canonical_host_profile() {
  local profile="${1:-}"
  case "$profile" in
    claude|claude-code) printf '%s\n' "claude-code" ;;
    codex|codex-cli) printf '%s\n' "codex" ;;
    claude-reviewer|codex-reviewer|gemini|gemini-cli) printf '%s\n' "$profile" ;;
    "") printf '%s\n' "unknown" ;;
    *) printf '%s\n' "$profile" ;;
  esac
}

_studio_context_resolve_host_profile() {
  if [ -n "${STUDIO_CONTEXT_HOST_PROFILE:-}" ]; then
    _studio_context_canonical_host_profile "$STUDIO_CONTEXT_HOST_PROFILE"
    return 0
  fi
  if [ -n "${STUDIO_HOST_PROFILE:-}" ]; then
    _studio_context_canonical_host_profile "$STUDIO_HOST_PROFILE"
    return 0
  fi
  _studio_context_canonical_host_profile "$(resolve_current_studio_host unknown)"
}

_studio_context_login_home() {
  local login_home=""
  login_home=$(resolve_user_login_home 2>/dev/null || true)
  if [ -n "$login_home" ] && [ -d "$login_home" ] && ! studio_home_is_synthetic "$login_home"; then
    printf '%s\n' "$login_home"
    return 0
  fi
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && ! studio_home_is_synthetic "$HOME"; then
    printf '%s\n' "$HOME"
    return 0
  fi
  _studio_context_fail "cannot resolve non-synthetic login home; set STUDIO_CONTEXT_STUDIO_HOME explicitly or fix host launch context"
}

_studio_context_repo_root() {
  if [ -n "${STUDIO_CONTEXT_REPO_ROOT:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_REPO_ROOT"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || true
}

_studio_context_project_slug() {
  local repo_root="$1"
  if [ -n "${STUDIO_CONTEXT_PROJECT_SLUG:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_PROJECT_SLUG"
    return 0
  fi
  if [ -n "${ACHILLES_PROJECT:-}" ]; then
    printf '%s\n' "$ACHILLES_PROJECT"
    return 0
  fi
  if [ -n "$repo_root" ]; then
    basename "$repo_root"
    return 0
  fi
  printf '%s\n' ""
}

_studio_context_default_studio_home() {
  local login_home
  if [ -n "${STUDIO_CONTEXT_STUDIO_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_STUDIO_HOME"
    return 0
  fi
  if [ -n "${STUDIO_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_HOME"
    return 0
  fi
  login_home=$(_studio_context_login_home) || return 1
  # Durable Studio state is rooted in the classified login home. Raw ambient
  # HOME is only accepted after the resolver proves it is not a synthetic host
  # home in _studio_context_login_home.
  resolve_studio_home_for_login_home "$login_home"
}

_studio_context_auth_home_for_profile() {
  local profile="$1" login_home
  if [ -n "${STUDIO_CONTEXT_AUTH_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_AUTH_HOME"
    return 0
  fi
  case "$profile" in
    codex)
      if [ -n "${CODEX_HOME:-}" ]; then
        printf '%s\n' "$CODEX_HOME"
      else
        login_home=$(_studio_context_login_home) || return 1
        printf '%s\n' "$login_home/.codex"
      fi
      ;;
    codex-reviewer)
      printf '%s\n' "${CODEX_REVIEWER_HOME:-}"
      ;;
    claude-code)
      login_home=$(_studio_context_login_home) || return 1
      printf '%s\n' "${CLAUDE_HOME:-$login_home}"
      ;;
    claude-reviewer)
      printf '%s\n' "${CLAUDE_REVIEWER_HOME:-}"
      ;;
    gemini|gemini-cli)
      login_home=$(_studio_context_login_home) || return 1
      printf '%s\n' "${GEMINI_HOME:-$login_home/.gemini}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

_studio_context_github_home() {
  if [ -n "${STUDIO_CONTEXT_GITHUB_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_GITHUB_HOME"
    return 0
  fi
  if _studio_context_truthy "${STUDIO_BYPASS_PARENT_HOME_FLIP:-0}"; then
    printf 'lib-studio-context: STUDIO_BYPASS_PARENT_HOME_FLIP active; github_home uses caller HOME for explicit debug/isolation only\n' >&2
  fi
  resolve_parent_home_for_github
}

_studio_context_runtime_owner() {
  if [ -n "${STUDIO_CONTEXT_RUNTIME_OWNER:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_RUNTIME_OWNER"
    return 0
  fi
  case "${1:-}" in
    claude-reviewer|codex-reviewer) printf '%s\n' "reviewer" ;;
    *) printf '%s\n' "project" ;;
  esac
}

_studio_context_data_visibility() {
  if [ -n "${STUDIO_CONTEXT_DATA_VISIBILITY:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_DATA_VISIBILITY"
    return 0
  fi
  printf '%s\n' "private-runtime"
}

_studio_context_path_is_under() {
  local child="${1%/}" parent="${2%/}"
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  [ "$child" = "$parent" ] && return 0
  case "$child/" in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_studio_context_field_has_newline() {
  case "$1" in
    *'
'*) return 0 ;;
    *) return 1 ;;
  esac
}

_studio_context_validate_current() {
  local operation="$1" field value tmpdir
  case "$operation" in
    read-only|runtime-mutation|repo-mutation|github-operation|delegated-host-spawn|release-action|test-debug-fixture) ;;
    *) _studio_context_fail "unsupported operation: $operation"; return 1 ;;
  esac

  while IFS= read -r field; do
    [ -n "$field" ] || continue
    value=$(studio_context_get_cached "$field")
    if _studio_context_field_has_newline "$value"; then
      _studio_context_fail "$field contains a newline and cannot be handed across a shell command boundary"
      return 1
    fi
  done <<EOF
$STUDIO_CONTEXT_FIELD_NAMES
EOF

  [ -n "$STUDIO_CONTEXT_STUDIO_HOME" ] || { _studio_context_fail "studio_home missing for $operation"; return 1; }
  [ -n "$STUDIO_CONTEXT_HOST_PROFILE" ] || { _studio_context_fail "host_profile missing for $operation"; return 1; }
  [ -n "$STUDIO_CONTEXT_RUNTIME_OWNER" ] || { _studio_context_fail "runtime_owner missing for $operation"; return 1; }
  [ -n "$STUDIO_CONTEXT_DATA_VISIBILITY" ] || { _studio_context_fail "data_visibility missing for $operation"; return 1; }

  if studio_home_is_synthetic "$STUDIO_CONTEXT_STUDIO_HOME"; then
    _studio_context_fail "studio_home points inside synthetic host home for $operation: $STUDIO_CONTEXT_STUDIO_HOME"
    return 1
  fi

  if [ -n "${STUDIO_CONTEXT_PROJECT_SLUG:-}" ] \
      && [ -n "${ACHILLES_PROJECT:-}" ] \
      && [ "$STUDIO_CONTEXT_PROJECT_SLUG" != "$ACHILLES_PROJECT" ]; then
    _studio_context_fail "project_slug conflicts with ACHILLES_PROJECT for $operation"
    return 1
  fi

  case "$STUDIO_CONTEXT_RUNTIME_OWNER" in
    project|machine|host|reviewer|temporary) ;;
    *) _studio_context_fail "runtime_owner has unsupported value for $operation: $STUDIO_CONTEXT_RUNTIME_OWNER"; return 1 ;;
  esac

  case "$STUDIO_CONTEXT_DATA_VISIBILITY" in
    public-repo|private-runtime|host-auth|secret|temporary) ;;
    *) _studio_context_fail "data_visibility has unsupported value for $operation: $STUDIO_CONTEXT_DATA_VISIBILITY"; return 1 ;;
  esac

  case "$operation" in
    runtime-mutation|repo-mutation)
      [ -n "$STUDIO_CONTEXT_PROJECT_SLUG" ] || { _studio_context_fail "project_slug missing for $operation"; return 1; }
      ;;
  esac

  if [ "$operation" = "repo-mutation" ]; then
    [ -n "$STUDIO_CONTEXT_REPO_ROOT" ] || { _studio_context_fail "repo_root missing for $operation"; return 1; }
  fi

  case "$operation" in
    github-operation|release-action)
      [ -n "$STUDIO_CONTEXT_GITHUB_HOME" ] || { _studio_context_fail "github_home missing for $operation"; return 1; }
      [ -d "$STUDIO_CONTEXT_GITHUB_HOME" ] || { _studio_context_fail "github_home is not a directory for $operation: $STUDIO_CONTEXT_GITHUB_HOME"; return 1; }
      ;;
  esac

  case "$operation" in
    delegated-host-spawn|release-action)
      [ -n "$STUDIO_CONTEXT_AUTH_HOME" ] || { _studio_context_fail "auth_home missing for $operation and host_profile=$STUDIO_CONTEXT_HOST_PROFILE"; return 1; }
      [ -d "$STUDIO_CONTEXT_AUTH_HOME" ] || { _studio_context_fail "auth_home is not a directory for $operation: $STUDIO_CONTEXT_AUTH_HOME"; return 1; }
      ;;
  esac

  if [ "$operation" = "runtime-mutation" ]; then
    tmpdir="${TMPDIR:-/tmp}"
    if _studio_context_path_is_under "$STUDIO_CONTEXT_STUDIO_HOME" "$tmpdir"; then
      _studio_context_fail "studio_home points under temporary root for $operation: $STUDIO_CONTEXT_STUDIO_HOME"
      return 1
    fi
  fi

  if [ "$STUDIO_CONTEXT_DATA_VISIBILITY" = "secret" ] \
      && [ -n "$STUDIO_CONTEXT_REPO_ROOT" ] \
      && _studio_context_path_is_under "$STUDIO_CONTEXT_STUDIO_HOME" "$STUDIO_CONTEXT_REPO_ROOT"; then
    _studio_context_fail "secret data_visibility cannot write under repo_root for $operation"
    return 1
  fi

  return 0
}

studio_context_resolve() {
  local operation profile repo_root project_slug
  operation=$(_studio_context_normalize_operation "${1:-read-only}")
  profile=$(_studio_context_resolve_host_profile)
  repo_root=$(_studio_context_repo_root)
  project_slug=$(_studio_context_project_slug "$repo_root")

  STUDIO_CONTEXT_OPERATION="$operation"
  STUDIO_CONTEXT_REPO_ROOT="$repo_root"
  STUDIO_CONTEXT_PROJECT_SLUG="$project_slug"
  STUDIO_CONTEXT_HOST_PROFILE="$profile"
  STUDIO_CONTEXT_STUDIO_HOME=$(_studio_context_default_studio_home) || return 1
  STUDIO_CONTEXT_AUTH_HOME=$(_studio_context_auth_home_for_profile "$profile") || return 1
  STUDIO_CONTEXT_GITHUB_HOME=$(_studio_context_github_home) || return 1
  STUDIO_CONTEXT_RUNTIME_OWNER=$(_studio_context_runtime_owner "$profile") || return 1
  STUDIO_CONTEXT_DATA_VISIBILITY=$(_studio_context_data_visibility) || return 1

  _studio_context_validate_current "$operation"
}

studio_context_validate() {
  studio_context_resolve "${1:-read-only}"
}

studio_context_get_cached() {
  case "${1:-}" in
    studio_home) printf '%s\n' "$STUDIO_CONTEXT_STUDIO_HOME" ;;
    project_slug) printf '%s\n' "$STUDIO_CONTEXT_PROJECT_SLUG" ;;
    repo_root) printf '%s\n' "$STUDIO_CONTEXT_REPO_ROOT" ;;
    host_profile) printf '%s\n' "$STUDIO_CONTEXT_HOST_PROFILE" ;;
    auth_home) printf '%s\n' "$STUDIO_CONTEXT_AUTH_HOME" ;;
    github_home) printf '%s\n' "$STUDIO_CONTEXT_GITHUB_HOME" ;;
    runtime_owner) printf '%s\n' "$STUDIO_CONTEXT_RUNTIME_OWNER" ;;
    data_visibility) printf '%s\n' "$STUDIO_CONTEXT_DATA_VISIBILITY" ;;
    operation) printf '%s\n' "$STUDIO_CONTEXT_OPERATION" ;;
    *) _studio_context_fail "unknown context field: ${1:-}"; return 2 ;;
  esac
}

studio_context_get() {
  local field="${1:?usage: studio_context_get <field> [operation]}" operation="${2:-read-only}"
  studio_context_resolve "$operation" || return 1
  studio_context_get_cached "$field"
}

studio_context_studio_home()    { studio_context_get studio_home    "${1:-read-only}"; }
studio_context_project_slug()   { studio_context_get project_slug   "${1:-read-only}"; }
studio_context_repo_root()      { studio_context_get repo_root      "${1:-read-only}"; }
studio_context_host_profile()   { studio_context_get host_profile   "${1:-read-only}"; }
studio_context_auth_home()      { studio_context_get auth_home      "${1:-read-only}"; }
studio_context_github_home()    { studio_context_get github_home    "${1:-read-only}"; }
studio_context_runtime_owner()  { studio_context_get runtime_owner  "${1:-read-only}"; }
studio_context_data_visibility(){ studio_context_get data_visibility "${1:-read-only}"; }

studio_context_emit_env() {
  local operation="${1:-read-only}" field value env_name
  studio_context_resolve "$operation" || return 1
  printf 'export STUDIO_CONTEXT_OPERATION=%q\n' "$STUDIO_CONTEXT_OPERATION"
  while IFS= read -r field; do
    [ -n "$field" ] || continue
    value=$(studio_context_get_cached "$field")
    env_name="STUDIO_CONTEXT_$(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')"
    printf 'export %s=%q\n' "$env_name" "$value"
  done <<EOF
$STUDIO_CONTEXT_FIELD_NAMES
EOF
}

studio_context_emit_json() {
  local operation="${1:-read-only}"
  studio_context_resolve "$operation" || return 1
  command -v jq >/dev/null 2>&1 || {
    _studio_context_fail "jq is required for JSON context emission"
    return 127
  }
  jq -n \
    --arg schema_version "1" \
    --arg kind "studio-context" \
    --arg operation "$STUDIO_CONTEXT_OPERATION" \
    --arg studio_home "$STUDIO_CONTEXT_STUDIO_HOME" \
    --arg project_slug "$STUDIO_CONTEXT_PROJECT_SLUG" \
    --arg repo_root "$STUDIO_CONTEXT_REPO_ROOT" \
    --arg host_profile "$STUDIO_CONTEXT_HOST_PROFILE" \
    --arg auth_home "$STUDIO_CONTEXT_AUTH_HOME" \
    --arg github_home "$STUDIO_CONTEXT_GITHUB_HOME" \
    --arg runtime_owner "$STUDIO_CONTEXT_RUNTIME_OWNER" \
    --arg data_visibility "$STUDIO_CONTEXT_DATA_VISIBILITY" \
    '{
      schema_version: ($schema_version | tonumber),
      kind: $kind,
      operation: $operation,
      studio_home: $studio_home,
      project_slug: $project_slug,
      repo_root: $repo_root,
      host_profile: $host_profile,
      auth_home: $auth_home,
      github_home: $github_home,
      runtime_owner: $runtime_owner,
      data_visibility: $data_visibility
    }'
}

studio_context_run() {
  local operation="${1:?usage: studio_context_run <operation> -- <command...>}"
  shift
  [ "${1:-}" != "--" ] || shift
  [ "$#" -gt 0 ] || {
    _studio_context_fail "studio_context_run requires a command"
    return 2
  }
  studio_context_resolve "$operation" || return 1
  env \
    STUDIO_CONTEXT_OPERATION="$STUDIO_CONTEXT_OPERATION" \
    STUDIO_CONTEXT_STUDIO_HOME="$STUDIO_CONTEXT_STUDIO_HOME" \
    STUDIO_CONTEXT_PROJECT_SLUG="$STUDIO_CONTEXT_PROJECT_SLUG" \
    STUDIO_CONTEXT_REPO_ROOT="$STUDIO_CONTEXT_REPO_ROOT" \
    STUDIO_CONTEXT_HOST_PROFILE="$STUDIO_CONTEXT_HOST_PROFILE" \
    STUDIO_CONTEXT_AUTH_HOME="$STUDIO_CONTEXT_AUTH_HOME" \
    STUDIO_CONTEXT_GITHUB_HOME="$STUDIO_CONTEXT_GITHUB_HOME" \
    STUDIO_CONTEXT_RUNTIME_OWNER="$STUDIO_CONTEXT_RUNTIME_OWNER" \
    STUDIO_CONTEXT_DATA_VISIBILITY="$STUDIO_CONTEXT_DATA_VISIBILITY" \
    "$@"
}
