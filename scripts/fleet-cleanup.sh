#!/usr/bin/env bash
# fleet-cleanup.sh [--dry-run] [--all] [--root <path>]
#
# Cleans up Achilles fleet artifacts. Two intensities:
#   default : soft sweep — stale .lock dirs (no live PID), stale `busy` markers
#             (heartbeat >180s), done/ files >7 days, rotate worker.log >5MB.
#   --all   : nuke every worker-N/ dir under the inbox root (only safe when
#             every worker pane has exited — refuses if any heartbeat <180s).
#
# Run automatically? Each worker already self-cleans its .lock + busy on exit
# and prunes its own done/ on boot. This script is for between-session sweeps,
# crashed-worker recovery, and full teardown.

set -uo pipefail
DRY=0; ALL=0
ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.dev-studio/.runtime/achilles-inbox}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --all)     ALL=1 ;;
    --root)    ROOT="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$ROOT" ] || { echo "no inbox root: $ROOT (nothing to clean)"; exit 0; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
do_or_say() { if [ "$DRY" = "1" ]; then echo "  [dry-run] $*"; else eval "$*"; fi; }
now=$(date +%s)

# --- --all: full teardown ---
if [ "$ALL" = "1" ]; then
  shopt -s nullglob
  for d in "$ROOT"/worker-*/; do
    if [ -f "$d/alive" ]; then
      age=$(( now - $(mtime "$d/alive") ))
      if [ "$age" -lt 180 ]; then
        echo "REFUSING --all: $(basename "$d") still alive (heartbeat ${age}s)" >&2
        echo "stop the worker pane first, or omit --all for a soft sweep" >&2
        exit 1
      fi
    fi
  done
  for d in "$ROOT"/worker-*/; do
    do_or_say "rm -rf '$d'"
  done
  echo "fleet teardown complete"
  exit 0
fi

# --- soft sweep ---
shopt -s nullglob
removed_locks=0; removed_busy=0; removed_done=0; rotated_logs=0
for d in "$ROOT"/worker-*/; do
  name=$(basename "$d")

  # 1. stale .lock — owner PID dead, OR no alive heartbeat in 180s
  if [ -d "$d/.lock" ]; then
    owner=$(cat "$d/.lock/owner" 2>/dev/null || true)
    stale=0
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then stale=1; fi
    if [ -f "$d/alive" ]; then
      age=$(( now - $(mtime "$d/alive") ))
      [ "$age" -gt 180 ] && stale=1
    elif [ -z "$owner" ]; then
      stale=1
    fi
    if [ "$stale" = "1" ]; then
      do_or_say "rm -rf '$d/.lock'"
      removed_locks=$((removed_locks+1))
      echo "  $name: cleared stale .lock (owner=${owner:-?})"
    fi
  fi

  # 2. stale busy marker (no live worker)
  if [ -f "$d/busy" ] && [ ! -d "$d/.lock" ]; then
    do_or_say "rm -f '$d/busy'"
    removed_busy=$((removed_busy+1))
    echo "  $name: cleared orphaned busy marker"
  fi

  # 3. done/ older than 7 days
  count=$(find "$d/done" -name '*.task' -mtime +7 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    do_or_say "find '$d/done' -name '*.task' -mtime +7 -delete"
    removed_done=$((removed_done+count))
    echo "  $name: pruned $count old done/ files"
  fi

  # 4. rotate worker.log >5MB
  if [ -f "$d/worker.log" ]; then
    size=$(wc -c < "$d/worker.log" | tr -d ' ')
    if [ "$size" -gt 5242880 ]; then
      do_or_say "mv '$d/worker.log' '$d/worker.log.1' && : > '$d/worker.log'"
      rotated_logs=$((rotated_logs+1))
      echo "  $name: rotated worker.log (${size} bytes -> .1)"
    fi
  fi
done

echo "soft sweep: cleared $removed_locks locks, $removed_busy busy, $removed_done done files, rotated $rotated_logs logs"
[ "$DRY" = "1" ] && echo "(dry-run — no changes written)"
