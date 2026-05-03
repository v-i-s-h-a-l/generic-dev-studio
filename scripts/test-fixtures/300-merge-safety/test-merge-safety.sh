#!/usr/bin/env bash
# test-merge-safety.sh — fixture for #300 composite merge safety gate.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

command -v yq >/dev/null 2>&1 || { printf 'skip: yq not installed\n' >&2; exit 0; }

TMPROOT=$(mktemp -d -t merge-safety.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"

PROJECT="fixture-300"
PROJ_ROOT="$HOME/.dev-studio/$PROJECT"
mkdir -p "$PROJ_ROOT/plans/debriefs" "$PROJ_ROOT/events"

REPO="$TMPROOT/$PROJECT"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@test
git -C "$REPO" config user.name Fixture
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -q -m 'seed'

TASK_ID="T300"
WORKTREE="$TMPROOT/wt-$TASK_ID"
git -C "$REPO" worktree add -q -b "achilles/$TASK_ID" "$WORKTREE"

assertions=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then fail "$1 — failed: $2"; fi
}

events_log() {
  printf '%s/events/%s.jsonl\n' "$PROJ_ROOT" "$(date -u +%Y-%m-%d)"
}

reset_runtime() {
  rm -f "$PROJ_ROOT/events"/*.jsonl "$PROJ_ROOT/plans/debriefs"/*.yaml 2>/dev/null || true
}

emit_event_line() {
  local event="$1"
  printf '{"ts":"2026-04-29T00:00:00Z","agent":"fixture","event":"%s","task":"%s","data":{}}\n' \
    "$event" "$TASK_ID" >> "$(events_log)"
}

stage_debrief() {
  cat > "$PROJ_ROOT/plans/debriefs/01234567-89ab-7cde-8000-000000000300.yaml" <<YAML
schema: debrief@2.0.1
state: emitted
mode: task
task_id: 00000000-0000-7000-8000-000000000300
legacy_task_id: $TASK_ID
created_at: 2026-04-29T00:00:00Z
updated_at: 2026-04-29T00:00:00Z
YAML
}

run_safety_only() {
  STUDIO_MERGE_SAFETY_ONLY=1 "$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main "$@" >/dev/null 2>&1
}

# 0 of 3 signals: block and list all three missing.
reset_runtime
set +e
run_safety_only
rc=$?
set -e
assert "zero signals blocks" "[ $rc -eq 4 ]"
assert "zero signals emits merge_safety_blocked" "grep -q 'merge_safety_blocked' '$(events_log)'"
assert "zero signals names all missing" "grep -Fq '\"missing_signals\":[\"build\",\"review\",\"debrief\"]' '$(events_log)'"

# 1 of 3 signals present: block because two are absent.
reset_runtime
emit_event_line build_check_passed
set +e
run_safety_only
rc=$?
set -e
assert "one present signal blocks" "[ $rc -eq 4 ]"
assert "one present signal names review and debrief" "grep -Fq '\"missing_signals\":[\"review\",\"debrief\"]' '$(events_log)'"

# 2 of 3 signals present: warn and pass.
reset_runtime
emit_event_line build_check_passed
emit_event_line review_approved
set +e
run_safety_only
rc=$?
set -e
assert "two present signals warn-pass" "[ $rc -eq 0 ]"
assert "two present emits merge_safety_warn" "grep -q 'merge_safety_warn' '$(events_log)'"

# 3 of 3 signals present: pass with no safety event.
reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_flagged
set +e
run_safety_only
rc=$?
set -e
assert "three signals pass" "[ $rc -eq 0 ]"
assert "three signals emit no merge_safety event" "! grep -q 'merge_safety_' '$(events_log)'"

# require-approved refuses flagged reviews even when the composite safety gate
# has all three signals.
reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_flagged
set +e
run_safety_only --require-approved
rc=$?
set -e
assert "require-approved defers flagged review" "[ $rc -eq 4 ]"
assert "require-approved emits merge_deferred_on_flagged" "grep -q 'merge_deferred_on_flagged' '$(events_log)'"

# A later approved review supersedes earlier flagged history.
reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_flagged
emit_event_line review_approved
set +e
run_safety_only --require-approved
rc=$?
set -e
assert "latest approved review clears prior flagged defer" "[ $rc -eq 0 ]"
assert "latest approved review emits no flagged defer" "! grep -q 'merge_deferred_on_flagged' '$(events_log)'"

# A later blocked review is a hard stop, not a missing-review warning.
reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_approved
emit_event_line review_blocked
set +e
run_safety_only
rc=$?
set -e
assert "latest blocked review blocks merge safety" "[ $rc -eq 4 ]"
assert "latest blocked review emits merge_safety_blocked" "grep -q 'review_blocked' '$(events_log)'"

# --steal-flagged is the user-controlled flagged-review override.
reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_flagged
set +e
run_safety_only --require-approved --steal-flagged
rc=$?
set -e
assert "steal-flagged bypasses require-approved flagged defer" "[ $rc -eq 0 ]"
assert "steal-flagged emits review_override for flagged merge" "grep -q 'review_override' '$(events_log)'"

# --force bypasses a composite block and emits override.
reset_runtime
set +e
run_safety_only --force
rc=$?
set -e
assert "force bypasses zero-signal block" "[ $rc -eq 0 ]"
assert "force emits merge_safety_override" "grep -q 'merge_safety_override' '$(events_log)'"

printf 'PASS: %s assertions\n' "$assertions"
