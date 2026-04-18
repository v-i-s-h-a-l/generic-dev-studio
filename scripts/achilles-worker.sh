#!/usr/bin/env bash
# achilles-worker.sh <N>
#
# Long-running worker pane. Watches ~/.claude/achilles-inbox/worker-<N>/inbox/
# for *.task files and spawns `claude -p "/achilles <task-id> <flags>"` per task.
#
# Env:
#   ACHILLES_INBOX_ROOT       default: $HOME/.claude/achilles-inbox
#   ACHILLES_TASK_TIMEOUT_SEC default: 2700  (45 min; needs gtimeout — `brew install coreutils`)
#   ACHILLES_UNATTENDED       set to 1 to pass --dangerously-skip-permissions to claude
#
# Deps: fswatch (brew install fswatch). claude CLI on PATH. gtimeout optional.

set -uo pipefail

N="${1:?usage: achilles-worker.sh <N>}"
ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.claude/achilles-inbox}"
DIR="$ROOT/worker-$N"
LOG="$DIR/worker.log"
TIMEOUT_SEC="${ACHILLES_TASK_TIMEOUT_SEC:-2700}"
PERM_FLAG=""
[ "${ACHILLES_UNATTENDED:-0}" = "1" ] && PERM_FLAG="--dangerously-skip-permissions"

mkdir -p "$DIR/inbox" "$DIR/done" "$DIR/rescue"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker-$N $*" | tee -a "$LOG"; }

command -v fswatch >/dev/null || { log "fswatch not installed (brew install fswatch)"; exit 1; }
command -v claude  >/dev/null || { log "claude CLI not on PATH"; exit 1; }
TIMEOUT_BIN=""
command -v gtimeout >/dev/null && TIMEOUT_BIN="gtimeout"

# heartbeat
( while true; do touch "$DIR/alive"; sleep 60; done ) &
HEARTBEAT_PID=$!

cleanup() {
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  rm -f "$DIR/busy"
  log "shutdown"
}
trap cleanup EXIT INT TERM

process_task() {
  local task_file="$1"
  [ -f "$task_file" ] || return 0
  local base task_id flags rc
  base=$(basename "$task_file")
  task_id=$(awk -F= '/^task_id=/{print $2; exit}' "$task_file")
  flags=$(awk  '/^flags=/{sub(/^flags=/,""); print; exit}' "$task_file")
  if [ -z "$task_id" ]; then
    log "skip $base (no task_id) -> rescue/"
    mv "$task_file" "$DIR/rescue/"
    return 0
  fi

  echo "$task_id" > "$DIR/busy"
  log "start $task_id (flags='$flags')"

  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT_SEC" -gt 0 ]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SEC" claude -p "/achilles $task_id $flags" $PERM_FLAG >> "$LOG" 2>&1
    rc=$?
  else
    claude -p "/achilles $task_id $flags" $PERM_FLAG >> "$LOG" 2>&1
    rc=$?
  fi
  rm -f "$DIR/busy"

  if [ "$rc" -eq 124 ]; then
    log "timeout $task_id after ${TIMEOUT_SEC}s -> rescue/"
    mv "$task_file" "$DIR/rescue/$base"
  else
    mv "$task_file" "$DIR/done/$base"
    log "done $task_id (rc=$rc)"
  fi
}

# Drain anything already pending in inbox at startup (e.g. dispatched while
# worker was offline). Rescue/ is left alone — operator decides when to retry.
shopt -s nullglob
for f in "$DIR/inbox"/*.task; do process_task "$f"; done
shopt -u nullglob

log "watching $DIR/inbox (timeout=${TIMEOUT_SEC}s, unattended=${ACHILLES_UNATTENDED:-0})"
fswatch -0 --event Created --event MovedTo "$DIR/inbox" | while IFS= read -r -d '' path; do
  case "$path" in
    *.task) process_task "$path" ;;
  esac
done
