#!/usr/bin/env bash
# Verifies stale chain reports are marked from report_generated_at before mtime fallback.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/studio-chain-telemetry-digest.sh"
TMPROOT=$(mktemp -d -t stale-chain-reports.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RUNS="$TMPROOT/chain-runs"
mkdir -p "$RUNS/run-stale/worker-summaries" "$RUNS/run-mtime-fallback"

REPORT_STALE="$RUNS/run-stale/report.md"
cat > "$REPORT_STALE" <<'MD'
# Studio Chain Run Report

- Status: `failed`
MD

cat > "$RUNS/run-stale/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-stale",
  "manifest": "chains/stale.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:10:00Z",
  "report": "$REPORT_STALE",
  "report_generated_at": "2026-05-08T00:01:00Z",
  "chains": [
    {"name": "stale-chain", "issues": [{"issue_number": 76501, "status": "completed"}]}
  ]
}
JSON

cat > "$RUNS/run-stale/events.jsonl" <<'JSONL'
{"schema_version":1,"run_id":"run-stale","created_at":"2026-05-08T00:11:00Z","event":"chain_issue_completed","stage":"execute","status":"completed","task":"76501","data":{"status":"completed","duration_s":5}}
JSONL

cat > "$RUNS/run-stale/worker-summaries/issue-76501.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "run-stale",
  "chain": "stale-chain",
  "issue_number": 76501,
  "host": "codex",
  "model": "gpt-test",
  "exit_code": 0,
  "duration_s": 5,
  "files_changed": 1,
  "additions": 1,
  "deletions": 0,
  "generated_file_count": 0,
  "tokens": {"total": 10},
  "tests": [],
  "lints": [],
  "builds": [],
  "telemetry_gaps": []
}
JSON

REPORT_MTIME="$RUNS/run-mtime-fallback/report.md"
printf '# fresh fallback report\n' > "$REPORT_MTIME"

cat > "$RUNS/run-mtime-fallback/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-mtime-fallback",
  "manifest": "chains/stale.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:10:00Z",
  "report": "$REPORT_MTIME",
  "chains": [
    {"name": "stale-chain", "issues": [{"issue_number": 76502, "status": "completed"}]}
  ]
}
JSON

cat > "$RUNS/run-mtime-fallback/events.jsonl" <<'JSONL'
{"schema_version":1,"run_id":"run-mtime-fallback","created_at":"2026-05-08T00:11:00Z","event":"chain_issue_completed","stage":"execute","status":"completed","task":"76502","data":{"status":"completed","duration_s":5}}
JSONL

JSON_OUT="$TMPROOT/digest.json"
"$RUN" --chain-runs-root "$RUNS" --since 2026-05-08 --until 2026-05-08 --format json > "$JSON_OUT"

jq -e '
  .counters.reports.stale == 1
  and .counters.reports.fresh == 1
  and (.runs[] | select(.run_id == "run-stale") | .report.freshness) == "stale"
  and (.runs[] | select(.run_id == "run-stale") | .report.stale) == true
  and (.runs[] | select(.run_id == "run-stale") | .report.generated_at) == "2026-05-08T00:01:00Z"
  and (.runs[] | select(.run_id == "run-stale") | .report.generated_at_source) == "state.report_generated_at"
  and (.runs[] | select(.run_id == "run-stale") | .report.latest_event_at) == "2026-05-08T00:11:00Z"
  and (.runs[] | select(.run_id == "run-stale") | .report.state_status) == "completed"
  and (.runs[] | select(.run_id == "run-mtime-fallback") | .report.freshness) == "fresh"
  and (.runs[] | select(.run_id == "run-mtime-fallback") | .report.stale) == false
  and (.runs[] | select(.run_id == "run-mtime-fallback") | .report.generated_at_source) == "filesystem_mtime"
' "$JSON_OUT" >/dev/null || {
  cat "$JSON_OUT" >&2
  fail "digest did not mark stale report from report_generated_at"
}

MD_OUT="$TMPROOT/digest.md"
"$RUN" --chain-runs-root "$RUNS" --since 2026-05-08 --until 2026-05-08 --format markdown > "$MD_OUT"
for needle in \
  "stale" \
  "2026-05-08T00:01:00Z" \
  "2026-05-08T00:11:00Z" \
  "completed"
do
  grep -q "$needle" "$MD_OUT" || {
    cat "$MD_OUT" >&2
    fail "markdown digest missing stale report needle: $needle"
  }
done

REPORT_RUN="$TMPROOT/report-run"
SUMMARY_ROOT="$REPORT_RUN/worker-summaries"
EVENTS_JSONL="$REPORT_RUN/events.jsonl"
RUN_STATE_JSON="$REPORT_RUN/state.json"
RUN_REPORT="$REPORT_RUN/report.md"
HALT_ROOT="$REPORT_RUN/halt-records"
ESCROW_ROOT="$REPORT_RUN/decision-escrows"
PHASE_REVIEW_ROOT="$REPORT_RUN/phase-reviews"
CHAIN_RUN_ROOT="$REPORT_RUN"
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$PHASE_REVIEW_ROOT"

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "run-report-metadata",
  "manifest": "chains/stale.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:10:00Z",
  "report": "$RUN_REPORT",
  "report_generated_at": "2026-05-08T00:01:00Z",
  "chains": []
}
JSON

cat > "$EVENTS_JSONL" <<'JSONL'
{"schema_version":1,"run_id":"run-report-metadata","created_at":"2026-05-08T00:11:00Z","event":"chain_issue_completed","stage":"execute","status":"completed","task":"76501","data":{"status":"completed","duration_s":5}}
JSONL

awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/generate-report.sh"

RUN_ID="run-report-metadata"
MANIFEST="chains/stale.yaml"
RUN_STATUS="completed"
RUN_FAILURE_REASON=""
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-08T00:00:00Z"
FINAL_PR_URL=""
SCRIPT_DIR="$ROOT/scripts"

iso_ts_now() { printf '2026-05-08T00:12:00Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$TMPROOT/generate-report.sh"
generate_run_report completed ""

for needle in \
  "Report generated: \`2026-05-08T00:12:00Z\`" \
  "Latest event: \`2026-05-08T00:11:00Z\`" \
  "State status: \`completed\`" \
  "State updated: \`2026-05-08T00:10:00Z\`"
do
  grep -q "$needle" "$RUN_REPORT" || {
    cat "$RUN_REPORT" >&2
    fail "report missing freshness metadata: $needle"
  }
done

jq -e '.report_generated_at == "2026-05-08T00:12:00Z"' "$RUN_STATE_JSON" >/dev/null || {
  cat "$RUN_STATE_JSON" >&2
  fail "state report_generated_at was not refreshed"
}

HOME_DIR="$TMPROOT/home"
REGEN_ROOT="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs/run-regenerate"
mkdir -p "$REGEN_ROOT/worker-summaries" "$REGEN_ROOT/halt-records" "$REGEN_ROOT/decision-escrows"
cat > "$REGEN_ROOT/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-regenerate",
  "manifest": "chains/stale.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:10:00Z",
  "report": "$REGEN_ROOT/report.md",
  "chains": []
}
JSON

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --regenerate-report run-regenerate >/dev/null 2>&1
[ -s "$REGEN_ROOT/report.md" ] || fail "opt-in regenerate command did not write report"
jq -e '.report_generated_at != null' "$REGEN_ROOT/state.json" >/dev/null || {
  cat "$REGEN_ROOT/state.json" >&2
  fail "opt-in regenerate command did not stamp report_generated_at"
}

LOCKED_ROOT="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs/run-locked"
mkdir -p "$LOCKED_ROOT/worker-summaries" "$LOCKED_ROOT/halt-records" "$LOCKED_ROOT/decision-escrows" "$LOCKED_ROOT/state.json.lock"
printf '%s\n' "$$" > "$LOCKED_ROOT/state.json.lock/pid"
cat > "$LOCKED_ROOT/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-locked",
  "manifest": "chains/stale.yaml",
  "status": "completed",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:10:00Z",
  "report": "$LOCKED_ROOT/report.md",
  "chains": []
}
JSON

set +e
HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --regenerate-report run-locked >/dev/null 2>&1
regen_rc=$?
set -e
[ "$regen_rc" -ne 0 ] || fail "locked regenerate unexpectedly succeeded"
jq -e '.status == "completed" and (.report_generated_at == null)' "$LOCKED_ROOT/state.json" >/dev/null || {
  cat "$LOCKED_ROOT/state.json" >&2
  fail "failed regenerate corrupted completed run state"
}

printf 'PASS: stale chain reports\n'
