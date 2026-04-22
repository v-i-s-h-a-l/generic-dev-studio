#!/usr/bin/env bash
# emit-agent-session-completed.sh — Step 9 of every agent session.
#
# Emits the cross-agent `agent_session_completed` event per
# `_shared/contracts/events.md` § Cross-agent events. Omits the `tokens`
# sub-object entirely when no token counts are supplied — duration-only
# sessions are still useful and explicit `null`s muddy the catalog.
#
# Usage:
#   scripts/emit-agent-session-completed.sh <agent> <mode> <task> <duration_s> \
#       [--verdict <v>] [--files-read <n>] [--files-written <n>] \
#       [--tokens-input <n>] [--tokens-output <n>] \
#       [--tokens-cache-read <n>] [--tokens-cache-write <n>]
#
# Exit codes:
#   0  event appended (or logged under DRY_RUN=1)
#   2  missing/invalid args
#   3  envelope > 4096 byte atomicity cap (propagated from emit_event_keyed)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -lt 4 ] && usage

AGENT="$1"
MODE="$2"
TASK="$3"
DURATION_S="$4"
shift 4

case "$AGENT" in
  chanakya|achilles|argus) ;;
  *) printf 'error: invalid agent "%s"\n' "$AGENT" >&2; exit 2 ;;
esac

# Duration must be numeric — non-negative int. Float would bloat the JSON and
# is never what a shell-time subtraction produces.
case "$DURATION_S" in
  ''|*[!0-9]*) printf 'error: duration_s must be a non-negative integer, got %s\n' "$DURATION_S" >&2; exit 2 ;;
esac

VERDICT=""
FILES_READ=""
FILES_WRITTEN=""
T_IN=""
T_OUT=""
T_CR=""
T_CW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verdict)            VERDICT="${2:?}";       shift 2 ;;
    --files-read)         FILES_READ="${2:?}";    shift 2 ;;
    --files-written)      FILES_WRITTEN="${2:?}"; shift 2 ;;
    --tokens-input)       T_IN="${2:?}";          shift 2 ;;
    --tokens-output)      T_OUT="${2:?}";         shift 2 ;;
    --tokens-cache-read)  T_CR="${2:?}";          shift 2 ;;
    --tokens-cache-write) T_CW="${2:?}";          shift 2 ;;
    *) printf 'error: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Build the data JSON via printf concatenation — avoids jq/python for a
# fixed-shape payload. Optional fields elided rather than `null` so readers
# can distinguish "not measured" from "zero".
data='{"mode":"'"$MODE"'","duration_s":'"$DURATION_S"

[ -n "$VERDICT" ]       && data+=',"verdict":"'"$VERDICT"'"'
[ -n "$FILES_READ" ]    && data+=',"files_read":'"$FILES_READ"
[ -n "$FILES_WRITTEN" ] && data+=',"files_written":'"$FILES_WRITTEN"

# Tokens sub-object appears only when at least one token field was supplied.
# Individual missing fields within the sub-object become `0` (safer for
# downstream arithmetic than `null`).
if [ -n "$T_IN$T_OUT$T_CR$T_CW" ]; then
  data+=',"tokens":{'
  data+='"input":'"${T_IN:-0}"
  data+=',"output":'"${T_OUT:-0}"
  data+=',"cache_read":'"${T_CR:-0}"
  data+=',"cache_write":'"${T_CW:-0}"
  data+='}'
fi

data+='}'

emit_event_keyed "$AGENT" "$MODE" agent_session_completed "$TASK" "$data"
