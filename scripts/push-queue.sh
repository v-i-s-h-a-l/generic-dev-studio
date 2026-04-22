#!/usr/bin/env bash
# push-queue.sh — read + mutate the per-project push queue.
#
# The queue is a JSONL file at `.runtime/state/push-queue.jsonl`. Each line is
# one entry; the `displayed` field (true|false) gates whether status mode
# surfaces it.
#
# Subcommands:
#   list [--unread-only]            Print entries (default: unread only).
#   mark-displayed <id> [<id>...]   Mark entries by `id` field as displayed.
#   count                           Print count of unread entries.
#
# Shared consumer across status.md (pre-display read + mark) and inbox-sweep
# event handlers (write). Read-only ops don't need write access.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

cmd="${1:-}"
case "$cmd" in
  list|mark-displayed|count) ;;
  "") printf 'usage: push-queue.sh <list|mark-displayed|count> [args]\n' >&2; exit 2 ;;
  *)  printf 'unknown subcommand: %s\n' "$cmd" >&2; exit 2 ;;
esac
shift

QUEUE=$(resolve_push_queue 2>/dev/null) || { printf 'push-queue: cannot resolve project\n' >&2; exit 2; }

case "$cmd" in
  list)
    local_unread_only=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --unread-only) local_unread_only=1; shift ;;
        --all)         local_unread_only=0; shift ;;
        *)             printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [ -f "$QUEUE" ] || exit 0
    if [ "$local_unread_only" -eq 1 ]; then
      jq -c 'select(.displayed != true)' "$QUEUE" 2>/dev/null
    else
      cat "$QUEUE"
    fi
    ;;

  count)
    [ -f "$QUEUE" ] || { printf '0\n'; exit 0; }
    jq -c 'select(.displayed != true)' "$QUEUE" 2>/dev/null | wc -l | tr -d ' '
    ;;

  mark-displayed)
    [ $# -ge 1 ] || { printf 'mark-displayed: at least one <id> required\n' >&2; exit 2; }
    [ -f "$QUEUE" ] || exit 0
    # Build a jq select filter matching any of the supplied IDs, then rewrite
    # the file in one pass: each matching line gets displayed=true, others pass
    # through unchanged. Atomic tmp+mv protects concurrent readers.
    local_ids_json="["
    local_first=1
    for id in "$@"; do
      esc=${id//\"/\\\"}
      if [ "$local_first" -eq 1 ]; then local_first=0; else local_ids_json+=","; fi
      local_ids_json+='"'"$esc"'"'
    done
    local_ids_json+="]"
    tmp="$QUEUE.tmp.$$"
    jq -c --argjson ids "$local_ids_json" '
      if (.id as $i | $ids | index($i)) then .displayed = true else . end
    ' "$QUEUE" > "$tmp" || { rm -f "$tmp"; exit 2; }
    mv "$tmp" "$QUEUE"
    ;;
esac
