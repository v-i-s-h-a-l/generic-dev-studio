#!/usr/bin/env bash
# studio-chain-rule-gates.sh - deterministic workflow gates for chain execution.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-feature-branch-policy.sh
. "$SCRIPT_DIR/lib-feature-branch-policy.sh"

PLAN=""
MANIFEST=""
REPO="$REPO_ROOT"
AUDIT_LOG=""
EXPECTED_RUN_WORK_ROOT=""
DRY_RUN=0
ENFORCE_GIT_WORKFLOW=0

usage() {
  cat >&2 <<'EOF'
usage: studio-chain-rule-gates.sh --plan <plan.json> [--manifest <path>] [--repo <path>] [--audit-log <jsonl>] [--expected-run-work-root <path>] [--dry-run] [--enforce-git-workflow]

Runs deterministic rule-pack gates. Failed hard gates exit 4 unless the gate's
documented STUDIO_BYPASS_* environment override is set to 1. A JSON result is
printed to stdout; audit events are appended to --audit-log when supplied.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="${2:?--plan requires a path}"; shift 2 ;;
    --plan=*) PLAN="${1#--plan=}"; shift ;;
    --manifest) MANIFEST="${2:?--manifest requires a path}"; shift 2 ;;
    --manifest=*) MANIFEST="${1#--manifest=}"; shift ;;
    --repo) REPO="${2:?--repo requires a path}"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --audit-log) AUDIT_LOG="${2:?--audit-log requires a path}"; shift 2 ;;
    --audit-log=*) AUDIT_LOG="${1#--audit-log=}"; shift ;;
    --expected-run-work-root) EXPECTED_RUN_WORK_ROOT="${2:?--expected-run-work-root requires a path}"; shift 2 ;;
    --expected-run-work-root=*) EXPECTED_RUN_WORK_ROOT="${1#--expected-run-work-root=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --enforce-git-workflow) ENFORCE_GIT_WORKFLOW=1; shift ;;
    -h|--help) usage ;;
    *) printf 'studio-chain-rule-gates: unexpected argument: %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$PLAN" ] || usage
[ -f "$PLAN" ] || { printf 'studio-chain-rule-gates: plan not found: %s\n' "$PLAN" >&2; exit 2; }
[ -d "$REPO" ] || { printf 'studio-chain-rule-gates: repo not found: %s\n' "$REPO" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-rule-gates: jq is required\n' >&2; exit 2; }
if ! jq empty "$PLAN" >/dev/null 2>&1; then
  printf 'studio-chain-rule-gates: plan is not valid JSON: %s\n' "$PLAN" >&2
  exit 2
fi

TMPROOT=$(mktemp -d -t studio-chain-rule-gates.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
CHECKS_JSONL="$TMPROOT/checks.jsonl"
: >"$CHECKS_JSONL"

iso_ts_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

audit_event() {
  local gate_id="$1" status="$2" severity="$3" override_env="$4" detail="$5"
  [ -n "$AUDIT_LOG" ] || return 0
  mkdir -p "$(dirname "$AUDIT_LOG")"
  jq -cn \
    --arg schema_version "1" \
    --arg kind "studio-chain-rule-gate-audit" \
    --arg created_at "$(iso_ts_now)" \
    --arg gate_id "$gate_id" \
    --arg status "$status" \
    --arg severity "$severity" \
    --arg override_env "$override_env" \
    --arg detail "$detail" \
    --arg manifest "$MANIFEST" \
    --arg plan "$PLAN" \
    --argjson dry_run "$DRY_RUN" \
    '{schema_version:($schema_version|tonumber),kind:$kind,created_at:$created_at,gate_id:$gate_id,status:$status,severity:$severity,override_env:(if $override_env == "" then null else $override_env end),detail:$detail,manifest:(if $manifest == "" then null else $manifest end),plan:$plan,dry_run:$dry_run}' \
    >>"$AUDIT_LOG"
}

record_check() {
  local gate_id="$1" status="$2" severity="$3" override_env="$4" detail="$5"
  jq -cn \
    --arg id "$gate_id" \
    --arg status "$status" \
    --arg severity "$severity" \
    --arg override_env "$override_env" \
    --arg detail "$detail" \
    '{id:$id,status:$status,severity:$severity,override_env:(if $override_env == "" then null else $override_env end),detail:$detail}' \
    >>"$CHECKS_JSONL"
  audit_event "$gate_id" "$status" "$severity" "$override_env" "$detail"
}

gate_pass() {
  record_check "$1" "passed" "${2:-hard}" "${3:-}" "${4:-passed}"
}

gate_skip() {
  record_check "$1" "skipped" "${2:-hard}" "${3:-}" "${4:-not applicable}"
}

gate_fail() {
  local gate_id="$1" severity="${2:-hard}" override_env="${3:-}" detail="${4:-failed}" override_value=""
  if [ -n "$override_env" ]; then
    override_value="${!override_env:-}"
  fi
  if [ "$override_value" = "1" ]; then
    record_check "$gate_id" "override" "$severity" "$override_env" "$detail"
  else
    record_check "$gate_id" "failed" "$severity" "$override_env" "$detail"
  fi
}

sanitize_ref_for_lock() {
  printf '%s' "$1" | tr '/.' '__' | tr -cd 'A-Za-z0-9_-'
}

path_under_root() {
  local root="$1" path="$2" canonical_root canonical_path
  [ -n "$root" ] || return 1
  [ -n "$path" ] || return 1
  mkdir -p "$root"
  canonical_root=$(cd "$root" && pwd -P) || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if [ -e "$path" ]; then
    canonical_path=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
  else
    canonical_path=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path") || return 1
  fi
  case "$canonical_path" in
    "$canonical_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_secret_like_text() {
  LC_ALL=C grep -E '(gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{20,})' "$1" >/dev/null 2>&1
}

if [ "$ENFORCE_GIT_WORKFLOW" -eq 1 ]; then
  dirty=$(git -C "$REPO" status --porcelain --untracked-files=all -- . ':!.studio' ':!.studio/**' 2>/dev/null || true)
  if [ -z "$dirty" ]; then
    gate_pass dirty_tree_and_index hard STUDIO_BYPASS_DIRTY_TREE_GATE "repo tree and index are clean"
  else
    gate_fail dirty_tree_and_index hard STUDIO_BYPASS_DIRTY_TREE_GATE "repo has unstaged, staged, or untracked public changes"
  fi
else
  gate_skip dirty_tree_and_index hard STUDIO_BYPASS_DIRTY_TREE_GATE "repo cleanliness is enforced when --enforce-git-workflow is set"
fi

while IFS=$'\t' read -r chain_name base expected_sha branch; do
  [ -n "$chain_name" ] || continue
  [ "$base" = "__none__" ] && base=""
  [ "$expected_sha" = "__none__" ] && expected_sha=""
  [ "$branch" = "__none__" ] && branch=""
  if [ -z "$base" ] || [ "$base" = "null" ]; then
    gate_fail explicit_pr_base hard STUDIO_BYPASS_EXPLICIT_PR_BASE_GATE "chain $chain_name has no explicit PR base"
  elif git check-ref-format --branch "$base" >/dev/null 2>&1; then
    gate_pass explicit_pr_base hard STUDIO_BYPASS_EXPLICIT_PR_BASE_GATE "chain $chain_name base is $base"
  else
    gate_fail explicit_pr_base hard STUDIO_BYPASS_EXPLICIT_PR_BASE_GATE "chain $chain_name base is not a valid branch ref: $base"
  fi

  if [ -n "$expected_sha" ] && [ "$expected_sha" != "null" ]; then
    actual_sha=$(git -C "$REPO" rev-parse --verify "origin/$base" 2>/dev/null || git -C "$REPO" rev-parse --verify "$base" 2>/dev/null || true)
    if [ "$actual_sha" = "$expected_sha" ]; then
      gate_pass expected_source_branch_sha hard STUDIO_BYPASS_SOURCE_SHA_GATE "chain $chain_name source SHA matches $expected_sha"
    else
      gate_fail expected_source_branch_sha hard STUDIO_BYPASS_SOURCE_SHA_GATE "chain $chain_name expected $expected_sha for $base, got ${actual_sha:-missing}"
    fi
  else
    gate_skip expected_source_branch_sha hard STUDIO_BYPASS_SOURCE_SHA_GATE "chain $chain_name does not declare expected_source_sha/source_sha"
  fi

  lock_dir="${STUDIO_SOURCE_BRANCH_LOCK_DIR:-}"
  if [ -n "$lock_dir" ]; then
    lock_path="$lock_dir/$(sanitize_ref_for_lock "$base").lock"
    if [ -f "$lock_path" ]; then
      lock_owner=$(cat "$lock_path" 2>/dev/null || true)
      if [ -n "${RUN_ID:-}" ] && [ "$lock_owner" = "$RUN_ID" ]; then
        gate_pass source_branch_lock hard STUDIO_BYPASS_SOURCE_BRANCH_LOCK_GATE "source branch lock for $base is owned by this run"
      else
        gate_fail source_branch_lock hard STUDIO_BYPASS_SOURCE_BRANCH_LOCK_GATE "source branch $base is locked by ${lock_owner:-unknown}"
      fi
    else
      gate_pass source_branch_lock hard STUDIO_BYPASS_SOURCE_BRANCH_LOCK_GATE "source branch $base is not locked"
    fi
  else
    gate_skip source_branch_lock hard STUDIO_BYPASS_SOURCE_BRANCH_LOCK_GATE "STUDIO_SOURCE_BRANCH_LOCK_DIR not configured"
  fi

  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    if feature_branch_policy_evaluate "$REPO" "$branch" "$base" "chain branch"; then
      case "$FEATURE_BRANCH_POLICY_STATUS" in
        skipped) gate_skip no_feature_branch_merge_commits hard STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE "$FEATURE_BRANCH_POLICY_DETAIL" ;;
        *) gate_pass no_feature_branch_merge_commits hard STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE "$FEATURE_BRANCH_POLICY_DETAIL" ;;
      esac
    else
      gate_fail no_feature_branch_merge_commits hard STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE "$FEATURE_BRANCH_POLICY_DETAIL"
    fi
  else
    gate_skip no_feature_branch_merge_commits hard STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE "feature branch $branch does not exist yet"
  fi
done < <(jq -r '.chains[] | [.name, (.base // "__none__"), (.expected_source_sha // .source_sha // "__none__"), (.branch // "__none__")] | @tsv' "$PLAN")

if command -v rg >/dev/null 2>&1; then
  if rg -n 'git[[:space:]].*push([^#\n]*[[:space:]])--force([[:space:]=]|$)' "$REPO/scripts" | grep -v 'studio-chain-rule-gates.sh:' >/dev/null 2>&1; then
    gate_fail no_raw_force_push hard STUDIO_BYPASS_RAW_FORCE_PUSH_GATE "raw git push --force is present under scripts/"
  else
    gate_pass no_raw_force_push hard STUDIO_BYPASS_RAW_FORCE_PUSH_GATE "no raw git push --force found under scripts/"
  fi
  if rg -n 'git[[:space:]].*push.*--force-with-lease' "$REPO/scripts" >/dev/null 2>&1; then
    if rg -n 'git[[:space:]].*push.*--force-with-lease' "$REPO/scripts" | grep -v 'STUDIO_BYPASS_FORCE_WITH_LEASE_GATE' >/dev/null 2>&1; then
      gate_fail force_with_lease_requires_override hard STUDIO_BYPASS_FORCE_WITH_LEASE_GATE "force-with-lease appears without the documented override gate"
    else
      gate_pass force_with_lease_requires_override hard STUDIO_BYPASS_FORCE_WITH_LEASE_GATE "force-with-lease uses the documented override gate"
    fi
  else
    gate_pass force_with_lease_requires_override hard STUDIO_BYPASS_FORCE_WITH_LEASE_GATE "no force-with-lease usage found under scripts/"
  fi
else
  gate_skip no_raw_force_push hard STUDIO_BYPASS_RAW_FORCE_PUSH_GATE "rg unavailable"
  gate_skip force_with_lease_requires_override hard STUDIO_BYPASS_FORCE_WITH_LEASE_GATE "rg unavailable"
fi

if [ -n "$EXPECTED_RUN_WORK_ROOT" ]; then
  invalid_artifacts=$(jq -r '
    [ .chains[]?.chain_worktree, .chains[]?.issues[]?.issue_worktree ]
    | map(select(. != null and . != ""))
    | .[]
  ' "$PLAN" | while IFS= read -r artifact_path; do
    path_under_root "$EXPECTED_RUN_WORK_ROOT" "$artifact_path" || printf '%s\n' "$artifact_path"
  done | paste -sd, -)
  if [ -z "$invalid_artifacts" ]; then
    gate_pass artifact_root_construction hard STUDIO_BYPASS_ARTIFACT_ROOT_GATE "all chain worktree artifacts are below the run work root"
  else
    gate_fail artifact_root_construction hard STUDIO_BYPASS_ARTIFACT_ROOT_GATE "artifact paths outside run work root: $invalid_artifacts"
  fi
else
  gate_skip artifact_root_construction hard STUDIO_BYPASS_ARTIFACT_ROOT_GATE "expected run work root not supplied"
fi

cache_key="${STUDIO_DERIVED_DATA_CACHE_KEY:-}"
if [ -n "$cache_key" ]; then
  if ! printf '%s\n' "$cache_key" | grep -Eq '^[A-Za-z0-9._-]{8,128}$' || printf '%s\n' "$cache_key" | grep -q '/'; then
    gate_fail derived_data_cache_key hard STUDIO_BYPASS_DERIVED_DATA_CACHE_KEY_GATE "DerivedData cache key must be an 8..128 character safe path segment"
  elif [ "$cache_key" = "." ] || [ "$cache_key" = ".." ]; then
    gate_fail derived_data_cache_key hard STUDIO_BYPASS_DERIVED_DATA_CACHE_KEY_GATE "DerivedData cache key must not be . or .."
  else
    gate_pass derived_data_cache_key hard STUDIO_BYPASS_DERIVED_DATA_CACHE_KEY_GATE "DerivedData cache key is a safe path segment"
  fi
else
  gate_skip derived_data_cache_key hard STUDIO_BYPASS_DERIVED_DATA_CACHE_KEY_GATE "STUDIO_DERIVED_DATA_CACHE_KEY not configured"
fi

ttl_class="${STUDIO_CHAIN_CLEANUP_TTL_CLASS:-}"
if [ -n "$ttl_class" ]; then
  case "$ttl_class" in
    immediate|event|failure_48h|rotate_7d_delete_30d)
      gate_pass cleanup_ttl_class hard STUDIO_BYPASS_CLEANUP_TTL_GATE "cleanup TTL class is $ttl_class"
      ;;
    *)
      gate_fail cleanup_ttl_class hard STUDIO_BYPASS_CLEANUP_TTL_GATE "invalid cleanup TTL class: $ttl_class"
      ;;
  esac
else
  gate_skip cleanup_ttl_class hard STUDIO_BYPASS_CLEANUP_TTL_GATE "STUDIO_CHAIN_CLEANUP_TTL_CLASS not configured"
fi

if detect_secret_like_text "$PLAN"; then
  gate_fail telemetry_redaction hard STUDIO_BYPASS_TELEMETRY_REDACTION_GATE "plan contains high-confidence secret material"
else
  gate_pass telemetry_redaction hard STUDIO_BYPASS_TELEMETRY_REDACTION_GATE "plan contains no high-confidence secret material"
fi

jq -s \
  --arg manifest "$MANIFEST" \
  --arg plan "$PLAN" \
  --arg audit_log "$AUDIT_LOG" \
  --argjson dry_run "$DRY_RUN" \
  '
  {
    schema_version:1,
    kind:"studio-chain-rule-gate-result",
    status:(if any(.[]; .status == "failed") then "halt" else "ok" end),
    dry_run:$dry_run,
    manifest:(if $manifest == "" then null else $manifest end),
    plan:$plan,
    audit_log:(if $audit_log == "" then null else $audit_log end),
    checks:.,
    failures:[.[] | select(.status == "failed")],
    overrides:[.[] | select(.status == "override")]
  }' "$CHECKS_JSONL" >"$TMPROOT/result.json"

cat "$TMPROOT/result.json"
if jq -e '.status == "halt"' "$TMPROOT/result.json" >/dev/null; then
  exit 4
fi
