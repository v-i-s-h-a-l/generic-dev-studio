#!/usr/bin/env bash
# Verifies chain run state is derived from durable events before resume/monitor reads.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-run-state-708.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=../../../scripts/lib-chain-run-state.sh disable=SC1091
. "$ROOT/scripts/lib-chain-run-state.sh"
# shellcheck source=../../../scripts/lib-chain-monitor-model.sh disable=SC1091
. "$ROOT/scripts/lib-chain-monitor-model.sh"

state="$TMPROOT/state.json"
events="$TMPROOT/events.jsonl"
projection="$TMPROOT/projection.json"
commit_after="defd4d78216a89f368eb7945e28a9fa08d7a04d5"
run_id="run-708"
chain_run_id="chain-708"
issue_run_id="issue-700"

cat > "$state" <<JSON
{
  "schema_version": 1,
  "run_id": "$run_id",
  "manifest": "chain-runtime-state-substrate.yaml",
  "status": "failed",
  "updated_at": "2026-05-07T00:00:00Z",
  "chains": [
    {
      "name": "chain-runtime-state-substrate",
      "chain_run_id": "$chain_run_id",
      "status": "failed",
      "failure_reason": "worker_exited_1",
      "issues": [
        {
          "number": 700,
          "title": "Release approval schema",
          "issue_run_id": "$issue_run_id",
          "status": "failed",
          "integrated": false,
          "commit_before": "5b411e425c036733026c78329bb3cf6eef176243",
          "commit_after": "5b411e425c036733026c78329bb3cf6eef176243",
          "failure_reason": "worker_exited_1",
          "exit_code": 1,
          "lifecycle_state": "failed",
          "lifecycle_history": [
            {"state": "issue-created", "at": "2026-05-07T00:00:00Z", "reason": "github-issue-mapping"},
            {"state": "failed", "at": "2026-05-07T00:02:00Z", "reason": "worker_exited_1"}
          ]
        }
      ]
    }
  ],
  "halt_records": [],
  "decision_escrows": []
}
JSON

append_event() {
  local event="$1" status="$2" task="$3" created_at="$4" data="$5"
  jq -cn \
    --arg run_id "$run_id" \
    --arg event "$event" \
    --arg status "$status" \
    --arg task "$task" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg created_at "$created_at" \
    --argjson data "$data" \
    '{
      schema_version:1,
      run_id:$run_id,
      created_at:$created_at,
      event:$event,
      stage:"fixture",
      status:$status,
      task:$task,
      chain_run_id:$chain_run_id,
      issue_run_id:(if $issue_run_id == "" then null else $issue_run_id end),
      attempt_id:"attempt-708",
      data:$data
    }' >> "$events"
}

append_event chain_issue_started running 700 "2026-05-07T00:01:00Z" '{"commit_before":"5b411e425c036733026c78329bb3cf6eef176243"}'
append_event chain_issue_completed failed 700 "2026-05-07T00:02:00Z" '{"failure_reason":"worker_exited_1","exit_code":1,"commit_after":"5b411e425c036733026c78329bb3cf6eef176243"}'
append_event chain_pr_opened completed 704 "2026-05-07T00:05:00Z" '{"pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/704"}'
append_event chain_review_completed completed 704 "2026-05-07T00:06:00Z" '{"pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/704","exit_code":0}'
append_event chain_completed completed "" "2026-05-07T00:07:00Z" '{"chain":"chain-runtime-state-substrate","pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/704","commit_after":"defd4d78216a89f368eb7945e28a9fa08d7a04d5"}'
append_event chain_issue_closed completed 700 "2026-05-07T00:08:00Z" '{"issue_number":700,"pr_url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/704"}'
append_event chain_run_completed completed "" "2026-05-07T00:09:00Z" '{"report":"report.md"}'

chain_run_state_projection_file "$state" "$events" "$projection" || fail "projection failed"
jq -e --arg after "$commit_after" '
  .status == "completed"
  and .chains[0].status == "completed"
  and .chains[0].issues[0].status == "completed"
  and .chains[0].issues[0].integrated == true
  and .chains[0].issues[0].closed == true
  and .chains[0].issues[0].lifecycle_state == "closed"
  and (.chains[0].issues[0].lifecycle_history | map(.state) | index("merged") != null)
  and .chains[0].issues[0].commit_after == $after
  and (.chains[0].issues[0] | has("failure_reason") | not)
  and (.chains[0].issues[0] | has("exit_code") | not)
' "$projection" >/dev/null || fail "failed-then-completed projection kept stale failure state"

repair_summary="$TMPROOT/repair-summary.json"
chain_run_state_reconcile_file "$state" "$events" resume-startup > "$repair_summary" \
  || fail "resume projection reconcile failed"
jq -e '.status == "repaired" and .repaired == true and (.backup | length > 0)' "$repair_summary" >/dev/null \
  || fail "reconcile did not report repair"
jq -e '.projection.source == "events.jsonl" and .chains[0].issues[0].status == "completed"' "$state" >/dev/null \
  || fail "state.json was not repaired from projection"

invalid_summary="$TMPROOT/invalid-summary.json"
(
  chain_run_state_projection_file() { : > "$3"; return 0; }
  chain_run_state_reconcile_file "$state" "$events" resume-startup > "$invalid_summary"
) && fail "reconcile did not flag empty projection output"
jq -e '.status == "projection_invalid"' "$invalid_summary" >/dev/null \
  || fail "reconcile did not report projection_invalid for empty projection output"

malformed_summary="$TMPROOT/malformed-summary.json"
(
  chain_run_state_projection_file() { printf 'not json\n' > "$3"; return 0; }
  chain_run_state_reconcile_file "$state" "$events" resume-startup > "$malformed_summary"
) && fail "reconcile did not flag malformed projection JSON"
jq -e '.status == "projection_invalid"' "$malformed_summary" >/dev/null \
  || fail "reconcile did not report projection_invalid for malformed projection output"

rows="$TMPROOT/monitor-rows.json"
fixture_now=$(jq -nr '"2026-05-07T00:10:00Z" | fromdateiso8601')
chain_monitor_claims_from_persisted_run_json "$run_id" "$state" "$fixture_now" 3600 300 > "$rows"
jq -e '
  any(.[]; .claim_kind == "chain" and .snapshot.fields.status == "completed" and .snapshot.fields.blocker == "")
  and any(.[]; .claim_kind == "task" and .snapshot.fields.status == "completed" and .snapshot.fields.blocker == "")
' "$rows" >/dev/null || fail "monitor model did not read event-derived projection"

helper_block=$(awk '
  /^lock_metadata_json\(\)/ { capture=1 }
  /^chain_artifact_hygiene_sweep\(\)/ { capture=0 }
  capture { print }
' "$ROOT/scripts/studio-chain-runner.sh")
eval "$helper_block"

iso_ts_now() { printf '2026-05-07T00:00:00Z\n'; }
now_epoch() { printf '1778112600\n'; }
RUN_ID="$run_id"
MANIFEST="fixture.yaml"
EVENTS_JSONL="$TMPROOT/lock-events.jsonl"
ATTEMPT_ID="attempt-708"
emit_chain_event() {
  local event="$1" status="$6" data="${8:-}"
  [ -n "$data" ] || data='{}'
  jq -cn --arg event "$event" --arg status "$status" --argjson data "$data" '{event:$event,status:$status,data:$data}' >> "$EVENTS_JSONL"
}

live_lock="$TMPROOT/live.lock"
mkdir "$live_lock"
write_lock_metadata "$live_lock" fixture-live
if lock_is_stale "$live_lock"; then
  fail "live lock was classified as stale"
fi

dead_lock="$TMPROOT/dead.lock"
mkdir "$dead_lock"
printf '999999\n' > "$dead_lock/pid"
printf '2026-05-07T00:00:00Z\n' > "$dead_lock/created_at"
hostname > "$dead_lock/host"
printf 'bash\n' > "$dead_lock/process"
if ! lock_is_stale "$dead_lock"; then
  fail "dead PID lock was not classified as stale"
fi
record_stale_lock_removed "$dead_lock" fixture
rm -rf "$dead_lock"
jq -e '
  .event == "chain_stale_lock_removed"
  and .data.context == "fixture"
  and .data.detail.reason == "pid_dead"
' "$EVENTS_JSONL" >/dev/null || fail "stale lock removal telemetry missing"

printf 'PASS: chain run state projection and stale lock recovery\n'
