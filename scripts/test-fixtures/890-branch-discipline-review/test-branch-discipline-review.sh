#!/usr/bin/env bash
# Regression coverage for PR #890 review findings that crossed branch policy
# and worktree cleanup boundaries.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t branch-discipline-review-890.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

repo="$TMPROOT/repo"
home_dir="$TMPROOT/home"
project="policy-project"
mkdir -p "$repo" "$home_dir/.dev-studio/$project/worktrees/keep-me" "$home_dir/.dev-studio/$project/worktrees/count-me"

git -C "$repo" init -q
git -C "$repo" config user.name "Fixture"
git -C "$repo" config user.email "fixture@example.com"
git -C "$repo" checkout -q -b main
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "base"

# shellcheck source=scripts/lib-worktree-marker.sh
. "$ROOT/scripts/lib-worktree-marker.sh"

worktree_marker_write "$home_dir/.dev-studio/$project/worktrees/keep-me" worker --project "$project" --task-id keep
worktree_marker_write "$home_dir/.dev-studio/$project/worktrees/count-me" worker --project "$project" --task-id count
printf 'kept payload\n' > "$home_dir/.dev-studio/$project/worktrees/keep-me/payload.txt"
printf 'counted payload\n' > "$home_dir/.dev-studio/$project/worktrees/count-me/payload.txt"

HOME="$home_dir" STUDIO_KEEP_WORKTREE=keep-me STUDIO_WORKTREE_COUNT_BUDGET=0 \
  "$ROOT/scripts/studio-worktree-gc.sh" --project "$project" --budget-check > "$TMPROOT/gc.json"

jq -e '
  .totals.worktrees == 2
  and .budget.count == 1
  and .budget.status == "alarm"
  and ([.entries[] | select(.slug == "keep-me" and .status == "kept")] | length == 1)
' "$TMPROOT/gc.json" >/dev/null || {
  cat "$TMPROOT/gc.json" >&2
  fail "kept worktree was not excluded from layer-3 budget accounting"
}

HOME="$home_dir" STUDIO_BRANCH_POLICY_DEFAULT_BASE=develop \
  "$ROOT/scripts/lib-manager-context-header.sh" --json "$repo" > "$TMPROOT/header.json"

jq -e '.policy.default_base == "develop" and .base_ref == "develop"' "$TMPROOT/header.json" >/dev/null || {
  cat "$TMPROOT/header.json" >&2
  fail "manager context header ignored canonical branch_policy.default_base"
}

printf 'PASS: branch discipline PR review regressions\n'
