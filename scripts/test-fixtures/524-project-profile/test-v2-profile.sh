#!/usr/bin/env bash
# Verifies Studio v2 project-profile validation and operation resolution.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/v2-profile.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/v2-profile.sh is not executable"
[ -x "$ROOT/profiles/ios-turnip/commands/xcode-operation" ] || fail "iOS operation command is not executable"

"$RUN" --profile ios-turnip --validate

ops=$("$RUN" --profile ios-turnip --list | sort | tr '\n' ' ')
for op in build format lint release:beta release:prod test:ui test:unit; do
  printf '%s\n' "$ops" | grep -q "$op" || fail "missing operation: $op"
done

dry_json=$("$RUN" --profile ios-turnip --operation build --project-root "$ROOT" --dry-run)
printf '%s\n' "$dry_json" | jq -e '
  .profile == "ios-turnip"
  and .operation == "build"
  and (.command | test("profiles/ios-turnip/commands/xcode-operation$"))
  and (.authority | test("profiles/ios-turnip/commands/xcode-operation.authority.yaml$"))
  and .args == ["build"]
' >/dev/null || {
  printf '%s\n' "$dry_json" >&2
  fail "dry-run output did not describe build operation"
}

if "$RUN" --profile ios-turnip --operation does-not-exist --dry-run >/tmp/v2-profile-missing.out 2>/tmp/v2-profile-missing.err; then
  fail "unknown operation should fail"
fi
grep -q 'operation not defined' /tmp/v2-profile-missing.err || {
  cat /tmp/v2-profile-missing.err >&2
  fail "unknown operation error not actionable"
}

printf 'PASS: v2 project profile resolver\n'
