#!/usr/bin/env bash
# Verifies pr-merge-finalize auto method selection without calling GitHub.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-merge-method.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
WORK="$TMPROOT/repo"
mkdir -p "$BIN" "$WORK"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

json_payload() {
  local n="${COMMIT_COUNT:-1}" base="${BASE_REF:-main}" repo="${PR_REPO_SLUG:-v-i-s-h-a-l/generic-dev-studio}" commits="" i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -gt 0 ]; then commits="$commits,"; fi
    commits="${commits}{\"oid\":\"c$i\"}"
    i=$((i + 1))
  done
  printf '{"number":123,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feature","headRefOid":"abc123","headRepositoryOwner":{"login":"owner"},"baseRefName":"%s","url":"https://github.com/%s/pull/123","commits":[%s]}\n' "$base" "$repo" "$commits"
}

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --jq "*) printf '\n' ;;
      *) json_payload ;;
    esac
    ;;
  "pr comment")
    exit 0
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_LOG:?}"
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export MERGE_LOG="$TMPROOT/merge.log"
export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="pr-merge-method"
EVENT_LOG="$HOME/.dev-studio/$ACHILLES_PROJECT/events/$(date -u +%Y-%m-%d).jsonl"

(
  cd "$WORK" || exit 1
  git init -q
  git checkout -b main -q
  git config user.email test@example.invalid
  git config user.name test
  printf 'x\n' > README.md
  git add README.md
  git commit -q -m init
)

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

run_case() {
  local base="$1" count="$2" expected="$3" out
  out="$TMPROOT/out-$base-$count.txt"
  : > "$MERGE_LOG"
  if [ "$base" = "feature" ]; then
    BASE_REF="$base" COMMIT_COUNT="$count" STUDIO_BYPASS_BRANCH_POLICY=1 \
      bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
        --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
        > "$out" 2>"$out.err"
  else
    BASE_REF="$base" COMMIT_COUNT="$count" \
      bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
        --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
        > "$out" 2>"$out.err"
  fi
  assert "auto $base $count commits reports $expected" "grep -q 'MERGE_METHOD=$expected' '$out'"
  assert "auto $base $count commits calls gh --$expected" "grep -q -- '--$expected' '$MERGE_LOG'"
  assert "auto $base $count commits leaves branch cleanup to git" "! grep -q -- '--delete-branch' '$MERGE_LOG'"
  assert "auto $base $count commits exits zero" "grep -q 'PR_MERGED=1' '$out'"
  assert "auto $base $count commits emits merge-finalize duration" \
    "jq -e 'select(.event==\"pr_merge_finalize_completed\" and .data.duration_s >= 0 and .data.cleanup_failed == true)' '$EVENT_LOG' >/dev/null"
}

run_merge_target_default_gate_case() {
  local out rc
  out="$TMPROOT/out-merge-target-default.txt"
  : > "$MERGE_LOG"

  set +e
  BASE_REF=feature COMMIT_COUNT=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out" 2>"$out.err"
  rc=$?
  set -e

  assert "default merge-target policy blocks non-main PR base" "[ $rc -ne 0 ]"
  assert "default merge-target policy explains configured target" "grep -q 'configured merge target main' '$out.err'"
  assert "default merge-target policy does not invoke gh merge" "! grep -q -- 'pr merge' '$MERGE_LOG'"
}

run_head_worktree_case() {
  local out main_wt branch_after
  out="$TMPROOT/out-head-worktree.txt"
  main_wt="$TMPROOT/main-worktree"
  git -C "$WORK" branch -f feature HEAD
  git -C "$WORK" checkout -q feature
  git -C "$WORK" worktree add -q "$main_wt" main
  : > "$MERGE_LOG"
  BASE_REF=main COMMIT_COUNT=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out" 2>"$out.err"
  branch_after=$(git -C "$WORK" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  assert "head worktree case detaches before gh merge" "[ -z '$branch_after' ]"
  assert "head worktree case reports merge success" "grep -q 'PR_MERGED=1' '$out'"
  assert "head worktree case avoided detach failure" "! grep -q 'head_worktree_detach_.*failed\\|head_worktree_detach_skipped_dirty' '$out'"
  git -C "$WORK" worktree remove -f "$main_wt"
  git -C "$WORK" checkout -q main
}

run_target_repo_auto_merge_lock_case() {
  local out rc
  out="$TMPROOT/out-target-auto-merge-lock.txt"
  : > "$MERGE_LOG"

  set +e
  PR_REPO_SLUG=owner/repo BASE_REF=main COMMIT_COUNT=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out" 2>"$out.err"
  rc=$?
  set -e

  assert "target repo auto-merge lock blocks default merge" "[ $rc -ne 0 ]"
  assert "target repo auto-merge lock reports no merge" "grep -q 'PR_MERGED=0' '$out'"
  assert "target repo auto-merge lock explains manual merge" "grep -q 'target repository owner/repo' '$out.err'"
  assert "target repo auto-merge lock does not invoke gh merge" "! grep -q -- 'pr merge' '$MERGE_LOG'"

  : > "$MERGE_LOG"
  PR_REPO_SLUG=owner/repo BASE_REF=main COMMIT_COUNT=1 STUDIO_TARGET_REPO_AUTO_MERGE=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out.allowed" 2>"$out.allowed.err"
  assert "target repo config unlock allows merge" "grep -q 'PR_MERGED=1' '$out.allowed'"
  assert "target repo config unlock reaches gh merge" "grep -q -- 'pr merge' '$MERGE_LOG'"

  : > "$MERGE_LOG"
  PR_REPO_SLUG=owner/repo BASE_REF=main COMMIT_COUNT=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review \
      --allow-target-repo-auto-merge \
      --user-approved-bypass https://github.com/owner/repo/issues/1 \
      > "$out.oneshot" 2>"$out.oneshot.err"
  assert "target repo one-shot unlock allows merge" "grep -q 'PR_MERGED=1' '$out.oneshot'"
  assert "target repo one-shot unlock reaches gh merge" "grep -q -- 'pr merge' '$MERGE_LOG'"
}

prepare_feature_branch_with_merge_commit() {
  git -C "$WORK" checkout -q main
  git -C "$WORK" branch -D feature sibling >/dev/null 2>&1 || true

  git -C "$WORK" checkout -q -b feature
  printf 'feature\n' > feature.txt
  git -C "$WORK" add feature.txt
  git -C "$WORK" commit -q -m 'feature work'

  git -C "$WORK" checkout -q main
  git -C "$WORK" checkout -q -b sibling
  printf 'sibling\n' > sibling.txt
  git -C "$WORK" add sibling.txt
  git -C "$WORK" commit -q -m 'sibling work'

  git -C "$WORK" checkout -q feature
  git -C "$WORK" merge --no-ff sibling -m 'merge sibling into feature' >/dev/null
  git -C "$WORK" checkout -q main
}

run_feature_merge_commit_gate_case() {
  local out rc
  out="$TMPROOT/out-feature-merge-gate.txt"
  prepare_feature_branch_with_merge_commit
  : > "$MERGE_LOG"

  set +e
  BASE_REF=main COMMIT_COUNT=2 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out" 2>"$out.err"
  rc=$?
  set -e

  assert "merge-commit feature history blocks PR finalize" "[ $rc -ne 0 ]"
  assert "merge-commit feature history explains rebase/retarget policy" "grep -q 'rebase or retarget the branch before merging' '$out.err'"
  assert "merge-commit feature history does not invoke gh merge" "! grep -q -- 'pr merge' '$MERGE_LOG'"

  : > "$MERGE_LOG"
  BASE_REF=main COMMIT_COUNT=2 STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1 \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out.bypass" 2>"$out.bypass.err"
  assert "merge-commit bypass allows finalize" "grep -q 'PR_MERGED=1' '$out.bypass'"
  assert "merge-commit bypass still records merge method" "grep -q 'MERGE_METHOD=rebase' '$out.bypass'"
  assert "merge-commit bypass reaches gh merge" "grep -q -- '--rebase' '$MERGE_LOG'"
}

cd "$WORK" || exit 1
run_case main 3 rebase
run_case main 4 merge
run_merge_target_default_gate_case
run_target_repo_auto_merge_lock_case
run_case feature 4 rebase
run_head_worktree_case
run_feature_merge_commit_gate_case

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: PR merge method policy\n'
