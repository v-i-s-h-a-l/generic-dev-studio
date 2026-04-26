#!/usr/bin/env bash
# suggestion-emit.sh — emit a `suggestion_emitted` event with idempotent dedupe.
#
# The suggestion engine substrate (#253). Producers (sweep paths, stale queries,
# hotfix detectors, etc.) shell here instead of building event envelopes inline.
# Dedupe scans recent event-log days for an open `suggestion_emitted` carrying
# the same `idempotency_key` whose paired `suggestion_resolved` has not landed.
#
# Usage:
#   scripts/suggestion-emit.sh \
#       --kind <enum>                  e.g. stale_brief
#       --idem-key <key>               stable hash of precondition (caller-built)
#       --action-hint <text>           one-line call-to-action (≤200 chars)
#       [--payload <json>]             kind-specific JSON object (default {})
#       [--task <id>]                  task field on event envelope
#       [--days <n>]                   dedupe window (default 30)
#       [--mode <m>]                   producer mode for envelope.producer
#
# Exit codes:
#   0  emitted (new) OR skipped (dedupe hit) — both are success
#   2  malformed args / payload not valid JSON / required flag missing
#   3  envelope > 4096 byte cap (propagated from emit_event_keyed)
#
# Stdout: `emitted\n` or `skipped:dedupe\n` so callers can branch.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

KIND=""
IDEM=""
HINT=""
PAYLOAD='{}'
TASK=""
DAYS=30
MODE="suggestion"

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)        KIND="${2:?--kind requires a value}";        shift 2 ;;
    --idem-key)    IDEM="${2:?--idem-key requires a value}";    shift 2 ;;
    --action-hint) HINT="${2:?--action-hint requires a value}"; shift 2 ;;
    --payload)     PAYLOAD="${2:-\{\}}";                        shift 2 ;;
    --task)        TASK="${2:-}";                               shift 2 ;;
    --days)        DAYS="${2:-30}";                             shift 2 ;;
    --mode)        MODE="${2:-suggestion}";                     shift 2 ;;
    -h|--help)     sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) printf 'suggestion-emit: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$KIND" ] || { printf 'suggestion-emit: --kind is required\n' >&2; exit 2; }
[ -n "$IDEM" ] || { printf 'suggestion-emit: --idem-key is required\n' >&2; exit 2; }
[ -n "$HINT" ] || { printf 'suggestion-emit: --action-hint is required\n' >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'suggestion-emit: jq required\n' >&2; exit 2
fi
if ! printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1; then
  printf 'suggestion-emit: --payload is not valid JSON\n' >&2; exit 2
fi

# Dedupe scan: walk the last $DAYS event-log files. An open suggestion has
# a `suggestion_emitted` with this idempotency_key and no later
# `suggestion_resolved` carrying the same key. We collect both sides then
# subtract.
events_dir=$(resolve_events_dir 2>/dev/null) || {
  printf 'suggestion-emit: cannot resolve events dir\n' >&2; exit 2
}

is_open=0
if [ -d "$events_dir" ]; then
  # Build the date list ourselves (portable: GNU `date -d` and BSD `date -v`
  # diverge). We compute "today minus N" via epoch math.
  now_epoch=$(date -u +%s)
  files=""
  i=0
  while [ "$i" -le "$DAYS" ]; do
    day_epoch=$(( now_epoch - i * 86400 ))
    day=$(date -u -r "$day_epoch" +%Y-%m-%d 2>/dev/null) || \
      day=$(date -u -d "@$day_epoch" +%Y-%m-%d 2>/dev/null) || break
    f="$events_dir/$day.jsonl"
    [ -f "$f" ] && files="$files
$f"
    i=$(( i + 1 ))
  done

  if [ -n "$files" ]; then
    emitted=$(printf '%s\n' "$files" | sed '/^$/d' | xargs -I {} jq -c \
      --arg key "$IDEM" \
      'select(.event == "suggestion_emitted" and .idempotency_key == $key)' \
      {} 2>/dev/null | wc -l | tr -d ' ')
    resolved=$(printf '%s\n' "$files" | sed '/^$/d' | xargs -I {} jq -c \
      --arg key "$IDEM" \
      'select(.event == "suggestion_resolved" and .idempotency_key == $key)' \
      {} 2>/dev/null | wc -l | tr -d ' ')
    if [ "$emitted" -gt "$resolved" ]; then
      is_open=1
    fi
  fi
fi

if [ "$is_open" -eq 1 ]; then
  printf 'skipped:dedupe\n'
  exit 0
fi

DATA=$(jq -nc \
  --arg kind "$KIND" \
  --arg hint "$HINT" \
  --argjson payload "$PAYLOAD" \
  '{kind: $kind, action_hint: $hint, payload: $payload}')

"$SCRIPT_DIR/write-event.sh" \
  --agent chanakya \
  --mode "$MODE" \
  --event suggestion_emitted \
  --task "$TASK" \
  --data "$DATA" \
  --idem-key "$IDEM" \
  >/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
printf 'emitted\n'
