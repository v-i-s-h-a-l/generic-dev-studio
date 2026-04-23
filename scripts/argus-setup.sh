#!/usr/bin/env bash
# argus-setup.sh — Step 1 of the Argus pipeline.
#
# Creates the legacy reviews dir (pre-2.6 carve-out under project-memory, not
# under ~/.dev-studio/; migrated at Commit H), writes the running marker with
# PID + ISO timestamp, and emits `review_requested`. Prints a trap-registration
# line on stdout the caller must `eval` so the marker always gets cleaned up
# (Behavior Rule 5).
#
# Usage:
#   eval "$(scripts/argus-setup.sh <task-id> <size> <worktree> [stage])"
#
# Stage: spec | quality (default: quality for back-compat with pre-2-stage
# callers). Tags the `review_requested` event with the current stage.
#
# Exit codes:
#   0  setup OK
#   2  missing args or project resolution failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: argus-setup.sh <task-id> <size> <worktree> [stage]}"
SIZE="${2:?size required (XS|S|M|L)}"
WORKTREE="${3:?worktree required}"
STAGE="${4:-quality}"
case "$STAGE" in
  spec|quality) ;;
  *) printf 'error: invalid stage %s (want spec|quality)\n' "$STAGE" >&2; exit 2 ;;
esac

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

# Resolve project to confirm the session can locate the event log. The
# reviews dir itself is under project-memory (outside ~/.dev-studio/) until
# the legacy carve-out is retired at Commit H.
PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }

PROJECT_MEMORY=$(resolve_project_memory 2>/dev/null) || {
  printf 'error: no project memory resolved (need a git repo)\n' >&2
  exit 2
}
REVIEWS_DIR="$PROJECT_MEMORY/reviews"
mkdir -p "$REVIEWS_DIR" "$REVIEWS_DIR/archive" || { printf 'error: mkdir %s failed\n' "$REVIEWS_DIR" >&2; exit 2; }

MARKER="$WORKTREE/.argus-running"
printf '%s:%s\n' "$$" "$(iso_ts_now)" > "$MARKER" || { printf 'error: cannot write marker %s\n' "$MARKER" >&2; exit 2; }

data=$(printf '{"size":"%s","worktree":"%s","stage":"%s"}' "$SIZE" "$WORKTREE" "$STAGE")
emit_event_keyed argus review review_requested "$TASK_ID" "$data" >/dev/null || {
  # Event-emit failure is not a setup-blocker — the review can still run and
  # the next emit (verdict) will surface on the log. But we log for observability.
  printf 'warn: review_requested emit failed\n' >&2
}

# Stdout contract: eval-able trap line + exported vars for the caller. The
# caller composes this with its own traps; bash's `trap` replaces rather than
# chains, so the caller's subsequent traps must re-register this one if they
# add their own handlers (Behavior Rule 5).
printf 'trap '\''rm -f "%s"'\'' EXIT INT TERM\n' "$MARKER"
printf 'ARGUS_MARKER=%s\n' "$MARKER"
printf 'ARGUS_REVIEWS_DIR=%s\n' "$REVIEWS_DIR"
