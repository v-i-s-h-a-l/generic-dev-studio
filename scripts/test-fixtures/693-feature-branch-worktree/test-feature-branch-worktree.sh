#!/usr/bin/env bash
# Verifies task-worktree setup blocks merge-polluted feature branches unless explicitly bypassed.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t feature-branch-worktree.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"

REPO="$TMPROOT/repo"
git -C "$TMPROOT" init -q repo
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "Feature Branch Fixture"
printf 'seed\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "initial"
git -C "$REPO" branch -M main

git -C "$REPO" checkout -q -b feature/clean
printf 'clean\n' > "$REPO/clean.txt"
git -C "$REPO" add clean.txt
git -C "$REPO" commit -q -m "clean feature"

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b feature/merged
printf 'merged\n' > "$REPO/merged.txt"
git -C "$REPO" add merged.txt
git -C "$REPO" commit -q -m "merged feature"

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b sibling/dep
printf 'dep\n' > "$REPO/dep.txt"
git -C "$REPO" add dep.txt
git -C "$REPO" commit -q -m "dependent branch"

git -C "$REPO" checkout -q feature/merged
git -C "$REPO" merge --no-ff sibling/dep -m "merge dependent branch" >/dev/null
git -C "$REPO" checkout -q main

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    fail "$name"
  fi
}

DRY_RUN=1 bash "$ROOT/scripts/task-worktree-setup.sh" T693-clean "$REPO" feature/clean >"$TMPROOT/clean.out" 2>"$TMPROOT/clean.err"
assert "clean feature branch succeeds" "grep -q 'export ORIG_BRANCH=feature/clean' '$TMPROOT/clean.out'"
assert "clean feature branch uses dry-run worktree add" "grep -q 'DRY-RUN git worktree add' '$TMPROOT/clean.err'"

set +e
DRY_RUN=1 bash "$ROOT/scripts/task-worktree-setup.sh" T693-merged "$REPO" feature/merged >"$TMPROOT/merged.out" 2>"$TMPROOT/merged.err"
rc=$?
set -e
assert "merge-polluted feature branch blocks worktree setup" "[ $rc -eq 4 ]"
assert "merge-polluted feature branch explains rebase/retarget guidance" "grep -q 'rebase or retarget the dependent branch before creating the task worktree' '$TMPROOT/merged.err'"

DRY_RUN=1 STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1 \
  bash "$ROOT/scripts/task-worktree-setup.sh" T693-bypass "$REPO" feature/merged >"$TMPROOT/bypass.out" 2>"$TMPROOT/bypass.err"
assert "merge-polluted feature branch bypass succeeds" "grep -q 'export ORIG_BRANCH=feature/merged' '$TMPROOT/bypass.out'"
assert "merge-polluted feature branch bypass emits warning" "grep -q 'override STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1' '$TMPROOT/bypass.err'"

printf 'PASS: feature branch worktree policy\n'
