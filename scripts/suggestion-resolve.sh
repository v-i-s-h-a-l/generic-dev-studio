#!/usr/bin/env bash
# suggestion-resolve.sh — emit a `suggestion_resolved` event closing a prior
# `suggestion_emitted` carrying the same idempotency_key.
#
# Usage:
#   scripts/suggestion-resolve.sh \
#       --idem-key <key> \
#       --kind <enum> \
#       --reason <user_acted|precondition_cleared|superseded|other> \
#       [--superseded-by <key>]      required when --reason superseded
#       [--task <id>]
#       [--mode <m>]
#
# Exit codes:
#   0  resolved
#   2  malformed args
#   3  envelope > 4096 byte cap

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

IDEM=""
KIND=""
REASON=""
SUPERSEDED_BY=""
TASK=""
MODE="suggestion"

while [ $# -gt 0 ]; do
  case "$1" in
    --idem-key)       IDEM="${2:?}";          shift 2 ;;
    --kind)           KIND="${2:?}";          shift 2 ;;
    --reason)         REASON="${2:?}";        shift 2 ;;
    --superseded-by)  SUPERSEDED_BY="${2:-}"; shift 2 ;;
    --task)           TASK="${2:-}";          shift 2 ;;
    --mode)           MODE="${2:-suggestion}";shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) printf 'suggestion-resolve: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$IDEM" ]   || { printf 'suggestion-resolve: --idem-key is required\n' >&2; exit 2; }
[ -n "$KIND" ]   || { printf 'suggestion-resolve: --kind is required\n' >&2; exit 2; }
[ -n "$REASON" ] || { printf 'suggestion-resolve: --reason is required\n' >&2; exit 2; }

case "$REASON" in
  user_acted|precondition_cleared|superseded|other) ;;
  *) printf 'suggestion-resolve: --reason must be user_acted|precondition_cleared|superseded|other\n' >&2; exit 2 ;;
esac

if [ "$REASON" = "superseded" ] && [ -z "$SUPERSEDED_BY" ]; then
  printf 'suggestion-resolve: --superseded-by required when --reason superseded\n' >&2
  exit 2
fi

if [ -n "$SUPERSEDED_BY" ]; then
  DATA=$(jq -nc --arg k "$KIND" --arg r "$REASON" --arg s "$SUPERSEDED_BY" \
    '{kind:$k, reason:$r, superseded_by:$s}')
else
  DATA=$(jq -nc --arg k "$KIND" --arg r "$REASON" '{kind:$k, reason:$r}')
fi

"$SCRIPT_DIR/write-event.sh" \
  --agent chanakya \
  --mode "$MODE" \
  --event suggestion_resolved \
  --task "$TASK" \
  --data "$DATA" \
  --idem-key "$IDEM" \
  >/dev/null
