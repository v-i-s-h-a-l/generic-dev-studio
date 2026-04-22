#!/usr/bin/env bash
# tests-pull-cases.sh — Step 3 extraction for one candidate task.
#
# Resolves test cases for a task from (in priority order):
#   1. Post-migration: the task's linked debrief YAML (tests.added + tests.modified
#      arrays).
#   2. Legacy: plans/chanakya-inbox/<task>-tests.md (standalone test artifact).
#   3. Legacy: `## Test Cases` block inside the processed debrief at
#      plans/chanakya-inbox/processed/<task>-debrief.md.
#
# Usage:
#   scripts/tests-pull-cases.sh <task-id>
#
# Stdout: YAML block listing cases (each with title, preconditions, steps,
# expected). Empty stdout when no cases are found (exit 0) — callers render a
# placeholder. Emits `legacy_artifact_read` once on fallback.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  printf 'usage: tests-pull-cases.sh <task-id>\n' >&2
  exit 2
fi

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
TASKS_DIR="$PROJECT_ROOT/plans/tasks"
DEBRIEFS_DIR="$PROJECT_ROOT/plans/debriefs"
INBOX="$PROJECT_ROOT/plans/chanakya-inbox"

LEGACY_EMITTED=0
emit_legacy_once() {
  [ "$LEGACY_EMITTED" = "1" ] && return 0
  LEGACY_EMITTED=1
  append_event chanakya legacy_artifact_read "" \
    "{\"domain\":\"tests\",\"reason\":\"yaml_tests_absent\",\"caller\":\"tests-pull-cases\",\"task\":\"$TASK_ID\"}" \
    2>/dev/null || true
}

# Resolve a task's YAML path. Accepts either a UUID (direct filename) or a
# legacy id (scan legacy_task_id field).
resolve_task_yaml() {
  local id="$1"
  local direct="$TASKS_DIR/$id.yaml"
  if [ -f "$direct" ]; then
    printf '%s\n' "$direct"
    return 0
  fi
  [ -d "$TASKS_DIR" ] || return 1
  grep -lE "^legacy_task_id: *\"?${id}\"?$" "$TASKS_DIR"/*.yaml 2>/dev/null | head -1
}

# YAML path — emit cases from the task's linked debrief.
emit_from_yaml() {
  command -v yq >/dev/null 2>&1 || return 1
  local task_yaml debrief_uuid debrief_yaml
  task_yaml=$(resolve_task_yaml "$TASK_ID") || return 1
  [ -n "$task_yaml" ] && [ -f "$task_yaml" ] || return 1
  debrief_uuid=$(yq -r '.links.debrief // ""' "$task_yaml" 2>/dev/null || echo "")
  [ -n "$debrief_uuid" ] && [ "$debrief_uuid" != "null" ] || return 1
  debrief_yaml="$DEBRIEFS_DIR/$debrief_uuid.yaml"
  [ -f "$debrief_yaml" ] || return 1

  # Count cases across added + modified. No cases → caller falls through.
  local added_n modified_n total
  added_n=$(yq -r '.tests.added // [] | length' "$debrief_yaml" 2>/dev/null || echo 0)
  modified_n=$(yq -r '.tests.modified // [] | length' "$debrief_yaml" 2>/dev/null || echo 0)
  total=$(( ${added_n:-0} + ${modified_n:-0} ))
  [ "$total" -gt 0 ] || return 1

  {
    printf 'cases:\n'
    # Each case entry may be a scalar (string title) or a map. yq's `tag`
    # distinguishes; we handle both.
    yq -r '
      (.tests.added // []) + (.tests.modified // []) |
      .[] |
      if (. | type) == "!!str" then
        "  - title: " + . + "\n    preconditions: \"\"\n    steps: \"\"\n    expected: \"\""
      else
        "  - title: " + (.title // .name // "untitled") + "\n" +
        "    preconditions: " + (.preconditions // "" | tojson) + "\n" +
        "    steps: " + (.steps // "" | tojson) + "\n" +
        "    expected: " + (.expected // "" | tojson)
      end
    ' "$debrief_yaml" 2>/dev/null
  }
  return 0
}

# Legacy path 1 — standalone <task>-tests.md. Converts the markdown
# bullets into a YAML cases block.
emit_from_tests_md() {
  local f="$INBOX/$TASK_ID-tests.md"
  [ -f "$f" ] || return 1
  emit_legacy_once
  # Grab bullet lines under any `## Test Cases` or `## Cases` heading; if no
  # such heading exists, fall back to top-level `- ` bullets.
  local body
  body=$(awk '
    BEGIN { in_block=0; found=0 }
    /^##[[:space:]]*(Test )?Cases[[:space:]]*$/ { in_block=1; found=1; next }
    in_block && /^## / { in_block=0 }
    in_block && /^-[[:space:]]/ { print; next }
    !found && /^-[[:space:]]/ { print }
  ' "$f" 2>/dev/null)
  [ -n "$body" ] || return 1
  printf 'cases:\n'
  printf '%s\n' "$body" | awk '
    {
      line=$0
      sub(/^-[[:space:]]*/, "", line)
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      printf "  - title: \"%s\"\n    preconditions: \"\"\n    steps: \"\"\n    expected: \"\"\n", line
    }
  '
}

# Legacy path 2 — `## Test Cases` block inside processed debrief.
emit_from_processed_debrief() {
  local f="$INBOX/processed/$TASK_ID-debrief.md"
  [ -f "$f" ] || return 1
  emit_legacy_once
  local body
  body=$(awk '
    BEGIN { in_block=0 }
    /^##[[:space:]]*Test Cases[[:space:]]*$/ { in_block=1; next }
    in_block && /^## / { in_block=0 }
    in_block && /^-[[:space:]]/ { print }
  ' "$f" 2>/dev/null)
  [ -n "$body" ] || return 1
  printf 'cases:\n'
  printf '%s\n' "$body" | awk '
    {
      line=$0
      sub(/^-[[:space:]]*/, "", line)
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      printf "  - title: \"%s\"\n    preconditions: \"\"\n    steps: \"\"\n    expected: \"\"\n", line
    }
  '
}

if emit_from_yaml; then
  exit 0
fi
if emit_from_tests_md; then
  exit 0
fi
if emit_from_processed_debrief; then
  exit 0
fi

# No cases anywhere — empty output, exit 0. Caller renders placeholder.
exit 0
