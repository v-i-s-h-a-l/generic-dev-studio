#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t refactoring-pressure-607.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"
command -v yq >/dev/null 2>&1 || fail "yq is required"

cat > "$TMPROOT/worker-valid.yaml" <<'YAML'
report_state: done_with_concerns
branch: {merge_sha: abc123}
known_issues:
  - "Deferred refactoring pressure captured as follow-up work."
refactoring_pressure:
  needed_now:
    - kind: localized_cleanup
      reason: "Duplicated parser branch would make the touched change unsafe to maintain."
      affected_area: "FilterPresetParser"
      risk: low
      implemented_change: "Extracted parsePresetName before adding the new branch."
  deferred_follow_ups:
    - kind: awkward_boundary
      reason: "Repeated task edits now cross the editor/export boundary."
      affected_area: "ExportCoordinator and EditorSessionStore"
      risk: medium
      suggested_timing: "Plan after the current release branch closes."
      follow_up_ref: "#607"
YAML

"$ROOT/scripts/validate-contract.sh" worker-report "$TMPROOT/worker-valid.yaml" >/dev/null \
  || fail "valid worker refactoring pressure was rejected"

cat > "$TMPROOT/worker-invalid.yaml" <<'YAML'
report_state: done_with_concerns
branch: {merge_sha: abc123}
known_issues:
  - "Deferred refactoring pressure lacks timing."
refactoring_pressure:
  deferred_follow_ups:
    - kind: duplication
      reason: "Three duplicated helpers now exist."
      affected_area: "Export helpers"
      risk: medium
YAML

if "$ROOT/scripts/validate-contract.sh" worker-report "$TMPROOT/worker-invalid.yaml" >/dev/null 2>"$TMPROOT/worker-invalid.err"; then
  fail "worker refactoring follow-up without suggested_timing was accepted"
fi

cat > "$TMPROOT/debrief-valid.yaml" <<'YAML'
schema_version: {name: debrief, version: 2.6.0, min_reader: 2.0.0, deprecated_at: null}
id: 0190f52a-79aa-7d02-8b88-33ce5fe65e66
task_id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11
brief_id: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c
mode: task
state: emitted
completed_at: 2026-05-05T00:00:00Z
branch: {worked_on: achilles/T607, merged_into: feature/refactoring-pressure, merge_sha: abc123}
commits:
  - {sha: abc1234, message: "Capture refactoring pressure"}
diff_summary: {files: 2, added_lines: 80, removed_lines: 4}
decisions: []
tests: {added: [], modified: [], skipped_because: null}
testability: null
build_gate: lsp-only
build_debt_override: false
debt: {build: false, test_unit: false, test_ui: false, notes: null}
performance: []
key_learnings: []
known_issues:
  - "Refactoring follow-up was proposed but not implemented in this bounded task."
follow_ups:
  - id: T607-fu-1
    title: "Refactor exporter boundary after repeated edits"
    text: "Refactor exporter boundary after repeated edits."
    category: refactoring-follow-up
    severity: medium
    refactoring:
      kind: awkward_boundary
      reason: "Repeated task edits now cross the editor/export boundary."
      affected_area: "ExportCoordinator and EditorSessionStore"
      risk: medium
      suggested_timing: "Plan after the current release branch closes."
open_questions: []
argus_review: {status: approved, review_id: null, notes: null}
report_state: done_with_concerns
refactoring_pressure:
  needed_now: []
  deferred_follow_ups:
    - kind: awkward_boundary
      reason: "Repeated task edits now cross the editor/export boundary."
      affected_area: "ExportCoordinator and EditorSessionStore"
      risk: medium
      suggested_timing: "Plan after the current release branch closes."
YAML

"$ROOT/scripts/validate-contract.sh" debrief "$TMPROOT/debrief-valid.yaml" >/dev/null \
  || fail "valid debrief refactoring follow-up was rejected"

cp "$ROOT/core/v2/handoffs/planner-output.yaml" "$TMPROOT/planner-invalid.yaml"
yq 'del(.payload.refactoring_follow_ups[0].suggested_timing)' "$TMPROOT/planner-invalid.yaml" > "$TMPROOT/planner-invalid.out"
if PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml \
  --schemafile "$ROOT/core/v2/schemas/handoff.schema.json" "$TMPROOT/planner-invalid.out" >/dev/null 2>"$TMPROOT/planner-invalid.err"; then
  fail "planner refactoring follow-up without suggested_timing was accepted"
fi

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
  - rule: R607_unsafe_refactoring_scope_expansion
    tier: ask
    severity: medium
    likelihood: plausible
    impact: medium
    change_risk: high
    confidence: medium
    basis: task-context
    recommended_action: deferred_follow_up
    message: "Broad cleanup is real but not justified as required for this bounded task."
    path: "core/v2/roles/worker.yaml"
checks_run: []
scope:
  context_scopes: [diff-only, task-context]
  diff_size: 42
  file_count: 2
  caps_triggered: []
notes: null
idempotency_key: "argus:review:0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11:quality:607"
YAML

"$ROOT/scripts/validate-contract.sh" review-verdict "$TMPROOT/review-valid.yaml" >/dev/null \
  || fail "valid unsafe refactoring scope finding was rejected"

grep -Fq '.follow_ups[$i].text' "$ROOT/scripts/sweep-ingest.sh" \
  || fail "sweep-ingest does not read structured follow_ups text"

printf 'PASS: refactoring pressure protocol\n'
