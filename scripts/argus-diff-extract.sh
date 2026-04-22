#!/usr/bin/env bash
# argus-diff-extract.sh — Step 2 of the Argus pipeline.
#
# Computes the diff between HEAD and origin/<base>, applies the two scope
# caps (500-line diff, 10-file max), writes the capped diff to a tmp file,
# and emits `review_scoped` for each cap that fires. Stdout is eval-able
# key=value lines — the caller sources them into its environment.
#
# Usage (TASK_ID must be set so tmp paths are task-scoped):
#   TASK_ID=T001 eval "$(scripts/argus-diff-extract.sh <worktree> <base-branch>)"
#
# Emits:
#   BASE_SHA=<sha>
#   CHANGED_FILES=<n>
#   DIFF_LINES=<n>
#   DIFF_PATH=/tmp/argus-<task-id>-diff.txt
#
# Exit codes:
#   0  OK
#   2  missing TASK_ID / args, or git failure

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

: "${TASK_ID:?TASK_ID env var required so diff tmp path is task-scoped}"

WORKTREE="${1:?usage: argus-diff-extract.sh <worktree> <base-branch>}"
BASE_BRANCH="${2:?base-branch required}"

[ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ] || {
  # A worktree's .git is a file (gitdir pointer); a main checkout's is a dir.
  # Both satisfy the check. Anything else is an error worth surfacing.
  if ! git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'error: %s is not a git worktree\n' "$WORKTREE" >&2
    exit 2
  fi
}

DIFF_CAP=500
FILE_CAP=10
DIFF_PATH="/tmp/argus-${TASK_ID}-diff.txt"

cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }

BASE_SHA=$(git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null) || {
  printf 'error: git merge-base HEAD origin/%s failed\n' "$BASE_BRANCH" >&2
  exit 2
}

# --name-only and full diff in one pass each — cheaper than piping the full
# diff through filters twice.
CHANGED_FILES=$(git diff --name-only "$BASE_SHA" HEAD 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
DIFF_LINES=$(git diff "$BASE_SHA" HEAD 2>/dev/null | wc -l | tr -d ' ')

_emit_scoped() {
  local cap="$1" value="$2" limit="$3"
  local data
  data=$(printf '{"cap":"%s","value":%s,"limit":%s}' "$cap" "$value" "$limit")
  emit_event_keyed argus review review_scoped "$TASK_ID" "$data" >/dev/null || true
}

# File-cap first — informational; the diff itself still lands, just with the
# file list truncated in the summary header. The 500-line diff cap below
# prunes the actual content.
if [ "$CHANGED_FILES" -gt "$FILE_CAP" ]; then
  _emit_scoped file_count "$CHANGED_FILES" "$FILE_CAP"
fi

if [ "$DIFF_LINES" -gt "$DIFF_CAP" ]; then
  _emit_scoped diff_size "$DIFF_LINES" "$DIFF_CAP"
  # Sort changed files by per-file diff line count desc, then walk the sorted
  # list emitting each file's full diff until the 500-line budget is spent.
  # Budget measured on output lines (includes headers + context), matching
  # how DIFF_LINES is computed — keeps the numbers comparable downstream.
  : > "$DIFF_PATH"
  written=0
  git diff --numstat "$BASE_SHA" HEAD 2>/dev/null \
    | awk '{print $1+$2, $3}' \
    | sort -rn \
    | awk '{print $2}' \
    | while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ "$written" -ge "$DIFF_CAP" ] && break
        remaining=$(( DIFF_CAP - written ))
        file_diff=$(git diff "$BASE_SHA" HEAD -- "$f" 2>/dev/null | head -n "$remaining")
        printf '%s\n' "$file_diff" >> "$DIFF_PATH"
        added=$(printf '%s\n' "$file_diff" | wc -l | tr -d ' ')
        written=$(( written + added ))
      done
  printf '\n--- truncated at %s lines; %s total in full diff ---\n' "$DIFF_CAP" "$DIFF_LINES" >> "$DIFF_PATH"
else
  git diff "$BASE_SHA" HEAD > "$DIFF_PATH" 2>/dev/null || {
    printf 'error: git diff failed\n' >&2
    exit 2
  }
fi

printf 'BASE_SHA=%s\n' "$BASE_SHA"
printf 'CHANGED_FILES=%s\n' "$CHANGED_FILES"
printf 'DIFF_LINES=%s\n' "$DIFF_LINES"
printf 'DIFF_PATH=%s\n' "$DIFF_PATH"
