#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/501-staleness-triage"
OUT=$(mktemp -t staleness-triage.XXXXXX)
trap 'rm -f "$OUT"' EXIT

STUDIO_STALENESS_NOW_EPOCH=1777766400 \
  "$ROOT/scripts/studio-staleness-triage.sh" \
    --input "$FIXTURE_DIR/issues.json" \
    --stale-days 30 \
    --escalate-days 60 \
    --archive-days 90 \
    --json > "$OUT"

jq -e '.schema_version == 1 and .kind == "studio_staleness_triage_plan"' "$OUT" >/dev/null
jq -e '.counts.inspected == 6' "$OUT" >/dev/null
jq -e '.counts.stale == 1 and .counts.escalate == 1 and .counts.archive_candidate == 1' "$OUT" >/dev/null
jq -e '.counts.excluded == 1 and .counts.mutating_issue_count == 4' "$OUT" >/dev/null
jq -e '.issues[] | select(.number == 11) | (.remove_labels == ["stale","stale:escalated"])' "$OUT" >/dev/null
jq -e '.issues[] | select(.number == 12) | (.add_labels == ["stale"])' "$OUT" >/dev/null
jq -e '.issues[] | select(.number == 13) | (.add_labels == ["stale","stale:escalated"])' "$OUT" >/dev/null
jq -e '.issues[] | select(.number == 14) | (.add_labels == ["stale:escalated","stale:archive-candidate"])' "$OUT" >/dev/null
jq -e '.issues[] | select(.number == 15) | (.reason == "excluded" and (.add_labels | length) == 0)' "$OUT" >/dev/null

printf 'PASS: studio staleness triage plan\n'
