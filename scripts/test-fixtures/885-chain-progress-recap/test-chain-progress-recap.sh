#!/usr/bin/env bash
# Verifies durable chain progress recap generator wiring.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'PROGRESS_RECAP_ROOT=""' "$RUNNER" \
  || fail "runner is missing progress recap root state"
grep -Fq 'PROGRESS_RECAP_ROOT="$CHAIN_RUN_ROOT/progress-recaps"' "$RUNNER" \
  || fail "runner does not place recaps under the chain run root"
grep -Fq 'progress_recap_artifact_path()' "$RUNNER" \
  || fail "runner is missing recap artifact path helper"
grep -Fq 'render_chain_progress_recap()' "$RUNNER" \
  || fail "runner is missing recap renderer"
grep -Fq 'write_chain_progress_recap()' "$RUNNER" \
  || fail "runner is missing durable recap writer"
grep -Fq 'Boundary: \($boundary)' "$RUNNER" \
  || fail "recap renderer does not include boundary"
grep -Fq 'Preferred command if this session stops' "$RUNNER" \
  || fail "recap renderer does not include resume command"

printf 'PASS: chain progress recap generator\n'
