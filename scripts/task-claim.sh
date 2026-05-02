#!/usr/bin/env bash
# task-claim.sh — Step 2 of the Achilles task mode.
#
# Flips the paired task + brief artifacts to the in-flight states and emits
# `brief_started`. lib-ledger's transition helpers are YAML-only post-#245
# A.4/A.5; any straggler legacy helper call fails loud inside lib-ledger.
#
# Usage:
#   scripts/task-claim.sh [--steal] <task-uuid> <brief-uuid> <size>
#
# Exit codes:
#   0  both transitions applied + event emitted
#   2  missing args / artifact not found
#   4  duplicate claim refused — a live worktree already holds this brief
#      (override: --steal flag or ACHILLES_RECLAIM_OK=1)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

STEAL=0
if [ "${1:-}" = "--steal" ]; then
  STEAL=1
  shift
fi

TASK_UUID="${1:?usage: task-claim.sh [--steal] <task-uuid> <brief-uuid> <size>}"
BRIEF_UUID="${2:?brief-uuid required (empty string OK for direct mode)}"
SIZE="${3:?size required}"

# ---------- Duplicate-claim guard (#221) ----------
# Before mutating state, check whether this brief is already held by a live
# worktree. Two signals are combined:
#   1. Worktree directory exists → a prior Achilles created the isolation
#      branch and hasn't merged/cleaned up yet.
#   2. Claim sidecar exists → a prior task-claim.sh wrote metadata. Used to
#      identify orphan reclaims (worktree present but sidecar stale).
#
# Decision matrix:
#   worktree gone                 → orphan reclaim; remove stale sidecar, proceed
#   worktree alive, no override   → refuse (exit 4)
#   worktree alive, --steal       → warn + proceed (forced override)
#   worktree alive, RECLAIM_OK=1  → warn + proceed (env override)
#
# Direct mode (empty BRIEF_UUID) skips this check — no brief to conflict on.
if [ -n "$BRIEF_UUID" ]; then
  project_root=$(resolve_project_root 2>/dev/null) || { printf 'error: resolve_project_root failed\n' >&2; exit 2; }
  worktree_dir="$project_root/worktrees/$TASK_UUID"
  claim_file="$project_root/plans/briefs/${BRIEF_UUID}.claim"

  brief_yaml="$project_root/plans/briefs/${BRIEF_UUID}.yaml"
  if [ -f "$brief_yaml" ]; then
    current_brief_state=$(yq -r '.state // "null"' "$brief_yaml" 2>/dev/null || echo "null")
    if [ "$current_brief_state" = "dispatched" ]; then
      if [ -d "$worktree_dir" ]; then
        # Live worktree — another Achilles session holds this brief.
        if [ "${ACHILLES_RECLAIM_OK:-0}" = "1" ] || [ "$STEAL" = "1" ]; then
          printf 'warn: brief %s is already dispatched with live worktree %s; proceeding (forced override)\n' \
            "$BRIEF_UUID" "$worktree_dir" >&2
          rm -f "$claim_file" 2>/dev/null || true
        else
          printf 'error: brief %s is already dispatched — worktree %s is alive.\n' \
            "$BRIEF_UUID" "$worktree_dir" >&2
          printf '  Another Achilles session may be in flight. To override:\n' >&2
          printf '    --steal flag:           scripts/task-claim.sh --steal %s %s %s\n' \
            "$TASK_UUID" "$BRIEF_UUID" "$SIZE" >&2
          printf '    env override:           ACHILLES_RECLAIM_OK=1 scripts/task-claim.sh ...\n' >&2
          exit 4
        fi
      else
        # Worktree gone — orphan (crashed without cleanup). Remove stale sidecar.
        if [ -f "$claim_file" ]; then
          printf 'warn: brief %s has stale claim (worktree gone); reclaiming\n' "$BRIEF_UUID" >&2
          rm -f "$claim_file" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

# Task flip first so a crash between the two transitions leaves task state
# ahead of brief state; the sweep can recover from a claimed task more safely
# than from a dispatched brief with no task-side evidence.
transition_task_state "$TASK_UUID" in-progress achilles "Step 2 claim" || {
  rc=$?
  printf 'error: transition_task_state failed rc=%s\n' "$rc" >&2
  exit 2
}

# Brief transition only when a brief exists — direct mode passes empty.
if [ -n "$BRIEF_UUID" ]; then
  transition_brief_state "$BRIEF_UUID" dispatched achilles "task-started" || {
    rc=$?
    printf 'error: transition_brief_state failed rc=%s\n' "$rc" >&2
    exit 2
  }

  # Write claim sidecar — coordination file for duplicate-claim detection on
  # subsequent invocations. Not a YAML ledger artifact; cleaned up at Step 10
  # (task-merge.sh) alongside the worktree.
  claim_ts=$(iso_ts_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  worker_id="$(hostname -s 2>/dev/null || echo unknown):$$"
  printf '{"worker_id":"%s","claimed_at":"%s","task_uuid":"%s"}\n' \
    "$worker_id" "$claim_ts" "$TASK_UUID" > "${claim_file:?}" 2>/dev/null || true
fi

# brief_started carries the Step 2 handoff signal for analysis. Keyed by
# task-uuid so the `task` field joins cleanly to downstream events. Gate is
# intentionally absent here — it can escalate mid-task (lsp-only → full-green),
# which made the brief_started copy silently stale. `brief_completed.gate` is
# the sole source of truth (see #86).
data=$(printf '{"size":"%s"}' "$SIZE")
emit_event_keyed achilles task brief_started "$TASK_UUID" "$data" >/dev/null
