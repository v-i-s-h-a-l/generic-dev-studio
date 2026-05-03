#!/usr/bin/env bash
# validate-brief.sh — pre-`ready` brief lint gate (#220 A2-1).
#
# Validates brief-specific constraints beyond summary length and concern-
# inheritance (those live in self-review-brief.sh). Called from
# self-review-brief.sh so callers stay one-line.
#
# Current checks:
#   R-LTID-1 — legacy_task_id required when parent task has one (#296).
#     Keeps migration/backfill parity intact for diagnostic legacy reads.
#     Warns (not blocks) to avoid breaking pre-3.5.0 briefs.
#   R-BUG-1 — reproducer required for bug briefs.
#     When parent task type=bug: brief must have non-empty `reproducer:` YAML
#     field (brief@3.4.0+) OR a non-empty ## Steps to Reproduce section in body.
#     Fails loud if neither is present.
#   R-QUAL-* — executable brief quality contract for brief@3.8.0+.
#     New direct-to-Achilles implementation briefs must be small enough to
#     execute, objectively reviewable, and carry verification guidance.
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

version_ge() {
  # Returns true when $1 >= $2 for dotted numeric versions.
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na=split(a, av, "."); nb=split(b, bv, ".")
      n=(na>nb?na:nb)
      for (i=1; i<=n; i++) {
        ai=(av[i] == "" ? 0 : av[i]) + 0
        bi=(bv[i] == "" ? 0 : bv[i]) + 0
        if (ai > bi) exit 0
        if (ai < bi) exit 1
      }
      exit 0
    }'
}

body_section_has_content() {
  local body="$1" heading_regex="$2"
  printf '%s' "$body" | awk -v heading="$heading_regex" '
    BEGIN { in_s=0 }
    $0 ~ heading { in_s=1; next }
    in_s && /^[[:space:]]*##[[:space:]]+/ { exit }
    in_s && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*<!--[[:space:]]*/ {
      found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

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
    fail "Brief missing legacy_task_id (parent task has '$TASK_LTID'). Add it for migration/backfill parity, or pass legacy_task_id=$TASK_LTID explicitly (#296)."
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

# ---------- R-QUAL-* — executable brief quality contract (brief@3.8.0+) ----------

SCHEMA_VERSION=$(yq -r '.schema_version.version // "0.0.0"' "$BRIEF")
if version_ge "$SCHEMA_VERSION" "3.8.0"; then
  BODY=$(yq -r '.body // ""' "$BRIEF")
  SIZE=$(yq -r '.size // ""' "$BRIEF" | tr '[:upper:]' '[:lower:]')
  KIND=$(yq -r '.type // ""' "$BRIEF")
  DISPATCH_AGENT=$(yq -r '.dispatch_agent // "achilles"' "$BRIEF")

  # Parent epics and planning containers should not be direct Achilles briefs.
  # If a large implementation brief really must dispatch, the waiver must be
  # explicit so Argus can review the risk instead of guessing author intent.
  if [ "$DISPATCH_AGENT" = "achilles" ] && [ "$KIND" = "impl" ] && [ "$SIZE" = "l" ]; then
    if ! body_section_has_content "$BODY" '^[[:space:]]*##[[:space:]]+(L-size [Rr]eason|Size [Ww]aiver|Split [Rr]ationale|Why not split)'; then
      fail "R-QUAL-SIZE: brief@3.8.0 executable Achilles impl brief has size=l without an explicit L-size reason or split rationale. Split to xs/s/m, or add a waiver section explaining why this must dispatch as one worker task."
    fi
  fi

  if ! body_section_has_content "$BODY" '^[[:space:]]*##[[:space:]]+Objective'; then
    fail "R-QUAL-OBJECTIVE: brief@3.8.0 requires a concise non-empty ## Objective section."
  fi

  ACCEPTANCE_LEN=$(yq -r '.acceptance // [] | length' "$BRIEF" 2>/dev/null || echo 0)
  if [ "${ACCEPTANCE_LEN:-0}" -eq 0 ]; then
    fail "R-QUAL-ACCEPTANCE: brief@3.8.0 requires non-empty structured acceptance criteria Argus can evaluate."
  else
    subjective=$(yq -r '.acceptance[]? // ""' "$BRIEF" \
      | grep -Eni '\b(smooth|seamless|intuitive|nice|better|good|clean|proper|reasonable|works well|feels|polished)\b' \
      | head -1 || true)
    if [ -n "$subjective" ]; then
      fail "R-QUAL-ACCEPTANCE: acceptance criterion is subjective instead of objectively verifiable: $subjective"
    fi
  fi

  if ! body_section_has_content "$BODY" '^[[:space:]]*##[[:space:]]+(Out of Scope|Non-goals|Non-goals / Out of Scope)'; then
    fail "R-QUAL-NON-GOALS: brief@3.8.0 requires explicit non-goals / out-of-scope."
  fi

  if ! body_section_has_content "$BODY" '^[[:space:]]*##[[:space:]]+(Verification|Evidence|Verification / Evidence|Expected Evidence)'; then
    fail "R-QUAL-VERIFY: brief@3.8.0 requires a verification/evidence section with expected proof or test guidance."
  fi

  if ! yq -e '.recommended_models.best_result.tier and .recommended_models.best_result.reasoning_effort and .recommended_models.fast_turnaround.tier and .recommended_models.fast_turnaround.reasoning_effort and .recommended_models.rationale' "$BRIEF" >/dev/null 2>&1; then
    fail "R-QUAL-MODEL: brief@3.8.0 requires structured recommended_models with best_result, fast_turnaround, and rationale."
  fi
fi

[ "$FAILURES" -eq 0 ] && exit 0
exit 1
