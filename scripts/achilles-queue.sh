#!/usr/bin/env bash
# achilles-queue.sh <subcommand> [args...]
#
# Work-stealing dispatch queue. Chanakya enqueues tasks; `drain` hands them
# out one-by-one to free workers (busy=0 AND pending=0) as they become
# available. Replaces upfront fan-out — slow tasks no longer starve fast
# ones of parallelism.
#
# Subcommands:
#   enqueue <task-id> [-- <flags>]   append to queue (no-op if already queued)
#   drain                            dispatch head-of-queue to each free worker
#   list                             print current queue (stdin-safe)
#   clear                            wipe the queue (for abort / debugging)
#   depth                            print queue depth (integer)
#
# Cross-project one-off: ACHILLES_PROJECT=<slug> achilles-queue.sh ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

QUEUE=$(resolve_dispatch_queue) || exit 1
mkdir -p "$(dirname "$QUEUE")"
touch "$QUEUE"

HEARTBEAT_MAX=180

is_alive() {
  local d="$1"
  [ -f "$d/alive" ] || return 1
  local age=$(( $(date +%s) - $(mtime "$d/alive") ))
  [ "$age" -lt "$HEARTBEAT_MAX" ]
}

count_pending() {
  find "$1/inbox" -maxdepth 1 -name '*.task' 2>/dev/null | wc -l | tr -d ' '
}

# A worker is free iff alive, busy=0, pending=0. Prints the slot number (N)
# of the first free worker found, or empty if none.
pick_free_worker() {
  local root="$1"
  local d N busy pending
  for d in "$root"/worker-*/; do
    [ -d "$d" ] || continue
    is_alive "$d" || continue
    busy=0; [ -f "$d/busy" ] && busy=1
    pending=$(count_pending "$d")
    if [ "$busy" = "0" ] && [ "$pending" = "0" ]; then
      N=$(basename "$d" | sed 's/worker-//')
      printf '%s\n' "$N"
      return 0
    fi
  done
  return 1
}

queue_depth() {
  grep -c '^{' "$QUEUE" 2>/dev/null | tr -d ' ' || echo 0
}

sub="${1:-}"
shift || true

case "$sub" in
  enqueue)
    TASK_ID="${1:?usage: enqueue <task-id> [-- <flags>]}"
    shift || true
    [ "${1:-}" = "--" ] && shift
    FLAGS="${*:-}"
    (
      flock -x 9 2>/dev/null || true
      if grep -q "\"task\":\"$TASK_ID\"" "$QUEUE" 2>/dev/null; then
        echo "already queued: $TASK_ID" >&2
        exit 0
      fi
      TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf '{"task":"%s","flags":"%s","enqueued_at":"%s"}\n' \
        "$TASK_ID" "$FLAGS" "$TS" >> "$QUEUE"
      echo "queued $TASK_ID (depth=$(queue_depth))"
    ) 9>"$QUEUE.lock"
    ;;

  drain)
    ROOT=$(resolve_inbox_root) || exit 1
    [ -d "$ROOT" ] || { echo "no inbox root at $ROOT" >&2; exit 0; }
    dispatched=0
    while :; do
      rc=0
      (
        flock -x 9 2>/dev/null || true
        [ -s "$QUEUE" ] || exit 10
        N=$(pick_free_worker "$ROOT") || exit 11
        head_line=$(head -n 1 "$QUEUE")
        [ -n "$head_line" ] || exit 10
        # Parse task + flags out of the JSONL head. Keep it regex-light to
        # avoid a jq dependency in the dispatch hot path.
        task=$(printf '%s' "$head_line" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')
        flags=$(printf '%s' "$head_line" | sed -n 's/.*"flags":"\([^"]*\)".*/\1/p')
        [ -n "$task" ] || exit 10
        # Pop head atomically.
        tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
        if [ -n "$flags" ]; then
          "$SCRIPT_DIR/achilles-dispatch.sh" "$task" "worker-$N" -- $flags
        else
          "$SCRIPT_DIR/achilles-dispatch.sh" "$task" "worker-$N"
        fi
      ) 9>"$QUEUE.lock" || rc=$?
      if [ "$rc" -eq 10 ] || [ "$rc" -eq 11 ]; then break; fi
      if [ "$rc" -ne 0 ]; then
        echo "drain: dispatch failed (rc=$rc)" >&2
        exit "$rc"
      fi
      dispatched=$(( dispatched + 1 ))
    done
    echo "drained $dispatched (depth=$(queue_depth))"
    ;;

  list)
    if [ ! -s "$QUEUE" ]; then
      echo "(queue empty)"
    else
      cat "$QUEUE"
    fi
    ;;

  depth)
    queue_depth
    ;;

  clear)
    : > "$QUEUE"
    echo "queue cleared"
    ;;

  ""|-h|--help)
    sed -n '2,17p' "$0"
    ;;

  *)
    echo "unknown subcommand: $sub" >&2
    sed -n '2,17p' "$0" >&2
    exit 2
    ;;
esac
