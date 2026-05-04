#!/usr/bin/env bash
# Verifies chain resume detection accepts standard git worktree .git files.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-resume-worktree.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

REPO="$TMPROOT/repo"
CHAIN_WORKTREE="$TMPROOT/chain-worktree"

git init -q "$REPO"
git -C "$REPO" config user.name "Fixture"
git -C "$REPO" config user.email "fixture@example.com"
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -M main
git -C "$REPO" worktree add -q -B feature/chain "$CHAIN_WORKTREE" main

[ -f "$CHAIN_WORKTREE/.git" ] || fail "fixture did not create a linked worktree with .git as a file"
git -C "$CHAIN_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "git-native checkout probe does not recognize linked worktree"

grep -q '^git_checkout_exists()' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing git checkout detection helper"

if grep -Fq '[ -d "$chain_worktree/.git" ]' "$ROOT/scripts/studio-chain-runner.sh"; then
  fail "runner still uses .git directory shape to detect chain worktrees"
fi

printf 'PASS: chain resume worktree detection\n'
