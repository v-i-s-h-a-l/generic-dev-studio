#!/usr/bin/env bash
# achilles-worker.sh [N]
#
# Long-running worker pane. Watches the current project's fleet inbox at
# ~/.dev-studio/<project>/.runtime/achilles-inbox/worker-<N>/inbox/ for *.task
# files and spawns `claude -p "/achilles <task-id> <flags>"` per task.
#
# Project resolved via lib-paths.sh: ACHILLES_PROJECT env > git toplevel basename.
# Cross-project: ACHILLES_PROJECT=<slug> achilles-worker.sh
#
# With no arg: atomically claims the lowest free slot (1..ACHILLES_MAX_SLOTS).
# Designed for iTerm "Broadcast Input" — type the same command in N panes
# and each pane picks its own slot, registers heartbeat, tells the manager.
#
# Env:
#   ACHILLES_PROJECT          override project slug (otherwise: git basename)
#   ACHILLES_INBOX_ROOT       explicit override (bypasses project resolution)
#   ACHILLES_MAX_SLOTS        default: 16  (upper bound for auto-claim scan)
#   ACHILLES_TASK_TIMEOUT_SEC default: 2700  (45 min; needs gtimeout — `brew install coreutils`)
#   ACHILLES_UNATTENDED       set to 1 to pass --dangerously-skip-permissions to claude
#   ACHILLES_AUTONOMOUS       set to 1 by the worker for every claude -p subprocess;
#                             tells Achilles to prefer obvious-default + debrief-note
#                             over asking the user (there is no user to answer in a
#                             one-shot subagent). Exported automatically — do not set
#                             manually unless you know what you're doing.
#
# Deps: fswatch (brew install fswatch). claude CLI on PATH. gtimeout optional.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

# Resolve project once, then build ROOT from it — avoids a second git fork.
# If ACHILLES_INBOX_ROOT is set, resolve_project may not apply; fall back.
if [ -n "${ACHILLES_INBOX_ROOT:-}" ]; then
  ROOT="$ACHILLES_INBOX_ROOT"
  PROJECT=$(resolve_project 2>/dev/null || echo "(override)")
else
  PROJECT=$(resolve_project) || exit 1
  ROOT=$(resolve_inbox_root_for "$PROJECT")
fi
MAX_SLOTS="${ACHILLES_MAX_SLOTS:-16}"
HEARTBEAT_MAX=180
TIMEOUT_SEC="${ACHILLES_TASK_TIMEOUT_SEC:-2700}"
PERM_FLAG=""
[ "${ACHILLES_UNATTENDED:-0}" = "1" ] && PERM_FLAG="--dangerously-skip-permissions"

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

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $PROJECT:worker-$N $*" | tee -a "$LOG"; }

# Set terminal pane title for at-a-glance visibility under iTerm/tmux.
# Uses OSC 0 escape — no-op on dumb terminals.
set_pane_title() {
  local title="$1"
  printf '\033]0;%s\007' "$title" 2>/dev/null || true
}
set_pane_title "$PROJECT:worker-$N"

log "claimed slot $N (pid $$) project=$PROJECT root=$ROOT"
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

  # ACHILLES_AUTONOMOUS=1 tells Achilles this invocation has no user to answer
  # questions (one-shot claude -p). Pair with the silent-stuck detector below:
  # autonomous reduces how often a task exits without a debrief in the first
  # place; the detector is the backstop for when a default truly can't be chosen.
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT_SEC" -gt 0 ]; then
    ACHILLES_AUTONOMOUS=1 "$TIMEOUT_BIN" "$TIMEOUT_SEC" claude -p "/achilles $task_id $flags" $PERM_FLAG >> "$LOG" 2>&1
    rc=$?
  else
    ACHILLES_AUTONOMOUS=1 claude -p "/achilles $task_id $flags" $PERM_FLAG >> "$LOG" 2>&1
    rc=$?
  fi
  rm -f "$DIR/busy"

  # claude -p stdout is fully redirected to $LOG, so rc=0 alone cannot
  # distinguish a completed task from a subagent that exited after asking
  # a clarifying question. Echoing the tail makes both outcomes visible
  # in the pane without relying on a separate tail -f.
  printf '────── %s output (tail) ──────\n' "$task_id"
  tail -n 40 "$LOG" 2>/dev/null || true
  printf '──────────────────────────────────\n'

  local debrief="$(resolve_chanakya_inbox_for "$PROJECT")/$task_id-debrief.md"
  local debrief_exists=0
  [ -f "$debrief" ] && debrief_exists=1

  if [ "$rc" -eq 124 ]; then
    log "timeout $task_id after ${TIMEOUT_SEC}s -> rescue/ (debrief=$debrief_exists)"
    mv "$task_file" "$DIR/rescue/$base"
    append_event achilles task_rescued "$task_id" \
      "{\"reason\":\"timeout\",\"timeout_s\":$TIMEOUT_SEC,\"debrief_written\":$debrief_exists,\"worker\":\"worker-$N\"}" \
      2>/dev/null || true
  elif [ "$rc" -eq 0 ] && [ "$debrief_exists" = "0" ]; then
    # Silent-stuck: subagent exited cleanly but wrote no debrief. Almost
    # always means it asked a clarifying question and the one-shot process
    # closed before an answer could arrive. Surface as stuck — operator
    # decides the next step — instead of letting the slot look completed.
    local stuck="$DIR/rescue/$task_id-stuck.md"
    {
      printf 'task_id=%s\n' "$task_id"
      printf 'flags=%s\n' "$flags"
      printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'rc=%s\n' "$rc"
      printf 'reason=no-debrief-written\n'
      printf '\n---- log tail (last 200 lines) ----\n'
      tail -n 200 "$LOG" 2>/dev/null || true
    } > "$stuck"
    mv "$task_file" "$DIR/rescue/$base"
    log "STUCK $task_id (rc=0 debrief=0) -> rescue/ (see $task_id-stuck.md)"
    append_event achilles task_rescued "$task_id" \
      "{\"reason\":\"silent_stuck\",\"rc\":0,\"debrief_written\":0,\"worker\":\"worker-$N\"}" \
      2>/dev/null || true
  else
    mv "$task_file" "$DIR/done/$base"
    log "done $task_id (rc=$rc debrief=$debrief_exists)"
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
