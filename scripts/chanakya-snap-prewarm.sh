#!/usr/bin/env bash
# chanakya-snap-prewarm.sh — SessionStart wrapper around chanakya-snap.sh.
#
# Runs `chanakya-snap.sh all` in the background so the next /chanakya
# invocation hits fresh snapshots instead of a cold fallback. Silent on
# success, silent on failure — all output goes to a per-project log under
# .runtime/logs/. Exits immediately; the snap producer completes out of
# band.
#
# Gated on:
#   1. Project resolves (we're inside a git repo).
#   2. ~/.dev-studio/<project>/ exists (Chanakya is configured for this repo).
#   3. Not already running (stale-pid check via marker file).
#
# Wired from .claude/settings.json SessionStart hook.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || exit 0

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")

# Gate: Chanakya is only configured for a project if its runtime dir exists.
# Absent = new / uninitialized project; nothing to pre-warm.
[ -d "$PROJECT_ROOT" ] || exit 0

LOG_DIR="$PROJECT_ROOT/.runtime/logs"
LOCK_FILE="$PROJECT_ROOT/.runtime/state/snap-prewarm.pid"
mkdir -p "$LOG_DIR" "$(dirname "$LOCK_FILE")" 2>/dev/null || exit 0

LOG_FILE="$LOG_DIR/snap-prewarm.log"

# Singleton guard. If a prior prewarm is still running, skip — one in-flight
# refresh is enough. Stale pid (process gone) clears the lock.
if [ -f "$LOCK_FILE" ]; then
  prior_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$prior_pid" ] && kill -0 "$prior_pid" 2>/dev/null; then
    exit 0
  fi
  rm -f "$LOCK_FILE" 2>/dev/null || true
fi

# Launch detached. Parent exits immediately so session start does not block.
# The child writes its pid to the lock, runs snap, clears the lock on exit.
(
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
  SNAP_CALLER=prewarm bash "$SCRIPT_DIR/chanakya-snap.sh" all >> "$LOG_FILE" 2>&1
) </dev/null >/dev/null 2>&1 &

exit 0
