#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CMD="$ROOT/scripts/v2-multispawn-pilot.sh"
TMPROOT=$(mktemp -d -t multispawn-pilot-548.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$CMD" ] || fail "v2-multispawn-pilot.sh is not executable"

RUNTIME="$TMPROOT/runtime"
mkdir -p "$RUNTIME"

"$CMD" run --runtime-root "$RUNTIME" --pilot-id success --subtask-id subtask-success \
  --task-class xs --worker-duration-s 2 --qa-duration-s 2 --format json > "$TMPROOT/success.json"
jq -e '
  .terminal_state == "completed" and
  .budget_result == "met" and
  .task_class == "xs" and
  .subtask_id == "subtask-success" and
  .expected_count == 2 and
  .completed_count == 2 and
  .qa_started_from_stable_contract == true
' "$TMPROOT/success.json" >/dev/null || fail "success pilot report missing expected fields"
jq -e '
  .contract_stable_epoch_s as $contract |
  any(.lanes[]; .role == "qa-engineer" and .start_epoch_s >= $contract)
' "$TMPROOT/success.json" >/dev/null || fail "success pilot stable contract field was not derived from timing"
jq -e '
  .overlap_s >= 1 and
  ([.lanes[].role] | sort) == ["qa-engineer","worker"]
' "$TMPROOT/success.json" >/dev/null || fail "success pilot report missing expected fields"

[ -f "$RUNTIME/analysis/multispawn-pilots/success/report.md" ] || fail "success markdown report missing"

"$CMD" run --runtime-root "$RUNTIME" --pilot-id budget --subtask-id subtask-budget \
  --task-class xs --worker-duration-s 0 --qa-duration-s 0 --launch-delay-s 6 --format json > "$TMPROOT/budget.json"
jq -e '
  .terminal_state == "budget_missed" and
  .budget_result == "missed" and
  .coordination_overhead_s > .coordination_budget_s
' "$TMPROOT/budget.json" >/dev/null || fail "budget miss was not reported"

"$CMD" run --runtime-root "$RUNTIME" --pilot-id partial --subtask-id subtask-partial \
  --task-class xs --worker-duration-s 0 --qa-duration-s 0 --qa-exit 7 --format json > "$TMPROOT/partial.json"
jq -e '.terminal_state == "partial" and .completed_count == 1 and .budget_result == "not_measurable"' "$TMPROOT/partial.json" >/dev/null \
  || fail "partial pilot was not reported"

"$CMD" run --runtime-root "$RUNTIME" --pilot-id failed --subtask-id subtask-failed \
  --task-class xs --worker-duration-s 0 --qa-duration-s 0 --worker-exit 6 --qa-exit 7 --format json > "$TMPROOT/failed.json"
jq -e '.terminal_state == "failed" and .completed_count == 0 and .budget_result == "not_measurable"' "$TMPROOT/failed.json" >/dev/null \
  || fail "failed pilot was not reported"

events="$TMPROOT/events.jsonl"
cat "$RUNTIME"/events/*.jsonl > "$events"
jq -e 'select(.event == "topology_budget_exhaustion" and .subject == "#548/C7/budget" and .data.budget_kind == "coordination_overhead_s")' "$events" >/dev/null \
  || fail "budget miss did not emit topology_budget_exhaustion"
jq -e 'select(.event == "topology_partial_multi_spawn" and .subject == "#548/C7/partial" and .data.completed_count == 1 and .data.expected_count == 2)' "$events" >/dev/null \
  || fail "partial pilot did not emit partial topology event"
jq -e 'select(.event == "topology_partial_multi_spawn" and .subject == "#548/C7/failed" and .data.completed_count == 0 and .data.expected_count == 2)' "$events" >/dev/null \
  || fail "failed pilot did not emit failed topology event"

if "$CMD" run --runtime-root "$RUNTIME" --pilot-id bad --subtask-id bad --task-class unknown \
  --worker-duration-s 0 --qa-duration-s 0 >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  fail "unknown task class was accepted"
fi
grep -q 'unknown task class: unknown' "$TMPROOT/bad.err" || fail "unknown task class error was not explicit"

printf 'PASS: multispawn pilot\n'
