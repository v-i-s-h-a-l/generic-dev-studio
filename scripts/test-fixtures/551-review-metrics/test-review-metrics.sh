#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CMD="$ROOT/scripts/v2-review-metrics.sh"
SCHEMA="$ROOT/core/v2/schemas/review-finding-event.schema.json"
TMPROOT=$(mktemp -d -t review-metrics-551.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"
[ -x "$CMD" ] || fail "v2-review-metrics.sh is not executable"

RUNTIME="$TMPROOT/runtime"
mkdir -p "$RUNTIME"

"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:00Z \
  --phase-ref '#551/C9' --review-ref plan-review --review-host claude-reviewer --review-kind plan \
  --finding-id host-attribution --severity high --disposition accepted \
  --summary 'Add review_host attribution' --prevented-defect-ref '#551'

# Duplicate same disposition should not double-count because report groups by review_ref/finding_id.
"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:01Z \
  --phase-ref '#551/C9' --review-ref plan-review --review-host claude-reviewer --review-kind plan \
  --finding-id host-attribution --severity high --disposition accepted \
  --summary 'Add review_host attribution' --prevented-defect-ref '#551'

# Re-disposition should be last-write-wins.
"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:02Z \
  --phase-ref '#551/C9' --review-ref outcome-review --review-host claude-reviewer --review-kind outcome \
  --finding-id style-warning --severity low --disposition accepted \
  --summary 'Initial style finding disposition'
"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:03Z \
  --phase-ref '#551/C9' --review-ref outcome-review --review-host claude-reviewer --review-kind outcome \
  --finding-id style-warning --severity low --disposition rejected \
  --summary 'Style finding rejected as non-substantive'

"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:04Z \
  --phase-ref '#551/C9' --review-ref pr-review --review-host codex-reviewer --review-kind pr \
  --finding-id disputed-finding --severity medium --disposition disputed \
  --summary 'Disputed finding example'

"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:05Z \
  --phase-ref '#548/C7' --review-ref pilot-review --review-host claude-reviewer --review-kind plan \
  --finding-id old-shape --severity high --disposition superseded --superseded-by new-shape \
  --summary 'Old pilot shape superseded'
"$CMD" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:06Z \
  --phase-ref '#548/C7' --review-ref pilot-review --review-host claude-reviewer --review-kind plan \
  --finding-id new-shape --severity low --disposition accepted --follow-up-ref '#548' \
  --summary 'Replacement pilot shape accepted'

OUT="$TMPROOT/report.json"
"$CMD" report --runtime-root "$RUNTIME" --format json --output "$OUT"

jq -e '
  .total_terminal_findings == 5 and
  .accepted_weighted_score == 6 and
  .disposition_counts.accepted == 2 and
  .disposition_counts.rejected == 1 and
  .disposition_counts.disputed == 1 and
  .disposition_counts.superseded == 1 and
  (.phases[] | select(.phase_ref == "#551/C9") | .accepted_weighted_score == 5) and
  (.phases[] | select(.phase_ref == "#551/C9") | .by_host[] | select(.review_host == "claude-reviewer") | .accepted_weighted_score == 5) and
  (.phases[] | select(.phase_ref == "#551/C9") | .by_host[] | select(.review_host == "codex-reviewer") | .disposition_counts.disputed == 1) and
  (.findings[] | select(.finding_id == "host-attribution") | .prevented_defect_ref == "#551") and
  (.findings[] | select(.finding_id == "new-shape") | .follow_up_ref == "#548") and
  (.findings[] | select(.finding_id == "style-warning") | .disposition == "rejected")
' "$OUT" >/dev/null || fail "review metrics report did not aggregate expected weighted findings"

MD="$TMPROOT/report.md"
"$CMD" report --runtime-root "$RUNTIME" --format markdown --output "$MD"
grep -q 'Accepted weighted score: 6' "$MD" || fail "markdown report missing score"
grep -q 'claude-reviewer' "$MD" || fail "markdown report missing host slice"

sample="$TMPROOT/sample.json"
head -n 1 "$RUNTIME/events/2026-05-04.jsonl" > "$sample"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" "$sample" >/dev/null \
  || fail "schema rejected review metric event"

if "$CMD" emit --runtime-root "$RUNTIME" --quiet \
  --phase-ref '#551/C9' --review-ref bad --review-host claude-reviewer --review-kind plan \
  --finding-id bad-severity --severity urgent --disposition accepted --summary 'bad' >"$TMPROOT/bad-severity.out" 2>"$TMPROOT/bad-severity.err"; then
  fail "invalid severity was accepted"
fi
grep -q 'unknown severity: urgent' "$TMPROOT/bad-severity.err" || fail "invalid severity error was not explicit"

if "$CMD" emit --runtime-root "$RUNTIME" --quiet \
  --phase-ref '#551/C9' --review-ref bad --review-host claude-reviewer --review-kind plan \
  --finding-id bad-disposition --severity low --disposition deferred --summary 'bad' >"$TMPROOT/bad-disposition.out" 2>"$TMPROOT/bad-disposition.err"; then
  fail "invalid disposition was accepted"
fi
grep -q 'unknown disposition: deferred' "$TMPROOT/bad-disposition.err" || fail "invalid disposition error was not explicit"

if "$CMD" emit --runtime-root "$RUNTIME" --quiet \
  --phase-ref '#551/C9' --review-ref bad --review-host claude-reviewer --review-kind plan \
  --finding-id bad-superseded --severity low --disposition superseded --summary 'bad' >"$TMPROOT/bad-superseded.out" 2>"$TMPROOT/bad-superseded.err"; then
  fail "superseded without superseded_by was accepted"
fi
grep -q 'superseded-by is required' "$TMPROOT/bad-superseded.err" || fail "superseded error was not explicit"

printf 'PASS: review metrics\n'
