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

if [ "$HAS_FINDINGS" = "yes" ]; then
  FINDINGS_BLOCK=$(printf '%s' "$FIELDS_JSON" | jq -r '
    .findings | map(
      "  - skill: \(.skill)\n    severity: \(.severity)\n    text: \(.text | @json)\n    fixed: \(.fixed)"
    ) | join("\n")
  ')
fi

{
  printf 'schema_version:\n  name: self-review\n  version: 1.0.0\n  min_reader: 1.0.0\n'
  printf 'task_id: %s\n' "$TASK_ID"
  printf 'completed_at: %s\n' "$NOW"
  printf 'iteration: %s\n' "$ITERATION"
  printf 'converged: %s\n' "$CONVERGED"
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
