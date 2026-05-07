#!/usr/bin/env bash
# Verifies Studio v2 project-profile validation and operation resolution.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/v2-profile.sh"
TMPROOT=$(mktemp -d -t v2-profile-524.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

arg_after() {
  local flag="$1" args_file="$2"
  awk -v flag="$flag" 'previous == flag { print; exit } { previous = $0 }' "$args_file"
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

BIN="$TMPROOT/bin"
PROJECT="$TMPROOT/FixtureProject"
ARTIFACT_ROOT="$TMPROOT/artifacts"
mkdir -p "$BIN" "$PROJECT/Fixture.xcodeproj"

cat > "$BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -eu
[ -n "${XCODEBUILD_CAPTURE:-}" ] || {
  printf 'XCODEBUILD_CAPTURE is required\n' >&2
  exit 2
}
printf '%s\0' "$@" > "$XCODEBUILD_CAPTURE"
printf '** BUILD SUCCEEDED **\n'
SH
chmod +x "$BIN/xcodebuild"

capture="$TMPROOT/xcodebuild-build.args0"
PATH="$BIN:$PATH" XCODEBUILD_CAPTURE="$capture" \
  STUDIO_PROJECT_ROOT="$PROJECT" \
  STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
  STUDIO_IOS_SCHEME="Fixture" \
  STUDIO_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" \
  STUDIO_IOS_LANE_ID="lane 1" \
  STUDIO_IOS_ISSUE_RUN_ID="issue-run-524" \
  STUDIO_IOS_ARTIFACT_ATTEMPT="2" \
  "$ROOT/profiles/ios-turnip/commands/xcode-operation" build >/dev/null

tr '\0' '\n' < "$capture" > "$TMPROOT/xcodebuild-build.args"
derived_path=$(arg_after -derivedDataPath "$TMPROOT/xcodebuild-build.args")
result_path=$(arg_after -resultBundlePath "$TMPROOT/xcodebuild-build.args")

case "$derived_path" in
  "$ARTIFACT_ROOT/DerivedData/lanes/lane-1/"*) ;;
  *) fail "build DerivedData path was not lane-scoped: $derived_path" ;;
esac
[ "$result_path" = "$ARTIFACT_ROOT/result-bundles/issue-run-524/2-build.xcresult" ] \
  || fail "build result bundle path was not issue/attempt scoped: $result_path"
grep -qx -- "-scheme" "$TMPROOT/xcodebuild-build.args" || fail "scheme flag missing from build command"
grep -qx -- "Fixture" "$TMPROOT/xcodebuild-build.args" || fail "scheme value missing from build command"
grep -qx -- "build" "$TMPROOT/xcodebuild-build.args" || fail "build action missing from build command"
if grep -q '/tmp/argus-\|/tmp/derived-data' "$TMPROOT/xcodebuild-build.args"; then
  cat "$TMPROOT/xcodebuild-build.args" >&2
  fail "build command leaked legacy global artifact paths"
fi
[ -f "$ARTIFACT_ROOT/logs/issue-run-524/2-build.log" ] || fail "build log was not written under artifact root"
[ -f "$ARTIFACT_ROOT/summaries/issue-run-524/2-build.summary.txt" ] || fail "build summary was not written under artifact root"
jq -e '
  .schema_version == 1
  and .kind == "studio-ios-derived-data-cache"
  and .cache_state == "cold_missing_inputs"
  and (.missing_inputs | index("xcode_version"))
  and (.paths.derived_data_path | test("/DerivedData/lanes/lane-1/"))
' "$derived_path.metadata.json" >/dev/null || fail "DerivedData metadata did not fail closed on missing cache inputs"

stable_capture_one="$TMPROOT/xcodebuild-stable-1.args0"
stable_capture_two="$TMPROOT/xcodebuild-stable-2.args0"
stable_env() {
  local capture_file="$1"
  shift
  PATH="$BIN:$PATH" \
  XCODEBUILD_CAPTURE="$capture_file" \
  STUDIO_PROJECT_ROOT="$PROJECT" \
  STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT/stable" \
  STUDIO_IOS_SCHEME="Fixture" \
  STUDIO_IOS_CONFIGURATION="Debug" \
  STUDIO_IOS_SDK="iphonesimulator" \
  STUDIO_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" \
  STUDIO_IOS_XCODE_VERSION="Xcode 16.4" \
  STUDIO_IOS_SIMULATOR_RUNTIME="iOS 18.4" \
  STUDIO_IOS_DEVICE_CLASS="iPhone 16" \
  STUDIO_IOS_PACKAGE_GRAPH_HASH="package-graph-hash" \
  STUDIO_IOS_BUILD_SETTINGS_HASH="build-settings-hash" \
  STUDIO_IOS_SOURCE_BRANCH="main" \
  STUDIO_IOS_BASE_COMMIT="base-sha" \
  STUDIO_IOS_WORKTREE_COMMIT="worktree-sha" \
  STUDIO_IOS_EXECUTOR_ID="executor-1" \
  STUDIO_IOS_PATH_SENSITIVITY="project-root-sha256:test" \
  "$@"
}
stable_env "$stable_capture_one" "$ROOT/profiles/ios-turnip/commands/xcode-operation" build >/dev/null
stable_env "$stable_capture_two" "$ROOT/profiles/ios-turnip/commands/xcode-operation" build >/dev/null
tr '\0' '\n' < "$stable_capture_one" > "$TMPROOT/xcodebuild-stable-1.args"
tr '\0' '\n' < "$stable_capture_two" > "$TMPROOT/xcodebuild-stable-2.args"
stable_derived_one=$(arg_after -derivedDataPath "$TMPROOT/xcodebuild-stable-1.args")
stable_derived_two=$(arg_after -derivedDataPath "$TMPROOT/xcodebuild-stable-2.args")
[ "$stable_derived_one" = "$stable_derived_two" ] || fail "matching cache metadata did not reuse stable DerivedData path"
jq -e '
  .cache_state == "stable"
  and .missing_inputs == []
  and .inputs.xcode_version == "Xcode 16.4"
  and .inputs.sdk == "iphonesimulator"
' "$stable_derived_one.metadata.json" >/dev/null || fail "stable DerivedData metadata did not record required cache inputs"

mkdir -p "$PROJECT/.studio"
cat > "$PROJECT/.studio/chain-task-start.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "start",
  "run_id": "run-envelope-524",
  "chain_run_id": "chain-envelope-524",
  "issue_run_id": "issue-envelope-524",
  "ownership": {
    "source_branch": "main"
  }
}
JSON
capture="$TMPROOT/xcodebuild-envelope.args0"
PATH="$BIN:$PATH" TMPDIR="$TMPROOT/tmp/" XCODEBUILD_CAPTURE="$capture" \
  STUDIO_PROJECT_ROOT="$PROJECT" \
  STUDIO_IOS_SCHEME="Fixture" \
  STUDIO_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" \
  "$ROOT/profiles/ios-turnip/commands/xcode-operation" test-unit >/dev/null
tr '\0' '\n' < "$capture" > "$TMPROOT/xcodebuild-envelope.args"
result_path=$(arg_after -resultBundlePath "$TMPROOT/xcodebuild-envelope.args")
[ "$result_path" = "$TMPROOT/tmp/studio-ios-artifacts/run-envelope-524/result-bundles/issue-envelope-524/1-test-unit.xcresult" ] \
  || fail "envelope-derived result path was not run/issue scoped: $result_path"
grep -qx -- "test" "$TMPROOT/xcodebuild-envelope.args" || fail "test action missing from test-unit command"

capture="$TMPROOT/xcodebuild-override.args0"
PATH="$BIN:$PATH" XCODEBUILD_CAPTURE="$capture" \
  STUDIO_PROJECT_ROOT="$PROJECT" \
  STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
  STUDIO_IOS_DERIVED_DATA_PATH="$ARTIFACT_ROOT/debug/DerivedData" \
  STUDIO_IOS_RESULT_BUNDLE_PATH="$ARTIFACT_ROOT/debug/result.xcresult" \
  STUDIO_IOS_LOG_PATH="$ARTIFACT_ROOT/debug/build.log" \
  STUDIO_IOS_SUMMARY_PATH="$ARTIFACT_ROOT/debug/build.summary.txt" \
  STUDIO_IOS_SCHEME="Fixture" \
  "$ROOT/profiles/ios-turnip/commands/xcode-operation" build >/dev/null
tr '\0' '\n' < "$capture" > "$TMPROOT/xcodebuild-override.args"
[ "$(arg_after -derivedDataPath "$TMPROOT/xcodebuild-override.args")" = "$ARTIFACT_ROOT/debug/DerivedData" ] \
  || fail "debug DerivedData override was not honored"
[ "$(arg_after -resultBundlePath "$TMPROOT/xcodebuild-override.args")" = "$ARTIFACT_ROOT/debug/result.xcresult" ] \
  || fail "debug result bundle override was not honored"
[ -f "$ARTIFACT_ROOT/debug/build.log" ] || fail "debug log override was not honored"
[ -f "$ARTIFACT_ROOT/debug/build.summary.txt" ] || fail "debug summary override was not honored"

if PATH="$BIN:$PATH" XCODEBUILD_CAPTURE="$TMPROOT/rejected.args0" \
  STUDIO_PROJECT_ROOT="$PROJECT" STUDIO_IOS_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
  "$ROOT/profiles/ios-turnip/commands/xcode-operation" build -derivedDataPath /tmp/leak \
  >"$TMPROOT/rejected.out" 2>"$TMPROOT/rejected.err"; then
  fail "raw DerivedData xcodebuild arg should be rejected"
fi
grep -q 'STUDIO_IOS_DERIVED_DATA_PATH' "$TMPROOT/rejected.err" || {
  cat "$TMPROOT/rejected.err" >&2
  fail "raw DerivedData rejection did not name override env"
}

if "$RUN" --profile ios-turnip --operation does-not-exist --dry-run >"$TMPROOT/v2-profile-missing.out" 2>"$TMPROOT/v2-profile-missing.err"; then
  fail "unknown operation should fail"
fi
grep -q 'operation not defined' "$TMPROOT/v2-profile-missing.err" || {
  cat "$TMPROOT/v2-profile-missing.err" >&2
  fail "unknown operation error not actionable"
}

printf 'PASS: v2 project profile resolver\n'
