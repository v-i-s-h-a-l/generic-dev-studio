#!/usr/bin/env bash
# worker-status.sh [--all-projects]
#
# Default: one-shot report of the current project's fleet.
# --all-projects: iterate every project under ~/.dev-studio/ that has a fleet.
# Cross-project one-off: ACHILLES_PROJECT=<slug> worker-status.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all-projects|-a) ALL=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

count() { find "$1" -maxdepth 1 -name '*.task' 2>/dev/null | wc -l | tr -d ' '; }
now=$(date +%s)

print_fleet() {
  local root="$1" label="$2"
  if [ ! -d "$root" ]; then
    echo "$label: no inbox root ($root)"
    return 0
  fi
  echo ""
  echo "== $label =="
  printf "%-10s %-6s %-5s %-5s %-5s %-14s %s\n" WORKER STATE PEND DONE RESC HEARTBEAT CURRENT
  shopt -s nullglob
  local found=0
  for d in "$root"/worker-*/; do
    found=1
    local N hb age busy state
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
  shopt -u nullglob
  [ "$found" = "1" ] || echo "(no worker-* dirs; launch one with /achilles worker or scripts/achilles-worker.sh)"
}

if [ "$ALL" = "1" ]; then
  found_any=0
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    found_any=1
    print_fleet "$(resolve_inbox_root_for "$project")" "$project"
  done < <(list_fleet_projects)
  [ "$found_any" = "1" ] || echo "(no fleets found under ~/.dev-studio/*/.runtime/achilles-inbox)"
else
  root=$(resolve_inbox_root) || exit 1
  project=$(resolve_project 2>/dev/null || echo "(override)")
  print_fleet "$root" "$project"
fi
