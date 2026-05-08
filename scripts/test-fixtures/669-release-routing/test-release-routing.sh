#!/usr/bin/env bash
# Verifies release/TestFlight priority routing for secret-scoped machines.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t release-routing.XXXXXX)
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

write_nodes() {
  cat >"$RUNTIME/nodes.json"
}

write_candidate() {
  local worker="$1" status="${2:-healthy}"
  cat >"$PROJECT_STATE/candidates/$worker.json" <<JSON
{
  "health_status": "$status",
  "probed_at": "$now",
  "xcode_version": "Xcode 16.4",
  "swift_version": "6.1",
  "simulator_available": true,
  "ram_available_gib": 32,
  "load1": 0.2,
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
  "run_id": "run-669",
  "chain_run_id": "chain-run-669",
  "issue_run_id": "issue-run-669",
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
    "$ROOT/scripts/studio-ios-check-router.sh" explain \
      --operation release:testflight \
      --role release \
      --release-channel testflight \
      --chain "$chain" \
      --task-id R669 \
      --source-branch main \
      --base-sha base-sha \
      --worktree-sha worktree-sha \
      --run-id run-669 \
      --chain-run-id chain-run-669 \
      --issue-run-id issue-run-669 \
      --manifest-version 1 \
      --xcode-version "Xcode 16.4" \
      "$@"
}

write_nodes <<'JSON'
{
  "nodes": [
    {
      "id": "build-only",
      "roles": ["xcodebuild", "swift-test"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["none"]
    },
    {
      "id": "release-a",
      "roles": ["xcodebuild", "release"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["asc", "slack"]
    }
  ]
}
JSON
write_candidate build-only
write_candidate release-a
write_proof capable-chain build-only
write_proof capable-chain release-a

capable=$(run_route capable-chain)
printf '%s\n' "$capable" | jq -e '
  .selected_executor == "release-a"
  and .job_class == "release"
  and .priority == "release"
  and .release.routing_policy == "capability_secret_priority_first"
  and .release.operator_approval_required == true
  and .selected_candidate.predicates.release.capable == true
  and ([.rejected_executors[] | select(.id == "build-only") | .reason_class] | index("role_mismatch"))
' >/dev/null || {
  printf '%s\n' "$capable" >&2
  fail "capable release machine was not selected by release predicates"
}

event_log=$(find "$HOME_DIR/.dev-studio/fixture/events" -name '*.jsonl' -type f | head -1)
[ -n "$event_log" ] || fail "release routing telemetry event log missing"
grep -q '"event":"release_priority_routing_decision"' "$event_log" || fail "release priority telemetry event missing"

write_nodes <<'JSON'
{
  "nodes": [
    {
      "id": "release-no-scopes",
      "roles": ["xcodebuild", "release"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": []
    }
  ]
}
JSON
rm -rf "$PROJECT_STATE/source-sync/no-secret-chain"
write_candidate release-no-scopes
write_proof no-secret-chain release-no-scopes

no_secret=$(run_route no-secret-chain)
printf '%s\n' "$no_secret" | jq -e '
  .selected_executor == null
  and .reason_class == "release_no_capable_secret_scoped_executor"
  and ([.rejected_executors[] | select(.id == "release-no-scopes") | .reason_class] | index("secret_scope_mismatch"))
  and ([.rejected_executors[] | select(.id == "release-no-scopes") | .predicates.release.required_secret_scopes[]] | index("asc"))
' >/dev/null || {
  printf '%s\n' "$no_secret" >&2
  fail "missing release secret scopes did not refuse dispatch"
}

write_nodes <<'JSON'
{
  "nodes": [
    {
      "id": "release-a",
      "roles": ["xcodebuild", "release"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["asc", "slack"]
    }
  ]
}
JSON
rm -rf "$PROJECT_STATE/source-sync/queue-chain"
write_candidate release-a
write_proof queue-chain release-a
QUEUE="$RUNTIME/build-queue/release-a"
mkdir -p "$QUEUE"
cat >"$QUEUE/1-0000000001-111-T669.json" <<'JSON'
{"id":"T669","priority":"task","enqueued_at":1,"pid":111,"role":"xcodebuild","secret_scope":"none"}
JSON
cat >"$QUEUE/2-0000000002-222-BG669.json" <<'JSON'
{"id":"BG669","priority":"background","enqueued_at":2,"pid":222,"role":"xcodebuild","secret_scope":"none"}
JSON

priority=$(run_route queue-chain)
printf '%s\n' "$priority" | jq -e '
  .selected_executor == "release-a"
  and .queue.selected_priority == "release"
  and .preemption.status == "safe_boundary"
  and .preemption.safe_boundary == "before_job_start"
  and .preemption.displaced_count == 2
  and .preemption.displaced_work_retains_cache_artifacts == true
  and (.preemption.displaced_jobs | index("T669"))
' >/dev/null || {
  printf '%s\n' "$priority" >&2
  fail "release priority did not preempt queued normal work at a safe boundary"
}

rm -rf "$QUEUE"
mkdir -p "$RUNTIME/xcodebuild-lock/release-a/slot-1"
waiting=$(run_route queue-chain)
printf '%s\n' "$waiting" | jq -e '
  .selected_executor == "release-a"
  and .preemption.status == "waiting"
  and .preemption.refused == true
  and .preemption.reason == "running_job_not_at_safe_boundary"
' >/dev/null || {
  printf '%s\n' "$waiting" >&2
  fail "release routing did not refuse mid-write preemption"
}
rm -rf "$RUNTIME/xcodebuild-lock/release-a"

printf 'self-669\n' >"$RUNTIME/machine-id"
write_nodes <<'JSON'
{
  "nodes": [
    {
      "id": "self-laptop",
      "machine_id": "self-669",
      "roles": ["xcodebuild", "release"],
      "enabled": true,
      "parallel_build_slots": 1,
      "secret_scopes": ["asc", "slack"]
    }
  ]
}
JSON

local_fallback=$(run_route local-chain --allow-release-local-fallback)
printf '%s\n' "$local_fallback" | jq -e '
  .selected_executor == "local"
  and .reason_class == "release_local_fallback_allowed"
  and .selected_candidate.predicates.release.capable == true
  and .selected_candidate.predicates.release.allow_local_fallback == true
' >/dev/null || {
  printf '%s\n' "$local_fallback" >&2
  fail "explicit local release fallback did not select a secret-scoped local machine"
}

printf 'PASS: release/TestFlight priority routing\n'
