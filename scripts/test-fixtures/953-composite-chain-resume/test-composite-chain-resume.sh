#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PLAN_FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-planning"
EXECUTION_FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-execution"
MANIFEST="$PLAN_FIXTURE_DIR/composite-manifest.yaml"
MANAGER="$ROOT/scripts/manager-composite-chain.sh"
PLAN_STUB="$PLAN_FIXTURE_DIR/stub-manager-plan-chain.sh"
WORK_STUB="$EXECUTION_FIXTURE_DIR/stub-manager-work-chain.sh"
RUN_ID="019e2c8a-9580-7000-8000-000000000001"
HALT_RUN_ID="019e2c8a-9580-7000-8000-000000000002"
COMPLETE_RUN_ID="019e2c8a-9580-7000-8000-000000000003"
STALE_MISSING_RUN_ID="019e2c8a-9580-7000-8000-000000000004"
CHILD_HALT_RUN_ID="019e2c8a-9580-7000-8000-000000000102"
CHILD_COMPLETE_RUN_ID="019e2c8a-9580-7000-8000-000000000103"
CHILD_STALE_COMPLETE_RUN_ID="019e2c8a-9580-7000-8000-000000000104"
TMPROOT="${TMPDIR:-/tmp}/composite-chain-resume.$$"

trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

plan_first_child() {
  local home="$1" run_id="$2" plan_log="$3" manifest="${4:-$MANIFEST}" init_json
  init_json=$(HOME="$home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" init --manifest "$manifest" --run-id "$run_id" --json)
  HOME="$home" ACHILLES_PROJECT=generic-dev-studio \
    STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT="$PLAN_STUB" STUB_PLAN_LOG="$plan_log" \
    "$MANAGER" plan-active-child --run-id "$run_id" --json > "$TMPROOT/$run_id-plan.json"
  printf '%s\n' "$init_json" | jq -r '.state_path'
}

write_single_child_manifest() {
  local manifest="$1"
  cat > "$manifest" <<'YAML'
kind: composite-chain
schema_version: 1
name: stale-missing-reconcile
mode: sequential
children:
  - id: first-child
    source_type: issue
    issue: 9004
YAML
}

write_child_state() {
  local home="$1" run_id="$2" manifest="$3" status="$4" halt_path="${5:-}"
  local root report
  root="$home/.dev-studio/generic-dev-studio/chain-runs/$run_id"
  report="$root/report.md"
  mkdir -p "$root"
  printf '# Child report\n' > "$report"
  jq -n \
    --arg run_id "$run_id" \
    --arg manifest "$manifest" \
    --arg status "$status" \
    --arg report "$report" \
    --arg halt_path "$halt_path" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest: $manifest,
      status: $status,
      started_at: "2026-05-15T17:00:00Z",
      updated_at: "2026-05-15T17:01:00Z",
      report: $report,
      halt_records: (
        if $halt_path == "" then []
        else [{
          reason_id: "reviewer_blocked",
          halt_class: "fatal",
          status: "terminated",
          path: $halt_path,
          next_safe_action: "Inspect child reviewer findings before retry."
        }]
        end
      ),
      chains: [
        {
          chain_run_id: "019e2c8a-9580-7000-8000-000000000201",
          name: "first-child",
          status: $status,
          pr_url: (if $status == "completed" then "https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/9903" else null end),
          issues: [
            {
              issue_run_id: "019e2c8a-9580-7000-8000-000000000301",
              number: 9003,
              status: $status,
              url: "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/9003",
              summary: $report
            }
          ]
        }
      ]
    }' > "$root/state.json"
  printf '%s/state.json\n' "$root"
}

mark_first_child_running() {
  local state_path="$1" child_state="$2" child_run_id="$3" tmp
  tmp="$state_path.tmp"
  jq \
    --arg child_state "$child_state" \
    --arg child_run_id "$child_run_id" '
      .state = "running_child"
      | .children[0].status = "running"
      | .children[0].refs.child_run_id = $child_run_id
      | .children[0].refs.child_run_state = $child_state
      | .children[0].blocked_reason = null
      | .active_halt_ref = null
      | .blocked_reason = null
      | .next_command = ("/dev-studio manager composite-chain resume --run-id " + .composite_run_id)
    ' "$state_path" > "$tmp"
  mv "$tmp" "$state_path"
}

mkdir -p "$TMPROOT"

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema required"
[ -x "$WORK_STUB" ] || fail "work-chain stub must be executable"

process_exit_home="$TMPROOT/home-process-exit"
process_state_path=$(plan_first_child "$process_exit_home" "$RUN_ID" "$TMPROOT/process-plan.log")
HOME="$process_exit_home" ACHILLES_PROJECT=generic-dev-studio \
  STUDIO_COMPOSITE_WORK_CHAIN_SCRIPT="$WORK_STUB" \
  "$MANAGER" resume --run-id "$RUN_ID" --json > "$TMPROOT/process-resume.json"

HOME="$process_exit_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$process_state_path" >/dev/null
jq -e '
  .state == "child_completed"
  and .children[0].status == "completed"
  and .children[0].refs.child_run_id == "019e2c8a-9570-7000-8000-000000000101"
  and .current_child_id == "second-child"
  and .children[1].status == "pending"
  and (.next_command | contains("composite-chain plan-active-child --run-id"))
' "$process_state_path" >/dev/null || fail "resume by run id did not read durable state and complete the planned child"

halt_home="$TMPROOT/home-child-halt"
halt_state_path=$(plan_first_child "$halt_home" "$HALT_RUN_ID" "$TMPROOT/halt-plan.log")
halt_work_manifest=$(jq -r '.children[0].refs.work_chain_manifest' "$halt_state_path")
halt_ref="$halt_home/.dev-studio/generic-dev-studio/chain-runs/$CHILD_HALT_RUN_ID/halts/reviewer-blocked.json"
mkdir -p "$(dirname "$halt_ref")"
printf '{"reason_id":"reviewer_blocked"}\n' > "$halt_ref"
halt_child_state=$(write_child_state "$halt_home" "$CHILD_HALT_RUN_ID" "$halt_work_manifest" "paused" "$halt_ref")
mark_first_child_running "$halt_state_path" "$halt_child_state" "$CHILD_HALT_RUN_ID"

halt_rc=0
if HOME="$halt_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" resume --run-id "$HALT_RUN_ID" --json > "$TMPROOT/halt-resume.json" 2>"$TMPROOT/halt-resume.err"; then
  :
else
  halt_rc=$?
fi
[ "$halt_rc" -ne 0 ] || fail "fatal child halt unexpectedly resumed"
HOME="$halt_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$halt_state_path" >/dev/null
jq -e \
  --arg child_halt_ref "$halt_ref" '
  .state == "halted"
  and .children[0].status == "halted"
  and .blocked_reason.reason_id == "reviewer_blocked"
  and .active_halt_ref.child_id == "first-child"
  and .active_halt_ref.child_run_id == "019e2c8a-9580-7000-8000-000000000102"
  and .active_halt_ref.child_halt_ref == $child_halt_ref
  and (.active_halt_ref.next_safe_action | contains("Inspect child reviewer findings"))
  and (.next_command | contains("composite-chain resume --run-id"))
  and .children[1].status == "pending"
  and .children[1].refs.work_chain_manifest == null
' "$halt_state_path" >/dev/null || fail "child halt did not map into composite halt state without advancing"

complete_home="$TMPROOT/home-completed-child"
complete_state_path=$(plan_first_child "$complete_home" "$COMPLETE_RUN_ID" "$TMPROOT/complete-plan.log")
complete_work_manifest=$(jq -r '.children[0].refs.work_chain_manifest' "$complete_state_path")
complete_child_state=$(write_child_state "$complete_home" "$CHILD_COMPLETE_RUN_ID" "$complete_work_manifest" "completed")
mark_first_child_running "$complete_state_path" "$complete_child_state" "$CHILD_COMPLETE_RUN_ID"

HOME="$complete_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" resume --run-id "$COMPLETE_RUN_ID" --json > "$TMPROOT/complete-resume.json"
HOME="$complete_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$complete_state_path" >/dev/null
jq -e '
  .state == "child_completed"
  and .children[0].status == "completed"
  and .children[0].blocked_reason == null
  and .children[1].status == "pending"
  and .current_child_id == "second-child"
  and .current_child_index == 1
  and (.next_command | contains("composite-chain plan-active-child --run-id"))
' "$complete_state_path" >/dev/null || fail "completed child did not advance composite pointer to the next pending child"

stale_home="$TMPROOT/home-stale-missing"
stale_manifest="$TMPROOT/stale-missing-manifest.yaml"
write_single_child_manifest "$stale_manifest"
stale_state_path=$(plan_first_child "$stale_home" "$STALE_MISSING_RUN_ID" "$TMPROOT/stale-plan.log" "$stale_manifest")
stale_work_manifest=$(jq -r '.children[0].refs.work_chain_manifest' "$stale_state_path")
stale_details_ref="$(dirname "$stale_state_path")/execution/first-child/manager-work-chain.err"
mkdir -p "$(dirname "$stale_details_ref")"
printf 'no durable state yet\n' > "$stale_details_ref"

jq \
  --arg details_ref "$stale_details_ref" '
    .state = "halted"
    | .children[0].status = "halted"
    | .children[0].blocked_reason = {
        reason_id: "child_run_state_missing",
        summary: "Resume could not find durable child chain state.",
        details_ref: $details_ref
      }
    | .blocked_reason = .children[0].blocked_reason
    | .active_halt_ref = {
        reason_id: "child_run_state_missing",
        halt_record: ((.source_ref.manifest_path | split("/")[:-1] | join("/")) + "/stale-missing-placeholder.json"),
        child_id: "first-child"
      }
    | .children[0].refs.child_halt_ref = .active_halt_ref.halt_record
    | .next_command = ("/dev-studio manager composite-chain resume --run-id " + .composite_run_id)
  ' "$stale_state_path" > "$stale_state_path.tmp"
mv "$stale_state_path.tmp" "$stale_state_path"

HOME="$stale_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$stale_state_path" >/dev/null
stale_halt_record=$(jq -r '.active_halt_ref.halt_record' "$stale_state_path")
mkdir -p "$(dirname "$stale_halt_record")"
printf '{"reason_id":"child_run_state_missing"}\n' > "$stale_halt_record"
stale_child_state=$(write_child_state "$stale_home" "$CHILD_STALE_COMPLETE_RUN_ID" "$stale_work_manifest" "completed")

HOME="$stale_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" resume --run-id "$STALE_MISSING_RUN_ID" --json > "$TMPROOT/stale-resume.json"
HOME="$stale_home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$stale_state_path" >/dev/null
[ -f "$stale_halt_record" ] || fail "historical child_run_state_missing halt record was deleted during reconciliation"
jq -e \
  --arg stale_child_state "$stale_child_state" '
  .state == "completed"
  and .children[0].status == "completed"
  and .children[0].refs.child_run_id == "019e2c8a-9580-7000-8000-000000000104"
  and .children[0].refs.child_run_state == $stale_child_state
  and .children[0].refs.child_halt_ref == null
  and .children[0].blocked_reason == null
  and .blocked_reason == null
  and .active_halt_ref == null
  and .next_command == null
' "$stale_state_path" >/dev/null || fail "stale child_run_state_missing blocker survived completed child reconciliation"

printf 'PASS: composite chain resume\n'
