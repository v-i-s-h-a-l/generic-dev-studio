#!/usr/bin/env bash
# Verifies retryable origin/network halts coalesce and surface resume guidance.
# shellcheck disable=SC2034

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t retryable-halt-coalescing-767.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

helpers="$TMPROOT/halt-helpers.sh"
awk '
  /^halt_class_for_reason\(\)/ { capture=1 }
  /^supersede_completed_halt_records\(\)/ { capture=0 }
  capture { print }
' "$RUNNER" > "$helpers"

RUN_ID="019e0969-7670-7000-8000-000000000001"
CHAIN_RUN_ID="019e0969-7670-7000-8000-000000000002"
RUN_STATE_JSON="$TMPROOT/state.json"
RUN_REPORT="$TMPROOT/report.md"
HALT_ROOT="$TMPROOT/halt-records"
EVENTS_JSONL="$TMPROOT/events.jsonl"
SCRIPT_DIR="$ROOT/scripts"
EXECUTION_MODE="unattended"
DRY_RUN=0
RETRY_LIMIT=2
RETRY_BACKOFF_SEC=2
export STUDIO_CHAIN_RETRY_HALT_COOLDOWN_SEC=30
export STUDIO_CHAIN_RETRY_HALT_INSPECTION_COUNT=3
mkdir -p "$HALT_ROOT"
: > "$EVENTS_JSONL"

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "status": "failed",
  "halt_records": []
}
JSON

BASE_EPOCH=$(jq -nr '"2026-05-09T00:00:00Z" | fromdateiso8601')
ISO_COUNTER="$TMPROOT/iso-counter"
printf '0\n' > "$ISO_COUNTER"
iso_ts_now() {
  local idx
  idx=$(cat "$ISO_COUNTER")
  printf '%s\n' "$((idx + 1))" > "$ISO_COUNTER"
  jq -nr --argjson epoch "$((BASE_EPOCH + idx))" '$epoch | todateiso8601'
}

NOW_EPOCH="$BASE_EPOCH"
now_epoch() {
  printf '%s\n' "$NOW_EPOCH"
}

duration_since() {
  printf '0\n'
}

emit_chain_event() {
  : "${1:-}"
}

update_state_jq() {
  local filter tmp
  filter="${*: -1}"
  set -- "${@:1:$(($# - 1))}"
  tmp="$RUN_STATE_JSON.tmp.$$"
  jq "$@" --arg updated_at "$(iso_ts_now)" ".updated_at = \$updated_at | $filter" "$RUN_STATE_JSON" > "$tmp"
  mv "$tmp" "$RUN_STATE_JSON"
}

# shellcheck source=/dev/null
. "$helpers"

details_first=$(jq -cn '{
  origin:"git@github.com:Org/Repo.git",
  command:"git fetch git@github.com:Org/Repo.git",
  error:"Could not resolve host github.com at 2026-05-09T00:00:00Z for 11111111-1111-4111-8111-111111111111"
}')
first_file=$(write_halt_record network_partition "fetch origin failed" "$CHAIN_RUN_ID" "" "retry-fixture" "" parent-runner "$details_first")

details_second=$(jq -cn '{
  origin:"https://github.com/Org/Repo",
  command:"git fetch https://github.com/Org/Repo",
  error:"Could not resolve host github.com at 2026-05-09T00:00:45Z for 22222222-2222-4222-8222-222222222222"
}')
second_file=$(write_halt_record network_partition "fetch origin failed again" "$CHAIN_RUN_ID" "" "retry-fixture" "" parent-runner "$details_second")

[ "$first_file" = "$second_file" ] || fail "equivalent retryable halts wrote multiple files"

jq -e '
  (.halt_records | length) == 1
  and .halt_records[0].retry_count == 2
  and .halt_records[0].first_seen != null
  and .halt_records[0].last_seen != null
  and .halt_records[0].last_observed_command == "git fetch https://github.com/Org/Repo"
  and .halt_records[0].normalized_origin == "github.com/org/repo"
  and (.halt_records[0].normalized_error | contains("<timestamp>"))
  and (.halt_records[0].normalized_error | contains("<uuid>"))
  and .halt_records[0].retry_policy.cooldown_until != null
  and .halt_records[0].coalesce_key.scope_kind == "chain_run"
' "$RUN_STATE_JSON" >/dev/null || {
  cat "$RUN_STATE_JSON" >&2
  fail "run state did not coalesce equivalent retryable halt"
}

"$ROOT/scripts/validate-contract.sh" chain-halt-record "$first_file" >/dev/null
jq -e '
  .retry_count == 2
  and .first_seen != null
  and .last_seen != null
  and .last_observed_error != null
  and (.coalesced_observations | length) == 2
' "$first_file" >/dev/null || {
  cat "$first_file" >&2
  fail "coalesced halt artifact did not retain retry metadata"
}

NOW_EPOCH=$(jq -nr '"2026-05-09T00:00:10Z" | fromdateiso8601')
selected_active_halt_resume_guidance | grep -q 'Retry halt state: `cooling_down`' \
  || fail "resume guidance did not report cooling_down"

NOW_EPOCH=$(jq -nr '"2026-05-09T00:01:00Z" | fromdateiso8601')
selected_active_halt_resume_guidance | grep -q 'Retry halt state: `retrying`' \
  || fail "resume guidance did not report retrying after cooldown"

third_file=$(write_halt_record network_partition "fetch origin failed third time" "$CHAIN_RUN_ID" "" "retry-fixture" "" parent-runner "$details_second")
[ "$third_file" = "$first_file" ] || fail "third equivalent retryable halt did not coalesce"
selected_active_halt_resume_guidance | grep -q 'Retry halt state: `needs_human_inspection`' \
  || fail "resume guidance did not report needs_human_inspection at retry threshold"

for _ in 1 2 3 4 5; do
  write_halt_record network_partition "fetch origin kept failing" "$CHAIN_RUN_ID" "" "retry-fixture" "" parent-runner "$details_second" >/dev/null
done
jq -e '.retry_count == 8 and (.coalesced_observations | length) == 5' "$first_file" >/dev/null || {
  cat "$first_file" >&2
  fail "coalesced observation cap or retry count was wrong"
}

details_distinct=$(jq -cn '{
  origin:"https://github.com/Other/Repo",
  command:"git fetch https://github.com/Other/Repo",
  error:"Could not resolve host github.com"
}')
distinct_file=$(write_halt_record network_partition "fetch other origin failed" "$CHAIN_RUN_ID" "" "retry-fixture" "" parent-runner "$details_distinct")
[ "$distinct_file" != "$first_file" ] || fail "distinct retryable halt reused the first coalesced file"
jq -e '(.halt_records | length) == 2' "$RUN_STATE_JSON" >/dev/null || {
  cat "$RUN_STATE_JSON" >&2
  fail "distinct origin/error did not stay separate"
}

printf 'PASS: retryable halt coalescing and resume guidance\n'
