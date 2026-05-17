#!/usr/bin/env bash
# Regression fixture: parent issue closeout waits for every child to be safely closed.
# shellcheck disable=SC2016

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DOCTOR="$ROOT/scripts/studio-chain-doctor.sh"
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t parent-closeout-990.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  local label="$1" file="$2" filter="$3"
  if ! jq -e "$filter" "$file" >/dev/null; then
    printf 'Assertion failed: %s\n' "$label" >&2
    cat "$file" >&2
    exit 1
  fi
}

command -v jq >/dev/null 2>&1 || fail "jq required"

grep -Fq 'parent_closeout_already_completed "$chain_run_id"' "$RUNNER" \
  || fail "runner does not skip already completed parent closeout on resume"
grep -Fq 'parent_child_issues_closed "$parent_issue"' "$RUNNER" \
  || fail "runner does not gate parent closeout on child closure"
grep -Fq 'mark_parent_closeout_completed "$chain_run_id" "$parent_issue"' "$RUNNER" \
  || fail "runner does not persist completed parent closeout state"

write_state() {
  local dir="$1" run_id="$2" parent_issue="$3" issues_json="$4" closeout_json="$5" parent_state="${6:-OPEN}" project_status="${7:-Todo}"
  mkdir -p "$dir"
  jq -n \
    --arg run_id "$run_id" \
    --arg parent_state "$parent_state" \
    --arg project_status "$project_status" \
    --argjson parent_issue "$parent_issue" \
    --argjson issues "$issues_json" \
    --argjson closeout "$closeout_json" \
    '{
      schema_version: 1,
      run_id: $run_id,
      issue_repo: "example/project",
      manifest: "chains/parent-closeout.yaml",
      status: "completed",
      started_at: "2026-05-17T00:00:00Z",
      updated_at: "2026-05-17T00:01:00Z",
      chains: [
        {
          name: "parent-closeout",
          chain_run_id: "chain-parent-closeout",
          parent_issue: {
            number: $parent_issue,
            state: $parent_state,
            project_status: $project_status
          },
          parent_closeout: $closeout,
          issues: $issues
        }
      ],
      halt_records: []
    }' > "$dir/state.json"
}

write_native_fixture() {
  local file="$1" parent_issue="$2" parent_state="$3" children_json="$4"
  jq -n \
    --argjson parent_issue "$parent_issue" \
    --arg parent_state "$parent_state" \
    --argjson children "$children_json" \
    '[{parent_issue:$parent_issue, parent_state:$parent_state, children:$children}]' > "$file"
}

closed_children='[
  {"number": 99011, "status": "completed", "integrated": true, "closed": true, "lifecycle_state": "closed"},
  {"number": 99012, "status": "completed", "integrated": true, "closed": true, "lifecycle_state": "closed"}
]'
closed_native='[
  {"number": 99011, "state": "CLOSED", "title": "Closed child 1"},
  {"number": 99012, "state": "CLOSED", "title": "Closed child 2"}
]'

READY_DIR="$TMPROOT/ready"
READY_NATIVE="$TMPROOT/ready-native.json"
write_state "$READY_DIR" "run-ready" 99001 "$closed_children" 'null'
write_native_fixture "$READY_NATIVE" 99001 OPEN "$closed_native"
STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE="$READY_NATIVE" \
  "$DOCTOR" --chain-run-root "$READY_DIR" --format json > "$TMPROOT/ready.json"
assert_jq "ready parent closeout is detected as drift" "$TMPROOT/ready.json" '
  .truth_state.parent_closeout_drift_count == 1
  and .recommendation.action == "close_parent_issue"
  and .parent_closeout_records[0].all_children_closeout_ready == true
  and .parent_closeout_records[0].drift_detected == true
'

COMPLETED_DIR="$TMPROOT/completed"
COMPLETED_NATIVE="$TMPROOT/completed-native.json"
write_state "$COMPLETED_DIR" "run-completed" 99002 "$closed_children" '{"status":"completed","mode":"closed"}' CLOSED Done
write_native_fixture "$COMPLETED_NATIVE" 99002 CLOSED "$closed_native"
STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE="$COMPLETED_NATIVE" \
  "$DOCTOR" --chain-run-root "$COMPLETED_DIR" --format json > "$TMPROOT/completed.json"
assert_jq "completed parent closeout stays idempotent" "$TMPROOT/completed.json" '
  .truth_state.parent_closeout_drift_count == 0
  and .parent_closeout_records[0].parent_closeout_status == "completed"
  and .parent_closeout_records[0].drift_detected == false
'

assert_blocker() {
  local name="$1" parent_issue="$2" issues_json="$3" native_json="$4" expected_reason="$5" expected_status="${6:-}"
  local dir="$TMPROOT/$name" native="$TMPROOT/$name-native.json" out="$TMPROOT/$name.json"
  write_state "$dir" "run-$name" "$parent_issue" "$issues_json" 'null'
  write_native_fixture "$native" "$parent_issue" OPEN "$native_json"
  STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE="$native" \
    "$DOCTOR" --chain-run-root "$dir" --format json > "$out"
  assert_jq "$name keeps parent open" "$out" \
    ".truth_state.parent_closeout_drift_count == 0
     and .parent_closeout_records[0].drift_detected == false
     and any(.parent_closeout_records[0].blockers[]; .reason_id == \"$expected_reason\"$(if [ -n "$expected_status" ]; then printf ' and .status == "%s"' "$expected_status"; fi))"
}

assert_blocker "open-child" 99003 \
  '[{"number": 99031, "status": "running", "integrated": false, "closed": false, "lifecycle_state": "running"}]' \
  '[{"number": 99031, "state": "OPEN", "title": "Open child"}]' \
  "child_not_closed" "running"

assert_blocker "failed-child" 99004 \
  '[{"number": 99041, "status": "failed", "integrated": true, "closed": true, "lifecycle_state": "closed"}]' \
  '[{"number": 99041, "state": "CLOSED", "title": "Failed child"}]' \
  "child_not_completed" "failed"

assert_blocker "blocked-child" 99005 \
  '[{"number": 99051, "status": "blocked", "integrated": true, "closed": true, "lifecycle_state": "closed"}]' \
  '[{"number": 99051, "state": "CLOSED", "title": "Blocked child"}]' \
  "child_not_completed" "blocked"

assert_blocker "unmerged-child" 99006 \
  '[{"number": 99061, "status": "completed", "integrated": false, "closed": true, "lifecycle_state": "closed"}]' \
  '[{"number": 99061, "state": "CLOSED", "title": "Unmerged child"}]' \
  "child_unmerged" "completed"

MISSING_DIR="$TMPROOT/missing-child"
MISSING_NATIVE="$TMPROOT/missing-child-native.json"
write_state "$MISSING_DIR" "run-missing-child" 99007 '[]' 'null'
write_native_fixture "$MISSING_NATIVE" 99007 OPEN '[]'
STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE="$MISSING_NATIVE" \
  "$DOCTOR" --chain-run-root "$MISSING_DIR" --format json > "$TMPROOT/missing-child.json"
assert_jq "missing generated children keep parent open" "$TMPROOT/missing-child.json" '
  .truth_state.parent_closeout_drift_count == 0
  and .parent_closeout_records[0].all_children_closeout_ready == false
  and .parent_closeout_records[0].drift_detected == false
  and (.parent_closeout_records[0].generated_children | length) == 0
'

UNREADABLE_DIR="$TMPROOT/unreadable-native"
write_state "$UNREADABLE_DIR" "run-unreadable-native" 99008 "$closed_children" 'null'
printf '[]\n' > "$TMPROOT/unreadable-native.json"
STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE="$TMPROOT/unreadable-native.json" \
  "$DOCTOR" --chain-run-root "$UNREADABLE_DIR" --format json > "$TMPROOT/unreadable-native.out" 2>"$TMPROOT/unreadable-native.err"
assert_jq "unreadable native children keep parent open" "$TMPROOT/unreadable-native.out" '
  .truth_state.parent_closeout_drift_count == 0
  and .truth_state.read_warning_count >= 1
  and .parent_closeout_records[0].native_children_status == "unreadable"
  and any(.parent_closeout_records[0].blockers[]; .set == "native" and .reason_id == "parent_native_children_fixture_missing")
'

printf 'PASS: parent closeout regression coverage\n'
