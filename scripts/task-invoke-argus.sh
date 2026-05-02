#!/usr/bin/env bash
# task-invoke-argus.sh — Step 8.5 of the Achilles task mode.
#
# Emits the `review_requested` event that marks the pre-Argus handoff and
# prints `ACHILLES_REVIEW_REQUESTED_AT=<iso-ts>` so the debrief and
# `dispatch-review.sh` timeout path can correlate verdict timing. The actual
# Argus invocation happens in the mode-pack prose via Claude's Agent tool (not
# reachable from a shell), and the verdict-event emit (`review_approved` /
# `review_flagged` / `review_blocked`) happens inside
# `scripts/argus-emit-verdict.sh`, which Argus calls directly.
#
# Usage:
#   scripts/task-invoke-argus.sh <task-id> <worktree> <base-branch> <size>
#
# Stdout (eval-able):
#   ACHILLES_REVIEW_REQUESTED_AT=<iso-ts>
#
# Exit codes:
#   0  event emitted
#   2  missing args

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: task-invoke-argus.sh <task-id> <worktree> <base-branch> <size>}"
WORKTREE="${2:?worktree required}"
BASE_BRANCH="${3:?base-branch required}"
SIZE="${4:?size required}"

ts=$(iso_ts_now)
# Carry enough detail for downstream correlation — Argus will emit its own
# `review_requested` with the same key shape, letting analysis join the
# Achilles-side and Argus-side events through the shared task id.
data=$(printf '{"worktree":"%s","base_branch":"%s","size":"%s"}' \
  "$WORKTREE" "$BASE_BRANCH" "$SIZE")
emit_event_keyed achilles task review_requested "$TASK_ID" "$data" >/dev/null

printf 'ACHILLES_REVIEW_REQUESTED_AT=%s\n' "$ts"
