#!/usr/bin/env bash
# Runner notification helpers for chain monitor sync.

# No `set -e` here. This file is sourced by the chain runner and fixtures.

CHAIN_MONITOR_NOTIFIER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-chain-monitor-slack-list.sh disable=SC1091
. "$CHAIN_MONITOR_NOTIFIER_LIB_DIR/lib-chain-monitor-slack-list.sh"
# shellcheck source=lib-ledger.sh disable=SC1091
. "$CHAIN_MONITOR_NOTIFIER_LIB_DIR/lib-ledger.sh" 2>/dev/null || true

chain_monitor_notifier_bool_active() {
  case "${1:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  return 1
}

chain_monitor_notifier_enabled() {
  case "${STUDIO_CHAIN_MONITOR_NOTIFY:-1}" in 0|false|FALSE|no|NO) return 1 ;; esac
  return 0
}

chain_monitor_notifier_sync_enabled() {
  case "${STUDIO_CHAIN_MONITOR_SYNC_ON_NOTIFY:-auto}" in
    0|false|FALSE|no|NO) return 1 ;;
    1|true|TRUE|yes|YES) return 0 ;;
  esac
  [ -n "${STUDIO_CHAIN_MONITOR_SLACK_LIST_ID:-${CHAIN_MONITOR_SLACK_LIST_ID:-}}" ]
}

chain_monitor_notifier_dry_run_bool() {
  if chain_monitor_notifier_bool_active "${1:-0}" \
    || chain_monitor_notifier_bool_active "${DRY_RUN:-0}" \
    || chain_monitor_notifier_bool_active "${STUDIO_CHAIN_MONITOR_DRY_RUN:-0}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

chain_monitor_notifier_row_keys_json() {
  local run_state="$1" chain_run_id="${2:-}" issue_run_id="${3:-}" issue_number="${4:-}"
  local run_source_id chain_id chain_key issue_from_state
  [ -f "$run_state" ] || { printf '[]\n'; return 0; }
  run_source_id=$(jq -r '.run_id // "persisted-run"' "$run_state" 2>/dev/null || printf 'persisted-run')
  chain_id=""
  if [ -n "$chain_run_id" ]; then
    chain_id=$(jq -r --arg id "$chain_run_id" '.chains[]? | select((.chain_run_id // "") == $id) | (.chain_run_id // .name // "")' "$run_state" 2>/dev/null | head -n 1)
  fi
  if [ -z "$chain_id" ] && [ -n "$issue_run_id" ]; then
    chain_id=$(jq -r --arg id "$issue_run_id" '.chains[]? as $chain | $chain.issues[]? | select((.issue_run_id // "") == $id) | ($chain.chain_run_id // $chain.name // "")' "$run_state" 2>/dev/null | head -n 1)
  fi
  [ -n "$chain_id" ] || { printf '[]\n'; return 0; }
  chain_key=$(chain_monitor_chain_key persisted-run "$run_source_id" "$chain_id")
  if [ -z "$issue_number" ] && [ -n "$issue_run_id" ]; then
    issue_from_state=$(jq -r --arg id "$issue_run_id" '.chains[]?.issues[]? | select((.issue_run_id // "") == $id) | (.number // .issue // "")' "$run_state" 2>/dev/null | head -n 1)
    issue_number="$issue_from_state"
  fi
  if [ -n "$issue_number" ] && [ "$issue_number" != "null" ]; then
    jq -cn --arg chain_key "$chain_key" --arg issue_key "$(chain_monitor_issue_task_key "$chain_key" "$issue_number")" '[$chain_key, $issue_key]'
  else
    jq -cn --arg chain_key "$chain_key" '[$chain_key]'
  fi
}

chain_monitor_notifier_payload_json() {
  local project="$1" run_state="$2" run_id="$3" chain_run_id="$4" issue_run_id="$5" chain="$6" issue_number="$7" mutation="$8" dry_run="$9"
  local state_path changed_keys
  state_path=$(chain_monitor_state_path_for_project "$project" 2>/dev/null || printf '')
  changed_keys=$(chain_monitor_notifier_row_keys_json "$run_state" "$chain_run_id" "$issue_run_id" "$issue_number")
  jq -n \
    --arg event "$CHAIN_MONITOR_NOTIFIER_EVENT" \
    --arg project "$project" \
    --arg run_id "$run_id" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg chain "$chain" \
    --arg issue_number "$issue_number" \
    --arg mutation "$mutation" \
    --arg state_path "$state_path" \
    --argjson changed_row_keys "$changed_keys" \
    --argjson dry_run "$dry_run" \
    '{
      schema_version: 1,
      event: $event,
      project: $project,
      run_id: $run_id,
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      chain: (if $chain == "" then null else $chain end),
      issue_number: (if $issue_number == "" then null else ($issue_number | tonumber? // $issue_number) end),
      mutation: (if $dry_run then "dry-run" else $mutation end),
      state_path: $state_path,
      changed_row_keys: $changed_row_keys,
      dry_run: $dry_run
    }'
}

chain_monitor_notifier_emit_payload() {
  local payload="$1" run_id issue_number chain_run_id issue_run_id mutation changed_hash
  declare -F emit_event_keyed >/dev/null 2>&1 || return 0
  run_id=$(printf '%s\n' "$payload" | jq -r '.run_id // ""')
  issue_number=$(printf '%s\n' "$payload" | jq -r '.issue_number // ""')
  chain_run_id=$(printf '%s\n' "$payload" | jq -r '.chain_run_id // "none"')
  issue_run_id=$(printf '%s\n' "$payload" | jq -r '.issue_run_id // "none"')
  mutation=$(printf '%s\n' "$payload" | jq -r '.mutation // "state-updated"')
  changed_hash=$(printf '%s\n' "$payload" | jq -c '.changed_row_keys // []' | chain_monitor_slack_list_sha256)
  emit_event_keyed studio chain "$CHAIN_MONITOR_NOTIFIER_EVENT" "$issue_number" "$payload" \
    --instance-id "$run_id" \
    --idem-key "chain-monitor:$run_id:$chain_run_id:$issue_run_id:$mutation:$changed_hash" \
    >/dev/null 2>&1 || true
}

chain_monitor_notify_runner_state() {
  local project="" run_state="" run_id="" chain_run_id="" issue_run_id="" chain="" issue_number="" mutation="state-updated" dry_run_arg="0"
  local dry_run payload payload_file summary_file sync_rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project="${2:-}"; shift 2 ;;
      --run-state) run_state="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --chain-run-id) chain_run_id="${2:-}"; shift 2 ;;
      --issue-run-id) issue_run_id="${2:-}"; shift 2 ;;
      --chain) chain="${2:-}"; shift 2 ;;
      --issue-number) issue_number="${2:-}"; shift 2 ;;
      --mutation) mutation="${2:-state-updated}"; shift 2 ;;
      --dry-run) dry_run_arg="${2:-0}"; shift 2 ;;
      *) printf 'chain-monitor-notifier: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  chain_monitor_notifier_enabled || return 0
  project="${project:-$(resolve_project 2>/dev/null || printf generic-dev-studio)}"
  [ -n "$run_state" ] && [ -f "$run_state" ] || return 0
  dry_run=$(chain_monitor_notifier_dry_run_bool "$dry_run_arg")
  payload=$(chain_monitor_notifier_payload_json "$project" "$run_state" "$run_id" "$chain_run_id" "$issue_run_id" "$chain" "$issue_number" "$mutation" "$dry_run")
  chain_monitor_notifier_emit_payload "$payload"

  chain_monitor_notifier_sync_enabled || return 0
  payload_file=$(mktemp -t chain-monitor-notifier-payload.XXXXXX)
  summary_file=$(mktemp -t chain-monitor-notifier-summary.XXXXXX)
  printf '%s\n' "$payload" > "$payload_file"
  if "$CHAIN_MONITOR_NOTIFIER_LIB_DIR/chain-monitor-sync.sh" \
    --project "$project" \
    --persisted-run "$run_state" \
    --event-payload "$payload_file" \
    --summary-output "$summary_file" \
    --no-discover \
    >/dev/null; then
    sync_rc=0
  else
    sync_rc=$?
  fi
  if [ "$sync_rc" -ne 0 ]; then
    printf 'chain-monitor-notifier: sync failed for %s/%s (exit %s)\n' "${chain_run_id:-none}" "${issue_run_id:-none}" "$sync_rc" >&2
    [ ! -s "$summary_file" ] || cat "$summary_file" >&2
    rm -f "$payload_file" "$summary_file"
    if chain_monitor_notifier_bool_active "${STUDIO_CHAIN_MONITOR_NOTIFY_STRICT:-0}"; then
      return "$sync_rc"
    fi
    return 0
  fi
  rm -f "$payload_file" "$summary_file"
  return 0
}
