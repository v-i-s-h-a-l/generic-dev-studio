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
# shellcheck source=lib-dispatch-registry.sh
. "$SCRIPT_DIR/lib-dispatch-registry.sh"
# shellcheck source=lib-dispatch-harvest.sh
. "$SCRIPT_DIR/lib-dispatch-harvest.sh"

# #270 — populated by the remote-dispatch branch via STUDIO_DISPATCH_UUID_FILE
# sidecar. Empty for self-node and dry-run paths.
DISPATCH_UUID=""

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
REASON_FILE=$(mktemp 2>/dev/null || printf '/tmp/dispatch-reason-%s' "$$")
: > "$REASON_FILE" 2>/dev/null || true
NODE_ID=$(STUDIO_DISPATCH_REASON_FILE="$REASON_FILE" \
  "$SCRIPT_DIR/node-pick.sh" swift-test 2>/dev/null || echo local)
DISPATCH_REASON=$(tr -d '\n' < "$REASON_FILE" 2>/dev/null)
rm -f "$REASON_FILE" 2>/dev/null || true
[ -z "$DISPATCH_REASON" ] && DISPATCH_REASON="healthy"
XCODE_VER=""
PARITY_CACHE="$(resolve_runtime_global)/node-parity-cache.json"
if [ -r "$PARITY_CACHE" ] && command -v jq >/dev/null 2>&1; then
  XCODE_VER=$(jq -r --arg id "$NODE_ID" '.nodes[$id].xcodebuild.version // ""' "$PARITY_CACHE" 2>/dev/null)
fi
DISPATCH_FIELDS=$(printf ',"studio.dispatch.node":"%s","studio.dispatch.role":"swift-test","studio.dispatch.reason":"%s","studio.dispatch.xcode_version":"%s"' \
  "$NODE_ID" "$DISPATCH_REASON" "$XCODE_VER")

if node_is_self "$NODE_ID"; then
  IS_LOCAL=1
else
  IS_LOCAL=0
  # Pre-flight Xcode-version drift guard (#136). Same contract as
  # task-build-gate.sh — block on major drift, warn on minor/patch.
  if ! "$SCRIPT_DIR/check-xcode-parity.sh" "$NODE_ID"; then
    data=$(printf '{"node":"%s","reason":"xcode_major_drift","attempt":%s%s}' "$NODE_ID" "${ATTEMPT:-1}" "$DISPATCH_FIELDS")
    emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    exit 2
  fi
fi

LOCK_ROOT="$(resolve_runtime_global)/xcodebuild-lock"
LOCK_BASE="$LOCK_ROOT/$NODE_ID"
LOCK=""
DERIVED=$(resolve_derived_data_for "$TASK_ID")
mkdir -p "$DERIVED" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$DERIVED" >&2; exit 2; }
mkdir -p "$LOCK_BASE" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$LOCK_BASE" >&2; exit 2; }

# Per-node parallel build slots (#218 Stage C / #268). Tests share the
# slot pool with builds — at slots=1 a test and a build still serialize
# on slot-1 (identical to pre-#268 cross-gate behaviour); at slots>1 a
# test pins one slot while builds use the rest. Synthetic `local` is
# always 1.
PARALLEL_SLOTS=1
if [ "$NODE_ID" != "local" ]; then
  REGISTRY="$(resolve_runtime_global)/nodes.json"
  if [ -r "$REGISTRY" ] && command -v jq >/dev/null 2>&1; then
    n=$(jq -r --arg id "$NODE_ID" '.nodes[]? | select(.id == $id) | .parallel_build_slots // 1' "$REGISTRY" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -lt 1 ] && n=1
    PARALLEL_SLOTS=$n
  fi
fi

ATTEMPT=1
GATE_START_S=$(date -u +%s)
gate_announce_start test "$NODE_ID" "$TASK_ID" full-test

start_data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","worktree":"%s","attempt":%s%s}' \
  "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$WORKTREE" "$ATTEMPT" "$DISPATCH_FIELDS")
emit_event_keyed achilles task test_run_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN xcodebuild test node=%s scheme=%s destination=%s test-target=%s -derivedDataPath=%s\n' \
    "$NODE_ID" "$SCHEME" "$DESTINATION" "${TEST_TARGET:-<all>}" "$DERIVED" >&2
  data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","dry_run":true,"attempt":%s%s}' \
    "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$ATTEMPT" "$DISPATCH_FIELDS")
  emit_event_keyed achilles task test_run_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  gate_announce_done test "$NODE_ID" "$TASK_ID" dry-run 0
  exit 0
fi

# #271 — reconnect-and-harvest. Skip lock + dispatch when a prior in-flight
# entry for this {task, node} has already produced a result on the worker.
# The probe is a no-op the first time the gate runs (no prior entry exists).
HARVESTED=0
if [ "$IS_LOCAL" = "0" ]; then
  prior_uuid=$(dispatch_harvest_find_inflight "$TASK_ID" "$NODE_ID" 2>/dev/null) || prior_uuid=""
  if [ -n "$prior_uuid" ]; then
    harvest_log=$(mktemp 2>/dev/null || printf '/tmp/harvest-%s.log' "$$")
    if harvested_rc=$(dispatch_harvest_attempt "$NODE_ID" "$prior_uuid" "$harvest_log" 2>&2); then
      DISPATCH_UUID="$prior_uuid"
      HARVESTED=1
      hdata=$(printf '{"node":"%s","uuid":"%s","exit_code":%s,"mode":"xcodebuild-test","attempt":%s%s}' \
        "$NODE_ID" "$prior_uuid" "$harvested_rc" "$ATTEMPT" "$DISPATCH_FIELDS")
      emit_event_keyed studio dispatch dispatch_harvested "$TASK_ID" "$hdata" >/dev/null 2>&1 || true
      dispatch_registry_mark "$prior_uuid" harvested 2>/dev/null || true
      DISPATCH_UUID=""
      DURATION_S=0
      TEST_COUNT=$(grep -Eo 'Test Suite .* passed|Executed [0-9]+ tests' "$harvest_log" 2>/dev/null \
        | grep -Eo '[0-9]+' | head -1)
      TEST_COUNT="${TEST_COUNT:-0}"
      rm -f "$harvest_log" 2>/dev/null || true
      if [ "$harvested_rc" -eq 0 ]; then
        data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"test_count":%s,"attempt":%s,"harvested":true%s}' \
          "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$TEST_COUNT" "$ATTEMPT" "$DISPATCH_FIELDS")
        emit_event_keyed achilles task test_run_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
        gate_announce_done test "$NODE_ID" "$TASK_ID" passed "$DURATION_S"
        exit 0
      fi
      data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"attempt":%s,"exit_code":%s,"harvested":true%s}' \
        "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$ATTEMPT" "$harvested_rc" "$DISPATCH_FIELDS")
      emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
      gate_announce_done test "$NODE_ID" "$TASK_ID" failed "$DURATION_S"
      exit 2
    else
      rm -f "$harvest_log" 2>/dev/null || true
    fi
  fi
fi

# Acquire one of the N slot locks with 30-min wait cap, 45-min staleness
# reclaim. Same envelope as task-build-gate.sh — keeps build + test
# phases of one task on the same per-node lock pool so they can't
# deadlock on cross-node resources. With slots=1 the inner loop tries
# only `slot-1` so behaviour is identical to the pre-#268 single-dir
# mkdir-lock.
wait_seconds=0
wait_cap=1800
backoff=10
while [ -z "$LOCK" ]; do
  for s in $(seq 1 "$PARALLEL_SLOTS"); do
    candidate="$LOCK_BASE/slot-$s"
    if mkdir "$candidate" 2>/dev/null; then
      LOCK="$candidate"
      printf '%s\n' "$$" > "$LOCK/pid"
      break
    fi
    if [ -n "$(find "$candidate" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
      printf 'warn: stale xcodebuild lock (>45m, slot %s), reclaiming\n' "$s" >&2
      rm -rf "$candidate"
      if mkdir "$candidate" 2>/dev/null; then
        LOCK="$candidate"
        printf '%s\n' "$$" > "$LOCK/pid"
        break
      fi
    fi
  done
  [ -n "$LOCK" ] && break
  if [ "$wait_seconds" -ge "$wait_cap" ]; then
    data=$(printf '{"node":"%s","reason":"locked_out","waited_s":%s,"slots":%s,"attempt":%s%s}' "$NODE_ID" "$wait_seconds" "$PARALLEL_SLOTS" "$ATTEMPT" "$DISPATCH_FIELDS")
    emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    printf 'error: xcodebuild lock wait exceeded %ss (slots=%s)\n' "$wait_cap" "$PARALLEL_SLOTS" >&2
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
    data=$(printf '{"node":"%s","reason":"source_sync_failed","attempt":%s%s}' "$NODE_ID" "$ATTEMPT" "$DISPATCH_FIELDS")
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

  # #270 — opt in to dispatch registry; capture UUID via sidecar so the
  # terminal-status mark below resolves to the right entry.
  UUID_SIDECAR=$(mktemp 2>/dev/null || printf '/tmp/dispatch-uuid-%s' "$$")
  STUDIO_DISPATCH_TASK_ID="$TASK_ID" \
    STUDIO_DISPATCH_UUID_FILE="$UUID_SIDECAR" \
    "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" >"$test_log" 2>&1
  TEST_STATUS=$?
  DISPATCH_UUID=$(tr -d '[:space:]' < "$UUID_SIDECAR" 2>/dev/null)
  rm -f "$UUID_SIDECAR" 2>/dev/null || true
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
  data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"test_count":%s,"attempt":%s%s}' \
    "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$TEST_COUNT" "$ATTEMPT" "$DISPATCH_FIELDS")
  emit_event_keyed achilles task test_run_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  [ -n "$DISPATCH_UUID" ] && dispatch_registry_mark "$DISPATCH_UUID" passed 2>/dev/null || true
  gate_announce_done test "$NODE_ID" "$TASK_ID" passed "$DURATION_S"
  exit 0
fi

data=$(printf '{"node":"%s","scheme":"%s","test_target":"%s","duration_s":%s,"attempt":%s,"exit_code":%s%s}' \
  "$NODE_ID" "$SCHEME" "$TEST_TARGET" "$DURATION_S" "$ATTEMPT" "$TEST_STATUS" "$DISPATCH_FIELDS")
emit_event_keyed achilles task test_run_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
[ -n "$DISPATCH_UUID" ] && dispatch_registry_mark "$DISPATCH_UUID" failed 2>/dev/null || true
gate_announce_done test "$NODE_ID" "$TASK_ID" failed "$DURATION_S"
exit 2
