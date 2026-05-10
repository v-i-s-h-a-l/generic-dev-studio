#!/usr/bin/env bash
# test-plan-chain-inline-paths.sh — fixture for #823.
#
# Verifies manager-plan-chain.sh fails fast with an actionable message when
# inline goal text references readable file paths, and respects the bypass
# envvar.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/manager-plan-chain.sh"
TMPROOT=$(mktemp -d -t plan-chain-inline.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

# Make a readable artifact-shaped file.
artifact="$TMPROOT/2026-05-10-foo-outcome-review.md"
printf '# review\n' > "$artifact"

# Case 1: inline prompt that references an existing readable path -> fail with redirect.
out=$("$RUN" "regenerate plan from review at $artifact and address blockers" 2> "$TMPROOT/c1.err" || printf 'rc=%s\n' "$?")
assert "inline path reference fails non-zero" \
  'grep -q "rc=2" <<< "$out"'
assert "error message names the offending path" \
  'grep -Fq "$artifact" "$TMPROOT/c1.err"'
assert "error suggests --source-file redirect" \
  'grep -q -- "--source-file <path>" "$TMPROOT/c1.err"'
assert "error documents the bypass envvar" \
  'grep -q "STUDIO_PLAN_CHAIN_ALLOW_INLINE_PATHS" "$TMPROOT/c1.err"'

# Case 2: inline prompt with NO paths -> path detection should not fire.
# (We can't run end-to-end without gh / planner; just confirm the detector
#  does not trigger by checking the early-exit error string is absent.)
"$RUN" "build a widget that does X" >"$TMPROOT/c2.out" 2>"$TMPROOT/c2.err" || true
assert "plain inline prompt does not trip path detector" \
  '! grep -q "references readable file path" "$TMPROOT/c2.err"'

# Case 3: inline prompt referencing a NON-existent path -> should not trip
# (we only fail when the path is actually readable; otherwise it's just prose).
"$RUN" "do something with /tmp/does-not-exist-$$.md" >"$TMPROOT/c3.out" 2>"$TMPROOT/c3.err" || true
assert "non-readable path reference is not flagged" \
  '! grep -q "references readable file path" "$TMPROOT/c3.err"'

# Case 4: bypass envvar lets the inline prompt through despite path reference.
STUDIO_PLAN_CHAIN_ALLOW_INLINE_PATHS=1 "$RUN" "regenerate from $artifact" \
  >"$TMPROOT/c4.out" 2>"$TMPROOT/c4.err" || true
assert "bypass=1 disables the path-detection guard" \
  '! grep -q "references readable file path" "$TMPROOT/c4.err"'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: plan-chain inline-paths (%d/%d)\n' "$pass" "$pass"
