#!/usr/bin/env bash
# swift-test-gate.sh — package-only fast path for Step 6 of the Achilles
# task mode (#110).
#
# Triggers when every changed file in the worktree lives under one SPM
# package directory (resolved by walking each path up to its nearest
# Package.swift). For that shape, `swift test --package-path <pkg>` is
# orders of magnitude faster than `xcodebuild test`: no simulator boot,
# no DerivedData warmup, no shared xcodebuild.lock contention. Parallel
# Achilles workers stop queueing on the build lock for tasks that never
# needed Xcode in the first place.
#
# The script does NOT acquire the xcodebuild lock — `swift test` doesn't
# touch the serialized resources (simulator, Xcode workspace caches) so
# the lock would only invent contention. Per-worktree paths keep SPM's
# .build dir disjoint between workers.
#
# Usage:
#   scripts/swift-test-gate.sh <task-id> <worktree> [<changed-files>]
#
#   <changed-files> — newline-separated paths relative to the worktree.
#                     Optional; if omitted, computed from the merge-base
#                     against origin/HEAD (matches task-build-gate.sh).
#
# Exit codes:
#   0  green       — package detected, swift test passed
#   1  skipped     — diff is not package-only (caller must escalate to
#                    task-build-gate.sh). NO events emitted on this path.
#   2  red         — swift test failed, or swift unavailable, or bad args
#   4  refused     — another build-check for this task is already in flight
#                    on this machine. No started/aborted events emitted. #209.
#
# Step 6 routing contract: a 0 means the gate is green and merge can
# proceed; a 1 means "I don't apply, run the size-driven gate"; a 2 is
# a hard red same as task-build-gate.sh.

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
# shellcheck source=lib-remote-failure.sh
. "$SCRIPT_DIR/lib-remote-failure.sh"

TASK_ID="${1:?usage: swift-test-gate.sh <task-id> <worktree> [<changed-files>]}"
WORKTREE="${2:?worktree required}"
CHANGED_INPUT="${3:-}"

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }

# Resolve the changed-files set. When the caller didn't pass one, mirror
# task-build-gate.sh's lsp-only computation so both gates see the same
# diff slice.
if [ -z "$CHANGED_INPUT" ]; then
  BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [ -z "$BASE" ] && BASE=main
  MERGE_BASE=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || echo HEAD)
  CHANGED_INPUT=$(git diff --name-only "$MERGE_BASE" HEAD 2>/dev/null)
fi

# Filter blanks. An empty diff means there is nothing to gate at all —
# escalate so the size-driven gate's existing "no swift files" green
# path runs (or whatever full-green decides for direct mode).
CHANGED=$(printf '%s\n' "$CHANGED_INPUT" | sed '/^$/d')
if [ -z "$CHANGED" ]; then
  exit 1
fi

# Walk each changed path up to its nearest Package.swift. If any path
# has no enclosing package, or two paths land in different packages,
# the diff is not package-only — escalate. The fast path requires a
# single, shared package root.
PKG_ROOT=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  d=$(dirname "$f")
  found=""
  # Bound the walk at 64 levels — paranoia, never hit in practice.
  for _ in $(seq 1 64); do
    if [ -f "$d/Package.swift" ]; then
      found="$d"
      break
    fi
    case "$d" in
      .|/) break ;;
    esac
    parent=$(dirname "$d")
    [ "$parent" = "$d" ] && break
    d="$parent"
  done
  if [ -z "$found" ]; then
    exit 1
  fi
  if [ -z "$PKG_ROOT" ]; then
    PKG_ROOT="$found"
  elif [ "$PKG_ROOT" != "$found" ]; then
    exit 1
  fi
done <<EOF
$CHANGED
EOF

[ -n "$PKG_ROOT" ] || exit 1

# Per-task attempt counter — same contract + storage layout as
# task-build-gate.sh so analytics can join across both gate flavors.
PROJECT=$(resolve_project 2>/dev/null || echo unknown)
PROJECT_ROOT="$(resolve_project_root_for "$PROJECT")"
ATTEMPTS_DIR="$PROJECT_ROOT/.runtime/state/build-check-attempts"
ATTEMPTS_FILE="$ATTEMPTS_DIR/$TASK_ID"
mkdir -p "$ATTEMPTS_DIR" 2>/dev/null || true

# Per-task duplicate-invocation guard (#209). Same contract as
# task-build-gate.sh. Refuses concurrent invocations on the same task
# before emitting started, eliminating duplicate started events as a
# source of the started/passed asymmetry.
TASK_LOCK_DIR="$PROJECT_ROOT/.runtime/state/build-check-locks"
TASK_LOCK="$TASK_LOCK_DIR/$TASK_ID"
mkdir -p "$TASK_LOCK_DIR" 2>/dev/null || true
if ! mkdir "$TASK_LOCK" 2>/dev/null; then
  if [ -n "$(find "$TASK_LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    rm -rf "$TASK_LOCK"
    mkdir "$TASK_LOCK" 2>/dev/null || { printf 'swift-test-gate: cannot acquire task lock: %s\n' "$TASK_LOCK" >&2; exit 4; }
  else
    printf 'swift-test-gate: another build-check for %s is in flight; refusing\n' "$TASK_ID" >&2
    exit 4
  fi
fi
printf '%s\n' "$$" > "$TASK_LOCK/pid" 2>/dev/null || true
# See task-build-gate.sh — installs lock-release before the full trap
# replaces it, so a bail-out before started-emit still clears the lock.
_release_task_lock() { rm -rf "$TASK_LOCK" 2>/dev/null || true; }
trap _release_task_lock EXIT INT TERM

ATTEMPT=1
if [ -r "$ATTEMPTS_FILE" ]; then
  prev=$(tr -d '[:space:]' < "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  ATTEMPT=$((prev + 1))
fi
printf '%s\n' "$ATTEMPT" > "$ATTEMPTS_FILE" 2>/dev/null || true

# Pre-flight dispatch decision (#137) — picked up here so the start
# event carries studio.dispatch.* tags. swift-test never uses xcodebuild,
# so xcode_version is best-effort from the parity cache (typically empty
# for pure-SPM nodes).
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

# #270 — populated by the remote-dispatch branch. Empty for self-node
# (no remote registry entry exists to mark).
DISPATCH_UUID=""

# Trap-based span closure. Without it, any exit between started and
# pass/fail (signal, swift-not-found, surprise non-zero) leaks an open
# build_check_started that analytics can't tell apart from "in flight".
TERMINAL_EMITTED=0
_emit_aborted_if_open() {
  local rc=$?
  [ "$TERMINAL_EMITTED" = "1" ] && return 0
  # rc=0 with no terminal emitted is a logic contradiction — see #209.
  local reason=""
  if [ "$rc" = "0" ]; then
    reason="clean_exit_no_verdict"
    rc=255
  fi
  local data
  if [ -n "$reason" ]; then
    data=$(printf '{"mode":"swift-test","attempt":%s,"exit_code":%s,"reason":"%s"%s}' "$ATTEMPT" "$rc" "$reason" "$DISPATCH_FIELDS")
  else
    data=$(printf '{"mode":"swift-test","attempt":%s,"exit_code":%s%s}' "$ATTEMPT" "$rc" "$DISPATCH_FIELDS")
  fi
  emit_event_keyed achilles task build_check_aborted "$TASK_ID" "$data" >/dev/null 2>&1 || true
  [ -n "$DISPATCH_UUID" ] && dispatch_registry_mark "$DISPATCH_UUID" aborted 2>/dev/null || true
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}
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

_swift_test_failure_reason() {
  local log="${1:?}"
  if grep -Eiq \
    "invalid manifest|package manifest|manifest parse|error:.*Package\.swift|could not find Package\.swift|the package at .* cannot be accessed|package .* is required using a stable-version|unknown package|unknown package dependency|unknown target|target .* has overlapping sources|source files for target .* should be located under|invalid custom path|resource .* not found|doesn't contain a package manifest" \
    "$log" 2>/dev/null; then
    printf 'focused_verification_structurally_blocked\n'
    return 0
  fi
  printf 'build_invocation_failed\n'
}

file_count=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
start_data=$(printf '{"mode":"swift-test","worktree":"%s","package":"%s","files":%s,"attempt":%s%s}' \
  "$WORKTREE" "$PKG_ROOT" "$file_count" "$ATTEMPT" "$DISPATCH_FIELDS")
emit_event_keyed achilles task build_check_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true
trap '_emit_aborted_if_open; _release_task_lock; _gate_set_title ""; _gate_set_badge ""' EXIT INT TERM

# DRY-RUN — log the invocation, skip the real test run. Idempotency-key
# parity with task-build-gate.sh so wet/dry-run output diffs cleanly.
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN swift test --package-path=%s\n' "$PKG_ROOT" >&2
  _emit_terminal build_check_passed \
    "$(printf '{"mode":"swift-test","dry_run":true,"package":"%s","attempt":%s%s}' "$PKG_ROOT" "$ATTEMPT" "$DISPATCH_FIELDS")"
  exit 0
fi

# NODE_ID was resolved during pre-flight (above) so the start event could
# carry studio.dispatch.* tags. `node-pick` returns `local` when no remote
# is registered or healthy, which keeps hosts without a node registry
# running bit-for-bit the old behaviour.
GATE_START_S=$(date -u +%s)
gate_announce_start swift-test "$NODE_ID" "$TASK_ID" swift-test

if node_is_self "$NODE_ID"; then
  # Local swift is only required on the local branch — if we're dispatching
  # to a remote node, the remote's toolchain is what matters and its
  # absence surfaces as a non-zero remote exit code below.
  if ! command -v swift >/dev/null 2>&1; then
    data=$(printf '{"mode":"swift-test","reason":"swift_unavailable","package":"%s","attempt":%s%s}' "$PKG_ROOT" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    gate_announce_done swift-test "$NODE_ID" "$TASK_ID" failed 0
    exit 2
  fi
fi

# #271 — reconnect-and-harvest. Probe the dispatch registry for an in-flight
# UUID for {task_id, node} on the remote branch. If the prior run's
# <uuid>.exit landed on the worker, fetch + use it instead of running again.
# No-op the first time the gate runs for a task (no prior entry exists).
HARVESTED=0
if ! node_is_self "$NODE_ID"; then
  prior_uuid=$(dispatch_harvest_find_inflight "$TASK_ID" "$NODE_ID" 2>/dev/null) || prior_uuid=""
  if [ -n "$prior_uuid" ]; then
    harvest_log=$(mktemp 2>/dev/null || printf '/tmp/harvest-%s.log' "$$")
    if harvested_rc=$(dispatch_harvest_attempt "$NODE_ID" "$prior_uuid" "$harvest_log" 2>&2); then
      DISPATCH_UUID="$prior_uuid"
      TEST_STATUS="$harvested_rc"
      test_log="$harvest_log"
      HARVESTED=1
      hdata=$(printf '{"node":"%s","uuid":"%s","exit_code":%s,"mode":"swift-test","attempt":%s%s}' \
        "$NODE_ID" "$prior_uuid" "$harvested_rc" "$ATTEMPT" "$DISPATCH_FIELDS")
      emit_event_keyed studio dispatch dispatch_harvested "$TASK_ID" "$hdata" >/dev/null 2>&1 || true
      dispatch_registry_mark "$prior_uuid" harvested 2>/dev/null || true
      DISPATCH_UUID=""
    else
      rm -f "$harvest_log" 2>/dev/null || true
    fi
  fi
fi

if [ "$HARVESTED" = "1" ]; then
  err_count=$(grep -cE '(^|: )error:' "$test_log" 2>/dev/null)
  case "$err_count" in ''|*[!0-9]*) err_count=0 ;; esac
  warn_count=$(grep -cE '(^|: )warning:' "$test_log" 2>/dev/null)
  case "$warn_count" in ''|*[!0-9]*) warn_count=0 ;; esac
  GATE_DUR_S=$(( $(date -u +%s) - GATE_START_S ))
  [ "$GATE_DUR_S" -lt 0 ] && GATE_DUR_S=0
  if [ "$TEST_STATUS" -ne 0 ]; then
    if [ "$TEST_STATUS" -eq 124 ]; then
      failure_reason="remote_timeout"
    else
      failure_reason=$(remote_failure_reason "$test_log")
      if [ "$failure_reason" = "remote_command_failed" ] || [ "$failure_reason" = "remote_harness_failure" ] || [ "$failure_reason" = "build_invocation_failed" ]; then
        failure_reason=$(_swift_test_failure_reason "$test_log")
      fi
    fi
    data=$(printf '{"mode":"swift-test","node":"%s","errors":%s,"warnings":%s,"package":"%s","attempt":%s,"harvested":true%s}' \
      "$NODE_ID" "$err_count" "$warn_count" "$PKG_ROOT" "$ATTEMPT" "$DISPATCH_FIELDS")
    data=$(printf '%s' "$data" | jq -c --arg reason "$failure_reason" '. + {reason:$reason}')
    if [ "$failure_reason" = "focused_verification_structurally_blocked" ]; then
      data=$(printf '%s' "$data" | jq -c '. + {verification_blocked:true, verdict_note:"focused verification structurally blocked"}')
    fi
    if [ "$failure_reason" = "remote_marker_writer_failed" ]; then
      data=$(remote_enrich_marker_failure "$data" "$test_log")
    fi
    rm -f "$test_log" 2>/dev/null || true
    _emit_terminal build_check_failed "$data"
    gate_announce_done swift-test "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
    exit 2
  fi
  rm -f "$test_log" 2>/dev/null || true
  data=$(printf '{"mode":"swift-test","node":"%s","warnings":%s,"package":"%s","files":%s,"attempt":%s,"harvested":true%s}' \
    "$NODE_ID" "$warn_count" "$PKG_ROOT" "$file_count" "$ATTEMPT" "$DISPATCH_FIELDS")
  _emit_terminal build_check_passed "$data"
  gate_announce_done swift-test "$NODE_ID" "$TASK_ID" passed "$GATE_DUR_S"
  exit 0
fi

test_log=$(mktemp 2>/dev/null || printf '/tmp/swift-test-%s.log' "$$")

if node_is_self "$NODE_ID"; then
  swift test --package-path "$PKG_ROOT" >"$test_log" 2>&1
  TEST_STATUS=$?
else
  # Remote dispatch (#127). Mirror $WORKTREE under remote $HOME via rsync,
  # then cd to the home-relative form. Laptop's $HOME and remote's $HOME
  # may differ (e.g. /Users/vishalsingh vs /Users/vishal); home-relative
  # mirroring is the stable anchor. PKG_ROOT is translated to its
  # home-relative form too — when it lives under $WORKTREE (the common
  # case), the rsync'd tree already contains it; otherwise we sync it
  # explicitly so `--package-path` resolves on the remote.
  # shellcheck source=lib-source-sync.sh
  . "$SCRIPT_DIR/lib-source-sync.sh"
  sourcesync_start_warmup_once "$NODE_ID" "$PROJECT" "$WORKTREE" "" "" ""
  REL_WORKTREE=$(sourcesync_push "$NODE_ID" "$WORKTREE") || {
    printf 'swift-test-gate: source sync to %s failed\n' "$NODE_ID" >&2
    data=$(printf '{"mode":"swift-test","reason":"source_sync_failed","node":"%s","attempt":%s%s}' "$NODE_ID" "$ATTEMPT" "$DISPATCH_FIELDS")
    _emit_terminal build_check_failed "$data"
    exit 2
  }
  # PKG_ROOT may be:
  #   (a) a worktree-relative path (e.g. "." or "Packages/Foo") — the script
  #       cd'd into $WORKTREE before walking, so the walk's `dirname` chain
  #       produced relative paths. After remote `cd $Q_WORKTREE`, the same
  #       relative path resolves correctly on the worker.
  #   (b) an absolute path under $WORKTREE — translate to worktree-relative.
  #   (c) an absolute path outside $WORKTREE — rare; sync separately and use
  #       the home-mirrored path on the remote.
  Q_WORKTREE=$(sourcesync_remote_quoted "$REL_WORKTREE")
  case "$PKG_ROOT" in
    /*)
      case "$PKG_ROOT" in
        "$WORKTREE"|"$WORKTREE"/*)
          # case (b): make it worktree-relative so the post-cd swift test
          # call resolves it under the synced tree.
          if [ "$PKG_ROOT" = "$WORKTREE" ]; then
            REMOTE_PKG_ARG="."
          else
            REMOTE_PKG_ARG="${PKG_ROOT#$WORKTREE/}"
          fi
          REMOTE_CMD='cd '"$Q_WORKTREE"' && swift test --package-path '"$(printf '%q' "$REMOTE_PKG_ARG")"
          ;;
        *)
          # case (c): sync the package tree separately.
          REL_PKG=$(sourcesync_push "$NODE_ID" "$PKG_ROOT") || {
            printf 'swift-test-gate: package sync to %s failed\n' "$NODE_ID" >&2
            data=$(printf '{"mode":"swift-test","reason":"package_sync_failed","node":"%s","attempt":%s%s}' "$NODE_ID" "$ATTEMPT" "$DISPATCH_FIELDS")
            _emit_terminal build_check_failed "$data"
            exit 2
          }
          Q_PKG=$(sourcesync_remote_quoted "$REL_PKG")
          REMOTE_CMD='cd '"$Q_WORKTREE"' && swift test --package-path '"$Q_PKG"
          ;;
      esac
      ;;
    *)
      # case (a): worktree-relative — pass through verbatim.
      REMOTE_CMD='cd '"$Q_WORKTREE"' && swift test --package-path '"$(printf '%q' "$PKG_ROOT")"
      ;;
  esac
  # #270 — sidecar capture so _emit_terminal / _emit_aborted_if_open can
  # mark the dispatch-registry entry node-dispatch wrote.
  UUID_SIDECAR=$(mktemp 2>/dev/null || printf '/tmp/dispatch-uuid-%s' "$$")
  STUDIO_DISPATCH_TASK_ID="$TASK_ID" \
    STUDIO_DISPATCH_UUID_FILE="$UUID_SIDECAR" \
    "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" \
      >"$test_log" 2>&1
  TEST_STATUS=$?
  DISPATCH_UUID=$(tr -d '[:space:]' < "$UUID_SIDECAR" 2>/dev/null)
  rm -f "$UUID_SIDECAR" 2>/dev/null || true
fi

# Counts kept cheap and well-defined: swift-test surfaces failures via
# `error:` and Xcode-style `: error:` prefixes, identical to xcodebuild.
# #237 — sanitise grep -c output without falling back to `|| echo 0`,
# which would concatenate two zeros across a newline on the no-matches
# path and corrupt the JSONL event payload.
err_count=$(grep -cE '(^|: )error:' "$test_log" 2>/dev/null)
case "$err_count" in ''|*[!0-9]*) err_count=0 ;; esac
warn_count=$(grep -cE '(^|: )warning:' "$test_log" 2>/dev/null)
case "$warn_count" in ''|*[!0-9]*) warn_count=0 ;; esac

GATE_DUR_S=$(( $(date -u +%s) - GATE_START_S ))
[ "$GATE_DUR_S" -lt 0 ] && GATE_DUR_S=0

if [ "$TEST_STATUS" -ne 0 ]; then
  failure_reason=$(_swift_test_failure_reason "$test_log")
  if ! node_is_self "$NODE_ID"; then
    if [ "$TEST_STATUS" -eq 124 ]; then
      failure_reason="remote_timeout"
    else
      failure_reason=$(remote_failure_reason "$test_log")
      if [ "$failure_reason" = "remote_command_failed" ] || [ "$failure_reason" = "remote_harness_failure" ] || [ "$failure_reason" = "build_invocation_failed" ]; then
        failure_reason=$(_swift_test_failure_reason "$test_log")
      fi
    fi
  fi
  data=$(printf '{"mode":"swift-test","node":"%s","errors":%s,"warnings":%s,"package":"%s","attempt":%s%s}' \
    "$NODE_ID" "$err_count" "$warn_count" "$PKG_ROOT" "$ATTEMPT" "$DISPATCH_FIELDS")
  data=$(printf '%s' "$data" | jq -c --arg reason "$failure_reason" '. + {reason:$reason}')
  if [ "$failure_reason" = "focused_verification_structurally_blocked" ]; then
    data=$(printf '%s' "$data" | jq -c '. + {verification_blocked:true, verdict_note:"focused verification structurally blocked"}')
  fi
  if [ "$failure_reason" = "remote_marker_writer_failed" ]; then
    data=$(remote_enrich_marker_failure "$data" "$test_log")
  fi
  rm -f "$test_log" 2>/dev/null || true
  _emit_terminal build_check_failed "$data"
  gate_announce_done swift-test "$NODE_ID" "$TASK_ID" failed "$GATE_DUR_S"
  exit 2
fi

rm -f "$test_log" 2>/dev/null || true
data=$(printf '{"mode":"swift-test","node":"%s","warnings":%s,"package":"%s","files":%s,"attempt":%s%s}' \
  "$NODE_ID" "$warn_count" "$PKG_ROOT" "$file_count" "$ATTEMPT" "$DISPATCH_FIELDS")
_emit_terminal build_check_passed "$data"
gate_announce_done swift-test "$NODE_ID" "$TASK_ID" passed "$GATE_DUR_S"
exit 0
