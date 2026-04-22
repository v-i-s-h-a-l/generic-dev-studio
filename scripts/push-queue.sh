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
#   append --kind K --task T --text TXT [--source S]
#                                   Append one JSONL entry (displayed=false).
#
# Shared consumer across status.md (pre-display read + mark) and inbox-sweep
# event handlers (write). Read-only ops don't need write access.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

cmd="${1:-}"
case "$cmd" in
  list|mark-displayed|count|append) ;;
  "") printf 'usage: push-queue.sh <list|mark-displayed|count|append> [args]\n' >&2; exit 2 ;;
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

  append)
    # Caller-facing shape: --kind K --task T --text TXT [--source S]. Sourced
    # from lib-ledger for `mint_uuidv7` + `iso_ts_now` — falls back to an
    # inline generator so the script stays usable in minimal environments.
    kind=""
    task=""
    text=""
    source_agent="chanakya"
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind)   kind="${2:?--kind requires a value}";   shift 2 ;;
        --task)   task="${2:-}";                          shift 2 ;;
        --text)   text="${2:-}";                          shift 2 ;;
        --source) source_agent="${2:-chanakya}";          shift 2 ;;
        *) printf 'append: unknown flag %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [ -n "$kind" ] || { printf 'append: --kind is required\n' >&2; exit 2; }
    [ -n "$text" ] || { printf 'append: --text is required\n' >&2; exit 2; }

    # Prefer the ledger's UUIDv7/timestamp helpers (time-ordered IDs align
    # with the rest of the studio); fall back to a coarse generator when
    # lib-ledger is unavailable so the script isn't wedged on minimal hosts.
    if command -v mint_uuidv7 >/dev/null 2>&1; then
      push_id=$(mint_uuidv7)
    else
      rnd=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo "00000000")
      push_id=$(printf '%s-%s-7%s-a%s-%s' \
        "$(printf '%012x' $(( $(date -u +%s) * 1000 )) | cut -c1-8)" \
        "$(printf '%012x' $(( $(date -u +%s) * 1000 )) | cut -c9-12)" \
        "${rnd:0:3}" "${rnd:3:3}" "${rnd:6:12}")
    fi
    if command -v iso_ts_now >/dev/null 2>&1; then
      ts=$(iso_ts_now)
    else
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi

    mkdir -p "$(dirname "$QUEUE")" 2>/dev/null || true
    # JSON-escape text + task so embedded quotes/backslashes don't break
    # jq readers downstream. Kind and source are constrained by callers.
    esc_text=${text//\\/\\\\}
    esc_text=${esc_text//\"/\\\"}
    esc_text=${esc_text//$'\n'/\\n}
    esc_task=${task//\\/\\\\}
    esc_task=${esc_task//\"/\\\"}
    printf '{"id":"%s","ts":"%s","source":"%s","kind":"%s","task":"%s","text":"%s","displayed":false}\n' \
      "$push_id" "$ts" "$source_agent" "$kind" "$esc_task" "$esc_text" >> "$QUEUE"
    printf '%s\n' "$push_id"
    ;;
esac
