#!/usr/bin/env bash
# validate-brief.sh — pre-`ready` brief lint gate (#220 A2-1).
#
# Validates brief-specific constraints beyond summary length and concern-
# inheritance (those live in self-review-brief.sh). Called from
# self-review-brief.sh so callers stay one-line.
#
# Current checks:
#   R-LTID-1 — legacy_task_id required when parent task has one (#296).
#     Prevents Achilles dispatch failure via task-load-spec.sh secondary
#     resolution path. Warns (not blocks) to avoid breaking pre-3.5.0 briefs.
#   R-BUG-1 — reproducer required for bug briefs.
#     When parent task type=bug: brief must have non-empty `reproducer:` YAML
#     field (brief@3.4.0+) OR a non-empty ## Steps to Reproduce section in body.
#     Fails loud if neither is present.
#
# Usage:  scripts/validate-brief.sh <brief.yaml>
# Exit:   0 pass, 1 block-level violation(s), 2 bad args / unreadable brief

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$SCRIPT_DIR/lib-paths.sh"

BRIEF=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'validate-brief: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)  BRIEF="$1"; shift ;;
  esac
done

[ -n "$BRIEF" ] || { printf 'validate-brief: brief path required\n' >&2; exit 2; }
[ -r "$BRIEF" ] || { printf 'validate-brief: cannot read %s\n' "$BRIEF" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf 'validate-brief: yq required\n' >&2; exit 2; }

FAILURES=0
fail() { printf 'validate-brief [BLOCK] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
warn() { printf 'validate-brief [WARN]  %s\n' "$1" >&2; }

# ---------- R-BUG-1 — reproducer required for bug briefs ----------

TASK_ID=$(yq -r '.task_id // ""' "$BRIEF")
BRIEF_TYPE=""
if [ -n "$TASK_ID" ]; then
  TASKS_DIR=$(resolve_tasks_dir_for "$(resolve_project)" 2>/dev/null || true)
  TASK_FILE="${TASKS_DIR}/${TASK_ID}.yaml"
  if [ -r "$TASK_FILE" ]; then
    BRIEF_TYPE=$(yq -r '.type // ""' "$TASK_FILE")
  else
    warn "task file not found at $TASK_FILE; skipping bug-reproducer check"
  fi
fi

# ---------- R-LTID-1 — legacy_task_id required when parent task has one ----------

if [ -n "$TASK_ID" ] && [ -r "${TASKS_DIR}/${TASK_ID}.yaml" ]; then
  TASK_LTID=$(yq -r '.legacy_task_id // ""' "${TASKS_DIR}/${TASK_ID}.yaml")
  BRIEF_LTID=$(yq -r '.legacy_task_id // ""' "$BRIEF")
  if [ -n "$TASK_LTID" ] && [ -z "$BRIEF_LTID" ]; then
    fail "Brief missing legacy_task_id (parent task has '$TASK_LTID'). task-load-spec.sh secondary resolution will fail. Use write_brief_artifact (auto-resolves) or pass legacy_task_id=$TASK_LTID explicitly (#296)."
  fi
fi

# ---------- R-BUG-1 — reproducer required for bug briefs ----------

if [ "$BRIEF_TYPE" = "bug" ]; then
  REPRODUCER_FIELD=$(yq -r '.reproducer // ""' "$BRIEF")
  BODY=$(yq -r '.body // ""' "$BRIEF")
  REPRO_BODY=$(printf '%s' "$BODY" \
    | awk '/^## Steps to Reproduce/{found=1; next} found && /^## /{exit} found{print}' \
    | grep -v '^[[:space:]]*$' | head -3)

  if [ -z "$REPRODUCER_FIELD" ] && [ -z "$REPRO_BODY" ]; then
    fail "Bug brief (task_id=$TASK_ID) has no reproducer: field and no ## Steps to Reproduce in body. Add steps before flipping to ready (brief@3.4.0, #220 A2-1)."
  fi
fi

[ "$FAILURES" -eq 0 ] && exit 0
exit 1
