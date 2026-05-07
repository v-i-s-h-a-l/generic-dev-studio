#!/usr/bin/env bash
# Fixture: release-bearing leaf with a post-launch merge commit.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/scripts/test-fixtures/699-release-bearing-policy/helpers.sh"

TMPROOT=$(mktemp -d -t release-bearing-policy-merge.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

release_policy_require_jq
release_policy_load_leaf_gate_functions

repo="$TMPROOT/repo"
chain="$TMPROOT/chain"
leaf="$TMPROOT/leaf"
sibling="$TMPROOT/sibling"

release_policy_setup_repo "$repo" "$chain" "feature/release-bearing-policy"
commit_before=$(git -C "$chain" rev-parse HEAD)

git -C "$repo" worktree add -q -B feature/release-bearing-policy-issue-merge "$leaf" "$commit_before"
git -C "$repo" worktree add -q -B feature/release-bearing-policy-issue-sibling "$sibling" "$commit_before"
printf 'sibling\n' >"$sibling/sibling.txt"
git -C "$sibling" add sibling.txt
git -C "$sibling" commit -q -m "sibling leaf"
printf 'leaf\n' >"$leaf/leaf.txt"
git -C "$leaf" add leaf.txt
git -C "$leaf" commit -q -m "leaf work"
git -C "$leaf" merge --no-ff feature/release-bearing-policy-issue-sibling -m "merge sibling leaf" >/dev/null

leaf_audit="$TMPROOT/leaf-audit.jsonl"
release_policy_prepare_leaf_gate_audit "$TMPROOT" "$leaf_audit"
if validate_release_chain_leaf_policy \
    "release-bearing-policy" \
    "69902" \
    "$leaf" \
    "feature/release-bearing-policy-issue-merge" \
    "$commit_before" \
    "rel-699-merge" \
    "rebase" \
    "chain-run-699-merge" \
    "issue-run-699-merge"; then
  release_policy_fail "merge-polluted release-bearing leaf unexpectedly passed"
fi

jq -e '
  select(
    .gate_id == "release_chain_leaf_merge_commits"
    and .status == "failed"
    and .severity == "hard"
    and .override_env == "STUDIO_BYPASS_CHAIN_LEAF_MERGE_COMMIT_GATE"
    and .issue_number == 69902
    and (.detail | contains("contains merge commits after launch chain commit"))
  )
' "$leaf_audit" >/dev/null || release_policy_fail "release_chain_leaf_merge_commits failure audit row missing"
jq -e 'select(.gate_id == "release_chain_leaf_ancestry" and .status == "passed" and .issue_number == 69902)' "$leaf_audit" >/dev/null \
  || release_policy_fail "merge fixture should still pass release_chain_leaf_ancestry"

printf 'PASS: release-bearing leaf merge-commit violation fixture\n'
