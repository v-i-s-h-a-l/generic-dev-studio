#!/usr/bin/env bash
# Tests has_leaky_tokens() from scripts/ingest-feedback.sh against fixtures.
# Each fixture is labelled CLEAN or LEAK; the test asserts the expected verdict.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INGEST="$REPO_ROOT/scripts/ingest-feedback.sh"

# Source only the function by extracting it; the script has a top-of-file
# guard that exits early outside generic-dev-studio runtime, so we can't just
# `source` it. Extract has_leaky_tokens via awk.
FUNC=$(awk '
  /^has_leaky_tokens\(\)/ { inside=1 }
  inside { print }
  inside && /^}$/ { exit }
' "$INGEST")

eval "$FUNC"

pass=0
fail=0

check() {
  local fixture="$1" expect="$2"  # expect: clean | leak
  local body
  body=$(awk '/^---[[:space:]]*$/ { n++; next } n>=2 { print }' "$fixture")
  if has_leaky_tokens "$body"; then
    got=leak
  else
    got=clean
  fi
  if [ "$got" = "$expect" ]; then
    printf 'PASS  %-40s expected=%s got=%s\n' "$(basename "$fixture")" "$expect" "$got"
    pass=$((pass+1))
  else
    printf 'FAIL  %-40s expected=%s got=%s\n' "$(basename "$fixture")" "$expect" "$got"
    fail=$((fail+1))
  fi
}

# Clean fixtures (task IDs, paths — should NOT trigger).
check "$SCRIPT_DIR/clean-task-ids.md" clean

# Live false-positive file (if present on this machine).
FP="$HOME/.dev-studio/generic-dev-studio/feedback-inbox/turnip-ios/20260423-141658-bug-sweep-misses-unregistered-task-debriefs.md"
if [ -f "$FP" ]; then
  check "$FP" clean
fi

# Leak fixtures (real secret shapes — SHOULD trigger).
check "$SCRIPT_DIR/secret-github-token.md" leak
check "$SCRIPT_DIR/secret-jwt.md"           leak
check "$SCRIPT_DIR/secret-aws.md"           leak

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
