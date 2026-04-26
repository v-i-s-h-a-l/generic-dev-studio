#!/usr/bin/env bash
# backfill-orphan-debriefs.sh — detect orphan debriefs (DEGRADED post-#245 A.4).
#
# An orphan debrief is a YAML debrief with `state in {done, ingested}` whose
# task has NO corresponding `### <legacy_task_id>` section in
# plans/chanakya-master.md. These are the debriefs the sweep silently missed
# — once `state != emitted`, Step 0A's filter skips them on every subsequent
# run and the master plan stays stale forever.
#
# DEGRADED MODE (post-#245 A.4): the master-plan is now a rendered projection
# from plans/tasks/*.yaml — back-filling rows directly into the markdown is no
# longer meaningful. The legacy_master_plan_append_row helper this script
# called was retired in #245 A.5; --apply mode currently no-ops (detection
# still works as a diagnostic). A YAML-shaped rewrite is tracked as a
# follow-up issue.
#
# Two entry points:
#   1. Fix F (one-shot recovery): user invokes manually once to recover
#      pre-existing orphans. Dry-run by default.
#   2. Fix B (sweep integration): inbox-sweep.md calls with --apply after
#      Step 0A to catch double-miss silently on every run.
#
# Usage:
#   scripts/backfill-orphan-debriefs.sh                 # dry-run: list orphans, no writes
#   scripts/backfill-orphan-debriefs.sh --apply         # back-fill master plan
#   scripts/backfill-orphan-debriefs.sh --apply --quiet # sweep integration (summary stdout only)
#
# Exit codes:
#   0  success (orphan count printed to stdout on last line when --quiet)
#   2  resolution error
#
# Output (human mode): one line per orphan, then summary.
# Output (--quiet):    single line `<orphan_count>` (backfilled) on stdout.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

APPLY=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  APPLY=1;  shift ;;
    --quiet)  QUIET=1;  shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'backfill-orphan-debriefs.sh: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Post-#245 A.4 caveat: --apply currently no-ops (legacy helper retired). Detect
# mode is still useful as a diagnostic. Surface the caveat once on --apply runs.
if [ "$APPLY" = "1" ] && [ "$QUIET" = "0" ]; then
  printf 'backfill-orphan-debriefs: --apply is currently a no-op (legacy_master_plan_append_row retired in #245 A.5). Detection prints orphans for diagnostic use; YAML-shaped backfill is a follow-up.\n' >&2
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'backfill: no project resolved\n' >&2; exit 2; }
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
MASTER="$PROJECT_ROOT/plans/chanakya-master.md"
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT" 2>/dev/null || echo "")

log() { [ "$QUIET" = "1" ] || printf '%s\n' "$*" >&2; }

if [ -z "$DEBRIEFS_DIR" ] || [ ! -d "$DEBRIEFS_DIR" ]; then
  log "backfill: no debriefs dir at $DEBRIEFS_DIR (nothing to do)"
  [ "$QUIET" = "1" ] && printf '0\n'
  exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  log "backfill: yq required for orphan detection; skipping"
  [ "$QUIET" = "1" ] && printf '0\n'
  exit 0
fi
if [ ! -f "$MASTER" ]; then
  log "backfill: no master plan at $MASTER (nothing to back-fill)"
  [ "$QUIET" = "1" ] && printf '0\n'
  exit 0
fi

orphan_count=0
backfilled_count=0

for yaml in "$DEBRIEFS_DIR"/*.yaml; do
  [ -f "$yaml" ] || continue

  state=$(yq -r '.state // "emitted"' "$yaml" 2>/dev/null || echo emitted)
  # Only consider debriefs whose task-side ingestion has nominally happened.
  # `emitted` is Step 0A's job; we're catching what Step 0A already processed
  # but that never landed on the master plan.
  case "$state" in
    done|ingested) ;;
    *) continue ;;
  esac

  mode=$(yq -r '.mode // "task"' "$yaml" 2>/dev/null || echo task)
  # Direct-debriefs (mode: direct-debrief, no task_id) don't own a master-plan
  # row — skip them. Only task-mode debriefs should land in chanakya-master.md.
  [ "$mode" = "task" ] || continue

  legacy_id=$(yq -r '.legacy_task_id // ""' "$yaml" 2>/dev/null)
  [ "$legacy_id" = "null" ] && legacy_id=""
  task_uuid=$(yq -r '.task_id // ""' "$yaml" 2>/dev/null)
  [ "$task_uuid" = "null" ] && task_uuid=""

  # Need a legacy id to key the master-plan section.
  if [ -z "$legacy_id" ] && [ -n "$task_uuid" ]; then
    TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT" 2>/dev/null || echo "")
    if [ -n "$TASKS_DIR" ] && [ -f "$TASKS_DIR/$task_uuid.yaml" ]; then
      legacy_id=$(yq -r '.legacy_task_id // ""' "$TASKS_DIR/$task_uuid.yaml" 2>/dev/null)
      [ "$legacy_id" = "null" ] && legacy_id=""
    fi
  fi

  # No legacy id = no master-plan section to key on; skip quietly.
  [ -n "$legacy_id" ] || continue

  # Fast-path: master plan already has a section for this id → not orphan.
  if grep -q "^### $legacy_id " "$MASTER" 2>/dev/null || grep -q "^### $legacy_id$" "$MASTER" 2>/dev/null; then
    continue
  fi

  # Extract fields for back-fill. Fall back to sensible defaults where missing.
  title=$(yq -r '.title // .brief_title // ""' "$yaml" 2>/dev/null)
  [ "$title" = "null" ] && title=""
  [ -z "$title" ] && title="(back-filled from debrief — title unknown)"

  priority=$(yq -r '.priority // "P2"' "$yaml" 2>/dev/null)
  [ "$priority" = "null" ] && priority="P2"
  type_field=$(yq -r '.type // .task_type // "feature"' "$yaml" 2>/dev/null)
  [ "$type_field" = "null" ] && type_field="feature"
  report_state=$(yq -r '.report_state // "done_with_concerns"' "$yaml" 2>/dev/null)
  [ "$report_state" = "null" ] && report_state="done_with_concerns"

  # Map report_state → legacy status label. `done_with_concerns` still counts
  # as `done` from the master-plan's perspective.
  case "$report_state" in
    blocked)       legacy_status="blocked" ;;
    needs_context) legacy_status="needs_brief_rework" ;;
    *)             legacy_status="done" ;;
  esac

  orphan_count=$((orphan_count + 1))
  log "orphan: $legacy_id  (state=$state, report_state=$report_state)  $yaml"

  if [ "$APPLY" = "1" ]; then
    if legacy_master_plan_append_row "$legacy_id" "$title" "$priority" "$type_field" "backfill:debrief" "$legacy_status" 2>/dev/null; then
      backfilled_count=$((backfilled_count + 1))
      # Annotate with merge SHA + concerns/follow-ups count, best-effort.
      merge_sha=$(yq -r '.branch.merge_sha // ""' "$yaml" 2>/dev/null)
      [ "$merge_sha" = "null" ] && merge_sha=""
      concerns_n=$(yq -r '.concerns // [] | length' "$yaml" 2>/dev/null || echo 0)
      follow_ups_n=$(yq -r '.follow_ups // [] | length' "$yaml" 2>/dev/null || echo 0)
      # Append extra bullets under the new section (append at EOF when the
      # section we just created is the last — cheap inline awk).
      if [ -n "$merge_sha" ] || [ "${concerns_n:-0}" -gt 0 ] || [ "${follow_ups_n:-0}" -gt 0 ]; then
        tmp="$MASTER.tmp.$$"
        awk -v id="$legacy_id" -v sha="$merge_sha" -v cn="$concerns_n" -v fn="$follow_ups_n" '
          BEGIN { in_section=0; annotated=0 }
          /^### / {
            if (in_section && !annotated) {
              if (sha != "") print "- **Merge SHA:** " sha
              if (cn+0 > 0) print "- **Concerns:** " cn
              if (fn+0 > 0) print "- **Follow-ups:** " fn
              annotated=1
            }
            if ($2 == id) in_section=1; else in_section=0
            print; next
          }
          /^## / {
            if (in_section && !annotated) {
              if (sha != "") print "- **Merge SHA:** " sha
              if (cn+0 > 0) print "- **Concerns:** " cn
              if (fn+0 > 0) print "- **Follow-ups:** " fn
              annotated=1
            }
            in_section=0
            print; next
          }
          { print }
          END {
            if (in_section && !annotated) {
              if (sha != "") print "- **Merge SHA:** " sha
              if (cn+0 > 0) print "- **Concerns:** " cn
              if (fn+0 > 0) print "- **Follow-ups:** " fn
            }
          }
        ' "$MASTER" > "$tmp" 2>/dev/null && mv "$tmp" "$MASTER" || rm -f "$tmp"
      fi

      # Emit an event so the back-fill is visible in the event stream.
      data=$(printf '{"legacy_task_id":"%s","source":"orphan_backfill","report_state":"%s"}' \
        "$legacy_id" "$report_state")
      emit_event_keyed chanakya inbox-sweep debrief_backfilled "$legacy_id" "$data" >/dev/null 2>&1 || true
    else
      log "  backfill failed for $legacy_id"
    fi
  fi
done

if [ "$QUIET" = "1" ]; then
  # Machine-readable single-line summary: count of rows actually back-filled.
  printf '%d\n' "$backfilled_count"
else
  if [ "$APPLY" = "1" ]; then
    log "orphan-backfill: $backfilled_count/$orphan_count rows back-filled into $MASTER"
  else
    log "orphan-backfill: $orphan_count orphans detected (dry-run). Re-run with --apply to back-fill."
  fi
fi

exit 0
