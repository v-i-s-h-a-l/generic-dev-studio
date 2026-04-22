#!/usr/bin/env bash
# argus-verify-tdd.sh — Step 5 of the Argus pipeline (TDD tasks only).
#
# Verifies the red→green cycle was honored: tests must be red at the commit
# before implementation started, and green at HEAD. Delegates both test runs
# to `argus-run-tests.sh` so event emission and slot management stay in one
# place.
#
# Usage:
#   scripts/argus-verify-tdd.sh <task-id> <worktree> <base-branch> <scheme> <test-target>
#
# Exit codes:
#   0  cycle honored (tests red at start, green at HEAD)
#   2  cycle violated (tests already green before implementation)
#   3  tests red at HEAD

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

TASK_ID="${1:?usage: argus-verify-tdd.sh <task-id> <worktree> <base-branch> <scheme> <test-target>}"
WORKTREE="${2:?worktree required}"
BASE_BRANCH="${3:?base-branch required}"
SCHEME="${4:?scheme required}"
TEST_TARGET="${5:?test-target required}"

RUN_TESTS="$SCRIPT_DIR/argus-run-tests.sh"
[ -x "$RUN_TESTS" ] || { printf 'error: %s not executable\n' "$RUN_TESTS" >&2; exit 2; }

# Current HEAD is captured before any checkout so the trap can restore it
# even if argus-run-tests.sh aborts mid-run.
ORIGINAL_HEAD=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null) || {
  printf 'error: cannot resolve HEAD in %s\n' "$WORKTREE" >&2
  exit 2
}

# Starting commit = the first commit on the task branch minus one parent —
# the state immediately before any implementation commit landed. `tail -1`
# picks the bottom of the `origin/base..HEAD` log (oldest-first when reversed
# with awk chain below). awk-then-rev-parse matches the argus SKILL.md §5 recipe.
FIRST_COMMIT=$(git -C "$WORKTREE" log --oneline "origin/$BASE_BRANCH"..HEAD 2>/dev/null | tail -1 | awk '{print $1}')
if [ -z "$FIRST_COMMIT" ]; then
  printf 'error: no commits between origin/%s and HEAD in %s\n' "$BASE_BRANCH" "$WORKTREE" >&2
  exit 2
fi
START_SHA=$(git -C "$WORKTREE" rev-parse "${FIRST_COMMIT}^" 2>/dev/null) || {
  printf 'error: cannot resolve parent of %s\n' "$FIRST_COMMIT" >&2
  exit 2
}

# Restore original HEAD on any exit path. Registered before the first checkout.
trap 'git -C "$WORKTREE" checkout -q "$ORIGINAL_HEAD" 2>/dev/null || true' EXIT INT TERM

git -C "$WORKTREE" checkout -q "$START_SHA" 2>/dev/null || {
  printf 'error: checkout start-commit %s failed\n' "$START_SHA" >&2
  exit 2
}

# Start-commit run: success (rc=0) here means tests were ALREADY green before
# implementation — TDD cycle violated. Non-zero (rc=3 typical) is the expected
# red signal.
"$RUN_TESTS" "$TASK_ID" "$SCHEME" "$TEST_TARGET"
START_RC=$?

git -C "$WORKTREE" checkout -q "$ORIGINAL_HEAD" 2>/dev/null || {
  printf 'error: checkout back to original HEAD %s failed\n' "$ORIGINAL_HEAD" >&2
  exit 2
}

if [ "$START_RC" -eq 0 ]; then
  # Green at start → cycle violated. Still run HEAD to surface any HEAD
  # regression (informational) — but the verdict is locked at 2.
  "$RUN_TESTS" "$TASK_ID" "$SCHEME" "$TEST_TARGET" >/dev/null 2>&1 || true
  exit 2
fi

"$RUN_TESTS" "$TASK_ID" "$SCHEME" "$TEST_TARGET"
HEAD_RC=$?

if [ "$HEAD_RC" -ne 0 ]; then
  exit 3
fi
exit 0
