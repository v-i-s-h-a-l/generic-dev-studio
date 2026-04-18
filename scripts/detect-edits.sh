#!/usr/bin/env bash
# detect-edits.sh [--quiet]
#
# Sweep-time blind-spot detector (#20 → Step 0E3). Scans the current project
# for two signals not directly observable from other agents:
#
#   brief_edited   — brief file mtime moved past the last task_dispatched ts,
#                    and no task_completed has closed the task.
#   debrief_edited — processed debrief mtime moved past the stashed first-seen
#                    mtime; signals a user correction after Chanakya filed it.
#
# Markers live in `<project-memory>/`:
#   brief_edit_seen.txt     — one-filename-per-line; prevents dupe brief_edited emits.
#   debrief_seen.txt        — `<filename> <epoch>` per line; first-seen mtime per debrief.
#
# Compact wipes both so a re-edit after archival can re-emit.
#
# Chanakya runs this during Step 0E3. Called without args; emits events via
# `append_event` in lib-paths.sh. Safe to call repeatedly — idempotent markers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

log() { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }

PROJECT=$(resolve_project) || { log "no project; skipping"; exit 0; }
MEMORY=$(resolve_project_memory) || { log "no project memory; skipping"; exit 0; }
BRIEFS_DIR=$(resolve_briefs_dir)
INBOX_PROCESSED="$(resolve_chanakya_inbox)/processed"
BRIEF_MARKER="$MEMORY/brief_edit_seen.txt"
DEBRIEF_MARKER="$MEMORY/debrief_seen.txt"

mkdir -p "$MEMORY" 2>/dev/null || true
touch "$BRIEF_MARKER" "$DEBRIEF_MARKER"

brief_emits=0
debrief_emits=0

# -----------------------------------------------------------------------------
# brief_edited
# -----------------------------------------------------------------------------
# Walk recent event logs to find the most recent task_dispatched ts per task,
# and skip any task that also has a task_completed.

if [ -d "$BRIEFS_DIR" ]; then
  EVENTS_DIR="$MEMORY/events"
  if [ -d "$EVENTS_DIR" ]; then
    # Newest 14 days of event files (lexicographic on YYYY-MM-DD == date order).
    recent_events=$(ls -r "$EVENTS_DIR"/*.jsonl 2>/dev/null | head -n 14)
    # Map: task → latest dispatched_at ts; task → completed? (1/0)
    # Use two temp files to keep shellcheck + zsh-compatible.
    DISPATCHED_MAP=$(mktemp)
    COMPLETED_SET=$(mktemp)
    trap 'rm -f "$DISPATCHED_MAP" "$COMPLETED_SET"' EXIT

    for f in $recent_events; do
      # task_dispatched: keep the latest ts per task (events are chronological
      # within a file, and we iterate newest-file first — so the *first* match
      # per task is the latest).
      grep '"event":"task_dispatched"' "$f" 2>/dev/null \
        | while IFS= read -r line; do
            task=$(printf '%s' "$line" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')
            ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [ -n "$task" ] || continue
            grep -q "^$task " "$DISPATCHED_MAP" 2>/dev/null && continue
            printf '%s %s\n' "$task" "$ts" >> "$DISPATCHED_MAP"
          done
      grep '"event":"task_completed"' "$f" 2>/dev/null \
        | sed -n 's/.*"task":"\([^"]*\)".*/\1/p' >> "$COMPLETED_SET"
    done

    while IFS= read -r line; do
      task=$(printf '%s' "$line" | awk '{print $1}')
      dispatched_ts=$(printf '%s' "$line" | awk '{print $2}')
      [ -n "$task" ] || continue
      # Skip if completed
      grep -qx "$task" "$COMPLETED_SET" 2>/dev/null && continue
      # Skip if already emitted
      grep -qx "$task" "$BRIEF_MARKER" 2>/dev/null && continue
      # Resolve brief file (slug unknown — glob)
      brief=""
      for candidate in "$BRIEFS_DIR/$task"-*.md; do
        [ -f "$candidate" ] || continue
        brief="$candidate"
        break
      done
      [ -n "$brief" ] || continue
      # Compare mtime vs dispatched_ts
      brief_epoch=$(mtime "$brief" 2>/dev/null || echo 0)
      dispatched_epoch=$(ts_to_epoch "$dispatched_ts")
      [ -z "$dispatched_epoch" ] && continue
      if [ "$brief_epoch" -gt "$dispatched_epoch" ]; then
        age_s=$(( brief_epoch - dispatched_epoch ))
        append_event chanakya brief_edited "$task" \
          "{\"age_s_since_dispatch\":$age_s}" 2>/dev/null || true
        printf '%s\n' "$task" >> "$BRIEF_MARKER"
        brief_emits=$(( brief_emits + 1 ))
        log "brief_edited: $task (brief mtime +${age_s}s past dispatch)"
      fi
    done < "$DISPATCHED_MAP"
  fi
fi

# -----------------------------------------------------------------------------
# debrief_edited
# -----------------------------------------------------------------------------
# First-seen mtime is stashed. Subsequent mtime > stashed → user edit.

if [ -d "$INBOX_PROCESSED" ]; then
  for debrief in "$INBOX_PROCESSED"/*-debrief.md; do
    [ -f "$debrief" ] || continue
    fname=$(basename "$debrief")
    current_mt=$(mtime "$debrief" 2>/dev/null || echo 0)
    stashed=$(grep "^$fname " "$DEBRIEF_MARKER" 2>/dev/null | awk '{print $2}' | tail -n 1)
    if [ -z "$stashed" ]; then
      # First sight — stash and continue; no event.
      printf '%s %s\n' "$fname" "$current_mt" >> "$DEBRIEF_MARKER"
      continue
    fi
    if [ "$current_mt" -gt "$stashed" ]; then
      task=$(printf '%s' "$fname" | sed -n 's/\(.*\)-debrief\.md$/\1/p')
      age_s=$(( current_mt - stashed ))
      append_event chanakya debrief_edited "${task:-unknown}" \
        "{\"age_s_since_process\":$age_s}" 2>/dev/null || true
      # Update the stash so a subsequent edit (later mtime) re-emits.
      grep -v "^$fname " "$DEBRIEF_MARKER" > "$DEBRIEF_MARKER.tmp" 2>/dev/null || true
      mv "$DEBRIEF_MARKER.tmp" "$DEBRIEF_MARKER" 2>/dev/null || true
      printf '%s %s\n' "$fname" "$current_mt" >> "$DEBRIEF_MARKER"
      debrief_emits=$(( debrief_emits + 1 ))
      log "debrief_edited: ${task:-$fname} (+${age_s}s past first-seen)"
    fi
  done
fi

log "detect-edits: brief_edited=$brief_emits debrief_edited=$debrief_emits"
