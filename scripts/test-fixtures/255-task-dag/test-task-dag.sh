#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/task-dag.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq required"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

export HOME="$TMP/home"
export ACHILLES_PROJECT="task-dag-project"

PROJECT_ROOT="$HOME/.dev-studio/$ACHILLES_PROJECT"
mkdir -p "$PROJECT_ROOT/plans/tasks" "$PROJECT_ROOT/events"

# shellcheck source=../../../scripts/lib-ledger.sh
. "$ROOT/scripts/lib-ledger.sh"

A="0190f52a-6e0c-7b3c-9a1d-0000000000a1"
B="0190f52a-6e0c-7b3c-9a1d-0000000000b2"
C="0190f52a-6e0c-7b3c-9a1d-0000000000c3"

write_task_artifact "$A" briefed "Task DAG A" \
  legacy_task_id=T255A \
  priority=p1 \
  predecessors=[] >/dev/null
write_task_artifact "$B" briefed "Task DAG B" \
  legacy_task_id=T255B \
  priority=p1 \
  predecessors="[$A]" >/dev/null
write_task_artifact "$C" briefed "Task DAG C" \
  legacy_task_id=T255C \
  priority=p1 \
  predecessors="[$B]" >/dev/null

"$ROOT/scripts/query-tasks.sh" --dispatch-ready --format=json > "$TMP/ready-start.json"
jq -e --arg a "$A" 'length == 1 and .[0].id == $a' "$TMP/ready-start.json" >/dev/null

mkdir -p "$PROJECT_ROOT/.runtime/achilles-inbox/worker-1/inbox"
touch "$PROJECT_ROOT/.runtime/achilles-inbox/worker-1/alive"
if "$ROOT/scripts/achilles-dispatch.sh" "$B" any >"$TMP/dispatch-block.out" 2>"$TMP/dispatch-block.err"; then
  echo "FAIL: dispatch unexpectedly ignored unresolved predecessor" >&2
  exit 1
fi
grep -q 'dispatch blocked' "$TMP/dispatch-block.err"

transition_task_state "$A" merged chanakya "fixture predecessor complete" >/dev/null
"$ROOT/scripts/query-tasks.sh" --dispatch-ready --format=json > "$TMP/ready-after-a.json"
jq -e --arg b "$B" 'length == 1 and .[0].id == $b' "$TMP/ready-after-a.json" >/dev/null

if write_task_artifact "$A" briefed "Task DAG A cycle" predecessors="[$B]" >"$TMP/cycle.out" 2>"$TMP/cycle.err"; then
  echo "FAIL: cycle write unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'predecessor cycle detected' "$TMP/cycle.err"

"$ROOT/scripts/query-plans.sh" --blocked-by="$A" --format=json > "$TMP/blocked-by-a.jsonl"
grep -q "$B" "$TMP/blocked-by-a.jsonl"
if grep -q "$C" "$TMP/blocked-by-a.jsonl"; then
  echo "FAIL: --blocked-by returned transitive successor" >&2
  exit 1
fi

transition_task_state "$A" blocked chanakya "fixture upstream blocked" >/dev/null
"$ROOT/scripts/chanakya-snap.sh" briefs >/dev/null
"$ROOT/scripts/status-render-tasks.sh" < "$PROJECT_ROOT/.runtime/state/chanakya-snapshots/briefs.json" > "$TMP/status.md"
grep -q "blocked_by_predecessor=$A" "$TMP/status.md"
grep -q "cascading_block=true" "$TMP/status.md"

echo "PASS: task DAG predecessor gating"
