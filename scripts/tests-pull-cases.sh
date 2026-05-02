#!/usr/bin/env bash
# tests-pull-cases.sh — Step 3 extraction for one candidate task.
#
# Resolves test cases for a task from canonical debrief YAML only:
#   task.links.debrief -> plans/debriefs/<id>.yaml -> tests.added + tests.modified.
#
# Legacy markdown test files are import/projection artifacts only. They are not
# a hidden authority for current test manifests.
#
# Usage:
#   scripts/tests-pull-cases.sh <task-id>
#
# Stdout: YAML block listing cases (each with title, preconditions, steps,
# expected). Empty stdout when no cases are found (exit 0) — callers render a
# placeholder.

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
  command -v jq >/dev/null 2>&1 || return 1
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
    yq -o=json -I=0 '(.tests.added // []) + (.tests.modified // [])' "$debrief_yaml" 2>/dev/null \
      | jq -r '
          .[] |
          if type == "string" then
            ["  - title: " + ., "    preconditions: \"\"", "    steps: \"\"", "    expected: \"\""] | join("\n")
          else
            ["  - title: " + (.title // .name // "untitled"),
             "    preconditions: " + ((.preconditions // "") | @json),
             "    steps: " + ((.steps // "") | @json),
             "    expected: " + ((.expected // "") | @json)] | join("\n")
          end
        ' 2>/dev/null
  }
  return 0
}

if emit_from_yaml; then
  exit 0
fi

# No canonical YAML cases — empty output, exit 0. Caller renders placeholder.
exit 0
