#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/705-chain-monitor"
TMPROOT=$(mktemp -d -t chain-monitor-model.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

command -v jq >/dev/null 2>&1 || { printf 'skip: jq required\n' >&2; exit 0; }
command -v yq >/dev/null 2>&1 || { printf 'skip: yq required\n' >&2; exit 0; }
command -v check-jsonschema >/dev/null 2>&1 || { printf 'skip: check-jsonschema required\n' >&2; exit 0; }

# shellcheck source=../../../scripts/lib-chain-monitor-config.sh disable=SC1091
. "$ROOT/scripts/lib-chain-monitor-config.sh"
# shellcheck source=../../../scripts/lib-chain-monitor-model.sh disable=SC1091
. "$ROOT/scripts/lib-chain-monitor-model.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  local name="$1" file="$2" filter="$3"
  jq -e "$filter" "$file" >/dev/null || fail "$name"
}

export ACHILLES_PROJECT="generic-dev-studio"
export HOME="$TMPROOT/.codex-homes/codex"
mkdir -p "$HOME"

login_home=$(resolve_user_login_home 2>/dev/null || true)
[ -n "$login_home" ] || fail "login home helper could not resolve owner home"

config="$TMPROOT/config.json"
chain_monitor_config_json_for_project generic-dev-studio > "$config"
expected_state_path="$(HOME="$login_home" resolve_project_root_for generic-dev-studio)/.runtime/state/chain-monitor-slack-list-state.json"
actual_state_path=$(jq -r '.state.path' "$config")
[ "$actual_state_path" = "$expected_state_path" ] || fail "state path resolves under login home: $actual_state_path"
assert_jq "lock path uses state filename lock suffix" "$config" '.state.lock_path == (.state.path + ".lock") and .state.lock_filename == "chain-monitor-slack-list-state.json.lock"'
assert_jq "Slack field set is closed and ordered" "$config" '.slack_fields == ["title","status","manifest","summary","progress","blocker"]'
assert_jq "effective status set contains ten statuses" "$config" '.effective_statuses == ["available","queued","running","paused","blocked","failed","completed","archived","stale","unknown"]'
assert_jq "source precedence is canonical" "$config" '.source_precedence == ["persisted-run","runtime-manifest","repo-manifest","slack-legacy"]'

unsafe_state_path="$(HOME="$HOME" resolve_project_root_for generic-dev-studio)/.runtime/state/chain-monitor-slack-list-state.json"
if chain_monitor_refuse_synthetic_state_mutation "$unsafe_state_path" 2>"$TMPROOT/refuse.err"; then
  fail "synthetic HOME mutation was not refused"
fi
grep -q 'refusing to mutate state under synthetic HOME' "$TMPROOT/refuse.err" || fail "synthetic refusal did not explain the unsafe path"
DRY_RUN=1 chain_monitor_refuse_synthetic_state_mutation "$unsafe_state_path"
unset DRY_RUN

contract="$TMPROOT/notifier-contract.json"
chain_monitor_runner_notifier_contract_json > "$contract"
assert_jq "notifier contract owns event name" "$contract" '.event_name == "chain_monitor.sync_requested" and .payload_shape.dry_run == false'

chain_key=$(chain_monitor_chain_key repo-manifest repo-chain chain-monitor-reconciliation)
[ "$chain_key" = "chain:repo-manifest:repo-chain:chain-monitor-reconciliation" ] || fail "chain key contract changed: $chain_key"
issue_key=$(chain_monitor_issue_task_key "$chain_key" 727)
[ "$issue_key" = "task:chain:repo-manifest:repo-chain:chain-monitor-reconciliation:issue:727" ] || fail "issue task key contract changed: $issue_key"
task_key=$(chain_monitor_named_task_key "$chain_key" sync-pass)
[ "$task_key" = "task:chain:repo-manifest:repo-chain:chain-monitor-reconciliation:task:sync-pass" ] || fail "named task key contract changed: $task_key"

status_results="$TMPROOT/status-results.json"
chain_monitor_status_cases_json "$FIXTURE_DIR/fixtures/status-derivation.json" > "$status_results"
assert_jq "status table covers all ten statuses" "$status_results" '[.cases[].actual] | unique | sort == ["archived","available","blocked","completed","failed","paused","queued","running","stale","unknown"]'
assert_jq "status table expectations pass" "$status_results" 'all(.cases[]; .passed == true)'

check-jsonschema --schemafile "$FIXTURE_DIR/row-snapshot.schema.json" "$FIXTURE_DIR/fixtures/row-snapshot-exemplar.json" >/dev/null

rows="$TMPROOT/rows.json"
fixture_now=$(jq -nr '"2026-05-07T20:30:00Z" | fromdateiso8601')
chain_monitor_build_rows_json \
  --now-epoch "$fixture_now" \
  --stale-threshold-s 3600 \
  --completed-retention-s 300 \
  --repo-manifest "$FIXTURE_DIR/fixtures/repo-manifest.yaml" \
  --runtime-manifest "$FIXTURE_DIR/fixtures/runtime-manifest.yaml" \
  --persisted-run "$FIXTURE_DIR/fixtures/persisted-run-state.json" \
  --legacy-slack "$FIXTURE_DIR/fixtures/legacy-slack-rows.json" \
  > "$rows"

assert_jq "persisted run wins over runtime and repo manifests" "$rows" '
  any(.rows[]; .row_type == "chain"
    and .fields.title == "chain-monitor-reconciliation"
    and .source.kind == "persisted-run"
    and .fields.status == "running")
'
assert_jq "runtime manifest wins over checked-in repo manifest when no run exists" "$rows" '
  any(.rows[]; .row_type == "chain"
    and .fields.title == "runtime-over-repo"
    and .source.kind == "runtime-manifest"
    and .fields.status == "queued")
'
assert_jq "runtime-only manifest rows are included" "$rows" '
  any(.rows[]; .row_type == "chain"
    and .fields.title == "runtime-only"
    and .source.kind == "runtime-manifest")
'
assert_jq "repo manifest appears when no higher-precedence source exists" "$rows" '
  any(.rows[]; .row_type == "chain"
    and .fields.title == "checked-in-only"
    and .source.kind == "repo-manifest"
    and .fields.status == "available")
'
assert_jq "legacy Slack rows are recovery records, not primary model rows" "$rows" '
  (any(.recoveries[]; .legacy_row_id == "slack-row-1" and .purpose == "row-id-recovery"))
  and (any(.recoveries[]; .legacy_row_id == "slack-row-legacy-only" and .purpose == "legacy-migration"))
  and ([.rows[] | select(.source.kind == "slack-legacy")] | length == 0)
'
assert_jq "incompatible issue lists produce explicit collision record" "$rows" '
  any(.collisions[]; .kind == "incompatible_issue_lists"
    and .logical_key == "chain:chain-monitor-reconciliation"
    and ([.claims[].issue_numbers] | unique | length) > 1)
'
assert_jq "terminal, stale, failed, and unknown states are derived in row output" "$rows" '
  any(.rows[]; .fields.title == "archived-chain" and .fields.status == "archived")
  and any(.rows[]; .fields.title == "stale-chain" and .fields.status == "stale")
  and any(.rows[]; .fields.title == "failed-chain" and .fields.status == "failed")
  and any(.rows[]; .fields.title == "unknown-chain" and .fields.status == "unknown")
'
assert_jq "persisted issue tasks are attached to the selected chain row" "$rows" '
  any(.rows[]; .row_type == "task"
    and .parent_row_key == "chain:persisted-run:run-705:chain-run-705"
    and .row_key == "task:chain:persisted-run:run-705:chain-run-705:issue:727")
'
assert_jq "row snapshots expose only the closed Slack field set" "$rows" '
  all(.rows[]; (.fields | keys | sort) == ["blocker","manifest","progress","status","summary","title"])
'

jq -c '.rows[]' "$rows" | while IFS= read -r row; do
  row_file="$TMPROOT/row.json"
  printf '%s\n' "$row" > "$row_file"
  check-jsonschema --schemafile "$FIXTURE_DIR/row-snapshot.schema.json" "$row_file" >/dev/null
done

if jq -e '.rows' "$rows" | grep -E 'private_prompt|tokens|raw_run_path|project_branch|proprietary_detail|private-project-branch|/private/var/folders' >/dev/null; then
  fail "private runner fields leaked into Slack row snapshots"
fi

if grep -Eq 'slack-(fetch|post)\.sh|SLACK_(BOT_)?TOKEN|conversations\.' "$ROOT/scripts/lib-chain-monitor-model.sh"; then
  fail "model library gained a Slack API dependency"
fi

zsh -c ". '$ROOT/scripts/lib-chain-monitor-config.sh' && . '$ROOT/scripts/lib-chain-monitor-model.sh' && chain_monitor_chain_key repo-manifest repo test-chain >/dev/null"

printf 'PASS: chain monitor model substrate\n'
