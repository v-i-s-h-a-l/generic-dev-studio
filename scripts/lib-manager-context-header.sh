#!/usr/bin/env bash
#
# lib-manager-context-header.sh — shared manager context-header primitive.
#
# Every `/dev-studio manager …` surface (ingest, plan-chain, work-chain,
# config, branch, analyze, reconcile) renders this header so the user can
# verify branch state and configured branch-policy fields before any side
# effect. The header is informational; it does not gate or mutate.
#
# Sourced by:
#   - scripts/dev-studio-ingest-resolve.sh (ingest pre-flight)
#   - host SKILL.md flow surfaces that need an always-on header
#
# Schema is documented in _shared/standards/branch-discipline.md
# (per-project policy fields) and core/v2/skills/dev-studio/SKILL.md
# (Manager Context Header section).

_lib_manager_context_header_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd
}

if ! declare -F resolve_studio_home_for_login_home >/dev/null 2>&1; then
  # shellcheck source=scripts/lib-paths.sh
  . "$(_lib_manager_context_header_root)/scripts/lib-paths.sh"
fi
if ! declare -F feature_branch_policy_default_base_ref >/dev/null 2>&1; then
  # shellcheck source=scripts/lib-feature-branch-policy.sh
  . "$(_lib_manager_context_header_root)/scripts/lib-feature-branch-policy.sh"
fi

manager_context_header_load_policy() {
  local project="${1:?usage: manager_context_header_load_policy <project-slug>}"
  local studio_home config_file
  studio_home=$(resolve_studio_home_for_login_home "${HOME:?HOME required}" 2>/dev/null || true)
  [ -n "$studio_home" ] || return 0
  config_file="${STUDIO_FEATURE_CONFIG_FILE:-$studio_home/$project/config/features.env}"
  [ -f "$config_file" ] || return 0
  # shellcheck disable=SC1090
  . "$config_file" 2>/dev/null || true
}

# Populates MANAGER_CONTEXT_* shell variables in the caller's scope so both
# emit_text and emit_json can render without re-running git/policy work.
manager_context_header_collect() {
  local repo="${1:?usage: manager_context_header_collect <repo-root>}"
  local project current_branch head_sha resolved_sha

  project=$(basename "$repo")

  MANAGER_CONTEXT_PROJECT="$project"
  MANAGER_CONTEXT_REPO_ROOT="$repo"

  current_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ "$current_branch" = "HEAD" ] && current_branch=""
  MANAGER_CONTEXT_CURRENT_BRANCH="$current_branch"

  head_sha=$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || true)
  MANAGER_CONTEXT_HEAD_SHA="$head_sha"

  if git -C "$repo" diff --quiet --ignore-submodules HEAD -- 2>/dev/null \
     && git -C "$repo" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    MANAGER_CONTEXT_DIRTY=false
  else
    MANAGER_CONTEXT_DIRTY=true
  fi

  manager_context_header_load_policy "$project"

  MANAGER_CONTEXT_DEFAULT_BASE="${STUDIO_RELEASE_BRANCH_DEFAULT_BASE:-main}"
  MANAGER_CONTEXT_RELEASE_PATTERN="${STUDIO_RELEASE_BRANCH_PATTERN:-release/{version}}"
  case "${STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN:-}" in
    1|true|TRUE|yes|YES|on|ON) MANAGER_CONTEXT_MERGE_TARGET_TO_MAIN=true ;;
    *) MANAGER_CONTEXT_MERGE_TARGET_TO_MAIN=false ;;
  esac
  case "${STUDIO_BRANCH_POLICY_ALLOW_FEATURE_OFF_FEATURE:-}" in
    1|true|TRUE|yes|YES|on|ON) MANAGER_CONTEXT_ALLOW_FEATURE_OFF_FEATURE=true ;;
    *) MANAGER_CONTEXT_ALLOW_FEATURE_OFF_FEATURE=false ;;
  esac

  MANAGER_CONTEXT_BASE_REF="$MANAGER_CONTEXT_DEFAULT_BASE"
  resolved_sha=$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$MANAGER_CONTEXT_BASE_REF^{commit}" 2>/dev/null || true)
  if [ -z "$resolved_sha" ]; then
    resolved_sha=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$MANAGER_CONTEXT_BASE_REF^{commit}" 2>/dev/null || true)
  fi
  MANAGER_CONTEXT_BASE_SHA="$resolved_sha"

  if declare -F is_protected_branch >/dev/null 2>&1 \
     && [ -n "$current_branch" ] \
     && is_protected_branch "$current_branch"; then
    MANAGER_CONTEXT_ON_PROTECTED_BASE=true
  else
    MANAGER_CONTEXT_ON_PROTECTED_BASE=false
  fi
}

manager_context_header_emit_text() {
  local repo="${1:?usage: manager_context_header_emit_text <repo-root>}"
  manager_context_header_collect "$repo"
  local dirty_marker=""
  [ "$MANAGER_CONTEXT_DIRTY" = "true" ] && dirty_marker="*"
  printf 'manager context — project=%s branch=%s%s head=%s base_ref=%s base_sha=%s merge_target_to_main=%s release_pattern=%s allow_feature_off_feature=%s on_protected_base=%s\n' \
    "$MANAGER_CONTEXT_PROJECT" \
    "${MANAGER_CONTEXT_CURRENT_BRANCH:-(detached)}" \
    "$dirty_marker" \
    "${MANAGER_CONTEXT_HEAD_SHA:-unknown}" \
    "$MANAGER_CONTEXT_BASE_REF" \
    "${MANAGER_CONTEXT_BASE_SHA:-unresolved}" \
    "$MANAGER_CONTEXT_MERGE_TARGET_TO_MAIN" \
    "$MANAGER_CONTEXT_RELEASE_PATTERN" \
    "$MANAGER_CONTEXT_ALLOW_FEATURE_OFF_FEATURE" \
    "$MANAGER_CONTEXT_ON_PROTECTED_BASE"
}

manager_context_header_emit_json() {
  local repo="${1:?usage: manager_context_header_emit_json <repo-root>}"
  manager_context_header_collect "$repo"
  jq -n \
    --arg project "$MANAGER_CONTEXT_PROJECT" \
    --arg repo_root "$MANAGER_CONTEXT_REPO_ROOT" \
    --arg current_branch "$MANAGER_CONTEXT_CURRENT_BRANCH" \
    --arg head_sha "$MANAGER_CONTEXT_HEAD_SHA" \
    --arg base_ref "$MANAGER_CONTEXT_BASE_REF" \
    --arg base_sha "$MANAGER_CONTEXT_BASE_SHA" \
    --arg release_pattern "$MANAGER_CONTEXT_RELEASE_PATTERN" \
    --argjson dirty "$MANAGER_CONTEXT_DIRTY" \
    --argjson on_protected_base "$MANAGER_CONTEXT_ON_PROTECTED_BASE" \
    --argjson merge_target_to_main "$MANAGER_CONTEXT_MERGE_TARGET_TO_MAIN" \
    --argjson allow_feature_off_feature "$MANAGER_CONTEXT_ALLOW_FEATURE_OFF_FEATURE" \
    '{
      kind: "manager-context-header",
      schema_version: 1,
      project: $project,
      repo_root: $repo_root,
      current_branch: (if $current_branch == "" then null else $current_branch end),
      head_sha: (if $head_sha == "" then null else $head_sha end),
      dirty: $dirty,
      on_protected_base: $on_protected_base,
      base_ref: $base_ref,
      base_sha: (if $base_sha == "" then null else $base_sha end),
      policy: {
        default_base: $base_ref,
        release_branch_pattern: $release_pattern,
        merge_target_to_main: $merge_target_to_main,
        allow_feature_off_feature: $allow_feature_off_feature
      }
    }'
}

# CLI mode for hosts that want to render the header directly:
#   scripts/lib-manager-context-header.sh [--json|--text] [<repo-root>]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  emit_format=text
  repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) emit_format=json; shift ;;
      --text) emit_format=text; shift ;;
      -h|--help)
        printf 'usage: lib-manager-context-header.sh [--json|--text] [<repo-root>]\n'
        exit 0
        ;;
      --) shift; break ;;
      -*)
        printf 'error: unknown flag: %s\n' "$1" >&2
        exit 2
        ;;
      *) repo="$1"; shift ;;
    esac
  done
  if [ -z "$repo" ]; then
    repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  case "$emit_format" in
    json) manager_context_header_emit_json "$repo" ;;
    *)    manager_context_header_emit_text "$repo" ;;
  esac
fi
