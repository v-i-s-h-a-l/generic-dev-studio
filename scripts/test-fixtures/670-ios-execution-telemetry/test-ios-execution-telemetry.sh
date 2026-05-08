#!/usr/bin/env bash
# Verifies iOS execution telemetry roll-up, gaps, and private/public artifact split.
# shellcheck disable=SC2034

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t ios-execution-telemetry.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RUN_ID="019e6700-1111-7000-8000-111111111111"
CHAIN_RUN_ID="019e6700-2222-7000-8000-222222222222"
ISSUE_RUN_ID_MISSING="019e6700-3333-7000-8000-333333333333"
ATTEMPT_ID="019e6700-4444-7000-8000-444444444444"

RUN_ROOT="$TMPROOT/run"
SUMMARY_ROOT="$RUN_ROOT/worker-summaries"
EVENTS_JSONL="$RUN_ROOT/events.jsonl"
RUN_STATE_JSON="$RUN_ROOT/state.json"
RUN_REPORT="$RUN_ROOT/report.md"
HALT_ROOT="$RUN_ROOT/halt-records"
ESCROW_ROOT="$RUN_ROOT/decision-escrows"
PHASE_REVIEW_ROOT="$RUN_ROOT/phase-reviews"
CHAIN_RUN_ROOT="$RUN_ROOT"
WORK="$TMPROOT/work"
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$PHASE_REVIEW_ROOT" "$WORK/.studio"
: > "$EVENTS_JSONL"

awk '/^codex_home_for_worker\(\)/,/^worker_summary_tracked\(\)/ { if ($0 !~ /^worker_summary_tracked\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/summary-functions.sh"
awk '/^chain_efficiency_metrics_json\(\)/,/^write_run_state\(\)/ { if ($0 !~ /^write_run_state\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/efficiency-functions.sh"
awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/report-functions.sh"

iso_ts_now() { printf '2026-05-08T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }
diff_stats_json() { printf '{"files_changed":1,"additions":10,"deletions":1,"generated_file_count":0}\n'; }
changed_artifacts_json() { printf '[]\n'; }
emit_chain_event() { :; }
emit_summary_telemetry_gaps() { :; }

# shellcheck source=/dev/null
. "$TMPROOT/summary-functions.sh"
# shellcheck source=/dev/null
. "$TMPROOT/efficiency-functions.sh"
# shellcheck source=/dev/null
. "$TMPROOT/report-functions.sh"

cat > "$WORK/.studio/chain-worker-summary.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "chain": "ios-v2-execution",
  "issue_number": 67003,
  "host": "codex",
  "model": "gpt-test",
  "tokens": {"total": 100},
  "exit_code": 0,
  "tests": [{"command":"fixture-test","outcome":"pass"}],
  "lints": [],
  "builds": [{"command":"fixture-build","outcome":"pass"}],
  "telemetry_gaps": []
}
JSON

missing_summary=$(ingest_worker_summary ios-v2-execution 67003 codex "$WORK" before after 0 100 "$CHAIN_RUN_ID" "$ISSUE_RUN_ID_MISSING" "$TMPROOT/missing-telemetry.json")
jq -e '
  ((.telemetry_gaps // []) | index("implementation_executor"))
  and ((.telemetry_gaps // []) | index("build_executor"))
  and ((.telemetry_gaps // []) | index("test_executor"))
  and ((.telemetry_gaps // []) | index("worker_routing"))
  and ((.telemetry_gaps // []) | index("artifact_evidence"))
  and ((.telemetry_gaps // []) | index("cleanup_telemetry"))
' "$missing_summary" >/dev/null || {
  cat "$missing_summary" >&2
  fail "iOS worker summary missing evidence did not emit loud gaps"
}

cat > "$SUMMARY_ROOT/issue-67001.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "019e6700-5555-7000-8000-555555555555",
  "chain": "ios-v2-execution",
  "issue_number": 67001,
  "host": "codex",
  "model": "gpt-test",
  "tokens": {"total": 200},
  "exit_code": 0,
  "duration_s": 20,
  "files_changed": 1,
  "additions": 5,
  "deletions": 0,
  "generated_file_count": 0,
  "tests": [{"command":"local-test","outcome":"pass"}],
  "lints": [],
  "builds": [{"command":"local-build","outcome":"pass"}],
  "execution_telemetry": {
    "schema_version": 1,
    "profile": "ios",
    "executors": {
      "implementation": {"executor": "local-manager", "node": "manager"},
      "build": {"executor": "local-manager", "node": "manager"},
      "test": {"executor": "local-manager", "node": "manager"},
      "review": {"executor": "codex-reviewer", "node": "reviewer"}
    },
    "routing": {
      "reason_class": "local_first_manager_available",
      "cost_summary": "local manager available; remote setup avoided",
      "economics": {"manager_queue_wait_s": 0, "remote_latency_cost_s": 60, "retry_cost_s": 60},
      "control_plane": {"scheduler_overhead_ms": 12, "overhead_budget_ms": 500, "over_budget": false}
    },
    "artifacts": {
      "private_roots": [{"kind": "chain_artifact_root", "path": "$RUN_ROOT/ios-artifacts/local"}],
      "public_classes": ["summary", "result_bundle"]
    },
    "cleanup": {"outcome": "deleted", "retention_class": "pass-summary-only", "ttl_class": "success-summary-only"}
  },
  "telemetry_gaps": []
}
JSON

cat > "$SUMMARY_ROOT/issue-67002.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "019e6700-6666-7000-8000-666666666666",
  "chain": "ios-v2-execution",
  "issue_number": 67002,
  "host": "codex",
  "model": "gpt-test",
  "tokens": {"total": 300},
  "exit_code": 1,
  "duration_s": 40,
  "files_changed": 2,
  "additions": 8,
  "deletions": 2,
  "generated_file_count": 0,
  "tests": [{"command":"worker-test","outcome":"fail"}],
  "lints": [],
  "builds": [{"command":"worker-build","outcome":"pass"}],
  "execution_telemetry": {
    "schema_version": 1,
    "profile": "ios",
    "executors": {
      "implementation": {"executor": "worker-a", "node": "worker-a"},
      "build": {"executor": "worker-a", "node": "worker-a"},
      "test": {"executor": "worker-b", "node": "worker-b"},
      "review": {"executor": "claude-reviewer", "node": "reviewer"},
      "release": {"executor": "release-a", "node": "release-a", "channel": "testflight"}
    },
    "routing": {
      "reason_class": "worker_offload_beneficial",
      "cost_summary": "remote worker saved manager wait after setup and retry costs",
      "economics": {"manager_savings_s": 900, "selected_queue_wait_s": 10, "remote_latency_cost_s": 60, "retry_cost_s": 60}
    },
    "artifacts": {
      "private_roots": [{"kind": "chain_artifact_root", "path": "$RUN_ROOT/ios-artifacts/worker"}],
      "public_classes": ["DerivedData", "log", "result_bundle"]
    },
    "cleanup": {"outcome": "retained", "retention_class": "failed-retain", "ttl_class": "48h"},
    "failover": {"failure_class": "worker_unavailable", "selected_retry_path": "retry_another_worker", "final_outcome": "retry_planned"}
  },
  "telemetry_gaps": []
}
JSON

cat > "$EVENTS_JSONL" <<JSONL
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-08T00:00:01Z","event":"chain_ios_artifact_cleanup_completed","stage":"ingest","status":"completed","attempt_id":"$ATTEMPT_ID","task":"","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":null,"data":{"chain":"ios-v2-execution","status":"completed","counts":{"deleted":1,"retained":1},"paths_redacted":true,"telemetry_artifact":"$RUN_ROOT/ios-artifact-cleanup.json","duration_s":1}}
JSONL

metrics=$(chain_efficiency_metrics_json completed "")
printf '%s\n' "$metrics" | jq -e '
  .execution_telemetry.reports == 2
  and .execution_telemetry.build_executors["worker-a"] == 1
  and .execution_telemetry.release_executors["release-a"] == 1
  and .execution_telemetry.routing_reason_classes.worker_offload_beneficial == 1
  and .execution_telemetry.cleanup_outcomes.retained == 1
  and .execution_telemetry.retention_classes["failed-retain"] == 1
  and .execution_telemetry.public_artifact_classes.log == 1
  and (.bottlenecks | map(.kind) | index("ios_execution_telemetry_gaps") != null)
' >/dev/null || {
  printf '%s\n' "$metrics" >&2
  fail "chain efficiency metrics did not roll up iOS execution telemetry"
}

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "manifest": "chains/ios-v2-execution.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:00:20Z",
  "chains": [
    {
      "name": "ios-v2-execution",
      "chain_run_id": "$CHAIN_RUN_ID",
      "status": "completed",
      "issues": [
        {"number": 67001, "status": "completed"},
        {"number": 67002, "status": "failed"},
        {"number": 67003, "status": "completed"}
      ]
    }
  ],
  "efficiency_metrics": $metrics
}
JSON

"$ROOT/scripts/studio-chain-telemetry-digest.sh" --chain-run-root "$RUN_ROOT" --since 2026-05-08 --until 2026-05-08 --format json > "$TMPROOT/digest.json"
jq -e '
  .counters.execution_telemetry.reports == 2
  and .counters.execution_telemetry.gap_count >= 6
  and .counters.execution_telemetry.routing_reason_classes.local_first_manager_available == 1
  and .counters.execution_telemetry.routing_reason_classes.worker_offload_beneficial == 1
  and .counters.execution_telemetry.cleanup_outcomes.deleted == 1
  and .counters.execution_telemetry.cleanup_outcomes.retained == 1
' "$TMPROOT/digest.json" >/dev/null || {
  cat "$TMPROOT/digest.json" >&2
  fail "telemetry digest did not expose iOS execution counters"
}

"$ROOT/scripts/studio-chain-telemetry-digest.sh" --chain-run-root "$RUN_ROOT" --since 2026-05-08 --until 2026-05-08 --format markdown > "$TMPROOT/digest.md"
grep -q '## iOS Execution' "$TMPROOT/digest.md" || fail "markdown digest missing iOS execution section"
grep -q 'worker_offload_beneficial: 1' "$TMPROOT/digest.md" || fail "markdown digest missing routing reason class"
grep -q 'failed-retain: 1' "$TMPROOT/digest.md" || fail "markdown digest missing retention class"

MANIFEST="chains/ios-v2-execution.yaml"
RUN_STATUS="completed"
RUN_FAILURE_REASON=""
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-08T00:00:00Z"
FINAL_PR_URL=""

generate_run_report completed ""
for needle in \
  "## iOS Execution Telemetry" \
  "worker_offload_beneficial" \
  "failed-retain" \
  "implementation_executor" \
  "Attach iOS routing decisions" \
  "Attach iOS cleanup outcome" \
  "Private Roots"
do
  grep -q "$needle" "$RUN_REPORT" || {
    cat "$RUN_REPORT" >&2
    fail "chain report missing expected iOS telemetry needle: $needle"
  }
done

grep -q "| \`release_priority_routing_decision\` |" "$ROOT/_shared/contracts/events.md" \
  || fail "release priority routing event is not registered in events.md"

printf 'PASS: iOS execution telemetry roll-up\n'
