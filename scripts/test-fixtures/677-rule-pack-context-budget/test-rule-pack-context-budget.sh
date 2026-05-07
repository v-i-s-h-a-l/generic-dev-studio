#!/usr/bin/env bash
# Regression coverage for context-budget telemetry on selective rule-pack loading.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RESOLVE="$ROOT/scripts/rule-pack-resolve.sh"
TMPROOT=$(mktemp -d -t rule-pack-context-budget-677.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for rule-pack context-budget fixture\n'
  exit 0
fi

[ -x "$RESOLVE" ] || fail "resolver is not executable"

manifest="$TMPROOT/chain.yaml"
cat >"$manifest" <<'YAML'
schema_version: 1
chains:
  - name: budget-fixture
    base: main
    branch: feature/budget-fixture
    host: codex
    phase_review: off
    rule_packs:
      optional: [privacy]
    issues:
      - number: 67701
        rule_packs:
          optional: [git-workflow]
      - number: 67702
      - number: 67703
      - number: 67704
      - number: 67705
      - number: 67706
YAML

resolve_case() {
  local name="$1" role="$2" mode="$3" phase="$4" issue="$5" classifier="{}"
  [ "$#" -lt 6 ] || classifier="$6"
  "$RESOLVE" \
    --manifest "$manifest" \
    --chain budget-fixture \
    --issue "$issue" \
    --role "$role" \
    --mode "$mode" \
    --phase "$phase" \
    --classifier-json "$classifier" >"$TMPROOT/$name.json"
}

resolve_case planner planner chain_runner plan 67701 '{"touches_public_output":true}'
resolve_case worker worker chain_runner implementation 67702 '{}'
resolve_case reviewer reviewer review review 67703 '{}'
resolve_case ios worker chain_runner implementation 67704 '{"platform_ios":true,"touches_swift":true}'
resolve_case release release-manager chain_runner release 67705 '{"release_job_testflight":true}'
resolve_case cleanup worker chain_runner cleanup 67706 '{"touches_runtime_artifacts":true}'

for case_name in planner worker reviewer ios release cleanup; do
  json="$TMPROOT/$case_name.json"
  jq -e '
    .status == "ok"
    and .context_budget.surface == "rule-pack-resolution"
    and .context_budget.selected_summary_bytes > 0
    and .context_budget.selected_summary_tokens_estimated > 0
    and .context_budget.skipped_full_doc_bytes > 0
    and .context_budget.skipped_full_doc_tokens_estimated > 0
    and .context_budget.cold_context_all_full_doc_tokens_estimated > .context_budget.selected_summary_tokens_estimated
    and .context_budget.cold_context_delta_tokens_estimated > 0
    and .timing.control_plane_rule_selection_s != null
    and .timing.llm_reasoning_s == null
    and .timing.task_execution_s == null
    and (.public_summary.selected_pack_ids | length) == (.selected_packs | length)
    and all(.selected_packs[]; .summary_bytes > 0 and .summary_tokens_estimated > 0)
    and all(.selected_packs[]; .full_doc_loaded == false)
    and all(.skipped_packs[]; .full_doc_loaded == false and .full_doc_bytes > 0 and .full_doc_tokens_estimated > 0)
  ' "$json" >/dev/null || {
    cat "$json" >&2
    fail "$case_name did not include measured context-budget telemetry"
  }
done

jq -e '([.selected_packs[].id] | index("worker-routing")) and ([.selected_packs[].id] | index("review") | not)' "$TMPROOT/worker.json" >/dev/null \
  || fail "worker fixture loaded unrelated review pack"
jq -e '([.selected_packs[].id] | index("review")) and ([.selected_packs[].id] | index("release-routing") | not)' "$TMPROOT/reviewer.json" >/dev/null \
  || fail "reviewer fixture loaded unrelated release pack"
jq -e '([.selected_packs[].id] | index("ios-artifacts")) and ([.selected_packs[].id] | index("release-routing") | not)' "$TMPROOT/ios.json" >/dev/null \
  || fail "iOS fixture loaded unrelated release pack"
jq -e '([.selected_packs[].id] | index("release-routing")) and ([.selected_packs[].id] | index("ios-artifacts"))' "$TMPROOT/release.json" >/dev/null \
  || fail "release fixture did not select release/iOS packs"
jq -e '([.selected_packs[].id] | index("cleanup-retention")) and ([.selected_packs[].id] | index("review") | not)' "$TMPROOT/cleanup.json" >/dev/null \
  || fail "cleanup fixture loaded unrelated review pack"

jq -e '
  .public_summary
  | has("selected_pack_ids")
  and has("skipped_pack_ids")
  and (has("manifest") | not)
  and (has("selected_packs") | not)
' "$TMPROOT/worker.json" >/dev/null || fail "public summary is not path-safe"

printf 'PASS: rule-pack context-budget telemetry\n'
