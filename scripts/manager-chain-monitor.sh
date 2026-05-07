#!/usr/bin/env bash
# manager-chain-monitor.sh - manager front door for chain monitor operations.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SYNC_SCRIPT="$SCRIPT_DIR/chain-monitor-sync.sh"

# shellcheck source=lib-chain-monitor-slack-list.sh disable=SC1091
. "$SCRIPT_DIR/lib-chain-monitor-slack-list.sh"

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/manager-chain-monitor.sh configure [--project <slug>] [--list-id <id>] [--dry-run] [--json]
  scripts/manager-chain-monitor.sh sync [--project <slug>] [chain-monitor-sync flags...]
  scripts/manager-chain-monitor.sh status [--project <slug>] [--list-id <id>] [--json] [source flags...]
  scripts/manager-chain-monitor.sh recovery --adopt-login-home-state [--execute] [--json]
  scripts/manager-chain-monitor.sh recovery --adopt-synthetic-home-state [--execute] [--json]
  scripts/manager-chain-monitor.sh recovery --merge-home-state [--execute] [--json]
  scripts/manager-chain-monitor.sh recovery --full-rewrite [--execute --approve-destructive-slack-rewrite <list-id>] [source flags...]

Recovery defaults to dry-run. Live full-rewrite execution requires an explicit
execute flag plus the Slack List ID repeated as operator approval.
EOF
  exit 2
}

bool_json() {
  case "${1:-0}" in 1|true|TRUE|yes|YES) printf 'true\n' ;; *) printf 'false\n' ;; esac
}

quote_env_value() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

upsert_env_line() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if [ -f "$file" ]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" key "=" { print key "=" value; done = 1; next }
      { print }
      END { if (!done) print key "=" value }
    ' "$file" > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

resolve_owner_home() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  if [ -n "${STUDIO_CHAIN_MONITOR_OWNER_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_MONITOR_OWNER_HOME"
    return 0
  fi
  chain_monitor_data_home
}

resolve_login_home() {
  local owner_home="$1"
  if [ -n "${STUDIO_CHAIN_MONITOR_LOGIN_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_MONITOR_LOGIN_HOME"
    return 0
  fi
  if studio_home_is_synthetic "$owner_home"; then
    resolve_user_login_home 2>/dev/null || printf '%s\n' "$owner_home"
    return 0
  fi
  printf '%s\n' "$owner_home"
}

resolve_project_slug() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  resolve_project
}

project_root_for_home() {
  local home="$1" project="$2"
  HOME="$home" resolve_project_root_for "$project"
}

config_file_for() {
  local owner_home="$1" project="$2" project_root
  if [ -n "${STUDIO_CHAIN_MONITOR_CONFIG_FILE:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_MONITOR_CONFIG_FILE"
    return 0
  fi
  project_root=$(project_root_for_home "$owner_home" "$project")
  printf '%s\n' "$project_root/config/chain-monitor.env"
}

load_manager_config() {
  local owner_home="$1" project="$2" config_file
  config_file=$(config_file_for "$owner_home" "$project")
  if [ -r "$config_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$config_file"
    set +a
  fi
}

current_list_id() {
  printf '%s\n' "${STUDIO_CHAIN_MONITOR_SLACK_LIST_ID:-${CHAIN_MONITOR_SLACK_LIST_ID:-}}"
}

state_path_for_home() {
  local home="$1" project="$2"
  HOME="$home" chain_monitor_state_path_for_project "$project"
}

synthetic_state_path_for_home() {
  local synthetic_home="$1" project="$2" project_root
  project_root=$(HOME="$synthetic_home" resolve_project_root_for "$project")
  printf '%s\n' "$project_root/.runtime/state/$CHAIN_MONITOR_STATE_FILENAME"
}

json_owner_summary() {
  local kind="$1" owner_home="$2" project="$3" state_path="$4" list_id="$5" config_file="$6"
  jq -n \
    --arg kind "$kind" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$project" \
    --arg state_path "$state_path" \
    --arg list_id "$list_id" \
    --arg config_file "$config_file" \
    '{
      schema_version: 1,
      kind: $kind,
      owner_home: $owner_home,
      owner_project: $owner_project,
      state_path: $state_path,
      list_id: $list_id,
      config_file: $config_file
    }'
}

append_existing_unique() {
  # shellcheck disable=SC2034 # Used inside the eval loop for the named array.
  local array_name="$1" path="$2" existing
  [ -n "$path" ] || return 0
  [ -f "$path" ] || return 0
  eval "for existing in \"\${${array_name}[@]:-}\"; do [ \"\$existing\" = \"\$path\" ] && return 0; done"
  eval "${array_name}+=(\"\$path\")"
}

append_colon_list() {
  local array_name="$1" value="$2" item
  [ -n "$value" ] || return 0
  IFS=':' read -r -a _chain_monitor_manager_items <<<"$value"
  for item in "${_chain_monitor_manager_items[@]}"; do
    append_existing_unique "$array_name" "$item"
  done
}

discover_sources() {
  local repo_root="$1" owner_home="$2" project="$3" project_root runtime_dir manifest state
  append_colon_list REPO_MANIFESTS "${STUDIO_CHAIN_MONITOR_REPO_MANIFESTS:-}"
  append_colon_list RUNTIME_MANIFESTS "${STUDIO_CHAIN_MONITOR_RUNTIME_MANIFESTS:-}"
  append_colon_list PERSISTED_RUNS "${STUDIO_CHAIN_MONITOR_PERSISTED_RUNS:-}"
  append_colon_list LEGACY_SLACK_ROWS "${STUDIO_CHAIN_MONITOR_LEGACY_SLACK_ROWS:-}"

  [ "$DISCOVER" -eq 1 ] || return 0

  if [ -d "$repo_root/chains" ]; then
    while IFS= read -r manifest; do append_existing_unique REPO_MANIFESTS "$manifest"; done < <(
      find "$repo_root/chains" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    )
  fi

  project_root=$(HOME="$owner_home" resolve_project_root_for "$project")
  for runtime_dir in "$project_root/chains" "$project_root/.runtime/chains" "$project_root/.runtime/manifests"; do
    [ -d "$runtime_dir" ] || continue
    while IFS= read -r manifest; do append_existing_unique RUNTIME_MANIFESTS "$manifest"; done < <(
      find "$runtime_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    )
  done
  if [ -d "$project_root/chain-runs" ]; then
    while IFS= read -r state; do append_existing_unique PERSISTED_RUNS "$state"; done < <(
      find "$project_root/chain-runs" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort
    )
  fi
}

build_source_args() {
  BUILD_ARGS=()
  local source
  if [ "${#PERSISTED_RUNS[@]}" -gt 0 ]; then
    for source in "${PERSISTED_RUNS[@]}"; do BUILD_ARGS+=(--persisted-run "$source"); done
  fi
  if [ "${#RUNTIME_MANIFESTS[@]}" -gt 0 ]; then
    for source in "${RUNTIME_MANIFESTS[@]}"; do BUILD_ARGS+=(--runtime-manifest "$source"); done
  fi
  if [ "${#REPO_MANIFESTS[@]}" -gt 0 ]; then
    for source in "${REPO_MANIFESTS[@]}"; do BUILD_ARGS+=(--repo-manifest "$source"); done
  fi
  if [ "${#LEGACY_SLACK_ROWS[@]}" -gt 0 ]; then
    for source in "${LEGACY_SLACK_ROWS[@]}"; do BUILD_ARGS+=(--legacy-slack "$source"); done
  fi
}

parse_common_source_arg() {
  PARSE_CONSUMED=0
  case "$1" in
    --repo) REPO_FOR_DISCOVERY="${2:?--repo requires a path}"; PARSE_CONSUMED=2 ;;
    --repo=*) REPO_FOR_DISCOVERY="${1#--repo=}"; PARSE_CONSUMED=1 ;;
    --repo-manifest) append_existing_unique REPO_MANIFESTS "${2:?--repo-manifest requires a path}"; PARSE_CONSUMED=2 ;;
    --repo-manifest=*) append_existing_unique REPO_MANIFESTS "${1#--repo-manifest=}"; PARSE_CONSUMED=1 ;;
    --runtime-manifest) append_existing_unique RUNTIME_MANIFESTS "${2:?--runtime-manifest requires a path}"; PARSE_CONSUMED=2 ;;
    --runtime-manifest=*) append_existing_unique RUNTIME_MANIFESTS "${1#--runtime-manifest=}"; PARSE_CONSUMED=1 ;;
    --persisted-run|--run-state) append_existing_unique PERSISTED_RUNS "${2:?--persisted-run requires a path}"; PARSE_CONSUMED=2 ;;
    --persisted-run=*|--run-state=*) append_existing_unique PERSISTED_RUNS "${1#*=}"; PARSE_CONSUMED=1 ;;
    --legacy-slack) append_existing_unique LEGACY_SLACK_ROWS "${2:?--legacy-slack requires a path}"; PARSE_CONSUMED=2 ;;
    --legacy-slack=*) append_existing_unique LEGACY_SLACK_ROWS "${1#--legacy-slack=}"; PARSE_CONSUMED=1 ;;
    --no-discover) DISCOVER=0; PARSE_CONSUMED=1 ;;
    --now-epoch) NOW_EPOCH="${2:?--now-epoch requires a value}"; PARSE_CONSUMED=2 ;;
    --now-epoch=*) NOW_EPOCH="${1#--now-epoch=}"; PARSE_CONSUMED=1 ;;
    --stale-threshold-s) STALE_THRESHOLD_S="${2:?--stale-threshold-s requires a value}"; PARSE_CONSUMED=2 ;;
    --stale-threshold-s=*) STALE_THRESHOLD_S="${1#--stale-threshold-s=}"; PARSE_CONSUMED=1 ;;
    --completed-retention-s) COMPLETED_RETENTION_S="${2:?--completed-retention-s requires a value}"; PARSE_CONSUMED=2 ;;
    --completed-retention-s=*) COMPLETED_RETENTION_S="${1#--completed-retention-s=}"; PARSE_CONSUMED=1 ;;
    --archive-retention-s) ARCHIVE_RETENTION_S="${2:?--archive-retention-s requires a value}"; PARSE_CONSUMED=2 ;;
    --archive-retention-s=*) ARCHIVE_RETENTION_S="${1#--archive-retention-s=}"; PARSE_CONSUMED=1 ;;
    *) return 1 ;;
  esac
  return 0
}

cmd_configure() {
  local project="" owner_override="" list_id_arg="" dry_run=0 json=0 owner_home state_path config_file wrote=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project="${2:?--project requires a value}"; shift 2 ;;
      --project=*) project="${1#--project=}"; shift ;;
      --owner-home) owner_override="${2:?--owner-home requires a path}"; shift 2 ;;
      --owner-home=*) owner_override="${1#--owner-home=}"; shift ;;
      --list-id) list_id_arg="${2:?--list-id requires a value}"; shift 2 ;;
      --list-id=*) list_id_arg="${1#--list-id=}"; shift ;;
      --dry-run) dry_run=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) usage ;;
      *) printf 'manager-chain-monitor: configure unknown arg: %s\n' "$1" >&2; usage ;;
    esac
  done

  project=$(resolve_project_slug "$project")
  owner_home=$(resolve_owner_home "$owner_override")
  load_manager_config "$owner_home" "$project"
  config_file=$(config_file_for "$owner_home" "$project")
  state_path=$(state_path_for_home "$owner_home" "$project")
  if [ -z "$list_id_arg" ]; then
    list_id_arg=$(current_list_id)
  fi

  if [ -n "$list_id_arg" ] && [ "$dry_run" -eq 0 ]; then
    upsert_env_line "$config_file" STUDIO_CHAIN_MONITOR_SLACK_LIST_ID "$(quote_env_value "$list_id_arg")"
    wrote=1
  fi

  if [ "$json" -eq 1 ]; then
    json_owner_summary "chain_monitor_manager_configure" "$owner_home" "$project" "$state_path" "$list_id_arg" "$config_file" |
      jq --argjson dry_run "$(bool_json "$dry_run")" --argjson wrote_config "$(bool_json "$wrote")" \
        '. + {dry_run:$dry_run,wrote_config:$wrote_config}'
  else
    printf 'owner_home=%s\n' "$owner_home"
    printf 'owner_project=%s\n' "$project"
    printf 'state_path=%s\n' "$state_path"
    printf 'list_id=%s\n' "$list_id_arg"
    printf 'config_file=%s\n' "$config_file"
    if [ "$dry_run" -eq 1 ]; then
      printf 'dry_run=1\n'
    else
      printf 'wrote_config=%s\n' "$wrote"
    fi
  fi
}

cmd_sync() {
  local project="" owner_override="" list_id_arg="" arg owner_home list_id
  local -a passthrough=()

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --project) project="${2:?--project requires a value}"; passthrough+=("$1" "$2"); shift 2 ;;
      --project=*) project="${1#--project=}"; passthrough+=("$1"); shift ;;
      --owner-home) owner_override="${2:?--owner-home requires a path}"; shift 2 ;;
      --owner-home=*) owner_override="${1#--owner-home=}"; shift ;;
      --list-id) list_id_arg="${2:?--list-id requires a value}"; passthrough+=("$1" "$2"); shift 2 ;;
      --list-id=*) list_id_arg="${1#--list-id=}"; passthrough+=("$1"); shift ;;
      -h|--help) "$SYNC_SCRIPT" --help ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done

  project=$(resolve_project_slug "$project")
  owner_home=$(resolve_owner_home "$owner_override")
  load_manager_config "$owner_home" "$project"
  list_id="${list_id_arg:-$(current_list_id)}"

  local -a sync_args=(--project "$project" --owner-home "$owner_home")
  [ -n "$list_id" ] && sync_args+=(--list-id "$list_id")
  exec env HOME="$owner_home" "$SYNC_SCRIPT" "${sync_args[@]}" "${passthrough[@]}"
}

cmd_status() {
  local project="" owner_override="" list_id_arg="" json=0 owner_home state_path config_file desired_tmp state_tmp reconcile_tmp
  local collision_count pending_write_count status="ok" source_count
  REPO_FOR_DISCOVERY="$REPO_ROOT"
  DISCOVER=1
  NOW_EPOCH=$(date -u +%s)
  STALE_THRESHOLD_S="$CHAIN_MONITOR_STALE_THRESHOLD_S"
  COMPLETED_RETENTION_S="$CHAIN_MONITOR_COMPLETED_RETENTION_S"
  ARCHIVE_RETENTION_S="$CHAIN_MONITOR_ARCHIVE_RETENTION_S"
  REPO_MANIFESTS=()
  RUNTIME_MANIFESTS=()
  PERSISTED_RUNS=()
  LEGACY_SLACK_ROWS=()
  BUILD_ARGS=()

  while [ "$#" -gt 0 ]; do
    PARSE_CONSUMED=0
    case "$1" in
      --project) project="${2:?--project requires a value}"; shift 2 ;;
      --project=*) project="${1#--project=}"; shift ;;
      --owner-home) owner_override="${2:?--owner-home requires a path}"; shift 2 ;;
      --owner-home=*) owner_override="${1#--owner-home=}"; shift ;;
      --list-id) list_id_arg="${2:?--list-id requires a value}"; shift 2 ;;
      --list-id=*) list_id_arg="${1#--list-id=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help) usage ;;
      *)
        parse_common_source_arg "$@" || {
          printf 'manager-chain-monitor: status unknown arg: %s\n' "$1" >&2
          usage
        }
        shift "$PARSE_CONSUMED"
        ;;
    esac
  done

  project=$(resolve_project_slug "$project")
  owner_home=$(resolve_owner_home "$owner_override")
  load_manager_config "$owner_home" "$project"
  list_id_arg="${list_id_arg:-$(current_list_id)}"
  config_file=$(config_file_for "$owner_home" "$project")
  state_path=$(state_path_for_home "$owner_home" "$project")

  discover_sources "$REPO_FOR_DISCOVERY" "$owner_home" "$project"
  build_source_args
  source_count=$((
    ${#PERSISTED_RUNS[@]} +
    ${#RUNTIME_MANIFESTS[@]} +
    ${#REPO_MANIFESTS[@]} +
    ${#LEGACY_SLACK_ROWS[@]}
  ))
  desired_tmp=$(mktemp -t chain-monitor-status-desired.XXXXXX)
  state_tmp=$(mktemp -t chain-monitor-status-state.XXXXXX)
  reconcile_tmp=$(mktemp -t chain-monitor-status-reconcile.XXXXXX)
  trap 'rm -f "$desired_tmp" "$state_tmp" "$reconcile_tmp"' RETURN

  if [ "$source_count" -eq 0 ]; then
    jq -n '{schema_version:1, rows:[], collisions:[], recoveries:[]}' > "$desired_tmp"
    status="no_sources"
  else
    chain_monitor_build_rows_json \
      --now-epoch "$NOW_EPOCH" \
      --stale-threshold-s "$STALE_THRESHOLD_S" \
      --completed-retention-s "$COMPLETED_RETENTION_S" \
      "${BUILD_ARGS[@]}" > "$desired_tmp"
  fi

  collision_count=$(jq -r '(.collisions // []) | length' "$desired_tmp")
  if [ -s "$state_path" ]; then
    cp "$state_path" "$state_tmp"
  else
    : > "$state_tmp"
  fi

  pending_write_count="null"
  if [ -n "$list_id_arg" ]; then
    set +e
    chain_monitor_slack_list_reconcile_json \
      --desired "$desired_tmp" \
      --state "$state_tmp" \
      --list-id "$list_id_arg" \
      --owner-home "$owner_home" \
      --owner-project "$project" \
      --source-fingerprint "status-dry-run" \
      --now-epoch "$NOW_EPOCH" \
      --archive-retention-s "$ARCHIVE_RETENTION_S" \
      --dry-run > "$reconcile_tmp"
    reconcile_rc=$?
    set -e
    if [ -s "$reconcile_tmp" ]; then
      pending_write_count=$(jq -r '[.operations[]? | select((.action // "") | startswith("would_"))] | length' "$reconcile_tmp")
    fi
    if [ "$reconcile_rc" -ne 0 ]; then
      status="dry_run_failed"
    else
      status="ok"
    fi
  else
    status="missing_list_id"
  fi

  if [ "$json" -eq 1 ]; then
    json_owner_summary "chain_monitor_manager_status" "$owner_home" "$project" "$state_path" "$list_id_arg" "$config_file" |
      jq \
        --arg status "$status" \
        --argjson dry_run_collision_count "$collision_count" \
        --argjson pending_write_count "$pending_write_count" \
        --argjson source_arg_count "$source_count" \
        '. + {
          status: $status,
          dry_run_collision_count: $dry_run_collision_count,
          pending_write_count: $pending_write_count,
          source_arg_count: $source_arg_count
        }'
  else
    printf 'owner_home=%s\n' "$owner_home"
    printf 'owner_project=%s\n' "$project"
    printf 'state_path=%s\n' "$state_path"
    printf 'list_id=%s\n' "$list_id_arg"
    printf 'dry_run_collision_count=%s\n' "$collision_count"
    printf 'pending_write_count=%s\n' "$pending_write_count"
    printf 'status=%s\n' "$status"
  fi
}

refresh_state_owner() {
  local input="$1" output="$2" list_id="$3" owner_home="$4" project="$5"
  jq \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$project" \
    '
      .schema_version = (.schema_version // 1)
      | .list_id = $list_id
      | .owner_home = $owner_home
      | .owner_project = $owner_project
      | .rows = (.rows // [])
    ' "$input" > "$output"
}

merge_state_files() {
  local login_state="$1" synthetic_state="$2" output="$3" list_id="$4" owner_home="$5" project="$6"
  jq -n \
    --argfile login "$login_state" \
    --argfile synthetic "$synthetic_state" \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$project" \
    '
      def by_key($rows):
        reduce ($rows // [])[] as $row
          ({}; .[$row.row_key] = $row);
      (by_key($synthetic.rows) + by_key($login.rows)) as $merged
      | {
          schema_version: 1,
          list_id: $list_id,
          owner_home: $owner_home,
          owner_project: $owner_project,
          source_fingerprint: ($login.source_fingerprint // $synthetic.source_fingerprint // "recovery-merge"),
          rows: ($merged | to_entries | map(.value) | sort_by(.row_key))
        }
    ' > "$output"
}

atomic_copy() {
  local src="$1" dest="$2" tmp
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "${dest}.XXXXXX") || return 1
  cp "$src" "$tmp"
  mv "$tmp" "$dest"
}

cmd_recovery() {
  local project="" owner_override="" synthetic_home_arg="" list_id_arg="" mode="" execute=0 json=0 approval=""
  local owner_home login_home synthetic_home login_state synthetic_state target_state config_file work_tmp sync_summary
  local dry_run=1 would_write=0 wrote=0 source_state="" source_exists=0 target_exists=0
  REPO_FOR_DISCOVERY="$REPO_ROOT"
  DISCOVER=1
  NOW_EPOCH=$(date -u +%s)
  STALE_THRESHOLD_S="$CHAIN_MONITOR_STALE_THRESHOLD_S"
  COMPLETED_RETENTION_S="$CHAIN_MONITOR_COMPLETED_RETENTION_S"
  ARCHIVE_RETENTION_S="$CHAIN_MONITOR_ARCHIVE_RETENTION_S"
  REPO_MANIFESTS=()
  RUNTIME_MANIFESTS=()
  PERSISTED_RUNS=()
  LEGACY_SLACK_ROWS=()
  BUILD_ARGS=()

  while [ "$#" -gt 0 ]; do
    PARSE_CONSUMED=0
    case "$1" in
      --project) project="${2:?--project requires a value}"; shift 2 ;;
      --project=*) project="${1#--project=}"; shift ;;
      --owner-home) owner_override="${2:?--owner-home requires a path}"; shift 2 ;;
      --owner-home=*) owner_override="${1#--owner-home=}"; shift ;;
      --synthetic-home) synthetic_home_arg="${2:?--synthetic-home requires a path}"; shift 2 ;;
      --synthetic-home=*) synthetic_home_arg="${1#--synthetic-home=}"; shift ;;
      --list-id) list_id_arg="${2:?--list-id requires a value}"; shift 2 ;;
      --list-id=*) list_id_arg="${1#--list-id=}"; shift ;;
      --adopt-login-home-state) mode="adopt-login-home-state"; shift ;;
      --adopt-synthetic-home-state) mode="adopt-synthetic-home-state"; shift ;;
      --merge-home-state) mode="merge-home-state"; shift ;;
      --full-rewrite) mode="full-rewrite"; shift ;;
      --execute) execute=1; dry_run=0; shift ;;
      --dry-run) dry_run=1; shift ;;
      --approve-destructive-slack-rewrite) approval="${2:?--approve-destructive-slack-rewrite requires the Slack List ID}"; shift 2 ;;
      --approve-destructive-slack-rewrite=*) approval="${1#--approve-destructive-slack-rewrite=}"; shift ;;
      --json) json=1; shift ;;
      -h|--help) usage ;;
      *)
        parse_common_source_arg "$@" || {
          printf 'manager-chain-monitor: recovery unknown arg: %s\n' "$1" >&2
          usage
        }
        shift "$PARSE_CONSUMED"
        ;;
    esac
  done

  [ -n "$mode" ] || {
    printf 'manager-chain-monitor: recovery requires one recovery mode\n' >&2
    usage
  }
  if [ "$execute" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
    printf 'manager-chain-monitor: --execute and --dry-run cannot be combined\n' >&2
    exit 2
  fi

  project=$(resolve_project_slug "$project")
  owner_home=$(resolve_owner_home "$owner_override")
  login_home=$(resolve_login_home "$owner_home")
  synthetic_home="${synthetic_home_arg:-${STUDIO_CHAIN_MONITOR_SYNTHETIC_HOME:-${HOME:-}}}"
  load_manager_config "$login_home" "$project"
  list_id_arg="${list_id_arg:-$(current_list_id)}"
  config_file=$(config_file_for "$login_home" "$project")
  login_state=$(state_path_for_home "$login_home" "$project")
  synthetic_state=$(synthetic_state_path_for_home "$synthetic_home" "$project")
  target_state="$login_state"

  if [ -z "$list_id_arg" ]; then
    printf 'manager-chain-monitor: recovery requires --list-id or configured STUDIO_CHAIN_MONITOR_SLACK_LIST_ID\n' >&2
    exit 2
  fi

  if [ "$mode" = "full-rewrite" ]; then
    if [ "$dry_run" -eq 0 ]; then
      if [ "$approval" != "$list_id_arg" ]; then
        printf 'manager-chain-monitor: full rewrite execution requires --approve-destructive-slack-rewrite %s\n' "$list_id_arg" >&2
        exit 2
      fi
    fi
    sync_summary=$(mktemp -t chain-monitor-full-rewrite.XXXXXX)
    discover_sources "$REPO_FOR_DISCOVERY" "$login_home" "$project"
    build_source_args
    if [ "${#BUILD_ARGS[@]}" -eq 0 ]; then
      printf 'manager-chain-monitor: full rewrite recovery found no monitor sources\n' >&2
      rm -f "$sync_summary"
      exit 2
    fi
    local -a sync_args=(--project "$project" --owner-home "$login_home" --list-id "$list_id_arg" --summary-output "$sync_summary" --full-rewrite)
    [ "$dry_run" -eq 1 ] && sync_args+=(--dry-run)
    set +e
    STUDIO_CHAIN_MONITOR_IMPORT_RECOVERY=1 HOME="$login_home" "$SYNC_SCRIPT" "${sync_args[@]}" "${BUILD_ARGS[@]}" >/dev/null
    sync_rc=$?
    set -e
    if [ "$json" -eq 1 ]; then
      jq -n \
        --arg mode "$mode" \
        --arg owner_home "$login_home" \
        --arg owner_project "$project" \
        --arg state_path "$login_state" \
        --arg list_id "$list_id_arg" \
        --argjson dry_run "$(bool_json "$dry_run")" \
        --argjson execute "$(bool_json "$execute")" \
        --argjson exit_code "$sync_rc" \
        --slurpfile sync "$sync_summary" \
        '{
          schema_version: 1,
          kind: "chain_monitor_manager_recovery",
          mode: $mode,
          owner_home: $owner_home,
          owner_project: $owner_project,
          state_path: $state_path,
          list_id: $list_id,
          dry_run: $dry_run,
          execute: $execute,
          sync: ($sync[0] // null),
          exit_code: $exit_code
        }'
    elif [ -s "$sync_summary" ]; then
      cat "$sync_summary"
    fi
    rm -f "$sync_summary"
    exit "$sync_rc"
  fi

  case "$mode" in
    adopt-login-home-state) source_state="$login_state" ;;
    adopt-synthetic-home-state) source_state="$synthetic_state" ;;
    merge-home-state) ;;
    *) printf 'manager-chain-monitor: unsupported recovery mode: %s\n' "$mode" >&2; exit 2 ;;
  esac

  [ -s "$login_state" ] && target_exists=1
  [ -n "$source_state" ] && [ -s "$source_state" ] && source_exists=1
  if [ "$mode" = "merge-home-state" ]; then
    source_exists=0
    [ -s "$login_state" ] && source_exists=1
    [ -s "$synthetic_state" ] && source_exists=1
  fi
  if [ "$source_exists" -eq 0 ]; then
    printf 'manager-chain-monitor: recovery source state not found for %s\n' "$mode" >&2
    exit 2
  fi

  work_tmp=$(mktemp -t chain-monitor-recovery-state.XXXXXX)
  case "$mode" in
    adopt-login-home-state|adopt-synthetic-home-state)
      refresh_state_owner "$source_state" "$work_tmp" "$list_id_arg" "$login_home" "$project"
      ;;
    merge-home-state)
      local login_input synthetic_input
      login_input="$login_state"
      synthetic_input="$synthetic_state"
      if [ ! -s "$login_input" ]; then
        login_input=$(mktemp -t chain-monitor-login-empty.XXXXXX)
        jq -n '{schema_version:1, rows:[]}' > "$login_input"
      fi
      if [ ! -s "$synthetic_input" ]; then
        synthetic_input=$(mktemp -t chain-monitor-synthetic-empty.XXXXXX)
        jq -n '{schema_version:1, rows:[]}' > "$synthetic_input"
      fi
      merge_state_files "$login_input" "$synthetic_input" "$work_tmp" "$list_id_arg" "$login_home" "$project"
      ;;
  esac

  would_write=1
  if [ "$dry_run" -eq 0 ]; then
    atomic_copy "$work_tmp" "$target_state"
    wrote=1
  fi

  if [ "$json" -eq 1 ]; then
    jq -n \
      --arg mode "$mode" \
      --arg owner_home "$login_home" \
      --arg owner_project "$project" \
      --arg state_path "$target_state" \
      --arg synthetic_state_path "$synthetic_state" \
      --arg list_id "$list_id_arg" \
      --arg config_file "$config_file" \
      --argjson dry_run "$(bool_json "$dry_run")" \
      --argjson would_write "$(bool_json "$would_write")" \
      --argjson wrote "$(bool_json "$wrote")" \
      --argjson source_exists "$(bool_json "$source_exists")" \
      --argjson target_existed "$(bool_json "$target_exists")" \
      --slurpfile recovered "$work_tmp" \
      '{
        schema_version: 1,
        kind: "chain_monitor_manager_recovery",
        mode: $mode,
        owner_home: $owner_home,
        owner_project: $owner_project,
        state_path: $state_path,
        synthetic_state_path: $synthetic_state_path,
        list_id: $list_id,
        config_file: $config_file,
        dry_run: $dry_run,
        would_write: $would_write,
        wrote: $wrote,
        source_exists: $source_exists,
        target_existed: $target_existed,
        recovered_row_count: (($recovered[0].rows // []) | length)
      }'
  else
    printf 'mode=%s\n' "$mode"
    printf 'owner_home=%s\n' "$login_home"
    printf 'owner_project=%s\n' "$project"
    printf 'state_path=%s\n' "$target_state"
    printf 'synthetic_state_path=%s\n' "$synthetic_state"
    printf 'list_id=%s\n' "$list_id_arg"
    printf 'dry_run=%s\n' "$dry_run"
    printf 'would_write=%s\n' "$would_write"
    printf 'wrote=%s\n' "$wrote"
  fi
  rm -f "$work_tmp"
}

case "$COMMAND" in
  configure) cmd_configure "$@" ;;
  sync) cmd_sync "$@" ;;
  status) cmd_status "$@" ;;
  recovery|recover) cmd_recovery "$@" ;;
  -h|--help|"") usage ;;
  *) printf 'manager-chain-monitor: unknown command: %s\n' "$COMMAND" >&2; usage ;;
esac
