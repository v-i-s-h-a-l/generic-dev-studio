#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-execution"
PLAN_FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-planning"
MANIFEST="$PLAN_FIXTURE_DIR/composite-manifest.yaml"
MANAGER="$ROOT/scripts/manager-composite-chain.sh"
PLAN_STUB="$PLAN_FIXTURE_DIR/stub-manager-plan-chain.sh"
WORK_STUB="$FIXTURE_DIR/stub-manager-work-chain.sh"
RUN_ID="019e2c8a-9570-7000-8000-000000000001"
PENDING_RUN_ID="019e2c8a-9570-7000-8000-000000000002"
HALT_RUN_ID="019e2c8a-9570-7000-8000-000000000003"
RUN_LOOP_ID="019e2c8a-9570-7000-8000-000000000004"
RUN_LOOP_BLOCKED_ID="019e2c8a-9570-7000-8000-000000000005"
RESUME_CONTINUE_ID="019e2c8a-9570-7000-8000-000000000006"
TMPROOT="${TMPDIR:-/tmp}/composite-chain-execution.$$"

trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

plan_first_child() {
  local home="$1" run_id="$2" plan_log="$3" init_json
  init_json=$(HOME="$home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" init --manifest "$MANIFEST" --run-id "$run_id" --json)
  HOME="$home" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$plan_log" \
    "$MANAGER" plan-active-child --run-id "$run_id" --json > "$TMPROOT/$run_id-plan.json"
  printf '%s\n' "$init_json" | jq -r '.state_path'
}

mkdir -p "$TMPROOT"

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema required"
[ -x "$WORK_STUB" ] || fail "work-chain stub must be executable"

plan_log="$TMPROOT/plan-calls.log"
work_log="$TMPROOT/work-calls.log"
state_path=$(plan_first_child "$TMPROOT/home" "$RUN_ID" "$plan_log")

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" STUB_WORK_LOG="$work_log" \
  "$MANAGER" execute-active-child --run-id "$RUN_ID" --json > "$TMPROOT/execute.json"

[ "$(wc -l < "$work_log" | tr -d ' ')" = "1" ] || fail "expected exactly one child work-chain invocation"
work_manifest=$(jq -r '.children[0].refs.work_chain_manifest' "$state_path")
grep -Fq -- "$work_manifest --attended --yes" "$work_log" \
  || fail "execution did not delegate through manager work-chain with attended closeout flags"
if grep -Fq 'studio-chain-runner.sh' "$work_log"; then
  fail "execution fixture should not bypass manager work-chain"
fi

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$state_path" >/dev/null
jq -e '
  .state == "child_completed"
  and .children[0].status == "completed"
  and .children[0].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000101"
  and (.children[0].refs.child_run_state | type == "string")
  and (.children[0].refs.child_run_report | type == "string")
  and (.children[0].refs.completion_summaries | length) == 1
  and (.children[0].refs.issue_urls | index("https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/9001"))
  and (.children[0].refs.pr_urls | index("https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/9901"))
  and .children[1].status == "pending"
  and .children[1].refs.work_chain_manifest == null
  and (.next_command | contains("composite-chain plan-active-child --run-id"))
' "$state_path" >/dev/null || fail "completed child run refs were not persisted correctly"

pending_plan_log="$TMPROOT/pending-plan-calls.log"
pending_state_path=$(plan_first_child "$TMPROOT/home-pending" "$PENDING_RUN_ID" "$pending_plan_log")
pending_rc=0
if HOME="$TMPROOT/home-pending" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$pending_plan_log" \
    "$MANAGER" plan-active-child --run-id "$PENDING_RUN_ID" --json > "$TMPROOT/pending-second-plan.json" 2>"$TMPROOT/pending-second-plan.err"; then
  :
else
  pending_rc=$?
fi
[ "$pending_rc" -ne 0 ] || fail "second child was planned before active child completion"
[ "$(wc -l < "$pending_plan_log" | tr -d ' ')" = "1" ] || fail "second plan invocation should not run while first child is only planned"
jq -e '.children[1].status == "pending" and .children[1].refs.work_chain_manifest == null' "$pending_state_path" >/dev/null \
  || fail "pending child changed before active child completion"

halt_plan_log="$TMPROOT/halt-plan-calls.log"
halt_work_log="$TMPROOT/halt-work-calls.log"
halt_state_path=$(plan_first_child "$TMPROOT/home-halt" "$HALT_RUN_ID" "$halt_plan_log")
halt_rc=0
if HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" STUB_WORK_LOG="$halt_work_log" \
    STUB_WORK_RUN_ID="019e2c8a-9570-7000-8000-000000000102" \
    STUB_WORK_STATUS=failed STUB_WORK_EXIT_CODE=1 \
    "$MANAGER" execute-active-child --run-id "$HALT_RUN_ID" --json > "$TMPROOT/halt-execute.json" 2>"$TMPROOT/halt-execute.err"; then
  :
else
  halt_rc=$?
fi
[ "$halt_rc" -ne 0 ] || fail "failed child work-chain unexpectedly exited zero"
HOME="$TMPROOT/home-halt" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$halt_state_path" >/dev/null
jq -e '
  .state == "halted"
  and .children[0].status == "halted"
  and .children[0].blocked_reason.reason_id == "child_run_failed"
  and .blocked_reason.reason_id == "child_run_failed"
  and (.children[0].refs.child_run_state | type == "string")
  and (.active_halt_ref.halt_record | type == "string")
  and .children[1].status == "pending"
  and .children[1].refs.work_chain_manifest == null
' "$halt_state_path" >/dev/null || fail "failed child run did not halt composite state correctly"

halt_record=$(jq -r '.active_halt_ref.halt_record' "$halt_state_path")
[ -f "$halt_record" ] || fail "execution halt record was not written"

run_loop_plan_log="$TMPROOT/run-loop-plan-calls.log"
run_loop_work_log="$TMPROOT/run-loop-work-calls.log"
HOME="$TMPROOT/home-run-loop" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$run_loop_plan_log" \
  STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" STUB_WORK_LOG="$run_loop_work_log" \
  STUB_WORK_RUN_ID_PREFIX="019e2c8a-9570-7000-8000-00000000010" \
  "$MANAGER" run --manifest "$MANIFEST" --run-id "$RUN_LOOP_ID" --json > "$TMPROOT/run-loop.json"

[ "$(wc -l < "$run_loop_plan_log" | tr -d ' ')" = "3" ] || fail "run loop should plan each child once"
[ "$(wc -l < "$run_loop_work_log" | tr -d ' ')" = "3" ] || fail "run loop should execute each child once"
run_loop_state_path=$(jq -r '.state_path' "$TMPROOT/run-loop.json")
HOME="$TMPROOT/home-run-loop" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$run_loop_state_path" >/dev/null
jq -e '
  .state == "completed"
  and (.children | length) == 3
  and ([.children[].status] | all(. == "completed"))
  and .children[0].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000101"
  and .children[1].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000102"
  and .children[2].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000103"
  and .next_command == null
' "$run_loop_state_path" >/dev/null || fail "run loop did not complete all children"
jq -e '
  .state == "completed"
  and (.remaining_children | length) == 0
  and .next_resume_command == null
' "$TMPROOT/run-loop.json" >/dev/null || fail "run loop did not print final completed status"

blocked_plan_log="$TMPROOT/run-loop-blocked-plan-calls.log"
blocked_work_log="$TMPROOT/run-loop-blocked-work-calls.log"
blocked_rc=0
if HOME="$TMPROOT/home-run-loop-blocked" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$blocked_plan_log" \
    STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" STUB_WORK_LOG="$blocked_work_log" \
    STUB_PLAN_STATUS=blocked STUB_PLAN_EXIT_CODE=1 \
    "$MANAGER" run --manifest "$MANIFEST" --run-id "$RUN_LOOP_BLOCKED_ID" --json > "$TMPROOT/run-loop-blocked.json" 2>"$TMPROOT/run-loop-blocked.err"; then
  :
else
  blocked_rc=$?
fi
[ "$blocked_rc" -ne 0 ] || fail "blocked run loop unexpectedly exited zero"
[ "$(wc -l < "$blocked_plan_log" | tr -d ' ')" = "1" ] || fail "blocked run loop should stop after one plan attempt"
if [ -e "$blocked_work_log" ]; then
  [ "$(wc -l < "$blocked_work_log" | tr -d ' ')" = "0" ] || fail "blocked run loop should not execute children"
fi
blocked_state_path=$(jq -r '.state_path' "$TMPROOT/run-loop-blocked.json")
jq -e '
  .state == "halted"
  and .children[0].status == "halted"
  and .children[1].status == "pending"
  and .blocked_reason.reason_id == "child_plan_blocked"
  and (.next_command | contains("composite-chain status --run-id"))
' "$blocked_state_path" >/dev/null || fail "blocked run loop did not halt after planning blocker"

resume_continue_plan_log="$TMPROOT/resume-continue-plan-calls.log"
resume_continue_work_log="$TMPROOT/resume-continue-work-calls.log"
resume_continue_state_path=$(plan_first_child "$TMPROOT/home-resume-continue" "$RESUME_CONTINUE_ID" "$resume_continue_plan_log")
HOME="$TMPROOT/home-resume-continue" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$resume_continue_plan_log" \
  STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" STUB_WORK_LOG="$resume_continue_work_log" \
  STUB_WORK_RUN_ID_PREFIX="019e2c8a-9570-7000-8000-00000000020" \
  "$MANAGER" resume --run-id "$RESUME_CONTINUE_ID" --continue --json > "$TMPROOT/resume-continue.json"

[ "$(wc -l < "$resume_continue_plan_log" | tr -d ' ')" = "3" ] || fail "resume --continue should finish planning remaining children"
[ "$(wc -l < "$resume_continue_work_log" | tr -d ' ')" = "3" ] || fail "resume --continue should execute planned and remaining children"
HOME="$TMPROOT/home-resume-continue" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$resume_continue_state_path" >/dev/null
jq -e '
  .state == "completed"
  and ([.children[].status] | all(. == "completed"))
  and .children[0].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000201"
  and .children[1].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000202"
  and .children[2].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000203"
' "$resume_continue_state_path" >/dev/null || fail "resume --continue did not complete the composite chain"

printf 'PASS: composite chain execution\n'
