#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SCHEMA="$ROOT/_shared/schemas/release-attempt.md"
LIFECYCLE="$ROOT/_shared/state-machines/release-attempt-lifecycle.md"
EVENTS="$ROOT/_shared/contracts/events.md"
LIB_PATHS="$ROOT/scripts/lib-paths.sh"
LIB_LEDGER="$ROOT/scripts/lib-ledger.sh"
REBUILD_INDEX="$ROOT/scripts/rebuild-index.sh"
QUERY_PLANS="$ROOT/scripts/query-plans.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'release-attempt@1.0.0' "$SCHEMA" || fail "release attempt schema version missing"
grep -Fq 'plans/release-attempts/<attempt-id>.yaml' "$SCHEMA" || fail "schema missing artifact location"
grep -Fq 'transaction_log' "$SCHEMA" || fail "schema missing transaction log"
grep -Fq 'systems:' "$SCHEMA" || fail "schema missing system-of-record sub-documents"
grep -Fq 'content_sha256 unchanged' "$SCHEMA" || fail "schema missing release-notes short-circuit"

grep -Fq 'submitted   → withdrawn' "$LIFECYCLE" || fail "lifecycle missing submitted to withdrawn"
grep -Fq 'withdrawn   → resubmitted' "$LIFECYCLE" || fail "lifecycle missing withdrawn to resubmitted"
grep -Fq 'resubmitted → released' "$LIFECYCLE" || fail "lifecycle missing resubmitted to released"
grep -Fq 'append a `resume` transaction' "$LIFECYCLE" || fail "lifecycle missing resume transaction rule"

grep -Fq 'release_attempt_state_changed' "$EVENTS" || fail "events missing release attempt state change"
grep -Fq 'release_attempt_transaction_appended' "$EVENTS" || fail "events missing release attempt transaction append"
grep -Fq 'resolve_release_attempts_dir_for' "$LIB_PATHS" || fail "lib-paths missing release attempts resolver"
grep -Fq 'write_release_attempt_artifact' "$LIB_LEDGER" || fail "lib-ledger missing attempt writer"
grep -Fq 'append_release_attempt_transaction' "$LIB_LEDGER" || fail "lib-ledger missing transaction append helper"
grep -Fq 'transition_release_attempt_state' "$LIB_LEDGER" || fail "lib-ledger missing attempt transition helper"
grep -Fq 'release-attempts' "$REBUILD_INDEX" || fail "rebuild-index missing release attempts"

tmp_home=$(mktemp -d)
trap 'rm -rf "$tmp_home"' EXIT

attempt_id=0191aaab-9000-7f01-8aaa-77fe8fa99bbb
(
  export HOME="$tmp_home"
  export ACHILLES_PROJECT=release-attempt-fixture
  # shellcheck source=../../../scripts/lib-ledger.sh
  . "$LIB_LEDGER"
  write_release_attempt_artifact "$attempt_id" replace appstore '{"summary":"replace build 3047 with 3048","from_build":3047,"to_build":3048}' >/dev/null
  append_release_attempt_transaction "$attempt_id" side_effect_completed complete nabu '{"side_effect":"git.withdraw_tag"}' >/dev/null
  transition_release_attempt_state "$attempt_id" withdrawn nabu "withdrawal side effects complete"
  mkdir -p "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/feedback" "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/crashes"
  cat > "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/feedback/0191aaab-ffff-7777-aaaa-ffffffffffff.yaml" <<'YAML'
schema_version: {name: feedback, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 0191aaab-ffff-7777-aaaa-ffffffffffff
source: slack-thread
state: new
linked_tasks: []
YAML
  cat > "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/crashes/0191aaab-cccc-7777-aaaa-cccccccccccc.yaml" <<'YAML'
schema_version: {name: crash, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 0191aaab-cccc-7777-aaaa-cccccccccccc
state: new
linked_tasks: []
linked_feedback: []
YAML
)

attempt_file="$tmp_home/.dev-studio/release-attempt-fixture/plans/release-attempts/$attempt_id.yaml"
[ -f "$attempt_file" ] || fail "release attempt artifact was not written"
[ "$(yq -r '.state' "$attempt_file")" = "withdrawn" ] || fail "attempt did not transition to withdrawn"
[ "$(yq -r '.transaction_log | length' "$attempt_file")" -ge 3 ] || fail "transaction log did not append side effect and transition rows"
[ "$(yq -r '.transaction_log[-1].type' "$attempt_file")" = "transition" ] || fail "state transition was not recorded in transaction log"
[ "$(yq -r '.side_effects[] | select(.key == "git.withdraw_tag") | .status' "$attempt_file")" = "complete" ] || fail "side effect table was not updated for resume"
[ "$(yq -r '.intent.from_build' "$attempt_file")" = "3047" ] || fail "intent JSON was not persisted"

HOME="$tmp_home" ACHILLES_PROJECT=release-attempt-fixture "$REBUILD_INDEX" --project release-attempt-fixture >/dev/null
query_out=$(HOME="$tmp_home" ACHILLES_PROJECT=release-attempt-fixture "$QUERY_PLANS" --project release-attempt-fixture --kind=release-attempt --operation=replace --format=json)
[ "$(printf '%s\n' "$query_out" | yq -r '.state')" = "withdrawn" ] || fail "release attempt was not queryable from plans index"
feedback_out=$(HOME="$tmp_home" ACHILLES_PROJECT=release-attempt-fixture "$QUERY_PLANS" --project release-attempt-fixture --kind=feedback --source=slack-thread --format=json)
[ "$(printf '%s\n' "$feedback_out" | yq -r '.id')" = "0191aaab-ffff-7777-aaaa-ffffffffffff" ] || fail "feedback kind query regressed"
crash_out=$(HOME="$tmp_home" ACHILLES_PROJECT=release-attempt-fixture "$QUERY_PLANS" --project release-attempt-fixture --kind=crash --format=json)
[ "$(printf '%s\n' "$crash_out" | yq -r '.id')" = "0191aaab-cccc-7777-aaaa-cccccccccccc" ] || fail "crash kind alias query regressed"

printf 'PASS: release attempt state machine contract\n'
