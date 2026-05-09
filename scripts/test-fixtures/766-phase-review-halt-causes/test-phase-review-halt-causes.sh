#!/usr/bin/env bash
# Verifies phase-review failure causes survive halt selection, state reasons, and reports.

# Fixture variables and callbacks are consumed by extracted runner functions.
# shellcheck disable=SC2034,SC2329

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t phase-review-halt-causes-766.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

halt_helpers="$TMPROOT/halt-helpers.sh"
awk '
  /^halt_class_for_reason\(\)/ { capture=1 }
  /^halt_issue_context_json\(\)/ { capture=0 }
  capture { print }
' "$RUNNER" > "$halt_helpers"

# shellcheck source=/dev/null
. "$halt_helpers"

[ "$(halt_reason_for_text reviewer_host_ineligible)" = "reviewer_host_ineligible" ] \
  || fail "typed reviewer_host_ineligible was not preserved"
[ "$(halt_reason_for_text reviewer_blocked)" = "reviewer_blocked" ] \
  || fail "typed reviewer_blocked was not preserved"
[ "$(halt_reason_for_text reviewer_ambiguous)" = "reviewer_ambiguous" ] \
  || fail "typed reviewer_ambiguous was not preserved"
[ "$(halt_reason_for_text required_review_failed)" = "required_review_failed" ] \
  || fail "typed required_review_failed was not preserved"
[ "$(halt_reason_for_text unexpected_exit_2)" != "child_crash" ] \
  || fail "parent unexpected exits should not be classified as child_crash"

RUN_STATE_JSON="$TMPROOT/priority-state.json"
cat > "$RUN_STATE_JSON" <<'JSON'
{
  "halt_records": [
    {
      "reason_id": "child_crash",
      "halt_class": "recoverable",
      "status": "paused",
      "created_at": "2026-05-09T00:00:02Z"
    },
    {
      "reason_id": "reviewer_blocked",
      "halt_class": "review-needed",
      "status": "paused",
      "created_at": "2026-05-09T00:00:01Z"
    }
  ]
}
JSON
[ "$(selected_active_halt_reason_id)" = "reviewer_blocked" ] \
  || fail "review-needed halt did not outrank later child crash"
[ "$(resolved_run_failure_reason failed "worker exited 1")" = "reviewer_blocked" ] \
  || fail "run failure reason did not resolve from selected halt"

cat > "$RUN_STATE_JSON" <<'JSON'
{
  "halt_records": [
    {
      "reason_id": "network_partition",
      "halt_class": "retryable",
      "status": "paused",
      "created_at": "2026-05-09T00:00:03Z"
    },
    {
      "reason_id": "missing_child_summary",
      "halt_class": "recoverable",
      "status": "paused",
      "created_at": "2026-05-09T00:00:01Z"
    }
  ]
}
JSON
[ "$(selected_active_halt_reason_id)" = "missing_child_summary" ] \
  || fail "recoverable halt did not outrank retryable halt"

cat > "$RUN_STATE_JSON" <<'JSON'
{
  "halt_records": [
    {
      "reason_id": "reviewer_blocked",
      "halt_class": "review-needed",
      "status": "paused",
      "created_at": "2026-05-09T00:00:01Z"
    },
    {
      "reason_id": "reviewer_ambiguous",
      "halt_class": "review-needed",
      "status": "paused",
      "created_at": "2026-05-09T00:00:01Z"
    }
  ]
}
JSON
[ "$(selected_active_halt_reason_id)" = "reviewer_ambiguous" ] \
  || fail "equal-priority tie did not choose latest run-state row"

phase_gate_block="$TMPROOT/phase-gate.sh"
awk '
  /^run_phase_review_gate\(\)/ { capture=1 }
  /^generated_file_count_between\(\)/ { capture=0 }
  capture { print }
' "$RUNNER" > "$phase_gate_block"

fixture_scripts="$TMPROOT/scripts"
mkdir -p "$fixture_scripts"
cat > "$fixture_scripts/phase-review.sh" <<'SH'
#!/usr/bin/env bash
mode="${PHASE_FIXTURE_MODE:-clean}"
case "$mode" in
  blocked)
    printf 'PHASE_REVIEW_HOST=claude-reviewer\n'
    printf 'PHASE_REVIEW_VERDICT=blocked\n'
    printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=true\n'
    printf 'PHASE_REVIEW_DEGRADED=0\n'
    exit 0
    ;;
  ambiguous)
    printf 'PHASE_REVIEW_HOST=claude-reviewer\n'
    printf 'PHASE_REVIEW_VERDICT=ambiguous\n'
    printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=true\n'
    printf 'PHASE_REVIEW_DEGRADED=0\n'
    exit 0
    ;;
  ineligible)
    printf 'PHASE_REVIEW_FALLBACK_DETAIL=reviewer host smoke failed\n'
    printf 'phase-review: reviewer host is not eligible: claude-reviewer\n'
    exit 2
    ;;
  degraded_clean)
    printf 'PHASE_REVIEW_HOST=claude-reviewer\n'
    printf 'PHASE_REVIEW_VERDICT=clean\n'
    printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=false\n'
    printf 'PHASE_REVIEW_DEGRADED=1\n'
    printf 'PHASE_REVIEW_DEGRADED_REASON=no_cross_host_reviewer_usable\n'
    printf 'PHASE_REVIEW_NEXT_CROSS_HOST_RETRY=next_boundary\n'
    exit 0
    ;;
  *)
    printf 'PHASE_REVIEW_HOST=claude-reviewer\n'
    printf 'PHASE_REVIEW_VERDICT=clean\n'
    printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=true\n'
    printf 'PHASE_REVIEW_DEGRADED=0\n'
    exit 0
    ;;
esac
SH
chmod +x "$fixture_scripts/phase-review.sh"

SCRIPT_DIR="$fixture_scripts"
PARENT_HOME_FOR_GITHUB="$TMPROOT/home"
CHAIN_RUN_ROOT="$TMPROOT/run"
PHASE_REVIEW_ROOT="$TMPROOT/phase-reviews"
RUN_ID="019e0969-7660-7000-8000-000000000001"
mkdir -p "$PARENT_HOME_FOR_GITHUB" "$CHAIN_RUN_ROOT" "$PHASE_REVIEW_ROOT"

log() { :; }
now_epoch() { printf '100\n'; }
duration_since() { printf '3\n'; }
phase_review_record() { return 1; }
record_phase_review() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TMPROOT/records.tsv"; }
append_phase_review_feedback() { :; }
compact_phase_review_feedback_json() { printf '[]\n'; }
emit_chain_event() { printf '%s\n' "${8:-{}}" >> "$TMPROOT/events.jsonl"; }
write_halt_record() {
  jq -cn \
    --arg reason "$1" \
    --arg summary "$2" \
    --arg details "${8:-null}" \
    --arg next_safe_action "${9:-}" \
    '{reason:$reason, summary:$summary, details:($details | fromjson? // $details), next_safe_action:$next_safe_action}' \
    > "$TMPROOT/halt-capture.json"
}

# shellcheck source=/dev/null
. "$phase_gate_block"

artifact="$TMPROOT/plan.md"
printf '# Plan\n' > "$artifact"

if PHASE_FIXTURE_MODE=blocked run_phase_review_gate plan "chain-766-issue-1" "$artifact" "chain-766" "issue-1" "diagnostics" "76601" >/dev/null; then
  rc=0
else
  rc=$?
fi
set -e
[ "$rc" -eq 71 ] || fail "blocked phase review returned $rc"
jq -e '
  .reason == "reviewer_blocked"
  and .details.kind == "plan"
  and .details.boundary_id == "chain-766-issue-1"
  and .details.exit_code == 0
  and (.next_safe_action | test("resolve the fatal reviewer findings"))
' "$TMPROOT/halt-capture.json" >/dev/null || {
  cat "$TMPROOT/halt-capture.json" >&2
  fail "blocked halt details were not preserved"
}

if PHASE_FIXTURE_MODE=ambiguous run_phase_review_gate plan "chain-766-issue-2" "$artifact" "chain-766" "issue-2" "diagnostics" "76602" >/dev/null; then
  rc=0
else
  rc=$?
fi
set -e
[ "$rc" -eq 72 ] || fail "ambiguous phase review returned $rc"
jq -e '.reason == "reviewer_ambiguous"' "$TMPROOT/halt-capture.json" >/dev/null \
  || fail "ambiguous phase review did not write reviewer_ambiguous"

if PHASE_FIXTURE_MODE=ineligible run_phase_review_gate plan "chain-766-issue-3" "$artifact" "chain-766" "issue-3" "diagnostics" "76603" >/dev/null; then
  rc=0
else
  rc=$?
fi
set -e
[ "$rc" -eq 70 ] || fail "ineligible phase review returned $rc"
jq -e '
  .reason == "reviewer_host_ineligible"
  and .details.exit_code == 2
  and .details.wrapper_detail == "reviewer host smoke failed"
  and (.next_safe_action | test("reviewer eligibility"))
' "$TMPROOT/halt-capture.json" >/dev/null || {
  cat "$TMPROOT/halt-capture.json" >&2
  fail "reviewer ineligibility details were not preserved"
}

rm -f "$TMPROOT/halt-capture.json"
PHASE_FIXTURE_MODE=degraded_clean run_phase_review_gate plan "chain-766-issue-4" "$artifact" "chain-766" "issue-4" "diagnostics" "76604" >/dev/null \
  || fail "degraded clean phase review should continue"
[ ! -f "$TMPROOT/halt-capture.json" ] \
  || fail "degraded clean review was incorrectly treated as reviewer ineligibility"
grep -q '"degraded_review":true' "$TMPROOT/events.jsonl" \
  || fail "degraded reviewer continuity metadata was not emitted"

generate_report_block="$TMPROOT/generate-report.sh"
awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$RUNNER" > "$generate_report_block"

CHAIN_RUN_ROOT="$TMPROOT/report-run"
SUMMARY_ROOT="$CHAIN_RUN_ROOT/worker-summaries"
HALT_ROOT="$CHAIN_RUN_ROOT/halt-records"
EVENTS_JSONL="$CHAIN_RUN_ROOT/events.jsonl"
RUN_STATE_JSON="$CHAIN_RUN_ROOT/state.json"
RUN_REPORT="$CHAIN_RUN_ROOT/report.md"
SCRIPT_DIR="$ROOT/scripts"
MANIFEST="chains/diagnostics.yaml"
RUN_STATUS="failed"
RUN_FAILURE_REASON="reviewer_host_ineligible"
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-09T00:00:00Z"
FINAL_PR_URL=""
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT"
: > "$EVENTS_JSONL"

iso_ts_now() { printf '2026-05-09T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

cat > "$RUN_STATE_JSON" <<'JSON'
{
  "schema_version": 1,
  "run_id": "019e0969-7660-7000-8000-000000000001",
  "manifest": "chains/diagnostics.yaml",
  "status": "failed",
  "started_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:00:10Z",
  "chains": [
    {
      "name": "diagnostics",
      "chain_run_id": "chain-766",
      "status": "failed",
      "issues": [
        {
          "number": 76603,
          "issue_number": 76603,
          "title": "Reviewer ineligible",
          "issue_run_id": "issue-3",
          "status": "failed",
          "failure_reason": "reviewer_host_ineligible"
        }
      ]
    }
  ],
  "halt_records": [
    {
      "path": "/private/halt-child.json",
      "created_at": "2026-05-09T00:00:12Z",
      "reason_id": "child_crash",
      "halt_class": "recoverable",
      "status": "paused",
      "summary": "worker exited after launch",
      "details": {"exit_code": 1},
      "next_command": "resume",
      "next_safe_action": "Inspect worker.",
      "issue_context": {"issue_run_id": "issue-3", "issue_number": 76603, "title": "Reviewer ineligible"}
    },
    {
      "path": "/private/halt-reviewer.json",
      "created_at": "2026-05-09T00:00:11Z",
      "reason_id": "reviewer_host_ineligible",
      "halt_class": "human-needed",
      "status": "paused",
      "summary": "plan phase review wrapper failed",
      "details": {"wrapper_detail": "reviewer host smoke failed", "requested_review_host": "claude-reviewer"},
      "next_command": "resume",
      "next_safe_action": "Inspect the phase-review wrapper output and reviewer eligibility details.",
      "issue_context": {"issue_run_id": "issue-3", "issue_number": 76603, "title": "Reviewer ineligible"}
    }
  ]
}
JSON

# shellcheck source=/dev/null
. "$generate_report_block"
failure_reason=$(resolved_run_failure_reason failed "worker exited 1")
[ "$failure_reason" = "reviewer_host_ineligible" ] \
  || fail "report failure reason did not select reviewer_host_ineligible"
generate_run_report failed "$failure_reason"

for needle in \
  "Failure reason: \`reviewer_host_ineligible\`" \
  'reviewer_host_ineligible' \
  'reviewer host smoke failed' \
  'Inspect the phase-review wrapper output and reviewer eligibility details.'
do
  grep -Fq "$needle" "$RUN_REPORT" || {
    cat "$RUN_REPORT" >&2
    fail "missing report reviewer halt detail: $needle"
  }
done

printf 'PASS: phase-review halt causes remain typed through state and reports\n'
