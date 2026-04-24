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
ATTEMPTS_DIR="$(resolve_project_root_for "$PROJECT")/.runtime/state/build-check-attempts"
ATTEMPTS_FILE="$ATTEMPTS_DIR/$TASK_ID"
mkdir -p "$ATTEMPTS_DIR" 2>/dev/null || true
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
  local data
  data=$(printf '{"mode":"swift-test","attempt":%s,"exit_code":%s}' "$ATTEMPT" "$rc")
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
trap _emit_aborted_if_open EXIT INT TERM

# DRY-RUN — log the invocation, skip the real test run. Idempotency-key
# parity with task-build-gate.sh so wet/dry-run output diffs cleanly.
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN swift test --package-path=%s\n' "$PKG_ROOT" >&2
  _emit_terminal build_check_passed \
    "$(printf '{"mode":"swift-test","dry_run":true,"package":"%s","attempt":%s}' "$PKG_ROOT" "$ATTEMPT")"
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  data=$(printf '{"mode":"swift-test","reason":"swift_unavailable","package":"%s","attempt":%s}' "$PKG_ROOT" "$ATTEMPT")
  _emit_terminal build_check_failed "$data"
  exit 2
fi

test_log=$(mktemp 2>/dev/null || printf '/tmp/swift-test-%s.log' "$$")
swift test --package-path "$PKG_ROOT" >"$test_log" 2>&1
TEST_STATUS=$?

# Counts kept cheap and well-defined: swift-test surfaces failures via
# `error:` and Xcode-style `: error:` prefixes, identical to xcodebuild.
err_count=$(grep -cE '(^|: )error:' "$test_log" 2>/dev/null || echo 0)
warn_count=$(grep -cE '(^|: )warning:' "$test_log" 2>/dev/null || echo 0)
rm -f "$test_log" 2>/dev/null || true

if [ "$TEST_STATUS" -ne 0 ]; then
  data=$(printf '{"mode":"swift-test","errors":%s,"warnings":%s,"package":"%s","attempt":%s}' \
    "$err_count" "$warn_count" "$PKG_ROOT" "$ATTEMPT")
  _emit_terminal build_check_failed "$data"
  exit 2
fi

data=$(printf '{"mode":"swift-test","warnings":%s,"package":"%s","files":%s,"attempt":%s}' \
  "$warn_count" "$PKG_ROOT" "$file_count" "$ATTEMPT")
_emit_terminal build_check_passed "$data"
exit 0
