#!/usr/bin/env bash
# argus-run-tests.sh — Step 4 of the Argus pipeline (M/L only).
#
# Acquires one of three machine-global test slots per
# `_shared/primitives/test-slot.md`, boots the matching Argus-<N> simulator,
# runs `xcodebuild test -only-testing:<target>`, emits test_run_started and
# test_run_{passed|failed}, and releases the slot. DerivedData reuses the
# per-task path via `resolve_derived_data_for` so Achilles's build products
# carry into the test phase without a recompile.
#
# Retention of `/tmp/argus-<task-id>.xcresult` is the caller's concern —
# this script always leaves the bundle in place on completion.
#
# Usage:
#   scripts/argus-run-tests.sh <task-id> <scheme> <test-target>
#
# Exit codes:
#   0  tests passed
#   2  setup / slot-acquire failure
#   3  tests failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: argus-run-tests.sh <task-id> <scheme> <test-target>}"
SCHEME="${2:?scheme required}"
TEST_TARGET="${3:?test-target required}"

SLOT_DIR="$(resolve_runtime_global)/locks/test-slots"
mkdir -p "$SLOT_DIR" || { printf 'error: mkdir %s\n' "$SLOT_DIR" >&2; exit 2; }

# Stale-slot reclamation runs once before the acquire loop (never inside it —
# would race with a live peer doing the same check). Stale = dead PID or age
# > 2h per the primitive doc.
_reclaim_stale_slots() {
  local n path pid acquired age_s now_s
  now_s=$(date -u +%s)
  for n in 1 2 3; do
    path="$SLOT_DIR/slot-$n"
    [ -d "$path" ] && [ -f "$path/pid" ] || continue
    pid=$(cut -d: -f1 "$path/pid" 2>/dev/null || echo "")
    acquired=$(cut -d: -f4 "$path/pid" 2>/dev/null || echo "")
    if [ -n "$acquired" ]; then
      age_s=$(( now_s - $(ts_to_epoch "$acquired" 2>/dev/null || echo "$now_s") ))
    else
      age_s=0
    fi
    if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || [ "$age_s" -gt 7200 ]; then
      printf 'reclaiming stale slot %s (pid=%s age=%ss)\n' "$n" "$pid" "$age_s" >&2
      rm -rf "$path"
    fi
  done
}
_reclaim_stale_slots

SLOT=""
SLOT_N=""
MAX_WAIT_S=1800
START_S=$(date -u +%s)

while :; do
  for n in 1 2 3; do
    if mkdir "$SLOT_DIR/slot-$n" 2>/dev/null; then
      printf '%s:argus:%s:%s\n' "$$" "$TASK_ID" "$(iso_ts_now)" > "$SLOT_DIR/slot-$n/pid"
      SLOT="$SLOT_DIR/slot-$n"
      SLOT_N="$n"
      break
    fi
  done
  [ -n "$SLOT" ] && break
  now_s=$(date -u +%s)
  if [ $(( now_s - START_S )) -ge "$MAX_WAIT_S" ]; then
    data=$(printf '{"reason":"slot_timeout","waited_s":%s}' $(( now_s - START_S )))
    emit_event_keyed argus review test_run_failed "$TASK_ID" "$data" >/dev/null || true
    printf 'error: no test slot after %s seconds\n' "$MAX_WAIT_S" >&2
    exit 2
  fi
  sleep 15
done

# Cleanup path: release slot on any exit. The outer caller's marker-trap is
# replaced when this script `eval`s — but this script runs as a child process,
# so its traps stay scoped to its own shell.
trap 'rm -rf "$SLOT" 2>/dev/null || true' EXIT INT TERM

DEST="platform=iOS Simulator,name=Argus-${SLOT_N}"
DERIVED=$(resolve_derived_data_for "$TASK_ID")
RESULT_BUNDLE="/tmp/argus-${TASK_ID}.xcresult"
TEST_OUTPUT="/tmp/argus-${TASK_ID}-test-output.txt"

# Auto-create the Argus-<N> simulator if it's missing. First run on a fresh
# machine hits this path; steady state is a no-op.
if ! xcrun simctl list devices 2>/dev/null | grep -q "Argus-${SLOT_N}"; then
  runtime=$(xcrun simctl list runtimes 2>/dev/null | grep "iOS" | tail -1 | awk '{print $NF}')
  if [ -n "$runtime" ]; then
    xcrun simctl create "Argus-${SLOT_N}" "iPhone 16" "$runtime" >/dev/null 2>&1 || true
  fi
fi
xcrun simctl boot "Argus-${SLOT_N}" >/dev/null 2>&1 || true

data=$(printf '{"slot":%s,"suite":"%s"}' "$SLOT_N" "$TEST_TARGET")
emit_event_keyed argus review test_run_started "$TASK_ID" "$data" >/dev/null || true

RUN_START_S=$(date -u +%s)
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled YES \
  -parallel-testing-worker-count 2 \
  -only-testing:"$TEST_TARGET" \
  >"$TEST_OUTPUT" 2>&1
TEST_STATUS=$?
RUN_END_S=$(date -u +%s)
DURATION_S=$(( RUN_END_S - RUN_START_S ))

if [ "$TEST_STATUS" -eq 0 ]; then
  # Test count parsed from the xcodebuild summary line. Failures here are
  # non-fatal — a `0` count is worse than a wrong count only for dashboards.
  TEST_COUNT=$(grep -Eo 'Test Suite .* passed|Executed [0-9]+ tests' "$TEST_OUTPUT" 2>/dev/null \
    | grep -Eo '[0-9]+' | head -1)
  TEST_COUNT="${TEST_COUNT:-0}"
  data=$(printf '{"duration_s":%s,"test_count":%s}' "$DURATION_S" "$TEST_COUNT")
  emit_event_keyed argus review test_run_passed "$TASK_ID" "$data" >/dev/null || true
  exit 0
fi

# On failure: collect up to 10 failing test names, then truncate-with-count.
# xcodebuild's failure lines look like: "Test Case '-[Target testFoo]' failed"
FAILING=$(grep -E "^Test Case .* failed" "$TEST_OUTPUT" 2>/dev/null \
  | sed -E "s/^Test Case '[-+]\[[^ ]+ ([^]]+)\].*/\1/" \
  | sort -u)
FAIL_COUNT=$(printf '%s\n' "$FAILING" | sed '/^$/d' | wc -l | tr -d ' ')

# JSON array of the first 10 names + optional truncation marker.
failing_json="["
idx=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  [ "$idx" -ge 10 ] && break
  [ "$idx" -gt 0 ] && failing_json+=","
  esc=${name//\\/\\\\}
  esc=${esc//\"/\\\"}
  failing_json+='"'"$esc"'"'
  idx=$(( idx + 1 ))
done <<< "$FAILING"
failing_json+="]"

if [ "$FAIL_COUNT" -gt 10 ]; then
  data=$(printf '{"failing_tests":%s,"truncated":%s,"total_failures":%s}' \
    "$failing_json" "$(( FAIL_COUNT - 10 ))" "$FAIL_COUNT")
else
  data=$(printf '{"failing_tests":%s}' "$failing_json")
fi
emit_event_keyed argus review test_run_failed "$TASK_ID" "$data" >/dev/null || true
exit 3
