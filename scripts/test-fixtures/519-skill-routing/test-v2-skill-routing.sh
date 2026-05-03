#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROUTE="$ROOT/scripts/v2-skill-route.sh"
RULES="$ROOT/core/v2/skills/routing-rules.yaml"
SCHEMA="$ROOT/core/v2/schemas/skill-routing-rules.schema.json"
TMPROOT=$(mktemp -d -t skill-routing-519.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$ROUTE" ] || fail "router is not executable"
[ -f "$RULES" ] || fail "missing routing rules"
[ -f "$SCHEMA" ] || fail "missing routing rules schema"

"$ROUTE" --validate-only >/dev/null || fail "default routing rules did not validate"
yq -o=json '.' "$RULES" >"$TMPROOT/rules.json"
check-jsonschema --schemafile "$SCHEMA" "$TMPROOT/rules.json" >/dev/null || fail "routing rules schema rejected default rules"

cat >"$TMPROOT/swiftui.json" <<'JSON'
{
  "agent": "achilles",
  "invocation_phase": "pre-edit",
  "task_type": "feature",
  "stack": "swift",
  "paths": ["Turnip/Editor/StickerView.swift"],
  "prompt": "Refactor the SwiftUI view body and @State usage for the sticker editor."
}
JSON

"$ROUTE" --context "$TMPROOT/swiftui.json" >"$TMPROOT/swiftui.out"
jq -e '.kind == "studio-v2-skill-routing-result" and .context.role == "worker"' "$TMPROOT/swiftui.out" >/dev/null || fail "result envelope or role normalization invalid"
jq -e '.skills | index("swiftui-pro") and index("swiftui-view-refactor")' "$TMPROOT/swiftui.out" >/dev/null || fail "SwiftUI view work did not route both SwiftUI skills"

cat >"$TMPROOT/reviewer-concurrency.json" <<'JSON'
{
  "role": "argus",
  "invocation_phase": "review",
  "task_type": "bugfix",
  "stack": "ios",
  "paths": ["Sources/Sync/UploadCoordinator.swift"],
  "prompt": "Review async Task cancellation and @MainActor isolation."
}
JSON

[ "$("$ROUTE" --context "$TMPROOT/reviewer-concurrency.json" --format names | tr '\n' ' ')" = "swift-concurrency-pro " ] || fail "reviewer concurrency context did not route exactly swift-concurrency-pro"

cat >"$TMPROOT/qa-tests.json" <<'JSON'
{
  "role": "qa-engineer",
  "invocation_phase": "plan",
  "task_type": "test-unit",
  "stack": "swift",
  "paths": ["Tests/EditorTests.swift"],
  "prompt": "Write Swift Testing @Test and #expect coverage for the editor."
}
JSON

"$ROUTE" --context "$TMPROOT/qa-tests.json" --format names | grep -Fxq "swift-testing-pro" || fail "qa test context did not route swift-testing-pro"

cat >"$TMPROOT/no-match.json" <<'JSON'
{
  "role": "release-manager",
  "invocation_phase": "release",
  "task_type": "release",
  "stack": "generic",
  "paths": ["RELEASES.md"],
  "prompt": "Draft release notes."
}
JSON

[ "$("$ROUTE" --context "$TMPROOT/no-match.json" | jq -r '.match_count')" = 0 ] || fail "unrelated release context should not match skill rules"

cat >"$TMPROOT/unknown-role.json" <<'JSON'
{"role": "unknown-role", "prompt": "SwiftUI"}
JSON

if "$ROUTE" --context "$TMPROOT/unknown-role.json" >"$TMPROOT/unknown.out" 2>"$TMPROOT/unknown.err"; then
  fail "unknown role routed successfully"
fi
grep -Fq "not a known Studio v2 role" "$TMPROOT/unknown.err" || fail "unknown role error was not explicit"

printf 'PASS: v2 intelligent skill routing\n'
