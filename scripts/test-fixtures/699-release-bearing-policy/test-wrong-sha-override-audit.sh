#!/usr/bin/env bash
# Fixture: wrong source SHA override records a typed audit row.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/scripts/test-fixtures/699-release-bearing-policy/helpers.sh"

TMPROOT=$(mktemp -d -t release-bearing-policy-wrong-sha.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

release_policy_require_jq

repo="$TMPROOT/repo"
chain="$TMPROOT/chain"
release_policy_setup_repo "$repo" "$chain" "feature/release-bearing-policy"

plan="$TMPROOT/wrong-sha-plan.json"
wrong_sha="0000000000000000000000000000000000000000"
jq -n \
  --arg wrong_sha "$wrong_sha" \
  --arg work_root "$TMPROOT/run-work" \
  '{
    schema_version:1,
    chains:[{
      name:"release-bearing-policy",
      base:"main",
      branch:"feature/release-bearing-policy",
      expected_source_sha:$wrong_sha,
      approved_release_id:"rel-699-wrong-sha",
      sync_strategy:"rebase",
      chain_worktree:($work_root + "/release-bearing-policy-feature"),
      issues:[{number:69904, issue_worktree:($work_root + "/release-bearing-policy-issue-69904")}]
    }]
  }' >"$plan"

audit="$TMPROOT/wrong-sha-audit.jsonl"
STUDIO_BYPASS_SOURCE_SHA_GATE=1 \
  "$ROOT/scripts/studio-chain-rule-gates.sh" \
    --plan "$plan" \
    --repo "$repo" \
    --expected-run-work-root "$TMPROOT/run-work" \
    --audit-log "$audit" >"$TMPROOT/wrong-sha-gates.json"

jq -e '
  .status == "ok"
  and ([.overrides[] | select(
    .id == "expected_source_branch_sha"
    and .status == "override"
    and .override_env == "STUDIO_BYPASS_SOURCE_SHA_GATE"
  )] | length == 1)
' "$TMPROOT/wrong-sha-gates.json" >/dev/null \
  || release_policy_fail "wrong source SHA override was not reported in gate result"

jq -e --arg wrong_sha "$wrong_sha" '
  select(
    .kind == "studio-chain-rule-gate-audit"
    and .gate_id == "expected_source_branch_sha"
    and .status == "override"
    and .severity == "hard"
    and .override_env == "STUDIO_BYPASS_SOURCE_SHA_GATE"
    and (.detail | contains($wrong_sha))
  )
' "$audit" >/dev/null || release_policy_fail "wrong source SHA override audit row missing"

printf 'PASS: wrong source SHA override audit fixture\n'
