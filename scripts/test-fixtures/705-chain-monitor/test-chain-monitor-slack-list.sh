#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/705-chain-monitor"
MOCK_API="$FIXTURE_DIR/fixtures/mock-slack-lists-api.sh"
TMPROOT=$(mktemp -d -t chain-monitor-slack-list.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

command -v jq >/dev/null 2>&1 || { printf 'skip: jq required\n' >&2; exit 0; }

# shellcheck source=../../../scripts/lib-chain-monitor-slack-list.sh disable=SC1091
. "$ROOT/scripts/lib-chain-monitor-slack-list.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  local name="$1" file="$2" filter="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$name"
}

run_reconcile() {
  local summary_path="$1"
  local rc
  shift
  chain_monitor_slack_list_reconcile_json "$@" > "$summary_path"
  rc=$?
  return "$rc"
}

write_alpha_desired() {
  local output_path="$1" task_summary="${2:-Reconcile monitor state}" chain_status="${3:-running}" task_status="${4:-queued}"
  jq -n \
    --arg chain_status "$chain_status" \
    --arg task_status "$task_status" \
    --arg task_summary "$task_summary" \
    '{
      schema_version: 1,
      rows: [
        {
          schema_version: 1,
          row_key: "chain:repo-manifest:fixture:alpha",
          row_type: "chain",
          source: {kind:"repo-manifest", id:"fixture", precedence:3},
          fields: {
            title: "alpha",
            status: $chain_status,
            manifest: "fixture.yaml",
            summary: "Chain alpha",
            progress: "0/1 completed",
            blocker: ""
          }
        },
        {
          schema_version: 1,
          row_key: "task:chain:repo-manifest:fixture:alpha:issue:728",
          row_type: "task",
          parent_row_key: "chain:repo-manifest:fixture:alpha",
          source: {kind:"repo-manifest", id:"fixture", precedence:3},
          fields: {
            title: "Issue #728",
            status: $task_status,
            manifest: "fixture.yaml",
            summary: $task_summary,
            progress: "",
            blocker: ""
          }
        }
      ]
    }' > "$output_path"
}

write_legacy_desired() {
  local output_path="$1"
  jq -n '{
    schema_version: 1,
    rows: [{
      schema_version: 1,
      row_key: "chain:repo-manifest:fixture:legacy-chain",
      row_type: "chain",
      source: {kind:"repo-manifest", id:"fixture", precedence:3},
      fields: {
        title: "legacy-chain",
        status: "running",
        manifest: "fixture.yaml",
        summary: "Mapped from live title",
        progress: "live",
        blocker: ""
      }
    }]
  }' > "$output_path"
}

reset_mock() {
  local store_path="$1" log_path="$2" active_json="${3:-[]}"
  jq -n --argjson active "$active_json" '{
    schema_version: 1,
    next_id: 1,
    active: $active,
    archived: [],
    failures: []
  }' > "$store_path"
  : > "$log_path"
}

OWNER_HOME="$TMPROOT/owner-home"
OWNER_PROJECT="generic-dev-studio"
LIST_ID="FCHAINMONITOR"
NOW=1778191200
mkdir -p "$OWNER_HOME"

export STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND="$MOCK_API"
export CHAIN_MONITOR_SLACK_LIST_MOCK_STORE="$TMPROOT/mock-store.json"
export CHAIN_MONITOR_SLACK_LIST_MOCK_LOG="$TMPROOT/mock.log"

desired="$TMPROOT/desired-alpha.json"
write_alpha_desired "$desired"
state="$TMPROOT/state.json"
summary="$TMPROOT/summary.json"
reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"

run_reconcile "$summary" \
  --desired "$desired" \
  --state "$state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "alpha-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "initial reconcile failed"

assert_jq "initial reconcile creates parent and child" "$summary" '.bootstrapped_from_live == true and .writes.create == 2 and (.failed | length) == 0'
jq -s -e '
  [.[].method] == ["slackLists.items.list","slackLists.items.create","slackLists.items.create"]
  and .[2].payload.parent_item_id == "Rec0001"
' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "children were not created after parent rows"
expected_fields=$(chain_monitor_slack_list_closed_field_keys_json)
jq -s -e --argjson expected "$expected_fields" '
  (.[1].payload.initial_fields | map(.column_id)) == $expected
' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "Slack payload did not use closed monitor field set"
jq -e --argjson expected "$expected_fields" '
  .schema_version == 1
  and .list_id == "FCHAINMONITOR"
  and .owner_home != ""
  and (.rows | length) == 2
  and all(.rows[]; (.display_fields | keys) == ($expected | sort))
  and all(.rows[]; (.source_fields.kind // "") == "repo-manifest")
  and all(.rows[]; (.last_synced_hash // "") != "")
  and all(.rows[]; (.row_id_history // []) == [])
' "$state" >/dev/null || fail "state did not persist the required row fields"

before_log_lines=$(wc -l < "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" | tr -d ' ')
run_reconcile "$summary" \
  --desired "$desired" \
  --state "$state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "alpha-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "idempotent reconcile failed"
after_log_lines=$(wc -l < "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" | tr -d ' ')
[ "$before_log_lines" = "$after_log_lines" ] || fail "idempotent reconcile performed Slack API calls"
assert_jq "idempotent reconcile has no writes" "$summary" '.writes == {create:0,update:0,archive:0} and .noops == 2 and (.failed | length) == 0'
cp "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$TMPROOT/alpha-store-after-idempotence.json"

partial_state="$TMPROOT/partial-state.json"
partial_summary="$TMPROOT/partial-summary.json"
reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
jq '.failures = [{method:"slackLists.items.create", row_key:"task:chain:repo-manifest:fixture:alpha:issue:728", error:"mock_create_failed"}]' \
  "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" > "$TMPROOT/mock-store.next"
mv "$TMPROOT/mock-store.next" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE"
if run_reconcile "$partial_summary" \
  --desired "$desired" \
  --state "$partial_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "alpha-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10; then
  fail "partial failure unexpectedly returned success"
fi
assert_jq "partial failure reports failed create" "$partial_summary" 'any(.failed[]; .row_key == "task:chain:repo-manifest:fixture:alpha:issue:728" and .error == "mock_create_failed")'
assert_jq "partial failure preserves successful parent row only" "$partial_state" '
  (.rows | length) == 1
  and .rows[0].row_key == "chain:repo-manifest:fixture:alpha"
  and .rows[0].row_id == "Rec0001"
  and (.rows[0].last_synced_hash // "") != ""
'

legacy_desired="$TMPROOT/legacy-desired.json"
legacy_state="$TMPROOT/legacy-state.json"
write_legacy_desired "$legacy_desired"
jq -n '{
  schema_version: 1,
  list_id: "FCHAINMONITOR",
  owner_home: "/wrong/home",
  owner_project: "generic-dev-studio",
  source_fingerprint: "old",
  rows: [{row_id:"Bogus", row_key:"chain:wrong", status:"running"}]
}' > "$legacy_state"
legacy_active='[{
  "id":"RecLegacy1",
  "list_id":"FCHAINMONITOR",
  "fields":{
    "title":"legacy-chain",
    "status":"running",
    "manifest":"legacy",
    "summary":"old live row",
    "progress":"live",
    "blocker":""
  },
  "saved":{"is_archived":false}
}]'
reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" "$legacy_active"
run_reconcile "$summary" \
  --desired "$legacy_desired" \
  --state "$legacy_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "legacy-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "legacy live-row mapping failed"
jq -s -e '
  [.[].method] == ["slackLists.items.list","slackLists.items.update"]
  and .[1].payload.row_key == "chain:repo-manifest:fixture:legacy-chain"
' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "legacy live row was not updated in place"
assert_jq "wrong-home state bootstraps from live and maps legacy row id" "$legacy_state" '
  .owner_home != "/wrong/home"
  and .rows[0].row_key == "chain:repo-manifest:fixture:legacy-chain"
  and .rows[0].row_id == "RecLegacy1"
'

changed="$TMPROOT/desired-alpha-changed.json"
write_alpha_desired "$changed" "Changed summary"
state="$TMPROOT/state.json"
cp "$TMPROOT/alpha-store-after-idempotence.json" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE"
: > "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
jq '.failures = [{method:"slackLists.items.update", row_key:"task:chain:repo-manifest:fixture:alpha:issue:728", error:"uneditable_column"}]' \
  "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" > "$TMPROOT/mock-store.next"
mv "$TMPROOT/mock-store.next" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE"
run_reconcile "$summary" \
  --desired "$changed" \
  --state "$state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "alpha-v2" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "recreate fallback failed"
jq -s -e '
  [.[].method] == ["slackLists.items.update","slackLists.items.create","slackLists.items.delete"]
  and .[0].payload.row_key == "task:chain:repo-manifest:fixture:alpha:issue:728"
  and .[1].payload.row_key == "task:chain:repo-manifest:fixture:alpha:issue:728"
  and .[2].payload.row_id == "Rec0002"
' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "recreate fallback did not isolate the changed row"
assert_jq "recreate fallback preserves row-id history" "$state" '
  any(.rows[]; .row_key == "task:chain:repo-manifest:fixture:alpha:issue:728"
    and .row_id == "Rec0003"
    and (.row_id_history | index("Rec0002")))
'
assert_jq "recreate fallback archived old live row" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" '
  any(.archived[]; .id == "Rec0002")
  and any(.active[]; .id == "Rec0003")
'

archive_desired="$TMPROOT/archive-desired.json"
write_alpha_desired "$archive_desired" "Reconcile monitor state" "archived" "archived"
archive_state="$TMPROOT/archive-state.json"
archive_store_active='[{
  "id":"RecArchive1",
  "list_id":"FCHAINMONITOR",
  "row_key":"chain:repo-manifest:fixture:alpha",
  "fields":{
    "title":"alpha",
    "status":"completed",
    "manifest":"fixture.yaml",
    "summary":"Chain alpha",
    "progress":"1/1 completed",
    "blocker":""
  },
  "saved":{"is_archived":false}
}]'
reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" "$archive_store_active"
jq -n --arg owner_home "$OWNER_HOME" '{
  schema_version: 1,
  list_id: "FCHAINMONITOR",
  owner_home: $owner_home,
  owner_project: "generic-dev-studio",
  source_fingerprint: "archive-old",
  rows: [{
    row_id: "RecArchive1",
    row_key: "chain:repo-manifest:fixture:alpha",
    parent_row_key: null,
    source_fields: {kind:"repo-manifest", id:"fixture", precedence:3},
    display_fields: {title:"alpha", status:"completed", manifest:"fixture.yaml", summary:"Chain alpha", progress:"1/1 completed", blocker:""},
    status: "completed",
    activity_timestamp: 1778191100,
    last_synced_hash: "old",
    row_id_history: []
  }]
}' > "$archive_state"
run_reconcile "$summary" \
  --desired "$archive_desired" \
  --state "$archive_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "archive-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "completed-row archive failed"
jq -s -e '[.[].method] == ["slackLists.items.delete"]' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "archived desired row did not use archive/delete row operation"
assert_jq "completed row is marked archived in state" "$archive_state" 'any(.rows[]; .row_key == "chain:repo-manifest:fixture:alpha" and .status == "archived" and .archived_at == 1778191200)'
before_log_lines=$(wc -l < "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" | tr -d ' ')
run_reconcile "$summary" \
  --desired "$archive_desired" \
  --state "$archive_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "archive-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "archived idempotence failed"
after_log_lines=$(wc -l < "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" | tr -d ' ')
[ "$before_log_lines" = "$after_log_lines" ] || fail "already archived rows caused repeat Slack writes"

orphan_state="$TMPROOT/orphan-state.json"
empty_desired="$TMPROOT/empty-desired.json"
jq -n '{schema_version:1, rows:[]}' > "$empty_desired"
orphan_active='[{
  "id":"RecOrphan1",
  "list_id":"FCHAINMONITOR",
  "row_key":"orphan:RecOrphan1",
  "fields":{"title":"old","status":"running","manifest":"","summary":"","progress":"","blocker":""},
  "saved":{"is_archived":false}
}]'
reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" "$orphan_active"
jq -n --arg owner_home "$OWNER_HOME" '{
  schema_version: 1,
  list_id: "FCHAINMONITOR",
  owner_home: $owner_home,
  owner_project: "generic-dev-studio",
  source_fingerprint: "orphan-old",
  rows: [{
    row_id: "RecOrphan1",
    row_key: "orphan:RecOrphan1",
    parent_row_key: null,
    source_fields: {kind:"slack-live", id:"FCHAINMONITOR", precedence:99},
    display_fields: {title:"old", status:"running", manifest:"", summary:"", progress:"", blocker:""},
    status: "running",
    activity_timestamp: 1778191100,
    last_synced_hash: null,
    row_id_history: []
  }]
}' > "$orphan_state"
run_reconcile "$summary" \
  --desired "$empty_desired" \
  --state "$orphan_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "orphan-v1" \
  --now-epoch "$NOW" \
  --archive-retention-s 10 || fail "orphan stale marking failed"
[ ! -s "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" ] || fail "fresh orphan was deleted before retention"
assert_jq "orphan is stale candidate first" "$orphan_state" '.rows[0].status == "stale" and .rows[0].orphan == true and .rows[0].orphaned_at == 1778191200'
run_reconcile "$summary" \
  --desired "$empty_desired" \
  --state "$orphan_state" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "orphan-v2" \
  --now-epoch "$((NOW + 11))" \
  --archive-retention-s 10 || fail "orphan retention archive failed"
jq -s -e '[.[].method] == ["slackLists.items.delete"]' "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" >/dev/null || fail "retained orphan was not archived"
assert_jq "retained orphan is archived in state" "$orphan_state" '.rows[0].status == "archived" and .rows[0].archived_at == 1778191211'

rewrite_summary="$TMPROOT/rewrite-summary.json"
if run_reconcile "$rewrite_summary" \
  --desired "$desired" \
  --state "$TMPROOT/rewrite-state.json" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "rewrite-v1" \
  --now-epoch "$NOW" \
  --full-rewrite; then
  fail "full rewrite was allowed in the normal sync path"
fi
assert_jq "full rewrite requires recovery flag" "$rewrite_summary" '.error == "full_rewrite_requires_explicit_recovery_flag"'
: > "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
STUDIO_CHAIN_MONITOR_IMPORT_RECOVERY=1 run_reconcile "$rewrite_summary" \
  --desired "$desired" \
  --state "$TMPROOT/rewrite-state.json" \
  --list-id "$LIST_ID" \
  --owner-home "$OWNER_HOME" \
  --owner-project "$OWNER_PROJECT" \
  --source-fingerprint "rewrite-v1" \
  --now-epoch "$NOW" \
  --dry-run \
  --full-rewrite || fail "recovery full-rewrite dry-run summary failed"
assert_jq "full rewrite recovery is dry-run summary only" "$rewrite_summary" '.recovery.full_rewrite == true and .recovery.dry_run_only == true and .recovery.would_create_count == 2'
[ ! -s "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" ] || fail "full rewrite dry-run touched Slack mock"

if grep -Eq 'slackLists\.items\.deleteMultiple|full.*rewrite.*slackLists\.items\.delete' "$ROOT/scripts/lib-chain-monitor-slack-list.sh"; then
  fail "normal reconciler contains a bulk active List rewrite path"
fi

bash -n "$ROOT/scripts/lib-chain-monitor-slack-list.sh"
zsh_summary="$TMPROOT/zsh-summary.json"
zsh -c ". '$ROOT/scripts/lib-chain-monitor-slack-list.sh' && chain_monitor_slack_list_reconcile_json --desired '$legacy_desired' --state '$TMPROOT/zsh-state.json' --list-id '$LIST_ID' --owner-home '$OWNER_HOME' --owner-project '$OWNER_PROJECT' --source-fingerprint zsh --now-epoch '$NOW' --dry-run > '$zsh_summary'"
assert_jq "zsh-sourced reconciler emits valid dry-run summary" "$zsh_summary" '.dry_run == true and .would_fetch_live == true'

printf 'PASS: chain monitor Slack List reconciler\n'
