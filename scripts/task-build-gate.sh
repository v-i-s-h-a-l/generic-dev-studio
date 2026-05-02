#!/usr/bin/env bash
# task-build-gate.sh — Step 6 of the Achilles task mode.
#
# Owns the full build-verification gate. Two modes:
#
#   lsp-only    — per-file swift-lsp diagnostics. No xcodebuild, no lock, no
#                 DerivedData. Red if any .swift file surfaces errors.
#   full-green  — xcodebuild under a per-dispatch-target lock with
#                 45-minute staleness reclaim, per-task DerivedData isolation,
#                 and a trap that releases the lock on any exit. Red if the
#                 build exits non-zero.
#
# The lock lives under `~/.dev-studio/.runtime/xcodebuild-lock/<node-id>/slot-<n>/`
# — machine-global scope (the serialized resource is the SPM cache + Clang
# module cache + simulator locks, all process-wide on the node that runs
# the build) but keyed by dispatch target so a laptop-local build and a
# mini-dispatched build don't serialize on each other. `<node-id>` is
# `local` when no remote is picked, preserving pre-B3 behaviour. This is
# an R4-exempted carve-out documented in file-locations.md.
#
# Slot count comes from the node's `parallel_build_slots` field in
# `~/.dev-studio/.runtime/nodes.json` (default 1; see #218 Stage C / #268).
# With slots=1 the lock path is `slot-1/` and behaviour is identical to
# the pre-#268 single-holder model. With slots>1 the queue grants up to N
# concurrent holders, each pinned to a distinct slot subdir.
#
# Usage:
#   scripts/task-build-gate.sh <mode> <task-id> <worktree> <scheme> <destination> [<project-or-workspace-relpath>]
#     mode: lsp-only | full-green
#     project-or-workspace-relpath: optional, worktree-relative path to a
#       .xcodeproj or .xcworkspace. When set, xcodebuild is pinned with
#       -project / -workspace; auto-detection at the worktree root is
#       fragile in multi-project repos (#238).
#
# Exit codes:
#   0  green
#   2  red (build / LSP errors, missing tools, bad args)
#   3  locked-out (30-minute wait exceeded)
#   4  refused — another build-check for this task is already in flight on
#      this machine. No started/aborted events emitted. See #209.

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
# shellcheck source=lib-build-queue.sh
. "$SCRIPT_DIR/lib-build-queue.sh"
# shellcheck source=lib-remote-failure.sh
. "$SCRIPT_DIR/lib-remote-failure.sh"

# STUDIO_BUILD_PRIORITY — build priority for the per-node queue (#267).
# Values: release | task (default) | background
# TF/AS callers (studio-tf-push.sh) set release; Achilles uses the default task.
BUILD_PRIORITY="${STUDIO_BUILD_PRIORITY:-task}"

MODE="${1:?usage: task-build-gate.sh <lsp-only|full-green> <task-id> <worktree> <scheme> <destination> [<project-or-workspace-relpath>]}"
TASK_ID="${2:?task-id required}"
WORKTREE="${3:?worktree required}"
SCHEME="${4:-}"
DESTINATION="${5:-}"
PROJECT_RELPATH="${6:-}"

case "$MODE" in
  lsp-only|full-green) ;;
  *) printf 'error: mode must be lsp-only or full-green (got %s)\n' "$MODE" >&2; exit 2 ;;
esac

# Validate the project-pin shape early (#238). xcodebuild auto-detection at
# the worktree root picks the first `*.xcodeproj` it finds, which is wrong
# in multi-project repos where the stub at root lacks a pbxproj. Refuse a
# relpath that isn't a project/workspace before any lock or event emit.
case "$PROJECT_RELPATH" in
  ''|*.xcodeproj|*.xcworkspace) ;;
  *)
    printf 'error: project-or-workspace-relpath must end in .xcodeproj or .xcworkspace (got %s)\n' "$PROJECT_RELPATH" >&2
    exit 2
    ;;
esac

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

# Per-task attempt counter. Distinguishes a cold start (1) from a retry
# (2+) so analytics can compute first-try success rate. State lives under
# the project-scoped runtime dir; reset when a terminal event lands. See
# issue #106.
PROJECT=$(resolve_project 2>/dev/null || echo unknown)
PROJECT_ROOT="$(resolve_project_root_for "$PROJECT")"
ATTEMPTS_DIR="$PROJECT_ROOT/.runtime/state/build-check-attempts"
ATTEMPTS_FILE="$ATTEMPTS_DIR/$TASK_ID"
mkdir -p "$ATTEMPTS_DIR" 2>/dev/null || true

# Per-task duplicate-invocation guard (#209). Refuses concurrent invocations
# for the same task before any started event is emitted, so the started/
# passed asymmetry can't be inflated by accidental re-fires (parallel
# Achilles re-entry, hung wrapper retried by hand). Stale lock reclaim at
# 60 min covers PID death; the inner per-node xcodebuild lock continues to
# serialize across tasks, this lock only catches same-task duplicates.
TASK_LOCK_DIR="$PROJECT_ROOT/.runtime/state/build-check-locks"
TASK_LOCK="$TASK_LOCK_DIR/$TASK_ID"
mkdir -p "$TASK_LOCK_DIR" 2>/dev/null || true
if ! mkdir "$TASK_LOCK" 2>/dev/null; then
  if [ -n "$(find "$TASK_LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    rm -rf "$TASK_LOCK"
    mkdir "$TASK_LOCK" 2>/dev/null || { printf 'task-build-gate: cannot acquire task lock: %s\n' "$TASK_LOCK" >&2; exit 4; }
  else
    printf 'task-build-gate: another build-check for %s is in flight; refusing\n' "$TASK_ID" >&2
    exit 4
  fi
fi
printf '%s\n' "$$" > "$TASK_LOCK/pid" 2>/dev/null || true
# Install lock-release immediately so any bail-out between here and the
# full trap below still cleans up. The full trap (set after started-emit)
# composes _emit_aborted_if_open in front; either trap form releases the
# lock as the last action.
_release_task_lock() { rm -rf "$TASK_LOCK" 2>/dev/null || true; }
trap _release_task_lock EXIT INT TERM

ATTEMPT=1
if [ -r "$ATTEMPTS_FILE" ]; then
  prev=$(tr -d '[:space:]' < "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  ATTEMPT=$((prev + 1))
fi
printf '%s\n' "$ATTEMPT" > "$ATTEMPTS_FILE" 2>/dev/null || true

# Pre-flight dispatch decision (issue #137 — every build_check_* event
# carries the studio.dispatch.* tags). LSP doesn't dispatch — empty
# fragment for that mode keeps the start-event shape unchanged. For
# full-green, run node-pick BEFORE the start emit so analytics can join
# fallback rate to first-try success without a separate stream.
NODE_ID=""
DISPATCH_FIELDS=""
if [ "$MODE" = "full-green" ]; then
  REASON_FILE=$(mktemp 2>/dev/null || printf '/tmp/dispatch-reason-%s' "$$")
  : > "$REASON_FILE" 2>/dev/null || true
  NODE_ID=$(STUDIO_DISPATCH_REASON_FILE="$REASON_FILE" \
    "$SCRIPT_DIR/node-pick.sh" xcodebuild 2>/dev/null || echo local)
  DISPATCH_REASON=$(tr -d '\n' < "$REASON_FILE" 2>/dev/null)
  rm -f "$REASON_FILE" 2>/dev/null || true
  [ -z "$DISPATCH_REASON" ] && DISPATCH_REASON="healthy"
  # Best-effort xcode_version pull from the parity cache. Cache miss is
  # routine on cold setups — emit empty rather than block on the lookup.
  XCODE_VER=""
  PARITY_CACHE="$(resolve_runtime_global)/node-parity-cache.json"
  if [ -r "$PARITY_CACHE" ] && command -v jq >/dev/null 2>&1; then
    XCODE_VER=$(jq -r --arg id "$NODE_ID" '.nodes[$id].xcodebuild.version // ""' "$PARITY_CACHE" 2>/dev/null)
  fi
  DISPATCH_FIELDS=$(printf ',"studio.dispatch.node":"%s","studio.dispatch.role":"xcodebuild","studio.dispatch.reason":"%s","studio.dispatch.xcode_version":"%s"' \
    "$NODE_ID" "$DISPATCH_REASON" "$XCODE_VER")
fi

# #270 — populated by the remote-dispatch branch via STUDIO_DISPATCH_UUID_FILE
# sidecar (node-dispatch.sh writes the UUID before its `exec ssh`). Empty for
# lsp-only, dry-run, locked-out, and self-node paths — those never hit
# node-dispatch and have no remote registry entry to mark.
DISPATCH_UUID=""

# Trap-based terminal-span closure. Without this, any exit path between
# build_check_started and the pass/fail emit (cd failures, missing args,
# SIGKILL, stale-lock retry-loop bail-outs) would leave an open span that
# analytics can't distinguish from "still running". See issue #106.
TERMINAL_EMITTED=0
_emit_aborted_if_open() {
  local rc=$?
  [ "$TERMINAL_EMITTED" = "1" ] && return 0
  # rc=0 with no terminal emitted is a logic contradiction (script reached
  # a clean exit without emitting pass/fail). Stamp a reason so analytics
  # can detect the bug-shape and force a non-zero exit_code per #209.
  local reason=""
  if [ "$rc" = "0" ]; then
    reason="clean_exit_no_verdict"
    rc=255
  fi
  local data
  if [ -n "$reason" ]; then
    data=$(printf '{"mode":"%s","attempt":%s,"exit_code":%s,"reason":"%s"%s}' "$MODE" "$ATTEMPT" "$rc" "$reason" "$DISPATCH_FIELDS")
  else
    data=$(printf '{"mode":"%s","attempt":%s,"exit_code":%s%s}' "$MODE" "$ATTEMPT" "$rc" "$DISPATCH_FIELDS")
  fi
  emit_event_keyed achilles task build_check_aborted "$TASK_ID" "$data" >/dev/null 2>&1 || true
  [ -n "$DISPATCH_UUID" ] && dispatch_registry_mark "$DISPATCH_UUID" aborted 2>/dev/null || true
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}

# Emit pass/fail, mark the span closed, and reset the attempt counter so the
# next build-check cycle starts fresh at 1. Callers pass the event name and
# the pre-built data payload.
_emit_terminal() {
  local event="${1:?}"
  local data="${2:?}"
  emit_event_keyed achilles task "$event" "$TASK_ID" "$data" >/dev/null 2>&1 || true
  TERMINAL_EMITTED=1
  if [ -n "$DISPATCH_UUID" ]; then
    case "$event" in
      *_passed)  dispatch_registry_mark "$DISPATCH_UUID" passed  2>/dev/null || true ;;
      *_failed)  dispatch_registry_mark "$DISPATCH_UUID" failed  2>/dev/null || true ;;
      *_aborted) dispatch_registry_mark "$DISPATCH_UUID" aborted 2>/dev/null || true ;;
    esac
  fi
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}

_json_string_from_file_tail() {
  local file="${1:?}" lines="${2:-200}"
  if [ ! -s "$file" ]; then
    printf '""'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    tail -n "$lines" "$file" 2>/dev/null | jq -Rs .
    return 0
  fi
  tail -n "$lines" "$file" 2>/dev/null | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""'
}

_emit_build_harness_failed() {
  local reason="${1:?}" exit_code="${2:?}" log_tail_json="${3:?}"
  local data
  data=$(printf '{"mode":"full-green","node":"%s","scheme":"%s","attempt":%s,"reason":"%s","xcode_exit_code":%s,"log_tail":%s%s}' \
    "$NODE_ID" "$SCHEME" "$ATTEMPT" "$reason" "$exit_code" "$log_tail_json" "$DISPATCH_FIELDS")
  emit_event_keyed achilles task build_harness_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
}

# Announce the attempt so analysis can bucket red gates by mode + retry.
start_data=$(printf '{"mode":"%s","worktree":"%s","attempt":%s%s}' "$MODE" "$WORKTREE" "$ATTEMPT" "$DISPATCH_FIELDS")
emit_event_keyed achilles task build_check_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true
trap '_emit_aborted_if_open; _release_task_lock' EXIT INT TERM

# ---------- lsp-only ----------
#
# Pure read analysis — no lock, no cleanup. The check is the union of errors
# across every changed .swift file between the merge-base and HEAD. Run
# against a file list so warnings don't block (only `error:` lines do).

if [ "$MODE" = "lsp-only" ]; then
  cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }

  # Prefer the repo's declared base when available; fall back to merge-base
  # against origin/main which is the safe default for most iOS repos.
  BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [ -z "$BASE" ] && BASE=main
  MERGE_BASE=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || echo HEAD)

  CHANGED=$(git diff --name-only "$MERGE_BASE" HEAD -- '*.swift' 2>/dev/null)
  if [ -z "$CHANGED" ]; then
    # No swift files changed — LSP has nothing to say; gate is trivially green.
    _emit_terminal build_check_passed '{"mode":"lsp-only","files":0,"attempt":'"$ATTEMPT"'}'
    exit 0
  fi

  # swift-lsp is the project-local diagnostic plugin. When unavailable we
  # degrade to `swift build --build-tests` on SPM repos or surface a
  # skipped-gate signal — xcode-only repos have no alternative here.
  errors=0
  file_count=0
  if command -v swift-lsp >/dev/null 2>&1; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
      file_count=$((file_count + 1))
      if ! swift-lsp diagnose "$f" 2>/dev/null | grep -q '^error:'; then
        continue
      fi
      errors=$((errors + 1))
    done <<EOF
$CHANGED
EOF
  elif command -v swift >/dev/null 2>&1 && [ -f "Package.swift" ]; then
    file_count=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
    swift build --build-tests >/dev/null 2>&1 || errors=1
  else
    # No diagnostic tool available — treat as green but surface the skip so
    # analysis can distinguish "checked and passed" from "had no checker".
    file_count=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
    printf 'warn: no swift-lsp or swift available; skipping lsp-only check\n' >&2
  fi

  if [ "$errors" -gt 0 ]; then
    data=$(printf '{"mode":"lsp-only","files":%s,"errors":%s,"attempt":%s}' "$file_count" "$errors" "$ATTEMPT")
    _emit_terminal build_check_failed "$data"
    exit 2
  fi
  data=$(printf '{"mode":"lsp-only","files":%s,"attempt":%s}' "$file_count" "$ATTEMPT")
  _emit_terminal build_check_passed "$data"
  exit 0
fi

# ---------- full-green ----------
#
# xcodebuild requires a scheme + destination. Bail early rather than run a
# pointless build against defaults.
[ -n "$SCHEME" ] || { printf 'error: scheme required for full-green mode\n' >&2; exit 2; }
[ -n "$DESTINATION" ] || { printf 'error: destination required for full-green mode\n' >&2; exit 2; }

# NODE_ID was resolved during pre-flight (above) so the start event could
# carry studio.dispatch.* tags. The lock is scoped per node: two workers
# dispatching to `mini` still serialize on the mini's cache + simulator
# resources; a laptop-local build runs in parallel with a mini build.
# #215 — when node-pick returns the current machine (either synthetic
# `local` or a registered self-id like `laptop`), run inline. Source-sync
# + SSH would loop back through the network stack, and ssh to self is not
# guaranteed (no sshd at home is the common case).
if node_is_self "$NODE_ID"; then
  IS_LOCAL=1
else
  IS_LOCAL=0
  # Pre-flight Xcode-version drift guard (#136). Major drift blocks dispatch;
  # minor/patch warns and allows. STUDIO_IGNORE_XCODE_DRIFT=1 demotes block
  # to warn. Refresh of the parity cache is cheap (one SSH per node, lazy
  # behind a 7-day TTL) so the guard's worst case is one extra round trip
  # before a real M/L build's lock acquire.
  if ! "$SCRIPT_DIR/check-xcode-parity.sh" "$NODE_ID"; then
    data=$(printf '{"mode":"full-green","node":"%s","reason":"xcode_major_drift","attempt":%s%s}' "$NODE_ID" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    exit 2
  fi
fi

# #271 — reconnect-and-harvest. Before any retry's lock + queue + dispatch,
# probe the registry for an in-flight UUID for this {task_id, node}. If the
# prior run's <uuid>.exit landed on the worker, fetch the log + exit code
# and use them as the gate result instead of re-running. The probe is a
# no-op the first time the gate runs for a task (no prior entry exists),
# so it's safe to gate-unconditionally on the remote branch.
HARVESTED=0
build_log=""
build_json=""
if [ "$IS_LOCAL" = "0" ]; then
  prior_uuid=$(dispatch_harvest_find_inflight "$TASK_ID" "$NODE_ID" 2>/dev/null) || prior_uuid=""
  if [ -n "$prior_uuid" ]; then
    harvest_log=$(mktemp 2>/dev/null || printf '/tmp/harvest-%s.log' "$$")
    if harvested_rc=$(dispatch_harvest_attempt "$NODE_ID" "$prior_uuid" "$harvest_log" 2>&2); then
      DISPATCH_UUID="$prior_uuid"
      BUILD_STATUS="$harvested_rc"
      build_log="$harvest_log"
      HARVESTED=1
      hdata=$(printf '{"node":"%s","uuid":"%s","exit_code":%s,"mode":"full-green","attempt":%s%s}' \
        "$NODE_ID" "$prior_uuid" "$harvested_rc" "$ATTEMPT" "$DISPATCH_FIELDS")
      emit_event_keyed studio dispatch dispatch_harvested "$TASK_ID" "$hdata" >/dev/null 2>&1 || true
      # Park the registry entry as harvested before _emit_terminal runs;
      # then null DISPATCH_UUID so the terminal mark in _emit_terminal
      # doesn't overwrite `harvested` with `passed`/`failed`.
      dispatch_registry_mark "$prior_uuid" harvested 2>/dev/null || true
      DISPATCH_UUID=""
    else
      rm -f "$harvest_log" 2>/dev/null || true
    fi
  fi
fi

# Harvested: skip the lock + queue + dispatch entirely. Mirrors the
# post-build parsing below (errors/warnings count + success-marker check)
# so the harvested terminal payload matches a normal full-green emit, with
# `harvested:true` distinguishing the path. Acceptance: only the original
# dispatch produced a build on the worker; this gate invocation contributes
# zero remote work.
if [ "$HARVESTED" = "1" ]; then
  err_count=$(grep -cE '(^|: )error:' "$build_log" 2>/dev/null)
  case "$err_count" in ''|*[!0-9]*) err_count=0 ;; esac
  warn_count=$(grep -cE '(^|: )warning:' "$build_log" 2>/dev/null)
  case "$warn_count" in ''|*[!0-9]*) warn_count=0 ;; esac
  # Success-marker contract from #265 applies identically — xcodebuild's
  # text path can exit 0 without compiling, and the harvested log is the
  # same text path that lib-source-sync would have rsync'd back.
  success_marker_present=1
  if [ "$BUILD_STATUS" -eq 0 ] && [ -s "$build_log" ]; then
    if ! grep -F '** BUILD SUCCEEDED **' "$build_log" >/dev/null 2>&1; then
      success_marker_present=0
    fi
  fi
  GATE_DUR_S=0
  gate_announce_start build "$NODE_ID" "$TASK_ID" full-green
  if [ "$BUILD_STATUS" -ne 0 ]; then
    log_tail_json="null"
    if [ "$err_count" -eq 0 ]; then
      log_tail_json=$(_json_string_from_file_tail "$build_log" 200)
    fi
    failure_reason="build_invocation_failed"
    if [ "$BUILD_STATUS" -eq 124 ]; then
      failure_reason="remote_timeout"
    fi
    data=$(printf '{"mode":"full-green","node":"%s","errors":%s,"warnings":%s,"scheme":"%s","attempt":%s,"reason":"%s","xcode_exit_code":%s,"log_tail":%s,"harvested":true%s}' \
      "$NODE_ID" "$err_count" "$warn_count" "$SCHEME" "$ATTEMPT" "$failure_reason" "$BUILD_STATUS" "$log_tail_json" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    gate_announce_done build "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
    rm -f "$build_log" 2>/dev/null || true
    exit 2
  fi
  if [ "$success_marker_present" -eq 0 ]; then
    log_tail_json=$(_json_string_from_file_tail "$build_log" 200)
    _emit_build_harness_failed success_marker_absent "$BUILD_STATUS" "$log_tail_json"
    data=$(printf '{"mode":"full-green","node":"%s","errors":%s,"warnings":%s,"scheme":"%s","attempt":%s,"reason":"success_marker_absent","xcode_exit_code":%s,"log_tail":%s,"harvested":true%s}' \
      "$NODE_ID" "$err_count" "$warn_count" "$SCHEME" "$ATTEMPT" "$BUILD_STATUS" "$log_tail_json" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    gate_announce_done build "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
    rm -f "$build_log" 2>/dev/null || true
    exit 2
  fi
  rm -f "$build_log" 2>/dev/null || true
  data=$(printf '{"mode":"full-green","node":"%s","warnings":%s,"scheme":"%s","attempt":%s,"harvested":true%s}' \
    "$NODE_ID" "$warn_count" "$SCHEME" "$ATTEMPT" "$DISPATCH_FIELDS")
  _emit_terminal build_check_passed "$data"
  gate_announce_done build "$NODE_ID" "$TASK_ID" passed "$GATE_DUR_S"
  exit 0
fi

# Surface the dispatch decision to the user — stderr banner + iTerm badge
# + terminal title. See lib-paths.sh #215. The cleared form lands on every
# terminal exit path via the trap.
GATE_START_S=$(date -u +%s)
gate_announce_start build "$NODE_ID" "$TASK_ID" full-green

LOCK_ROOT="$(resolve_runtime_global)/xcodebuild-lock"
LOCK_BASE="$LOCK_ROOT/$NODE_ID"
LOCK=""
DERIVED=$(resolve_derived_data_for "$TASK_ID")
mkdir -p "$DERIVED" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$DERIVED" >&2; exit 2; }
mkdir -p "$LOCK_BASE" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$LOCK_BASE" >&2; exit 2; }

# Per-node parallel build slots (#218 Stage C / #268). Default 1 keeps the
# pre-#268 single-holder model. Synthetic `local` is always 1 — it's the
# not-registered fallback, no nodes.json entry to read.
PARALLEL_SLOTS=$(bq_node_slots "$NODE_ID")

# ---------- queue substrate (#266 / #218 Stage A+B) ----------
#
# Priority-aware queue (#267) feeding the per-node mkdir-lock below.
# lib-build-queue.sh provides bq_enqueue / bq_wait / bq_release.
# Filename format: <rank>-<enqueued_at>-<pid>-<task-id>.json
# rank: 0=release, 1=task (default), 2=background
# Release entries sort ahead of task entries regardless of arrival time.
# 45-min stale-entry GC is handled inside bq_wait.
QUEUE_DIR="$(resolve_runtime_global)/build-queue/$NODE_ID"
QUEUE_ENTRY=$(bq_enqueue "$QUEUE_DIR" "$TASK_ID" "$BUILD_PRIORITY" xcodebuild none) \
  || { printf 'error: bq_enqueue failed\n' >&2; exit 2; }

_release_queue_entry() { bq_release "$QUEUE_ENTRY"; }

QUEUE_DEPTH=$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
case "$QUEUE_DEPTH" in ''|*[!0-9]*) QUEUE_DEPTH=1 ;; esac
[ "$QUEUE_DEPTH" -lt 1 ] && QUEUE_DEPTH=1
QUEUE_POSITION=$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
  | sort | awk -v me="$QUEUE_ENTRY" '{ if ($0 == me) { print NR; exit } }')
case "$QUEUE_POSITION" in ''|*[!0-9]*) QUEUE_POSITION="$QUEUE_DEPTH" ;; esac

queue_data=$(printf '{"mode":"%s","node":"%s","position":%s,"depth":%s,"slots":%s,"attempt":%s,"priority":"%s"%s}' \
  "$MODE" "$NODE_ID" "$QUEUE_POSITION" "$QUEUE_DEPTH" "$PARALLEL_SLOTS" "$ATTEMPT" "$BUILD_PRIORITY" "$DISPATCH_FIELDS")
emit_event_keyed achilles task build_queue_position "$TASK_ID" "$queue_data" >/dev/null 2>&1 || true

# Compose: aborted-if-open → queue release → task lock release. The
# inner-lock release is layered on once that lock is acquired below.
trap '_emit_aborted_if_open; _release_queue_entry; _release_task_lock' EXIT INT TERM

# Wait until our entry is in the first PARALLEL_SLOTS positions. Re-GC
# each iteration so an orphaned entry ahead of us doesn't strand the
# wait. 30-min envelope matches the inner mkdir-lock's wait cap; combined
# ceiling is 60 min, but that requires both layers saturated — a
# substrate anomaly worth surfacing as a failed gate via reason:
# queue_locked_out. With slots=1 the head set is just {head}, so behaviour
# is identical to the pre-#268 strict-head wait.
bq_wait "$QUEUE_DIR" "$QUEUE_ENTRY" "$PARALLEL_SLOTS" 1800 "$TASK_ID" "$NODE_ID" || {
  gate_announce_done build "$NODE_ID" "$TASK_ID" locked-out 1800
  exit 3
}

# DRY-RUN — log the invocation, skip the lock + xcodebuild. Idempotency
# key matches the wet-run's path so diff-comparison works
# (patterns/dry-run.md). The queue substrate above ran for real (enqueue
# + head-wait + dequeue via trap), so DRY_RUN faithfully exercises FIFO
# ordering — used by the #266 acceptance harness.
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN xcodebuild node=%s scheme=%s destination=%s -derivedDataPath=%s\n' \
    "$NODE_ID" "$SCHEME" "$DESTINATION" "$DERIVED" >&2
  _emit_terminal build_check_passed \
    "$(printf '{"mode":"full-green","node":"%s","dry_run":true,"scheme":"%s","attempt":%s%s}' "$NODE_ID" "$SCHEME" "$ATTEMPT" "$DISPATCH_FIELDS")"
  gate_announce_done build "$NODE_ID" "$TASK_ID" dry-run 0
  exit 0
fi

# Acquire one of the N slot locks with bounded wait. 45-min staleness
# threshold reclaims a slot whose holder died without cleanup (e.g.
# SIGKILL from the runner). Wait envelope: 30 min total (180 × 10s).
# Backoff kept linear — contention is rare and 10s granularity is fine.
# With N=1 the inner loop tries only `slot-1` so behaviour is identical
# to the pre-#268 single-dir mkdir-lock.
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
    printf 'error: xcodebuild lock wait exceeded %ss (slots=%s)\n' "$wait_cap" "$PARALLEL_SLOTS" >&2
    data=$(printf '{"mode":"full-green","reason":"locked_out","waited_s":%s,"slots":%s,"attempt":%s%s}' "$wait_seconds" "$PARALLEL_SLOTS" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    gate_announce_done build "$NODE_ID" "$TASK_ID" locked-out "$wait_seconds"
    exit 3
  fi
  sleep "$backoff"
  wait_seconds=$((wait_seconds + backoff))
done

# Trap registered inside the script — the caller invokes synchronously so
# EXIT fires once this script returns. Internal handler is sufficient.
# Composite: first emit an aborted event iff no terminal was sent, THEN
# release the lock — preserves the span-close invariant for the full-green
# branch even when the earlier outer trap got overridden by this one. Also
# clears the iTerm badge + terminal title so a SIGKILL or unexpected exit
# doesn't leave a stale "→ m1mini" overlay pinned in the user's pane.
trap '_emit_aborted_if_open; rm -rf "$LOCK" 2>/dev/null; _release_queue_entry; _release_task_lock; _gate_set_title ""; _gate_set_badge ""' EXIT INT TERM

# Local branch still needs to cd before invoking xcodebuild. Remote branch
# delegates the cd to the remote shell below — the dispatch still happens
# from whatever cwd the caller had.
if [ "$IS_LOCAL" = "1" ]; then
  cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }
fi

# Run the build. Output is captured for downstream analysis (error-line count
# in the data payload) but not stored — we trust the build tool's exit status.
# Both local and remote branches route through xcodebuild-shim.sh which
# selects between xcodebuild and xcodebuildmcp per STUDIO_XCODEBUILDMCP.
# When xcodebuildmcp is in use, $XCB_JSON_SIDECAR receives a structured
# JSON view the build_check_failed event picks up below. The remote branch
# (#178) runs the shim on the worker and pulls the sidecar back.
build_log=$(mktemp 2>/dev/null || printf '/tmp/xcb-%s.log' "$$")
build_json="${build_log}.json"
remote_derived_abs=""
retrieved_artifacts_file=""
export XCB_JSON_SIDECAR="$build_json"

# Compose xcodebuild argv via `set --` so the optional -project / -workspace
# flag (#238) folds in cleanly without conditional duplication of the whole
# command. The flag must appear before -scheme; xcodebuild errors otherwise
# on workspace-vs-project mismatch.
set -- build
case "$PROJECT_RELPATH" in
  *.xcworkspace) set -- "$@" -workspace "$PROJECT_RELPATH" ;;
  *.xcodeproj)   set -- "$@" -project   "$PROJECT_RELPATH" ;;
esac
set -- "$@" -scheme "$SCHEME" -destination "$DESTINATION" -derivedDataPath "$DERIVED"

if [ "$IS_LOCAL" = "1" ]; then
  "$SCRIPT_DIR/xcodebuild-shim.sh" "$@" >"$build_log" 2>&1
  BUILD_STATUS=$?
else
  # Remote dispatch (#127, #178). Source sync, path translation, shim
  # routing, and sidecar pull-back for structured error enrichment.
  # shellcheck source=lib-source-sync.sh
  . "$SCRIPT_DIR/lib-source-sync.sh"
  sourcesync_start_warmup_once "$NODE_ID" "$PROJECT" "$WORKTREE" "$SCHEME" "$DESTINATION" "$PROJECT_RELPATH"
  REL_WORKTREE=$(sourcesync_push "$NODE_ID" "$WORKTREE") || {
    printf 'task-build-gate: source sync to %s failed\n' "$NODE_ID" >&2
    data=$(printf '{"mode":"full-green","node":"%s","reason":"source_sync_failed","scheme":"%s","attempt":%s%s}' \
      "$NODE_ID" "$SCHEME" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    exit 2
  }
  REL_DERIVED=$(sourcesync_relative_to_home "$DERIVED") || {
    printf 'task-build-gate: DerivedData path %s is outside $HOME — refusing remote dispatch\n' "$DERIVED" >&2
    exit 2
  }
  remote_derived_abs=$(sourcesync_remote_abs "$NODE_ID" "$REL_DERIVED" 2>/dev/null || printf '')
  sourcesync_mkdir_remote "$NODE_ID" "$REL_DERIVED" || {
    printf 'task-build-gate: failed to mkdir DerivedData on %s\n' "$NODE_ID" >&2
    data=$(printf '{"mode":"full-green","node":"%s","reason":"remote_shell_path_failed","scheme":"%s","attempt":%s%s}' \
      "$NODE_ID" "$SCHEME" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    exit 2
  }
  Q_WORKTREE=$(sourcesync_remote_quoted "$REL_WORKTREE")
  Q_DERIVED=$(sourcesync_remote_quoted "$REL_DERIVED")

  REMOTE_SIDECAR_REL=".dev-studio/.runtime/sidecar/xcb-${TASK_ID}.json"

  # Propagate STUDIO_XCODEBUILDMCP so the worker's shim honours the
  # manager's routing preference (=0 skips the shim on both sides).
  Q_MCP_MODE=$(printf '%q' "${STUDIO_XCODEBUILDMCP:-auto}")

  # Build remote command. Guards:
  #   a) brew shellenv — non-interactive SSH lacks /opt/homebrew/bin in
  #      PATH; without it, xcodebuildmcp (brew-installed) is invisible.
  #   b) shim existence — falls back to xcodebuild if sync-worker.sh
  #      hasn't mirrored the shim yet (preserves pre-#178 behaviour).
  #   c) sidecar dir — mkdir so the shim can write the JSON sidecar.
  REMOTE_CMD='[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)";'
  REMOTE_CMD+=' [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)";'
  REMOTE_CMD+=' _SHIM="$HOME/.dev-studio/.runtime/bin/xcodebuild-shim.sh";'
  REMOTE_CMD+=' [ -x "$_SHIM" ] || _SHIM=xcodebuild;'
  REMOTE_CMD+=' export STUDIO_XCODEBUILDMCP='"$Q_MCP_MODE"';'
  REMOTE_CMD+=' mkdir -p "$HOME/.dev-studio/.runtime/sidecar" 2>/dev/null;'
  REMOTE_CMD+=' export XCB_JSON_SIDECAR="$HOME/'"$REMOTE_SIDECAR_REL"'";'
  REMOTE_CMD+=' cd '"$Q_WORKTREE"' && "$_SHIM" build'
  case "$PROJECT_RELPATH" in
    *.xcworkspace) REMOTE_CMD+=' -workspace '"$(printf '%q' "$PROJECT_RELPATH")" ;;
    *.xcodeproj)   REMOTE_CMD+=' -project '"$(printf '%q' "$PROJECT_RELPATH")" ;;
  esac
  REMOTE_CMD+=' -scheme '"$(printf '%q' "$SCHEME")"' -destination '"$(printf '%q' "$DESTINATION")"' -derivedDataPath '"$Q_DERIVED"
  # #270 — opt in to the laptop-side dispatch registry. node-dispatch.sh
  # writes the in-flight entry once the UUID is generated and stamps it
  # into the sidecar; we capture it after dispatch returns so _emit_terminal
  # / _emit_aborted_if_open can mark the terminal status.
  UUID_SIDECAR=$(mktemp 2>/dev/null || printf '/tmp/dispatch-uuid-%s' "$$")
  STUDIO_DISPATCH_TASK_ID="$TASK_ID" \
    STUDIO_DISPATCH_UUID_FILE="$UUID_SIDECAR" \
    "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" \
      >"$build_log" 2>&1
  BUILD_STATUS=$?
  DISPATCH_UUID=$(tr -d '[:space:]' < "$UUID_SIDECAR" 2>/dev/null)
  rm -f "$UUID_SIDECAR" 2>/dev/null || true

  # Sidecar pull-back: structured JSON from the worker's shim → local
  # build_json for error enrichment below. Non-fatal — when the shim
  # fell back to xcodebuild (or xcodebuildmcp isn't installed), no
  # sidecar exists and the pull fails silently.
  sourcesync_pull_file "$NODE_ID" "$REMOTE_SIDECAR_REL" "$build_json" 2>/dev/null || true

  # AXe evidence pull-back (#178). If tests ran on the worker, snapshots
  # live at this path. Pull to the matching local path so evidence is
  # reachable regardless of which machine produced it. No-op when the
  # directory doesn't exist (the common case for build-only dispatch).
  REMOTE_EVIDENCE_REL=".dev-studio/$PROJECT/.runtime/ui-evidence/$TASK_ID"
  LOCAL_EVIDENCE="$HOME/$REMOTE_EVIDENCE_REL"
  sourcesync_pull_dir "$NODE_ID" "$REMOTE_EVIDENCE_REL" "$LOCAL_EVIDENCE" 2>/dev/null || true

  if [ "$BUILD_STATUS" -eq 0 ] && [ "${NODE_ARTIFACT_RETRIEVE:-0}" = "1" ]; then
    retrieved_artifacts_file=$(mktemp 2>/dev/null || printf '/tmp/node-artifacts-%s' "$$")
    sourcesync_pull_xcode_artifacts "$NODE_ID" "$REL_DERIVED" "$DERIVED" >"$retrieved_artifacts_file" 2>/dev/null || true
  fi
fi

# Parse error + warning counts. Cheap and well-defined — xcodebuild's error
# lines match `error:` case-insensitively and begin at column 0 or after a path.
# #237 — `grep -c` exits 1 on zero matches. The legacy `|| echo 0` form
# concatenated grep's "0" with the fallback "0" through a newline,
# corrupting the JSONL event payload below. The case-statement sanitises
# empty + non-numeric to 0 without firing on the zero-matches path.
err_count=$(grep -cE '(^|: )error:' "$build_log" 2>/dev/null)
case "$err_count" in ''|*[!0-9]*) err_count=0 ;; esac
warn_count=$(grep -cE '(^|: )warning:' "$build_log" 2>/dev/null)
case "$warn_count" in ''|*[!0-9]*) warn_count=0 ;; esac

# When the shim wrote a JSON sidecar (xcodebuildmcp executor), capture up to
# the first 5 error objects for the build_check_failed payload. Bounded to
# keep the event-log shard small. Failures here are non-fatal — the legacy
# count-based payload is still emitted.
errors_json="null"
if [ -s "$build_json" ] && command -v jq >/dev/null 2>&1; then
  errors_json=$(jq -c '
    [(.errors // [])[:5] | .[] | {
      file: (.file // .path // null),
      line: (.line // null),
      message: (.message // (. | tostring))
    }]
  ' "$build_json" 2>/dev/null || printf 'null')
fi

# #265 — success-marker verification on the xcodebuild text path.
# xcodebuild can exit 0 without compiling (unresolvable destination is the
# observed case; future misbehaviors may have different shapes). The
# `** BUILD SUCCEEDED **` line is xcodebuild's own success contract — its
# absence on an exit-0 run is the silent-success signature. The check is
# gated to the xcodebuild executor: when the JSON sidecar is present and
# parsed, errors_json is authoritative and the text projection in stdout
# does not include the marker.
success_marker_present=1
if [ "$errors_json" = "null" ] && [ -s "$build_log" ]; then
  if ! grep -F '** BUILD SUCCEEDED **' "$build_log" >/dev/null 2>&1; then
    success_marker_present=0
  fi
fi

GATE_DUR_S=$(( $(date -u +%s) - GATE_START_S ))
[ "$GATE_DUR_S" -lt 0 ] && GATE_DUR_S=0

if [ "$BUILD_STATUS" -ne 0 ]; then
  failure_reason="build_invocation_failed"
  if [ "$IS_LOCAL" != "1" ]; then
    if [ "$BUILD_STATUS" -eq 124 ]; then
      failure_reason="remote_timeout"
    else
      failure_reason=$(remote_failure_reason "$build_log")
    fi
  fi
  log_tail_json="null"
  if [ "$err_count" -eq 0 ]; then
    log_tail_json=$(_json_string_from_file_tail "$build_log" 200)
  fi
  data=$(printf '{"mode":"full-green","node":"%s","errors":%s,"warnings":%s,"scheme":"%s","attempt":%s,"xcode_exit_code":%s,"log_tail":%s,"errors_json":%s%s}' \
    "$NODE_ID" "$err_count" "$warn_count" "$SCHEME" "$ATTEMPT" "$BUILD_STATUS" "$log_tail_json" "$errors_json" "$DISPATCH_FIELDS")
  data=$(printf '%s' "$data" | jq -c --arg reason "$failure_reason" '. + {reason:$reason}')
  if [ "$failure_reason" = "remote_marker_writer_failed" ]; then
    data=$(remote_enrich_marker_failure "$data" "$build_log")
  fi
  _emit_terminal build_check_failed "$data"
  gate_announce_done build "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
  rm -f "$build_log" "$build_json" 2>/dev/null || true
  exit 2
fi

if [ "$success_marker_present" -eq 0 ]; then
  log_tail_json=$(_json_string_from_file_tail "$build_log" 200)
  _emit_build_harness_failed success_marker_absent "$BUILD_STATUS" "$log_tail_json"
  data=$(printf '{"mode":"full-green","node":"%s","errors":%s,"warnings":%s,"scheme":"%s","attempt":%s,"reason":"success_marker_absent","xcode_exit_code":%s,"log_tail":%s,"errors_json":%s%s}' \
    "$NODE_ID" "$err_count" "$warn_count" "$SCHEME" "$ATTEMPT" "$BUILD_STATUS" "$log_tail_json" "$errors_json" "$DISPATCH_FIELDS")
  _emit_terminal build_check_failed "$data"
  gate_announce_done build "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
  rm -f "$build_log" "$build_json" 2>/dev/null || true
  exit 2
fi

rm -f "$build_log" "$build_json" 2>/dev/null || true

data=$(printf '{"mode":"full-green","node":"%s","warnings":%s,"scheme":"%s","attempt":%s%s}' "$NODE_ID" "$warn_count" "$SCHEME" "$ATTEMPT" "$DISPATCH_FIELDS")
if [ -n "$remote_derived_abs" ] && command -v jq >/dev/null 2>&1; then
  data=$(printf '%s' "$data" | jq -c --arg path "$remote_derived_abs" '. + {remote_derived_data_path:$path}')
fi
if [ -n "$retrieved_artifacts_file" ] && command -v jq >/dev/null 2>&1; then
  artifacts_json=$(jq -Rsc 'split("\n")[:-1]' "$retrieved_artifacts_file" 2>/dev/null || printf '[]')
  data=$(printf '%s' "$data" | jq -c --argjson artifacts "$artifacts_json" '. + {retrieved_artifacts:$artifacts}')
fi
rm -f "$build_log" "$build_json" "$retrieved_artifacts_file" 2>/dev/null || true
_emit_terminal build_check_passed "$data"
gate_announce_done build "$NODE_ID" "$TASK_ID" passed "$GATE_DUR_S"
exit 0
