#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-planning"
MANIFEST="$FIXTURE_DIR/composite-manifest.yaml"
MANAGER="$ROOT/scripts/manager-composite-chain.sh"
STUB="$FIXTURE_DIR/stub-manager-plan-chain.sh"
RUN_ID="019e2c8a-9560-7000-8000-000000000001"
HALT_RUN_ID="019e2c8a-9560-7000-8000-000000000002"
MANIFEST_CHILD_RUN_ID="019e2c8a-9560-7000-8000-000000000003"
CROSS_PROJECT_RUN_ID="019e2c8a-9560-7000-8000-000000000004"
TMPROOT="${TMPDIR:-/tmp}/composite-chain-planning.$$"

trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TMPROOT"

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema required"

plan_log="$TMPROOT/plan-calls.log"
init_json=$(HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
  "$MANAGER" init --manifest "$MANIFEST" --run-id "$RUN_ID" --json)
state_path=$(printf '%s\n' "$init_json" | jq -r '.state_path')

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$STUB" STUB_PLAN_LOG="$plan_log" \
  "$MANAGER" plan-active-child --run-id "$RUN_ID" --json > "$TMPROOT/plan.json"

[ "$(wc -l < "$plan_log" | tr -d ' ')" = "1" ] || fail "expected exactly one child plan invocation"
grep -Fq -- "--issue 123" "$plan_log" || fail "first eligible child issue was not planned"
if grep -Fq -- "--include-comments" "$plan_log"; then
  fail "issue child planning should rely on default comment-aware planning, not --include-comments"
fi
if grep -Fq -- "--issue 124" "$plan_log" || grep -Fq -- "--issue 125" "$plan_log"; then
  fail "later child was planned eagerly"
fi

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$state_path" >/dev/null
jq -e '
  .state == "child_planned"
  and .manifest.repo == "v-i-s-h-a-l/generic-dev-studio"
  and .manifest.project == "generic-dev-studio"
  and .current_child_id == "first-child"
  and .children[0].status == "planned"
  and (.children[0].refs.planner_artifact | type == "string")
  and (.children[0].refs.review_artifact | type == "string")
  and (.children[0].refs.work_chain_manifest | type == "string")
  and .children[0].refs.comment_context.comments_included == true
  and .children[0].refs.comment_context.mode == "issue-context-packet"
  and (.children[0].refs.comment_context.packet_path | type == "string")
  and (.children[0].refs.child_issues | length) == 1
  and .children[1].status == "pending"
  and .children[1].refs.planner_artifact == null
  and .children[1].refs.review_artifact == null
  and .children[1].refs.work_chain_manifest == null
  and .children[2].status == "pending"
  and .children[2].refs.planner_artifact == null
' "$state_path" >/dev/null || fail "planned state did not persist only the active child refs"

jq -e '
  .current_child.comment_context.comments_included == true
  and .current_child.comment_context.mode == "issue-context-packet"
' "$TMPROOT/plan.json" >/dev/null || fail "status json did not surface comment-aware child planning context"

halt_log="$TMPROOT/halt-plan-calls.log"
halt_init_json=$(HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio \
  "$MANAGER" init --manifest "$MANIFEST" --run-id "$HALT_RUN_ID" --json)
halt_state_path=$(printf '%s\n' "$halt_init_json" | jq -r '.state_path')

halt_rc=0
if HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$STUB" STUB_PLAN_LOG="$halt_log" \
    STUB_PLAN_STATUS=blocked STUB_PLAN_EXIT_CODE=1 \
    "$MANAGER" plan-active-child --run-id "$HALT_RUN_ID" --json > "$TMPROOT/halt-plan.json" 2>"$TMPROOT/halt-plan.err"; then
  :
else
  halt_rc=$?
fi

[ "$halt_rc" -ne 0 ] || fail "blocked child plan unexpectedly exited zero"
[ "$(wc -l < "$halt_log" | tr -d ' ')" = "1" ] || fail "expected exactly one failed child plan invocation"
if grep -Fq -- "--include-comments" "$halt_log"; then
  fail "blocked issue child planning should rely on default comment-aware planning, not --include-comments"
fi
HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$halt_state_path" >/dev/null
jq -e '
  .state == "halted"
  and .children[0].status == "halted"
  and .children[0].blocked_reason.reason_id == "child_plan_blocked"
  and .children[0].refs.comment_context.comments_included == true
  and .children[0].refs.comment_context.mode == "issue-context-packet"
  and .blocked_reason.reason_id == "child_plan_blocked"
  and (.active_halt_ref.halt_record | type == "string")
  and (.next_command | contains("composite-chain status --run-id"))
  and .children[1].status == "pending"
  and .children[1].refs.planner_artifact == null
' "$halt_state_path" >/dev/null || fail "failed child plan did not record halt state and leave later children pending"

halt_record=$(jq -r '.active_halt_ref.halt_record' "$halt_state_path")
[ -f "$halt_record" ] || fail "halt record was not written"

manifest_child_source="$TMPROOT/child-source.md"
manifest_child_manifest="$TMPROOT/manifest-child-composite.yaml"
printf '# Child source\n' > "$manifest_child_source"
cat > "$manifest_child_manifest" <<YAML
kind: composite-chain
schema_version: 1
name: manifest-child-planning-fixture
mode: sequential
children:
  - id: manifest-child
    source_type: manifest
    manifest_path: $manifest_child_source
YAML

manifest_log="$TMPROOT/manifest-plan-calls.log"
manifest_init_json=$(HOME="$TMPROOT/home-manifest" ACHILLES_PROJECT=generic-dev-studio \
  "$MANAGER" init --manifest "$manifest_child_manifest" --run-id "$MANIFEST_CHILD_RUN_ID" --json)
manifest_state_path=$(printf '%s\n' "$manifest_init_json" | jq -r '.state_path')

HOME="$TMPROOT/home-manifest" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$STUB" STUB_PLAN_LOG="$manifest_log" \
  "$MANAGER" plan-active-child --run-id "$MANIFEST_CHILD_RUN_ID" --json > "$TMPROOT/manifest-plan.json"

grep -Fq -- "--source-file $manifest_child_source" "$manifest_log" || fail "manifest child source-file planning changed"
if grep -Fq -- "--include-comments" "$manifest_log"; then
  fail "manifest child planning unexpectedly requested comment-aware context"
fi
HOME="$TMPROOT/home-manifest" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$manifest_state_path" >/dev/null
jq -e '
  .children[0].refs.comment_context.comments_included == false
  and .children[0].refs.comment_context.mode == "body-only"
' "$manifest_state_path" >/dev/null || fail "manifest child planning did not preserve body-only context"

cross_project_root="$TMPROOT/turnip-repo"
cross_project_manifest="$TMPROOT/cross-project-composite.yaml"
mkdir -p "$cross_project_root"
cross_project_root=$(cd "$cross_project_root" && pwd -P)
cat > "$cross_project_manifest" <<YAML
kind: composite-chain
schema_version: 1
name: cross-project-planning-fixture
mode: sequential
repo: example-org/sample-app
project: sample-app
target_repo_root: $cross_project_root
children:
  - id: turnip-child
    source_type: issue
    issue: 311
YAML

cross_log="$TMPROOT/cross-project-plan-calls.log"
cross_init_json=$(HOME="$TMPROOT/home-cross" ACHILLES_PROJECT=generic-dev-studio \
  "$MANAGER" init --manifest "$cross_project_manifest" --run-id "$CROSS_PROJECT_RUN_ID" --json)
cross_state_path=$(printf '%s\n' "$cross_init_json" | jq -r '.state_path')

jq -e \
  --arg root "$cross_project_root" '
  .manifest.repo == "example-org/sample-app"
  and .manifest.project == "sample-app"
  and .manifest.target_repo_root == $root
  and .children[0].source.issue_url == "https://github.com/example-org/sample-app/issues/311"
  and .children[0].refs.issue_url == "https://github.com/example-org/sample-app/issues/311"
' "$cross_state_path" >/dev/null || fail "cross-project manifest metadata was not normalized into state"

HOME="$TMPROOT/home-cross" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$STUB" STUB_PLAN_LOG="$cross_log" \
  "$MANAGER" plan-active-child --run-id "$CROSS_PROJECT_RUN_ID" --json > "$TMPROOT/cross-plan.json"

grep -Fq -- "--issue 311" "$cross_log" || fail "cross-project child issue was not planned"
grep -Fq -- "--repo example-org/sample-app" "$cross_log" || fail "cross-project child did not pass manifest repo"
grep -Fq -- "--project sample-app" "$cross_log" || fail "cross-project child did not pass manifest project"
grep -Fq -- "--target-repo-root $cross_project_root" "$cross_log" || fail "cross-project child did not pass manifest target repo root"
HOME="$TMPROOT/home-cross" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$cross_state_path" >/dev/null
jq -e '
  .state == "child_planned"
  and (.children[0].refs.plan_result | contains("/.dev-studio/sample-app/plan-chains/"))
  and .children[0].refs.child_issues[0].url == "https://github.com/example-org/sample-app/issues/9001"
  and .children[0].refs.parent_issue.url == "https://github.com/example-org/sample-app/issues/123"
' "$cross_state_path" >/dev/null || fail "cross-project child planning results did not use target project runtime state"

printf 'PASS: composite chain planning\n'
