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
#   pm-surface

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
project_board
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
: "${STUDIO_CONTEXT_PROJECT_BOARD:=}"
: "${STUDIO_CONTEXT_PROJECT_BOARD_SOURCE:=}"
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
    pm|pm-surface|project-board) operation="pm-surface" ;;
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
  local repo_root="$1" slug
  if [ -n "${STUDIO_CONTEXT_PROJECT_SLUG:-}" ]; then
    printf '%s\n' "$STUDIO_CONTEXT_PROJECT_SLUG"
    return 0
  fi
  if [ -n "${ACHILLES_PROJECT:-}" ]; then
    printf '%s\n' "$ACHILLES_PROJECT"
    return 0
  fi
  # Prefer resolve_project so linked worktrees (where basename($repo_root) is
  # the worktree dir, not the main project slug) resolve to the main project.
  if slug=$(resolve_project 2>/dev/null); then
    printf '%s\n' "$slug"
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
      if [ -n "${CODEX_REVIEWER_HOME:-}" ]; then
        printf '%s\n' "$CODEX_REVIEWER_HOME"
      elif [ -n "${CODEX_HOME:-}" ]; then
        printf '%s\n' "$CODEX_HOME"
      else
        login_home=$(_studio_context_login_home) || return 1
        if [ -d "$login_home/.codex-reviewer" ]; then
          printf '%s\n' "$login_home/.codex-reviewer"
        else
          printf '%s\n' "$login_home/.codex"
        fi
      fi
      ;;
    claude-code)
      login_home=$(_studio_context_login_home) || return 1
      printf '%s\n' "${CLAUDE_HOME:-$login_home}"
      ;;
    claude-reviewer)
      if [ -n "${CLAUDE_REVIEWER_HOME:-}" ]; then
        printf '%s\n' "$CLAUDE_REVIEWER_HOME"
      else
        login_home=$(_studio_context_login_home) || return 1
        printf '%s\n' "$login_home"
      fi
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

# Read a project-board YAML file and return the canonical owner_kind:owner_login:project_number
# token. Empty stdout (exit 0) when required keys are missing — the caller
# treats that as "not configured here" and walks the next discovery step.
_studio_context_project_board_token_from_file() {
  local file="$1" owner_kind owner_login project_number
  [ -f "$file" ] || { printf '%s\n' ""; return 0; }
  owner_kind=$(project_board_yaml_scalar "$file" owner_kind 2>/dev/null || true)
  owner_login=$(project_board_yaml_scalar "$file" owner_login 2>/dev/null || true)
  project_number=$(project_board_yaml_scalar "$file" project_number 2>/dev/null || true)
  if [ -z "$owner_kind" ] || [ -z "$owner_login" ] || [ -z "$project_number" ]; then
    printf '%s\n' ""
    return 0
  fi
  case "$owner_kind" in
    user|org) ;;
    *)
      _studio_context_fail "project-board.yaml owner_kind must be user or org (got '$owner_kind') at $file"
      return 1
      ;;
  esac
  case "$project_number" in
    ''|*[!0-9]*)
      _studio_context_fail "project-board.yaml project_number must be a positive integer (got '$project_number') at $file"
      return 1
      ;;
  esac
  printf '%s:%s:%s\n' "$owner_kind" "$owner_login" "$project_number"
}

# Validate a colon-encoded `<owner_kind>:<owner_login>:<project_number>` override.
_studio_context_project_board_validate_token() {
  local token="$1" source_label="$2"
  local owner_kind owner_login project_number
  owner_kind=${token%%:*}
  local rest=${token#*:}
  owner_login=${rest%%:*}
  project_number=${rest#*:}
  case "$owner_kind" in
    user|org) ;;
    *)
      _studio_context_fail "$source_label owner_kind must be 'user' or 'org' (expected <user|org>:<login>:<n>, got '$token')"
      return 1
      ;;
  esac
  if [ -z "$owner_login" ] || [ "$owner_login" = "$token" ]; then
    _studio_context_fail "$source_label missing owner_login: '$token'"
    return 1
  fi
  case "$project_number" in
    ''|*[!0-9]*)
      _studio_context_fail "$source_label project_number must be a positive integer: '$token'"
      return 1
      ;;
  esac
  return 0
}

# Resolve the project-board identity for the current context. Walks the
# discovery order defined in PM-SURFACE.md §Per-Project Project Board
# Portability Contract and _shared/contracts/studio-context.md §Project
# Board Resolution:
#
#   1. STUDIO_CONTEXT_PROJECT_BOARD (caller-set; treated as a CLI flag handoff)
#   2. STUDIO_PROJECT_BOARD_OVERRIDE env override
#   3. Runtime override at <studio_home>/<project_slug>/config/project-board.yaml
#   4. Durable repo file at profiles/<project_slug>/project-board.yaml
#   5. Empty (caller decides whether to loud-fail; the validator enforces it
#      for pm-surface operations)
#
# Sets STUDIO_CONTEXT_PROJECT_BOARD and STUDIO_CONTEXT_PROJECT_BOARD_SOURCE
# directly (not via command substitution) so the source label survives.
# Source values: cli | env_override | runtime_override | durable | missing.
_studio_context_project_board() {
  local repo_root="$1" project_slug="$2"
  local token=""

  if [ -n "${STUDIO_CONTEXT_PROJECT_BOARD:-}" ]; then
    _studio_context_project_board_validate_token \
      "$STUDIO_CONTEXT_PROJECT_BOARD" "STUDIO_CONTEXT_PROJECT_BOARD" || return 1
    STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="cli"
    return 0
  fi

  if [ -n "${STUDIO_PROJECT_BOARD_OVERRIDE:-}" ]; then
    _studio_context_project_board_validate_token \
      "$STUDIO_PROJECT_BOARD_OVERRIDE" "STUDIO_PROJECT_BOARD_OVERRIDE" || return 1
    STUDIO_CONTEXT_PROJECT_BOARD="$STUDIO_PROJECT_BOARD_OVERRIDE"
    STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="env_override"
    return 0
  fi

  if [ -n "$project_slug" ]; then
    local runtime_yaml
    runtime_yaml=$(resolve_project_board_config_runtime_for "$project_slug" "$STUDIO_CONTEXT_STUDIO_HOME")
    if [ -f "$runtime_yaml" ]; then
      token=$(_studio_context_project_board_token_from_file "$runtime_yaml") || return 1
      if [ -n "$token" ]; then
        STUDIO_CONTEXT_PROJECT_BOARD="$token"
        STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="runtime_override"
        printf 'lib-studio-context: project_board sourced from runtime override at %s\n' \
          "$runtime_yaml" >&2
        return 0
      fi
    fi
  fi

  if [ -n "$repo_root" ] && [ -n "$project_slug" ]; then
    local durable_yaml
    durable_yaml=$(resolve_project_board_config_durable_for "$project_slug" "$repo_root")
    if [ -f "$durable_yaml" ]; then
      token=$(_studio_context_project_board_token_from_file "$durable_yaml") || return 1
      if [ -n "$token" ]; then
        STUDIO_CONTEXT_PROJECT_BOARD="$token"
        STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="durable"
        return 0
      fi
    fi
  fi

  STUDIO_CONTEXT_PROJECT_BOARD=""
  STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="missing"
  return 0
}

# Locate the actual project-board.yaml file (if any) that backed the
# resolution. Returns empty for env_override / cli / missing sources.
studio_context_project_board_source_path() {
  local project_slug="${1:-${STUDIO_CONTEXT_PROJECT_SLUG:-}}"
  local repo_root="${2:-${STUDIO_CONTEXT_REPO_ROOT:-}}"
  case "${STUDIO_CONTEXT_PROJECT_BOARD_SOURCE:-}" in
    runtime_override)
      [ -n "$project_slug" ] || return 1
      resolve_project_board_config_runtime_for "$project_slug" "$STUDIO_CONTEXT_STUDIO_HOME"
      ;;
    durable)
      [ -n "$project_slug" ] || return 1
      [ -n "$repo_root" ] || return 1
      resolve_project_board_config_durable_for "$project_slug" "$repo_root"
      ;;
    *)
      return 1
      ;;
  esac
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
    read-only|runtime-mutation|repo-mutation|github-operation|delegated-host-spawn|release-action|test-debug-fixture|pm-surface) ;;
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

  if [ "$operation" = "pm-surface" ]; then
    [ -n "$STUDIO_CONTEXT_PROJECT_SLUG" ] || { _studio_context_fail "project_slug missing for $operation"; return 1; }
    if [ -z "$STUDIO_CONTEXT_PROJECT_BOARD" ]; then
      local durable_hint runtime_hint
      durable_hint=$(resolve_project_board_config_durable_for "$STUDIO_CONTEXT_PROJECT_SLUG" "${STUDIO_CONTEXT_REPO_ROOT:-}" 2>/dev/null || true)
      runtime_hint=$(resolve_project_board_config_runtime_for "$STUDIO_CONTEXT_PROJECT_SLUG" "$STUDIO_CONTEXT_STUDIO_HOME" 2>/dev/null || true)
      _studio_context_fail \
"project_board missing for $operation (project_slug=$STUDIO_CONTEXT_PROJECT_SLUG); \
expected one of: --project-board CLI flag, STUDIO_PROJECT_BOARD_OVERRIDE env, \
runtime override at ${runtime_hint:-<studio_home>/<project_slug>/config/project-board.yaml}, \
or durable repo file at ${durable_hint:-profiles/<project_slug>/project-board.yaml}"
      return 1
    fi
  fi

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
  # Sets STUDIO_CONTEXT_PROJECT_BOARD and STUDIO_CONTEXT_PROJECT_BOARD_SOURCE directly.
  _studio_context_project_board "$repo_root" "$project_slug" || return 1

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
    project_board) printf '%s\n' "$STUDIO_CONTEXT_PROJECT_BOARD" ;;
    project_board_source) printf '%s\n' "$STUDIO_CONTEXT_PROJECT_BOARD_SOURCE" ;;
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
studio_context_project_board() { studio_context_get project_board   "${1:-read-only}"; }

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
  printf 'export STUDIO_CONTEXT_PROJECT_BOARD_SOURCE=%q\n' "$STUDIO_CONTEXT_PROJECT_BOARD_SOURCE"
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
    --arg project_board "$STUDIO_CONTEXT_PROJECT_BOARD" \
    --arg project_board_source "$STUDIO_CONTEXT_PROJECT_BOARD_SOURCE" \
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
      data_visibility: $data_visibility,
      project_board: (if $project_board == "" then null else $project_board end),
      project_board_source: (if $project_board_source == "" then null else $project_board_source end)
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
    STUDIO_CONTEXT_PROJECT_BOARD="$STUDIO_CONTEXT_PROJECT_BOARD" \
    STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="$STUDIO_CONTEXT_PROJECT_BOARD_SOURCE" \
    "$@"
}
