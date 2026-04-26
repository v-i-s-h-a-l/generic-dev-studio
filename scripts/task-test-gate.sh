#!/usr/bin/env bash
# task-test-gate.sh — sibling of task-build-gate.sh for `xcodebuild test`.
#
# Phase 0 of the release-substrate arc (#215). The achilles test-suite mode
# (and any future agent path that wants a full xcodebuild test run) routes
# here so the toolchain entry funnels through one place: node-pick + per-
# node lock + structured event emission. Direct xcodebuild from agent prose
# is the bug — this wrapper closes that path for the test-suite shape.
#
# Why a sibling rather than a new mode on task-build-gate.sh: the eventing
# vocabulary differs (test_run_* vs build_check_*), the optional argument
# set differs (-only-testing target), and the gate's worktree+attempts
# state should not collide with the build gate's per-task lock — a build
# and a test for the same task should be allowed to run sequentially
# without one refusing the other on the build-check task lock. Sibling
# script keeps both gates compositional and independently testable.
#
# Usage:
#   scripts/task-test-gate.sh <task-id> <worktree> <scheme> <destination> [<test-target>] [<project-or-workspace-relpath>]
#
#   project-or-workspace-relpath: optional, worktree-relative path to a
#     .xcodeproj or .xcworkspace. Pinned via xcodebuild's -project /
#     -workspace; auto-detection at the worktree root is fragile in
#     multi-project repos (#238). Pass empty test-target to skip the 5th
#     arg when only the project pin is needed: `... <dest> "" <project>`.
#
# Exit codes:
#   0  green       — all tests passed
#   2  red         — tests failed, missing tools, or bad args
#   3  locked-out  — 30-minute xcodebuild-lock wait exceeded
#
# Events emitted:
#   test_run_started     — entry, payload includes attempt + node + worktree
#   test_run_passed      — clean exit 0
#   test_run_failed      — non-zero exit; payload carries node + scheme +
#                          test_target + duration_s + attempt
#
# DerivedData reuses `resolve_derived_data_for "$TASK_ID"` so a build that
# already ran for this task hands its products to the test phase without
# a recompile (matches argus-run-tests.sh's behaviour). The xcodebuild lock
# is the same per-node lock task-build-gate.sh uses — running build then
# test serializes naturally on the node's SPM + simulator caches.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:?usage: task-test-gate.sh <task-id> <worktree> <scheme> <destination> [<test-target>] [<project-or-workspace-relpath>]}"
WORKTREE="${2:?worktree required}"
SCHEME="${3:?scheme required}"
DESTINATION="${4:?destination required}"
TEST_TARGET="${5:-}"
PROJECT_RELPATH="${6:-}"

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

case "$PROJECT_RELPATH" in
  ''|*.xcodeproj|*.xcworkspace) ;;
  *)
    printf 'error: project-or-workspace-relpath must end in .xcodeproj or .xcworkspace (got %s)\n' "$PROJECT_RELPATH" >&2
    exit 2
    ;;
esac

# Pick a swift-test-tagged node — same role as swift-test-gate.sh asks for.
# The build gate uses `xcodebuild`; the test gate uses `swift-test`. Both
# resolve to the same machines today, but the role split keeps future
# differentiation cheap (e.g. a node with simulators but no Xcode).
NODE_ID=$("$SCRIPT_DIR/node-pick.sh" swift-test 2>/dev/null || echo local)

if node_is_self "$NODE_ID"; then
  IS_LOCAL=1
else
  IS_LOCAL=0
  # Pre-flight Xcode-version drift guard (#136). Same contract as
  # task-build-gate.sh — block on major drift, warn on minor/patch.
  if ! "$SCRIPT_DIR/check-xcode-parity.sh" "$NODE_ID"; then
    data=$(printf '{"node":"%s","reason":"xcode_major_drift","attempt":%s}' "$NODE_ID" "$ATTEMPT")
    emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    exit 2
  fi
fi

LOCK_ROOT="$(resolve_runtime_global)/xcodebuild-lock"
LOCK="$LOCK_ROOT/$NODE_ID"
DERIVED=$(resolve_derived_data_for "$TASK_ID")
mkdir -p "$DERIVED" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$DERIVED" >&2; exit 2; }
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$(dirname "$LOCK")" >&2; exit 2; }

ATTEMPT=1
GATE_START_S=$(date -u +%s)
gate_announce_start test "$NODE_ID" "$TASK_ID" full-test

start_data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","worktree":"%s","attempt":%s}' \
  "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$WORKTREE" "$ATTEMPT")
emit_event_keyed achilles task test_run_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN xcodebuild test node=%s scheme=%s destination=%s test-target=%s -derivedDataPath=%s\n' \
    "$NODE_ID" "$SCHEME" "$DESTINATION" "${TEST_TARGET:-<all>}" "$DERIVED" >&2
  data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","dry_run":true,"attempt":%s}' \
    "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$ATTEMPT")
  emit_event_keyed achilles task test_run_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  gate_announce_done test "$NODE_ID" "$TASK_ID" dry-run 0
  exit 0
fi

# Acquire per-node lock with 30-min wait cap, 45-min staleness reclaim.
# Same envelope as task-build-gate.sh — keeps build + test phases of one
# task on the same lock so they can't deadlock each other on cross-node
# resources.
wait_seconds=0
wait_cap=1800
backoff=10
while true; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/pid"
    break
  fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    printf 'warn: stale xcodebuild lock (>45m), reclaiming\n' >&2
    rm -rf "$LOCK"
    continue
  fi
  if [ "$wait_seconds" -ge "$wait_cap" ]; then
    data=$(printf '{"node":"%s","reason":"locked_out","waited_s":%s,"attempt":%s}' "$NODE_ID" "$wait_seconds" "$ATTEMPT")
    emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    printf 'error: xcodebuild lock wait exceeded %ss\n' "$wait_cap" >&2
    gate_announce_done test "$NODE_ID" "$TASK_ID" locked-out "$wait_seconds"
    exit 3
  fi
  sleep "$backoff"
  wait_seconds=$((wait_seconds + backoff))
done
# Trap also clears the badge/title on aborted exit so a SIGKILL'd run
# doesn't leave a stale overlay pinned in the user's pane.
trap 'rm -rf "$LOCK" 2>/dev/null; _gate_set_title ""; _gate_set_badge ""' EXIT INT TERM

if [ "$IS_LOCAL" = "1" ]; then
  cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }
fi

test_log=$(mktemp 2>/dev/null || printf '/tmp/xcb-test-%s.log' "$$")
RUN_START_S=$(date -u +%s)

# `set --` builds the argv so an empty TEST_TARGET means "no -only-testing"
# rather than "-only-testing:" (which xcodebuild would reject). Keeps the
# wrapper usable for both targeted and full-suite runs. The optional
# -project / -workspace pin (#238) is folded in before -scheme; xcodebuild
# requires that ordering.
set -- test
case "$PROJECT_RELPATH" in
  *.xcworkspace) set -- "$@" -workspace "$PROJECT_RELPATH" ;;
  *.xcodeproj)   set -- "$@" -project   "$PROJECT_RELPATH" ;;
esac
set -- "$@" -scheme "$SCHEME" -destination "$DESTINATION" -derivedDataPath "$DERIVED"
[ -n "$TEST_TARGET" ] && set -- "$@" -only-testing:"$TEST_TARGET"

if [ "$IS_LOCAL" = "1" ]; then
  "$SCRIPT_DIR/xcodebuild-shim.sh" "$@" >"$test_log" 2>&1
  TEST_STATUS=$?
else
  # Remote dispatch — mirror the worktree under remote $HOME, route the
  # test invocation through the worker's xcodebuild-shim. Shape borrowed
  # from task-build-gate.sh's remote branch; kept inline rather than
  # extracted to avoid premature factoring.
  # shellcheck source=lib-source-sync.sh
  . "$SCRIPT_DIR/lib-source-sync.sh"
  REL_WORKTREE=$(sourcesync_push "$NODE_ID" "$WORKTREE") || {
    printf 'task-test-gate: source sync to %s failed\n' "$NODE_ID" >&2
    data=$(printf '{"node":"%s","reason":"source_sync_failed","attempt":%s}' "$NODE_ID" "$ATTEMPT")
    emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    exit 2
  }
  REL_DERIVED=$(sourcesync_relative_to_home "$DERIVED") || {
    printf 'task-test-gate: DerivedData path %s outside $HOME — refusing remote dispatch\n' "$DERIVED" >&2
    exit 2
  }
  sourcesync_mkdir_remote "$NODE_ID" "$REL_DERIVED" || exit 2
  Q_WORKTREE=$(sourcesync_remote_quoted "$REL_WORKTREE")
  Q_DERIVED=$(sourcesync_remote_quoted "$REL_DERIVED")
  Q_MCP_MODE=$(printf '%q' "${STUDIO_XCODEBUILDMCP:-auto}")

  REMOTE_CMD='[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)";'
  REMOTE_CMD+=' [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)";'
  REMOTE_CMD+=' _SHIM="$HOME/.dev-studio/.runtime/bin/xcodebuild-shim.sh";'
  REMOTE_CMD+=' [ -x "$_SHIM" ] || _SHIM=xcodebuild;'
  REMOTE_CMD+=' export STUDIO_XCODEBUILDMCP='"$Q_MCP_MODE"';'
  REMOTE_CMD+=' cd '"$Q_WORKTREE"' && "$_SHIM" test'
  case "$PROJECT_RELPATH" in
    *.xcworkspace) REMOTE_CMD+=' -workspace '"$(printf '%q' "$PROJECT_RELPATH")" ;;
    *.xcodeproj)   REMOTE_CMD+=' -project '"$(printf '%q' "$PROJECT_RELPATH")" ;;
  esac
  REMOTE_CMD+=' -scheme '"$(printf '%q' "$SCHEME")"' -destination '"$(printf '%q' "$DESTINATION")"' -derivedDataPath '"$Q_DERIVED"
  [ -n "$TEST_TARGET" ] && REMOTE_CMD+=' -only-testing:'"$(printf '%q' "$TEST_TARGET")"

  "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" >"$test_log" 2>&1
  TEST_STATUS=$?
fi

RUN_END_S=$(date -u +%s)
DURATION_S=$(( RUN_END_S - RUN_START_S ))
[ "$DURATION_S" -lt 0 ] && DURATION_S=0

# Test count is best-effort — same parser shape as argus-run-tests.sh.
TEST_COUNT=$(grep -Eo 'Test Suite .* passed|Executed [0-9]+ tests' "$test_log" 2>/dev/null \
  | grep -Eo '[0-9]+' | head -1)
TEST_COUNT="${TEST_COUNT:-0}"

rm -f "$test_log" 2>/dev/null || true

if [ "$TEST_STATUS" -eq 0 ]; then
  data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"test_count":%s,"attempt":%s}' \
    "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$TEST_COUNT" "$ATTEMPT")
  emit_event_keyed achilles task test_run_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  gate_announce_done test "$NODE_ID" "$TASK_ID" passed "$DURATION_S"
  exit 0
fi

data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"attempt":%s,"exit_code":%s}' \
  "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$ATTEMPT" "$TEST_STATUS")
emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
gate_announce_done test "$NODE_ID" "$TASK_ID" failed "$DURATION_S"
exit 2
