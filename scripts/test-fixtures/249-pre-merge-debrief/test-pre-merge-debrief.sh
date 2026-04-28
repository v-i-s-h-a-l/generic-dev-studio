#!/usr/bin/env bash
# test-pre-merge-debrief.sh — fixture for #249 Phase 2.
#
# Exercises scripts/task-merge.sh's pre-merge debrief precondition by
# building a synthetic git repo + worktree + plans/debriefs/ tree under a
# tempdir, then running the script in three scenarios:
#
#   1. Debrief staged (state: emitted) plus build/review signals → script
#      proceeds past the composite precondition.
#   2. No debrief staged and no other safety signals → exit 4,
#      `merge_safety_blocked` names debrief as one of the missing signals.
#   3. No debrief staged but build/review signals present → `debrief_missing`
#      event fires with reason=pre_merge_warn and merge proceeds.
#
# Per CLAUDE.md: smoke-test against synthetic fixtures only; never the
# live turnip ledger. Runtime paths are HOME-overridden to a tempdir.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

command -v yq >/dev/null 2>&1 || { printf 'skip: yq not installed\n' >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'skip: jq not installed\n' >&2; exit 0; }

TMPROOT=$(mktemp -d -t pre-merge-debrief.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Override HOME so all ~/.dev-studio writes go into the tempdir.
export HOME="$TMPROOT/home"
mkdir -p "$HOME"

PROJECT="fixture-249"
PROJ_ROOT="$TMPROOT/home/.dev-studio/$PROJECT"
mkdir -p "$PROJ_ROOT/plans/debriefs"
mkdir -p "$PROJ_ROOT/events"

export ACHILLES_PROJECT="$PROJECT"
export ACHILLES_PROJECT_ROOT="$PROJ_ROOT"
export LEDGER_PROJECT_ROOT="$PROJ_ROOT"

# Build a synthetic git repo with one branch + one worktree. Repo basename
# must match $PROJECT — task-merge.sh derives PROJECT via `basename
# "$REPO_ROOT"` and uses that to resolve the debriefs dir.
REPO="$TMPROOT/$PROJECT"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@test
git -C "$REPO" config user.name Fixture
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -q -m 'seed'

TASK_ID="T999"
WORKTREE="$TMPROOT/wt-$TASK_ID"
git -C "$REPO" worktree add -q -b "achilles/$TASK_ID" "$WORKTREE"
printf 'work\n' > "$WORKTREE/work.txt"
git -C "$WORKTREE" add work.txt
git -C "$WORKTREE" commit -q -m "$TASK_ID: work"

assertions=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then fail "$1 — failed: $2"; fi
}

events_log() {
  date_today=$(date -u +%Y-%m-%d)
  printf '%s/events/%s.jsonl\n' "$PROJ_ROOT" "$date_today"
}

count_events() {
  local pat="$1" log n
  log=$(events_log)
  [ -f "$log" ] || { printf '0\n'; return; }
  n=$(grep -c "$pat" "$log" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

append_event() {
  local event="$1" log
  log=$(events_log)
  mkdir -p "$(dirname "$log")"
  printf '{"ts":"2026-04-28T00:00:00Z","agent":"fixture","event":"%s","task":"%s","data":{}}\n' \
    "$event" "$TASK_ID" >> "$log"
}

# ---------- Scenario 2: no debrief, strict (default) ----------
rm -f "$PROJ_ROOT/events"/*.jsonl 2>/dev/null || true
set +e
"$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main "Merge $TASK_ID into main" >/dev/null 2>&1
rc=$?
set -e
assert "scenario 2 strict refuses with exit 4" "[ $rc -eq 4 ]"
assert "scenario 2 emits merge_safety_blocked event" \
  "[ \$(count_events 'merge_safety_blocked') -ge 1 ]"
log=$(events_log)
assert "scenario 2 names debrief as missing" \
  "grep -q 'debrief' '$log'"

# ---------- Scenario 3: no debrief, but other safety signals present ----------
rm -rf "$WORKTREE" 2>/dev/null || true
git -C "$REPO" worktree prune
git -C "$REPO" branch -D "achilles/$TASK_ID" >/dev/null 2>&1 || true
git -C "$REPO" worktree add -q -b "achilles/$TASK_ID" "$WORKTREE"
printf 'work3\n' > "$WORKTREE/work3.txt"
git -C "$WORKTREE" add work3.txt
git -C "$WORKTREE" commit -q -m "$TASK_ID: work3"

rm -f "$PROJ_ROOT/events"/*.jsonl 2>/dev/null || true
append_event build_check_passed
append_event review_approved
set +e
"$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main "Merge $TASK_ID into main" >/dev/null 2>&1
rc=$?
set -e
assert "scenario 3 one missing signal merges" "[ $rc -eq 0 ]"
assert "scenario 3 emits debrief_missing event" \
  "[ \$(count_events 'debrief_missing') -ge 1 ]"
log=$(events_log)
assert "scenario 3 reason is pre_merge_warn" \
  "grep -q 'pre_merge_warn' '$log'"

# ---------- Scenario 1: debrief staged, default (strict) ----------
# Re-create the worktree (scenario 3's merge may have removed it).
git -C "$REPO" branch -D "achilles/$TASK_ID" >/dev/null 2>&1 || true
rm -rf "$WORKTREE" 2>/dev/null || true
git -C "$REPO" worktree prune
git -C "$REPO" worktree add -q -b "achilles/$TASK_ID" "$WORKTREE"
printf 'work2\n' > "$WORKTREE/work2.txt"
git -C "$WORKTREE" add work2.txt
git -C "$WORKTREE" commit -q -m "$TASK_ID: work2"

# Stage a synthetic debrief for TASK_ID.
DEBRIEF_UUID="01234567-89ab-7cde-8000-000000000001"
cat > "$PROJ_ROOT/plans/debriefs/$DEBRIEF_UUID.yaml" <<YAML
schema: debrief@2.0.1
state: emitted
mode: task
task_id: 00000000-0000-7000-8000-000000000001
legacy_task_id: $TASK_ID
created_at: 2026-04-27T00:00:00Z
updated_at: 2026-04-27T00:00:00Z
YAML

rm -f "$PROJ_ROOT/events"/*.jsonl 2>/dev/null || true
append_event build_check_passed
append_event review_approved
set +e
"$REPO_SCRIPTS/task-merge.sh" "$TASK_ID" "$WORKTREE" main "Merge $TASK_ID into main" >/dev/null 2>&1
rc=$?
set -e
assert "scenario 1 staged debrief: precondition does not refuse (exit != 4)" "[ $rc -ne 4 ]"
log=$(events_log)
# Confirm no debrief_missing event was emitted (precondition passed).
assert "scenario 1 emits no debrief_missing event" \
  "[ \$(count_events 'debrief_missing') -eq 0 ]"

printf 'PASS: %s assertions\n' "$assertions"
