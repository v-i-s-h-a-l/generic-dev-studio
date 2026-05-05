#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/609-ingest-feedback-consolidation"
RUN="$ROOT/scripts/ingest-feedback.sh"
TMPROOT=$(mktemp -d -t ingest-feedback-consolidation.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/ingest-feedback.sh is not executable"

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=generic-dev-studio
INBOX="$HOME/.dev-studio/generic-dev-studio/feedback-inbox/sample-project"
mkdir -p "$INBOX"

cat > "$INBOX/001-related.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:00:00Z
cluster: feedback ingest consolidation
---
# Feedback ingest should create one durable issue

Automatic feedback ingest needs a durable public destination when no related issue exists.
MD

cat > "$INBOX/002-related.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:01:00Z
cluster: feedback ingest consolidation
---
# Feedback ingest should consolidate related records

The same feedback ingest consolidation gap should be added to the first issue instead of creating another one.
MD

cat > "$INBOX/003-existing.md" <<'MD'
---
kind: bug
scope: generic-dev-studio
ts: 2026-05-05T00:02:00Z
---
# Sibling review payload handoff drops context

The sibling review payload handoff should preserve readable context for later phases.
MD

cat > "$INBOX/004-distinct.md" <<'MD'
---
kind: enhancement
scope: generic-dev-studio
ts: 2026-05-05T00:03:00Z
---
# Mermaid chronology renderer needs year buckets

Release notes chronology rendering should group entries into stable year buckets.
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

cat > "$INBOX/006-uncertain.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:05:00Z
---
# Budget note should remain for triage

A budget-only overlap is not enough evidence to pick an existing issue automatically.
MD

ACTIONS="$TMPROOT/actions.jsonl"
ANALYSIS="$TMPROOT/analysis.md"

"$RUN" \
  --inbox-root "$HOME/.dev-studio/generic-dev-studio/feedback-inbox" \
  --issues-file "$FIXTURE_DIR/issues.json" \
  --actions-file "$ACTIONS" \
  --analysis-file "$ANALYSIS"

jq -s -e '
  ([ .[] | select(.action == "create_issue") ] | length) == 2
  and ([ .[] | select(.action == "comment_issue" and .issue_number == 9101) ] | length) == 1
  and ([ .[] | select(.action == "comment_issue" and .issue_number == 606) ] | length) == 1
' "$ACTIONS" >/dev/null

[ -f "$INBOX/processed/001-related.md" ] || fail "related source was not processed"
[ -f "$INBOX/processed/002-related.md" ] || fail "consolidated source was not processed"
[ -f "$INBOX/processed/003-existing.md" ] || fail "existing-match source was not processed"
[ -f "$INBOX/processed/004-distinct.md" ] || fail "distinct source was not processed"
[ -f "$INBOX/005-unsafe.md" ] || fail "unsafe source should remain in inbox"
[ -f "$INBOX/006-uncertain.md" ] || fail "uncertain source should remain in inbox"

EVENT_LOG="$HOME/.dev-studio/generic-dev-studio/events/$(date -u +%Y-%m-%d).jsonl"
[ -f "$EVENT_LOG" ] || fail "feedback_ingested events were not emitted"
[ "$(grep -c '"event":"feedback_ingested"' "$EVENT_LOG")" -eq 6 ] || fail "expected six feedback_ingested events"

jq -s -e '
  any(.[]; .event == "feedback_ingested"
    and .data.source_file == "sample-project/001-related.md"
    and .data.disposition == "created_issue"
    and .data.destination_issue == 9101)
' "$EVENT_LOG" >/dev/null || fail "created_issue event missing destination"

jq -s -e '
  any(.[]; .event == "feedback_ingested"
    and .data.source_file == "sample-project/002-related.md"
    and .data.disposition == "added_to_existing_issue"
    and .data.destination_issue == 9101)
' "$EVENT_LOG" >/dev/null || fail "same-batch consolidation event missing destination"

jq -s -e '
  any(.[]; .event == "feedback_ingested"
    and .data.source_file == "sample-project/003-existing.md"
    and .data.disposition == "added_to_existing_issue"
    and .data.destination_issue == 606)
' "$EVENT_LOG" >/dev/null || fail "existing issue event missing destination"

jq -s -e '
  any(.[]; .event == "feedback_ingested"
    and .data.source_file == "sample-project/005-unsafe.md"
    and .data.disposition == "deferred_manual_triage"
    and .data.triage_reason == "privacy_scrub_required")
' "$EVENT_LOG" >/dev/null || fail "privacy deferral event missing reason"

jq -s -e '
  any(.[]; .event == "feedback_ingested"
    and .data.source_file == "sample-project/006-uncertain.md"
    and .data.disposition == "deferred_manual_triage"
    and .data.destination_issue == 607
    and .data.triage_reason == "uncertain_similarity")
' "$EVENT_LOG" >/dev/null || fail "uncertain deferral event missing candidate destination"

printf 'PASS: feedback ingest consolidation\n'
