#!/usr/bin/env bash
# task-write-test-cases.sh — Step 7 of the Achilles task mode.
#
# Emits the canonical debrief `tests.added` payload on stdout. Human-facing
# checklists are derived later by Chanakya from the debrief YAML.
#
# Input cases-json shape (array of objects):
#   [{"title":"…","preconditions":"…","steps":["…"],"expected":"…"}, …]
#
# Usage:
#   scripts/task-write-test-cases.sh <task-id> '<cases-json>'
#
# Exit codes:
#   0  YAML-compatible JSON array printed
#   2  missing args or invalid JSON

set -u
umask 022

: "${1:?usage: task-write-test-cases.sh <task-id> <cases-json>}"
CASES_JSON="${2:?cases-json required}"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required for cases-json parsing\n' >&2; exit 2; }

# Validate JSON up front — downstream paths assume well-formed input.
printf '%s' "$CASES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  printf 'error: cases-json must be a JSON array\n' >&2
  exit 2
}

# Stdout: compact JSON is valid inline YAML and preserves the full case
# details in the debrief instead of relying on a sidecar markdown file.
printf '%s' "$CASES_JSON" | jq -c '
  [
    .[] |
    if type == "string" then
      {
        title: .,
        preconditions: "",
        steps: [],
        expected: ""
      }
    else
      {
        title: (.title // .name // "untitled"),
        preconditions: (.preconditions // ""),
        steps: (
          if (.steps // []) | type == "array" then (.steps // [])
          elif (.steps // "") == "" then []
          else [ .steps ]
          end
        ),
        expected: (.expected // "")
      }
    end
  ]
'
