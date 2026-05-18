#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/bug-reopen-iteration-report.sh"
TMPROOT=$(mktemp -d -t bug-reopen-iteration-report.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

EVENTS="$TMPROOT/events.json"
REPORT="$TMPROOT/report.json"
cat > "$EVENTS" <<'JSON'
[
  {"issue_number": 1, "event": "closed", "created_at": "2026-05-01T00:00:00Z"},
  {"issue_number": 1, "event": "reopened", "created_at": "2026-05-01T12:00:00Z"},
  {"issue_number": 1, "event": "closed", "created_at": "2026-05-02T00:00:00Z"},
  {"issue_number": 2, "event": "closed", "created_at": "2026-05-02T12:00:00Z"},
  {"issue_number": 3, "event": "closed", "created_at": "2026-05-04T00:00:00Z"},
  {"issue_number": 4, "event": "closed", "created_at": "2026-05-05T00:00:00Z"},
  {"issue_number": 4, "event": "reopened", "created_at": "2026-05-05T12:00:00Z"},
  {"issue_number": 4, "event": "closed", "created_at": "2026-05-06T00:00:00Z"}
]
JSON

"$RUN" --events-json "$EVENTS" --cutover "2026-05-03T23:37:02Z" --cohort-size 3 --now "2026-05-18T00:00:00Z" --json > "$REPORT"

jq -e '
  .kind == "bug-reopen-iteration-report"
  and .baseline.count == 3
  and .baseline.reopened_count == 1
  and .baseline.rate == 0.3333
  and .post_cutover.count == 3
  and .post_cutover.reopened_count == 1
  and .post_cutover.rate == 0.3333
  and .comparison.cohorts_complete == true
  and .comparison.claim_supported == false
' "$REPORT" >/dev/null || {
  jq . "$REPORT" >&2
  fail "unexpected bug reopen iteration report JSON"
}

"$RUN" --events-json "$EVENTS" --cutover "2026-05-03T23:37:02Z" --cohort-size 4 --now "2026-05-18T00:00:00Z" > "$TMPROOT/report.md"
grep -Fq 'Directional only' "$TMPROOT/report.md" || fail "markdown report did not surface directional smaller-N note"

printf 'PASS: bug reopen iteration report\n'
