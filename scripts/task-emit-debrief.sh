#!/usr/bin/env bash
# task-emit-debrief.sh — Step 10 of the Achilles task mode.
#
# Wraps lib-ledger's `write_debrief_artifact` with the task-mode-specific
# follow-ons: mint a UUIDv7 for the debrief, set the task's
# `links.debrief` back-ref, flip the task + brief states to their post-merge
# values, and emit `brief_completed`. The debrief artifact and its own
# `debrief_emitted` event are handled inside `write_debrief_artifact`.
#
# The debrief-fields-json is an object whose keys become YAML lines via
# `_append_kv_lines` (lib-ledger). Keys starting with `[` / `{` are passed
# through as inline YAML; everything else is yaml-quoted. Typical keys:
#   legacy_task_id, branch, commits, diff_summary, build_gate,
#   build_debt_override, argus_review, body.
#
# Usage:
#   scripts/task-emit-debrief.sh <task-uuid> <brief-uuid> <state> <fields-json>
#     state: one of the task-lifecycle.md states (self-reviewed |
#            argus-reviewed | merged | blocked | cancelled).
#
# Pre-merge mode (#249 Phase 2): pass `argus-reviewed` to *stage* the
# debrief before task-merge.sh runs. The brief→debriefed transition and
# the `brief_completed` event are deferred to task-finalize-merge.sh on
# successful merge. Any other state runs the direct single-shot path used by
# direct-mode and pre-#249 callers.
#
# Stdout: the minted debrief UUID.
#
# Exit codes:
#   0  debrief written + state flips applied
#   2  missing args or artifact not found

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_UUID="${1:?usage: task-emit-debrief.sh <task-uuid> <brief-uuid> <state> <fields-json>}"
BRIEF_UUID="${2:?brief-uuid required (empty string OK for direct mode)}"
TARGET_STATE="${3:?state required (self-reviewed|merged|blocked|cancelled)}"
# Explicit default — bash's `${4:-{}}` parses as `${4:-{}`+`}` on macOS's
# /bin/bash 3.2, leaving FIELDS_JSON=`{}}` when arg is unset. Use a separate
# branch so the literal `{}` is unambiguous.
if [ $# -ge 4 ] && [ -n "${4:-}" ]; then
  FIELDS_JSON="$4"
else
  FIELDS_JSON='{}'
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required for fields-json parsing\n' >&2; exit 2; }

case "$TARGET_STATE" in
  self-reviewed|merged|blocked|cancelled|argus-reviewed) ;;
  *) printf 'error: unknown target state %s\n' "$TARGET_STATE" >&2; exit 2 ;;
esac

DEBRIEF_UUID=$(mint_uuidv7)

# Convert JSON object → k=v args that _append_kv_lines consumes. jq renders
# scalars + objects + arrays on one line per key; arrays/objects keep their
# bracket prefix so the helper routes them to the inline-YAML branch.
#
# Avoid `mapfile` — it's bash-only and this script must run under zsh too.
# Read into a plain array with NUL-separated entries so embedded spaces in
# values survive the round-trip intact.
printf '%s' "$FIELDS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || {
  printf 'error: fields-json is not a parseable JSON object\n' >&2
  exit 2
}
KV_ARGS=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  KV_ARGS+=("$line")
done < <(printf '%s' "$FIELDS_JSON" | jq -r '
  to_entries[] |
  if (.value | type) == "object" or (.value | type) == "array"
  then "\(.key)=\(.value | tojson)"
  elif (.value | type) == "boolean"
  then "\(.key)=\(.value)"
  elif .value == null
  then "\(.key)=null"
  else "\(.key)=\(.value)"
  end
' 2>/dev/null)

# Map empty brief uuid → lib-ledger's null sentinel. write_debrief_artifact
# already guards both `null` and empty string.
BRIEF_ARG="$BRIEF_UUID"
[ -z "$BRIEF_ARG" ] && BRIEF_ARG="null"

# Batch the index rebuild — we fire N mutations in a row; the caller has
# nothing useful to do between them.
saved_withhold="${WITHHOLD_INDEX:-0}"
export WITHHOLD_INDEX=1

write_debrief_artifact "$DEBRIEF_UUID" "$TASK_UUID" "$BRIEF_ARG" task emitted ${KV_ARGS[@]+"${KV_ARGS[@]}"} || {
  rc=$?
  printf 'error: write_debrief_artifact failed rc=%s\n' "$rc" >&2
  exit "$rc"
}

# Task back-ref — point at the new debrief. Idempotent if the caller retries.
set_task_link "$TASK_UUID" debrief "$DEBRIEF_UUID" || {
  printf 'warn: set_task_link debrief failed; continuing\n' >&2
}

# Task state flip. `merged` is the terminal happy path; `self-reviewed` covers
# pre-Argus debriefs; `blocked` / `cancelled` are the escape hatches.
transition_task_state "$TASK_UUID" "$TARGET_STATE" achilles "debrief emitted" || {
  rc=$?
  printf 'error: transition_task_state failed rc=%s\n' "$rc" >&2
  exit "$rc"
}

# Brief → debriefed only when we have a brief. Direct-mode skips. The
# argus-reviewed target state is the pre-merge stage (#249 Phase 2): the
# brief isn't "complete" until task-finalize-merge.sh runs post-merge, so
# defer the brief transition + brief_completed event there.
if [ -n "$BRIEF_UUID" ] && [ "$TARGET_STATE" != "argus-reviewed" ]; then
  transition_brief_state "$BRIEF_UUID" debriefed achilles "task complete" || {
    rc=$?
    printf 'error: transition_brief_state failed rc=%s\n' "$rc" >&2
    exit "$rc"
  }
fi

# brief_completed carries the summary signal Chanakya's sweep keys on.
#
# Gate taxonomy (per events.md, issue #84). The debrief's `build_gate` field
# is the *selected* gate mode (lsp-only | full-green). The event's `gate`
# field is the *outcome* — it splits full-green into three cases so analytics
# + humans can tell "really verified" apart from "build green but tests
# disabled" and "build green but review waived":
#
#   verified    build-green + tests executed + Argus approved/flagged
#   build-only  build-green + tests suite disabled (tests.skipped_because set)
#   waived      build-green + Argus skipped/not-invoked on a non-exempt path
#   lsp-only    LSP-only gate (unchanged)
#
# Ordering matters: waived takes precedence over build-only when both apply —
# a disabled-tests suite with a waived review is the least-verified of the
# three, and the review waiver is the signal most likely to surface policy
# drift. `gate_legacy` is emitted alongside as the pre-#84 value so any
# consumer still matching on `full-green` / `lsp-only` keeps working.
build_gate=$(printf '%s' "$FIELDS_JSON" | jq -r '.build_gate // "lsp-only"' 2>/dev/null || echo lsp-only)
argus_status=$(printf '%s' "$FIELDS_JSON" | jq -r '.argus_review.status // "not-invoked"' 2>/dev/null || echo "not-invoked")
tests_skipped=$(printf '%s' "$FIELDS_JSON" | jq -r '.tests.skipped_because // ""' 2>/dev/null || echo "")
merge_sha=$(printf '%s' "$FIELDS_JSON" | jq -r '.branch.merge_sha // ""' 2>/dev/null || echo "")

case "$build_gate" in
  lsp-only)
    gate="lsp-only"
    gate_legacy="lsp-only"
    ;;
  full-green)
    gate_legacy="full-green"
    case "$argus_status" in
      skipped|not-invoked)
        # `not-invoked` on the task-mode path (as opposed to build/test-suite
        # modes which are Argus-exempt and route through different emitters)
        # means the gate was waived. Build / test-suite modes don't land here.
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
        # `blocked` shouldn't reach brief_completed (merge wouldn't happen),
        # but if it does, treat as waived — the merge bypassed a hard stop.
        gate="waived"
        ;;
    esac
    ;;
  *)
    # Unknown build_gate — preserve raw value for debugging; legacy mirrors it.
    gate="$build_gate"
    gate_legacy="$build_gate"
    ;;
esac

if [ "$TARGET_STATE" != "argus-reviewed" ]; then
  data=$(printf '{"gate":"%s","gate_legacy":"%s","merge_sha":"%s","debrief_id":"%s"}' \
    "$gate" "$gate_legacy" "$merge_sha" "$DEBRIEF_UUID")
  emit_event_keyed achilles task brief_completed "$TASK_UUID" "$data" >/dev/null 2>&1 || true
fi

# Flush the index now that the batch is done.
export WITHHOLD_INDEX="$saved_withhold"
flush_index 2>/dev/null || true

printf '%s\n' "$DEBRIEF_UUID"

exit 0
