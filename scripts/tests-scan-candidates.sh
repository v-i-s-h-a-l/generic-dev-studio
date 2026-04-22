#!/usr/bin/env bash
# tests-scan-candidates.sh — Step 2 of the test-manifest / test-flow pipeline.
#
# Enumerates tasks awaiting manual verification. Post-migration: queries
# plans/index.yaml for tasks in {merged, user-verifying}. Legacy fallback:
# scans chanakya-master.md for `Status: done` rows (explicitly excludes
# `verified` / `archived`).
#
# Usage:
#   scripts/tests-scan-candidates.sh
#
# One candidate id per stdout line. Exit 0 even when empty — empty candidate
# sets are a normal state (nothing to test). Emits `legacy_artifact_read`
# once on the fallback path so the transition stays observable.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
INDEX="$PROJECT_ROOT/plans/index.yaml"

# Prefer post-migration surface. query-plans.sh already handles the yq-absent
# fallback internally; we call it twice (merged + user-verifying) and dedupe.
emit_from_index() {
  command -v yq >/dev/null 2>&1 || return 1
  [ -f "$INDEX" ] || return 1
  local merged verifying
  merged=$("$SCRIPT_DIR/query-plans.sh" --kind=tasks --state=merged --format=json 2>/dev/null || true)
  verifying=$("$SCRIPT_DIR/query-plans.sh" --kind=tasks --state=user-verifying --format=json 2>/dev/null || true)
  local combined="$merged"$'\n'"$verifying"
  # Prefer legacy_task_id (human-readable) when present; fall back to UUID.
  printf '%s' "$combined" | jq -r 'select(.) | .legacy_task_id // .id // empty' 2>/dev/null \
    | awk 'NF && !seen[$0]++'
}

emitted=$(emit_from_index 2>/dev/null || true)
if [ -n "$emitted" ]; then
  printf '%s\n' "$emitted"
  exit 0
fi

# Legacy fallback — parse chanakya-master.md for `Status: done` rows.
MASTER="$PROJECT_ROOT/plans/chanakya-master.md"
if [ ! -f "$MASTER" ]; then
  exit 0
fi

append_event chanakya legacy_artifact_read "" \
  '{"domain":"candidates","reason":"plans_index_missing","caller":"tests-scan-candidates"}' \
  2>/dev/null || true

# Walk `## Tasks` block; for each `### Txxx — title`, check the Status bullet
# inside that section. Emit the legacy id when status is exactly `done`.
awk '
  BEGIN { in_tasks=0; in_section=0; cur_id="" }
  /^## Tasks[[:space:]]*$/ { in_tasks=1; next }
  in_tasks && /^## / { in_tasks=0; in_section=0; next }
  in_tasks && /^### / {
    cur_id=$2
    in_section=1
    next
  }
  in_tasks && in_section && /^- \*\*Status:\*\*/ {
    t=$0
    sub(/^.*Status:\*\*[[:space:]]*/, "", t)
    sub(/[[:space:]].*$/, "", t)
    if (t == "done" && cur_id != "") print cur_id
    in_section=0
  }
' "$MASTER"

exit 0
