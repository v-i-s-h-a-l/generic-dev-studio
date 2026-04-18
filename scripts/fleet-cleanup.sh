#!/usr/bin/env bash
# fleet-cleanup.sh [--dry-run] [--all] [--all-projects] [--root <path>]
#
# Cleans up Achilles fleet artifacts for the current project.
#
#   default          : soft sweep — stale .lock dirs (no live PID), stale `busy`
#                      markers (heartbeat >180s), done/ files >7 days, rotate
#                      worker.log >5MB.
#   --all            : nuke every worker-N/ dir under the inbox root (only safe
#                      when every worker pane has exited — refuses if any
#                      heartbeat <180s).
#   --all-projects   : iterate every project with a fleet. Combinable with --all
#                      (each project's fleet is individually checked).
#   --root <path>    : explicit inbox root (bypasses project resolution).
#
# Each worker already self-cleans .lock + busy on exit and prunes its own done/
# on boot. This script is for between-session sweeps, crashed-worker recovery,
# and full teardown.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

DRY=0; ALL=0; ALL_PROJECTS=0; ROOT_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)         DRY=1 ;;
    --all)             ALL=1 ;;
    --all-projects|-A) ALL_PROJECTS=1 ;;
    --root)            ROOT_OVERRIDE="$2"; shift ;;
    -h|--help)         sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

do_or_say() { if [ "$DRY" = "1" ]; then echo "  [dry-run] $*"; else eval "$*"; fi; }
now=$(date +%s)

# One-shot machine-global orphan sweep. `rmdir` only succeeds on empty dirs,
# so anything that gets re-populated is protected. Currently just `state/`
# (moved per-project in v0.2.0-beta.1); add more as migrations accumulate.
for orphan in "$HOME/.dev-studio/.runtime/state"; do
  [ -d "$orphan" ] || continue
  if [ "$DRY" = "1" ]; then
    echo "  [dry-run] rmdir '$orphan' (if empty)"
  elif rmdir "$orphan" 2>/dev/null; then
    echo "cleared empty machine-global leftover: $orphan"
  fi
done

sweep_fleet() {
  local ROOT="$1" LABEL="$2"
  [ -d "$ROOT" ] || { echo "$LABEL: no inbox root ($ROOT) — skipping"; return 0; }
  echo "== $LABEL =="

  # --all: teardown
  if [ "$ALL" = "1" ]; then
    shopt -s nullglob
    for d in "$ROOT"/worker-*/; do
      if [ -f "$d/alive" ]; then
        local age=$(( now - $(mtime "$d/alive") ))
        if [ "$age" -lt 180 ]; then
          echo "  REFUSING --all: $(basename "$d") still alive (heartbeat ${age}s)" >&2
          echo "  stop the worker pane first, or omit --all for a soft sweep" >&2
          return 1
        fi
      fi
    done
    for d in "$ROOT"/worker-*/; do
      do_or_say "rm -rf '$d'"
    done
    echo "  fleet teardown complete"
    shopt -u nullglob
    return 0
  fi

  # soft sweep
  shopt -s nullglob
  local removed_locks=0 removed_busy=0 removed_done=0 rotated_logs=0
  for d in "$ROOT"/worker-*/; do
    local name=$(basename "$d")

    if [ -d "$d/.lock" ]; then
      local owner=$(cat "$d/.lock/owner" 2>/dev/null || true)
      local stale=0
      if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then stale=1; fi
      if [ -f "$d/alive" ]; then
        local age=$(( now - $(mtime "$d/alive") ))
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

    if [ -f "$d/busy" ] && [ ! -d "$d/.lock" ]; then
      do_or_say "rm -f '$d/busy'"
      removed_busy=$((removed_busy+1))
      echo "  $name: cleared orphaned busy marker"
    fi

    local count=$(find "$d/done" -name '*.task' -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      do_or_say "find '$d/done' -name '*.task' -mtime +7 -delete"
      removed_done=$((removed_done+count))
      echo "  $name: pruned $count old done/ files"
    fi

    if [ -f "$d/worker.log" ]; then
      local size=$(wc -c < "$d/worker.log" | tr -d ' ')
      if [ "$size" -gt 5242880 ]; then
        do_or_say "mv '$d/worker.log' '$d/worker.log.1' && : > '$d/worker.log'"
        rotated_logs=$((rotated_logs+1))
        echo "  $name: rotated worker.log (${size} bytes -> .1)"
      fi
    fi
  done
  shopt -u nullglob
  echo "  soft sweep: cleared $removed_locks locks, $removed_busy busy, $removed_done done files, rotated $rotated_logs logs"
}

if [ "$ALL_PROJECTS" = "1" ]; then
  [ -n "$ROOT_OVERRIDE" ] && { echo "--all-projects is incompatible with --root" >&2; exit 2; }
  found=0
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    found=1
    sweep_fleet "$(resolve_inbox_root_for "$project")" "$project" || true
  done < <(list_fleet_projects)
  [ "$found" = "1" ] || echo "(no fleets found under ~/.dev-studio/*/.runtime/achilles-inbox)"
else
  if [ -n "$ROOT_OVERRIDE" ]; then
    ROOT="$ROOT_OVERRIDE"; LABEL="(override: $ROOT_OVERRIDE)"
  else
    ROOT=$(resolve_inbox_root) || exit 1
    LABEL=$(resolve_project 2>/dev/null || echo "(override)")
  fi
  sweep_fleet "$ROOT" "$LABEL"
fi

[ "$DRY" = "1" ] && echo "(dry-run — no changes written)"
