#!/usr/bin/env bash
# achilles-worker.sh [N]
#
# Long-running worker pane. Watches ~/.dev-studio/.runtime/achilles-inbox/worker-<N>/inbox/
# for *.task files and spawns `claude -p "/achilles <task-id> <flags>"` per task.
#
# With no arg: atomically claims the lowest free slot (1..ACHILLES_MAX_SLOTS).
# Designed for iTerm "Broadcast Input" — type the same command in N panes
# and each pane picks its own slot, registers heartbeat, tells the manager.
#
# Env:
#   ACHILLES_INBOX_ROOT       default: $HOME/.dev-studio/.runtime/achilles-inbox
#   ACHILLES_MAX_SLOTS        default: 16  (upper bound for auto-claim scan)
#   ACHILLES_TASK_TIMEOUT_SEC default: 2700  (45 min; needs gtimeout — `brew install coreutils`)
#   ACHILLES_UNATTENDED       set to 1 to pass --dangerously-skip-permissions to claude
#
# Deps: fswatch (brew install fswatch). claude CLI on PATH. gtimeout optional.

set -uo pipefail

ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.dev-studio/.runtime/achilles-inbox}"
MAX_SLOTS="${ACHILLES_MAX_SLOTS:-16}"
HEARTBEAT_MAX=180
TIMEOUT_SEC="${ACHILLES_TASK_TIMEOUT_SEC:-2700}"
PERM_FLAG=""
[ "${ACHILLES_UNATTENDED:-0}" = "1" ] && PERM_FLAG="--dangerously-skip-permissions"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

verify_owner() {
  # After mkdir .lock, write our PID and verify after a brief settle
  # window — if a racing reclaimer clobbered our lock and re-mkdir'd,
  # owner won't match $$ and we back off.
  local d="$1"
  echo "$$" > "$d/.lock/owner" 2>/dev/null || return 1
  sleep 0.3
  local recorded
  recorded=$(cat "$d/.lock/owner" 2>/dev/null || true)
  [ "$recorded" = "$$" ]
}

claim_slot() {
  # Atomically claim the lowest free slot via mkdir of a .lock dir.
  # A slot is "free" if its .lock dir doesn't exist OR its alive heartbeat
  # is older than HEARTBEAT_MAX (stale worker — reclaim it).
  local n d
  for n in $(seq 1 "$MAX_SLOTS"); do
    d="$ROOT/worker-$n"
    mkdir -p "$d/inbox" "$d/done" "$d/rescue"
    if mkdir "$d/.lock" 2>/dev/null; then
      verify_owner "$d" || { rm -rf "$d/.lock"; continue; }
      echo "$n"; return 0
    fi
    # .lock exists — check if the holder is dead
    if [ -f "$d/alive" ]; then
      local age=$(( $(date +%s) - $(mtime "$d/alive") ))
      if [ "$age" -gt "$HEARTBEAT_MAX" ]; then
        rm -rf "$d/.lock" 2>/dev/null
        if mkdir "$d/.lock" 2>/dev/null; then
          if verify_owner "$d"; then
            rm -f "$d/busy"
            echo "$n"; return 0
          fi
          rm -rf "$d/.lock"
        fi
      fi
    fi
  done
  return 1
}

# Boot-time housekeeping: prune done/ files older than 7 days (per-worker).
sweep_done() {
  local d="$1"
  find "$d/done" -name '*.task' -mtime +7 -delete 2>/dev/null || true
}

if [ $# -ge 1 ]; then
  N="$1"
  DIR="$ROOT/worker-$N"
  mkdir -p "$DIR/inbox" "$DIR/done" "$DIR/rescue"
  if ! mkdir "$DIR/.lock" 2>/dev/null; then
    echo "worker-$N already locked by another process; refusing" >&2
    exit 1
  fi
else
  N=$(claim_slot) || { echo "no free slot in 1..$MAX_SLOTS" >&2; exit 1; }
  DIR="$ROOT/worker-$N"
fi
LOG="$DIR/worker.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] worker-$N $*" | tee -a "$LOG"; }
log "claimed slot $N (pid $$)"
sweep_done "$DIR"

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
  rm -rf "$DIR/.lock"
  log "shutdown — released slot $N"
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
fswatch -0 --event Created --event Updated --event MovedTo --event Renamed "$DIR/inbox" | while IFS= read -r -d '' path; do
  case "$path" in
    *.task)
      [ -e "$path" ] || continue
      # Coalesce duplicate events for the same file (Created+Updated arrives twice)
      sleep 0.05
      [ -e "$path" ] && process_task "$path"
      ;;
  esac
done
