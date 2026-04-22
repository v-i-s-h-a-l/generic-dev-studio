#!/usr/bin/env bash
# task-claim.sh — Step 2 of the Achilles task mode.
#
# Flips the paired task + brief artifacts to the in-flight states and emits
# `brief_started`. lib-ledger's transition helpers handle the dual-write to
# legacy master-plan (task side) so the mode-pack no longer carries that
# prose. Brief state has no legacy counterpart today (Phase 2.6 defers brief
# Status rows), so the brief transition is YAML-only.
#
# Usage:
#   scripts/task-claim.sh <task-uuid> <brief-uuid> <size> <gate-mode>
#
# Exit codes:
#   0  both transitions applied + event emitted
#   2  missing args / artifact not found
#   3  dual-write partial (propagated from lib-ledger)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_UUID="${1:?usage: task-claim.sh <task-uuid> <brief-uuid> <size> <gate>}"
BRIEF_UUID="${2:?brief-uuid required (empty string OK for direct mode)}"
SIZE="${3:?size required}"
GATE="${4:?gate required (lsp-only|full-green)}"

# Task flip first — the task's legacy dual-write (master-plan Status) lives
# here, so a crash between the two transitions leaves the post-migration
# shape biased consistent (dual-write-transition.md rule 2).
transition_task_state "$TASK_UUID" in-progress achilles "Step 2 claim" || {
  rc=$?
  [ "$rc" -eq 3 ] && exit 3
  printf 'error: transition_task_state failed rc=%s\n' "$rc" >&2
  exit 2
}

# Brief transition only when a brief exists — direct mode passes empty.
if [ -n "$BRIEF_UUID" ]; then
  transition_brief_state "$BRIEF_UUID" dispatched achilles "task-started" || {
    rc=$?
    [ "$rc" -eq 3 ] && exit 3
    printf 'error: transition_brief_state failed rc=%s\n' "$rc" >&2
    exit 2
  }
fi

# brief_started carries the Step 2 handoff signal for analysis. Keyed by
# task-uuid so the `task` field joins cleanly to downstream events.
data=$(printf '{"size":"%s","gate_selected":"%s"}' "$SIZE" "$GATE")
emit_event_keyed achilles task brief_started "$TASK_UUID" "$data" >/dev/null
