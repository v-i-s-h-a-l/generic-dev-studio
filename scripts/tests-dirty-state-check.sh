#!/usr/bin/env bash
# tests-dirty-state-check.sh — Step 1 dirty-state guard for test-manifest +
# promote flows. Refuses to clobber a user-testing.md (or any surface using
# the same case/notes shape) that already carries feedback.
#
# Usage:
#   scripts/tests-dirty-state-check.sh <path>
#
# Exit codes:
#   0  clean (no checked boxes, no Notes with content)
#   2  dirty — counts printed to stderr so the caller can surface them

set -u
umask 022

PATH_ARG="${1:-}"
if [ -z "$PATH_ARG" ]; then
  printf 'usage: tests-dirty-state-check.sh <path-to-user-testing.md>\n' >&2
  exit 2
fi

# Missing file is vacuously clean — caller hasn't written yet.
if [ ! -f "$PATH_ARG" ]; then
  exit 0
fi

# Count `- [x]` (case-insensitive) and `Notes:` lines whose body has non-whitespace.
# The Notes heuristic mirrors the mode pack's: `Notes:` with empty trailing
# content is the template scaffold, not user input.
# `grep -c` exits 1 on zero matches — swallow the exit and treat that as 0.
# Two command substitutions (prefer awk for both to keep the count well-formed
# without relying on `|| echo` producing a second number).
checks=$(awk '/^[[:space:]]*-[[:space:]]*\[[xX]\]/ { n++ } END { print n + 0 }' "$PATH_ARG" 2>/dev/null)
notes=$(awk '
  /^[[:space:]]*Notes:/ {
    rest=$0
    sub(/^[[:space:]]*Notes:[[:space:]]*/, "", rest)
    if (rest ~ /[^[:space:]]/) n++
  }
  END { print n + 0 }
' "$PATH_ARG" 2>/dev/null)
checks=${checks:-0}
notes=${notes:-0}

if [ "$checks" -gt 0 ] || [ "$notes" -gt 0 ]; then
  printf 'dirty: %s checked boxes, %s notes with content\n' "$checks" "$notes" >&2
  exit 2
fi

exit 0
