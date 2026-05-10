#!/usr/bin/env bash
# test-resolve-project-worktree.sh — fixture for #820.
#
# Verifies resolve_project() returns the project slug (not the worktree dir
# name) when invoked from inside a git worktree.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t resolve-project-wt.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

# Set up a fake project repo + worktree inside it. Mirrors the studio layout:
#   <main>/turnip-ios            (main checkout)
#   <main>/turnip-ios/worktrees/T368  (worktree, branch feature-x)
mkdir -p "$TMPROOT/turnip-ios"
cd "$TMPROOT/turnip-ios"
git init -q -b main
git config user.email a@b.c
git config user.name test
printf 'x\n' > README.md
git add README.md
git commit -q -m initial
mkdir -p worktrees
git worktree add -q -b feature-x worktrees/T368 main >/dev/null

# Case 1: inside the main checkout, resolve_project must return "turnip-ios".
result_main=$(cd "$TMPROOT/turnip-ios" && bash -c "
  source '$ROOT/scripts/lib-paths.sh' && resolve_project
")
assert "main checkout resolves project to 'turnip-ios'" \
  '[ "$result_main" = "turnip-ios" ]'

# Case 2: inside the worktree at worktrees/T368, resolve_project must return
# "turnip-ios" — NOT "T368". This is the #820 regression.
result_wt=$(cd "$TMPROOT/turnip-ios/worktrees/T368" && bash -c "
  source '$ROOT/scripts/lib-paths.sh' && resolve_project
")
assert "worktree resolves project to 'turnip-ios' (not 'T368') — #820" \
  '[ "$result_wt" = "turnip-ios" ]'

# Case 3: ACHILLES_PROJECT env var still wins over both.
result_env=$(cd "$TMPROOT/turnip-ios/worktrees/T368" && ACHILLES_PROJECT=override bash -c "
  source '$ROOT/scripts/lib-paths.sh' && resolve_project
")
assert "ACHILLES_PROJECT override still beats worktree resolution" \
  '[ "$result_env" = "override" ]'

# Case 4: outside any git repo, resolve_project errors. Use a temp dir that
# has no .git ancestor (mktemp under TMPROOT works since TMPROOT itself has
# no .git in its parent chain).
result_norepo_rc=0
(cd "$TMPROOT" && bash -c "
  source '$ROOT/scripts/lib-paths.sh' && resolve_project
" >/dev/null 2>&1) || result_norepo_rc=$?
assert "non-repo resolve_project returns non-zero" \
  '[ "$result_norepo_rc" -ne 0 ]'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: resolve_project worktree (%d/%d)\n' "$pass" "$pass"
