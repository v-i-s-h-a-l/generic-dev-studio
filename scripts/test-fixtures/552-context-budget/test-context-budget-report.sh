#!/usr/bin/env bash
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CMD="$REPO_ROOT/scripts/v2-context-budget.sh"
MANIFEST="$REPO_ROOT/core/v2/context-budget/manifest.json"
TMPROOT=$(mktemp -d -t context-budget-552.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

report="$TMPROOT/report.json"
"$CMD" --report --format json --output "$report"

jq -e '
  (.roles | length) == 9 and
  (.summary.unmeasured | length) == 0 and
  (["manager","planner","worker","reviewer","qa-engineer","flow-tester","perf","release-manager"] - [.roles[].role] | length) == 0 and
  all(.roles[]; .status != "unmeasured" and (.evidence_files | length) > 0) and
  .manifest_path == "core/v2/context-budget/manifest.json" and
  .evidence_scope == "static contract-surface lower bound; not runtime token telemetry"
' "$report" >/dev/null || fail "default report did not cover measured #552 roles"

markdown="$TMPROOT/report.md"
"$CMD" --report --format markdown --output "$markdown"
grep -q 'static contract-surface lower bound' "$markdown" || fail "markdown missing evidence disclosure"
grep -q 'On-demand skill content is excluded' "$markdown" || fail "markdown missing on-demand skill caveat"
grep -q '## Under Budget' "$markdown" || fail "markdown missing under-budget section"
grep -q '## Unmeasured' "$markdown" || fail "markdown missing unmeasured section"

missing_manifest="$TMPROOT/missing-manifest.json"
jq '.roles += [{
  "role": "operator",
  "max_context_tokens": 1000,
  "required_declared_reads": true,
  "telemetry_scope": "role"
}]' "$MANIFEST" > "$missing_manifest"
"$CMD" --manifest "$missing_manifest" --report --roles operator --format json > "$TMPROOT/missing.json"
jq -e '
  .summary.unmeasured == ["operator"] and
  .roles[0].status == "unmeasured" and
  (.roles[0].missing_evidence_files | index("core/v2/roles/operator.yaml"))
' "$TMPROOT/missing.json" >/dev/null || fail "missing role surface was not reported as unmeasured"

planner_estimated=$(jq -r '.roles[] | select(.role == "planner") | .estimated_tokens' "$report")

warning_manifest="$TMPROOT/warning-manifest.json"
jq --argjson budget "$((planner_estimated + 1))" '
  (.roles[] | select(.role == "planner") | .max_context_tokens) = $budget
' "$MANIFEST" > "$warning_manifest"
"$CMD" --manifest "$warning_manifest" --report --roles planner --format json > "$TMPROOT/warning.json"
jq -e '.summary.warning == ["planner"] and .roles[0].status == "warning"' "$TMPROOT/warning.json" >/dev/null \
  || fail "warning classification was not reported"

over_manifest="$TMPROOT/over-manifest.json"
jq '(.roles[] | select(.role == "planner") | .max_context_tokens) = 1' "$MANIFEST" > "$over_manifest"
"$CMD" --manifest "$over_manifest" --report --roles planner --format json > "$TMPROOT/over.json"
jq -e '.summary.over_budget == ["planner"] and .roles[0].status == "over_budget"' "$TMPROOT/over.json" >/dev/null \
  || fail "over-budget classification was not reported"

printf 'PASS: context budget report\n'
