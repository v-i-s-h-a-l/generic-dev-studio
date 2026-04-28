#!/usr/bin/env bash
# test-merge-safety.sh — fixture for #300 composite merge gate.
#
# Builds a fresh synthetic git repo for each scenario and verifies
# scripts/task-merge.sh blocks, warns, passes, or records --force override
# based on the build/review/debrief safety-signal count.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not installed\n' >&2; exit 0; }

TMPROOT=$(mktemp -d -t merge-safety.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"

TASK_ID="T300"
PROJECT="fixture-300"
export ACHILLES_PROJECT="$PROJECT"

assertions=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then fail "$1 — failed: $2"; fi
}

events_log() {
  date_today=$(date -u +%Y-%m-%d)
  printf '%s/.dev-studio/%s/events/%s.jsonl\n' "$HOME" "$PROJECT" "$date_today"
}

setup_repo() {
  local name="$1" root repo worktree proj_root
  root="$TMPROOT/$name"
  repo="$root/$PROJECT"
  worktree="$root/wt-$TASK_ID"
  proj_root="$HOME/.dev-studio/$PROJECT"

  rm -rf "$root" "$proj_root"
  mkdir -p "$repo" "$proj_root/events" "$proj_root/plans/debriefs"

  git -C "$repo" init -q -b main
  git -C "$repo" config user.email fixture@test
  git -C "$repo" config user.name Fixture
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -q -m 'seed'

  git -C "$repo" worktree add -q -b "achilles/$TASK_ID" "$worktree"
  printf 'work for %s\n' "$name" > "$worktree/$name.txt"
  git -C "$worktree" add "$name.txt"
  git -C "$worktree" commit -q -m "$TASK_ID: $name"

  printf '%s\n' "$worktree"
}

append_event() {
  local event="$1" log
  log=$(events_log)
  mkdir -p "$(dirname "$log")"
  printf '{"ts":"2026-04-28T00:00:00Z","agent":"fixture","event":"%s","task":"%s","data":{}}\n' \
    "$event" "$TASK_ID" >> "$log"
}

run_merge() {
  local worktree="$1"
  shift
  "$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$worktree" main "$@"
}

count_events() {
  local pat="$1" log
  log=$(events_log)
  [ -f "$log" ] || { printf '0\n'; return; }
  grep -c "$pat" "$log" 2>/dev/null || true
}

# ---------- 0 of 3 signals: block ----------
WORKTREE=$(setup_repo block-zero)
set +e
run_merge "$WORKTREE" "Merge $TASK_ID into main" >/tmp/merge-safety-zero.out 2>/tmp/merge-safety-zero.err
rc=$?
set -e
assert "zero signals blocks with exit 4" "[ $rc -eq 4 ]"
assert "zero signals emits merge_safety_blocked" "[ \$(count_events 'merge_safety_blocked') -eq 1 ]"
assert "zero signals lists build" "grep -q 'build_passed' /tmp/merge-safety-zero.err"
assert "zero signals lists review" "grep -q 'review_verdict' /tmp/merge-safety-zero.err"
assert "zero signals lists debrief" "grep -q 'debrief' /tmp/merge-safety-zero.err"

# ---------- 1 of 3 signals: block ----------
WORKTREE=$(setup_repo block-two-missing)
append_event build_check_passed
set +e
run_merge "$WORKTREE" "Merge $TASK_ID into main" >/tmp/merge-safety-two.out 2>/tmp/merge-safety-two.err
rc=$?
set -e
assert "two missing signals blocks with exit 4" "[ $rc -eq 4 ]"
assert "two missing emits merge_safety_blocked" "[ \$(count_events 'merge_safety_blocked') -eq 1 ]"
assert "two missing lists review" "grep -q 'review_verdict' /tmp/merge-safety-two.err"
assert "two missing lists debrief" "grep -q 'debrief' /tmp/merge-safety-two.err"

# ---------- 2 of 3 signals: warn and merge ----------
WORKTREE=$(setup_repo warn-one-missing)
append_event build_check_passed
append_event review_approved
set +e
run_merge "$WORKTREE" "Merge $TASK_ID into main" >/tmp/merge-safety-warn.out 2>/tmp/merge-safety-warn.err
rc=$?
set -e
assert "one missing signal merges" "[ $rc -eq 0 ]"
assert "one missing emits merge_safety_warn" "[ \$(count_events 'merge_safety_warn') -eq 1 ]"
assert "one missing warns about debrief" "grep -q 'debrief' /tmp/merge-safety-warn.err"

# ---------- 3 of 3 signals: pass with no warning ----------
WORKTREE=$(setup_repo pass-all)
append_event build_check_passed
append_event review_flagged
append_event debrief_emitted
set +e
run_merge "$WORKTREE" "Merge $TASK_ID into main" >/tmp/merge-safety-pass.out 2>/tmp/merge-safety-pass.err
rc=$?
set -e
assert "all signals merge" "[ $rc -eq 0 ]"
assert "all signals emits no merge safety warning" "[ \$(count_events 'merge_safety_warn') -eq 0 ]"
assert "all signals emits no merge safety block" "[ \$(count_events 'merge_safety_blocked') -eq 0 ]"

# ---------- 0 of 3 signals with --force: override and merge ----------
WORKTREE=$(setup_repo force-zero)
set +e
run_merge "$WORKTREE" --force "Merge $TASK_ID into main" >/tmp/merge-safety-force.out 2>/tmp/merge-safety-force.err
rc=$?
set -e
assert "force override merges" "[ $rc -eq 0 ]"
assert "force override emits merge_safety_override" "[ \$(count_events 'merge_safety_override') -eq 1 ]"
assert "force override stderr names override" "grep -q 'merge safety override' /tmp/merge-safety-force.err"

printf 'PASS: %s assertions\n' "$assertions"
