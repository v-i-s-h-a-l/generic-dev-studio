#!/usr/bin/env bash
# Verifies private chain reports render the v1 summary sections with fallbacks.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-report.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

SUMMARY_ROOT="$TMPROOT/summaries"
EVENTS_JSONL="$TMPROOT/events.jsonl"
RUN_REPORT="$TMPROOT/report.md"
mkdir -p "$SUMMARY_ROOT"

cat > "$SUMMARY_ROOT/issue-446.json" <<'JSON'
{
  "schema_version": 1,
  "chain": "chain-a",
  "issue_number": 446,
  "host": "codex",
  "exit_code": 0,
  "duration_s": 12,
  "files_changed": 3,
  "additions": 20,
  "deletions": 4,
  "generated_file_count": 0,
  "model": "gpt-5",
  "tokens": {"total_tokens": 1234, "cache_hit_rate": 0.5},
  "tests": [{"command": "fixture", "outcome": "pass"}],
  "lints": [],
  "builds": [],
  "review_pass_count": 1,
  "review_findings_tier": "warn",
  "functionality_delivered": ["Operators can list persisted chain runs."],
  "user_visible_change": ["The manager finish output now explains the operator-facing result."],
  "carryover": ["Full D1 amendment flow remains deferred."],
  "lessons": ["List mode should short-circuit before run allocation."],
  "telemetry_gaps": []
}
JSON

cat > "$SUMMARY_ROOT/issue-340-old.json" <<'JSON'
{
  "schema_version": 1,
  "chain": "chain-a",
  "issue_number": 340,
  "host": "codex",
  "exit_code": 0,
  "duration_s": 3,
  "files_changed": 1,
  "additions": 2,
  "deletions": 1,
  "generated_file_count": 0,
  "telemetry_gaps": ["model", "tokens"]
}
JSON

cat > "$EVENTS_JSONL" <<'JSONL'
{"event":"chain_issue_completed","task":"446","data":{}}
{"event":"chain_run_completed","task":"","data":{}}
JSONL

awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/generate-report.sh"

RUN_ID="fixture-run"
MANIFEST="chains/fixture.yaml"
RUN_STATUS="completed"
RUN_FAILURE_REASON=""
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-03T00:00:00Z"
FINAL_PR_URL=""

iso_ts_now() { printf '2026-05-03T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$TMPROOT/generate-report.sh"
generate_run_report completed ""

for heading in \
  '## Work-Chain Finish Summary' \
  '## Functionality Delivered' \
  '## Telemetry Roll-up' \
  '## Quality Signals' \
  '## Chains And Issues' \
  '## Carryover' \
  '## Lessons' \
  '## PRs And Review' \
  '## Telemetry Gaps' \
  '## Improvement Candidates' \
  '## Privacy'
do
  grep -q "$heading" "$RUN_REPORT" || {
    printf 'missing heading: %s\n' "$heading" >&2
    cat "$RUN_REPORT" >&2
    exit 1
  }
done

grep -q 'Operators can list persisted chain runs.' "$RUN_REPORT" || {
  printf 'missing functionality narrative\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'The manager finish output now explains the operator-facing result.' "$RUN_REPORT" || {
  printf 'missing user-facing change narrative\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'Token total: 1234' "$RUN_REPORT" || {
  printf 'missing token roll-up\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'Full D1 amendment flow remains deferred.' "$RUN_REPORT" || {
  printf 'missing carryover\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'List mode should short-circuit before run allocation.' "$RUN_REPORT" || {
  printf 'missing lesson\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'model: 1' "$RUN_REPORT" || {
  printf 'missing old-summary telemetry gap fallback\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}

printf 'PASS: chain-runner report summary sections\n'
