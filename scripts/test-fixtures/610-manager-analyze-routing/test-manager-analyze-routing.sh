#!/usr/bin/env bash
# Regression fixture: manager analyze stays studio-scoped while manager
# reconcile processes project debriefs without draining studio feedback.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ANALYZE="$ROOT/scripts/manager-analyze.sh"
RECONCILE="$ROOT/scripts/manager-reconcile.sh"
ISSUES="$ROOT/scripts/test-fixtures/608-feedback-analyze-ingest/issues.json"
TMPROOT=$(mktemp -d -t manager-analyze-routing.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for manager analyze/reconcile routing fixture\n'
  exit 0
fi

export HOME="$TMPROOT/home"
export STUDIO_BYPASS_ANALYZE_LOGIN_HOME=1
PROJECT_CWD="$TMPROOT/sample-app"
PROJECT_ROOT="$HOME/.dev-studio/sample-app"
STUDIO_INBOX="$HOME/.dev-studio/generic-dev-studio/feedback-inbox/sample-app"
mkdir -p "$PROJECT_CWD" "$PROJECT_ROOT/plans/debriefs" "$STUDIO_INBOX"

cat > "$PROJECT_ROOT/plans/debriefs/project-bug.yaml" <<'YAML'
schema: debrief@2.0.2
id: project-bug
state: emitted
mode: direct-debrief
task_id: null
legacy_task_id: null
branch:
  worked_on: null
  merged_into: null
  merge_sha: null
argus_review:
  status: invoked
  review_id: null
report_state: done_with_concerns
follow_ups:
  - title: Fix project-only bug reported from direct debrief
YAML

cat > "$STUDIO_INBOX/studio-feedback.md" <<'MD'
---
kind: rule-gap
scope: generic-dev-studio
ts: 2026-05-05T00:00:00Z
---
# Studio feedback should wait for studio scope

Do not process this while analyzing project debriefs.
MD

if "$ANALYZE" --cwd "$PROJECT_CWD" >"$TMPROOT/analyze-project.out" 2>"$TMPROOT/analyze-project.err"; then
  fail "project analyze should refuse outside generic-dev-studio"
fi
grep -q 'manager reconcile' "$TMPROOT/analyze-project.err" \
  || fail "project analyze refusal should point to manager reconcile"

PROJECT_OUT="$TMPROOT/project-out.json"
"$RECONCILE" --cwd "$PROJECT_CWD" > "$PROJECT_OUT"

jq -e '
  .kind == "manager_reconcile_project_reports"
  and .scope == "project"
  and .project == "sample-app"
  and .debrief_queue_count_before == 1
  and .debrief_queue_count_after == 0
  and .processed_count == 1
  and .failed_count == 0
' "$PROJECT_OUT" >/dev/null

yq -e '.state == "ingested"' "$PROJECT_ROOT/plans/debriefs/project-bug.yaml" >/dev/null \
  || fail "project debrief was not ingested"

find "$PROJECT_ROOT/plans/tasks" -maxdepth 1 -type f -name '*.yaml' -print -quit | grep -q . \
  || fail "project follow-up task was not minted"

[ -f "$STUDIO_INBOX/studio-feedback.md" ] \
  || fail "project reconcile should not process studio-feedback sidecar"

STUDIO_OUT="$TMPROOT/studio-out.json"
"$ANALYZE" --cwd "$ROOT" --dry-run --issues-file "$ISSUES" > "$STUDIO_OUT"
jq -e '
  .kind == "manager_analyze_feedback_ingest"
  and .mode == "dry-run"
  and .inbox_count_before == 1
  and .inbox_count_after == 1
' "$STUDIO_OUT" >/dev/null

printf 'PASS: manager analyze/reconcile routing\n'
