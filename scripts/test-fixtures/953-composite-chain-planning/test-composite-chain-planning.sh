#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-planning"
MANIFEST="$FIXTURE_DIR/composite-manifest.yaml"
MANAGER="$ROOT/scripts/manager-composite-chain.sh"
STUB="$FIXTURE_DIR/stub-manager-plan-chain.sh"
RUN_ID="019e2c8a-9560-7000-8000-000000000001"
HALT_RUN_ID="019e2c8a-9560-7000-8000-000000000002"
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
if grep -Fq -- "--issue 124" "$plan_log" || grep -Fq -- "--issue 125" "$plan_log"; then
  fail "later child was planned eagerly"
fi

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$state_path" >/dev/null
jq -e '
  .state == "child_planned"
  and .current_child_id == "first-child"
  and .children[0].status == "planned"
  and (.children[0].refs.planner_artifact | type == "string")
  and (.children[0].refs.review_artifact | type == "string")
  and (.children[0].refs.work_chain_manifest | type == "string")
  and (.children[0].refs.child_issues | length) == 1
  and .children[1].status == "pending"
  and .children[1].refs.planner_artifact == null
  and .children[1].refs.review_artifact == null
  and .children[1].refs.work_chain_manifest == null
  and .children[2].status == "pending"
  and .children[2].refs.planner_artifact == null
' "$state_path" >/dev/null || fail "planned state did not persist only the active child refs"

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
HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$halt_state_path" >/dev/null
jq -e '
  .state == "halted"
  and .children[0].status == "halted"
  and .children[0].blocked_reason.reason_id == "child_plan_blocked"
  and .blocked_reason.reason_id == "child_plan_blocked"
  and (.active_halt_ref.halt_record | type == "string")
  and (.next_command | contains("composite-chain status --run-id"))
  and .children[1].status == "pending"
  and .children[1].refs.planner_artifact == null
' "$halt_state_path" >/dev/null || fail "failed child plan did not record halt state and leave later children pending"

halt_record=$(jq -r '.active_halt_ref.halt_record' "$halt_state_path")
[ -f "$halt_record" ] || fail "halt record was not written"

printf 'PASS: composite chain planning\n'
