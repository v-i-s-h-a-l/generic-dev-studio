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

grep -Fq 'STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing the documented base SHA drift bypass env"

grep -Fq '.base_ref // .source_branch // .base' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing the v2 base_ref resolution at preflight/launch"

grep -Fq '.base_sha // .expected_source_sha // .source_sha' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing the v2 base_sha resolution at preflight/launch"

grep -Eq 'live_preflight\b' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing live_preflight"

# Resume re-runs prepare_plan and live_preflight against the recorded base ref/sha.
# Guard against a regression that removes the resume drift check entirely.
grep -nE 'live_preflight "\$PLAN_JSON"' "$ROOT/scripts/studio-chain-runner.sh" | grep -q . \
  || fail "resume path no longer invokes live_preflight on the plan"

printf 'PASS: chain resume worktree detection\n'
