#!/usr/bin/env bash
# detect-edits.sh [--quiet]
#
# Sweep-time blind-spot detector (#20 → Step 0E3). Scans the current project
# for two signals not directly observable from other agents:
#
#   brief_edited   — brief file mtime moved past the last task_dispatched ts,
#                    and no task_completed has closed the task.
#   debrief_edited — debrief mtime moved past the stashed first-seen mtime;
#                    signals a user correction after Chanakya filed it.
#
# Post-Phase-2.6 canonical layout:
#   briefs:   plans/briefs/<brief-id>.yaml  (look up brief-id by task-id via
#             plans/index.yaml — see scripts/query-plans.sh --kind=brief)
#   debriefs: plans/debriefs/<debrief-id>.yaml
#
# Legacy fallback: if plans/index.yaml is absent the project hasn't migrated
# yet — scan the pre-2.6 plans/chanakya-tasks/ + chanakya-inbox/processed/
# paths, and emit one `legacy_artifact_read` event per sweep per domain so
# the transition is observable.
#
# Markers live in `<project-memory>/`:
#   brief_edit_seen.txt   — one-task-id-per-line; prevents dupe brief_edited emits.
#   debrief_seen.txt      — `<filename> <epoch>` per line; first-seen mtime per debrief.
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
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
PLANS_INDEX="$PROJECT_ROOT/plans/index.yaml"
BRIEFS_DIR_NEW="$PROJECT_ROOT/plans/briefs"
DEBRIEFS_DIR_NEW="$PROJECT_ROOT/plans/debriefs"
BRIEF_MARKER="$MEMORY/brief_edit_seen.txt"
DEBRIEF_MARKER="$MEMORY/debrief_seen.txt"

mkdir -p "$MEMORY" 2>/dev/null || true
touch "$BRIEF_MARKER" "$DEBRIEF_MARKER"

brief_emits=0
debrief_emits=0

# Look up a brief YAML file for a given task-id. Prefers plans/index.yaml
# (post-2.6). Returns a full path, or empty string if none found.
#
# Indicates fallback usage via the BRIEF_USED_LEGACY global (set to 1 on
# fallback so the caller can emit legacy_artifact_read exactly once).
BRIEF_USED_LEGACY=0
BRIEF_LEGACY_REASON=""
resolve_brief_for_task() {
  local task="$1" id brief
  if [ -f "$PLANS_INDEX" ] && command -v yq >/dev/null 2>&1; then
    # Preferred path: yq query against index.yaml.
    id=$(yq eval ".briefs[] | select(.task_id == \"$task\") | .id" "$PLANS_INDEX" 2>/dev/null | head -n 1)
    if [ -n "$id" ] && [ "$id" != "null" ]; then
      brief="$BRIEFS_DIR_NEW/$id.yaml"
      [ -f "$brief" ] && { printf '%s\n' "$brief"; return 0; }
    fi
    # Index present but no match — not a legacy read; just return empty.
    return 1
  fi
  # Legacy fallback: index absent (pre-migration) or yq missing.
  BRIEF_USED_LEGACY=1
  if [ ! -f "$PLANS_INDEX" ]; then
    BRIEF_LEGACY_REASON="plans_index_missing"
  else
    BRIEF_LEGACY_REASON="yq_unavailable"
  fi
  local legacy_dir="$PROJECT_ROOT/plans/chanakya-tasks"
  [ -d "$legacy_dir" ] || return 1
  for candidate in "$legacy_dir/$task"-*.md; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# brief_edited
# -----------------------------------------------------------------------------
# Walk recent event logs to find the most recent task_dispatched ts per task,
# and skip any task that also has a task_completed.

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

  brief_legacy_emitted=0
  while IFS= read -r line; do
    task=$(printf '%s' "$line" | awk '{print $1}')
    dispatched_ts=$(printf '%s' "$line" | awk '{print $2}')
    [ -n "$task" ] || continue
    # Skip if completed
    grep -qx "$task" "$COMPLETED_SET" 2>/dev/null && continue
    # Skip if already emitted
    grep -qx "$task" "$BRIEF_MARKER" 2>/dev/null && continue
    # Resolve brief file via index (or legacy fallback).
    BRIEF_USED_LEGACY=0
    brief=$(resolve_brief_for_task "$task") || brief=""
    if [ "$BRIEF_USED_LEGACY" = "1" ] && [ "$brief_legacy_emitted" = "0" ]; then
      # One marker event per sweep per domain — observable transition signal.
      append_event chanakya legacy_artifact_read "" \
        "{\"domain\":\"briefs\",\"reason\":\"${BRIEF_LEGACY_REASON}\",\"caller\":\"detect-edits.sh\"}" \
        2>/dev/null || true
      brief_legacy_emitted=1
    fi
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

# -----------------------------------------------------------------------------
# debrief_edited
# -----------------------------------------------------------------------------
# First-seen mtime is stashed. Subsequent mtime > stashed → user edit.
#
# Post-2.6 canonical source: plans/debriefs/*.yaml. The marker file keys
# entries by filename — legacy `<task>-debrief.md` and new `<uuid>.yaml`
# are disjoint by construction, so the marker works across both shapes
# without a schema bump.

scan_debriefs() {
  local dir="$1" pattern="$2" taskid_mode="$3"
  # taskid_mode: "filename" (legacy: task = basename sans -debrief.md)
  #              "yaml"     (new: read `task_id:` scalar out of the YAML)
  [ -d "$dir" ] || return 1
  local debrief fname current_mt stashed task age_s
  # `find` instead of glob expansion for zsh-portability (R5). -maxdepth 1
  # keeps the scan flat — legacy `processed/` and new `debriefs/` are both
  # single-directory shapes.
  while IFS= read -r debrief; do
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
      if [ "$taskid_mode" = "yaml" ]; then
        task=$(awk '/^task_id:[[:space:]]*/{sub(/^task_id:[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$debrief" 2>/dev/null)
      else
        task=$(printf '%s' "$fname" | sed -n 's/\(.*\)-debrief\.md$/\1/p')
      fi
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
  done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null)
}

if [ -d "$DEBRIEFS_DIR_NEW" ]; then
  scan_debriefs "$DEBRIEFS_DIR_NEW" "*.yaml" "yaml" || true
else
  # Legacy-only project: emit one marker event, then scan the old location.
  legacy_inbox="$PROJECT_ROOT/plans/chanakya-inbox/processed"
  if [ -d "$legacy_inbox" ]; then
    append_event chanakya legacy_artifact_read "" \
      "{\"domain\":\"debriefs\",\"reason\":\"plans_debriefs_missing\",\"caller\":\"detect-edits.sh\"}" \
      2>/dev/null || true
    scan_debriefs "$legacy_inbox" "*-debrief.md" "filename" || true
  fi
fi

log "detect-edits: brief_edited=$brief_emits debrief_edited=$debrief_emits"
