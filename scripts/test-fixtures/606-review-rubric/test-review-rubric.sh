#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t review-rubric-606.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

cat > "$TMPROOT/review-valid.yaml" <<'YAML'
schema_version: {name: review, version: 1.2.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77
stage: quality
subject: {kind: task, id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11}
reviewer: argus
state: flagged
requested_at: 2026-05-05T00:00:00Z
completed_at: 2026-05-05T00:01:00Z
verdict: flagged
findings:
  - rule: R606_review_scope
    tier: ask
    severity: medium
    likelihood: plausible
    impact: medium
    change_risk: medium
    confidence: medium
    basis: task-context
    recommended_action: accepted_with_modified_fix
    message: "Finding needs worker disposition instead of direct application."
    path: "_shared/schemas/review.md"
checks_run: []
scope:
  context_scopes: [diff-only, task-context]
  diff_size: 42
  file_count: 2
  caps_triggered: []
notes: null
idempotency_key: "argus:review:0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11:quality:1"
YAML

"$ROOT/scripts/validate-contract.sh" review-verdict "$TMPROOT/review-valid.yaml" >/dev/null \
  || fail "valid structured review verdict was rejected"

cat > "$TMPROOT/review-invalid.yaml" <<'YAML'
schema_version: {name: review, version: 1.2.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77
stage: quality
subject: {kind: task, id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11}
reviewer: argus
state: blocked
requested_at: 2026-05-05T00:00:00Z
completed_at: 2026-05-05T00:01:00Z
verdict: blocked
findings:
  - rule: R606_uncertain_high_risk
    tier: block
    severity: high
    likelihood: uncertain
    impact: high
    change_risk: high
    confidence: low
    basis: diff-only
    recommended_action: fix_now
    message: "This must escalate or defer instead of forcing a direct fix."
checks_run: []
scope:
  context_scopes: [diff-only]
  diff_size: 12
  file_count: 1
  caps_triggered: []
notes: null
idempotency_key: "argus:review:0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11:quality:2"
YAML

if "$ROOT/scripts/validate-contract.sh" review-verdict "$TMPROOT/review-invalid.yaml" >/dev/null 2>"$TMPROOT/review-invalid.err"; then
  fail "uncertain high-change-risk review finding accepted fix_now"
fi

cat > "$TMPROOT/worker-valid.yaml" <<'YAML'
report_state: done_with_concerns
branch: {merge_sha: abc123}
known_issues:
  - "Deferred high-risk uncertain review finding for manager arbitration."
review_loop:
  attempt: 3
  budget: 2
  escalation_required: true
  escalation_reason: "Third review attempt exceeded loop budget."
review_responses:
  - finding_id: R606_uncertain_high_risk
    response_state: needs_manager_planner_decision
    self_check: "Direct fix could undo the accepted architecture contract."
    rationale: "Reviewer only had diff context and likelihood was uncertain."
    escalation_ref: "#606"
    review_metadata:
      severity: high
      likelihood: uncertain
      impact: high
      change_risk: high
      confidence: low
      basis: diff-only
      recommended_action: needs_manager_planner_decision
YAML

PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml \
  --schemafile "$ROOT/_shared/contracts/worker-report.schema.json" \
  "$TMPROOT/worker-valid.yaml" >/dev/null \
  || fail "valid worker review response was rejected"

cat > "$TMPROOT/worker-invalid.yaml" <<'YAML'
report_state: done_with_concerns
branch: {merge_sha: abc123}
known_issues:
  - "Invalid direct fix for high-risk uncertain finding."
review_responses:
  - finding_id: R606_uncertain_high_risk
    response_state: accepted_and_fixed
    self_check: "No broader contract checked."
    rationale: "Applied reviewer command directly."
    review_metadata:
      severity: high
      likelihood: uncertain
      impact: high
      change_risk: high
      confidence: low
      basis: diff-only
      recommended_action: fix_now
YAML

if PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml \
  --schemafile "$ROOT/_shared/contracts/worker-report.schema.json" \
  "$TMPROOT/worker-invalid.yaml" >/dev/null 2>"$TMPROOT/worker-invalid.err"; then
  fail "worker accepted direct fix for uncertain high-change-risk finding"
fi

printf 'PASS: review rubric and worker response protocol\n'
