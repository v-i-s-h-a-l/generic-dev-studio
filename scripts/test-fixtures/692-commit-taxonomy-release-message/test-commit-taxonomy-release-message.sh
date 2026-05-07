#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/commit-taxonomy-release-message.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

COMMITS="$TMP_DIR/commits.txt"
TF_OUT="$TMP_DIR/testflight.md"
APP_OUT="$TMP_DIR/appstore.md"
JSON_OUT="$TMP_DIR/testflight.json"

cat >"$COMMITS" <<'EOF'
aaa111 | Add smarter release composer
Change-Type: feature
Problem: Release writers had to classify every commit by hand.
Solution: The composer now groups taxonomy metadata into release sections.
---
bbb222 | Fix shipped editor upload retry
Change-Type: bugfix-shipped
Problem: Upload retry sometimes stopped after the first failed request.
Solution: Retry state now survives the transient failure.
---
ccc333 | Draft fix for flaky tester invite sync
Change-Type: bugfix-wip
Problem: Tester invite sync is still being verified.
Solution: A partial guard narrows the failure while testing continues.
---
ddd444 | Repair regression in release marker finalization
Change-Type: regression-fix
Problem: Release finalization could skip marker cleanup.
Solution: Finalization now records every completed step.
---
eee555 | Update release docs
Change-Type: docs
Problem: Internal release docs were stale.
Solution: The examples now match the current scripts.
---
fff666 | Handle missing taxonomy trailers from old commits
Old commit body without structured metadata.
---
999aaa | Crash fix from Crashlytics
Change-Type: bugfix-shipped
Problem: Crashlytics showed a crash on launch. https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123
Solution: Startup now waits for configuration.
EOF

"$ROOT/scripts/studio-tf-push.sh" compose-message --channel testflight --input "$COMMITS" >"$TF_OUT"
"$ROOT/scripts/studio-tf-push.sh" compose-message --channel appstore --input "$COMMITS" >"$APP_OUT"
"$ROOT/scripts/studio-tf-push.sh" compose-message --channel testflight --input "$COMMITS" --json >"$JSON_OUT"

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    printf 'expected %s to contain: %s\n' "$file" "$expected" >&2
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    printf 'expected %s not to contain: %s\n' "$file" "$unexpected" >&2
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_contains "$TF_OUT" "*New*"
assert_contains "$TF_OUT" "Release writers had to classify every commit by hand"
assert_contains "$TF_OUT" "*Fixed*"
assert_contains "$TF_OUT" "Upload retry sometimes stopped after the first failed request"
assert_contains "$TF_OUT" "Work-in-progress fix: Tester invite sync is still being verified"
assert_contains "$TF_OUT" "regression bug fix: Release finalization could skip marker cleanup"
assert_contains "$TF_OUT" "Handle missing taxonomy trailers from old commits"
assert_contains "$TF_OUT" "https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123"

assert_contains "$APP_OUT" "*New*"
assert_contains "$APP_OUT" "Upload retry sometimes stopped after the first failed request"
assert_contains "$APP_OUT" "Fixed crash https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123"
assert_not_contains "$APP_OUT" "Work-in-progress fix"
assert_not_contains "$APP_OUT" "Internal release docs were stale"

assert_not_contains "$TF_OUT" "Change-Type:"
assert_not_contains "$APP_OUT" "Change-Type:"

jq -e '
  .channel == "testflight"
  and ([.commits[].change_type] | index("feature"))
  and ([.commits[].change_type] | index("bugfix-wip"))
  and ([.commits[].bucket] | index("crash"))
' "$JSON_OUT" >/dev/null

printf 'commit taxonomy release message fixture passed\n'
