#!/usr/bin/env bash
# Verifies parent-side chain-runner follow-ups for telemetry and halt reporting.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-runner-followups.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

RUN_ID="019df000-1111-7000-8000-111111111111"
CHAIN_RUN_ID="019df000-2222-7000-8000-222222222222"
ISSUE_RUN_ID="019df000-3333-7000-8000-333333333333"
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
ATTEMPT_ID="019df000-4444-7000-8000-444444444444"

WORK="$TMPROOT/work"
SUMMARY_ROOT="$TMPROOT/summaries"
HALT_ROOT="$TMPROOT/halts"
ESCROW_ROOT="$TMPROOT/escrows"
EVENTS_JSONL="$TMPROOT/events.jsonl"
RUN_STATE_JSON="$TMPROOT/state.json"
RUN_REPORT="$TMPROOT/report.md"
CHAIN_RUN_ROOT="$TMPROOT/run"
CODEX_HOME="$TMPROOT/codex"
mkdir -p "$WORK/.studio" "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$CHAIN_RUN_ROOT" "$CODEX_HOME/sessions/2026/05/07"

awk '/^codex_home_for_worker\(\)/,/^worker_summary_tracked\(\)/ { if ($0 !~ /^worker_summary_tracked\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/summary-functions.sh"
awk '/^supersede_completed_halt_records\(\)/,/^default_review_deadline\(\)/ { if ($0 !~ /^default_review_deadline\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/halt-functions.sh"
awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/report-functions.sh"

iso_ts_now() { printf '2026-05-07T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }
diff_stats_json() { printf '{"files_changed":0,"additions":0,"deletions":0,"generated_file_count":0}\n'; }
changed_artifacts_json() { printf '[]\n'; }
emit_chain_event() { :; }
emit_summary_telemetry_gaps() { :; }

# shellcheck source=/dev/null
. "$TMPROOT/summary-functions.sh"
# shellcheck source=/dev/null
. "$TMPROOT/halt-functions.sh"
# shellcheck source=/dev/null
. "$TMPROOT/report-functions.sh"

cat > "$WORK/.studio/chain-worker-summary.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "chain": "followups",
  "issue_number": 656,
  "host": "codex",
  "exit_code": 0,
  "tests": [{"command":"fixture","outcome":"pass"}],
  "lints": [],
  "builds": [],
  "tokens": null,
  "model": null,
  "model_version": null,
  "effort": null,
  "telemetry_gaps": ["tokens", "model", "model_version", "effort"]
}
JSON

cat > "$CODEX_HOME/sessions/2026/05/07/rollout-telemetry.jsonl" <<JSONL
{"type":"session_meta","payload":{"cwd":"$WORK","timestamp":"2026-05-07T00:00:01Z"}}
{"type":"turn_context","payload":{"cwd":"$WORK","model":"gpt-5.5","effort":"medium"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":130}}}}
JSONL

telemetry_file="$TMPROOT/telemetry.json"
collect_codex_worker_session_telemetry codex "$WORK" 0 "$TMPROOT/home" > "$telemetry_file"
summary_file=$(ingest_worker_summary followups 656 codex "$WORK" before after 0 100 "$CHAIN_RUN_ID" "$ISSUE_RUN_ID" "$telemetry_file")

jq -e '
  .tokens.total == 130
  and .model == "gpt-5.5"
  and .model_version == "gpt-5.5"
  and .effort == "medium"
  and (.telemetry_sources | index("codex_session_log"))
  and ((.telemetry_gaps // []) | index("tokens") | not)
  and ((.telemetry_gaps // []) | index("model") | not)
  and ((.telemetry_gaps // []) | index("model_version") | not)
  and ((.telemetry_gaps // []) | index("effort") | not)
' "$summary_file" >/dev/null || {
  printf 'parent telemetry enrichment failed\n' >&2
  cat "$summary_file" >&2
  exit 1
}

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "status": "running",
  "halt_records": [
    {
      "path": "$HALT_ROOT/halt.json",
      "reason_id": "child_crash",
      "halt_class": "recoverable",
      "status": "paused",
      "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes"
    }
  ]
}
JSON

# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
DRY_RUN=0
supersede_completed_halt_records
jq -e '
  .halt_records[0].status == "superseded"
  and .halt_records[0].next_command == null
  and .halt_records[0].resolution == "run_completed_after_resume"
  and .halt_record_resolution.superseded_count == 1
' "$RUN_STATE_JSON" >/dev/null || {
  printf 'halt supersession failed\n' >&2
  cat "$RUN_STATE_JSON" >&2
  exit 1
}

# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
MANIFEST="chains/followups.yaml"
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
RUN_STATUS="completed"
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
RUN_FAILURE_REASON=""
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
RUN_STARTED_AT=100
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
RUN_STARTED_TS="2026-05-07T00:00:00Z"
# shellcheck disable=SC2034 # consumed by sourced chain-runner functions.
FINAL_PR_URL=""
: > "$EVENTS_JSONL"
generate_run_report completed ""

grep -q "No active halt records. Superseded halt records: 1" "$RUN_REPORT" || {
  printf 'completed report did not suppress active halted state\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
if grep -q -- "--resume $RUN_ID" "$RUN_REPORT"; then
  printf 'completed report still advertised stale resume command\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
fi

printf 'PASS: chain-runner follow-up telemetry and halt supersession\n'
