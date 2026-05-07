#!/usr/bin/env bash
# Configuration substrate for the chain monitor Slack row reconciler.

# No `set -e` here. This file is sourced by scripts and fixture harnesses.

CHAIN_MONITOR_CONFIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh disable=SC1091
. "$CHAIN_MONITOR_CONFIG_LIB_DIR/lib-paths.sh"

CHAIN_MONITOR_STATE_FILENAME="chain-monitor-slack-list-state.json"
CHAIN_MONITOR_LOCK_FILENAME="chain-monitor-slack-list-state.json.lock"
CHAIN_MONITOR_SCHEDULER_INTERVAL_S="${CHAIN_MONITOR_SCHEDULER_INTERVAL_S:-60}"
CHAIN_MONITOR_STALE_THRESHOLD_EXPLICIT="${CHAIN_MONITOR_STALE_THRESHOLD_S+x}"
CHAIN_MONITOR_STALE_THRESHOLD_S="${CHAIN_MONITOR_STALE_THRESHOLD_S:-900}"
if [ -z "$CHAIN_MONITOR_STALE_THRESHOLD_EXPLICIT" ]; then
  case "$CHAIN_MONITOR_SCHEDULER_INTERVAL_S" in
    ''|*[!0-9]*) ;;
    *)
      CHAIN_MONITOR_MIN_STALE_THRESHOLD_S=$((CHAIN_MONITOR_SCHEDULER_INTERVAL_S * 2))
      if [ "$CHAIN_MONITOR_STALE_THRESHOLD_S" -lt "$CHAIN_MONITOR_MIN_STALE_THRESHOLD_S" ]; then
        CHAIN_MONITOR_STALE_THRESHOLD_S="$CHAIN_MONITOR_MIN_STALE_THRESHOLD_S"
      fi
      ;;
  esac
fi
CHAIN_MONITOR_COMPLETED_RETENTION_S="${CHAIN_MONITOR_COMPLETED_RETENTION_S:-604800}"
CHAIN_MONITOR_ARCHIVE_RETENTION_S="${CHAIN_MONITOR_ARCHIVE_RETENTION_S:-2592000}"
CHAIN_MONITOR_SLACK_FIELDS="title status manifest summary progress blocker"
CHAIN_MONITOR_EFFECTIVE_STATUSES="available queued running paused blocked failed completed archived stale unknown"
CHAIN_MONITOR_SOURCE_PRECEDENCE="persisted-run runtime-manifest repo-manifest slack-legacy"
CHAIN_MONITOR_NOTIFIER_EVENT="chain_monitor.sync_requested"

chain_monitor_data_home() {
  if studio_home_is_synthetic "${HOME:-}"; then
    local login_home
    login_home=$(resolve_user_login_home 2>/dev/null || true)
    if [ -n "$login_home" ] && [ -d "$login_home" ]; then
      printf '%s\n' "$login_home"
      return 0
    fi
  fi
  printf '%s\n' "${HOME:-}"
}

chain_monitor_state_path_for_project() {
  local project="${1:?usage: chain_monitor_state_path_for_project <project>}"
  local data_home project_root
  data_home=$(chain_monitor_data_home) || return 1
  project_root=$(HOME="$data_home" resolve_project_root_for "$project") || return 1
  printf '%s\n' "$project_root/.runtime/state/$CHAIN_MONITOR_STATE_FILENAME"
}

chain_monitor_state_path() {
  local project
  project=$(resolve_project) || return 1
  chain_monitor_state_path_for_project "$project"
}

chain_monitor_lock_path_for_project() {
  local project="${1:?usage: chain_monitor_lock_path_for_project <project>}"
  local state_path
  state_path=$(chain_monitor_state_path_for_project "$project") || return 1
  printf '%s\n' "$state_path.lock"
}

chain_monitor_lock_path() {
  local project
  project=$(resolve_project) || return 1
  chain_monitor_lock_path_for_project "$project"
}

chain_monitor_recovery_mode_active() {
  case "${DRY_RUN:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  case "${STUDIO_CHAIN_MONITOR_DRY_RUN:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  case "${STUDIO_CHAIN_MONITOR_IMPORT_RECOVERY:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  return 1
}

chain_monitor_refuse_synthetic_state_mutation() {
  local state_path="${1:?usage: chain_monitor_refuse_synthetic_state_mutation <state-path>}"
  if chain_monitor_recovery_mode_active; then
    return 0
  fi
  if studio_home_is_synthetic "${HOME:-}"; then
    case "$state_path" in
      "${HOME:-}"/.dev-studio/*)
        printf 'chain-monitor: refusing to mutate state under synthetic HOME: %s\n' "$state_path" >&2
        printf 'chain-monitor: resolve the owner login-home path or use dry-run/import recovery mode\n' >&2
        return 1
        ;;
    esac
  fi
  return 0
}

chain_monitor_prepare_state_mutation_for_project() {
  local project="${1:?usage: chain_monitor_prepare_state_mutation_for_project <project>}"
  local state_path
  state_path=$(chain_monitor_state_path_for_project "$project") || return 1
  chain_monitor_refuse_synthetic_state_mutation "$state_path" || return 1
  mkdir -p "$(dirname "$state_path")" || return 1
  printf '%s\n' "$state_path"
}

chain_monitor_config_json_for_project() {
  local project="${1:?usage: chain_monitor_config_json_for_project <project>}"
  local state_path lock_path
  state_path=$(chain_monitor_state_path_for_project "$project") || return 1
  lock_path=$(chain_monitor_lock_path_for_project "$project") || return 1
  jq -n \
    --arg state_path "$state_path" \
    --arg lock_path "$lock_path" \
    --arg state_filename "$CHAIN_MONITOR_STATE_FILENAME" \
    --arg lock_filename "$CHAIN_MONITOR_LOCK_FILENAME" \
    --argjson scheduler_interval_s "$CHAIN_MONITOR_SCHEDULER_INTERVAL_S" \
    --argjson stale_threshold_s "$CHAIN_MONITOR_STALE_THRESHOLD_S" \
    --argjson completed_retention_s "$CHAIN_MONITOR_COMPLETED_RETENTION_S" \
    --argjson archive_retention_s "$CHAIN_MONITOR_ARCHIVE_RETENTION_S" \
    --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" \
    --arg statuses "$CHAIN_MONITOR_EFFECTIVE_STATUSES" \
    --arg precedence "$CHAIN_MONITOR_SOURCE_PRECEDENCE" \
    --arg notifier_event "$CHAIN_MONITOR_NOTIFIER_EVENT" \
    '{
      schema_version: 1,
      state: {
        path: $state_path,
        filename: $state_filename,
        lock_path: $lock_path,
        lock_filename: $lock_filename
      },
      scheduler: {
        interval_s: $scheduler_interval_s,
        stale_threshold_s: $stale_threshold_s,
        completed_retention_s: $completed_retention_s,
        archive_retention_s: $archive_retention_s
      },
      slack_fields: ($fields | split(" ")),
      effective_statuses: ($statuses | split(" ")),
      source_precedence: ($precedence | split(" ")),
      runner_notifier_event: $notifier_event
    }'
}

chain_monitor_config_json() {
  local project
  project=$(resolve_project) || return 1
  chain_monitor_config_json_for_project "$project"
}

chain_monitor_runner_notifier_contract_json() {
  jq -n \
    --arg event "$CHAIN_MONITOR_NOTIFIER_EVENT" \
    '{
      schema_version: 1,
      event_name: $event,
      payload_shape: {
        schema_version: 1,
        event: $event,
        project: "<studio-project-slug>",
        run_id: "<chain-runner-run-uuid>",
        chain_run_id: "<chain-run-uuid-or-null>",
        issue_run_id: "<issue-run-uuid-or-null>",
        chain: "<chain-name-or-null>",
        issue_number: "<issue-number-or-null>",
        mutation: "state-updated|row-reconciled|row-archived|dry-run",
        state_path: "<canonical-login-home-state-path>",
        changed_row_keys: ["<row-key>"],
        dry_run: false
      },
      behavior: {
        sync_async: "Runner emits after local state mutation; monitor consumers process asynchronously. A future explicit sync mode may wait for local state reconciliation only, not for Slack API completion.",
        dry_run: "Emit the same payload with dry_run=true and mutation=dry-run; do not write monitor state or Slack rows.",
        opt_out: "STUDIO_CHAIN_MONITOR_NOTIFY=0 disables emission for the runner process.",
        failure: "Notifier failure is loud in logs and telemetry but does not fail issue execution unless STUDIO_CHAIN_MONITOR_NOTIFY_STRICT=1 is set by the user."
      }
    }'
}
