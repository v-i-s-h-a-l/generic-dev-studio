#!/usr/bin/env bash
# sweep-threshold-actions.sh — Step 0C of the inbox sweep.
#
# Inspects the Build Debt counter in chanakya-master.md and fires threshold
# actions per `_shared/rules/debt-tracking.md`:
#
#   counter ≥ 6 (warn)  AND no open TBUILD task  → mint TBUILD, emit
#                                                  build_debt_warned.
#   counter ≥ 12 (block)                         → set build_debt_blocked
#                                                  state flag, emit
#                                                  build_debt_blocked.
#
# Idempotent: second run with no counter change no-ops (existing TBUILD
# detected, flag file already written). The counter itself is maintained by
# sweep-ingest.sh when processing debriefs.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
MASTER="$PROJECT_ROOT/plans/chanakya-master.md"
STATE_DIR="$PROJECT_ROOT/.runtime/state"
BLOCK_FLAG="$STATE_DIR/build_debt_blocked"

[ -f "$MASTER" ] || exit 0

# Parse the Counter line inside the `## Build Debt` block. Scope is bounded
# by the next `##` heading so we don't accidentally pick up Unit/UI sections.
counter=$(awk '
  /^## Build Debt/ { in_block=1; next }
  in_block && /^## / { exit }
  in_block && /^- Counter:/ {
    t=$0
    sub(/^.*Counter: */, "", t)
    sub(/ .*$/, "", t)
    print t + 0
    exit
  }
' "$MASTER")
counter=${counter:-0}

# Check for an existing open TBUILD task in the post-2.6 surface. Grep tasks
# whose title references TBUILD and whose state is still open — if one exists
# we don't mint another (idempotency; per inbox-sweep Step 0C second bullet).
has_open_tbuild=0
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT" 2>/dev/null || echo "")
if [ -n "$TASKS_DIR" ] && [ -d "$TASKS_DIR" ] && command -v yq >/dev/null 2>&1; then
  for t in "$TASKS_DIR"/*.yaml; do
    [ -f "$t" ] || continue
    state=$(yq -r '.state // ""' "$t" 2>/dev/null || echo "")
    case "$state" in
      proposed|briefed|dispatched|in-progress) ;;
      *) continue ;;
    esac
    title=$(yq -r '.title // ""' "$t" 2>/dev/null || echo "")
    case "$title" in
      *TBUILD*)
        has_open_tbuild=1
        break
        ;;
    esac
  done
fi

# Warn threshold — mint a TBUILD task if none open.
if [ "$counter" -ge 6 ] && [ "$has_open_tbuild" = "0" ]; then
  tbuild_uuid=$(mint_uuidv7)
  # `P1` per spec (build-debt threshold, not red-build emergency which is P0).
  write_task_artifact "$tbuild_uuid" proposed \
    "TBUILD — Build verification checkpoint (debt counter=$counter)" \
    type=build-check priority=P1 source=build-debt legacy_task_id=TBUILD || true
  emit_event_keyed chanakya inbox-sweep build_debt_warned "" \
    "{\"counter\":$counter,\"threshold\":6}" >/dev/null || true
fi

# Block threshold — set the per-project flag and emit.
if [ "$counter" -ge 12 ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  # Flag file contents: counter + timestamp. Readers only check existence,
  # but the contents help debugging.
  tmp="$BLOCK_FLAG.tmp.$$"
  printf 'counter: %s\nset_at: %s\n' "$counter" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$BLOCK_FLAG" 2>/dev/null || rm -f "$tmp"
  emit_event_keyed chanakya inbox-sweep build_debt_blocked "" \
    "{\"counter\":$counter}" >/dev/null || true
fi

exit 0
