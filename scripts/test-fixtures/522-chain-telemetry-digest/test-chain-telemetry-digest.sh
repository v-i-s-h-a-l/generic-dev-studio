#!/usr/bin/env bash
# Verifies v1 counters and markdown digest for private chain runs.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/studio-chain-telemetry-digest.sh"
TMPROOT=$(mktemp -d -t chain-telemetry-digest.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "studio-chain-telemetry-digest.sh is not executable"

RUNS="$TMPROOT/chain-runs"
mkdir -p "$RUNS/run-a/worker-summaries" "$RUNS/run-b/worker-summaries" "$RUNS/old-run/worker-summaries"

cat > "$RUNS/run-a/state.json" <<'JSON'
{
  "run_id": "run-a",
  "manifest": "chains/a.yaml",
  "status": "completed",
  "started_at": "2026-05-03T00:00:00Z",
  "updated_at": "2026-05-03T00:05:00Z",
  "report": "/private/run-a/report.md",
  "chains": [
    {"issues": [
      {"issue_number": 522, "status": "completed"},
      {"issue_number": 523, "status": "failed"}
    ]}
  ],
  "phase_reviews": [{"kind": "plan"}, {"kind": "outcome"}]
}
JSON

cat > "$RUNS/run-a/events.jsonl" <<'JSONL'
{"event":"chain_issue_started","stage":"execute","status":"running","data":{"duration_s":0}}
{"event":"chain_issue_completed","stage":"execute","status":"completed","data":{"duration_s":9}}
{"event":"chain_review_completed","stage":"review","status":"completed","data":{"duration_s":3}}
{"event":"chain_telemetry_gap","stage":"ingest","status":"missing","data":{"gap_kind":"tokens","reason_id":"codex_usage_absent"}}
JSONL

cat > "$RUNS/run-a/worker-summaries/issue-522.json" <<'JSON'
{
  "schema_version": 1,
  "issue_number": 522,
  "host": "codex",
  "model": "gpt-5",
  "exit_code": 0,
  "duration_s": 12,
  "files_changed": 2,
  "additions": 30,
  "deletions": 4,
  "generated_file_count": 0,
  "tokens": {"total_tokens": 100},
  "tests": [{"command": "unit", "outcome": "pass"}],
  "lints": [{"command": "shellcheck", "outcome": "pass"}],
  "builds": [],
  "telemetry_gaps": [],
  "lessons": ["Keep digest counters cheap."]
}
JSON

cat > "$RUNS/run-a/worker-summaries/issue-523.json" <<'JSON'
{
  "schema_version": 1,
  "issue_number": 523,
  "host": "codex",
  "exit_code": 1,
  "duration_s": 5,
  "files_changed": 1,
  "additions": 2,
  "deletions": 1,
  "generated_file_count": 1,
  "tokens": null,
  "tests": [{"command": "unit", "outcome": "fail"}],
  "lints": [],
  "builds": [{"command": "build", "outcome": "error"}],
  "telemetry_gaps": ["model", "tokens"],
  "telemetry_gap_reasons": [
    {"gap_kind": "model", "reason_id": "codex_session_context_absent"},
    {"gap_kind": "tokens", "reason_id": "codex_home_mismatch"}
  ],
  "carryover": ["Retry blocked worker."]
}
JSON

cat > "$RUNS/run-b/state.json" <<'JSON'
{
  "run_id": "run-b",
  "manifest": "chains/b.yaml",
  "status": "failed",
  "started_at": "2026-05-04T00:00:00Z",
  "updated_at": "2026-05-04T00:02:00Z",
  "report": "/private/run-b/report.md",
  "chains": [{"issues": [{"issue_number": 524, "status": "failed"}]}]
}
JSON

cat > "$RUNS/run-b/events.jsonl" <<'JSONL'
{"event":"chain_review_completed","stage":"review","status":"failed","data":{"duration_s":4}}
JSONL

cat > "$RUNS/old-run/state.json" <<'JSON'
{
  "run_id": "old-run",
  "manifest": "chains/old.yaml",
  "status": "completed",
  "started_at": "2026-04-01T00:00:00Z",
  "updated_at": "2026-04-01T00:01:00Z",
  "chains": [{"issues": [{"issue_number": 1, "status": "completed"}]}]
}
JSON

JSON_OUT="$TMPROOT/digest.json"
"$RUN" --chain-runs-root "$RUNS" --since 2026-05-01 --until 2026-05-04 --format json > "$JSON_OUT"

jq -e '
  .schema_version == 1
  and .kind == "studio_chain_telemetry_digest"
  and .counters.runs_total == 2
  and .counters.runs_by_status.completed == 1
  and .counters.runs_by_status.failed == 1
  and .counters.issues_total == 3
  and .counters.worker_summaries_total == 2
  and .counters.worker_exit_nonzero == 1
  and .counters.tokens_total == 100
  and .counters.token_reports == 1
  and .counters.reviews_total == 2
  and .counters.review_passes == 1
  and .counters.review_failures == 1
  and .counters.tests_total == 2
  and .counters.tests_bad == 1
  and .counters.builds_bad == 1
  and .counters.telemetry_gap_counts.tokens == 2
  and .counters.telemetry_gap_counts.model == 1
  and .counters.telemetry_gap_reason_counts["tokens:codex_home_mismatch"] == 1
  and .counters.telemetry_gap_reason_counts["tokens:codex_usage_absent"] == 1
  and .counters.telemetry_gap_reason_counts["model:codex_session_context_absent"] == 1
  and .counters.generated_file_count == 1
  and (.runs | length) == 2
' "$JSON_OUT" >/dev/null || {
  cat "$JSON_OUT" >&2
  fail "json counters did not match"
}

MD_OUT="$TMPROOT/digest.md"
"$RUN" --chain-run-root "$RUNS/run-a" --format markdown > "$MD_OUT"

for needle in \
  "# Studio Chain Telemetry Digest" \
  "Runs: 1" \
  "Issues: 2" \
  "Reviews: 1 pass / 0 fail" \
  "Tokens: 100 across 1 summaries" \
  "chain_issue_completed: 1" \
  "tokens: 2" \
  "tokens:codex_home_mismatch: 1" \
  "run-a"
do
  grep -q "$needle" "$MD_OUT" || {
    cat "$MD_OUT" >&2
    fail "missing markdown needle: $needle"
  }
done

printf 'PASS: chain telemetry digest counters\n'
