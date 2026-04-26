#!/usr/bin/env bash
# tests/lint-comms-boundary/run.sh — exercise lint-comms-boundary.sh against
# a hand-crafted synthetic manifest. Asserts every intended violation fires
# with the documented code, and the negative-test row produces zero errors.
#
# Usage: tests/lint-comms-boundary/run.sh
#
# Exit 0: pass. Exit 1: lint failed to catch a violation, or fired a false
# positive on the negative-test row.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
LINTER="$REPO_ROOT/scripts/lint-comms-boundary.sh"
FIXTURE="$SCRIPT_DIR/fixtures/synthetic-bad-manifest.json"

if [ ! -x "$LINTER" ]; then
  printf 'tests/lint-comms-boundary: linter not executable at %s\n' "$LINTER" >&2
  exit 1
fi

if [ ! -f "$FIXTURE" ]; then
  printf 'tests/lint-comms-boundary: fixture missing at %s\n' "$FIXTURE" >&2
  exit 1
fi

# Run the linter against the fixture. Capture both streams.
output=$(LINT_BOUNDARY_MANIFEST="$FIXTURE" "$LINTER" 2>&1; printf 'EXIT=%d' $?)
rc=${output##*EXIT=}
output=${output%EXIT=*}

failures=0

assert_contains() {
  local needle="$1" label="$2"
  if printf '%s' "$output" | grep -qF "$needle"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s — expected output to contain: %s\n' "$label" "$needle" >&2
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  local needle="$1" label="$2"
  if printf '%s' "$output" | grep -qF "$needle"; then
    printf 'FAIL: %s — expected output to NOT contain: %s\n' "$label" "$needle" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$label"
  fi
}

# Expected positive findings.
assert_contains "B_FORBIDDEN_CREATE" "B_FORBIDDEN_CREATE fires (achilles emitting reviews + chanakya creating debriefs)"
assert_contains "achilles/fake-review-emitter" "fake-review-emitter row identified"
assert_contains "chanakya/fake-debrief-creator" "fake-debrief-creator row identified"
assert_contains "B_PASS_THROUGH_VIOLATION" "B_PASS_THROUGH_VIOLATION fires (argus/spec-compliance)"
assert_contains "argus/spec-compliance" "spec-compliance pass-through row identified"

# Negative test — argus task back-ref MUST NOT trigger any error.
# (Match the source location to be precise — the row's unique fingerprint.)
assert_not_contains "argus/fake-task-payload-mutator" "argus task back-ref (negative test) does not trigger an error"

# Linter must exit non-zero overall (we deliberately injected violations).
if [ "$rc" -ne 1 ]; then
  printf 'FAIL: expected linter exit 1, got %s\n' "$rc" >&2
  failures=$((failures + 1))
else
  printf 'PASS: linter exits non-zero on bad fixture\n'
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d failures\n' "$failures" >&2
  exit 1
fi

printf '\nall assertions passed\n'
exit 0
