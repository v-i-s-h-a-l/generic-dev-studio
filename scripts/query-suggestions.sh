#!/usr/bin/env bash
# query-suggestions.sh — list active (unsuperseded, unresolved) suggestions.
#
# Reads recent event-log days. Active = `suggestion_emitted` whose
# `idempotency_key` has no later `suggestion_resolved` carrying the same key.
#
# Usage:
#   scripts/query-suggestions.sh [--days N] [--format json|render]
#
# Output:
#   --format render (default): one rendered line per active suggestion —
#                              `[<task>] <action_hint>` (task omitted when empty)
#   --format json:             one JSON object per line with
#                              {idempotency_key, kind, action_hint, payload, task, ts}
#
# Exit codes:
#   0  succeeded (zero or more suggestions printed)
#   2  cannot resolve events dir / jq missing

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

DAYS=30
FORMAT="render"

while [ $# -gt 0 ]; do
  case "$1" in
    --days)   DAYS="${2:-30}";    shift 2 ;;
    --format) FORMAT="${2:-render}"; shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) printf 'query-suggestions: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$FORMAT" in
  render|json) ;;
  *) printf 'query-suggestions: --format must be render|json\n' >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf 'query-suggestions: jq required\n' >&2; exit 2
fi

events_dir=$(resolve_events_dir 2>/dev/null) || {
  printf 'query-suggestions: cannot resolve events dir\n' >&2; exit 2
}
[ -d "$events_dir" ] || exit 0

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
files=$(printf '%s\n' "$files" | sed '/^$/d')
[ -n "$files" ] || exit 0

# Build the active set: emitted minus resolved by idempotency_key.
# jq slurp across all matching files in chronological (oldest-first) order so
# the *latest* emit per key wins in the final accumulator.
ordered=$(printf '%s\n' "$files" | sort)

active_json=$(printf '%s\n' "$ordered" | xargs cat 2>/dev/null | jq -s -c '
  reduce .[] as $e ({};
    if $e.event == "suggestion_emitted" and ($e.idempotency_key // "") != "" then
      .[$e.idempotency_key] = {
        idempotency_key: $e.idempotency_key,
        kind: ($e.data.kind // ""),
        action_hint: ($e.data.action_hint // ""),
        payload: ($e.data.payload // {}),
        task: ($e.task // ""),
        ts: $e.ts
      }
    elif $e.event == "suggestion_resolved" and ($e.idempotency_key // "") != "" then
      del(.[$e.idempotency_key])
    else . end)
  | to_entries | map(.value) | sort_by(.ts)
')

if [ "$FORMAT" = "json" ]; then
  printf '%s' "$active_json" | jq -c '.[]'
  exit 0
fi

printf '%s' "$active_json" | jq -r '
  .[] | if (.task // "") == "" then .action_hint else "[\(.task)] \(.action_hint)" end
'
