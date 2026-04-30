#!/usr/bin/env bash
# sweep-process-events.sh [--offset-file <path>]
#
# Step 0E — event-log handler fan-out. Replaces the mode-pack's event-table
# prose with an executable dispatcher. Reads new events since the stored
# offset, fires one action per event, updates the offset atomically.
#
# This script emits no new events itself (pure orchestration). Handlers can
# spawn further work (achilles-queue drain, push-queue appends, follow-up
# task minting), which is where visible side effects originate.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-sweep-timing.sh
. "$SCRIPT_DIR/lib-sweep-timing.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
STATE_DIR="$PROJECT_ROOT/.runtime/state"
OFFSET_FILE="$STATE_DIR/events_offset"
sweep_timing_start

while [ $# -gt 0 ]; do
  case "$1" in
    --offset-file) OFFSET_FILE="${2:?--offset-file requires a path}"; shift 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR" 2>/dev/null || true

EVENT_LOG=$(resolve_event_log 2>/dev/null) || exit 0
[ -f "$EVENT_LOG" ] || exit 0
TODAY=$(basename "$EVENT_LOG" .jsonl)

# Offset file format: single line `<YYYY-MM-DD>.jsonl:<bytes>`. Day-rollover
# resets offset to 0 — day-partitioned logs mean a new file starts fresh.
offset=0
if [ -f "$OFFSET_FILE" ]; then
  entry=$(head -n 1 "$OFFSET_FILE" 2>/dev/null)
  prev_date=${entry%%.jsonl:*}
  prev_bytes=${entry##*:}
  if [ "$prev_date" = "$TODAY" ]; then
    case "$prev_bytes" in
      ''|*[!0-9]*) offset=0 ;;
      *) offset=$prev_bytes ;;
    esac
  fi
fi

current_size=$(stat -f %z "$EVENT_LOG" 2>/dev/null || stat -c %s "$EVENT_LOG" 2>/dev/null || echo 0)
if [ "$offset" -ge "$current_size" ]; then
  # Nothing new; rewrite the offset so the timestamp ladder records activity.
  sweep_timing_emit process-events noop 0
  final_size=$(stat -f %z "$EVENT_LOG" 2>/dev/null || stat -c %s "$EVENT_LOG" 2>/dev/null || echo 0)
  tmp="$OFFSET_FILE.tmp.$$"
  printf '%s.jsonl:%s\n' "$TODAY" "$final_size" > "$tmp" && mv "$tmp" "$OFFSET_FILE" || rm -f "$tmp"
  exit 0
fi

# Read from the stored byte offset to EOF. `tail -c +N` counts from 1.
new_events=$(tail -c "+$(( offset + 1 ))" "$EVENT_LOG" 2>/dev/null)
new_event_count=$(printf '%s\n' "$new_events" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')

# Dispatch table per event name. Multiple events fall through to the same
# action (`achilles-queue drain`) because any one of them frees a worker
# slot; see the inbox-sweep event-handler table for the rationale.
drain_queue() {
  if [ -x "$SCRIPT_DIR/achilles-queue.sh" ]; then
    "$SCRIPT_DIR/achilles-queue.sh" drain >/dev/null 2>&1 || true
  fi
}

push_append() {
  # kind task text — fan out to push-queue append.
  "$SCRIPT_DIR/push-queue.sh" append --kind "$1" --task "$2" --text "$3" >/dev/null 2>&1 || true
}

# Persist drift log lines under state/. A mkdir + touch handles the
# fresh-project case without an explicit bootstrap step.
DRIFT_LOG="$STATE_DIR/drift-log.jsonl"
touch "$DRIFT_LOG" 2>/dev/null || true

# Track per-review finding indices seen in this run so re-entrancy (two
# review_flagged events in the same batch) doesn't mint duplicate followups.
# Cross-run idempotency relies on re-scanning plans/tasks for the marker.
printf '%s\n' "$new_events" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Extract event + task + data.review_id/findings cheaply via jq when
  # available; fall back to sed for minimal environments.
  if command -v jq >/dev/null 2>&1; then
    event=$(printf '%s' "$line" | jq -r '.event // empty' 2>/dev/null)
    task=$(printf '%s' "$line" | jq -r '.task // ""' 2>/dev/null)
  else
    event=$(printf '%s' "$line" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
    task=$(printf '%s' "$line" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')
  fi
  [ -z "$event" ] && continue

  case "$event" in
    task_completed|debrief_ingested|brief_failed|merge_conflict|task_awaiting_user|task_rescued)
      drain_queue
      ;;
  esac

  case "$event" in
    review_blocked)
      # review_blocked additionally drains (handled above implicitly? no —
      # we enumerated explicitly in the drain list above). Push the block
      # reason for visibility on the next status pass.
      drain_queue
      reason=""
      if command -v jq >/dev/null 2>&1; then
        reason=$(printf '%s' "$line" | jq -r '.data.block_reason // .data.reason // "review_blocked"' 2>/dev/null)
      else
        reason="review_blocked"
      fi
      push_append review_blocked "$task" "$reason"
      ;;
    review_flagged)
      # Mint one follow-up task per finding. Idempotency: scan plans/tasks
      # for tasks whose description references `source_review=<review_id>`
      # + the finding index. Skip if already minted.
      if command -v jq >/dev/null 2>&1; then
        review_id=$(printf '%s' "$line" | jq -r '.data.review_file // .data.review_id // ""' 2>/dev/null)
        finding_count=$(printf '%s' "$line" | jq -r '.data.findings | length // 0' 2>/dev/null)
        [ -z "$finding_count" ] || [ "$finding_count" = "null" ] && finding_count=0
        i=0
        while [ "$i" -lt "$finding_count" ]; do
          finding=$(printf '%s' "$line" | jq -r --argjson idx "$i" '.data.findings[$idx] // ""' 2>/dev/null)
          # Minimal existence check — grep tasks dir for the review+index marker.
          tasks_dir=$(resolve_tasks_dir_for "$PROJECT" 2>/dev/null || echo "")
          already=0
          if [ -n "$tasks_dir" ] && [ -d "$tasks_dir" ]; then
            if grep -lF "source_review: \"$review_id\"" "$tasks_dir"/*.yaml 2>/dev/null \
                | xargs grep -lF "finding_index: $i" 2>/dev/null | head -1 >/dev/null 2>&1; then
              already=1
            fi
          fi
          if [ "$already" = "0" ]; then
            new_uuid=$(mint_uuidv7)
            # Keep title short — finding text may be long; embed in notes via k=v.
            title="Follow-up: $(printf '%s' "$finding" | cut -c1-80)"
            write_task_artifact "$new_uuid" proposed "$title" \
              type=review-followup priority=P2 \
              "source_review=$review_id" "finding_index=$i" >/dev/null 2>&1 || true
          fi
          i=$(( i + 1 ))
        done
      fi
      ;;
    appstore_watch_stuck)
      reason="watcher_stuck"
      if command -v jq >/dev/null 2>&1; then
        reason=$(printf '%s' "$line" | jq -r '.data.reason // "watcher_stuck"' 2>/dev/null)
      fi
      push_append appstore_stuck "$task" "$reason"
      ;;
    dual_write_partial)
      # Fan out to both the push queue (so the user sees it) and the drift
      # log (so post-hoc analysis has the raw event preserved).
      push_append drift "$task" "dual_write_partial"
      printf '%s\n' "$line" >> "$DRIFT_LOG" 2>/dev/null || true
      ;;
    debrief_missing)
      # #249 Phase 1 — surface the merge-without-debrief gap. Body carries
      # the merge_sha so the operator can locate the merge commit; the task
      # id flows through the standard `task` column.
      merge_sha=""
      if command -v jq >/dev/null 2>&1; then
        merge_sha=$(printf '%s' "$line" | jq -r '.data.merge_sha // ""' 2>/dev/null)
      fi
      push_append debrief_missing "$task" "merged at ${merge_sha:-<unknown>} with no debrief"
      ;;
    review_pending)
      merge_sha=""
      if command -v jq >/dev/null 2>&1; then
        merge_sha=$(printf '%s' "$line" | jq -r '.data.merge_sha // ""' 2>/dev/null)
      fi
      push_append review_pending "$task" "merged without Argus${merge_sha:+ at $merge_sha}"
      ;;
    direct_main_ungated_merge)
      merged_into=""
      if command -v jq >/dev/null 2>&1; then
        merged_into=$(printf '%s' "$line" | jq -r '.data.merged_into // ""' 2>/dev/null)
      fi
      push_append ungated_merge "$task" "merged into protected branch ${merged_into:-<unknown>} without review evidence"
      ;;
    debrief_concerns)
      push_append debrief_concerns "$task" "completed with concerns recorded in debrief"
      ;;
    debrief_needs_context)
      push_append debrief_needs_context "$task" "needs context before redispatch"
      ;;
    follow_up_mint_failed)
      push_append follow_up_mint_failed "$task" "structured follow-up could not be minted"
      ;;
    argus_gate_skipped)
      # Auto-file a GitHub issue for infra-broken skip reasons (#244).
      # Operational reasons (verdict_timeout, no_verdict_at_merge) are no-ops here.
      if command -v jq >/dev/null 2>&1; then
        ags_reason=$(printf '%s' "$line" | jq -r '.data.reason // ""' 2>/dev/null)
        ags_host=$(printf '%s' "$line" | jq -r '.data.host // "unknown"' 2>/dev/null)
        ags_idem=$(printf '%s' "$line" | jq -r '.data.idem_key // ""' 2>/dev/null)
        case "$ags_reason" in
          unknown_host|missing_manifest|missing_spawn_command|secret_scope_floor_unmet)
            ags_title="Argus infra-failure: ${ags_reason} on ${ags_host}"
            existing=""
            if command -v gh >/dev/null 2>&1; then
              existing=$(gh issue list --label bug --state open --limit 100 \
                --json number,title 2>/dev/null \
                | jq -r --arg t "$ags_title" '.[] | select(.title == $t) | .number' 2>/dev/null \
                | head -1)
            fi
            if [ -n "$existing" ]; then
              gh issue comment "$existing" \
                --body "Repeat occurrence at $(date -u +%Y-%m-%dT%H:%M:%SZ). idem_key: \`${ags_idem}\`" \
                >/dev/null 2>&1 \
                || printf 'warn: could not comment on #%s for argus infra-failure\n' "$existing"
            else
              ags_body=$(printf '**reason:** `%s`\n**host:** `%s`\n**idem_key:** `%s`\n\nAuto-filed by inbox sweep on %s.' \
                "$ags_reason" "$ags_host" "$ags_idem" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
              gh issue create \
                --label "bug" --label "theme/internal" \
                --title "$ags_title" \
                --body "$ags_body" \
                >/dev/null 2>&1 \
                || printf 'warn: could not file issue for argus infra-failure: %s on %s\n' "$ags_reason" "$ags_host"
            fi
            ;;
        esac
      fi
      ;;
    test_run_failed|build_debt_incremented)
      # No direct action — Chanakya surfaces these via status summaries.
      :
      ;;
  esac
done

sweep_timing_emit process-events completed "$new_event_count"

# Update offset atomically. New size is the current filesize, not the one we
# cached upfront — a writer may have appended mid-run. O_APPEND semantics
# mean we never miss events, only delay their processing to the next sweep.
final_size=$(stat -f %z "$EVENT_LOG" 2>/dev/null || stat -c %s "$EVENT_LOG" 2>/dev/null || echo 0)
tmp="$OFFSET_FILE.tmp.$$"
printf '%s.jsonl:%s\n' "$TODAY" "$final_size" > "$tmp" && mv "$tmp" "$OFFSET_FILE" || rm -f "$tmp"

exit 0
