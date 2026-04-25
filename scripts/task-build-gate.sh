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
# The lock lives under `~/.dev-studio/.runtime/xcodebuild-lock/<node-id>/`
# — machine-global scope (the serialized resource is the SPM cache + Clang
# module cache + simulator locks, all process-wide on the node that runs
# the build) but keyed by dispatch target so a laptop-local build and a
# mini-dispatched build don't serialize on each other. `<node-id>` is
# `local` when no remote is picked, preserving pre-B3 behaviour. This is
# an R4-exempted carve-out documented in file-locations.md.
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

# Per-task attempt counter. Distinguishes a cold start (1) from a retry
# (2+) so analytics can compute first-try success rate. State lives under
# the project-scoped runtime dir; reset when a terminal event lands. See
# issue #106.
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

# Trap-based terminal-span closure. Without this, any exit path between
# build_check_started and the pass/fail emit (cd failures, missing args,
# SIGKILL, stale-lock retry-loop bail-outs) would leave an open span that
# analytics can't distinguish from "still running". See issue #106.
TERMINAL_EMITTED=0
_emit_aborted_if_open() {
  local rc=$?
  [ "$TERMINAL_EMITTED" = "1" ] && return 0
  local data
  data=$(printf '{"mode":"%s","attempt":%s,"exit_code":%s}' "$MODE" "$ATTEMPT" "$rc")
  emit_event_keyed achilles task build_check_aborted "$TASK_ID" "$data" >/dev/null 2>&1 || true
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
  rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
}

# Announce the attempt so analysis can bucket red gates by mode + retry.
start_data=$(printf '{"mode":"%s","worktree":"%s","attempt":%s}' "$MODE" "$WORKTREE" "$ATTEMPT")
emit_event_keyed achilles task build_check_started "$TASK_ID" "$start_data" >/dev/null 2>&1 || true
trap _emit_aborted_if_open EXIT INT TERM

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

# Route xcodebuild through node-dispatch so an SSH-reachable mini (or any
# future node tagged `xcodebuild`) can absorb the M/L build cost. The lock
# is scoped per node: two workers dispatching to `mini` still serialize on
# the mini's cache + simulator resources, but a laptop-local build running
# against `local` runs in parallel with a mini build — different machines,
# different serialized resources. `node-pick` returns `local` when no
# remote is registered or healthy, so hosts without a registry keep the
# pre-B3 behaviour bit-for-bit under `xcodebuild-lock/local/`.
NODE_ID=$("$SCRIPT_DIR/node-pick.sh" xcodebuild 2>/dev/null || echo local)

LOCK_ROOT="$(resolve_runtime_global)/xcodebuild-lock"
LOCK="$LOCK_ROOT/$NODE_ID"
DERIVED=$(resolve_derived_data_for "$TASK_ID")
mkdir -p "$DERIVED" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$DERIVED" >&2; exit 2; }
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$(dirname "$LOCK")" >&2; exit 2; }

# DRY-RUN — log the invocation, skip the lock + xcodebuild. Idempotency key
# matches the wet-run's path so diff-comparison works (patterns/dry-run.md).
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN xcodebuild node=%s scheme=%s destination=%s -derivedDataPath=%s\n' \
    "$NODE_ID" "$SCHEME" "$DESTINATION" "$DERIVED" >&2
  _emit_terminal build_check_passed \
    "$(printf '{"mode":"full-green","node":"%s","dry_run":true,"scheme":"%s","attempt":%s}' "$NODE_ID" "$SCHEME" "$ATTEMPT")"
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
    data=$(printf '{"mode":"full-green","reason":"locked_out","waited_s":%s,"attempt":%s}' "$wait_seconds" "$ATTEMPT")
    _emit_terminal build_check_failed "$data"
    exit 3
  fi
  sleep "$backoff"
  wait_seconds=$((wait_seconds + backoff))
done

# Trap registered inside the script — the caller invokes synchronously so
# EXIT fires once this script returns. Internal handler is sufficient.
# Composite: first emit an aborted event iff no terminal was sent, THEN
# release the lock — preserves the span-close invariant for the full-green
# branch even when the earlier outer trap got overridden by this one.
trap '_emit_aborted_if_open; rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# Local branch still needs to cd before invoking xcodebuild. Remote branch
# delegates the cd to the remote shell below — the dispatch still happens
# from whatever cwd the caller had.
if [ "$NODE_ID" = "local" ]; then
  cd "$WORKTREE" || { printf 'error: cd %s failed\n' "$WORKTREE" >&2; exit 2; }
fi

# Run the build. Output is captured for downstream analysis (error-line count
# in the data payload) but not stored — we trust the build tool's exit status.
# Inner build call routes through scripts/xcodebuild-shim.sh which selects
# between xcodebuild and xcodebuildmcp per STUDIO_XCODEBUILDMCP env var. When
# xcodebuildmcp is in use, $XCB_JSON_SIDECAR receives a structured JSON view
# the build_check_failed event picks up below to enrich with error detail.
build_log=$(mktemp 2>/dev/null || printf '/tmp/xcb-%s.log' "$$")
build_json="${build_log}.json"
export XCB_JSON_SIDECAR="$build_json"
if [ "$NODE_ID" = "local" ]; then
  "$SCRIPT_DIR/xcodebuild-shim.sh" build \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    >"$build_log" 2>&1
  BUILD_STATUS=$?
else
  # Remote shell owns the cd + shim invocation. %q keeps every path safe
  # through the SSH argv round trip. DerivedData on the remote uses the
  # remote's $HOME (which resolves from the laptop's absolute path when
  # usernames match — the common case) — an unexpected location is
  # auto-created rather than failing. STUDIO_XCODEBUILDMCP env propagates
  # through the remote shell so the same routing rules apply on both sides.
  "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "STUDIO_XCODEBUILDMCP=$(printf '%q' "${STUDIO_XCODEBUILDMCP:-auto}") $(printf '%q' "$SCRIPT_DIR/xcodebuild-shim.sh") build -scheme $(printf '%q' "$SCHEME") -destination $(printf '%q' "$DESTINATION") -derivedDataPath $(printf '%q' "$DERIVED")" \
    >"$build_log" 2>&1
  BUILD_STATUS=$?
fi

# Parse error + warning counts. Cheap and well-defined — xcodebuild's error
# lines match `error:` case-insensitively and begin at column 0 or after a path.
err_count=$(grep -cE '(^|: )error:' "$build_log" 2>/dev/null || echo 0)
warn_count=$(grep -cE '(^|: )warning:' "$build_log" 2>/dev/null || echo 0)

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
rm -f "$build_log" "$build_json" 2>/dev/null || true

if [ "$BUILD_STATUS" -ne 0 ]; then
  data=$(printf '{"mode":"full-green","node":"%s","errors":%s,"warnings":%s,"scheme":"%s","attempt":%s,"errors_json":%s}' \
    "$NODE_ID" "$err_count" "$warn_count" "$SCHEME" "$ATTEMPT" "$errors_json")
  _emit_terminal build_check_failed "$data"
  exit 2
fi

data=$(printf '{"mode":"full-green","node":"%s","warnings":%s,"scheme":"%s","attempt":%s}' "$NODE_ID" "$warn_count" "$SCHEME" "$ATTEMPT")
_emit_terminal build_check_passed "$data"
exit 0
