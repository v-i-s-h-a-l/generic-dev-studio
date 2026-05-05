#!/usr/bin/env bash
# task-write-self-review.sh — Step 5 artifact writer (#222 A2-4).
#
# Writes plans/self-reviews/<task-id>.yaml capturing per-skill verdicts,
# diff stats, iteration count, and findings. Argus Stage 2 reads this to
# cross-check without re-deriving from debrief prose.
#
# Usage:
#   scripts/task-write-self-review.sh <task-id> '<fields-json>'
#
# fields-json shape:
#   {
#     "iteration": 1,
#     "converged": true,
#     "self_review_performed": true,
#     "self_review_findings": [{"id": "SR1", "focus": "edge_case",
#       "finding": "...", "severity": "material", "disposition": "fixed"}],
#     "self_review_fixes": [{"finding_id": "SR1", "action": "fixed",
#       "summary": "..."}],
#     "skill_verdicts": {"simplify": "clean", "swiftui-pro": "minor"},
#     "diff_stats": {"files": 4, "added_lines": 187, "removed_lines": 12,
#                    "public_api_changed": false},
#     "findings": [{"skill": "swiftui-pro", "severity": "minor",
#                   "text": "...", "fixed": true}],
#     "coverage_delta_checked": true,
#     "coverage_delta_found": true
#   }
#
# Prints the artifact path on stdout on success.
# Exit 0: written. Exit 2: missing args or invalid JSON.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TASK_ID="${1:?usage: task-write-self-review.sh <task-id> <fields-json>}"
FIELDS_JSON="${2:?fields-json required}"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

printf '%s' "$FIELDS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || {
  printf 'error: fields-json must be a JSON object\n' >&2
  exit 2
}

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
SELF_REVIEWS_DIR="$(resolve_plans_dir_for "$PROJECT")/self-reviews"
mkdir -p "$SELF_REVIEWS_DIR"
OUT="$SELF_REVIEWS_DIR/${TASK_ID}.yaml"

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
ITERATION=$(printf '%s' "$FIELDS_JSON" | jq -r '.iteration // 1')
# Use explicit null-check for booleans — jq's // treats false as falsy.
CONVERGED=$(printf '%s' "$FIELDS_JSON" | jq -r 'if .converged == null then "true" else (.converged | tostring) end')
SELF_REVIEW_PERFORMED=$(printf '%s' "$FIELDS_JSON" | jq -r 'if .self_review_performed == null then "true" else (.self_review_performed | tostring) end')
FILES=$(printf '%s' "$FIELDS_JSON" | jq -r '.diff_stats.files // 0')
ADDED=$(printf '%s' "$FIELDS_JSON" | jq -r '.diff_stats.added_lines // 0')
REMOVED=$(printf '%s' "$FIELDS_JSON" | jq -r '.diff_stats.removed_lines // 0')
PUBLIC_API=$(printf '%s' "$FIELDS_JSON" | jq -r 'if .diff_stats.public_api_changed == null then "false" else (.diff_stats.public_api_changed | tostring) end')
COV_CHECKED=$(printf '%s' "$FIELDS_JSON" | jq -r 'if .coverage_delta_checked == null then "true" else (.coverage_delta_checked | tostring) end')
COV_FOUND=$(printf '%s' "$FIELDS_JSON" | jq -r 'if .coverage_delta_found == null then "false" else (.coverage_delta_found | tostring) end')

# Render skill_verdicts block (each key: value on its own line).
SKILL_BLOCK=$(printf '%s' "$FIELDS_JSON" | jq -r '
  (.skill_verdicts // {}) | to_entries |
  if length == 0 then "  {}"
  else map("  \(.key): \(.value)") | join("\n")
  end
')

# Render findings block.
HAS_FINDINGS=$(printf '%s' "$FIELDS_JSON" | jq -e '(.findings // []) | length > 0' >/dev/null 2>&1 && printf 'yes' || printf 'no')
HAS_SELF_REVIEW_FINDINGS=$(printf '%s' "$FIELDS_JSON" | jq -e '(.self_review_findings // []) | length > 0' >/dev/null 2>&1 && printf 'yes' || printf 'no')
HAS_SELF_REVIEW_FIXES=$(printf '%s' "$FIELDS_JSON" | jq -e '(.self_review_fixes // []) | length > 0' >/dev/null 2>&1 && printf 'yes' || printf 'no')

if [ "$HAS_FINDINGS" = "yes" ]; then
  FINDINGS_BLOCK=$(printf '%s' "$FIELDS_JSON" | jq -r '
    .findings | map(
      "  - skill: \(.skill)\n    severity: \(.severity)\n    text: \(.text | @json)\n    fixed: \(.fixed)"
    ) | join("\n")
  ')
fi

if [ "$HAS_SELF_REVIEW_FINDINGS" = "yes" ]; then
  SELF_REVIEW_FINDINGS_BLOCK=$(printf '%s' "$FIELDS_JSON" | jq -r '
    .self_review_findings | map(
      "  - id: \(.id)\n    focus: \(.focus)\n    finding: \(.finding | @json)\n    severity: \(.severity)\n    disposition: \(.disposition)"
      + (if .evidence_ref then "\n    evidence_ref: \(.evidence_ref | @json)" else "" end)
    ) | join("\n")
  ')
fi

if [ "$HAS_SELF_REVIEW_FIXES" = "yes" ]; then
  SELF_REVIEW_FIXES_BLOCK=$(printf '%s' "$FIELDS_JSON" | jq -r '
    .self_review_fixes | map(
      "  - finding_id: \(.finding_id)\n    action: \(.action)\n    summary: \(.summary | @json)"
      + (if .commit then "\n    commit: \(.commit | @json)" else "" end)
      + (if .follow_up_ref then "\n    follow_up_ref: \(.follow_up_ref | @json)" else "" end)
    ) | join("\n")
  ')
fi

{
  printf 'schema_version:\n  name: self-review\n  version: 1.2.0\n  min_reader: 1.0.0\n'
  printf 'task_id: %s\n' "$TASK_ID"
  printf 'completed_at: %s\n' "$NOW"
  printf 'iteration: %s\n' "$ITERATION"
  printf 'converged: %s\n' "$CONVERGED"
  printf 'self_review_performed: %s\n' "$SELF_REVIEW_PERFORMED"
  if [ "$HAS_SELF_REVIEW_FINDINGS" = "yes" ]; then
    printf 'self_review_findings:\n%s\n' "$SELF_REVIEW_FINDINGS_BLOCK"
  else
    printf 'self_review_findings: []\n'
  fi
  if [ "$HAS_SELF_REVIEW_FIXES" = "yes" ]; then
    printf 'self_review_fixes:\n%s\n' "$SELF_REVIEW_FIXES_BLOCK"
  else
    printf 'self_review_fixes: []\n'
  fi
  printf 'skill_verdicts:\n%s\n' "$SKILL_BLOCK"
  printf 'diff_stats:\n  files: %s\n  added_lines: %s\n  removed_lines: %s\n  public_api_changed: %s\n' \
    "$FILES" "$ADDED" "$REMOVED" "$PUBLIC_API"
  if [ "$HAS_FINDINGS" = "yes" ]; then
    printf 'findings:\n%s\n' "$FINDINGS_BLOCK"
  else
    printf 'findings: []\n'
  fi
  printf 'coverage_delta_checked: %s\n' "$COV_CHECKED"
  printf 'coverage_delta_found: %s\n' "$COV_FOUND"
} > "$OUT"

printf '%s\n' "$OUT"
