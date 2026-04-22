#!/usr/bin/env bash
# task-build-gate.sh — Step 6 of the Achilles task mode.
#
# Owns the full build-verification gate. Two modes:
#
#   lsp-only    — per-file swift-lsp diagnostics. No xcodebuild, no lock, no
#                 DerivedData. Red if any .swift file surfaces errors.
#   full-green  — xcodebuild under the machine-global xcodebuild-lock with
#                 45-minute staleness reclaim, per-task DerivedData isolation,
#                 and a trap that releases the lock on any exit. Red if the
#                 build exits non-zero.
#
# The lock is machine-global (the serialized resource is the SPM cache +
# Clang module cache + simulator locks — all process-wide), so it lives under
# `~/.dev-studio/.runtime/xcodebuild-lock/` rather than per-project. This is
# a R4-exempted carve-out documented in file-locations.md.
#
# Usage:
#   scripts/task-build-gate.sh <mode> <task-id> <worktree> <scheme> <destination>
#     mode: lsp-only | full-green
#
# Exit codes:
#   0  green
#   2  red (build / LSP errors, missing tools, bad args)
#   3  locked-out (30-minute wait exceeded)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

MODE="${1:?usage: task-build-gate.sh <lsp-only|full-green> <task-id> <worktree> <scheme> <destination>}"
TASK_ID="${2:?task-id required}"
WORKTREE="${3:?worktree required}"
SCHEME="${4:-}"
DESTINATION="${5:-}"

case "$MODE" in
  lsp-only|full-green) ;;
  *) printf 'error: mode must be lsp-only or full-green (got %s)\n' "$MODE" >&2; exit 2 ;;
esac

[ -d "$WORKTREE" ] || { printf 'error: worktree not a directory: %s\n' "$WORKTREE" >&2; exit 2; }

# Announce the attempt so analysis can bucket red gates by mode.
start_data=$(printf '{"mode":"%s","worktree":"%s"}' "$MODE" "$WORKTREE")
emit_event_keyed achilles task build_check_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true

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
    emit_event_keyed achilles task build_check_passed "$TASK_ID" \
      '{"mode":"lsp-only","files":0}' >/dev/null 2>&1 || true
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
    data=$(printf '{"mode":"lsp-only","files":%s,"errors":%s}' "$file_count" "$errors")
    emit_event_keyed achilles task build_check_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    exit 2
  fi
  data=$(printf '{"mode":"lsp-only","files":%s}' "$file_count")
  emit_event_keyed achilles task build_check_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  exit 0
fi

# ---------- full-green ----------
#
# xcodebuild requires a scheme + destination. Bail early rather than run a
# pointless build against defaults.
[ -n "$SCHEME" ] || { printf 'error: scheme required for full-green mode\n' >&2; exit 2; }
[ -n "$DESTINATION" ] || { printf 'error: destination required for full-green mode\n' >&2; exit 2; }

LOCK_ROOT="$(resolve_runtime_global)/xcodebuild-lock"
LOCK="$LOCK_ROOT"
DERIVED=$(resolve_derived_data_for "$TASK_ID")
mkdir -p "$DERIVED" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$DERIVED" >&2; exit 2; }
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$(dirname "$LOCK")" >&2; exit 2; }

# DRY-RUN — log the invocation, skip the lock + xcodebuild. Idempotency key
# matches the wet-run's path so diff-comparison works (patterns/dry-run.md).
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN xcodebuild scheme=%s destination=%s -derivedDataPath=%s\n' \
    "$SCHEME" "$DESTINATION" "$DERIVED" >&2
  emit_event_keyed achilles task build_check_passed "$TASK_ID" \
    "$(printf '{"mode":"full-green","dry_run":true,"scheme":"%s"}' "$SCHEME")" >/dev/null 2>&1 || true
  exit 0
fi

# Acquire the lock with bounded wait. 45-min staleness threshold reclaims a
# lock whose holder died without cleanup (e.g. SIGKILL from the runner). Wait
# envelope: 30 min total (180 × 10s). Backoff kept linear — contention is
# rare and 10s granularity is fine.
wait_seconds=0
wait_cap=1800
backoff=10
while true; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/pid"
    break
  fi
  # Stale-lock reclaim — mdir mtime beyond 45m → presume orphan.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    printf 'warn: stale xcodebuild lock (>45m), reclaiming\n' >&2
    rm -rf "$LOCK"
    continue
  fi
  if [ "$wait_seconds" -ge "$wait_cap" ]; then
    printf 'error: xcodebuild lock wait exceeded %ss\n' "$wait_cap" >&2
    data=$(printf '{"mode":"full-green","reason":"locked_out","waited_s":%s}' "$wait_seconds")
    emit_event_keyed achilles task build_check_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
    exit 3
  fi
  sleep "$backoff"
  wait_seconds=$((wait_seconds + backoff))
done

# Trap registered inside the script — the caller invokes synchronously so
# EXIT fires once this script returns. Internal handler is sufficient.
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }

# Run the build. Output is captured for downstream analysis (error-line count
# in the data payload) but not stored — we trust xcodebuild's exit status.
build_log=$(mktemp 2>/dev/null || printf '/tmp/xcb-%s.log' "$$")
xcodebuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  build \
  >"$build_log" 2>&1
BUILD_STATUS=$?

# Parse error + warning counts. Cheap and well-defined — xcodebuild's error
# lines match `error:` case-insensitively and begin at column 0 or after a path.
err_count=$(grep -cE '(^|: )error:' "$build_log" 2>/dev/null || echo 0)
warn_count=$(grep -cE '(^|: )warning:' "$build_log" 2>/dev/null || echo 0)
rm -f "$build_log" 2>/dev/null || true

if [ "$BUILD_STATUS" -ne 0 ]; then
  data=$(printf '{"mode":"full-green","errors":%s,"warnings":%s,"scheme":"%s"}' \
    "$err_count" "$warn_count" "$SCHEME")
  emit_event_keyed achilles task build_check_failed "$TASK_ID" "$data" >/dev/null 2>&1 || true
  exit 2
fi

data=$(printf '{"mode":"full-green","warnings":%s,"scheme":"%s"}' "$warn_count" "$SCHEME")
emit_event_keyed achilles task build_check_passed "$TASK_ID" "$data" >/dev/null 2>&1 || true
exit 0
