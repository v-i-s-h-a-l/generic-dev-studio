#!/usr/bin/env bash
# argus-emit-verdict.sh — Step 7 of the Argus pipeline (+ Step 8 stdout line).
#
# Writes the YAML review artifact via `write_review_artifact`, compensates for
# the stubbed `legacy_review_write_markdown` helper by writing the legacy
# markdown directly, appends the review to the parent task's `links.reviews`
# via `append_task_link`, emits the verdict event (handled inside
# write_review_artifact), appends to the push queue on block, manages result-
# bundle retention on flag, and prints the Step-8 machine-parseable verdict
# line on stdout.
#
# Usage:
#   scripts/argus-emit-verdict.sh <task-id> <verdict> <findings-json> \
#     [--task-uuid <uuid>] [--review-file-legacy <path>] [--block-reason <str>]
#
# Exit codes:
#   0  verdict recorded
#   2  missing args, task-uuid resolution failed, or unknown verdict
#   3  dual-write partial failure (propagated from lib-ledger)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: argus-emit-verdict.sh <task-id> <verdict> <findings-json> [flags]}"
VERDICT="${2:?verdict required (approved|flagged|blocked)}"
FINDINGS_JSON="${3:-[]}"
shift 3

case "$VERDICT" in
  approved|flagged|blocked) ;;
  *) printf 'error: unknown verdict %s (want approved|flagged|blocked)\n' "$VERDICT" >&2; exit 2 ;;
esac

TASK_UUID=""
LEGACY_PATH_OVERRIDE=""
BLOCK_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task-uuid)          TASK_UUID="${2:?}";            shift 2 ;;
    --review-file-legacy) LEGACY_PATH_OVERRIDE="${2:?}"; shift 2 ;;
    --block-reason)       BLOCK_REASON="${2:?}";         shift 2 ;;
    *) printf 'error: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }

# Resolve task UUID. Explicit --task-uuid wins; otherwise scan plans/tasks/
# for the legacy_task_id match. The scan is cheap (O(tasks)) and runs once
# per verdict — no index lookup warranted for Phase 2.6.5.
if [ -z "$TASK_UUID" ]; then
  tasks_dir=$(resolve_tasks_dir_for "$PROJECT")
  if [ -d "$tasks_dir" ]; then
    TASK_UUID=$(grep -l "^legacy_task_id: \"$TASK_ID\"$" "$tasks_dir"/*.yaml 2>/dev/null \
      | head -1 \
      | xargs -I{} basename {} .yaml 2>/dev/null)
  fi
  if [ -z "$TASK_UUID" ]; then
    printf 'error: cannot resolve task UUID for legacy id %s; pass --task-uuid explicitly\n' "$TASK_ID" >&2
    exit 2
  fi
fi

REVIEW_ID=$(mint_uuidv7)

# Primary write: YAML artifact + verdict event. lib-ledger attempts the
# legacy dual-write via the stubbed helper (returns 9, swallowed via `|| true`
# inside write_review_artifact).
write_review_artifact "$REVIEW_ID" task "$TASK_UUID" "$VERDICT" "$FINDINGS_JSON"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
  # rc=3 is `dual_write_partial` and is expected here because the legacy
  # helper is stubbed. Any other nonzero is a real failure.
  printf 'error: write_review_artifact failed rc=%s\n' "$rc" >&2
  exit "$rc"
fi

# Compensate for the stubbed legacy helper by writing the markdown directly.
# Path: project-memory (pre-2.6 carve-out); not under ~/.dev-studio/. This
# is a one-time compensation until the lib-ledger stub fills in at Commit H.
if [ -n "$LEGACY_PATH_OVERRIDE" ]; then
  LEGACY_REVIEW_FILE="$LEGACY_PATH_OVERRIDE"
else
  PROJECT_MEMORY=$(resolve_project_memory 2>/dev/null || echo "")
  if [ -n "$PROJECT_MEMORY" ]; then
    LEGACY_REVIEW_FILE="$PROJECT_MEMORY/reviews/review_${TASK_ID}.md"
  else
    # No git context; fall back to skipping legacy write. Post-2.6 YAML is
    # the source of truth anyway.
    LEGACY_REVIEW_FILE=""
  fi
fi

if [ -n "$LEGACY_REVIEW_FILE" ]; then
  mkdir -p "$(dirname "$LEGACY_REVIEW_FILE")" 2>/dev/null || true
  finding_count=$(printf '%s' "$FINDINGS_JSON" | jq 'length' 2>/dev/null || echo 0)
  ts=$(iso_ts_now)
  {
    printf '# Argus Review: %s\n' "$TASK_ID"
    printf 'Reviewed: %s\n' "$ts"
    printf 'Verdict: %s\n' "$VERDICT"
    [ -n "$BLOCK_REASON" ] && printf 'Block reason: %s\n' "$BLOCK_REASON"
    printf 'Review UUID: %s\n\n' "$REVIEW_ID"
    printf '## Findings (%s)\n\n' "$finding_count"
    if [ "$finding_count" -gt 0 ]; then
      printf '%s\n' "$FINDINGS_JSON" | jq -r '.[] |
        "### [\(.tier)] \(.rule)\n- **Message:** \(.message)\n- **Path:** \(.path // "—")\n"' 2>/dev/null \
        || printf '(findings JSON not parseable; see YAML artifact %s)\n' "$REVIEW_ID"
    else
      printf '(none)\n'
    fi
    printf '\n---\nJoin key: review_id=%s — see plans/reviews/%s.yaml\n' "$REVIEW_ID" "$REVIEW_ID"
  } > "$LEGACY_REVIEW_FILE" 2>/dev/null || true
fi

# Back-reference: append review-id to the task's links.reviews array.
# Bidirectional consistency enforced by contracts/plans-index-validator.md.
append_task_link "$TASK_UUID" reviews "$REVIEW_ID" || {
  printf 'warn: append_task_link reviews failed for task %s\n' "$TASK_UUID" >&2
}

case "$VERDICT" in
  approved)
    # Approve path retention: delete the result bundle immediately. It's not
    # useful after a clean approve, and bundles are multi-MB.
    rm -rf "/tmp/argus-${TASK_ID}.xcresult" 2>/dev/null || true
    ;;
  flagged)
    # Flag = success for bundle retention per derived-data.md.
    rm -rf "/tmp/argus-${TASK_ID}.xcresult" 2>/dev/null || true
    ;;
  blocked)
    # Block: retain bundle 48h; cleanup-policy handles the sweep. Also push.
    QUEUE=$(resolve_push_queue 2>/dev/null || echo "")
    if [ -n "$QUEUE" ]; then
      mkdir -p "$(dirname "$QUEUE")" 2>/dev/null || true
      push_id=$(mint_uuidv7)
      ts=$(iso_ts_now)
      reason_short="$BLOCK_REASON"
      [ -z "$reason_short" ] && reason_short="Review blocked"
      # JSON-escape the reason for safe embedding.
      reason_esc=${reason_short//\\/\\\\}
      reason_esc=${reason_esc//\"/\\\"}
      printf '{"id":"%s","ts":"%s","source":"argus","kind":"review_blocked","task":"%s","text":"%s","displayed":false}\n' \
        "$push_id" "$ts" "$TASK_ID" "$reason_esc" >> "$QUEUE"
    fi
    ;;
esac

# Remove the running marker. The trap registered by argus-setup.sh will also
# clean this up on exit, but removing it now lets status.md see the review
# as complete before the outer shell terminates.
rm -f "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)/.argus-running" 2>/dev/null || true

# Step 8 — stdout contract. Achilles parses this line.
case "$VERDICT" in
  approved)
    printf 'ARGUS_VERDICT=approved review_file=%s findings=%s\n' "${LEGACY_REVIEW_FILE:-}" "${finding_count:-0}"
    ;;
  flagged)
    printf 'ARGUS_VERDICT=flagged review_file=%s findings=%s\n' "${LEGACY_REVIEW_FILE:-}" "${finding_count:-0}"
    ;;
  blocked)
    printf 'ARGUS_VERDICT=blocked block_reason="%s" review_file=%s\n' "${BLOCK_REASON:-}" "${LEGACY_REVIEW_FILE:-}"
    ;;
esac
