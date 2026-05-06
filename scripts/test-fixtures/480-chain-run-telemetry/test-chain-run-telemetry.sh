#!/usr/bin/env bash
# Verifies a failed/paused autonomous run can be reconstructed from private telemetry.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-run-telemetry.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

RUN_ID="019dec8a-1111-7000-8000-111111111111"
CHAIN_RUN_ID="019dec8a-2222-7000-8000-222222222222"
ISSUE_RUN_ID="019dec8a-3333-7000-8000-333333333333"
ATTEMPT_ID="019dec8a-4444-7000-8000-444444444444"

SUMMARY_ROOT="$TMPROOT/summaries"
HALT_ROOT="$TMPROOT/halts"
ESCROW_ROOT="$TMPROOT/escrows"
EVENTS_JSONL="$TMPROOT/events.jsonl"
RUN_STATE_JSON="$TMPROOT/state.json"
RUN_REPORT="$TMPROOT/report.md"
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT"

cat > "$SUMMARY_ROOT/issue-480.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "chain": "autonomous-continuation-loop-480",
  "issue_number": 480,
  "host": "codex",
  "exit_code": 1,
  "duration_s": 42,
  "files_changed": 2,
  "additions": 50,
  "deletions": 4,
  "generated_file_count": 0,
  "tokens": {"total": 900},
  "tests": [{"command":"fixture-test","outcome":"pass"},{"command":"flaky-test","outcome":"flaky"}],
  "lints": [],
  "builds": [],
  "telemetry_gaps": ["model"]
}
JSON

cat > "$HALT_ROOT/halt.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-03T00:00:10Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "status": "paused",
  "reason_id": "model_tool_permission_prompt",
  "halt_class": "human-needed",
  "writer": "child-worker",
  "summary": "The host requested permission.",
  "resumable_state": {"run_state":"$RUN_STATE_JSON"},
  "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
  "affected_artifacts": ["$RUN_STATE_JSON"],
  "rollback_path": "Resolve the prompt, then resume.",
  "true_hard_stop": false,
  "human_action_required": true,
  "privacy": {"classification":"private-runtime"}
}
JSON

cat > "$EVENTS_JSONL" <<JSONL
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:00Z","event":"chain_run_started","stage":"plan","status":"running","attempt_id":"$ATTEMPT_ID","task":"","chain_run_id":null,"issue_run_id":null,"data":{"status":"running","duration_s":0,"attempt_id":"$ATTEMPT_ID"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:01Z","event":"chain_resume_attempt_started","stage":"resume","status":"running","attempt_id":"$ATTEMPT_ID","task":"","chain_run_id":null,"issue_run_id":null,"data":{"attempt_id":"$ATTEMPT_ID","status":"running","duration_s":0}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:02Z","event":"chain_issue_started","stage":"execute","status":"running","attempt_id":"$ATTEMPT_ID","task":"480","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID","data":{"status":"running","duration_s":0,"host":"codex"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:03Z","event":"chain_artifact_validation_failed","stage":"preflight","status":"failed","attempt_id":"$ATTEMPT_ID","task":"480","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID","data":{"artifact":"chain-worker-summary","reason_id":"telemetry_artifact_malformed","summary":"$SUMMARY_ROOT/issue-480.json","status":"failed","duration_s":1}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:04Z","event":"chain_review_completed","stage":"review","status":"completed","attempt_id":"$ATTEMPT_ID","task":"123","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":null,"data":{"pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/123","exit_code":0,"verdict":"approved","duration_s":8,"status":"completed"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:05Z","event":"chain_review_completed","stage":"review","status":"failed","attempt_id":"$ATTEMPT_ID","task":"124","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":null,"data":{"pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/124","exit_code":1,"verdict":"blocked","duration_s":3,"status":"failed"}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:06Z","event":"chain_telemetry_gap","stage":"ingest","status":"missing","attempt_id":"$ATTEMPT_ID","task":"480","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID","data":{"gap_kind":"tokens","stage":"ingest","reason":"missing_or_unavailable","status":"missing","duration_s":0}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:07Z","event":"chain_halt_recorded","stage":"finalize","status":"paused","attempt_id":"$ATTEMPT_ID","task":"480","chain_run_id":"$CHAIN_RUN_ID","issue_run_id":"$ISSUE_RUN_ID","data":{"reason_id":"model_tool_permission_prompt","halt_class":"human-needed","halt_record":"$HALT_ROOT/halt.json","status":"paused","duration_s":0}}
{"schema_version":1,"run_id":"$RUN_ID","created_at":"2026-05-03T00:00:08Z","event":"chain_resume_attempt_completed","stage":"resume","status":"failed","attempt_id":"$ATTEMPT_ID","task":"","chain_run_id":null,"issue_run_id":null,"data":{"attempt_id":"$ATTEMPT_ID","failure_reason":"model permission prompt","status":"failed","duration_s":9}}
JSONL

jq -e '
  select(.schema_version == 1)
  | select(.run_id != null and .created_at != null and .event != null)
  | select((.stage | IN("plan","preflight","execute","ingest","review","merge","close","resume","finalize")))
  | select(.status != null and (.data | type == "object"))
' "$EVENTS_JSONL" >/dev/null

awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/generate-report.sh"

MANIFEST="chains/fixture.yaml"
RUN_STATUS="failed"
RUN_FAILURE_REASON="model permission prompt"
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-03T00:00:00Z"
FINAL_PR_URL=""

iso_ts_now() { printf '2026-05-03T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$TMPROOT/generate-report.sh"
generate_run_report failed "model permission prompt"

for needle in \
  "Run UUID: \`$RUN_ID\`" \
  "Status: \`failed\`" \
  "## Stage Reconstruction" \
  "## Efficiency Summary" \
  "Seconds per changed file: 21" \
  "Tokens per changed file: 450" \
  "Rework signals: 1 bad/flaky tests" \
  "execute:" \
  "review:" \
  "resume:" \
  "Review passes: 1" \
  "Review failures: 1" \
  "## Resume Attempts" \
  "$ATTEMPT_ID" \
  "model_tool_permission_prompt" \
  "model: 1" \
  "telemetry_artifact_malformed" \
  "Run state: \`$RUN_STATE_JSON\`" \
  "Event log: \`$EVENTS_JSONL\`" \
  "Worker summaries: \`$SUMMARY_ROOT\`"
do
  grep -q "$needle" "$RUN_REPORT" || {
    printf 'missing report reconstruction needle: %s\n' "$needle" >&2
    cat "$RUN_REPORT" >&2
    exit 1
  }
done

printf 'PASS: chain-run telemetry reconstruction\n'
