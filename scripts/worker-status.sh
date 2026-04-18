#!/usr/bin/env bash
# worker-status.sh — one-shot report of all Achilles worker panes.
set -uo pipefail
ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.claude/achilles-inbox}"
[ -d "$ROOT" ] || { echo "no inbox root: $ROOT"; exit 0; }

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
count() { find "$1" -maxdepth 1 -name '*.task' 2>/dev/null | wc -l | tr -d ' '; }
now=$(date +%s)

printf "%-10s %-6s %-5s %-5s %-5s %-14s %s\n" WORKER STATE PEND DONE RESC HEARTBEAT CURRENT
shopt -s nullglob
found=0
for d in "$ROOT"/worker-*/; do
  found=1
  N=$(basename "$d" | sed 's/worker-//')
  if [ -f "$d/alive" ]; then
    age=$(( now - $(mtime "$d/alive") ))
    if [ "$age" -lt 180 ]; then hb="alive(${age}s)"; else hb="DEAD(${age}s)"; fi
  else
    hb="never"
  fi
  busy=$(cat "$d/busy" 2>/dev/null || true)
  state=$([ -n "$busy" ] && echo busy || echo idle)
  printf "%-10s %-6s %-5s %-5s %-5s %-14s %s\n" \
    "worker-$N" "$state" "$(count "$d/inbox")" "$(count "$d/done")" "$(count "$d/rescue")" "$hb" "${busy:--}"
done
[ "$found" = "1" ] || echo "(no worker-* dirs under $ROOT — start one with: scripts/achilles-worker.sh 1)"
