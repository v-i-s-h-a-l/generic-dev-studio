#!/usr/bin/env bash
# Reopen a closed task. Validates current state, transitions to `reopened`,
# stamps `reopen_reason`, appends prior debrief id to `reopen_chain`, emits
# `task_reopened` (the matching `task_state_changed` event is emitted by
# `transition_task_state` in lib-ledger).
#
# Usage:
#   scripts/task-reopen.sh <task-uuid|legacy-task-id> --reason="<text>"
#
# Exit codes:
#   0 — reopen applied
#   2 — usage / unresolved task / yq missing
#   3 — task in non-reopenable state (must be verified|merged|archived|cancelled)
#   4 — reason missing or > 280 chars

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

usage() {
  cat <<EOF
usage: task-reopen.sh <task-uuid|legacy-task-id> --reason="<text>"

Reopens a closed task. Source state must be one of:
  verified | merged | archived | cancelled

The reopen_reason is required (≤ 280 chars). Conventional prefixes:
  qa-rejected: design-rejected: product-rejected: regression: incomplete:
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 2; }

case "$1" in -h|--help) usage; exit 0 ;; esac

TASK_ARG="$1"; shift
REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason=*) REASON="${1#--reason=}" ;;
    --reason)   shift; REASON="${1:-}" ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'task-reopen.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$REASON" ] || { printf 'task-reopen.sh: --reason is required\n' >&2; exit 4; }
[ "${#REASON}" -le 280 ] || { printf 'task-reopen.sh: --reason exceeds 280 chars (%d)\n' "${#REASON}" >&2; exit 4; }

command -v yq >/dev/null 2>&1 || { printf 'task-reopen.sh: yq required\n' >&2; exit 2; }

PROJECT="$(resolve_project)"
TASKS_DIR="$(resolve_tasks_dir_for "$PROJECT")"
[ -d "$TASKS_DIR" ] || { printf 'task-reopen.sh: tasks dir missing at %s\n' "$TASKS_DIR" >&2; exit 2; }

# Resolve UUID. Accept either a UUID directly or a legacy task id.
TASK_UUID=""
if [ -f "$TASKS_DIR/$TASK_ARG.yaml" ]; then
  TASK_UUID="$TASK_ARG"
else
  TASK_UUID="$(grep -lE "^legacy_task_id: *\"?${TASK_ARG}\"?$" "$TASKS_DIR"/*.yaml 2>/dev/null \
    | head -1 \
    | xargs -I{} basename {} .yaml 2>/dev/null || true)"
fi
[ -n "$TASK_UUID" ] || { printf 'task-reopen.sh: no task matches %s under %s\n' "$TASK_ARG" "$TASKS_DIR" >&2; exit 2; }

TASK_FILE="$TASKS_DIR/$TASK_UUID.yaml"

PRIOR_STATE="$(yq -r '.state // ""' "$TASK_FILE")"
case "$PRIOR_STATE" in
  verified|merged|archived|cancelled) ;;
  *)
    printf 'task-reopen.sh: task %s is in state %s — only verified|merged|archived|cancelled may reopen\n' \
      "$TASK_UUID" "$PRIOR_STATE" >&2
    exit 3 ;;
esac

PRIOR_DEBRIEF="$(yq -r '.links.debrief // ""' "$TASK_FILE")"

# State transition + history append + event emission (task_state_changed).
transition_task_state "$TASK_UUID" reopened chanakya "$REASON"

# Stamp reopen_reason and append prior debrief to reopen_chain (idempotent —
# never appends an empty value, never duplicates the most recent entry).
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REASON_ESCAPED="$(printf '%s' "$REASON" | sed 's/"/\\"/g')"
if [ -n "$PRIOR_DEBRIEF" ]; then
  yq -i \
    ".reopen_reason = \"$REASON_ESCAPED\" \
     | .updated_at = \"$TS\" \
     | (.reopen_chain |= ((. // []) | (. + [\"$PRIOR_DEBRIEF\"]) | unique_by(.)))" \
    "$TASK_FILE"
else
  yq -i \
    ".reopen_reason = \"$REASON_ESCAPED\" | .updated_at = \"$TS\"" \
    "$TASK_FILE"
fi

CHAIN_DEPTH="$(yq -r '.reopen_chain | length' "$TASK_FILE")"

# Emit the domain event. Idempotent per (chanakya:reopen:<uuid>:<prior_state>:<ts>).
DATA=$(printf '{"prior_state":"%s","reason":"%s","prior_debrief_id":%s,"chain_depth":%d}' \
  "$PRIOR_STATE" \
  "$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
  "$([ -n "$PRIOR_DEBRIEF" ] && printf '"%s"' "$PRIOR_DEBRIEF" || printf 'null')" \
  "$CHAIN_DEPTH")

IDEM="$(idem_key chanakya reopen "$TASK_UUID" "${PRIOR_STATE}>reopened:${TS}")"
emit_event_keyed chanakya reopen task_reopened "$TASK_UUID" "$DATA" --idem-key "$IDEM" >/dev/null

printf 'task-reopen.sh: %s %s -> reopened (chain_depth=%d, reason=%s)\n' \
  "$TASK_UUID" "$PRIOR_STATE" "$CHAIN_DEPTH" "$REASON"
