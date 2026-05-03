#!/usr/bin/env bash
# Verifies A11 build/release message linting.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/lint-build-release-message.sh"
TMPROOT=$(mktemp -d -t build-release-message.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "linter is not executable"

cat > "$TMPROOT/tf-pass.md" <<'MSG'
[iOS] build 1234 is available on TestFlight

*New*
- Adds profile-aware build routing.

*Fixed*
- Improves release preflight copy.
MSG

cat > "$TMPROOT/appstore-pass.md" <<'MSG'
[iOS] v26.5.0 (build 1234) has been submitted for App Store review

*New*
- Adds profile-aware build routing.
MSG

cat > "$TMPROOT/dup-heading.md" <<'MSG'
[iOS] build 1234 is available on TestFlight

*New*
- Adds profile-aware build routing.

*New*
- Adds release copy linting.
MSG

cat > "$TMPROOT/dup-bullet.md" <<'MSG'
[iOS] build 1234 is available on TestFlight

*Fixed*
- Fixes archive preflight.
- fixes archive preflight
MSG

cat > "$TMPROOT/bad-shape.md" <<'MSG'
Build 1234 is ready

- Missing section and recognized headline.
MSG

"$RUN" --file "$TMPROOT/tf-pass.md" --channel testflight
"$RUN" --file "$TMPROOT/appstore-pass.md" --channel appstore
printf '%s\n' "$(cat "$TMPROOT/tf-pass.md")" | "$RUN" --stdin --channel testflight

if "$RUN" --file "$TMPROOT/dup-heading.md" --channel testflight >"$TMPROOT/dup-heading.out" 2>"$TMPROOT/dup-heading.err"; then
  fail "duplicate heading should fail"
fi
grep -q 'duplicate-heading' "$TMPROOT/dup-heading.err" || fail "missing duplicate heading finding"

if "$RUN" --file "$TMPROOT/dup-bullet.md" --channel testflight >"$TMPROOT/dup-bullet.out" 2>"$TMPROOT/dup-bullet.err"; then
  fail "duplicate bullet should fail"
fi
grep -q 'duplicate-bullet' "$TMPROOT/dup-bullet.err" || fail "missing duplicate bullet finding"

if "$RUN" --file "$TMPROOT/bad-shape.md" --channel testflight >"$TMPROOT/bad-shape.out" 2>"$TMPROOT/bad-shape.err"; then
  fail "bad shape should fail"
fi
grep -q 'headline:' "$TMPROOT/bad-shape.err" || fail "missing headline finding"
grep -q 'shape:' "$TMPROOT/bad-shape.err" || fail "missing shape finding"

printf 'PASS: build/release message linter\n'
