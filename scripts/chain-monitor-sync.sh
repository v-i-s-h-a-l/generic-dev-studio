#!/usr/bin/env bash
# Build and reconcile chain monitor row snapshots through one locked path.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT_DEFAULT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-chain-monitor-slack-list.sh
. "$SCRIPT_DIR/lib-chain-monitor-slack-list.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/chain-monitor-sync.sh [--project <slug>] [--repo <repo-root>] [--list-id <id>]
                                [--repo-manifest <yaml>] [--runtime-manifest <yaml>]
                                [--persisted-run <state.json>] [--legacy-slack <rows.json>]
                                [--event-payload <payload.json>] [--desired-output <json>]
                                [--summary-output <json>] [--dry-run] [--no-discover]
                                [--emit-desired]

Discovers checked-in chain manifests, runtime manifests, and persisted chain-run
state when no explicit --no-discover is supplied. Mutating Slack List sync
requires STUDIO_CHAIN_MONITOR_SLACK_LIST_ID or --list-id.
EOF
  exit 2
}

PROJECT=""
REPO_ROOT="$REPO_ROOT_DEFAULT"
OWNER_HOME=""
STATE_PATH=""
LIST_ID="${STUDIO_CHAIN_MONITOR_SLACK_LIST_ID:-${CHAIN_MONITOR_SLACK_LIST_ID:-}}"
NOW_EPOCH=$(date -u +%s)
STALE_THRESHOLD_S="$CHAIN_MONITOR_STALE_THRESHOLD_S"
COMPLETED_RETENTION_S="$CHAIN_MONITOR_COMPLETED_RETENTION_S"
ARCHIVE_RETENTION_S="$CHAIN_MONITOR_ARCHIVE_RETENTION_S"
LOCK_TIMEOUT_S="${STUDIO_CHAIN_MONITOR_LOCK_TIMEOUT_S:-120}"
LOCK_STALE_S="${STUDIO_CHAIN_MONITOR_LOCK_STALE_S:-900}"
DRY_RUN_SYNC=false
DISCOVER=1
EMIT_DESIRED=0
DESIRED_OUTPUT=""
SUMMARY_OUTPUT=""
EVENT_PAYLOAD=""
FULL_REWRITE=false
REPAIR_ORPHANS=false

declare -a REPO_MANIFESTS=()
declare -a RUNTIME_MANIFESTS=()
declare -a PERSISTED_RUNS=()
declare -a LEGACY_SLACK_ROWS=()

bool_active() {
  case "${1:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  return 1
}

append_existing_unique() {
  local kind="$1" path="$2" existing
  [ -n "$path" ] || return 0
  [ -f "$path" ] || return 0
  case "$kind" in
    repo)
      for existing in "${REPO_MANIFESTS[@]:-}"; do [ "$existing" = "$path" ] && return 0; done
      REPO_MANIFESTS+=("$path")
      ;;
    runtime)
      for existing in "${RUNTIME_MANIFESTS[@]:-}"; do [ "$existing" = "$path" ] && return 0; done
      RUNTIME_MANIFESTS+=("$path")
      ;;
    persisted)
      for existing in "${PERSISTED_RUNS[@]:-}"; do [ "$existing" = "$path" ] && return 0; done
      PERSISTED_RUNS+=("$path")
      ;;
    legacy)
      for existing in "${LEGACY_SLACK_ROWS[@]:-}"; do [ "$existing" = "$path" ] && return 0; done
      LEGACY_SLACK_ROWS+=("$path")
      ;;
  esac
}

append_colon_list() {
  local kind="$1" value="$2" item
  [ -n "$value" ] || return 0
  IFS=':' read -r -a _chain_monitor_items <<<"$value"
  for item in "${_chain_monitor_items[@]}"; do
    append_existing_unique "$kind" "$item"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project requires a value}"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --repo) REPO_ROOT="${2:?--repo requires a path}"; shift 2 ;;
    --repo=*) REPO_ROOT="${1#--repo=}"; shift ;;
    --owner-home) OWNER_HOME="${2:?--owner-home requires a path}"; shift 2 ;;
    --owner-home=*) OWNER_HOME="${1#--owner-home=}"; shift ;;
    --state) STATE_PATH="${2:?--state requires a path}"; shift 2 ;;
    --state=*) STATE_PATH="${1#--state=}"; shift ;;
    --list-id) LIST_ID="${2:?--list-id requires a value}"; shift 2 ;;
    --list-id=*) LIST_ID="${1#--list-id=}"; shift ;;
    --now-epoch) NOW_EPOCH="${2:?--now-epoch requires a value}"; shift 2 ;;
    --now-epoch=*) NOW_EPOCH="${1#--now-epoch=}"; shift ;;
    --stale-threshold-s) STALE_THRESHOLD_S="${2:?--stale-threshold-s requires a value}"; shift 2 ;;
    --stale-threshold-s=*) STALE_THRESHOLD_S="${1#--stale-threshold-s=}"; shift ;;
    --completed-retention-s) COMPLETED_RETENTION_S="${2:?--completed-retention-s requires a value}"; shift 2 ;;
    --completed-retention-s=*) COMPLETED_RETENTION_S="${1#--completed-retention-s=}"; shift ;;
    --archive-retention-s) ARCHIVE_RETENTION_S="${2:?--archive-retention-s requires a value}"; shift 2 ;;
    --archive-retention-s=*) ARCHIVE_RETENTION_S="${1#--archive-retention-s=}"; shift ;;
    --lock-timeout-s) LOCK_TIMEOUT_S="${2:?--lock-timeout-s requires a value}"; shift 2 ;;
    --lock-timeout-s=*) LOCK_TIMEOUT_S="${1#--lock-timeout-s=}"; shift ;;
    --repo-manifest) append_existing_unique repo "${2:?--repo-manifest requires a path}"; shift 2 ;;
    --repo-manifest=*) append_existing_unique repo "${1#--repo-manifest=}"; shift ;;
    --runtime-manifest) append_existing_unique runtime "${2:?--runtime-manifest requires a path}"; shift 2 ;;
    --runtime-manifest=*) append_existing_unique runtime "${1#--runtime-manifest=}"; shift ;;
    --persisted-run|--run-state) append_existing_unique persisted "${2:?--persisted-run requires a path}"; shift 2 ;;
    --persisted-run=*|--run-state=*) append_existing_unique persisted "${1#*=}"; shift ;;
    --legacy-slack) append_existing_unique legacy "${2:?--legacy-slack requires a path}"; shift 2 ;;
    --legacy-slack=*) append_existing_unique legacy "${1#--legacy-slack=}"; shift ;;
    --event-payload) EVENT_PAYLOAD="${2:?--event-payload requires a path}"; shift 2 ;;
    --event-payload=*) EVENT_PAYLOAD="${1#--event-payload=}"; shift ;;
    --desired-output) DESIRED_OUTPUT="${2:?--desired-output requires a path}"; shift 2 ;;
    --desired-output=*) DESIRED_OUTPUT="${1#--desired-output=}"; shift ;;
    --summary-output) SUMMARY_OUTPUT="${2:?--summary-output requires a path}"; shift 2 ;;
    --summary-output=*) SUMMARY_OUTPUT="${1#--summary-output=}"; shift ;;
    --dry-run) DRY_RUN_SYNC=true; shift ;;
    --no-discover) DISCOVER=0; shift ;;
    --emit-desired) EMIT_DESIRED=1; shift ;;
    --full-rewrite) FULL_REWRITE=true; shift ;;
    --repair-orphans) REPAIR_ORPHANS=true; shift ;;
    -h|--help) usage ;;
    *) printf 'chain-monitor-sync: unknown flag: %s\n' "$1" >&2; usage ;;
  esac
done

if bool_active "${DRY_RUN:-0}" || bool_active "${STUDIO_CHAIN_MONITOR_DRY_RUN:-0}"; then
  DRY_RUN_SYNC=true
fi

PROJECT="${PROJECT:-$(resolve_project)}"
OWNER_HOME="${OWNER_HOME:-$(chain_monitor_data_home)}"

case "$NOW_EPOCH$STALE_THRESHOLD_S$COMPLETED_RETENTION_S$ARCHIVE_RETENTION_S$LOCK_TIMEOUT_S$LOCK_STALE_S" in
  *[!0-9]*)
    printf 'chain-monitor-sync: timing values must be non-negative integers\n' >&2
    exit 2
    ;;
esac

project_root=$(HOME="$OWNER_HOME" resolve_project_root_for "$PROJECT")
if [ -z "$STATE_PATH" ]; then
  if [ "$DRY_RUN_SYNC" = "true" ]; then
    STATE_PATH=$(HOME="$OWNER_HOME" chain_monitor_state_path_for_project "$PROJECT")
  else
    STATE_PATH=$(HOME="$OWNER_HOME" chain_monitor_prepare_state_mutation_for_project "$PROJECT")
  fi
else
  if [ "$DRY_RUN_SYNC" != "true" ]; then
    chain_monitor_refuse_synthetic_state_mutation "$STATE_PATH"
    mkdir -p "$(dirname "$STATE_PATH")"
  fi
fi
LOCK_PATH=$(HOME="$OWNER_HOME" chain_monitor_lock_path_for_project "$PROJECT")

append_colon_list repo "${STUDIO_CHAIN_MONITOR_REPO_MANIFESTS:-}"
append_colon_list runtime "${STUDIO_CHAIN_MONITOR_RUNTIME_MANIFESTS:-}"
append_colon_list persisted "${STUDIO_CHAIN_MONITOR_PERSISTED_RUNS:-}"
append_colon_list legacy "${STUDIO_CHAIN_MONITOR_LEGACY_SLACK_ROWS:-}"

if [ "$DISCOVER" -eq 1 ]; then
  if [ -d "$REPO_ROOT/chains" ]; then
    while IFS= read -r manifest; do append_existing_unique repo "$manifest"; done < <(
      find "$REPO_ROOT/chains" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    )
  fi
  for runtime_dir in "$project_root/chains" "$project_root/.runtime/chains" "$project_root/.runtime/manifests"; do
    [ -d "$runtime_dir" ] || continue
    while IFS= read -r manifest; do append_existing_unique runtime "$manifest"; done < <(
      find "$runtime_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    )
  done
  if [ -d "$project_root/chain-runs" ]; then
    while IFS= read -r state; do append_existing_unique persisted "$state"; done < <(
      find "$project_root/chain-runs" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort
    )
  fi
fi

declare -a BUILD_ARGS=()
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

if [ "${#BUILD_ARGS[@]}" -eq 0 ]; then
  printf 'chain-monitor-sync: no monitor sources found; refusing empty desired set\n' >&2
  exit 2
fi

if [ "$EMIT_DESIRED" -eq 0 ] && [ -z "$LIST_ID" ]; then
  printf 'chain-monitor-sync: --list-id or STUDIO_CHAIN_MONITOR_SLACK_LIST_ID is required for reconciliation\n' >&2
  exit 2
fi

validate_live_column_mapping() {
  [ "$DRY_RUN_SYNC" != "true" ] || return 0
  [ -z "${STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND:-}" ] || return 0
  [ -z "${STUDIO_CHAIN_MONITOR_SLACK_LIST_API_FUNCTION:-}" ] || return 0
  bool_active "${STUDIO_CHAIN_MONITOR_ALLOW_FIELD_KEY_COLUMNS:-0}" && return 0
  [ -n "${STUDIO_CHAIN_MONITOR_SLACK_FIELD_COLUMNS_JSON:-}" ] || {
    printf 'chain-monitor-sync: live Slack sync requires STUDIO_CHAIN_MONITOR_SLACK_FIELD_COLUMNS_JSON mapping monitor fields to Slack column IDs\n' >&2
    return 2
  }
  jq -e --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" '
    . as $columns
    | ($fields | split(" ")) as $fields
    | all($fields[]; (($columns[.] // "") | tostring | length) > 0)
  ' <<<"$STUDIO_CHAIN_MONITOR_SLACK_FIELD_COLUMNS_JSON" >/dev/null || {
    printf 'chain-monitor-sync: STUDIO_CHAIN_MONITOR_SLACK_FIELD_COLUMNS_JSON must include every monitor field: %s\n' "$CHAIN_MONITOR_SLACK_FIELDS" >&2
    return 2
  }
}

validate_live_column_mapping

lock_acquired=0
acquire_lock() {
  local started now pid lock_mtime
  mkdir -p "$(dirname "$LOCK_PATH")"
  started=$(date -u +%s)
  while ! mkdir "$LOCK_PATH" 2>/dev/null; do
    if [ -f "$LOCK_PATH/pid" ]; then
      pid=$(cat "$LOCK_PATH/pid" 2>/dev/null || true)
      case "$pid" in ''|*[!0-9]*) pid="" ;; esac
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$LOCK_PATH"
        continue
      fi
    fi
    lock_mtime=$(mtime "$LOCK_PATH" 2>/dev/null || printf '0')
    now=$(date -u +%s)
    if [ "$LOCK_STALE_S" -gt 0 ] && [ "$lock_mtime" -gt 0 ] && [ "$((now - lock_mtime))" -ge "$LOCK_STALE_S" ]; then
      rm -rf "$LOCK_PATH"
      continue
    fi
    if [ "$((now - started))" -ge "$LOCK_TIMEOUT_S" ]; then
      printf 'chain-monitor-sync: timed out waiting for lock: %s\n' "$LOCK_PATH" >&2
      return 1
    fi
    sleep 1
  done
  lock_acquired=1
  printf '%s\n' "$$" > "$LOCK_PATH/pid"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_PATH/created_at"
}

release_lock() {
  if [ "$lock_acquired" -eq 1 ]; then
    rm -rf "$LOCK_PATH"
    lock_acquired=0
  fi
}

trap release_lock EXIT

desired_tmp=$(mktemp -t chain-monitor-desired.XXXXXX)
reconcile_tmp=$(mktemp -t chain-monitor-reconcile.XXXXXX)
summary_tmp=$(mktemp -t chain-monitor-sync-summary.XXXXXX)
payload_tmp=""
if [ -n "$EVENT_PAYLOAD" ] && [ -f "$EVENT_PAYLOAD" ]; then
  payload_tmp="$EVENT_PAYLOAD"
fi

source_fingerprint=$(
  printf '%s\n' "${BUILD_ARGS[@]}" "$NOW_EPOCH" "$STALE_THRESHOLD_S" "$COMPLETED_RETENTION_S" \
    | chain_monitor_slack_list_sha256
)

acquire_lock

chain_monitor_build_rows_json \
  --now-epoch "$NOW_EPOCH" \
  --stale-threshold-s "$STALE_THRESHOLD_S" \
  --completed-retention-s "$COMPLETED_RETENTION_S" \
  "${BUILD_ARGS[@]}" > "$desired_tmp"

if [ -n "$DESIRED_OUTPUT" ]; then
  mkdir -p "$(dirname "$DESIRED_OUTPUT")"
  cp "$desired_tmp" "$DESIRED_OUTPUT"
fi

if [ "$EMIT_DESIRED" -eq 1 ]; then
  cat "$desired_tmp"
  release_lock
  rm -f "$desired_tmp" "$reconcile_tmp" "$summary_tmp"
  exit 0
fi

declare -a RECONCILE_ARGS=(
  --desired "$desired_tmp"
  --state "$STATE_PATH"
  --list-id "$LIST_ID"
  --owner-home "$OWNER_HOME"
  --owner-project "$PROJECT"
  --source-fingerprint "$source_fingerprint"
  --now-epoch "$NOW_EPOCH"
  --archive-retention-s "$ARCHIVE_RETENTION_S"
)
[ "$DRY_RUN_SYNC" = "true" ] && RECONCILE_ARGS+=(--dry-run)
[ "$FULL_REWRITE" = "true" ] && RECONCILE_ARGS+=(--full-rewrite)
[ "$REPAIR_ORPHANS" = "true" ] && RECONCILE_ARGS+=(--repair-orphans)

set +e
chain_monitor_slack_list_reconcile_json "${RECONCILE_ARGS[@]}" > "$reconcile_tmp"
reconcile_rc=$?
set -e

jq -n \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg project "$PROJECT" \
  --arg state_path "$STATE_PATH" \
  --arg lock_path "$LOCK_PATH" \
  --arg list_id "$LIST_ID" \
  --arg source_fingerprint "$source_fingerprint" \
  --argjson dry_run "$DRY_RUN_SYNC" \
  --argjson now_epoch "$NOW_EPOCH" \
  --argjson stale_threshold_s "$STALE_THRESHOLD_S" \
  --argjson completed_retention_s "$COMPLETED_RETENTION_S" \
  --argjson archive_retention_s "$ARCHIVE_RETENTION_S" \
  --argjson exit_code "$reconcile_rc" \
  --argjson repo_manifest_count "${#REPO_MANIFESTS[@]}" \
  --argjson runtime_manifest_count "${#RUNTIME_MANIFESTS[@]}" \
  --argjson persisted_run_count "${#PERSISTED_RUNS[@]}" \
  --argjson legacy_slack_count "${#LEGACY_SLACK_ROWS[@]}" \
  --slurpfile desired "$desired_tmp" \
  --slurpfile reconcile "$reconcile_tmp" \
  --slurpfile event "${payload_tmp:-/dev/null}" \
  '{
    schema_version: 1,
    kind: "chain_monitor_sync",
    created_at: $created_at,
    status: (if $exit_code == 0 then "completed" else "failed" end),
    project: $project,
    state_path: $state_path,
    lock_path: $lock_path,
    list_id: $list_id,
    dry_run: $dry_run,
    source_fingerprint: $source_fingerprint,
    source_counts: {
      repo_manifests: $repo_manifest_count,
      runtime_manifests: $runtime_manifest_count,
      persisted_runs: $persisted_run_count,
      legacy_slack_rows: $legacy_slack_count
    },
    timing: {
      now_epoch: $now_epoch,
      stale_threshold_s: $stale_threshold_s,
      completed_retention_s: $completed_retention_s,
      archive_retention_s: $archive_retention_s
    },
    desired: {
      row_count: (($desired[0].rows // []) | length),
      collision_count: (($desired[0].collisions // []) | length),
      recovery_count: (($desired[0].recoveries // []) | length)
    },
    event: ($event[0] // null),
    reconcile: ($reconcile[0] // {}),
    exit_code: $exit_code
  }' > "$summary_tmp"

if [ -n "$SUMMARY_OUTPUT" ]; then
  mkdir -p "$(dirname "$SUMMARY_OUTPUT")"
  cp "$summary_tmp" "$SUMMARY_OUTPUT"
fi
cat "$summary_tmp"

release_lock
rm -f "$desired_tmp" "$reconcile_tmp" "$summary_tmp"
exit "$reconcile_rc"
