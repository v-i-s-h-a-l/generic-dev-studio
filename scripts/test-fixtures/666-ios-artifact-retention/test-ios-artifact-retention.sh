#!/usr/bin/env bash
# Verifies scoped iOS artifact retention, pass cleanup, TTL sweep, and disk-pressure refusal.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
JANITOR="$ROOT/scripts/studio-ios-artifact-janitor.sh"
TMPROOT=$(mktemp -d -t ios-artifact-retention.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

seed_artifacts() {
  local root="$1" issue="$2" attempt="$3"
  mkdir -p \
    "$root/result-bundles/$issue/$attempt.xcresult" \
    "$root/logs/$issue" \
    "$root/summaries/$issue" \
    "$root/tmp/$issue/$attempt" \
    "$root/DerivedData/lanes/lane/cache-$attempt"
  printf 'result evidence\n' > "$root/result-bundles/$issue/$attempt.xcresult/Info.plist"
  printf 'summary extracted\n' > "$root/summaries/$issue/$attempt.summary.txt"
  printf 'large retained log\n' > "$root/logs/$issue/$attempt.log"
}

[ -x "$JANITOR" ] || fail "janitor script is not executable"

pass_root="$TMPROOT/pass"
seed_artifacts "$pass_root" "issue-pass" "1-build"
"$JANITOR" finalize-operation \
  --root "$pass_root" \
  --summary "$pass_root/summaries/issue-pass/1-build.summary.txt" \
  --result-bundle "$pass_root/result-bundles/issue-pass/1-build.xcresult" \
  --log "$pass_root/logs/issue-pass/1-build.log" \
  --tmp "$pass_root/tmp/issue-pass/1-build" \
  --derived-data "$pass_root/DerivedData/lanes/lane/cache-1-build" \
  --exit-code 0 \
  --operation build \
  --attempt 1-build \
  --issue-run-id issue-pass \
  --json > "$TMPROOT/pass.json"

[ ! -e "$pass_root/result-bundles/issue-pass/1-build.xcresult" ] || fail "passed result bundle was not deleted"
[ ! -e "$pass_root/logs/issue-pass/1-build.log" ] || fail "passed log was not deleted"
[ ! -e "$pass_root/tmp/issue-pass/1-build" ] || fail "passed tmp dir was not deleted"
[ -f "$pass_root/summaries/issue-pass/1-build.summary.txt" ] || fail "passed summary was not retained"
[ -d "$pass_root/DerivedData/lanes/lane/cache-1-build" ] || fail "passed DerivedData should not be task-cleaned"
jq -e '.status == "completed" and .paths_redacted == true and .counts.deleted >= 3' "$TMPROOT/pass.json" >/dev/null \
  || fail "pass cleanup telemetry missing expected redacted delete counts"
"$JANITOR" complete-chain --root "$pass_root" --status completed --json > "$TMPROOT/pass-chain.json"
[ ! -e "$pass_root" ] || fail "completed pass-only chain root should be deleted"
jq -e '.status == "completed" and .counts.deleted >= 1' "$TMPROOT/pass-chain.json" >/dev/null \
  || fail "complete-chain telemetry missing delete counts"

fail_root="$TMPROOT/fail"
seed_artifacts "$fail_root" "issue-fail" "1-test"
STUDIO_IOS_ARTIFACT_COMPRESS_MIN_BYTES=1 \
  "$JANITOR" finalize-operation \
    --root "$fail_root" \
    --summary "$fail_root/summaries/issue-fail/1-test.summary.txt" \
    --result-bundle "$fail_root/result-bundles/issue-fail/1-test.xcresult" \
    --log "$fail_root/logs/issue-fail/1-test.log" \
    --tmp "$fail_root/tmp/issue-fail/1-test" \
    --derived-data "$fail_root/DerivedData/lanes/lane/cache-1-test" \
    --exit-code 65 \
    --operation test \
    --attempt 1-test \
    --issue-run-id issue-fail \
    --json > "$TMPROOT/fail.json"

[ -d "$fail_root/result-bundles/issue-fail/1-test.xcresult" ] || fail "failed result bundle should be retained"
[ -f "$fail_root/logs/issue-fail/1-test.log.gz" ] || fail "failed log should be compressed and retained"
jq -e '.counts.retained >= 1 and .counts.compressed >= 1' "$TMPROOT/fail.json" >/dev/null \
  || fail "fail-retain telemetry missing retain/compress counts"
jq -e '.retention_class == "failed-retain" and (.expires_at | type == "string")' \
  "$fail_root/retention/issue-fail/1-test.json" >/dev/null \
  || fail "failed retention record missing class or expiry"

ttl_root="$TMPROOT/ttl"
seed_artifacts "$ttl_root" "issue-ttl" "1-test"
STUDIO_IOS_ARTIFACT_FAILED_TTL_HOURS=1 \
  "$JANITOR" finalize-operation \
    --root "$ttl_root" \
    --summary "$ttl_root/summaries/issue-ttl/1-test.summary.txt" \
    --result-bundle "$ttl_root/result-bundles/issue-ttl/1-test.xcresult" \
    --log "$ttl_root/logs/issue-ttl/1-test.log" \
    --tmp "$ttl_root/tmp/issue-ttl/1-test" \
    --derived-data "$ttl_root/DerivedData/lanes/lane/cache-1-test" \
    --exit-code 65 \
    --operation test \
    --attempt 1-test \
    --issue-run-id issue-ttl \
    --now-epoch 1000 \
    --json > "$TMPROOT/ttl-finalize.json"
"$JANITOR" sweep --root "$ttl_root" --now-epoch 10000 --json > "$TMPROOT/ttl-sweep.json"
[ ! -e "$ttl_root/result-bundles/issue-ttl/1-test.xcresult" ] || fail "expired result bundle was not swept"
[ ! -e "$ttl_root/DerivedData/lanes/lane/cache-1-test" ] || fail "expired DerivedData was not swept"
[ ! -e "$ttl_root/retention/issue-ttl/1-test.json" ] || fail "expired retention record was not swept"
jq -e '.counts.deleted >= 4 and .bytes_freed > 0' "$TMPROOT/ttl-sweep.json" >/dev/null \
  || fail "TTL sweep telemetry missing delete counts"

pressure_root="$TMPROOT/pressure"
seed_artifacts "$pressure_root" "issue-pressure" "1-test"
set +e
STUDIO_IOS_ARTIFACT_MIN_FREE_KB=999999999999 \
  "$JANITOR" sweep --root "$pressure_root" --json > "$TMPROOT/pressure.json"
pressure_rc=$?
set -e
[ "$pressure_rc" -eq 75 ] || fail "disk-pressure refusal should exit 75"
jq -e '.status == "refused_disk_pressure" and .counts.refused == 1 and .paths_redacted == true' "$TMPROOT/pressure.json" >/dev/null \
  || fail "disk-pressure telemetry missing refusal status"
[ -d "$pressure_root/result-bundles/issue-pressure/1-test.xcresult" ] || fail "disk-pressure refusal should not delete artifacts"

printf 'PASS: iOS artifact retention janitor\n'
