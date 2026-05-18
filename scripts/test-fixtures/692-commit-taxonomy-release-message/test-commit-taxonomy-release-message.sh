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
Impact: Release writers can draft TestFlight and App Store notes from compact metadata.
Areas: release composer, TestFlight, App Store
Release-Note: Release writers now get cleaner build notes from compact commit metadata.
Why: Release writers had to classify every commit by hand.
Risk: low; parser fallback remains compatible.
---
bbb222 | Fix shipped editor upload retry
Change-Type: bugfix-shipped
Changelog: Editor upload retry now recovers after the first failed request.
Problem: Upload retry sometimes stopped after the first failed request.
Solution: Retry state now survives the transient failure.
Caveat: Retry requires network connectivity to return.
---
ccc333 | Draft fix for flaky tester invite sync
Change-Type: bugfix-wip
Impact: Tester invite sync has a narrower temporary failure mode while verification continues.
Solution: A partial guard narrows the failure while testing continues.
---
ddd444 | Repair regression in release marker finalization
Change-Type: regression-fix
Problem: Release finalization could skip marker cleanup.
Solution: Finalization now records every completed step.
---
eee555 | Update release docs
Change-Type: docs
Release-Note: none
Impact: Internal release docs explain the compact metadata fallback order.
---
fff666 | Handle missing taxonomy trailers from old commits
Old commit body without structured metadata.
---
ggg777 | Subject fallback remains safe
Change-Type: bugfix-shipped
---
999aaa | Crash fix from Crashlytics
Change-Type: bugfix-shipped
Problem: Crashlytics showed a crash on launch. https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123
Solution: Startup now waits for configuration.
Fix-Confidence: fixed
---
999bbb | Multiple Crashlytics fixes
Change-Type: bugfix-shipped
Crash-Fixes: [{"public_label":"Crash opening editor","public_crash_url":"https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/456","fix_confidence":"possibly_fixed"},{"public_label":"Crash exporting collage","public_crash_url":"https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/789","fix_confidence":"mitigated"}]
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
assert_contains "$TF_OUT" "Release writers now get cleaner build notes from compact commit metadata"
assert_contains "$TF_OUT" "*Fixed*"
assert_contains "$TF_OUT" "Editor upload retry now recovers after the first failed request"
assert_contains "$TF_OUT" "Editor upload retry now recovers after the first failed request (note: Retry requires network connectivity to return)"
assert_contains "$TF_OUT" "Work-in-progress fix: Tester invite sync has a narrower temporary failure mode while verification continues"
assert_contains "$TF_OUT" "regression bug fix: Release finalization could skip marker cleanup"
assert_contains "$TF_OUT" "Handle missing taxonomy trailers from old commits"
assert_contains "$TF_OUT" "Subject fallback remains safe"
assert_contains "$TF_OUT" "https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123"
assert_contains "$TF_OUT" "https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/456"
assert_contains "$TF_OUT" "https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/789"

assert_contains "$APP_OUT" "*New*"
assert_contains "$APP_OUT" "Editor upload retry now recovers after the first failed request"
assert_contains "$APP_OUT" "Fixed crash https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/123"
assert_contains "$APP_OUT" "Possible fix for crash https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/456"
assert_contains "$APP_OUT" "Mitigated crash https://console.firebase.google.com/project/demo/crashlytics/app/ios:demo/issues/789"
assert_contains "$APP_OUT" "Subject fallback remains safe"
assert_not_contains "$APP_OUT" "Work-in-progress fix"
assert_not_contains "$APP_OUT" "Internal release docs explain the compact metadata fallback order"

assert_not_contains "$TF_OUT" "Change-Type:"
assert_not_contains "$TF_OUT" "Release-Note:"
assert_not_contains "$TF_OUT" "Impact:"
assert_not_contains "$TF_OUT" "Areas:"
assert_not_contains "$TF_OUT" "Risk:"
assert_not_contains "$TF_OUT" "Caveat:"
assert_not_contains "$TF_OUT" "caveat:"
assert_not_contains "$TF_OUT" "Crash opening editor"
assert_not_contains "$TF_OUT" "Crash exporting collage"
assert_not_contains "$APP_OUT" "Change-Type:"
assert_not_contains "$APP_OUT" "Release-Note:"
assert_not_contains "$APP_OUT" "Impact:"
assert_not_contains "$APP_OUT" "Areas:"
assert_not_contains "$APP_OUT" "Risk:"
assert_not_contains "$APP_OUT" "Caveat:"
assert_not_contains "$APP_OUT" "caveat:"
assert_not_contains "$APP_OUT" "Crash opening editor"
assert_not_contains "$APP_OUT" "Crash exporting collage"

jq -e '
  .channel == "testflight"
  and ([.commits[].change_type] | index("feature"))
  and ([.commits[].change_type] | index("bugfix-wip"))
  and ([.commits[].bucket] | index("crash"))
  and ([.commits[] | select(.bucket == "crash") | .crash.public_crash_url] | length == 3)
' "$JSON_OUT" >/dev/null

printf 'commit taxonomy release message fixture passed\n'
