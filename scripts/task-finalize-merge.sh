#!/usr/bin/env bash
# task-finalize-merge.sh — Step 11 of the Achilles task mode (#249 Phase 2).
#
# Post-merge finalizer paired with the pre-merge debrief stage. Stamps
# `merge_sha` into the staged debrief YAML, transitions the task to
# `merged`, transitions the brief to `debriefed`, emits `brief_completed`.
#
# Splits the responsibilities of the legacy single-shot task-emit-debrief.sh
# call so the debrief artifact is *staged* before merge (Step 9), then
# *finalized* after merge (this script). The pre-merge stage is what lets
# task-merge.sh refuse merges that lack a debrief — closing the silent-
# merge dark window #249 was filed for.
#
# Idempotent: every mutation is keyed by (subject, from-state>to-state) or
# is a value-set on a YAML field, so reruns of the finalize step on the
# same task are safe.
#
# Usage:
#   scripts/task-finalize-merge.sh <task-uuid> <brief-uuid> <debrief-uuid> <merge-sha> [fields-json]
#     brief-uuid: empty string for direct-mode (no brief).
#     fields-json: optional. Reads build_gate / argus_review.status /
#                  tests.skipped_because to derive the brief_completed
#                  event payload — same shape as task-emit-debrief.sh's
#                  pre-#249 emission.
#
# Exit codes:
#   0  finalized
#   2  missing args / artifact not found

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_UUID="${1:?usage: task-finalize-merge.sh <task-uuid> <brief-uuid> <debrief-uuid> <merge-sha> [fields-json]}"
BRIEF_UUID="${2:?brief-uuid required (empty string OK for direct mode)}"
DEBRIEF_UUID="${3:?debrief-uuid required}"
MERGE_SHA="${4:?merge-sha required}"
if [ $# -ge 5 ] && [ -n "${5:-}" ]; then
  FIELDS_JSON="$5"
else
  FIELDS_JSON='{}'
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required for fields-json parsing\n' >&2; exit 2; }

saved_withhold="${WITHHOLD_INDEX:-0}"
export WITHHOLD_INDEX=1

# Stamp merge_sha into the staged debrief. The pre-merge call wrote
# `branch.merge_sha` empty; fill it now. yq creates the parent if needed.
PROJECT=$(resolve_project 2>/dev/null || echo "")
if [ -n "$PROJECT" ]; then
  DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
  DEBRIEF_PATH="$DEBRIEFS_DIR/$DEBRIEF_UUID.yaml"
  if [ -f "$DEBRIEF_PATH" ] && command -v yq >/dev/null 2>&1; then
    ts=$(iso_ts_now)
    yq -i ".branch.merge_sha = \"$MERGE_SHA\" | .updated_at = \"$ts\"" "$DEBRIEF_PATH" 2>/dev/null \
      || printf 'warn: failed to stamp merge_sha into %s\n' "$DEBRIEF_PATH" >&2
  fi
fi

transition_task_state "$TASK_UUID" merged achilles "post-merge finalize" || {
  rc=$?
  printf 'error: transition_task_state failed rc=%s\n' "$rc" >&2
  exit "$rc"
}

if [ -n "$BRIEF_UUID" ]; then
  transition_brief_state "$BRIEF_UUID" debriefed achilles "task complete" || {
    rc=$?
    printf 'error: transition_brief_state failed rc=%s\n' "$rc" >&2
    exit "$rc"
  }
fi

# brief_completed gate derivation — kept structurally identical to the
# pre-#249 emission in task-emit-debrief.sh so consumers see the same
# event shape regardless of which path mints it.
build_gate=$(printf '%s' "$FIELDS_JSON" | jq -r '.build_gate // "lsp-only"' 2>/dev/null || echo lsp-only)
argus_status=$(printf '%s' "$FIELDS_JSON" | jq -r '.argus_review.status // "not-invoked"' 2>/dev/null || echo "not-invoked")
tests_skipped=$(printf '%s' "$FIELDS_JSON" | jq -r '.tests.skipped_because // ""' 2>/dev/null || echo "")

case "$build_gate" in
  lsp-only)
    gate="lsp-only"
    gate_legacy="lsp-only"
    ;;
  full-green)
    gate_legacy="full-green"
    case "$argus_status" in
      skipped|not-invoked)
        gate="waived"
        ;;
      approved|flagged)
        if [ -n "$tests_skipped" ]; then
          gate="build-only"
        else
          gate="verified"
        fi
        ;;
      blocked|*)
        gate="waived"
        ;;
    esac
    ;;
  *)
    gate="$build_gate"
    gate_legacy="$build_gate"
    ;;
esac

data=$(printf '{"gate":"%s","gate_legacy":"%s","merge_sha":"%s","debrief_id":"%s"}' \
  "$gate" "$gate_legacy" "$MERGE_SHA" "$DEBRIEF_UUID")
emit_event_keyed achilles task brief_completed "$TASK_UUID" "$data" >/dev/null 2>&1 || true

export WITHHOLD_INDEX="$saved_withhold"
flush_index 2>/dev/null || true

exit 0
