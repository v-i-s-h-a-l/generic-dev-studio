#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/705-chain-monitor"
MOCK_API="$FIXTURE_DIR/fixtures/mock-slack-lists-api.sh"
MANAGER="$ROOT/scripts/manager-chain-monitor.sh"
SCHEDULER="$ROOT/scripts/schedule-chain-monitor.sh"
TMPROOT=$(mktemp -d -t chain-monitor-front-doors.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

command -v jq >/dev/null 2>&1 || { printf 'skip: jq required\n' >&2; exit 0; }

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  local name="$1" file="$2"
  shift 2
  jq -e "$@" "$file" >/dev/null || fail "$name"
}

snapshot_tree() {
  local root="$1"
  if [ -d "$root" ]; then
    find "$root" -mindepth 1 -print | sort
  fi
}

RUN_STATE="$FIXTURE_DIR/fixtures/persisted-run-state.json"
LIST_ID="FCHAINMONITOR"
ARCHIVED_LIST_ID="FCHAINARCHIVE"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/synthetic"
mkdir -p "$LOGIN_HOME" "$SYNTH_HOME"

status_before="$TMPROOT/status-before.txt"
status_after="$TMPROOT/status-after.txt"
status_json="$TMPROOT/status.json"
snapshot_tree "$LOGIN_HOME" > "$status_before"
HOME="$SYNTH_HOME" "$MANAGER" status \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --json \
  --no-discover \
  --persisted-run "$RUN_STATE" \
  --list-id "$LIST_ID" \
  --archived-list-id "$ARCHIVED_LIST_ID" > "$status_json"
snapshot_tree "$LOGIN_HOME" > "$status_after"
cmp "$status_before" "$status_after" >/dev/null || fail "status mutated login-home state"
assert_jq "status reports owner and non-secret counts" "$status_json" \
  --arg owner "$LOGIN_HOME" --arg list "$LIST_ID" '
    .owner_home == $owner
    and .owner_project == "generic-dev-studio"
    and (.state_path | startswith($owner + "/.dev-studio/generic-dev-studio/.runtime/state/"))
    and .list_id == $list
    and .archived_list_id == "FCHAINARCHIVE"
    and (.archived_state_path | startswith($owner + "/.dev-studio/generic-dev-studio/.runtime/state/"))
    and (.dry_run_collision_count | type) == "number"
    and (.pending_write_count | type) == "number"
    and (.pending_archive_write_count | type) == "number"
  '

configure_json="$TMPROOT/configure.json"
HOME="$SYNTH_HOME" "$MANAGER" configure \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --list-id "$LIST_ID" \
  --archived-list-id "$ARCHIVED_LIST_ID" \
  --dry-run \
  --json > "$configure_json"
assert_jq "configure dry-run reports login-owned config without writing" "$configure_json" \
  --arg owner "$LOGIN_HOME" --arg list "$LIST_ID" '
    .owner_home == $owner
    and .list_id == $list
    and .archived_list_id == "FCHAINARCHIVE"
    and .dry_run == true
    and .wrote_config == false
  '
[ ! -e "$LOGIN_HOME/.dev-studio/generic-dev-studio/config/chain-monitor.env" ] || fail "configure dry-run wrote config"

synthetic_state_dir="$SYNTH_HOME/.dev-studio/generic-dev-studio/.runtime/state"
mkdir -p "$synthetic_state_dir"
jq -n --arg home "$SYNTH_HOME" --arg list "$LIST_ID" '{
  schema_version: 1,
  list_id: $list,
  owner_home: $home,
  owner_project: "generic-dev-studio",
  rows: [{row_key:"chain:synthetic", row_id:"RecSynthetic"}]
}' > "$synthetic_state_dir/chain-monitor-slack-list-state.json"

recovery_dry="$TMPROOT/recovery-dry.json"
HOME="$SYNTH_HOME" "$MANAGER" recovery \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --synthetic-home "$SYNTH_HOME" \
  --list-id "$LIST_ID" \
  --adopt-synthetic-home-state \
  --json > "$recovery_dry"
assert_jq "recovery defaults to dry-run" "$recovery_dry" '
  .mode == "adopt-synthetic-home-state"
  and .dry_run == true
  and .would_write == true
  and .wrote == false
'
[ ! -e "$LOGIN_HOME/.dev-studio/generic-dev-studio/.runtime/state/chain-monitor-slack-list-state.json" ] \
  || fail "dry-run recovery wrote login-home state"

recovery_exec="$TMPROOT/recovery-exec.json"
HOME="$SYNTH_HOME" "$MANAGER" recovery \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --synthetic-home "$SYNTH_HOME" \
  --list-id "$LIST_ID" \
  --adopt-synthetic-home-state \
  --execute \
  --json > "$recovery_exec"
assert_jq "explicit recovery execution adopts synthetic state into login home" "$recovery_exec" '
  .dry_run == false and .wrote == true and .recovered_row_count == 1
'
assert_jq "adopted state is login-home owned" \
  "$LOGIN_HOME/.dev-studio/generic-dev-studio/.runtime/state/chain-monitor-slack-list-state.json" \
  --arg owner "$LOGIN_HOME" --arg list "$LIST_ID" '
    .owner_home == $owner
    and .list_id == $list
    and any(.rows[]; .row_key == "chain:synthetic")
  '

export STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND="$MOCK_API"
export CHAIN_MONITOR_SLACK_LIST_MOCK_STORE="$TMPROOT/mock-store.json"
export CHAIN_MONITOR_SLACK_LIST_MOCK_LOG="$TMPROOT/mock.log"
jq -n '{schema_version:1,next_id:1,active:[],archived:[],failures:[]}' > "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE"
: > "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
full_rewrite_json="$TMPROOT/full-rewrite.json"
HOME="$SYNTH_HOME" "$MANAGER" recovery \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --list-id "$LIST_ID" \
  --archived-list-id "$ARCHIVED_LIST_ID" \
  --full-rewrite \
  --json \
  --no-discover \
  --persisted-run "$RUN_STATE" > "$full_rewrite_json"
assert_jq "full rewrite recovery defaults to dry-run summary" "$full_rewrite_json" '
  .mode == "full-rewrite"
  and .dry_run == true
  and .exit_code == 0
  and .sync.reconcile.recovery.full_rewrite == true
  and .sync.reconcile.recovery.dry_run_only == true
'
[ ! -s "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG" ] || fail "full rewrite dry-run touched Slack mock"

if HOME="$SYNTH_HOME" "$MANAGER" recovery \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --list-id "$LIST_ID" \
  --archived-list-id "$ARCHIVED_LIST_ID" \
  --full-rewrite \
  --execute \
  --json \
  --no-discover \
  --persisted-run "$RUN_STATE" > "$TMPROOT/full-rewrite-unapproved.json" 2>"$TMPROOT/full-rewrite-unapproved.err"; then
  fail "full rewrite execution did not require operator approval"
fi
grep -q -- '--approve-destructive-slack-rewrite' "$TMPROOT/full-rewrite-unapproved.err" \
  || fail "full rewrite refusal did not name the approval flag"

plist_stdout="$TMPROOT/plist.out"
plist_stderr="$TMPROOT/plist.err"
STUDIO_CHAIN_MONITOR_UNAME=Darwin "$SCHEDULER" --install \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --list-id "$LIST_ID" \
  --archived-list-id "$ARCHIVED_LIST_ID" \
  --dry-run > "$plist_stdout" 2> "$plist_stderr"
grep -q "$LOGIN_HOME/Library/LaunchAgents/dev.studio.chain-monitor-sync.generic-dev-studio.plist" "$plist_stderr" \
  || fail "scheduler dry-run did not target login-home LaunchAgent"
grep -q '<key>STUDIO_CHAIN_MONITOR_SLACK_LIST_ID</key>' "$plist_stdout" \
  || fail "scheduler plist did not carry non-secret List ID"
grep -q '<key>STUDIO_CHAIN_MONITOR_ARCHIVED_SLACK_LIST_ID</key>' "$plist_stdout" \
  || fail "scheduler plist did not carry archived List ID"

if STUDIO_CHAIN_MONITOR_UNAME=Darwin "$SCHEDULER" --install \
  --project generic-dev-studio \
  --owner-home "$SYNTH_HOME" \
  --dry-run > "$TMPROOT/synthetic-schedule.out" 2> "$TMPROOT/synthetic-schedule.err"; then
  fail "scheduler accepted synthetic-home LaunchAgent ownership"
fi
grep -q 'refusing synthetic-home LaunchAgent ownership' "$TMPROOT/synthetic-schedule.err" \
  || fail "synthetic scheduler refusal was not explicit"

if STUDIO_CHAIN_MONITOR_UNAME=Linux "$SCHEDULER" --install \
  --project generic-dev-studio \
  --owner-home "$LOGIN_HOME" \
  --dry-run > "$TMPROOT/linux-schedule.out" 2> "$TMPROOT/linux-schedule.err"; then
  fail "scheduler accepted non-macOS LaunchAgent install"
fi
grep -q 'macOS-only' "$TMPROOT/linux-schedule.err" || fail "non-macOS refusal was not explicit"

bash -n "$MANAGER"
bash -n "$SCHEDULER"

printf 'PASS: chain monitor front doors\n'
