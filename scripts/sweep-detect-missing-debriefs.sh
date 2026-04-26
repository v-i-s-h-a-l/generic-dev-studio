#!/usr/bin/env bash
# sweep-detect-missing-debriefs.sh — Step 0E0 of the inbox sweep.
#
# Detects the merge-without-debrief contract violation #249 was filed for.
# Scans `task_merged` events from today + yesterday's logs; for each one
# whose paired debrief never landed under `plans/debriefs/`, emits a
# `debrief_missing` event. Idempotent per `(task, merge_sha)` — re-runs
# never duplicate.
#
# Catches the dark window between Step 9 (`task-merge.sh` emits
# `task_merged`) and Step 10 (`task-emit-debrief.sh` writes the YAML +
# emits `debrief_emitted`) when a session crashes mid-flight, plus any
# `task_merged` produced by a manual session that bypassed Step 10.
#
# Stale window: a `task_merged` event younger than 600s is skipped — Step
# 10 may still be running. Only sufficiently-aged events qualify, so the
# normal pipeline never trips a false positive.
#
# Phase 1 of #249 — observability. Phase 2 flips the pipeline so the
# debrief is staged BEFORE merge and `task-merge.sh` refuses without one;
# tracked separately. See `_shared/contracts/events.md` § `debrief_missing`.
#
# Usage:
#   scripts/sweep-detect-missing-debriefs.sh
#
# Stdout: count of `debrief_missing` events emitted in this run.
# Exit codes:
#   0  ran (count printed; may be 0)
#   1  unexpected internal error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

PROJECT=$(resolve_project 2>/dev/null) || { printf '0\n'; exit 0; }

command -v jq >/dev/null 2>&1 || { printf '0\n'; exit 0; }

STALE_WINDOW_S="${STUDIO_DEBRIEF_MISSING_STALE_S:-600}"

# Convert RFC3339 UTC ts (e.g. 2026-04-27T14:23:11Z) to epoch seconds.
# Linux: `date -d`, macOS: `date -j -f`. Returns "" on parse failure so
# the caller can skip rather than emit a corrupt age_s.
ts_to_epoch() {
  local ts="$1" out
  out=$(date -u -d "$ts" +%s 2>/dev/null) && { printf '%s' "$out"; return 0; }
  out=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) && { printf '%s' "$out"; return 0; }
  return 1
}

# Walk plans/debriefs/*.yaml once; build a set of legacy_task_id values
# that have a staged debrief (any state). We match against this set, so
# re-runs are O(N debriefs + M task_merged events), not the cross-product.
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")
debriefs_with_legacy=""
if [ -n "$DEBRIEFS_DIR" ] && [ -d "$DEBRIEFS_DIR" ] && command -v yq >/dev/null 2>&1; then
  for yaml in "$DEBRIEFS_DIR"/*.yaml; do
    [ -f "$yaml" ] || continue
    legacy=$(yq -r '.legacy_task_id // ""' "$yaml" 2>/dev/null)
    [ -n "$legacy" ] && [ "$legacy" != "null" ] && debriefs_with_legacy="$debriefs_with_legacy
$legacy"
  done
fi

has_debrief_for_task() {
  local task="$1"
  case "$debriefs_with_legacy" in
    *"
$task
"*) return 0 ;;
    *"
$task") return 0 ;;
  esac
  return 1
}

# Per-(task, merge_sha) idempotency: scan today + yesterday's events for
# any prior `debrief_missing` with the same pair. One emit per pair, ever
# (within the 2-day visibility window — older `task_merged` events would
# need a longer window if we ever extend, but day-partitioned logs keep
# the scan cheap).
EVENT_LOG_TODAY=$(resolve_event_log 2>/dev/null || echo "")
EVENTS_DIR=$(resolve_events_dir 2>/dev/null || echo "")
yesterday=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null \
  || date -u -v-1d +%Y-%m-%d 2>/dev/null \
  || echo "")
EVENT_LOG_YESTERDAY=""
[ -n "$EVENTS_DIR" ] && [ -n "$yesterday" ] && EVENT_LOG_YESTERDAY="$EVENTS_DIR/$yesterday.jsonl"

already_emitted() {
  local task="$1" merge_sha="$2"
  local pat="\"event\":\"debrief_missing\""
  for log in "$EVENT_LOG_TODAY" "$EVENT_LOG_YESTERDAY"; do
    [ -n "$log" ] && [ -f "$log" ] || continue
    grep -F "$pat" "$log" 2>/dev/null \
      | jq -c --arg task "$task" --arg sha "$merge_sha" \
          'select(.task == $task and (.data.merge_sha // "") == $sha)' 2>/dev/null \
      | grep -q . && return 0
  done
  return 1
}

now_s=$(date -u +%s)
emitted=0

# Iterate task_merged events from today + yesterday. Newest first isn't
# required — idempotency is keyed, not order-sensitive.
for log in "$EVENT_LOG_TODAY" "$EVENT_LOG_YESTERDAY"; do
  [ -n "$log" ] && [ -f "$log" ] || continue

  # jq filter is the cheap gate; per-row Bash logic only runs on candidates.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts=$(printf '%s' "$line" | jq -r '.ts // ""' 2>/dev/null)
    task=$(printf '%s' "$line" | jq -r '.task // ""' 2>/dev/null)
    merge_sha=$(printf '%s' "$line" | jq -r '.data.merge_sha // ""' 2>/dev/null)
    branch=$(printf '%s' "$line" | jq -r '.data.branch // ""' 2>/dev/null)

    [ -z "$task" ] || [ -z "$merge_sha" ] && continue

    ts_epoch=$(ts_to_epoch "$ts") || continue
    age_s=$(( now_s - ts_epoch ))
    [ "$age_s" -lt "$STALE_WINDOW_S" ] && continue

    has_debrief_for_task "$task" && continue
    already_emitted "$task" "$merge_sha" && continue

    data=$(printf '{"merge_sha":"%s","source_branch":"%s","age_s":%s}' \
      "$merge_sha" "$branch" "$age_s")
    if emit_event_keyed chanakya inbox-sweep debrief_missing "$task" "$data" >/dev/null 2>&1; then
      emitted=$(( emitted + 1 ))
    fi
  done < <(jq -c 'select(.event == "task_merged")' "$log" 2>/dev/null)
done

printf '%s\n' "$emitted"
exit 0
