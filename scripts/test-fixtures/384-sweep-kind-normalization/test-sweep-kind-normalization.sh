#!/usr/bin/env bash
# Fixture for #384: sweep-ingest accepts enumerator kind aliases.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t sweep-kind-384.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="fixture-384"
PROJ="$HOME/.dev-studio/$ACHILLES_PROJECT"
TASK_UUID="01234567-89ab-7cde-8000-000000000384"
DEBRIEF_UUID="01234567-89ab-7cde-8000-000000003840"

mkdir -p "$PROJ/plans/tasks" "$PROJ/plans/debriefs" "$PROJ/events"

cat > "$PROJ/plans/tasks/$TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_UUID
legacy_task_id: T384
title: "Fixture task"
state: self-reviewed
created_at: 2026-05-02T00:00:00Z
updated_at: 2026-05-02T00:00:00Z
links:
  brief: null
  debrief: null
  reviews: []
  release: null
  feedback: []
history: []
YAML

cat > "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" <<YAML
schema_version: {name: debrief, version: 2.0.2, min_reader: 2.0.0, deprecated_at: null}
id: $DEBRIEF_UUID
task_id: $TASK_UUID
legacy_task_id: T384
mode: task
state: emitted
report_state: done
completed_at: 2026-05-02T00:01:00Z
branch: {worked_on: achilles/T384, merged_into: main, merge_sha: abc384}
commits: []
diff_summary: {files: 1, added_lines: 1, removed_lines: 0}
decisions: []
tests: {added: [], modified: [], skipped_because: "fixture"}
testability: null
build_gate: full-green
build_debt_override: false
debt: {build: false, test_unit: false, test_ui: false, notes: ""}
performance: []
key_learnings: []
known_issues: []
follow_ups: []
open_questions: []
argus_review: {status: approved, review_id: null}
YAML

if ! bash "$ROOT/scripts/sweep-ingest.sh" task-debrief "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" >/dev/null; then
  printf 'FAIL: task-debrief alias was not accepted\n' >&2
  exit 1
fi

if ! yq -e '.state == "ingested"' "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" >/dev/null; then
  printf 'FAIL: task-debrief alias did not ingest the debrief\n' >&2
  exit 1
fi

printf 'PASS: #384 sweep kind normalization\n'
