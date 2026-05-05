#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t self-review-gate-605.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

cat > "$TMPROOT/worker-valid.yaml" <<'YAML'
report_state: done
branch: {merge_sha: abc123}
argus_review: {status: approved}
debt: {build: false, test_unit: false, test_ui: false}
self_review_performed: true
self_review_findings:
  - id: SR1
    focus: edge_case
    finding: "Empty input path needed an explicit guard."
    severity: material
    disposition: fixed
self_review_fixes:
  - finding_id: SR1
    action: fixed
    summary: "Added the empty-input guard before final verification."
final_verification_evidence:
  - command: "scripts/test-fixtures/605-self-review-gate/test-self-review-gate.sh"
    outcome: pass
    timestamp: 2026-05-05T01:30:00Z
    after_self_review_fixes: true
YAML

"$ROOT/scripts/validate-contract.sh" worker-report "$TMPROOT/worker-valid.yaml" >/dev/null \
  || fail "valid worker self-review fields were rejected"

writer_out=$(
  HOME="$TMPROOT/home" ACHILLES_PROJECT=self-review-test \
    "$ROOT/scripts/task-write-self-review.sh" T605 \
      '{"self_review_findings":[{"id":"SR1","focus":"edge_case","finding":"Empty path was missed.","severity":"material","disposition":"fixed"}],"self_review_fixes":[{"finding_id":"SR1","action":"fixed","summary":"Added the guard."}],"skill_verdicts":{"simplify":"clean"},"diff_stats":{"files":1,"added_lines":2,"removed_lines":0,"public_api_changed":false}}'
)
grep -q '^self_review_performed: true$' "$writer_out" \
  || fail "self-review writer omitted self_review_performed"
grep -q '^self_review_findings:' "$writer_out" \
  || fail "self-review writer omitted self_review_findings"
grep -q '^self_review_fixes:' "$writer_out" \
  || fail "self-review writer omitted self_review_fixes"
grep -q 'version: 1.2.0' "$writer_out" \
  || fail "self-review writer did not emit self-review@1.2.0"

cat > "$TMPROOT/worker-invalid.yaml" <<'YAML'
report_state: done
branch: {merge_sha: abc123}
argus_review: {status: approved}
debt: {build: false, test_unit: false, test_ui: false}
self_review_performed: true
final_verification_evidence:
  - command: "scripts/test-fixtures/605-self-review-gate/test-self-review-gate.sh"
    outcome: pass
    timestamp: 2026-05-05T01:30:00Z
    after_self_review_fixes: false
YAML

if "$ROOT/scripts/validate-contract.sh" worker-report "$TMPROOT/worker-invalid.yaml" >/dev/null 2>"$TMPROOT/worker-invalid.err"; then
  fail "worker final verification before self-review fixes was accepted"
fi

cat > "$TMPROOT/review-missing-self-review.yaml" <<'YAML'
schema_version: {name: review, version: 1.3.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77
stage: quality
subject: {kind: task, id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11}
reviewer: argus
state: flagged
requested_at: 2026-05-05T00:00:00Z
completed_at: 2026-05-05T00:01:00Z
verdict: flagged
findings:
  - rule: R605_missing_same_host_self_review
    tier: warn
    severity: medium
    likelihood: confirmed
    impact: medium
    change_risk: low
    confidence: high
    basis: runtime/evidence-context
    recommended_action: fix_now
    message: "Worker summary omitted same-host self-review before final verification."
checks_run: []
self_review_checked:
  applicable: true
  self_review_performed: false
  artifact_refs: []
  findings_reviewed: 0
  fixes_reviewed: 0
  absence_disposition: warn
  note: "Missing same-host self-review was treated as a workflow defect."
scope:
  context_scopes: [diff-only, runtime/evidence-context]
  diff_size: 12
  file_count: 1
  caps_triggered: []
notes: null
idempotency_key: "argus:review:0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11:quality:605"
YAML

"$ROOT/scripts/validate-contract.sh" review-verdict "$TMPROOT/review-missing-self-review.yaml" >/dev/null \
  || fail "review verdict warning for missing same-host self-review was rejected"

cat > "$TMPROOT/review-invalid.yaml" <<'YAML'
schema_version: {name: review, version: 1.3.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77
stage: quality
subject: {kind: task, id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11}
reviewer: argus
state: approved
requested_at: 2026-05-05T00:00:00Z
completed_at: 2026-05-05T00:01:00Z
verdict: approved
findings: []
checks_run: []
self_review_checked:
  applicable: true
  self_review_performed: false
  artifact_refs: []
  findings_reviewed: 0
  fixes_reviewed: 0
  absence_disposition: none
  note: null
scope:
  context_scopes: [diff-only]
  diff_size: 12
  file_count: 1
  caps_triggered: []
notes: null
idempotency_key: "argus:review:0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11:quality:605-invalid"
YAML

if "$ROOT/scripts/validate-contract.sh" review-verdict "$TMPROOT/review-invalid.yaml" >/dev/null 2>"$TMPROOT/review-invalid.err"; then
  fail "missing same-host self-review with absence_disposition none was accepted"
fi

cp "$ROOT/core/v2/handoffs/planner-output.yaml" "$TMPROOT/planner-valid.yaml"
PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml \
  --schemafile "$ROOT/core/v2/schemas/handoff.schema.json" \
  "$TMPROOT/planner-valid.yaml" >/dev/null \
  || fail "planner output with self-review fields was rejected"

printf 'PASS: same-host self-review gate\n'
