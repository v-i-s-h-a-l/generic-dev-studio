#!/usr/bin/env bash
# codex-smoke-test.sh — exercise the conformance harness against a real
# codex binary (not the mock shim).
#
# Today scripts/test-host.sh codex runs against tests/conformance/mock-codex/
# unless STUDIO_CODEX_BIN points at a real binary. This wrapper auto-detects
# the system codex binary, sets STUDIO_CODEX_BIN, and invokes the full
# conformance matrix (4 happy-path tasks + 4 failure-mode floors + baseline-
# diff) against it. A green pass is the structural prerequisite for #166's
# live-task dispatch.
#
# Usage:
#   scripts/codex-smoke-test.sh                    # full matrix, real codex
#   scripts/codex-smoke-test.sh --binary <path>    # explicit binary
#   scripts/codex-smoke-test.sh --failure-modes-only
#   scripts/codex-smoke-test.sh --check-only       # detect binary; don't run
#
# Exit 0 iff every conformance task PASSes against the real codex binary.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

CODEX_BIN=""
EXTRA_ARGS=()
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --binary) shift; CODEX_BIN="$1" ;;
    --check-only) CHECK_ONLY=1 ;;
    --failure-modes-only) EXTRA_ARGS+=("--failure-modes-only") ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf 'codex-smoke-test: unknown arg "%s"\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Resolve the binary: CLI arg > $STUDIO_CODEX_BIN > $(which codex).
if [ -z "$CODEX_BIN" ]; then
  if [ -n "${STUDIO_CODEX_BIN:-}" ]; then
    CODEX_BIN="$STUDIO_CODEX_BIN"
  elif command -v codex >/dev/null 2>&1; then
    CODEX_BIN=$(command -v codex)
  fi
fi

if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
  printf 'codex-smoke-test: no real codex binary on PATH and STUDIO_CODEX_BIN unset.\n' >&2
  printf '  install via: brew install codex   (or pull from openai/codex)\n' >&2
  exit 1
fi

# Print binary identity — useful in CI logs and for human verification that
# we're not accidentally running the mock.
printf 'codex-smoke-test: binary=%s version=%s\n' \
  "$CODEX_BIN" "$("$CODEX_BIN" --version 2>/dev/null | head -1)" >&2

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 0
fi

# Hand off to the conformance harness with STUDIO_CODEX_BIN exported. The
# harness's mock-shim fallback is bypassed because the env var is set.
export STUDIO_CODEX_BIN="$CODEX_BIN"

# Surface that we're running against the REAL binary, not the mock — easy
# to miss in scrolling output otherwise.
printf '\n=== conformance matrix vs REAL codex (STUDIO_CODEX_BIN=%s) ===\n\n' \
  "$CODEX_BIN" >&2

if "$SCRIPT_DIR/test-host.sh" codex "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; then
  printf '\ncodex-smoke-test: PASS — every conformance task passed against real codex.\n' >&2
  printf '  #166 live-task dispatch is unblocked. Next step: pick a real XS/S task,\n' >&2
  printf '  set STUDIO_HOST=codex, run /achilles <task-id>, and verify the debrief\n' >&2
  printf '  carries gen_ai.system=codex.\n' >&2
  exit 0
else
  rc=$?
  printf '\ncodex-smoke-test: FAIL — at least one conformance task failed.\n' >&2
  printf '  Inspect the [FAIL] lines above; capture rough edges as new issues per #166 done-condition.\n' >&2
  exit "$rc"
fi
