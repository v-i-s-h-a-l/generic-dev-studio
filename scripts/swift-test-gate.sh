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
    data=$(printf '{"mode":"swift-test","attempt":%s,"exit_code":%s,"reason":"%s"}' "$ATTEMPT" "$rc" "$reason")
  else
    data=$(printf '{"mode":"swift-test","attempt":%s,"exit_code":%s}' "$ATTEMPT" "$rc")
  fi
  emit_event_keyed achilles task build_check_aborted "$TASK_ID" "$data" >/dev/null 2>&1 || true
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}
_emit_terminal() {
  local event="${1:?}"
  local data="${2:?}"
  emit_event_keyed achilles task "$event" "$TASK_ID" "$data" >/dev/null 2>&1 || true
  TERMINAL_EMITTED=1
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}

file_count=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
start_data=$(printf '{"mode":"swift-test","worktree":"%s","package":"%s","files":%s,"attempt":%s}' \
  "$WORKTREE" "$PKG_ROOT" "$file_count" "$ATTEMPT")
emit_event_keyed achilles task build_check_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true
trap '_emit_aborted_if_open; _release_task_lock' EXIT INT TERM

# DRY-RUN — log the invocation, skip the real test run. Idempotency-key
# parity with task-build-gate.sh so wet/dry-run output diffs cleanly.
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN swift test --package-path=%s\n' "$PKG_ROOT" >&2
  _emit_terminal build_check_passed \
    "$(printf '{"mode":"swift-test","dry_run":true,"package":"%s","attempt":%s}' "$PKG_ROOT" "$ATTEMPT")"
  exit 0
fi

# Route the test run through node-dispatch so an SSH-reachable worker
# node tagged `swift-test` absorbs the compile + test cost. `node-pick`
# returns `local` when no remote is registered or healthy, which keeps
# hosts without a node registry running bit-for-bit the old behaviour.
NODE_ID=$("$SCRIPT_DIR/node-pick.sh" swift-test 2>/dev/null || echo local)

if node_is_self "$NODE_ID"; then
  # Local swift is only required on the local branch — if we're dispatching
  # to a remote node, the remote's toolchain is what matters and its
  # absence surfaces as a non-zero remote exit code below.
  if ! command -v swift >/dev/null 2>&1; then
    data=$(printf '{"mode":"swift-test","reason":"swift_unavailable","package":"%s","attempt":%s}' "$PKG_ROOT" "$ATTEMPT")
    _emit_terminal build_check_failed "$data"
    exit 2
  fi
fi

test_log=$(mktemp 2>/dev/null || printf '/tmp/swift-test-%s.log' "$$")

if node_is_self "$NODE_ID"; then
  swift test --package-path "$PKG_ROOT" >"$test_log" 2>&1
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
  REL_WORKTREE=$(sourcesync_push "$NODE_ID" "$WORKTREE") || {
    printf 'swift-test-gate: source sync to %s failed\n' "$NODE_ID" >&2
    data=$(printf '{"mode":"swift-test","reason":"source_sync_failed","node":"%s","attempt":%s}' "$NODE_ID" "$ATTEMPT")
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
            data=$(printf '{"mode":"swift-test","reason":"package_sync_failed","node":"%s","attempt":%s}' "$NODE_ID" "$ATTEMPT")
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
  "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" \
    >"$test_log" 2>&1
fi
TEST_STATUS=$?

# Counts kept cheap and well-defined: swift-test surfaces failures via
# `error:` and Xcode-style `: error:` prefixes, identical to xcodebuild.
err_count=$(grep -cE '(^|: )error:' "$test_log" 2>/dev/null || echo 0)
warn_count=$(grep -cE '(^|: )warning:' "$test_log" 2>/dev/null || echo 0)
rm -f "$test_log" 2>/dev/null || true

if [ "$TEST_STATUS" -ne 0 ]; then
  data=$(printf '{"mode":"swift-test","node":"%s","errors":%s,"warnings":%s,"package":"%s","attempt":%s}' \
    "$NODE_ID" "$err_count" "$warn_count" "$PKG_ROOT" "$ATTEMPT")
  _emit_terminal build_check_failed "$data"
  exit 2
fi

data=$(printf '{"mode":"swift-test","node":"%s","warnings":%s,"package":"%s","files":%s,"attempt":%s}' \
  "$NODE_ID" "$warn_count" "$PKG_ROOT" "$file_count" "$ATTEMPT")
_emit_terminal build_check_passed "$data"
exit 0
