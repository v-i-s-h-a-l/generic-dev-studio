#!/usr/bin/env bash
# task-emit-debrief.sh — Step 10 of the Achilles task mode.
#
# Wraps lib-ledger's `write_debrief_artifact` with the task-mode-specific
# follow-ons: mint a UUIDv7 for the debrief, set the task's
# `links.debrief` back-ref, flip the task + brief states to their post-merge
# values, and emit `brief_completed`. The debrief artifact + its own
# `debrief_emitted` event + legacy markdown dual-write are handled inside
# `write_debrief_artifact`.
#
# The debrief-fields-json is an object whose keys become YAML lines via
# `_append_kv_lines` (lib-ledger). Keys starting with `[` / `{` are passed
# through as inline YAML; everything else is yaml-quoted. Typical keys:
#   legacy_task_id, branch, commits, diff_summary, build_gate,
#   build_debt_override, argus_review, body (legacy markdown payload).
#
# Usage:
#   scripts/task-emit-debrief.sh <task-uuid> <brief-uuid> <state> <fields-json>
#     state: one of the task-lifecycle.md states (self-reviewed | merged |
#            blocked | cancelled).
#
# Stdout: the minted debrief UUID.
#
# Exit codes:
#   0  debrief written + state flips applied
#   2  missing args or artifact not found
#   3  dual-write partial (propagated)

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
  [ "$rc" -ne 3 ] && { printf 'error: write_debrief_artifact failed rc=%s\n' "$rc" >&2; exit "$rc"; }
  # rc=3 = dual-write partial — YAML landed, legacy failed. Continue with the
  # state flips + event so the canonical shape reflects reality; surface
  # exit 3 at the end.
  DUAL_WRITE_PARTIAL=1
}

# Task back-ref — point at the new debrief. Idempotent if the caller retries.
set_task_link "$TASK_UUID" debrief "$DEBRIEF_UUID" || {
  printf 'warn: set_task_link debrief failed; continuing\n' >&2
}

# Task state flip. `merged` is the terminal happy path; `self-reviewed` covers
# pre-Argus debriefs; `blocked` / `cancelled` are the escape hatches.
transition_task_state "$TASK_UUID" "$TARGET_STATE" achilles "debrief emitted" || {
  rc=$?
  [ "$rc" -eq 3 ] && DUAL_WRITE_PARTIAL=1 || { printf 'error: transition_task_state failed rc=%s\n' "$rc" >&2; exit "$rc"; }
}

# Brief → debriefed only when we have a brief. Direct-mode skips.
if [ -n "$BRIEF_UUID" ]; then
  transition_brief_state "$BRIEF_UUID" debriefed achilles "task complete" || {
    rc=$?
    [ "$rc" -eq 3 ] && DUAL_WRITE_PARTIAL=1 || { printf 'error: transition_brief_state failed rc=%s\n' "$rc" >&2; exit "$rc"; }
  }
fi

# brief_completed carries the summary signal Chanakya's sweep keys on.
# Include gate when supplied in fields-json (e.g. build_gate=full-green).
gate=$(printf '%s' "$FIELDS_JSON" | jq -r '.build_gate // "lsp-only"' 2>/dev/null || echo lsp-only)
merge_sha=$(printf '%s' "$FIELDS_JSON" | jq -r '.branch.merge_sha // ""' 2>/dev/null || echo "")
data=$(printf '{"gate":"%s","merge_sha":"%s","debrief_id":"%s"}' "$gate" "$merge_sha" "$DEBRIEF_UUID")
emit_event_keyed achilles task brief_completed "$TASK_UUID" "$data" >/dev/null 2>&1 || true

# Flush the index now that the batch is done.
export WITHHOLD_INDEX="$saved_withhold"
flush_index 2>/dev/null || true

printf '%s\n' "$DEBRIEF_UUID"

[ "${DUAL_WRITE_PARTIAL:-0}" -eq 1 ] && exit 3
exit 0
