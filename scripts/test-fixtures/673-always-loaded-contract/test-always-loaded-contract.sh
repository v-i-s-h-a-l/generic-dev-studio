#!/usr/bin/env bash
# Regression coverage for the minimal always-loaded rule contract.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONTRACT="$ROOT/core/v2/rule-packs/always-loaded-contract.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  needle="$1"
  grep -Fq -- "$needle" "$CONTRACT" || fail "contract missing: $needle"
}

[ -f "$CONTRACT" ] || fail "contract file not found"

budget=$(sed -n 's/^<!-- always-loaded-contract:budget-tokens=\([0-9][0-9]*\) -->$/\1/p' "$CONTRACT")
[ -n "$budget" ] || fail "budget anchor missing"

chars=$(wc -c < "$CONTRACT" | tr -d ' ')
estimated_tokens=$(( (chars + 3) / 4 ))
[ "$estimated_tokens" -le "$budget" ] || {
  fail "contract estimate ${estimated_tokens} tokens exceeds budget ${budget}"
}

for anchor in \
  '<!-- always-loaded-contract:rules -->' \
  '<!-- always-loaded-contract:exclusions -->' \
  '<!-- always-loaded-contract:lookup-order -->' \
  '<!-- always-loaded-contract:missing-invalid-pack -->' \
  '<!-- always-loaded-contract:budget -->'
do
  contains "$anchor"
done

for required in \
  'Worktree isolation' \
  'Privacy/public-output boundary' \
  'GitHub wrapper' \
  'Rule-pack loading obligation' \
  'Script-enforcement obligation' \
  'User-controlled override requirement'
do
  contains "$required"
done

for excluded in \
  'Detailed iOS artifact policy' \
  'Worker-routing scoring' \
  'Release, TestFlight' \
  'Cleanup TTL details' \
  'Full git policy' \
  'Full telemetry field lists'
do
  contains "$excluded"
done

for lookup in \
  '1. Task or chain manifest.' \
  '2. Project profile.' \
  '3. Role or mode contract.' \
  '4. Classifier output.' \
  '5. Manual operator override.'
do
  contains "$lookup"
done

contains 'stop before side effects'
contains 'blocked result'
contains 'operator-owned override'

printf 'PASS: always-loaded contract within %s-token budget (~%s tokens)\n' "$budget" "$estimated_tokens"
