#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/705-chain-monitor"
MOCK_API="$FIXTURE_DIR/fixtures/mock-slack-lists-api.sh"
TMPROOT=$(mktemp -d -t chain-monitor-sync.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

command -v jq >/dev/null 2>&1 || { printf 'skip: jq required\n' >&2; exit 0; }
command -v yq >/dev/null 2>&1 || { printf 'skip: yq required\n' >&2; exit 0; }

# shellcheck source=../../../scripts/lib-chain-monitor-notifier.sh disable=SC1091
. "$ROOT/scripts/lib-chain-monitor-notifier.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  local name="$1" file="$2" filter="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$name"
}

reset_mock() {
  local store_path="$1" log_path="$2"
  jq -n '{schema_version:1,next_id:1,active:[],archived:[],failures:[]}' > "$store_path"
  : > "$log_path"
}

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="generic-dev-studio"
export STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND="$MOCK_API"
export CHAIN_MONITOR_SLACK_LIST_MOCK_STORE="$TMPROOT/mock-store.json"
export CHAIN_MONITOR_SLACK_LIST_MOCK_LOG="$TMPROOT/mock.log"
export STUDIO_CHAIN_MONITOR_SLACK_LIST_ID="FCHAINMONITOR"
export STUDIO_CHAIN_MONITOR_SYNC_ON_NOTIFY=1
export STUDIO_CHAIN_MONITOR_NOTIFY=1
mkdir -p "$HOME"

NOW=$(jq -nr '"2026-05-07T20:40:00Z" | fromdateiso8601')
RUN_STATE="$FIXTURE_DIR/fixtures/persisted-run-state.json"
SYNC_STATE="$HOME/.dev-studio/generic-dev-studio/.runtime/state/chain-monitor-slack-list-state.json"

reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
rm -f "$SYNC_STATE"

summary_a="$TMPROOT/concurrent-a.json"
summary_b="$TMPROOT/concurrent-b.json"
"$ROOT/scripts/chain-monitor-sync.sh" \
  --project generic-dev-studio \
  --no-discover \
  --persisted-run "$RUN_STATE" \
  --now-epoch "$NOW" \
  --stale-threshold-s 3600 \
  --completed-retention-s 300 \
  --archive-retention-s 10 \
  --summary-output "$summary_a" >/dev/null &
pid_a=$!
"$ROOT/scripts/chain-monitor-sync.sh" \
  --project generic-dev-studio \
  --no-discover \
  --persisted-run "$RUN_STATE" \
  --now-epoch "$NOW" \
  --stale-threshold-s 3600 \
  --completed-retention-s 300 \
  --archive-retention-s 10 \
  --summary-output "$summary_b" >/dev/null &
pid_b=$!
wait "$pid_a" || fail "first concurrent sync failed"
wait "$pid_b" || fail "second concurrent sync failed"

assert_jq "concurrent sync used one lock/idempotency path" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" '
  (.active | length) > 0
  and (([.active[].row_key] | length) == ([.active[].row_key] | unique | length))
'
assert_jq "sync summary reports monitor lock path" "$summary_a" '.lock_path | endswith("chain-monitor-slack-list-state.json.lock")'

reset_mock "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" "$CHAIN_MONITOR_SLACK_LIST_MOCK_LOG"
rm -f "$SYNC_STATE"
chain_monitor_notify_runner_state \
  --project generic-dev-studio \
  --run-state "$RUN_STATE" \
  --run-id run-705 \
  --chain-run-id chain-run-705 \
  --issue-run-id issue-run-728 \
  --chain chain-monitor-reconciliation \
  --issue-number 728 \
  --mutation state-updated \
  --dry-run 0
"$ROOT/scripts/chain-monitor-sync.sh" \
  --project generic-dev-studio \
  --no-discover \
  --repo-manifest "$FIXTURE_DIR/fixtures/repo-manifest.yaml" \
  --runtime-manifest "$FIXTURE_DIR/fixtures/runtime-manifest.yaml" \
  --persisted-run "$RUN_STATE" \
  --now-epoch "$NOW" \
  --stale-threshold-s 3600 \
  --completed-retention-s 300 \
  --archive-retention-s 10 \
  --summary-output "$TMPROOT/periodic-after-event.json" >/dev/null
assert_jq "event-driven and periodic sync do not duplicate rows" "$CHAIN_MONITOR_SLACK_LIST_MOCK_STORE" '
  (([.active[].row_key] | length) == ([.active[].row_key] | unique | length))
  and any(.active[]; .row_key == "chain:persisted-run:run-705:chain-run-705")
'
assert_jq "periodic sync includes all source families" "$TMPROOT/periodic-after-event.json" '
  .source_counts.repo_manifests == 1
  and .source_counts.runtime_manifests == 1
  and .source_counts.persisted_runs == 1
'

payload="$TMPROOT/payload.json"
chain_monitor_notifier_payload_json generic-dev-studio "$RUN_STATE" run-705 chain-run-705 issue-run-728 chain-monitor-reconciliation 728 state-updated false > "$payload"
assert_jq "runner notifier contract emits row-key scoped payload" "$payload" '
  .event == "chain_monitor.sync_requested"
  and .dry_run == false
  and (.changed_row_keys | index("chain:persisted-run:run-705:chain-run-705"))
  and (.changed_row_keys | index("task:chain:persisted-run:run-705:chain-run-705:issue:728"))
'

status_run="$TMPROOT/status-run.json"
cat > "$status_run" <<JSON
{
  "schema_version": 1,
  "run_id": "status-run",
  "manifest": "status.yaml",
  "status": "running",
  "updated_at": "2026-05-07T20:39:00Z",
  "chains": [
    {"name":"blocked-over-running","chain_run_id":"blocked","status":"running","updated_at":"2026-05-07T20:39:00Z","issues":[{"number":1,"status":"running"},{"number":2,"status":"blocked"}]},
    {"name":"paused-over-running","chain_run_id":"paused","status":"running","updated_at":"2026-05-07T20:39:00Z","issues":[{"number":3,"status":"paused"}]},
    {"name":"failed-over-queued","chain_run_id":"failed","status":"queued","updated_at":"2026-05-07T20:39:00Z","issues":[{"number":4,"status":"failed"}]},
    {"name":"unknown-conflict","chain_run_id":"unknown","status":"running","updated_at":"2026-05-07T20:39:00Z","issues":[{"number":5,"status":"mystery"}]},
    {"name":"fresh-completed","chain_run_id":"fresh-completed","status":"completed","completed_at":"2026-05-07T20:38:30Z","issues":[{"number":6,"status":"completed","completed_at":"2026-05-07T20:38:30Z"}]},
    {"name":"retained-completed","chain_run_id":"retained-completed","status":"completed","completed_at":"2026-05-07T20:20:00Z","issues":[{"number":7,"status":"completed","completed_at":"2026-05-07T20:20:00Z"}]},
    {"name":"stale-running","chain_run_id":"stale","status":"running","updated_at":"2026-05-07T20:00:00Z","issues":[{"number":8,"status":"running","updated_at":"2026-05-07T20:00:00Z"}]},
    {"name":"fresh-running","chain_run_id":"fresh-running","status":"running","updated_at":"2026-05-07T20:39:30Z","issues":[{"number":9,"status":"running","updated_at":"2026-05-07T20:39:30Z"}]}
  ]
}
JSON

desired_status="$TMPROOT/status-desired.json"
"$ROOT/scripts/chain-monitor-sync.sh" \
  --project generic-dev-studio \
  --no-discover \
  --persisted-run "$status_run" \
  --now-epoch "$NOW" \
  --stale-threshold-s 120 \
  --completed-retention-s 300 \
  --emit-desired > "$desired_status"
assert_jq "persisted run status precedence is applied" "$desired_status" '
  any(.rows[]; .fields.title == "blocked-over-running" and .fields.status == "blocked")
  and any(.rows[]; .fields.title == "paused-over-running" and .fields.status == "paused")
  and any(.rows[]; .fields.title == "failed-over-queued" and .fields.status == "failed")
  and any(.rows[]; .fields.title == "unknown-conflict" and .fields.status == "unknown")
'
assert_jq "stale and completion retention thresholds are honored" "$desired_status" '
  any(.rows[]; .fields.title == "fresh-completed" and .fields.status == "completed")
  and any(.rows[]; .fields.title == "retained-completed" and .fields.status == "archived")
  and any(.rows[]; .fields.title == "stale-running" and .fields.status == "stale")
  and any(.rows[]; .fields.title == "fresh-running" and .fields.status == "running")
'

default_threshold=$(
  CHAIN_MONITOR_SCHEDULER_INTERVAL_S=600 bash -c ". '$ROOT/scripts/lib-chain-monitor-config.sh'; printf '%s\n' \"\$CHAIN_MONITOR_STALE_THRESHOLD_S\""
)
[ "$default_threshold" -ge 1200 ] || fail "default stale threshold did not stay at least two scheduler intervals"

bash -n "$ROOT/scripts/chain-monitor-sync.sh"
bash -n "$ROOT/scripts/lib-chain-monitor-notifier.sh"
zsh -c ". '$ROOT/scripts/lib-chain-monitor-notifier.sh' && chain_monitor_notifier_payload_json generic-dev-studio '$RUN_STATE' run-705 chain-run-705 issue-run-728 chain-monitor-reconciliation 728 state-updated false >/dev/null"

printf 'PASS: chain monitor sync integration\n'
