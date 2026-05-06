#!/usr/bin/env bash
# Verifies compact chain-run efficiency metrics and digest bottleneck surfacing.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-run-efficiency.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

RUN_ID="019df0e1-1111-7000-8000-111111111111"
CHAIN_RUN_ID="019df0e1-2222-7000-8000-222222222222"
ISSUE_RUN_ID_ONE="019df0e1-3333-7000-8000-333333333333"
ISSUE_RUN_ID_TWO="019df0e1-4444-7000-8000-444444444444"
RUN_ROOT="$TMPROOT/$RUN_ID"
SUMMARY_ROOT="$RUN_ROOT/worker-summaries"
EVENTS_JSONL="$RUN_ROOT/events.jsonl"
mkdir -p "$SUMMARY_ROOT"

cat > "$SUMMARY_ROOT/issue-65201.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID_ONE",
  "chain": "prd-to-chain-automation",
  "issue_number": 65201,
  "host": "codex",
  "model": "gpt-test",
  "exit_code": 0,
  "duration_s": 10,
  "files_changed": 2,
  "additions": 20,
  "deletions": 4,
  "generated_file_count": 0,
  "tokens": {"total": 1000},
  "tests": [{"command":"unit","outcome":"pass"}],
  "lints": [{"command":"shellcheck","outcome":"pass"}],
  "builds": [],
  "telemetry_gaps": []
}
JSON

cat > "$SUMMARY_ROOT/issue-65202.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID_TWO",
  "chain": "prd-to-chain-automation",
  "issue_number": 65202,
  "host": "codex",
  "exit_code": 1,
  "duration_s": 30,
  "files_changed": 2,
  "additions": 5,
  "deletions": 1,
  "generated_file_count": 0,
  "tokens": null,
  "tests": [{"command":"integration","outcome":"flaky"}],
  "lints": [],
  "builds": [{"command":"build","outcome":"pass"}],
  "telemetry_gaps": ["tokens", "model"]
}
JSON

cat > "$EVENTS_JSONL" <<JSONL
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-06T00:00:00Z","event":"chain_run_started","stage":"plan","status":"running","attempt_id":"019df0e1-5555-7000-8000-555555555555","task":"","chain_run_id":null,"issue_run_id":null,"data":{"duration_s":0,"status":"running"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-06T00:00:01Z","event":"chain_retry_attempt","stage":"preflight","status":"retrying","attempt_id":"019df0e1-5555-7000-8000-555555555555","task":"","chain_run_id":null,"issue_run_id":null,"data":{"duration_s":0,"status":"retrying"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-06T00:00:02Z","event":"chain_issue_completed","stage":"execute","status":"completed","attempt_id":"019df0e1-5555-7000-8000-555555555555","task":"65201","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID_ONE","data":{"duration_s":10,"status":"completed","check_counts":{"tests":{"total":1,"bad":0},"lints":{"total":1,"bad":0},"builds":{"total":0,"bad":0}},"token_telemetry":"present"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-06T00:00:03Z","event":"chain_issue_completed","stage":"execute","status":"failed","attempt_id":"019df0e1-5555-7000-8000-555555555555","task":"65202","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID_TWO","data":{"duration_s":30,"status":"failed","check_counts":{"tests":{"total":1,"bad":1},"lints":{"total":0,"bad":0},"builds":{"total":1,"bad":0}},"token_telemetry":"missing"}}
JSONL

awk '/^chain_efficiency_metrics_json\(\)/,/^write_run_state\(\)/ { if ($0 !~ /^write_run_state\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/efficiency.sh"

# shellcheck source=/dev/null
. "$TMPROOT/efficiency.sh"
metrics=$(chain_efficiency_metrics_json failed "fixture failure")

printf '%s\n' "$metrics" | jq -e '
  .worker_duration_s == 40 and
  .avg_worker_duration_s == 20 and
  .seconds_per_file_changed == 10 and
  .tokens_per_file_changed == 250 and
  .slowest_issue.issue_number == 65202 and
  .retry_events == 1 and
  .tests.bad == 1 and
  .telemetry_gap_counts.tokens == 1 and
  (.bottlenecks | map(.kind) | index("test_failures_or_flakes") != null)
' >/dev/null || {
  printf 'efficiency metrics did not match expected compact roll-up\n' >&2
  printf '%s\n' "$metrics" >&2
  exit 1
}

cat > "$RUN_ROOT/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "manifest": "chains/prd-to-chain-automation.yaml",
  "status": "failed",
  "started_at": "2026-05-06T00:00:00Z",
  "updated_at": "2026-05-06T00:00:04Z",
  "chains": [
    {
      "name": "prd-to-chain-automation",
      "chain_run_id": "$CHAIN_RUN_ID",
      "status": "failed",
      "issues": [
        {"number": 65201, "status": "completed"},
        {"number": 65202, "status": "failed"}
      ]
    }
  ],
  "efficiency_metrics": $metrics
}
JSON

"$ROOT/scripts/studio-chain-telemetry-digest.sh" --chain-run-root "$RUN_ROOT" --format json > "$TMPROOT/digest.json"
jq -e '
  .counters.avg_worker_duration_s == 20 and
  .counters.seconds_per_file_changed == 10 and
  .counters.tokens_per_file_changed == 250 and
  .counters.slowest_issue.issue_number == 65202 and
  (.bottlenecks | map(.kind) | index("missing_token_telemetry") != null)
' "$TMPROOT/digest.json" >/dev/null || {
  printf 'digest did not include comparable efficiency metrics\n' >&2
  cat "$TMPROOT/digest.json" >&2
  exit 1
}

"$ROOT/scripts/studio-chain-telemetry-digest.sh" --chain-run-root "$RUN_ROOT" --format markdown > "$TMPROOT/digest.md"
grep -q '## Bottlenecks' "$TMPROOT/digest.md" || {
  printf 'markdown digest missing bottlenecks section\n' >&2
  cat "$TMPROOT/digest.md" >&2
  exit 1
}
grep -q 'Efficiency: avg 20s/issue, 10s/file, 250 tokens/file' "$TMPROOT/digest.md" || {
  printf 'markdown digest missing efficiency ratios\n' >&2
  cat "$TMPROOT/digest.md" >&2
  exit 1
}

printf 'PASS: chain-run efficiency metrics and digest\n'
