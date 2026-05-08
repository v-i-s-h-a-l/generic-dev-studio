#!/usr/bin/env bash
# End-to-end regression coverage for the v2 iOS execution contract.

set -euo pipefail
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t ios-execution-contract-671.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 required"
}

assert_json() {
  local json="$1" filter="$2" message="$3"
  printf '%s\n' "$json" | jq -e "$filter" >/dev/null || {
    printf '%s\n' "$json" >&2
    fail "$message"
  }
}

assert_file_json() {
  local file="$1" filter="$2" message="$3"
  jq -e "$filter" "$file" >/dev/null || {
    cat "$file" >&2
    fail "$message"
  }
}

arg_after() {
  local flag="$1" args_file="$2"
  awk -v flag="$flag" 'previous == flag { print; exit } { previous = $0 }' "$args_file"
}

require_command jq
require_command yq

for fixture in \
  scripts/test-fixtures/664-source-branch-chain/test-source-branch-chain.sh \
  scripts/test-fixtures/666-ios-artifact-retention/test-ios-artifact-retention.sh \
  scripts/test-fixtures/667-ios-check-routing/test-ios-check-routing.sh \
  scripts/test-fixtures/668-ios-check-failover/test-ios-check-failover.sh \
  scripts/test-fixtures/669-release-routing/test-release-routing.sh \
  scripts/test-fixtures/670-ios-execution-telemetry/test-ios-execution-telemetry.sh
do
  bash "$ROOT/$fixture" >/dev/null || fail "upstream fixture failed: $fixture"
done

SCHEMA="$ROOT/core/v2/schemas/chain-manifest.schema.json"
IOS_CONTRACT="$ROOT/_shared/contracts/ios-isolated-execution.md"
TELEMETRY_CONTRACT="$ROOT/_shared/contracts/chain-run-telemetry.md"

jq -e '
  ."$defs".chain.properties.source_branch.default == "main"
  and ."$defs".chain.properties.base.default == "main"
  and ."$defs".chain.properties.sync_strategy.enum == ["rebase", "squash"]
  and ."$defs".chain.properties.execution_policy["$ref"] == "#/$defs/execution_policy"
  and ."$defs".execution_policy.properties.build_test_affinity.default == "chain"
  and ."$defs".execution_policy.properties.derived_data_scope.default == "chain-lane"
  and ."$defs".execution_policy.properties.prefer_local_manager.default == true
  and ."$defs".execution_policy.properties.max_affinity_queue_wait_sec.default == 900
  and ."$defs".execution_policy.properties.artifact_retention.default == "default"
  and ."$defs".execution_policy.properties.offload_economics.default == "required"
  and (."$defs".execution_policy.properties.build_test_affinity.enum | index("worker-owned") == null)
  and (."$defs".execution_policy.properties.derived_data_scope.enum | index("global") == null)
  and (."$defs".execution_policy.properties.offload_economics.enum | index("always") == null)
' "$SCHEMA" >/dev/null || fail "manifest schema does not encode execution_policy defaults and invalid-value refusals"

yq -e '
  .chains[] | select(.name == "ios-v2-execution") |
  (.execution_policy.build_test_affinity == "chain" and
  .execution_policy.derived_data_scope == "chain-lane" and
  .execution_policy.prefer_local_manager == true and
  .execution_policy.max_affinity_queue_wait_sec == 900 and
  .execution_policy.offload_economics == "required")
' "$ROOT/chains/ios-v2-execution.yaml" >/dev/null || fail "ios-v2-execution manifest does not declare the expected policy"

grep -Fq '## v1 Migration Capture' "$IOS_CONTRACT" || fail "iOS contract missing v1 migration capture gate"
grep -Fq 'secret-bearing release details stay in private runtime artifacts' "$IOS_CONTRACT" \
  || fail "iOS migration capture gate missing privacy boundary"
grep -Fq 'control-plane overhead, source sync, simulator boot, xcodebuild, tests, log parsing, and cleanup' "$TELEMETRY_CONTRACT" \
  || fail "telemetry contract missing separated iOS timing fields"

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "iOS contract fixture $issue",
  "body": "Synthetic fixture body.",
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

old_manifest="$TMPROOT/old-manifest.yaml"
cat > "$old_manifest" <<'YAML'
schema_version: 1
chains:
  - name: old-compatible
    branch: feature/old-compatible
    host: codex
    phase_review: off
    issues: [67101]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$old_manifest" --dry-run > "$TMPROOT/old-dry-run.out" 2>&1
grep -Fq 'Source branch: `main`' "$TMPROOT/old-dry-run.out" || fail "old manifest did not default source branch to main"
grep -Fq 'Leaf sync strategy: `rebase`' "$TMPROOT/old-dry-run.out" || fail "old manifest did not default leaf sync strategy"

source_manifest="$TMPROOT/source-policy.yaml"
cat > "$source_manifest" <<'YAML'
schema_version: 1
chains:
  - name: source-policy
    source_branch: feature/ios-contract-source
    branch: feature/ios-contract-chain
    host: codex
    phase_review: off
    execution_policy:
      build_test_affinity: chain
      derived_data_scope: chain-lane
      prefer_local_manager: true
      max_affinity_queue_wait_sec: 120
      artifact_retention: failure-retain
      offload_economics: advisory
    issues:
      - number: 67102
      - number: 67103
        dependencies: [67102]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$source_manifest" --dry-run > "$TMPROOT/source-dry-run.out" 2>&1
grep -Fq 'Source branch: `feature/ios-contract-source`' "$TMPROOT/source-dry-run.out" \
  || fail "dry-run did not explain explicit source branch"
grep -Fq 'Planned PR: base `feature/ios-contract-source`, head `feature/ios-contract-chain`' "$TMPROOT/source-dry-run.out" \
  || fail "dry-run did not target source branch as PR base"
grep -q 'studio-chain-runner: issue #67102 ->' "$TMPROOT/source-dry-run.out" \
  || fail "dry-run did not schedule first issue"
grep -q 'studio-chain-runner: issue #67103 ->' "$TMPROOT/source-dry-run.out" \
  || fail "dry-run did not schedule dependent issue"

# Independent issue worktrees should launch from the chain branch and merge back
# through the chain integration worktree without touching the source branch.
. "$ROOT/scripts/lib-chain-git.sh"
REPO="$TMPROOT/repo"
CHAIN_WORKTREE="$TMPROOT/chain-worktree"
ISSUE_ONE="$TMPROOT/issue-one"
ISSUE_TWO="$TMPROOT/issue-two"
git init -q "$REPO"
git -C "$REPO" config user.name "iOS Contract Fixture"
git -C "$REPO" config user.email "fixture@example.invalid"
mkdir -p "$REPO/scripts"
printf 'base\n' > "$REPO/base.txt"
printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/scripts/noop.sh"
git -C "$REPO" add base.txt scripts/noop.sh
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -M main
git -C "$REPO" checkout -q -b feature/ios-contract-source
printf 'source\n' > "$REPO/source.txt"
git -C "$REPO" add source.txt
git -C "$REPO" commit -q -m "source"
source_before=$(git -C "$REPO" rev-parse feature/ios-contract-source)
git -C "$REPO" worktree add -q -B feature/ios-contract-chain "$CHAIN_WORKTREE" feature/ios-contract-source

chain_git_prepare_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/ios-contract-chain "$ISSUE_ONE" feature/ios-contract-chain-issue-one local-clone
chain_git_prepare_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/ios-contract-chain "$ISSUE_TWO" feature/ios-contract-chain-issue-two local-clone
git -C "$ISSUE_ONE" config user.name "iOS Contract Fixture"
git -C "$ISSUE_ONE" config user.email "fixture@example.invalid"
git -C "$ISSUE_TWO" config user.name "iOS Contract Fixture"
git -C "$ISSUE_TWO" config user.email "fixture@example.invalid"
printf 'issue one\n' > "$ISSUE_ONE/one.txt"
git -C "$ISSUE_ONE" add one.txt
git -C "$ISSUE_ONE" commit -q -m "bugfix-wip: fixture issue one"
printf 'issue two\n' > "$ISSUE_TWO/two.txt"
git -C "$ISSUE_TWO" add two.txt
git -C "$ISSUE_TWO" commit -q -m "bugfix-wip: fixture issue two"
chain_git_integrate_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/ios-contract-chain "$ISSUE_ONE" feature/ios-contract-chain-issue-one local-clone rebase
chain_git_integrate_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/ios-contract-chain "$ISSUE_TWO" feature/ios-contract-chain-issue-two local-clone rebase
[ -f "$CHAIN_WORKTREE/one.txt" ] || fail "first independent issue did not integrate into chain branch"
[ -f "$CHAIN_WORKTREE/two.txt" ] || fail "second independent issue did not integrate into chain branch"
[ "$(git -C "$REPO" rev-parse feature/ios-contract-source)" = "$source_before" ] || fail "issue integration mutated source branch"
[ -z "$(git -C "$CHAIN_WORKTREE" rev-list --merges feature/ios-contract-source..HEAD)" ] || fail "rebase-first integration introduced merge commits"

PLAN="$TMPROOT/rule-gate-plan.json"
jq -n \
  --arg work_root "$TMPROOT/run-work" \
  --arg source_sha "$source_before" \
  '{
    schema_version: 1,
    chains: [{
      name: "ios-contract-gates",
      source_branch: "feature/ios-contract-source",
      base: "feature/ios-contract-source",
      expected_source_sha: $source_sha,
      branch: "feature/ios-contract-chain",
      sync_strategy: "rebase",
      chain_worktree: ($work_root + "/chain"),
      issues: [{number: 67104, issue_worktree: ($work_root + "/issue")}]
    }]
  }' > "$PLAN"
LOCK_DIR="$TMPROOT/source-locks"
mkdir -p "$LOCK_DIR"
STUDIO_SOURCE_BRANCH_LOCK_DIR="$LOCK_DIR" RUN_ID=run-671 \
  "$ROOT/scripts/studio-chain-rule-gates.sh" --plan "$PLAN" --repo "$REPO" --expected-run-work-root "$TMPROOT/run-work" > "$TMPROOT/gates-pass.json"
assert_file_json "$TMPROOT/gates-pass.json" '
  .status == "ok"
  and ([.checks[] | select(.id == "expected_source_branch_sha" and .status == "passed")] | length == 1)
  and ([.checks[] | select(.id == "source_branch_lock" and .status == "passed")] | length == 1)
  and ([.checks[] | select(.id == "no_feature_branch_merge_commits" and .status == "passed")] | length == 1)
' "source-branch gates did not pass for isolated chain plan"

printf 'other-run\n' > "$LOCK_DIR/feature_ios-contract-source.lock"
if STUDIO_SOURCE_BRANCH_LOCK_DIR="$LOCK_DIR" RUN_ID=run-671 \
  "$ROOT/scripts/studio-chain-rule-gates.sh" --plan "$PLAN" --repo "$REPO" --expected-run-work-root "$TMPROOT/run-work" > "$TMPROOT/gates-lock-fail.json"; then
  fail "source branch lock held by another run unexpectedly passed"
fi
assert_file_json "$TMPROOT/gates-lock-fail.json" '.status == "halt" and ([.failures[] | select(.id == "source_branch_lock")] | length == 1)' \
  "source branch lock failure was not typed"

ROUTER_HOME="$TMPROOT/router-home"
RUNTIME="$ROUTER_HOME/.dev-studio/.runtime"
PROJECT_STATE="$ROUTER_HOME/.dev-studio/fixture/.runtime/state/ios-check-routing"
mkdir -p "$RUNTIME" "$PROJECT_STATE/candidates"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_nodes() {
  cat > "$RUNTIME/nodes.json"
}

write_candidate() {
  local worker="$1" queue_wait="${2:-0}" status="${3:-healthy}" cache="${4:-warm}" disk="${5:-normal}" stale="${6:-false}"
  cat > "$PROJECT_STATE/candidates/$worker.json" <<JSON
{
  "health_status": "$status",
  "probed_at": "$now",
  "xcode_version": "Xcode 16.4",
  "swift_version": "6.1",
  "simulator_available": true,
  "simulator_slots": [{"runtime":"iOS 18.4","device":"iPhone 16","slot":"slot-1","state":"idle"}],
  "ram_available_gib": 32,
  "load1": 0.2,
  "queue_depth": 0,
  "queue_wait_s": $queue_wait,
  "cache_warmth": "$cache",
  "disk_pressure": "$disk",
  "stale": $stale
}
JSON
}

write_proof() {
  local chain="$1" worker="$2" worktree_sha="${3:-worktree-sha}"
  mkdir -p "$PROJECT_STATE/source-sync/$chain"
  cat > "$PROJECT_STATE/source-sync/$chain/$worker.json" <<JSON
{
  "source_branch": "feature/ios-source",
  "base_sha": "base-sha",
  "worktree_sha": "$worktree_sha",
  "run_id": "run-671",
  "chain_run_id": "chain-run-671",
  "issue_run_id": "issue-run-671",
  "manifest_version": "1",
  "synced_at": "$now"
}
JSON
}

run_route() {
  local chain="$1" operation="$2" role="$3"
  shift 3
  HOME="$ROUTER_HOME" ACHILLES_PROJECT=fixture \
    STUDIO_IOS_ROUTER_PROBE_TTL_S=3600 \
    STUDIO_IOS_ROUTER_SOURCE_SYNC_TTL_S=3600 \
    STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S=60 \
    STUDIO_IOS_ROUTER_RETRY_COST_S=60 \
    STUDIO_IOS_ROUTER_MIN_SAVINGS_S=120 \
    STUDIO_IOS_ROUTER_OVERHEAD_BUDGET_MS=100000 \
    "$ROOT/scripts/studio-ios-check-router.sh" explain \
      --operation "$operation" \
      --role "$role" \
      --chain "$chain" \
      --task-id T671 \
      --source-branch feature/ios-source \
      --base-sha base-sha \
      --worktree-sha worktree-sha \
      --run-id run-671 \
      --chain-run-id chain-run-671 \
      --issue-run-id issue-run-671 \
      --manifest-version 1 \
      --xcode-version "Xcode 16.4" \
      "$@"
}

write_nodes <<'JSON'
{
  "nodes": [
    {"id":"worker-a","roles":["xcodebuild","swift-test"],"enabled":true,"parallel_build_slots":1,"secret_scopes":["none"]},
    {"id":"worker-b","roles":["xcodebuild","swift-test"],"enabled":true,"parallel_build_slots":1,"secret_scopes":["none"]}
  ]
}
JSON
write_candidate worker-a
write_candidate worker-b
write_proof contract-chain worker-a
write_proof contract-chain worker-b

affinity_file="$PROJECT_STATE/affinity/contract-chain-feature-ios-source-xcodebuild.json"
dry_route=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route contract-chain build xcodebuild --cache-key cache-a --dry-run)
assert_json "$dry_route" '.selected_executor == "worker-a" and .scheduler.overhead_ms >= 0 and .scheduler.over_budget == false' \
  "dry-run router explanation did not show scheduler overhead and worker choice"
[ ! -f "$affinity_file" ] || fail "dry-run routing should not persist affinity"

offload=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route contract-chain build xcodebuild --cache-key cache-a)
assert_json "$offload" '.selected_executor == "worker-a" and .reason_class == "worker_offload_beneficial" and .affinity.decision == "set"' \
  "worker offload did not set chain affinity"
[ -f "$affinity_file" ] || fail "worker offload did not write affinity file"

reuse=$(run_route contract-chain build xcodebuild --cache-key cache-a)
assert_json "$reuse" '.selected_executor == "worker-a" and .reason_class == "affinity_reused" and .affinity.decision == "reused"' \
  "subsequent build/test job did not reuse chain affinity"

cache_break=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route contract-chain build xcodebuild --cache-key cache-b)
assert_json "$cache_break" '.affinity.break_reason == "cold_or_invalid_cache" and .cache.key == "cache-b"' \
  "cache key drift did not break affinity"

user_break=$(run_route contract-chain build xcodebuild --cache-key cache-b --break-affinity)
assert_json "$user_break" '.selected_executor == "local" and .affinity.break_reason == "user_override"' \
  "break-affinity override did not keep build local with a recorded reason"

forced_local=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route contract-chain build xcodebuild --force-local)
assert_json "$forced_local" '.selected_executor == "local" and .reason_class == "user_force_local"' \
  "force-local override did not select local manager"

forced_worker=$(run_route contract-chain build xcodebuild --force-worker worker-b)
assert_json "$forced_worker" '.selected_executor == "worker-b" and .reason_class == "user_force_worker"' \
  "force-worker override did not select named worker"

light_task=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route contract-chain implementation worker --cache-key cache-b)
assert_json "$light_task" '.selected_executor == "local" and .reason_class == "local_first_light_check"' \
  "non-build task did not parallelize away from the build/test affinity executor"

HOME="$ROUTER_HOME" ACHILLES_PROJECT=fixture "$ROOT/scripts/studio-ios-check-router.sh" clear-affinity \
  --chain contract-chain --source-branch feature/ios-source --role xcodebuild >/dev/null
[ ! -f "$affinity_file" ] || fail "clear-affinity did not remove manager-owned affinity state"

write_nodes <<'JSON'
{
  "nodes": [
    {"id":"worker-a","roles":["xcodebuild","swift-test"],"enabled":true,"parallel_build_slots":1,"secret_scopes":["none"]}
  ]
}
JSON
write_candidate worker-a 0 healthy warm high
write_proof pressure-chain worker-a
pressure=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route pressure-chain build xcodebuild --cache-key cache-pressure)
assert_json "$pressure" '
  .selected_executor == "local"
  and .reason_class == "no_eligible_worker_fallback"
  and ([.rejected_executors[] | select(.id == "worker-a") | .reason_class] | index("disk_pressure"))
' "disk-pressure worker was not refused before accepting a build/test job"

write_candidate worker-a 0 healthy warm normal
write_proof stale-proof-chain worker-a wrong-worktree-sha
stale_proof=$(STUDIO_IOS_MANAGER_BUSY_BUILD_TEST=1 STUDIO_IOS_MANAGER_QUEUE_WAIT_S=1200 run_route stale-proof-chain build xcodebuild --cache-key cache-stale)
assert_json "$stale_proof" '
  .selected_executor == "local"
  and ([.rejected_executors[] | select(.id == "worker-a") | .reason_class] | index("source_sync_worktree_sha_mismatch"))
  and .source_sync_remediation.required == true
' "stale worker source-sync proof was not refused with remediation"

mkdir -p "$RUNTIME/build-queue/worker-a" "$RUNTIME/xcodebuild-lock/worker-a/slot-1"
printf '123456789\n' > "$RUNTIME/xcodebuild-lock/worker-a/slot-1/pid"
cat > "$RUNTIME/build-queue/worker-a/1-0000000001-111-T671.json" <<'JSON'
{"id":"T671","priority":"task","enqueued_at":1,"pid":111,"role":"xcodebuild"}
JSON
write_candidate worker-a 300 healthy warm normal true
status_json=$(HOME="$ROUTER_HOME" ACHILLES_PROJECT=fixture "$ROOT/scripts/studio-ios-check-router.sh" status --chain contract-chain --json)
assert_json "$status_json" '
  has("queues")
  and has("active_locks")
  and has("simulator_slots")
  and has("disk_pressure")
  and has("stale_workers")
  and (.queues | length) >= 1
  and (.active_locks | length) >= 1
  and (.simulator_slots[0].simulator_slots | length) >= 1
' "status view did not expose queue, lock, simulator, disk-pressure, and stale-worker state"

FAILOVER_HOME="$TMPROOT/failover-home"
FAILOVER_ARTIFACT_ROOT="$TMPROOT/failover-artifacts"
mkdir -p "$FAILOVER_HOME" "$FAILOVER_ARTIFACT_ROOT"
route_with_alt="$TMPROOT/route-with-alt.json"
jq -n '{
  schema_version: 1,
  kind: "studio-ios-routing-decision",
  selected_executor: "worker-a",
  candidates: [
    {id:"local", is_local:true, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:0}},
    {id:"worker-a", is_local:false, eligible:true, queue:{wait_s:0}, economics:{remote_total_s:60}},
    {id:"worker-b", is_local:false, eligible:true, queue:{wait_s:10}, economics:{remote_total_s:70}}
  ]
}' > "$route_with_alt"

run_failover() {
  local task="$1" signal="$2" exit_code="${3:-1}"
  HOME="$FAILOVER_HOME" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$FAILOVER_ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" decide \
      --operation build \
      --role xcodebuild \
      --chain ios-v2-execution \
      --task-id "$task" \
      --source-branch feature/ios-source \
      --run-id run-671 \
      --chain-run-id chain-run-671 \
      --issue-run-id "issue-$task" \
      --selected-executor worker-a \
      --failure-signal "$signal" \
      --exit-code "$exit_code" \
      --attempt 1 \
      --retry-count 0 \
      --route-decision-file "$route_with_alt"
}

stale_lock=$(run_failover T671-lock stale_lock 3)
assert_json "$stale_lock" '
  .failure.class == "stale_lock"
  and .retry.selected_path == "reclaim_stale_lock_then_retry"
  and .retention.retention_class == "aborted-retain"
  and (.lock_recovery.lock_order == ["scheduler_queue","source_branch","worker_slot","simulator_slot","artifact_publication","cleanup"])
' "stale-lock failover did not preserve lock recovery contract"

sim_timeout=$(run_failover T671-sim-timeout simulator_slot_timeout 124)
assert_json "$sim_timeout" '
  .failure.class == "simulator_slot_timeout"
  and .retry.selected_path == "retry_another_worker"
  and .simulator_recovery.slot_timeout != null
' "simulator slot timeout did not select a retryable simulator recovery path"

sim_mismatch=$(run_failover T671-sim-runtime simulator_runtime_mismatch 2)
assert_json "$sim_mismatch" '
  .failure.class == "simulator_runtime_mismatch"
  and .retry.selected_path == "halt_operator_review"
  and .final_outcome == "halted"
  and .retention.retention_class == "blocked-retain"
' "simulator runtime mismatch did not halt at the safety boundary"

cache_poison=$(run_failover T671-cache cache_poisoning 65)
assert_json "$cache_poison" '
  .failure.class == "cache_poisoning"
  and .retry.selected_path == "quarantine_cache_then_retry_local_cold"
  and .retention.retention_class == "cache-quarantined"
' "cache poisoning did not require quarantine before retry"

sync_missing=$(run_failover T671-sync source_sync_missing 1)
assert_json "$sync_missing" '
  .failure.class == "sync_drift"
  and .retry.selected_path == "retry_same_worker_after_source_sync"
  and .retry.preserves_original_run_identity == true
' "missing source-sync proof did not retry only after refreshing same-run identity"

malformed_artifact="$TMPROOT/malformed.json"
printf '{not json\n' > "$malformed_artifact"
artifact_malformed=$(
  HOME="$FAILOVER_HOME" ACHILLES_PROJECT=fixture STUDIO_CHAIN_ARTIFACT_ROOT="$FAILOVER_ARTIFACT_ROOT" \
    "$ROOT/scripts/studio-ios-check-failover.sh" decide \
      --operation build \
      --role xcodebuild \
      --chain ios-v2-execution \
      --task-id T671-artifact \
      --source-branch feature/ios-source \
      --run-id run-671 \
      --chain-run-id chain-run-671 \
      --issue-run-id issue-T671-artifact \
      --selected-executor worker-a \
      --failure-signal artifact_malformed \
      --exit-code 0 \
      --attempt 1 \
      --retry-count 0 \
      --artifact "$malformed_artifact" \
      --artifact-kind json \
      --route-decision-file "$route_with_alt"
)
assert_json "$artifact_malformed" '
  .failure.class == "artifact_malformed"
  and .retry.selected_path == "halt_operator_review"
  and .idempotency_keys.failover != .idempotency_keys.result_reporting
  and .idempotency_keys.result_reporting != .idempotency_keys.artifact_publication
' "artifact malformed path did not halt with separate idempotency keys"

XCODE_BIN="$TMPROOT/xcode-bin"
PROJECT="$TMPROOT/FixtureProject"
ARTIFACT_ROOT="$TMPROOT/xcode-artifacts"
mkdir -p "$XCODE_BIN" "$PROJECT/Fixture.xcodeproj"
cat > "$XCODE_BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -eu
[ -n "${XCODEBUILD_CAPTURE:-}" ] || {
  printf 'XCODEBUILD_CAPTURE is required\n' >&2
  exit 2
}
printf '%s\0' "$@" > "$XCODEBUILD_CAPTURE"
printf '** BUILD SUCCEEDED **\n'
printf 'log parsing fixture line\n'
exit "${XCODEBUILD_RC:-0}"
SH
chmod +x "$XCODE_BIN/xcodebuild"

run_xcode_stable() {
  local capture="$1" lane="$2" package_hash="$3" settings_hash="$4" xcode_version="$5" operation="${6:-build}"
  PATH="$XCODE_BIN:$PATH" \
    XCODEBUILD_CAPTURE="$capture" \
    STUDIO_PROJECT_ROOT="$PROJECT" \
    STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT/stable" \
    STUDIO_IOS_SCHEME="Fixture" \
    STUDIO_IOS_CONFIGURATION="Debug" \
    STUDIO_IOS_SDK="iphonesimulator" \
    STUDIO_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" \
    STUDIO_IOS_XCODE_VERSION="$xcode_version" \
    STUDIO_IOS_SIMULATOR_RUNTIME="iOS 18.4" \
    STUDIO_IOS_DEVICE_CLASS="iPhone 16" \
    STUDIO_IOS_PACKAGE_GRAPH_HASH="$package_hash" \
    STUDIO_IOS_BUILD_SETTINGS_HASH="$settings_hash" \
    STUDIO_IOS_SOURCE_BRANCH="feature/ios-source" \
    STUDIO_IOS_BASE_COMMIT="base-sha" \
    STUDIO_IOS_WORKTREE_COMMIT="worktree-sha" \
    STUDIO_IOS_EXECUTOR_ID="$lane" \
    STUDIO_IOS_LANE_ID="$lane" \
    STUDIO_IOS_PATH_SENSITIVITY="project-root-sha256:fixture" \
    "$ROOT/profiles/ios-turnip/commands/xcode-operation" "$operation" >/dev/null
}

run_xcode_stable "$TMPROOT/xcode-a1.args0" worker-a package-a settings-a "Xcode 16.4"
run_xcode_stable "$TMPROOT/xcode-a2.args0" worker-a package-a settings-a "Xcode 16.4"
run_xcode_stable "$TMPROOT/xcode-b.args0" worker-b package-a settings-a "Xcode 16.4"
run_xcode_stable "$TMPROOT/xcode-package.args0" worker-a package-b settings-a "Xcode 16.4"
run_xcode_stable "$TMPROOT/xcode-settings.args0" worker-a package-a settings-b "Xcode 16.4"
run_xcode_stable "$TMPROOT/xcode-toolchain.args0" worker-a package-a settings-a "Xcode 17.0"

for f in "$TMPROOT"/xcode-*.args0; do
  tr '\0' '\n' < "$f" > "${f%.args0}.args"
done
dd_a1=$(arg_after -derivedDataPath "$TMPROOT/xcode-a1.args")
dd_a2=$(arg_after -derivedDataPath "$TMPROOT/xcode-a2.args")
dd_b=$(arg_after -derivedDataPath "$TMPROOT/xcode-b.args")
dd_package=$(arg_after -derivedDataPath "$TMPROOT/xcode-package.args")
dd_settings=$(arg_after -derivedDataPath "$TMPROOT/xcode-settings.args")
dd_toolchain=$(arg_after -derivedDataPath "$TMPROOT/xcode-toolchain.args")
[ "$dd_a1" = "$dd_a2" ] || fail "sequential chain did not reuse stable chain integration cache"
case "$dd_a1" in "$ARTIFACT_ROOT/stable/DerivedData/lanes/worker-a/"*) ;; *) fail "worker-a DerivedData path was not lane scoped" ;; esac
case "$dd_b" in "$ARTIFACT_ROOT/stable/DerivedData/lanes/worker-b/"*) ;; *) fail "worker-b DerivedData path was not lane scoped" ;; esac
[ "$dd_a1" != "$dd_b" ] || fail "parallel workers shared one writable DerivedData root"
[ "$dd_a1" != "$dd_package" ] || fail "package graph drift did not invalidate DerivedData cache key"
[ "$dd_a1" != "$dd_settings" ] || fail "build settings drift did not invalidate DerivedData cache key"
[ "$dd_a1" != "$dd_toolchain" ] || fail "toolchain drift did not invalidate DerivedData cache key"
assert_file_json "$dd_a1.metadata.json" '.cache_state == "stable" and .inputs.executor_id == "worker-a" and .inputs.package_graph_hash == "package-a"' \
  "worker-a cache metadata missing stable cache inputs"
assert_file_json "$dd_b.metadata.json" '.cache_state == "stable" and .inputs.executor_id == "worker-b"' \
  "worker-b cache metadata missing executor identity"

printf '{"schema_version":1,"cache_key":"wrong"}\n' > "$dd_a1.metadata.json"
run_xcode_stable "$TMPROOT/xcode-quarantine.args0" worker-a package-a settings-a "Xcode 16.4"
find "$ARTIFACT_ROOT/stable/quarantine/cache" -type d -name 'cache-*' 2>/dev/null | grep -q . \
  || fail "metadata mismatch did not quarantine stale DerivedData"
tr '\0' '\n' < "$TMPROOT/xcode-quarantine.args0" > "$TMPROOT/xcode-quarantine.args"
dd_quarantine=$(arg_after -derivedDataPath "$TMPROOT/xcode-quarantine.args")
assert_file_json "$dd_quarantine.metadata.json" '.cache_state == "cold_metadata_mismatch"' \
  "quarantine rerun did not fail closed to cold metadata-mismatch cache"

[ ! -e "$ARTIFACT_ROOT/stable/logs/standalone/1-build.log" ] || fail "passed xcodebuild log was not pruned after summary extraction"
[ -f "$ARTIFACT_ROOT/stable/summaries/standalone/1-build.summary.txt" ] || fail "passed xcodebuild summary was not retained"

set +e
PATH="$XCODE_BIN:$PATH" \
  XCODEBUILD_CAPTURE="$TMPROOT/xcode-fail.args0" \
  XCODEBUILD_RC=65 \
  STUDIO_PROJECT_ROOT="$PROJECT" \
  STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT/failure" \
  STUDIO_IOS_ARTIFACT_COMPRESS_MIN_BYTES=1 \
  STUDIO_IOS_SCHEME="Fixture" \
  "$ROOT/profiles/ios-turnip/commands/xcode-operation" test-unit >/dev/null
fail_rc=$?
set -e
[ "$fail_rc" -eq 65 ] || fail "failing xcodebuild fixture did not preserve xcodebuild exit code"
[ -f "$ARTIFACT_ROOT/failure/logs/standalone/1-test-unit.log.gz" ] || fail "failed xcodebuild log was not retained and compressed"
assert_file_json "$ARTIFACT_ROOT/failure/retention/standalone/1-test-unit.json" '.retention_class == "failed-retain"' \
  "failed xcodebuild retention record missing failed-retain class"

RUN_ROOT="$TMPROOT/telemetry-run"
SUMMARY_ROOT="$RUN_ROOT/worker-summaries"
EVENTS_JSONL="$RUN_ROOT/events.jsonl"
mkdir -p "$SUMMARY_ROOT"
cat > "$SUMMARY_ROOT/issue-671.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "run-671",
  "chain_run_id": "chain-run-671",
  "issue_run_id": "issue-run-671",
  "chain": "ios-v2-execution",
  "issue_number": 671,
  "host": "codex",
  "model": "gpt-test",
  "tokens": {"total": 10},
  "exit_code": 0,
  "duration_s": 120,
  "files_changed": 1,
  "additions": 1,
  "deletions": 0,
  "generated_file_count": 0,
  "tests": [{"command":"fixture-test","outcome":"pass"}],
  "lints": [],
  "builds": [{"command":"fixture-build","outcome":"pass"}],
  "execution_telemetry": {
    "schema_version": 1,
    "profile": "ios",
    "executors": {
      "implementation": {"executor": "local-manager"},
      "build": {"executor": "worker-a"},
      "test": {"executor": "worker-a"},
      "review": {"executor": "codex-reviewer"},
      "release": {"executor": "release-a", "channel": "testflight"}
    },
    "routing": {
      "reason_class": "worker_offload_beneficial",
      "control_plane": {"scheduler_overhead_ms": 42, "overhead_budget_ms": 500, "over_budget": false}
    },
    "timing": {
      "source_sync_s": 3,
      "simulator_boot_s": 8,
      "xcodebuild_s": 90,
      "tests_s": 40,
      "log_parsing_s": 2,
      "cleanup_s": 1
    },
    "artifacts": {
      "private_roots": [{"kind": "chain_artifact_root", "path": "$RUN_ROOT/private-ios-artifacts"}],
      "public_classes": ["summary", "result_bundle", "log"]
    },
    "cleanup": {"outcome": "deleted", "retention_class": "pass-summary-only", "ttl_class": "success-summary-only"}
  },
  "telemetry_gaps": []
}
JSON
cat > "$EVENTS_JSONL" <<'JSONL'
{"schema_version":1,"run_id":"run-671","created_at":"2026-05-08T00:00:01Z","event":"release_priority_routing_decision","stage":"release","status":"completed","task":"671","chain_run_id":"chain-run-671","issue_run_id":"issue-run-671","data":{"selected_executor":"release-a","reason_class":"release_capable_secret_scoped_worker","paths_redacted":true}}
JSONL

awk '/^chain_efficiency_metrics_json\(\)/,/^write_run_state\(\)/ { if ($0 !~ /^write_run_state\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/efficiency-functions.sh"
# shellcheck source=/dev/null
. "$TMPROOT/efficiency-functions.sh"
metrics=$(chain_efficiency_metrics_json completed "")
assert_json "$metrics" '
  .execution_telemetry.timing.reports_with_timing == 1
  and .execution_telemetry.timing.control_plane_overhead_ms == 42
  and .execution_telemetry.timing.source_sync_s == 3
  and .execution_telemetry.timing.simulator_boot_s == 8
  and .execution_telemetry.timing.xcodebuild_s == 90
  and .execution_telemetry.timing.tests_s == 40
  and .execution_telemetry.timing.log_parsing_s == 2
  and .execution_telemetry.timing.cleanup_s == 1
' "chain efficiency metrics did not keep iOS timing phases separate"

cat > "$RUN_ROOT/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-671",
  "manifest": "chains/ios-v2-execution.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:00:20Z",
  "chains": [
    {
      "name": "ios-v2-execution",
      "chain_run_id": "chain-run-671",
      "status": "completed",
      "issues": [{"number": 671, "status": "completed"}]
    }
  ],
  "efficiency_metrics": $metrics
}
JSON
"$ROOT/scripts/studio-chain-telemetry-digest.sh" --chain-run-root "$RUN_ROOT" --since 2026-05-08 --until 2026-05-08 --format json > "$TMPROOT/digest.json"
assert_file_json "$TMPROOT/digest.json" '
  .counters.event_counts.release_priority_routing_decision == 1
  and .counters.execution_telemetry.timing.control_plane_overhead_ms == 42
  and .counters.execution_telemetry.timing.xcodebuild_s == 90
  and .counters.execution_telemetry.release_executors["release-a"] == 1
' "telemetry digest did not roll up release routing and separated iOS timing"

jq -e --arg root "$RUN_ROOT" '
  (.execution_telemetry.artifacts.private_roots[0].path | startswith($root))
  and (.execution_telemetry.artifacts.public_classes | all(.[]; (contains("/") | not)))
' "$SUMMARY_ROOT/issue-671.json" >/dev/null || {
  cat "$SUMMARY_ROOT/issue-671.json" >&2
  fail "worker summary did not keep public-safe artifact classes separate from private artifact roots"
}

printf 'PASS: v2 iOS execution contract fixture\n'
