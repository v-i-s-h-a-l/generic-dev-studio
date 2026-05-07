#!/usr/bin/env bash
# Verifies local-first, affinity-aware iOS check routing.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t ios-check-routing.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

HOME_DIR="$TMPROOT/home"
RUNTIME="$HOME_DIR/.dev-studio/.runtime"
PROJECT_STATE="$HOME_DIR/.dev-studio/fixture/.runtime/state/ios-check-routing"
mkdir -p "$RUNTIME" "$PROJECT_STATE/candidates"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat >"$RUNTIME/nodes.json" <<'JSON'
{
  "nodes": [
    {
      "id": "worker-a",
      "roles": ["xcodebuild", "swift-test"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["none"]
    },
    {
      "id": "worker-b",
      "roles": ["xcodebuild", "swift-test"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["none"]
    }
  ]
}
JSON

write_candidate() {
  local worker="$1" queue_wait="${2:-0}" status="${3:-healthy}"
  cat >"$PROJECT_STATE/candidates/$worker.json" <<JSON
{
  "health_status": "$status",
  "probed_at": "$now",
  "xcode_version": "Xcode 16.4",
  "swift_version": "6.1",
  "simulator_available": true,
  "ram_available_gib": 32,
  "load1": 0.2,
  "queue_depth": 0,
  "queue_wait_s": $queue_wait,
  "cache_warmth": "warm",
  "disk_pressure": "normal"
}
JSON
}

write_proof() {
  local chain="$1" worker="$2"
  mkdir -p "$PROJECT_STATE/source-sync/$chain"
  cat >"$PROJECT_STATE/source-sync/$chain/$worker.json" <<JSON
{
  "source_branch": "main",
  "base_sha": "base-sha",
  "worktree_sha": "worktree-sha",
  "run_id": "run-667",
  "chain_run_id": "chain-run-667",
  "issue_run_id": "issue-run-667",
  "manifest_version": "1",
  "synced_at": "$now"
}
JSON
}

run_route() {
  local chain="$1"
  shift
  HOME="$HOME_DIR" ACHILLES_PROJECT=fixture \
    STUDIO_IOS_ROUTER_PROBE_TTL_S=3600 \
    STUDIO_IOS_ROUTER_SOURCE_SYNC_TTL_S=3600 \
    STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S="${STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S:-60}" \
    STUDIO_IOS_ROUTER_RETRY_COST_S="${STUDIO_IOS_ROUTER_RETRY_COST_S:-60}" \
    STUDIO_IOS_ROUTER_MIN_SAVINGS_S="${STUDIO_IOS_ROUTER_MIN_SAVINGS_S:-120}" \
    "$ROOT/scripts/studio-ios-check-router.sh" explain \
      --operation build \
      --role xcodebuild \
      --chain "$chain" \
      --task-id T667 \
      --source-branch main \
      --base-sha base-sha \
      --worktree-sha worktree-sha \
      --run-id run-667 \
      --chain-run-id chain-run-667 \
      --issue-run-id issue-run-667 \
      --manifest-version 1 \
      --cache-key cache-667 \
      --xcode-version "Xcode 16.4" \
      "$@"
}

write_candidate worker-a 0
write_candidate worker-b 0
write_proof local-first-chain worker-a
write_proof local-first-chain worker-b

local_first=$(run_route local-first-chain)
printf '%s\n' "$local_first" | jq -e '
  .selected_executor == "local"
  and .reason_class == "local_first_manager_available"
  and (.eligibility_predicates | index("source_sync_freshness"))
' >/dev/null || {
  printf '%s\n' "$local_first" >&2
  fail "local-first decision did not prefer manager"
}

write_proof offload-chain worker-a
write_proof offload-chain worker-b
offload=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route offload-chain)
printf '%s\n' "$offload" | jq -e '
  .selected_executor == "worker-a"
  and .reason_class == "worker_offload_beneficial"
  and .economics.manager_savings_s >= 1000
  and .affinity.decision == "set"
' >/dev/null || {
  printf '%s\n' "$offload" >&2
  fail "worker-offload decision did not pick eligible worker with economics"
}

affinity="$PROJECT_STATE/affinity/offload-chain-main-xcodebuild.json"
jq -e '.preferred_executor == "worker-a" and .set_reason == "worker_offload_beneficial"' "$affinity" >/dev/null \
  || fail "offload did not persist chain affinity"

event_log=$(find "$HOME_DIR/.dev-studio/fixture/events" -name '*.jsonl' -type f | head -1)
[ -n "$event_log" ] || fail "routing telemetry event log missing"
grep -q '"event":"ios_check_routing_decision"' "$event_log" || fail "routing telemetry event missing"

fallback=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route no-proof-chain)
printf '%s\n' "$fallback" | jq -e '
  .selected_executor == "local"
  and .reason_class == "no_eligible_worker_fallback"
  and .source_sync_remediation.required == true
  and .source_sync_remediation.candidate_executor == "worker-a"
  and ([.rejected_executors[].reason_class] | index("source_sync_missing"))
' >/dev/null || {
  printf '%s\n' "$fallback" >&2
  fail "no-eligible-worker fallback did not explain rejected workers"
}

write_proof cost-chain worker-a
write_proof cost-chain worker-b
cost_refusal=$(
  STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 \
    STUDIO_IOS_MANAGER_QUEUE_WAIT_S=500 \
    STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S=300 \
    STUDIO_IOS_ROUTER_RETRY_COST_S=120 \
    STUDIO_IOS_ROUTER_MIN_SAVINGS_S=120 \
    run_route cost-chain
)
printf '%s\n' "$cost_refusal" | jq -e '
  .selected_executor == "local"
  and .reason_class == "cost_threshold_refusal"
  and .economics.remote_latency_cost_s == 300
' >/dev/null || {
  printf '%s\n' "$cost_refusal" >&2
  fail "cost-threshold refusal did not keep the job local"
}

write_proof exclude-chain worker-a
write_proof exclude-chain worker-b
excluded=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 STUDIO_IOS_ROUTER_EXCLUDE_WORKERS=worker-a run_route exclude-chain)
printf '%s\n' "$excluded" | jq -e '
  .selected_executor == "worker-b"
  and .reason_class == "worker_offload_beneficial"
  and ([.rejected_executors[] | select(.id == "worker-a") | .reason_class] | index("excluded_by_failover"))
' >/dev/null || {
  printf '%s\n' "$excluded" >&2
  fail "failover exclusion did not route to the alternate eligible worker"
}

write_proof override-chain worker-a
forced=$(run_route override-chain --force-worker worker-a)
printf '%s\n' "$forced" | jq -e '
  .selected_executor == "worker-a"
  and .reason_class == "user_force_worker"
' >/dev/null || {
  printf '%s\n' "$forced" >&2
  fail "force-worker override did not select named eligible worker"
}

status_json=$(HOME="$HOME_DIR" ACHILLES_PROJECT=fixture "$ROOT/scripts/studio-ios-check-router.sh" status --chain offload-chain --json)
printf '%s\n' "$status_json" | jq -e '
  .active_chains[0].preferred_executor == "worker-a"
  and has("queues")
  and has("active_locks")
  and has("active_jobs")
  and has("simulator_slots")
  and has("disk_pressure")
  and has("retained_artifacts")
' >/dev/null || {
  printf '%s\n' "$status_json" >&2
  fail "status view did not expose affinity, queue, lock, and retention fields"
}

HOME="$HOME_DIR" ACHILLES_PROJECT=fixture "$ROOT/scripts/studio-ios-check-router.sh" clear-affinity --chain offload-chain --source-branch main --role xcodebuild >/dev/null
[ ! -f "$affinity" ] || fail "clear-affinity did not remove affinity state"

grep -q 'studio-ios-check-router.sh' "$ROOT/scripts/task-build-gate.sh" \
  || fail "build gate is not wired through the router"
grep -q 'studio-ios-check-router.sh' "$ROOT/scripts/task-test-gate.sh" \
  || fail "test gate is not wired through the router"

printf 'PASS: iOS check routing\n'
