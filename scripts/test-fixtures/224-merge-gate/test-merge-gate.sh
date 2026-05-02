#!/usr/bin/env bash
# test-merge-gate.sh — fixture for #224 approved-only and post-review base gates.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

command -v yq >/dev/null 2>&1 || { printf 'skip: yq not installed\n' >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'skip: jq not installed\n' >&2; exit 0; }

TMPROOT=$(mktemp -d -t merge-gate-224.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"

PROJECT="fixture-224"
PROJ_ROOT="$HOME/.dev-studio/$PROJECT"
mkdir -p "$PROJ_ROOT/plans/debriefs" "$PROJ_ROOT/events"

REMOTE="$TMPROOT/$PROJECT.git"
REPO="$TMPROOT/$PROJECT"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" checkout -q -b main
git -C "$REPO" config user.email fixture@test
git -C "$REPO" config user.name Fixture
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -q -m 'seed'
git -C "$REPO" push -q -u origin main

TASK_ID="T224"
WORKTREE="$TMPROOT/wt-$TASK_ID"
git -C "$REPO" worktree add -q -b "achilles/$TASK_ID" "$WORKTREE" main
git -C "$WORKTREE" config user.email fixture@test
git -C "$WORKTREE" config user.name Fixture
printf 'task\n' > "$WORKTREE/task.txt"
git -C "$WORKTREE" add task.txt
git -C "$WORKTREE" commit -q -m 'task work'

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
  local event="$1" data
  if [ $# -ge 2 ]; then
    data="$2"
  else
    data='{}'
  fi
  printf '{"ts":"2026-04-29T00:00:00Z","agent":"fixture","event":"%s","task":"%s","data":%s}\n' \
    "$event" "$TASK_ID" "$data" >> "$(events_log)"
}

stage_debrief() {
  cat > "$PROJ_ROOT/plans/debriefs/01234567-89ab-7cde-8000-000000000224.yaml" <<YAML
schema: debrief@2.0.1
state: emitted
mode: task
task_id: 00000000-0000-7000-8000-000000000224
legacy_task_id: $TASK_ID
created_at: 2026-04-29T00:00:00Z
updated_at: 2026-04-29T00:00:00Z
YAML
}

run_safety_only() {
  STUDIO_MERGE_SAFETY_ONLY=1 "$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main "$@" >/dev/null 2>&1
}

reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_approved '{"stage":"spec"}'
emit_event_line review_flagged
set +e
run_safety_only --require-approved
rc=$?
set -e
assert "require-approved defers flagged review" "[ $rc -eq 4 ]"
assert "flagged defer emits event" "grep -q 'merge_deferred_on_flagged' '$(events_log)'"

reset_runtime
stage_debrief
emit_event_line build_check_passed
emit_event_line review_flagged
set +e
run_safety_only --require-approved --steal-flagged
rc=$?
set -e
assert "steal-flagged allows flagged review" "[ $rc -eq 0 ]"

reset_runtime
stage_debrief
base_sha=$(git -C "$REPO" rev-parse origin/main)
emit_event_line build_check_passed
emit_event_line review_approved
emit_event_line review_requested "{\"base_branch\":\"main\",\"base_sha\":\"$base_sha\"}"

git -C "$REPO" checkout -q main
printf 'sibling\n' > "$REPO/sibling.txt"
git -C "$REPO" add sibling.txt
git -C "$REPO" commit -q -m 'sibling merge'
git -C "$REPO" push -q origin main

set +e
"$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main --require-approved >/dev/null 2>&1
rc=$?
set -e
assert "post-review base divergence blocks merge" "[ $rc -eq 4 ]"
assert "post-review base divergence emits event" "grep -q 'base_diverged_post_review' '$(events_log)'"
assert "task branch was not merged" "! git -C '$REPO' log --oneline main | grep -q 'Merge T224'"

reset_runtime
stage_debrief
current_local_base=$(git -C "$REPO" rev-parse origin/main)
emit_event_line build_check_passed
emit_event_line review_approved
emit_event_line review_requested "{\"base_branch\":\"main\",\"base_sha\":\"$current_local_base\"}"
git -C "$REPO" remote set-url origin "$TMPROOT/missing-remote.git"
set +e
"$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main --require-approved >/dev/null 2>&1
rc=$?
set -e
assert "fetch failure blocks when reviewed base was recorded" "[ $rc -eq 4 ]"
assert "fetch failure did not merge task branch" "! git -C '$REPO' log --oneline main | grep -q 'Merge T224'"

printf 'PASS: %s assertions\n' "$assertions"
