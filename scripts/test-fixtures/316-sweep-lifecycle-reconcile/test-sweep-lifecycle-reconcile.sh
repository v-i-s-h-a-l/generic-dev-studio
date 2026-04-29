#!/usr/bin/env bash
# Debrief YAML facts must reconcile lifecycle events and visible side effects
# even when the canonical event log was empty.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t sweep-lifecycle-316.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="fixture-316"
PROJ="$HOME/.dev-studio/$ACHILLES_PROJECT"
TASK_UUID="01234567-89ab-7cde-8000-000000000316"
DEBRIEF_UUID="01234567-89ab-7cde-8000-000000003160"

mkdir -p "$PROJ/plans/tasks" "$PROJ/plans/debriefs" "$PROJ/events" "$PROJ/.runtime/state" "$TMPROOT/bin"

cat > "$TMPROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "issue create") printf 'https://example.invalid/issue/1\n' ;;
  "issue comment") exit 0 ;;
esac
SH
chmod +x "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH"

cat > "$PROJ/plans/tasks/$TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_UUID
legacy_task_id: T316
title: "Fixture task"
state: self-reviewed
created_at: 2026-04-30T00:00:00Z
updated_at: 2026-04-30T00:00:00Z
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
brief_id: null
legacy_task_id: T316
mode: task
state: emitted
report_state: done_with_concerns
completed_at: 2026-04-30T00:01:00Z
branch:
  worked_on: achilles/T316
  merged_into: main
  merge_sha: abc123
commits: []
diff_summary: {files: 1, added_lines: 1, removed_lines: 0}
decisions: []
tests: {added: [], modified: [], skipped_because: "fixture"}
testability: null
build_gate: full-green
build_debt_override: false
debt: {build: false, test_unit: true, test_ui: false, notes: "fixture concern"}
performance: []
key_learnings: []
known_issues: []
follow_ups:
  - title: "Write a regression test for the concern"
open_questions: []
argus_review:
  status: not-invoked
  reason: missing_manifest
  notes: codex-fixture-host
YAML

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

bash "$ROOT/scripts/sweep-ingest.sh" debrief "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" >/dev/null
# Re-run directly against the now-ingested artifact. This models the repair
# path after event-log loss: the YAML facts are canonical and re-ingestable.
bash "$ROOT/scripts/sweep-ingest.sh" debrief "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" >/dev/null

LOG=$(find "$PROJ/events" -name '*.jsonl' -print | head -1)
debrief_ingested_count=$(grep -c '"event":"debrief_ingested"' "$LOG" 2>/dev/null | tr -d ' ')
followup_count=$(find "$PROJ/plans/tasks" -name '*.yaml' -print0 \
  | xargs -0 grep -l "source_debrief: \"$DEBRIEF_UUID\"" 2>/dev/null \
  | xargs grep -l 'source_follow_up_index: 0' 2>/dev/null \
  | wc -l | tr -d ' ')

assert "debrief_ingested emitted once by producer-side reconciliation key" \
  "[ \"$debrief_ingested_count\" = 1 ]"
assert "task_completed repaired from debrief merge_sha" \
  "jq -e 'select(.event == \"task_completed\" and .data.source == \"debrief_reconcile\")' \"$LOG\" >/dev/null"
assert "review_pending repaired from argus not-invoked" \
  "jq -e 'select(.event == \"review_pending\" and .data.reason == \"argus_skipped_in_debrief\")' \"$LOG\" >/dev/null"
assert "argus infra skip repaired for recognized reason" \
  "jq -e 'select(.event == \"argus_gate_skipped\" and .data.reason == \"missing_manifest\")' \"$LOG\" >/dev/null"
assert "protected branch ungated merge audit repaired" \
  "jq -e 'select(.event == \"direct_main_ungated_merge\" and .data.merged_into == \"main\")' \"$LOG\" >/dev/null"
assert "done_with_concerns emits visible concern signal" \
  "jq -e 'select(.event == \"debrief_concerns\" and .data.report_state == \"done_with_concerns\")' \"$LOG\" >/dev/null"
assert "follow-up task minted exactly once" \
  "[ \"$followup_count\" = 1 ]"

bash "$ROOT/scripts/sweep-process-events.sh" --offset-file "$PROJ/.runtime/state/events_offset.fixture" >/dev/null
QUEUE="$PROJ/.runtime/state/push-queue.jsonl"

assert "review pending appears in push queue" \
  "jq -e 'select(.kind == \"review_pending\" and .task == \"T316\")' \"$QUEUE\" >/dev/null"
assert "ungated merge appears in push queue" \
  "jq -e 'select(.kind == \"ungated_merge\" and .task == \"T316\")' \"$QUEUE\" >/dev/null"
assert "done_with_concerns appears in push queue" \
  "jq -e 'select(.kind == \"debrief_concerns\" and .task == \"T316\")' \"$QUEUE\" >/dev/null"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: #316 sweep lifecycle reconciliation\n'
