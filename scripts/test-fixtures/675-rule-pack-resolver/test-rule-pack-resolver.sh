#!/usr/bin/env bash
# Regression coverage for manifest-declared Studio rule-pack resolution.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RESOLVE="$ROOT/scripts/rule-pack-resolve.sh"
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
SCHEMA="$ROOT/core/v2/schemas/chain-manifest.schema.json"
TMPROOT=$(mktemp -d -t rule-pack-resolver-675.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for rule-pack resolver fixture\n'
  exit 0
fi

[ -x "$RESOLVE" ] || fail "resolver is not executable"
[ -f "$SCHEMA" ] || fail "missing chain manifest schema"
jq -e '
  .properties.execution_policy["$ref"] == "#/$defs/execution_policy"
  and ."$defs".chain.properties.execution_policy["$ref"] == "#/$defs/execution_policy"
  and (."$defs".execution_policy.properties.build_test_affinity.enum == ["chain", "none"])
  and (."$defs".execution_policy.properties.derived_data_scope.enum == ["chain-lane", "issue"])
  and (."$defs".execution_policy.properties.offload_economics.enum == ["required", "advisory", "disabled"])
' "$SCHEMA" >/dev/null || fail "chain manifest schema missing execution policy contract"

manifest="$TMPROOT/chain.yaml"
cat >"$manifest" <<'YAML'
schema_version: 1
rule_packs:
  required: [privacy]
  advisory: [missing-advisory]
execution_policy:
  build_test_affinity: chain
  derived_data_scope: chain-lane
  prefer_local_manager: true
  max_affinity_queue_wait_sec: 900
  artifact_retention: default
  offload_economics: required
chains:
  - name: resolver-fixture
    base: main
    branch: feature/resolver-fixture
    host: codex
    phase_review: off
    rule_packs:
      optional: [review]
    issues:
      - number: 67501
        rule_packs:
          required: [git-workflow]
YAML

"$RESOLVE" \
  --manifest "$manifest" \
  --chain resolver-fixture \
  --issue 67501 \
  --role worker \
  --mode chain_runner \
  --classifier-json '{"touches_public_output":true}' >"$TMPROOT/resolve.json"

jq -e '
  .schema_version == 1
  and .kind == "studio-v2-rule-pack-resolution"
  and .status == "ok"
  and (.compatibility.argus_frontmatter_compatible == true)
  and ([.selected_packs[].id] | index("privacy"))
  and ([.selected_packs[].id] | index("git-workflow"))
  and ([.selected_packs[] | select(.id == "review" and .metadata_path == "core/v2/rule-packs/review/pack.yaml")] | length == 1)
  and ([.warnings[] | select(.pack_id == "missing-advisory")] | length == 1)
  and (.estimated_context_cost.summary_tokens_estimated > 0)
  and (.estimated_context_cost.summary_bytes > 0)
  and (.estimated_context_cost.skipped_full_doc_tokens_estimated > 0)
  and (.context_budget.surface == "rule-pack-resolution")
  and (.timing.llm_reasoning_s == null)
' "$TMPROOT/resolve.json" >/dev/null || {
  cat "$TMPROOT/resolve.json" >&2
  fail "resolver did not select explicit, optional, overlay, and advisory packs"
}

missing_required="$TMPROOT/missing-required.yaml"
cat >"$missing_required" <<'YAML'
schema_version: 1
rule_packs:
  required: [does-not-exist]
chains:
  - name: blocked
    issues: [67502]
YAML

if "$RESOLVE" --manifest "$missing_required" --chain blocked >"$TMPROOT/blocked.json"; then
  cat "$TMPROOT/blocked.json" >&2
  fail "missing required pack unexpectedly passed"
fi
jq -e '
  .status == "halt"
  and .halt.reason_id == "rule_pack_resolution_blocked"
  and ([.blockers[] | select(.reason_id == "rule_pack_required_missing" and .pack_id == "does-not-exist")] | length == 1)
' "$TMPROOT/blocked.json" >/dev/null || {
  cat "$TMPROOT/blocked.json" >&2
  fail "missing required pack did not produce typed halt JSON"
}

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"
cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Rule pack resolver fixture $issue",
  "body": "Exercise dry-run rule-pack output.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$manifest" --dry-run >"$TMPROOT/dry-run.out" 2>&1
grep -q '### Rule Packs' "$TMPROOT/dry-run.out" || fail "dry-run did not print rule-pack section"
grep -q 'privacy | selected' "$TMPROOT/dry-run.out" || fail "dry-run did not list selected required pack"
grep -q 'review | selected' "$TMPROOT/dry-run.out" || fail "dry-run did not list selected optional pack"
grep -q 'estimated summary tokens' "$TMPROOT/dry-run.out" || fail "dry-run did not list estimated context cost"
grep -q 'cold-context delta' "$TMPROOT/dry-run.out" || fail "dry-run did not list context-budget delta"
grep -q 'missing-advisory | warning' "$TMPROOT/dry-run.out" || fail "dry-run did not list advisory warning"

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$missing_required" --dry-run >"$TMPROOT/dry-run-blocked.out" 2>&1; then
  cat "$TMPROOT/dry-run-blocked.out" >&2
  fail "dry-run with missing required pack unexpectedly passed"
fi
grep -q 'does-not-exist | blocker | rule_pack_required_missing' "$TMPROOT/dry-run-blocked.out" \
  || fail "dry-run did not surface missing required blocker"
grep -q 'rule-pack resolution blocked' "$TMPROOT/dry-run-blocked.out" \
  || fail "dry-run did not fail closed with rule-pack halt"

printf 'PASS: rule-pack resolver manifest and dry-run behavior\n'
