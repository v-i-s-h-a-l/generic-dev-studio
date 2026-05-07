#!/usr/bin/env bash
# Verifies typed failover decisions for worker-routed iOS build/test checks.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t ios-check-failover.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

HOME_DIR="$TMPROOT/home"
ARTIFACT_ROOT="$TMPROOT/chain-artifacts"
mkdir -p "$HOME_DIR" "$ARTIFACT_ROOT"

route_with_alt="$TMPROOT/route-with-alt.json"
route_local_only="$TMPROOT/route-local-only.json"
route_invalid="$TMPROOT/route-invalid.json"

jq -n '{
  schema_version: 1,
  kind: "studio-ios-routing-decision",
  selected_executor: "worker-a",
  candidates: [
    {id:"local", is_local:true, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:0}},
    {id:"worker-a", is_local:false, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:60}},
    {id:"worker-b", is_local:false, eligible:true, queue:{wait_s:10}, economics:{remote_total_s:70}}
  ]
}' >"$route_with_alt"

jq -n '{
  schema_version: 1,
  kind: "studio-ios-routing-decision",
  selected_executor: "worker-a",
  candidates: [
    {id:"local", is_local:true, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:0}},
    {id:"worker-a", is_local:false, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:60}}
  ]
}' >"$route_local_only"

jq -n '{schema_version: 1, kind: "studio-ios-routing-decision"}' >"$route_invalid"

run_failover() {
  local -a args
  args=(
    decide
    --operation "${1:?operation}"
    --role "${2:?role}"
    --chain ios-v2-execution
    --task-id T668
    --source-branch main
    --run-id run-668
    --chain-run-id chain-run-668
    --issue-run-id issue-668
    --selected-executor worker-a
    --failure-signal "${3:?failure-signal}"
    --exit-code "${4:?exit-code}"
    --attempt "${5:?attempt}"
    --retry-count 0
    --route-decision-file "${6:?route-file}"
  )
  [ -n "${7:-}" ] && args+=(--log "$7")
  [ -n "${8:-}" ] && args+=(--artifact "$8")
  HOME="$HOME_DIR" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" "${args[@]}"
}

disappear_log="$TMPROOT/disappear.log"
printf 'xcodebuild...\nConnection to worker-a closed by remote host\n' >"$disappear_log"
disappeared=$(run_failover build xcodebuild worker_disappeared 255 1 "$route_with_alt" "$disappear_log")
printf '%s\n' "$disappeared" | jq -e '
  .failure.class == "worker_unavailable"
  and .retry.selected_path == "retry_another_worker"
  and .retry.target_executor == "worker-b"
  and .final_outcome == "retry_planned"
  and .retry.finite == true
  and .retry.preserves_original_run_identity == true
  and (.idempotency_keys.failover | contains(":failover:r0:worker_unavailable"))
' >/dev/null || {
  printf '%s\n' "$disappeared" >&2
  fail "mid-build disappearance did not retry another worker"
}

timeout_log="$TMPROOT/timeout.log"
printf 'node-dispatch: remote command exit code: 124\n' >"$timeout_log"
timed_out=$(run_failover test swift-test remote_timeout 124 1 "$route_with_alt" "$timeout_log")
printf '%s\n' "$timed_out" | jq -e '
  .failure.class == "worker_timeout"
  and .retry.selected_path == "retry_another_worker"
  and .retry.target_executor == "worker-b"
  and .retention.retention_class == "aborted-retain"
' >/dev/null || {
  printf '%s\n' "$timed_out" >&2
  fail "timeout did not classify as worker_timeout with alternate-worker retry"
}

missing_log="$TMPROOT/missing-artifact.log"
printf 'BUILD SUCCEEDED but result bundle did not publish\n' >"$missing_log"
missing_artifact="$TMPROOT/missing.xcresult"
artifact_missing=$(run_failover build xcodebuild artifact_missing 0 1 "$route_with_alt" "$missing_log" "$missing_artifact")
printf '%s\n' "$artifact_missing" | jq -e '
  .failure.class == "artifact_missing"
  and .retry.selected_path == "retry_local"
  and .retry.target_executor == "local"
  and .retention.retention_class == "failed-retain"
  and (.retention.partial_artifacts | length) >= 1
' >/dev/null || {
  printf '%s\n' "$artifact_missing" >&2
  fail "artifact-missing path did not pick local retry and retain evidence"
}
retained_log=$(printf '%s\n' "$artifact_missing" | jq -r '.retention.partial_artifacts[] | select(.kind == "log") | .path' | head -1)
[ -n "$retained_log" ] && [ -f "$retained_log" ] || fail "artifact-missing log was not preserved"
[ -f "$ARTIFACT_ROOT/retention/issue-668/1-build-failover.json" ] || fail "retention record missing for failover artifact"

source_drift=$(run_failover build xcodebuild source_sync_worktree_sha_mismatch 2 1 "$route_with_alt" "$disappear_log")
printf '%s\n' "$source_drift" | jq -e '
  .failure.class == "sync_drift"
  and .retry.selected_path == "halt_source_drift"
  and .final_outcome == "halted"
' >/dev/null || {
  printf '%s\n' "$source_drift" >&2
  fail "source drift mismatch did not halt"
}

local_fallback=$(run_failover build xcodebuild worker_unavailable 255 1 "$route_local_only" "$disappear_log")
printf '%s\n' "$local_fallback" | jq -e '
  .failure.class == "worker_unavailable"
  and .retry.selected_path == "retry_local"
  and .retry.target_executor == "local"
' >/dev/null || {
  printf '%s\n' "$local_fallback" >&2
  fail "worker-unavailable without alternate did not retry local"
}

invalid_route=$(run_failover build xcodebuild worker_unavailable 255 1 "$route_invalid" "$disappear_log")
printf '%s\n' "$invalid_route" | jq -e '
  .failure.class == "worker_unavailable"
  and .retry.selected_path == "halt_operator_review"
  and .retry.target_executor == null
  and .routing_considered.status == "route_decision_file_malformed"
  and .routing_considered.local_eligible == false
' >/dev/null || {
  printf '%s\n' "$invalid_route" >&2
  fail "invalid routing context did not halt instead of local fallback"
}

budget_one=$(
  HOME="$HOME_DIR" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" decide \
      --operation build \
      --role xcodebuild \
      --chain ios-v2-execution \
      --task-id T668-budget \
      --source-branch main \
      --run-id run-668 \
      --chain-run-id chain-run-668 \
      --issue-run-id issue-668-budget \
      --selected-executor worker-a \
      --failure-signal worker_unavailable \
      --exit-code 255 \
      --attempt 1 \
      --route-decision-file "$route_local_only"
)
budget_two=$(
  HOME="$HOME_DIR" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" decide \
      --operation build \
      --role xcodebuild \
      --chain ios-v2-execution \
      --task-id T668-budget \
      --source-branch main \
      --run-id run-668 \
      --chain-run-id chain-run-668 \
      --issue-run-id issue-668-budget \
      --selected-executor worker-a \
      --failure-signal worker_unavailable \
      --exit-code 255 \
      --attempt 1 \
      --route-decision-file "$route_local_only"
)
budget_three=$(
  HOME="$HOME_DIR" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" decide \
      --operation build \
      --role xcodebuild \
      --chain ios-v2-execution \
      --task-id T668-budget \
      --source-branch main \
      --run-id run-668 \
      --chain-run-id chain-run-668 \
      --issue-run-id issue-668-budget \
      --selected-executor worker-a \
      --failure-signal worker_unavailable \
      --exit-code 255 \
      --attempt 1 \
      --route-decision-file "$route_local_only"
)
printf '%s\n%s\n%s\n' "$budget_one" "$budget_two" "$budget_three" | jq -s -e '
  .[0].retry.retry_count == 0
  and .[0].retry.selected_path == "retry_local"
  and .[1].retry.retry_count == 1
  and .[1].retry.selected_path == "retry_local"
  and .[2].retry.retry_count == 2
  and .[2].retry.selected_path == "halt_retry_exhausted"
' >/dev/null || {
  printf '%s\n%s\n%s\n' "$budget_one" "$budget_two" "$budget_three" >&2
  fail "durable retry budget did not halt after max retries"
}

event_log=$(find "$HOME_DIR/.dev-studio/fixture/events" -name '*.jsonl' -type f | head -1)
[ -n "$event_log" ] || fail "failover telemetry event log missing"
grep -q '"event":"ios_check_failover_decision"' "$event_log" || fail "failover telemetry event missing"

printf 'PASS: iOS check failover\n'
