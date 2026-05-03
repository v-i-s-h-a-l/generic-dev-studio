#!/usr/bin/env bash
# Regression coverage for Argus diff classification and selective rule loading.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t argus-classifier.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

CLASSIFY="$ROOT/scripts/argus-classify-diff.sh"
SELECT="$ROOT/scripts/argus-select-rules.sh"
RULES="$ROOT/core/v2/reviewer/rules"

assertions=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  label="$1"
  json="$2"
  filter="$3"
  assertions=$((assertions + 1))
  printf '%s' "$json" | jq -e "$filter" >/dev/null || fail "$label"
}

run_case() {
  name="$1"
  diff_file="$TMPROOT/$name.diff"
  json_file="$TMPROOT/$name.json"
  selection_file="$TMPROOT/$name-selection.json"
  cat > "$diff_file"
  "$CLASSIFY" "$diff_file" > "$json_file"
  "$SELECT" "$(cat "$json_file")" "$RULES" > "$selection_file"
  printf '%s\n' "$json_file:$selection_file"
}

paths=$(run_case backend <<'DIFF'
diff --git a/Sources/AuthClient.swift b/Sources/AuthClient.swift
--- a/Sources/AuthClient.swift
+++ b/Sources/AuthClient.swift
@@ -1,3 +1,6 @@
+final class AuthClient {
+  func load() async throws {
+    _ = try await URLSession.shared.data(from: URL(string: "https://example.com")!)
+  }
+}
DIFF
)
backend_json=${paths%%:*}
backend_selection=${paths#*:}
assert_jq "backend detects security/io/concurrency" "$(cat "$backend_json")" '.touches_security and .touches_io and .touches_concurrency'
assert_jq "backend skips SwiftUI packs" "$(cat "$backend_selection")" '.skipped | index("swiftui")'
assert_jq "backend keeps secrets pack" "$(cat "$backend_selection")" '.load | index("secrets")'

paths=$(run_case tests_only <<'DIFF'
diff --git a/Tests/AuthClientTests.swift b/Tests/AuthClientTests.swift
--- a/Tests/AuthClientTests.swift
+++ b/Tests/AuthClientTests.swift
@@ -1,2 +1,5 @@
+@Test func parsesEmptyResponse() {
+  #expect(parse("") == nil)
+}
DIFF
)
tests_json=${paths%%:*}
tests_selection=${paths#*:}
assert_jq "tests-only classification is true" "$(cat "$tests_json")" '.touches_test_only == true'
assert_jq "tests-only skips production adequacy" "$(cat "$tests_selection")" '.skipped | index("test-adequacy") and index("cross-file-regression") and index("edge-cases")'
assert_jq "tests-only still keeps baseline packs" "$(cat "$tests_selection")" '.load | index("base-staleness") and index("diff-anomalies")'
assert_jq "tests-only still keeps secrets scan" "$(cat "$tests_selection")" '.load | index("secrets")'

paths=$(run_case a11y <<'DIFF'
diff --git a/App/ProfileView.swift b/App/ProfileView.swift
--- a/App/ProfileView.swift
+++ b/App/ProfileView.swift
@@ -1,5 +1,7 @@
 import SwiftUI
 struct ProfileView: View {
   var body: some View {
+    Text("Save").accessibilityLabel("Save profile")
   }
 }
DIFF
)
a11y_json=${paths%%:*}
a11y_selection=${paths#*:}
assert_jq "a11y detects view and accessibility" "$(cat "$a11y_json")" '.touches_a11y and .touches_views and .touches_swiftui'
assert_jq "a11y loads a11y and SwiftUI packs" "$(cat "$a11y_selection")" '.load | index("a11y") and index("swiftui")'

paths=$(run_case mixed <<'DIFF'
diff --git a/App/FeedView.swift b/App/FeedView.swift
--- a/App/FeedView.swift
+++ b/App/FeedView.swift
@@ -1,4 +1,8 @@
 import SwiftUI
 struct FeedView: View {
+  @State private var title = ""
+  var body: some View { Text(title).task { await refresh() } }
+  func refresh() async { _ = try? await URLSession.shared.data(from: URL(string: "https://example.com")!) }
 }
DIFF
)
mixed_json=${paths%%:*}
assert_jq "mixed output is stable" "$(cat "$mixed_json")" '.touches_swiftui and .touches_concurrency and .touches_io and .diff_size_class == "XS"'

printf 'PASS: %d assertions\n' "$assertions"
