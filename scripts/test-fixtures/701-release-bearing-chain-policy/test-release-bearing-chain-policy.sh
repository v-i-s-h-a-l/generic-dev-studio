#!/usr/bin/env bash
# Regression coverage for release-bearing chain manifest policy and leaf validation.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
GATES="$ROOT/scripts/studio-chain-rule-gates.sh"
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
SCHEMA="$ROOT/core/v2/schemas/chain-manifest.schema.json"
DOC="$ROOT/_shared/schemas/chain-plan.md"
TMPROOT=$(mktemp -d -t release-bearing-chain-policy-701.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"

[ -f "$DOC" ] || fail "missing chain-plan schema doc"
jq -e '
  ."$defs".chain.properties.approved_release_id.type == "string"
  and (."$defs".chain.properties.sync_strategy.enum == ["rebase", "squash"])
' "$SCHEMA" >/dev/null || fail "chain manifest schema missing release-bearing policy fields"

. "$ROOT/scripts/lib-chain-git.sh"

repo="$TMPROOT/repo"
chain_worktree="$TMPROOT/chain"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Release Policy Fixture"
mkdir -p "$repo/scripts"
printf 'base\n' >"$repo/README.md"
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/scripts/safe.sh"
git -C "$repo" add README.md scripts/safe.sh
git -C "$repo" commit -q -m "initial"
git -C "$repo" branch -M main
git -C "$repo" worktree add -q -B feature/release-policy "$chain_worktree" main
printf 'chain\n' >"$chain_worktree/chain.txt"
git -C "$chain_worktree" add chain.txt
git -C "$chain_worktree" commit -q -m "chain anchor"
commit_before=$(git -C "$chain_worktree" rev-parse HEAD)
source_sha=$(git -C "$repo" rev-parse main)

good_leaf="$TMPROOT/good-leaf"
wrong_leaf="$TMPROOT/wrong-leaf"
merge_leaf="$TMPROOT/merge-leaf"
sibling_leaf="$TMPROOT/sibling-leaf"
git -C "$repo" worktree add -q -B feature/good-leaf "$good_leaf" "$commit_before"
printf 'good\n' >"$good_leaf/good.txt"
git -C "$good_leaf" add good.txt
git -C "$good_leaf" commit -q -m "good leaf"
chain_git_release_leaf_ancestry_ok "$good_leaf" "$commit_before" "good leaf" \
  || fail "valid release leaf ancestry did not pass"
chain_git_release_leaf_merge_commits_ok "$good_leaf" "$commit_before" "good leaf" \
  || fail "valid release leaf merge policy did not pass"

git -C "$repo" worktree add -q -B feature/wrong-leaf "$wrong_leaf" main
printf 'wrong\n' >"$wrong_leaf/wrong.txt"
git -C "$wrong_leaf" add wrong.txt
git -C "$wrong_leaf" commit -q -m "wrong leaf"
if chain_git_release_leaf_ancestry_ok "$wrong_leaf" "$commit_before" "wrong leaf"; then
  fail "wrong-ancestry release leaf unexpectedly passed"
fi

git -C "$repo" worktree add -q -B feature/merge-leaf "$merge_leaf" "$commit_before"
git -C "$repo" worktree add -q -B feature/sibling-leaf "$sibling_leaf" "$commit_before"
printf 'sibling\n' >"$sibling_leaf/sibling.txt"
git -C "$sibling_leaf" add sibling.txt
git -C "$sibling_leaf" commit -q -m "sibling leaf"
printf 'merge\n' >"$merge_leaf/merge.txt"
git -C "$merge_leaf" add merge.txt
git -C "$merge_leaf" commit -q -m "merge leaf"
git -C "$merge_leaf" merge --no-ff feature/sibling-leaf -m "merge sibling leaf" >/dev/null
if chain_git_release_leaf_merge_commits_ok "$merge_leaf" "$commit_before" "merge leaf"; then
  fail "merge-polluted release leaf unexpectedly passed"
fi

squash_repo="$TMPROOT/squash-repo"
squash_chain="$TMPROOT/squash-chain"
squash_issue="$TMPROOT/squash-issue"
git init -q "$squash_repo"
git -C "$squash_repo" config user.email test@example.invalid
git -C "$squash_repo" config user.name "Release Policy Fixture"
printf 'base\n' >"$squash_repo/base.txt"
git -C "$squash_repo" add base.txt
git -C "$squash_repo" commit -q -m "base"
git -C "$squash_repo" branch -M main
git -C "$squash_repo" worktree add -q -B feature/squash-chain "$squash_chain" main
chain_git_prepare_issue_workspace "$squash_repo" "$squash_chain" feature/squash-chain "$squash_issue" feature/squash-chain-issue local-clone
git -C "$squash_issue" config user.email test@example.invalid
git -C "$squash_issue" config user.name "Release Policy Fixture"
printf 'one\n' >"$squash_issue/one.txt"
git -C "$squash_issue" add one.txt
git -C "$squash_issue" commit -q -m "one"
printf 'two\n' >"$squash_issue/two.txt"
git -C "$squash_issue" add two.txt
git -C "$squash_issue" commit -q -m "two"
squash_before=$(git -C "$squash_chain" rev-parse HEAD)
chain_git_integrate_issue_workspace "$squash_repo" "$squash_chain" feature/squash-chain "$squash_issue" feature/squash-chain-issue local-clone squash >/dev/null
[ ! -e "$squash_issue" ] || fail "squash integration did not remove issue clone"
[ "$(git -C "$squash_chain" rev-list --count "$squash_before..HEAD")" = "1" ] \
  || fail "squash integration did not collapse leaf commits"
git -C "$squash_chain" show --name-only --oneline HEAD | grep -q 'two.txt' \
  || fail "squash integration did not carry leaf changes"

plan="$TMPROOT/plan.json"
jq -n \
  --arg source_sha "$source_sha" \
  --arg work_root "$TMPROOT/run-work" \
  '{
    schema_version:1,
    chains:[{
      name:"release-policy",
      base:"main",
      branch:"feature/release-policy",
      expected_source_sha:$source_sha,
      approved_release_id:"rel-701",
      sync_strategy:"squash",
      chain_worktree:($work_root + "/release-policy-feature"),
      issues:[{number:70101, issue_worktree:($work_root + "/release-policy-issue-70101")}]
    }]
  }' >"$plan"

audit="$TMPROOT/audit.jsonl"
"$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$audit" >"$TMPROOT/gates.json"
jq -e '
  .status == "ok"
  and ([.checks[] | select(.id == "release_chain_manifest_policy" and .status == "passed")] | length == 1)
  and ([.checks[] | select(.id == "chain_manifest_sync_strategy" and .status == "passed")] | length == 1)
' "$TMPROOT/gates.json" >/dev/null || fail "release-bearing manifest gates did not pass"
jq -e 'select(.gate_id == "release_chain_manifest_policy" and .status == "passed")' "$audit" >/dev/null \
  || fail "release-bearing manifest policy audit row missing"

bad_plan="$TMPROOT/bad-plan.json"
jq '.chains[0].branch = "release/missing-policy" | del(.chains[0].approved_release_id)' "$plan" >"$bad_plan"
if "$GATES" --plan "$bad_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/bad-audit.jsonl" >"$TMPROOT/bad-gates.json"; then
  cat "$TMPROOT/bad-gates.json" >&2
  fail "release-line chain without approved_release_id unexpectedly passed"
fi
jq -e '.status == "halt" and ([.failures[] | select(.id == "release_chain_manifest_policy")] | length == 1)' "$TMPROOT/bad-gates.json" >/dev/null \
  || fail "release-line manifest policy did not fail closed"
STUDIO_BYPASS_RELEASE_CHAIN_MANIFEST_POLICY_GATE=1 \
  "$GATES" --plan "$bad_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/bad-override-audit.jsonl" >"$TMPROOT/bad-override.json"
jq -e '.status == "ok" and ([.overrides[] | select(.id == "release_chain_manifest_policy")] | length == 1)' "$TMPROOT/bad-override.json" >/dev/null \
  || fail "release-line manifest policy override did not record evidence"

bad_strategy_plan="$TMPROOT/bad-strategy-plan.json"
jq '.chains[0].sync_strategy = "merge"' "$plan" >"$bad_strategy_plan"
if "$GATES" --plan "$bad_strategy_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" >"$TMPROOT/bad-strategy.json"; then
  cat "$TMPROOT/bad-strategy.json" >&2
  fail "invalid sync_strategy unexpectedly passed"
fi
jq -e '.status == "halt" and ([.failures[] | select(.id == "chain_manifest_sync_strategy")] | length == 1)' "$TMPROOT/bad-strategy.json" >/dev/null \
  || fail "invalid sync_strategy did not fail closed"
STUDIO_BYPASS_CHAIN_SYNC_STRATEGY_GATE=1 \
  "$GATES" --plan "$bad_strategy_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" >"$TMPROOT/bad-strategy-override.json"
jq -e '.status == "ok" and ([.overrides[] | select(.id == "chain_manifest_sync_strategy")] | length == 1)' "$TMPROOT/bad-strategy-override.json" >/dev/null \
  || fail "invalid sync_strategy override did not record evidence"

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"
cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{"number":$issue,"title":"Release policy fixture $issue","body":"Exercise release policy dry-run.","url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue","state":"OPEN"}
JSON
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/chain.yaml"
cat >"$manifest" <<'YAML'
schema_version: 1
chains:
  - name: release-policy-dry-run
    base: main
    branch: feature/release-policy-dry-run
    host: codex
    approved_release_id: rel-701
    sync_strategy: squash
    phase_review: off
    issues: [70101]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$manifest" --dry-run >"$TMPROOT/runner.out" 2>&1
grep -Fq "Approved release: \`rel-701\`" "$TMPROOT/runner.out" || fail "dry-run did not show approved release policy"
grep -Fq "Leaf sync strategy: \`squash\`" "$TMPROOT/runner.out" || fail "dry-run did not show sync strategy"
grep -q 'merge --squash' "$TMPROOT/runner.out" || fail "dry-run did not use manifest-declared squash strategy"

printf 'PASS: release-bearing chain policy\n'
