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
# `<duration_s>` accepts either:
#   - a non-negative integer (legacy caller-measured form), or
#   - `auto:<session-id>` — resolves the session-start stamp written by
#     `emit-agent-boot.sh` at first-write and computes `now - start`. Use this
#     from any agent session-completion path (task, waived merge, direct,
#     rescue) — the stamp is captured unconditionally at session start, so
#     duration_s is never null regardless of which path the session took
#     through the lifecycle. Falls back to 0 (with a stderr warn) if the
#     stamp is missing, since completion without prior first-write is a
#     read-only session anomaly worth seeing rather than swallowing.
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

# Plausibility guards for the computed duration. `EPOCH_FLOOR` rejects a
# stamp file containing 0 or a sub-2020 value — the `NOW - 0` bug produced
# ~56-year durations (issue #107). `DURATION_CAP` (24h) rejects runaway
# values from any other arithmetic error. When the computed value fails
# either guard, we OMIT duration_s from the event rather than emit garbage
# — readers then see "session recorded but timing unreliable" instead of a
# plausible-looking lie.
EPOCH_FLOOR=1577836800          # 2020-01-01T00:00:00Z
DURATION_CAP=86400              # 24 hours
DURATION_OK=1                   # set to 0 when the computed value is rejected

# `auto:<session-id>` form: read the start-ts stamped by emit-agent-boot.sh
# and compute now - start. This is the unconditional-stamp path — works for
# task, waived merge, direct, and rescue sessions because all four pass
# through agent-boot at first write. Legacy integer form still accepted so
# existing callers (argus-run-tests.sh) don't churn.
case "$DURATION_S" in
  auto:*)
    SESSION_ID="${DURATION_S#auto:}"
    [ -z "$SESSION_ID" ] && { printf 'error: auto: form requires a session-id (got empty)\n' >&2; exit 2; }
    START_STAMP=$(resolve_session_start_stamp "$SESSION_ID" 2>/dev/null) || START_STAMP=""
    START_S=""
    if [ -n "$START_STAMP" ] && [ -r "$START_STAMP" ]; then
      START_S=$(cat "$START_STAMP" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$START_S" in
      ''|*[!0-9]*)
        printf 'warn: no session-start stamp for "%s" — omitting duration_s (agent-boot was not invoked; read-only session?)\n' "$SESSION_ID" >&2
        DURATION_OK=0
        ;;
      *)
        if [ "$START_S" -lt "$EPOCH_FLOOR" ]; then
          printf 'warn: session-start stamp for "%s" is pre-%s (%s) — omitting duration_s (stamp file corrupt?)\n' \
            "$SESSION_ID" "$EPOCH_FLOOR" "$START_S" >&2
          DURATION_OK=0
        else
          NOW_S=$(date -u +%s)
          DURATION_S=$(( NOW_S - START_S ))
          if [ "$DURATION_S" -lt 0 ]; then
            DURATION_S=0
          elif [ "$DURATION_S" -gt "$DURATION_CAP" ]; then
            printf 'warn: computed duration_s=%s exceeds %ss cap for "%s" — omitting (clock skew or stale stamp?)\n' \
              "$DURATION_S" "$DURATION_CAP" "$SESSION_ID" >&2
            DURATION_OK=0
          fi
        fi
        ;;
    esac
    ;;
  ''|*[!0-9]*) printf 'error: duration_s must be a non-negative integer or auto:<session-id>, got %s\n' "$DURATION_S" >&2; exit 2 ;;
  *)
    # Caller-supplied integer form — still clamp to the upper cap. Below-zero
    # is impossible here (non-negative-integer regex above).
    if [ "$DURATION_S" -gt "$DURATION_CAP" ]; then
      printf 'warn: caller-supplied duration_s=%s exceeds %ss cap — omitting\n' \
        "$DURATION_S" "$DURATION_CAP" >&2
      DURATION_OK=0
    fi
    ;;
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
# can distinguish "not measured" from "zero". duration_s is omitted entirely
# when DURATION_OK=0 (see plausibility guards above) — readers then treat
# the event as "session recorded, timing unreliable" rather than trust a
# fabricated number.
if [ "$DURATION_OK" = "1" ]; then
  data='{"mode":"'"$MODE"'","duration_s":'"$DURATION_S"
else
  data='{"mode":"'"$MODE"'"'
fi

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
