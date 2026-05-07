#!/usr/bin/env bash
# Fixture: clean release-bearing chain path.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/scripts/test-fixtures/699-release-bearing-policy/helpers.sh"

TMPROOT=$(mktemp -d -t release-bearing-policy-clean.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

release_policy_require_jq
release_policy_load_leaf_gate_functions

repo="$TMPROOT/repo"
chain="$TMPROOT/chain"
leaf="$TMPROOT/leaf"
chain_branch="feature/release-bearing-policy"

release_policy_setup_repo "$repo" "$chain" "$chain_branch"
commit_before=$(git -C "$chain" rev-parse HEAD)
source_sha=$(git -C "$repo" rev-parse main)

git -C "$repo" worktree add -q -B feature/release-bearing-policy-issue-clean "$leaf" "$commit_before"
printf 'leaf\n' >"$leaf/leaf.txt"
git -C "$leaf" add leaf.txt
git -C "$leaf" commit -q -m "clean leaf"

plan="$TMPROOT/plan.json"
jq -n \
  --arg source_sha "$source_sha" \
  --arg work_root "$TMPROOT/run-work" \
  '{
    schema_version:1,
    chains:[{
      name:"release-bearing-policy",
      base:"main",
      branch:"feature/release-bearing-policy",
      expected_source_sha:$source_sha,
      approved_release_id:"rel-699-clean",
      sync_strategy:"rebase",
      chain_worktree:($work_root + "/release-bearing-policy-feature"),
      issues:[{number:69901, issue_worktree:($work_root + "/release-bearing-policy-issue-69901")}]
    }]
  }' >"$plan"

manifest_audit="$TMPROOT/manifest-audit.jsonl"
"$ROOT/scripts/studio-chain-rule-gates.sh" \
  --plan "$plan" \
  --repo "$repo" \
  --expected-run-work-root "$TMPROOT/run-work" \
  --audit-log "$manifest_audit" >"$TMPROOT/manifest-gates.json"

jq -e '
  .status == "ok"
  and ([.checks[] | select(.id == "release_chain_manifest_policy" and .status == "passed")] | length == 1)
  and ([.checks[] | select(.id == "chain_manifest_sync_strategy" and .status == "passed")] | length == 1)
  and ([.checks[] | select(.id == "expected_source_branch_sha" and .status == "passed")] | length == 1)
' "$TMPROOT/manifest-gates.json" >/dev/null || release_policy_fail "clean release-bearing manifest gates did not pass"
jq -e 'select(.gate_id == "release_chain_manifest_policy" and .status == "passed")' "$manifest_audit" >/dev/null \
  || release_policy_fail "release_chain_manifest_policy pass audit row missing"

leaf_audit="$TMPROOT/leaf-audit.jsonl"
release_policy_prepare_leaf_gate_audit "$TMPROOT" "$leaf_audit"
validate_release_chain_leaf_policy \
  "release-bearing-policy" \
  "69901" \
  "$leaf" \
  "feature/release-bearing-policy-issue-clean" \
  "$commit_before" \
  "rel-699-clean" \
  "rebase" \
  "chain-run-699-clean" \
  "issue-run-699-clean"

jq -e 'select(.gate_id == "release_chain_sync_strategy" and .status == "passed" and .issue_number == 69901)' "$leaf_audit" >/dev/null \
  || release_policy_fail "release_chain_sync_strategy pass audit row missing"
jq -e 'select(.gate_id == "release_chain_leaf_ancestry" and .status == "passed" and .issue_number == 69901)' "$leaf_audit" >/dev/null \
  || release_policy_fail "release_chain_leaf_ancestry pass audit row missing"
jq -e 'select(.gate_id == "release_chain_leaf_merge_commits" and .status == "passed" and .issue_number == 69901)' "$leaf_audit" >/dev/null \
  || release_policy_fail "release_chain_leaf_merge_commits pass audit row missing"

printf 'PASS: clean release-bearing chain fixture\n'
