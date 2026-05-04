#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/608-feedback-analyze-ingest"
RUN="$ROOT/scripts/analyze-feedback-ingest.sh"
TMPROOT=$(mktemp -d -t feedback-analyze-ingest.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/analyze-feedback-ingest.sh is not executable"

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=generic-dev-studio
INBOX="$HOME/.dev-studio/generic-dev-studio/feedback-inbox/sample-project"
mkdir -p "$INBOX"

cat > "$INBOX/001-related.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:00:00Z
cluster: analyze ingest durable routing
---
# Analyze ingest durable routing should file work

Manager analyze should turn actionable feedback into a durable destination.
MD

cat > "$INBOX/002-related.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:01:00Z
cluster: analyze ingest durable routing
---
# Analyze ingest durable routing needs consolidation

The same manager analyze routing gap should not create a duplicate issue.
MD

cat > "$INBOX/003-existing.md" <<'MD'
---
kind: bug
scope: generic-dev-studio
ts: 2026-05-05T00:02:00Z
---
# Sibling review payload handoff drops context

The sibling review payload handoff should preserve readable context.
MD

cat > "$INBOX/004-distinct.md" <<'MD'
---
kind: enhancement
scope: generic-dev-studio
ts: 2026-05-05T00:03:00Z
---
# Destination list required in final analysis output

Manager analyze should end with the remaining inbox count and every destination issue.
MD

cat > "$INBOX/005-unsafe.md" <<'MD'
---
kind: bug
scope: generic-dev-studio
ts: 2026-05-05T00:04:00Z
---
# Unsafe public issue body

This record includes a token-shaped string: ghp_12345678901234567890.
MD

OUT="$TMPROOT/out.json"
ACTIONS="$TMPROOT/actions.jsonl"
DRY_OUT="$TMPROOT/dry-run.json"

"$RUN" \
  --inbox-root "$HOME/.dev-studio/generic-dev-studio/feedback-inbox" \
  --issues-file "$FIXTURE_DIR/issues.json" > "$DRY_OUT"

jq -e '
  .mode == "dry-run"
  and .inbox_count_before == 5
  and .inbox_count_after == 5
  and .destination_count == 4
  and (.policy_holds | length) == 1
' "$DRY_OUT" >/dev/null

[ ! -d "$INBOX/processed" ] || fail "dry-run should not move feedback records"

"$RUN" \
  --apply \
  --inbox-root "$HOME/.dev-studio/generic-dev-studio/feedback-inbox" \
  --issues-file "$FIXTURE_DIR/issues.json" \
  --actions-file "$ACTIONS" > "$OUT"

jq -e '
  .kind == "manager_analyze_feedback_ingest"
  and .mode == "apply"
  and .inbox_count_before == 5
  and .inbox_count_after == 1
  and .destination_count == 4
  and (.policy_holds | length) == 1
  and (.policy_holds[] | select(.source_file == "sample-project/005-unsafe.md" and .policy_reason == "privacy_scrub_required"))
' "$OUT" >/dev/null

jq -e '
  [ .destinations[] | select(.disposition == "created_issue") ] | length == 2
' "$OUT" >/dev/null

jq -e '
  [ .destinations[] | select(.disposition == "consolidated_with_related_feedback") ] | length == 1
' "$OUT" >/dev/null

jq -e '
  .destinations[] | select(.source_file == "sample-project/003-existing.md")
  | .destination_issue == 606 and .disposition == "matched_existing_issue" and .moved_to_processed == true
' "$OUT" >/dev/null

jq -s -e '
  ([ .[] | select(.action == "create_issue") ] | length) == 2
  and ([ .[] | select(.action == "comment_issue" and .issue_number == 9001) ] | length) == 1
  and ([ .[] | select(.action == "comment_issue" and .issue_number == 606) ] | length) == 1
' "$ACTIONS" >/dev/null

[ -f "$INBOX/processed/001-related.md" ] || fail "related source was not processed"
[ -f "$INBOX/processed/002-related.md" ] || fail "consolidated source was not processed"
[ -f "$INBOX/processed/003-existing.md" ] || fail "existing-match source was not processed"
[ -f "$INBOX/processed/004-distinct.md" ] || fail "distinct source was not processed"
[ -f "$INBOX/005-unsafe.md" ] || fail "unsafe source should remain in inbox"

EVENT_LOG="$HOME/.dev-studio/generic-dev-studio/events/$(date -u +%Y-%m-%d).jsonl"
[ -f "$EVENT_LOG" ] || fail "feedback_ingested events were not emitted"
[ "$(grep -c '"event":"feedback_ingested"' "$EVENT_LOG")" -eq 4 ] || fail "expected four feedback_ingested events"
grep -q '"source_file":"sample-project/003-existing.md"' "$EVENT_LOG" || fail "event lacks source file"
grep -q '"destination_issue":606' "$EVENT_LOG" || fail "event lacks destination issue"
grep -q '"disposition":"matched_existing_issue"' "$EVENT_LOG" || fail "event lacks disposition"

printf 'PASS: manager analyze feedback ingestion\n'
