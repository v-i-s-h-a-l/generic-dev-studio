#!/usr/bin/env bash
# task-write-test-cases.sh — Step 7 of the Achilles task mode.
#
# Twin-writes the test cases: a human-readable checklist at
# `plans/chanakya-inbox/<task-id>-tests.md` (Chanakya reads this for
# `/chanakya test-manifest`) and a YAML block on stdout that the caller
# splices into the debrief's `tests.added:` field.
#
# Input cases-json shape (array of objects):
#   [{"title":"…","preconditions":"…","steps":["…"],"expected":"…"}, …]
#
# Usage:
#   scripts/task-write-test-cases.sh <task-id> '<cases-json>'
#
# Exit codes:
#   0  written + YAML block printed
#   2  missing args or invalid JSON

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TASK_ID="${1:?usage: task-write-test-cases.sh <task-id> <cases-json>}"
CASES_JSON="${2:?cases-json required}"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required for cases-json parsing\n' >&2; exit 2; }

# Validate JSON up front — downstream paths assume well-formed input.
printf '%s' "$CASES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  printf 'error: cases-json must be a JSON array\n' >&2
  exit 2
}

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
INBOX="$(resolve_plans_dir_for "$PROJECT")/chanakya-inbox"
OUT="$INBOX/${TASK_ID}-tests.md"

count=$(printf '%s' "$CASES_JSON" | jq 'length' 2>/dev/null || echo 0)

# Render the markdown checklist. Matches the prose-era format the mode pack
# documented — each case has a `- [ ]` heading line plus indented Pre / Steps /
# Expected sub-bullets so test-manifest's parser can stay as-is.
render_md() {
  printf '# Test Cases: %s\n\n' "$TASK_ID"
  if [ "$count" -eq 0 ]; then
    printf '(none)\n'
    return
  fi
  printf '%s' "$CASES_JSON" | jq -r '
    to_entries[] |
    "- [ ] \(.value.title)\n" +
    "  - **Preconditions:** \(.value.preconditions // "—")\n" +
    "  - **Steps:**\n" +
    (if (.value.steps // []) | length == 0 then "    1. —\n"
     else (.value.steps | to_entries | map("    \(.key+1). \(.value)") | join("\n")) + "\n"
     end) +
    "  - **Expected:** \(.value.expected // "—")"
  '
}

# Atomic write — tmp + mv. Readers (Chanakya test-manifest) pick up either the
# old or the new file, never a half-written one.
if [ "${DRY_RUN:-0}" = "1" ]; then
  bytes=$(render_md | wc -c | tr -d ' ')
  printf 'DRY-RUN write path=%s bytes=%s idempotency_key=achilles:tests:%s\n' \
    "$OUT" "$bytes" "$TASK_ID" >&2
else
  mkdir -p "$INBOX" || { printf 'error: mkdir %s failed\n' "$INBOX" >&2; exit 2; }
  tmp="$OUT.tmp.$$"
  render_md > "$tmp" || { rm -f "$tmp"; exit 2; }
  mv "$tmp" "$OUT" || { rm -f "$tmp"; exit 2; }
fi

# Stdout: the YAML block the caller splices into the debrief. Keeps cases
# as structured objects so the schema contract (tests.added: array) holds.
# jq emits compact JSON; yq would be nicer but adds a tool requirement.
if [ "$count" -eq 0 ]; then
  printf '[]\n'
else
  printf '%s' "$CASES_JSON" | jq -c '[ .[].title ]'
fi
