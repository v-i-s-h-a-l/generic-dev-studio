#!/usr/bin/env bash
# Verifies chain doctor recommends safe recovery actions from existing run artifacts.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DOCTOR="$ROOT/scripts/studio-chain-doctor.sh"
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t chain-doctor-771.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

RUNS="$TMPROOT/chain-runs"
mkdir -p "$RUNS/run-stale" "$RUNS/run-retry" "$RUNS/run-reviewer"

cat > "$RUNS/run-stale/report.md" <<'MD'
# Studio Chain Run Report

- Status: `failed`
MD
cat > "$RUNS/run-stale/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-stale",
  "manifest": "chains/doctor.yaml",
  "status": "completed",
  "started_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:10:00Z",
  "report": "$RUNS/run-stale/report.md",
  "report_generated_at": "2026-05-09T00:01:00Z",
  "chains": [
    {
      "name": "doctor",
      "issues": [
        {"issue_number": 77101, "issue_run_id": "issue-run-stale", "status": "completed"}
      ]
    }
  ],
  "halt_records": []
}
JSON
cat > "$RUNS/run-stale/events.jsonl" <<'JSONL'
{"schema_version":1,"run_id":"run-stale","created_at":"2026-05-09T00:11:00Z","event":"chain_issue_completed","stage":"execute","status":"completed","task":"77101","data":{"status":"completed","duration_s":5}}
JSONL

STALE_MD="$TMPROOT/stale.md"
"$DOCTOR" --chain-run-root "$RUNS/run-stale" > "$STALE_MD"
grep -q 'Recommended action: `regenerate_report`' "$STALE_MD" || {
  cat "$STALE_MD" >&2
  fail "stale report did not recommend regeneration"
}
grep -q 'scripts/studio-chain-runner.sh --regenerate-report run-stale' "$STALE_MD" || {
  cat "$STALE_MD" >&2
  fail "stale report did not print regenerate command"
}

STALE_JSON="$TMPROOT/stale.json"
"$DOCTOR" --chain-run-root "$RUNS/run-stale" --format json > "$STALE_JSON"
jq -e '
  .report.freshness == "stale"
  and .stale_artifacts[0].artifact == "report"
  and .recommendation.action == "regenerate_report"
' "$STALE_JSON" >/dev/null || {
  cat "$STALE_JSON" >&2
  fail "stale report JSON recommendation was wrong"
}

cat > "$RUNS/run-retry/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-retry",
  "manifest": "chains/doctor.yaml",
  "status": "failed",
  "started_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:02:00Z",
  "report": "$RUNS/run-retry/report.md",
  "chains": [
    {
      "name": "doctor",
      "issues": [
        {"issue_number": 77102, "issue_run_id": "issue-run-retry", "status": "failed"}
      ]
    }
  ],
  "halt_records": [
    {
      "path": "$RUNS/run-retry/halt-records/network.json",
      "created_at": "2026-05-09T00:02:00Z",
      "reason_id": "network_partition",
      "halt_class": "retryable",
      "status": "paused",
      "summary": "fetch origin failed twice",
      "retry_count": 2,
      "first_seen": "2026-05-09T00:01:00Z",
      "last_seen": "2026-05-09T00:02:00Z",
      "last_observed_command": "git fetch https://github.com/Org/Repo",
      "last_observed_error": "Could not resolve host github.com",
      "normalized_origin": "github.com/org/repo",
      "normalized_error": "could not resolve host github.com",
      "coalesce_key": {
        "run_id": "run-retry",
        "scope_kind": "issue_run",
        "scope_id": "issue-run-retry",
        "reason_id": "network_partition",
        "normalized_origin": "github.com/org/repo",
        "normalized_error": "could not resolve host github.com"
      },
      "retry_policy": {
        "cooldown_seconds": 30,
        "cooldown_until": "2099-01-01T00:00:00Z",
        "human_inspection_retry_count": 3
      },
      "issue_context": {
        "issue_number": 77102,
        "issue_run_id": "issue-run-retry",
        "title": "Retry fixture"
      },
      "next_command": "scripts/studio-chain-runner.sh --resume run-retry --yes",
      "next_safe_action": "Correct the transient cause or wait for recovery, then run next_command to resume."
    }
  ]
}
JSON

RETRY_MD="$TMPROOT/retry.md"
"$DOCTOR" --chain-run-root "$RUNS/run-retry" > "$RETRY_MD"
grep -q 'Recommended action: `wait_for_cooldown`' "$RETRY_MD" || {
  cat "$RETRY_MD" >&2
  fail "retryable halt did not recommend cooldown wait"
}
grep -q 'cooling_down' "$RETRY_MD" || {
  cat "$RETRY_MD" >&2
  fail "retryable halt did not expose cooling_down state"
}
if grep -q 'Recommended action: `retry_after_transient_check`' "$RETRY_MD"; then
  cat "$RETRY_MD" >&2
  fail "retryable halt recommended blind resume during cooldown"
fi

cat > "$RUNS/run-reviewer/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-reviewer",
  "manifest": "chains/doctor.yaml",
  "status": "failed",
  "started_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:04:00Z",
  "report": "$RUNS/run-reviewer/report.md",
  "chains": [
    {
      "name": "doctor",
      "issues": [
        {"issue_number": 77103, "issue_run_id": "issue-run-reviewer", "status": "failed"}
      ]
    }
  ],
  "phase_reviews": [
    {
      "kind": "outcome",
      "boundary_id": "doctor-issue-77103",
      "verdict": "blocked",
      "review": "$RUNS/run-reviewer/phase-review.md",
      "issue_run_id": "issue-run-reviewer"
    }
  ],
  "halt_records": [
    {
      "path": "$RUNS/run-reviewer/halt-records/child.json",
      "created_at": "2026-05-09T00:04:00Z",
      "reason_id": "child_crash",
      "halt_class": "recoverable",
      "status": "paused",
      "summary": "worker exited 1"
    },
    {
      "path": "$RUNS/run-reviewer/halt-records/reviewer.json",
      "created_at": "2026-05-09T00:03:00Z",
      "reason_id": "reviewer_blocked",
      "halt_class": "review-needed",
      "status": "paused",
      "summary": "phase review blocked",
      "issue_context": {
        "issue_number": 77103,
        "issue_run_id": "issue-run-reviewer",
        "title": "Reviewer fixture"
      },
      "next_command": "scripts/studio-chain-runner.sh --resume run-reviewer --yes",
      "next_safe_action": "Inspect the phase review artifact, resolve the fatal reviewer findings, rerun sibling review, then resume the chain."
    }
  ]
}
JSON

REVIEWER_MD="$TMPROOT/reviewer.md"
"$DOCTOR" --chain-run-root "$RUNS/run-reviewer" > "$REVIEWER_MD"
grep -q 'Active blocker: `reviewer_blocked / review-needed`' "$REVIEWER_MD" || {
  cat "$REVIEWER_MD" >&2
  fail "reviewer block was not selected over child crash"
}
grep -q 'Recommended action: `review_phase_artifact`' "$REVIEWER_MD" || {
  cat "$REVIEWER_MD" >&2
  fail "reviewer block did not recommend phase artifact review"
}
if grep -q 'Active blocker: `child_crash / recoverable`' "$REVIEWER_MD"; then
  cat "$REVIEWER_MD" >&2
  fail "reviewer block was treated as child crash"
fi

HOME_DIR="$TMPROOT/home"
mkdir -p "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"
cp -R "$RUNS/run-stale" "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs/run-stale"
RUNNER_JSON="$TMPROOT/runner-doctor.json"
HOME="$HOME_DIR" "$RUNNER" --doctor run-stale --format json --public-safe > "$RUNNER_JSON"
jq -e '
  .source.public_safe == true
  and (.source.chain_run_root | startswith("<redacted>/"))
  and .recommendation.action == "regenerate_report"
' "$RUNNER_JSON" >/dev/null || {
  cat "$RUNNER_JSON" >&2
  fail "runner --doctor pass-through or public-safe redaction failed"
}

printf 'PASS: chain doctor recovery recommendations\n'
