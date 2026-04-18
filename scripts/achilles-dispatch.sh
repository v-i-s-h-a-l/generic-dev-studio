#!/usr/bin/env bash
# achilles-dispatch.sh <task-id> [worker-N|any] [-- <flags...>]
#
# Writes a task file into a worker's inbox. With "any" (default) picks the
# alive worker with the lowest current load (busy-flag + pending-count).
#
# Examples:
#   achilles-dispatch.sh T001
#   achilles-dispatch.sh T002 worker-3
#   achilles-dispatch.sh T004 any -- --wait --force-build

set -euo pipefail

TASK_ID="${1:?usage: achilles-dispatch.sh <task-id> [worker-N|any] [-- <flags>]}"
TARGET="${2:-any}"
shift || true
[ "${1:-}" != "" ] && shift || true
[ "${1:-}" = "--" ] && shift
FLAGS="${*:-}"

ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.dev-studio/.runtime/achilles-inbox}"
HEARTBEAT_MAX=180

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

is_alive() {
  local d="$1"
  [ -f "$d/alive" ] || return 1
  local age=$(( $(date +%s) - $(mtime "$d/alive") ))
  [ "$age" -lt "$HEARTBEAT_MAX" ]
}

count_pending() {
  find "$1/inbox" -maxdepth 1 -name '*.task' 2>/dev/null | wc -l | tr -d ' '
}

pick_worker() {
  local best="" best_load=999
  shopt -s nullglob
  for d in "$ROOT"/worker-*/; do
    is_alive "$d" || continue
    local n=$(basename "$d" | sed 's/worker-//')
    local busy=0; [ -f "$d/busy" ] && busy=1
    local pending=$(count_pending "$d")
    local load=$(( busy + pending ))
    if [ "$load" -lt "$best_load" ]; then
      best_load=$load; best="$n"
    fi
  done
  shopt -u nullglob
  [ -n "$best" ] || { echo "no alive workers under $ROOT" >&2; exit 1; }
  echo "$best"
}

if [ "$TARGET" = "any" ]; then
  N=$(pick_worker)
else
  N="${TARGET#worker-}"
fi

DIR="$ROOT/worker-$N"
mkdir -p "$DIR/inbox"
is_alive "$DIR" || { echo "worker-$N is not alive (no recent heartbeat)" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
FILE="$DIR/inbox/${STAMP}-${TASK_ID}.task"
{
  echo "task_id=$TASK_ID"
  echo "flags=$FLAGS"
  echo "dispatched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "dispatched_from=${USER:-unknown}@${HOSTNAME:-$(hostname)}"
} > "$FILE.tmp"
mv "$FILE.tmp" "$FILE"
echo "dispatched $TASK_ID -> worker-$N"
echo "  $FILE"
