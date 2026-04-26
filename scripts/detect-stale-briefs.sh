#!/usr/bin/env bash
# detect-stale-briefs.sh — find briefed tasks aged past threshold and emit
# `suggestion_emitted{kind:stale_brief}` events (idempotent via suggestion-emit).
#
# Usage:
#   scripts/detect-stale-briefs.sh [--days N]   default 7
#
# Stdout: one summary line — `stale_briefs: <count> (<emitted>) emitted`.
# Idempotency comes from suggestion-emit.sh: re-running on the same precondition
# is a no-op until the suggestion is resolved.
#
# Exit codes:
#   0  succeeded (regardless of count)
#   2  underlying tooling missing / query failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:-7}"; shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) printf 'detect-stale-briefs: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { printf 'detect-stale-briefs: jq required\n' >&2; exit 2; }

rows=$("$SCRIPT_DIR/query-tasks.sh" --state=briefed --state-age-gt="$DAYS" --format=json 2>/dev/null) || {
  printf 'detect-stale-briefs: query-tasks failed\n' >&2; exit 2
}

# Augment each row with computed state_age_days from history_at.
augmented=$(printf '%s' "$rows" | jq -c '
  map(. + {state_age_days: (((now - (.history_at | fromdateiso8601)) / 86400) | floor)})
')

count=$(printf '%s' "$augmented" | jq 'length')
emitted=0
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$augmented" | jq -c ".[$i]")
  id=$(printf '%s' "$row"    | jq -r '.id // ""')
  title=$(printf '%s' "$row" | jq -r '.title // ""')
  age=$(printf '%s' "$row"   | jq -r '.state_age_days // 0')
  [ -n "$id" ] || { i=$(( i + 1 )); continue; }

  # Bucket the age so a fresh suggestion fires when the task crosses doubling
  # boundaries (7d, 14d, 28d, 56d) — keeps the noise floor stable while still
  # re-surfacing if the task stays parked weeks longer.
  bucket=7
  for b in 56 28 14 7; do
    if [ "$age" -ge "$b" ]; then bucket="$b"; break; fi
  done

  idem="chanakya:suggestion:stale_brief:${id}:${bucket}"
  hint="${id} has been in \`briefed\` for ${age} days — re-brief or downgrade."
  payload=$(jq -nc --arg id "$id" --arg title "$title" --argjson age "$age" \
    '{task_uuid:$id, title:$title, state_age_days:$age}')

  result=$("$SCRIPT_DIR/suggestion-emit.sh" \
    --kind stale_brief \
    --idem-key "$idem" \
    --action-hint "$hint" \
    --payload "$payload" \
    --task "$id" \
    --mode stale 2>/dev/null) || true

  case "$result" in
    emitted) emitted=$(( emitted + 1 )) ;;
  esac
  i=$(( i + 1 ))
done

printf 'stale_briefs: %s (%s emitted)\n' "$count" "$emitted"
