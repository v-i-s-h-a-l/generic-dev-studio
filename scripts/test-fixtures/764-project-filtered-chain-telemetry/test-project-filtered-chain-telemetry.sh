#!/usr/bin/env bash

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/studio-chain-telemetry-digest.sh"
TMPROOT=$(mktemp -d -t project-chain-telemetry.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RUNS="$TMPROOT/chain-runs"
PROJECT_ROOT="$TMPROOT/projects/turnip-ios"
OTHER_ROOT="$TMPROOT/projects/other-app"
MANIFEST_ROOT="$TMPROOT/manifests"
mkdir -p \
  "$RUNS/run-alpha/worker-summaries" \
  "$RUNS/run-alpha/halt-records" \
  "$RUNS/run-fallback/worker-summaries" \
  "$RUNS/run-beta/worker-summaries" \
  "$PROJECT_ROOT" \
  "$OTHER_ROOT" \
  "$MANIFEST_ROOT"

REPORT_ALPHA="$RUNS/run-alpha/report.md"
printf '# alpha report\n' > "$REPORT_ALPHA"
touch -t 202605090000 "$REPORT_ALPHA" 2>/dev/null || true

cat > "$RUNS/run-alpha/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-alpha",
  "manifest": "$MANIFEST_ROOT/alpha.yaml",
  "target_project_slug": "turnip-ios",
  "target_repo_root": "$PROJECT_ROOT",
  "issue_repo": "owner/turnip-ios",
  "status": "paused",
  "started_at": "2026-05-08T00:00:00Z",
  "updated_at": "2026-05-08T00:05:00Z",
  "report": "$REPORT_ALPHA",
  "chains": [
    {
      "name": "target-chain",
      "chain_run_id": "chain-alpha",
      "status": "paused",
      "issues": [
        {
          "number": 76401,
          "issue_run_id": "issue-alpha-1",
          "status": "failed",
          "auto_retry_attempts": 2,
          "summary": "$RUNS/run-alpha/worker-summaries/issue-76401.json"
        }
      ]
    }
  ],
  "halt_records": [
    {
      "path": "$RUNS/run-alpha/halt-records/halt.json",
      "reason_id": "worker_timeout",
      "halt_class": "retryable",
      "status": "paused"
    }
  ],
  "phase_reviews": [
    {
      "boundary_id": "chain-alpha-issue-alpha-1",
      "kind": "plan",
      "verdict": "clean",
      "review": "$TMPROOT/analysis/plan-review.md",
      "review_host": "claude-reviewer",
      "issue_run_id": "issue-alpha-1"
    },
    {
      "boundary_id": "chain-alpha-issue-alpha-1",
      "kind": "outcome",
      "verdict": "blocked",
      "review": "$TMPROOT/analysis/outcome-review.md",
      "review_host": "claude-reviewer",
      "issue_run_id": "issue-alpha-1"
    }
  ]
}
JSON

cat > "$RUNS/run-alpha/worker-summaries/issue-76401.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "run-alpha",
  "chain_run_id": "chain-alpha",
  "issue_run_id": "issue-alpha-1",
  "chain": "target-chain",
  "issue_number": 76401,
  "host": "codex",
  "exit_code": 1,
  "duration_s": 20,
  "files_changed": 1,
  "additions": 5,
  "deletions": 1,
  "generated_file_count": 0,
  "tokens": null,
  "tests": [{"command": "unit", "outcome": "pass"}],
  "lints": [],
  "builds": [],
  "telemetry_gaps": ["tokens", "model"]
}
JSON

cat > "$RUNS/run-alpha/halt-records/halt.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "run_id": "run-alpha",
  "chain_run_id": "chain-alpha",
  "issue_run_id": "issue-alpha-1",
  "issue_number": 76401,
  "status": "paused",
  "reason_id": "worker_timeout",
  "halt_class": "retryable",
  "summary": "Worker timed out."
}
JSON

cat > "$RUNS/run-alpha/events.jsonl" <<'JSONL'
{"event":"chain_retry_attempt","stage":"preflight","status":"retrying","data":{"duration_s":0}}
{"event":"chain_resume_attempt_started","stage":"resume","status":"running","attempt_id":"attempt-alpha","data":{"duration_s":0}}
{"event":"chain_review_completed","stage":"review","status":"completed","task":"100","data":{"verdict":"approved","duration_s":3}}
{"event":"chain_telemetry_gap","stage":"ingest","status":"missing","data":{"gap_kind":"tokens"}}
JSONL

cat > "$RUNS/run-fallback/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-fallback",
  "manifest": "$MANIFEST_ROOT/fallback.yaml",
  "target_repo_root": "$PROJECT_ROOT",
  "status": "completed",
  "started_at": "2026-05-08T00:10:00Z",
  "updated_at": "2026-05-08T00:11:00Z",
  "chains": [
    {
      "name": "fallback-chain",
      "chain_run_id": "chain-fallback",
      "status": "completed",
      "issues": [
        {
          "number": 76402,
          "issue_run_id": "issue-fallback-1",
          "status": "completed"
        }
      ]
    }
  ]
}
JSON

cat > "$RUNS/run-fallback/worker-summaries/issue-76402.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "run-fallback",
  "chain_run_id": "chain-fallback",
  "issue_run_id": "issue-fallback-1",
  "chain": "fallback-chain",
  "issue_number": 76402,
  "host": "codex",
  "model": "gpt-test",
  "exit_code": 0,
  "duration_s": 5,
  "files_changed": 1,
  "additions": 1,
  "deletions": 0,
  "generated_file_count": 0,
  "tokens": {"total": 25},
  "tests": [],
  "lints": [],
  "builds": [],
  "telemetry_gaps": []
}
JSON

cat > "$RUNS/run-fallback/events.jsonl" <<'JSONL'
{"event":"chain_review_completed","stage":"review","status":"failed","task":"101","data":{"verdict":"blocked","duration_s":4}}
JSONL

cat > "$RUNS/run-beta/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "run-beta",
  "manifest": "$MANIFEST_ROOT/beta.yaml",
  "target_project_slug": "other-app",
  "target_repo_root": "$OTHER_ROOT",
  "issue_repo": "owner/other-app",
  "status": "failed",
  "started_at": "2026-05-08T00:20:00Z",
  "updated_at": "2026-05-08T00:21:00Z",
  "chains": [{"name": "unrelated-chain", "issues": [{"number": 999, "status": "failed"}]}]
}
JSON

cat > "$RUNS/run-beta/worker-summaries/issue-999.json" <<'JSON'
{"schema_version":1,"issue_number":999,"host":"codex","exit_code":1,"duration_s":1,"telemetry_gaps":["should_not_appear"]}
JSON

JSON_OUT="$TMPROOT/digest.json"
"$RUN" --chain-runs-root "$RUNS" --since 2026-05-08 --until 2026-05-08 --project turnip-ios --public-safe --format json > "$JSON_OUT"

jq -e '
  .source.public_safe == true
  and (.source.root | startswith("<redacted>/"))
  and .filter.project == "turnip-ios"
  and .filter.matched_runs == 2
  and .filter.excluded_runs == 1
  and .filter.fallback_path_matches == 1
  and .filter.path_fallback_reported == true
  and .filter.match_sources["canonical:target_project"] == 1
  and .filter.match_sources["fallback_path:target_repo_root"] == 1
  and .counters.runs_total == 2
  and (.runs | map(.run_id) | index("run-beta") | not)
  and (.runs[] | select(.run_id == "run-alpha") | .report.freshness) == "fresh"
  and (.runs[] | select(.run_id == "run-alpha") | .manifest | startswith("<redacted>/"))
  and .counters.halt_records_total == 1
  and .counters.halt_records_by_class.retryable == 1
  and .counters.retry_counts.issue_auto_retries == 2
  and .counters.retry_counts.chain_retry_events == 1
  and .counters.retry_counts.resume_attempts == 1
  and .counters.telemetry_gap_counts.tokens == 2
  and .counters.telemetry_gap_counts.model == 1
  and .counters.review_verdict_counts.approved == 1
  and .counters.review_verdict_counts.blocked == 1
  and .counters.phase_review_verdict_counts.clean == 1
  and .counters.phase_review_verdict_counts.blocked == 1
  and (.issues | length) == 2
  and (.issues[] | select(.issue_number == 76401) | .retry_count == 2 and .halt_count == 1 and (.telemetry_gaps | index("tokens")) and (.phase_review_verdicts | index("plan:clean")))
  and (.issues | map(.issue_number) | index(999) | not)
' "$JSON_OUT" >/dev/null || {
  cat "$JSON_OUT" >&2
  fail "project-filtered json rollup did not match"
}

ENV_SAFE_JSON="$TMPROOT/env-safe.json"
STUDIO_CHAIN_TELEMETRY_PUBLIC_SAFE=1 "$RUN" --chain-runs-root "$RUNS" --since 2026-05-08 --until 2026-05-08 --project turnip-ios --format json > "$ENV_SAFE_JSON"
jq -e '.source.public_safe == true and .source.public_safe_trigger == "env"' "$ENV_SAFE_JSON" >/dev/null || {
  cat "$ENV_SAFE_JSON" >&2
  fail "env-triggered public-safe mode did not activate"
}

MD_OUT="$TMPROOT/digest.md"
"$RUN" --chain-runs-root "$RUNS" --since 2026-05-08 --until 2026-05-08 --project turnip-ios --public-safe --format markdown > "$MD_OUT"

for needle in \
  "Project filter: turnip-ios" \
  "Project match fallback: path-derived target repo root used for at least one run" \
  "## Issues" \
  "fallback_path:target_repo_root" \
  "#76401" \
  "plan:clean" \
  "fresh"
do
  grep -q "$needle" "$MD_OUT" || {
    cat "$MD_OUT" >&2
    fail "missing markdown needle: $needle"
  }
done

if grep -q 'unrelated-chain\|should_not_appear\|#999' "$MD_OUT"; then
  cat "$MD_OUT" >&2
  fail "unrelated project leaked into markdown digest"
fi

printf 'PASS: project-filtered chain telemetry roll-up\n'
