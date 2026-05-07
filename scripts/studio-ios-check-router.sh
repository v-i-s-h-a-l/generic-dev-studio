#!/usr/bin/env bash
# studio-ios-check-router.sh - local-first scheduler for iOS build/test checks.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || { printf 'studio-ios-check-router: jq required\n' >&2; exit 2; }

COMMAND="explain"
if [ $# -gt 0 ]; then
  case "$1" in
    explain|pick|status|clear-affinity)
      COMMAND="$1"
      shift
      ;;
  esac
fi

OPERATION="build"
ROLE="xcodebuild"
CHAIN=""
TASK_ID=""
WORKTREE=""
SOURCE_BRANCH=""
BASE_SHA=""
WORKTREE_SHA=""
RUN_ID=""
CHAIN_RUN_ID=""
ISSUE_RUN_ID=""
MANIFEST_VERSION="1"
CACHE_KEY=""
SIMULATOR_RUNTIME=""
XCODE_VERSION=""
REQUIRED_SECRET_SCOPES=""
USER_BLOCKED="false"
FORCE_LOCAL=0
FORCE_WORKER=""
BREAK_AFFINITY=0
CLEAR_AFFINITY=0
ALLOW_MANAGER_IMPACT=0
JSON_OUTPUT=1
DRY_RUN_FLAG=0
NO_TELEMETRY=0

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/studio-ios-check-router.sh explain [options]
  scripts/studio-ios-check-router.sh pick [options]
  scripts/studio-ios-check-router.sh status [--chain <name>] [--json]
  scripts/studio-ios-check-router.sh clear-affinity --chain <name> [--source-branch <branch>] [--role <role>]

Options:
  --operation <build|test|test:unit|test:ui|lsp-only|implementation>
  --role <xcodebuild|swift-test>
  --chain <name> --task-id <id> --worktree <path>
  --source-branch <branch> --base-sha <sha> --worktree-sha <sha>
  --run-id <id> --chain-run-id <id> --issue-run-id <id> --manifest-version <n>
  --cache-key <key> --simulator-runtime <runtime> --xcode-version <version>
  --requires-secret-scope <a,b>
  --user-blocked true|false
  --force-local | --force-worker <node-id> | --break-affinity | --clear-affinity
  --allow-manager-impact
  --dry-run
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --operation) OPERATION="${2:?--operation requires a value}"; shift 2 ;;
    --operation=*) OPERATION="${1#--operation=}"; shift ;;
    --role) ROLE="${2:?--role requires a value}"; shift 2 ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    --chain) CHAIN="${2:?--chain requires a value}"; shift 2 ;;
    --chain=*) CHAIN="${1#--chain=}"; shift ;;
    --task-id) TASK_ID="${2:?--task-id requires a value}"; shift 2 ;;
    --task-id=*) TASK_ID="${1#--task-id=}"; shift ;;
    --worktree) WORKTREE="${2:?--worktree requires a value}"; shift 2 ;;
    --worktree=*) WORKTREE="${1#--worktree=}"; shift ;;
    --source-branch) SOURCE_BRANCH="${2:?--source-branch requires a value}"; shift 2 ;;
    --source-branch=*) SOURCE_BRANCH="${1#--source-branch=}"; shift ;;
    --base-sha) BASE_SHA="${2:?--base-sha requires a value}"; shift 2 ;;
    --base-sha=*) BASE_SHA="${1#--base-sha=}"; shift ;;
    --worktree-sha) WORKTREE_SHA="${2:?--worktree-sha requires a value}"; shift 2 ;;
    --worktree-sha=*) WORKTREE_SHA="${1#--worktree-sha=}"; shift ;;
    --run-id) RUN_ID="${2:?--run-id requires a value}"; shift 2 ;;
    --run-id=*) RUN_ID="${1#--run-id=}"; shift ;;
    --chain-run-id) CHAIN_RUN_ID="${2:?--chain-run-id requires a value}"; shift 2 ;;
    --chain-run-id=*) CHAIN_RUN_ID="${1#--chain-run-id=}"; shift ;;
    --issue-run-id) ISSUE_RUN_ID="${2:?--issue-run-id requires a value}"; shift 2 ;;
    --issue-run-id=*) ISSUE_RUN_ID="${1#--issue-run-id=}"; shift ;;
    --manifest-version) MANIFEST_VERSION="${2:?--manifest-version requires a value}"; shift 2 ;;
    --manifest-version=*) MANIFEST_VERSION="${1#--manifest-version=}"; shift ;;
    --cache-key) CACHE_KEY="${2:?--cache-key requires a value}"; shift 2 ;;
    --cache-key=*) CACHE_KEY="${1#--cache-key=}"; shift ;;
    --simulator-runtime) SIMULATOR_RUNTIME="${2:?--simulator-runtime requires a value}"; shift 2 ;;
    --simulator-runtime=*) SIMULATOR_RUNTIME="${1#--simulator-runtime=}"; shift ;;
    --xcode-version) XCODE_VERSION="${2:?--xcode-version requires a value}"; shift 2 ;;
    --xcode-version=*) XCODE_VERSION="${1#--xcode-version=}"; shift ;;
    --requires-secret-scope) REQUIRED_SECRET_SCOPES="${2:?--requires-secret-scope requires a value}"; shift 2 ;;
    --requires-secret-scope=*) REQUIRED_SECRET_SCOPES="${1#--requires-secret-scope=}"; shift ;;
    --user-blocked) USER_BLOCKED="${2:?--user-blocked requires true|false}"; shift 2 ;;
    --user-blocked=*) USER_BLOCKED="${1#--user-blocked=}"; shift ;;
    --force-local) FORCE_LOCAL=1; shift ;;
    --force-worker) FORCE_WORKER="${2:?--force-worker requires node-id}"; shift 2 ;;
    --force-worker=*) FORCE_WORKER="${1#--force-worker=}"; shift ;;
    --break-affinity) BREAK_AFFINITY=1; shift ;;
    --clear-affinity) CLEAR_AFFINITY=1; shift ;;
    --allow-manager-impact) ALLOW_MANAGER_IMPACT=1; shift ;;
    --dry-run) DRY_RUN_FLAG=1; shift ;;
    --json) JSON_OUTPUT=1; shift ;;
    --no-telemetry) NO_TELEMETRY=1; shift ;;
    -h|--help) usage ;;
    *) printf 'studio-ios-check-router: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

case "${STUDIO_IOS_ROUTER_FORCE_LOCAL:-0}" in 1|true|TRUE|yes|YES) FORCE_LOCAL=1 ;; esac
[ -n "${STUDIO_IOS_ROUTER_FORCE_WORKER:-}" ] && FORCE_WORKER="$STUDIO_IOS_ROUTER_FORCE_WORKER"
case "${STUDIO_IOS_ROUTER_BREAK_AFFINITY:-0}" in 1|true|TRUE|yes|YES) BREAK_AFFINITY=1 ;; esac
case "${STUDIO_IOS_ROUTER_CLEAR_AFFINITY:-0}" in 1|true|TRUE|yes|YES) CLEAR_AFFINITY=1 ;; esac
case "${STUDIO_IOS_ROUTER_ALLOW_MANAGER_IMPACT:-0}" in 1|true|TRUE|yes|YES) ALLOW_MANAGER_IMPACT=1 ;; esac
case "${DRY_RUN:-0}" in 1|true|TRUE|yes|YES) DRY_RUN_FLAG=1 ;; esac

safe_segment() {
  local value="${1:-unknown}" safe
  safe=$(printf '%s' "$value" | sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  [ -n "$safe" ] || safe="unknown"
  printf '%s\n' "$safe"
}

now_ms() {
  perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time() * 1000' 2>/dev/null || {
    local s
    s=$(date -u +%s)
    printf '%s000\n' "$s"
  }
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

json_lines_to_array() {
  jq -R 'select(length > 0)' | jq -s .
}

state_root() {
  if [ -n "${STUDIO_IOS_ROUTING_STATE_ROOT:-}" ]; then
    printf '%s\n' "$STUDIO_IOS_ROUTING_STATE_ROOT"
    return 0
  fi
  local project_root
  project_root=$(resolve_project_root 2>/dev/null || printf '')
  if [ -n "$project_root" ]; then
    printf '%s\n' "$project_root/.runtime/state/ios-check-routing"
  else
    printf '%s\n' "$(resolve_runtime_global)/ios-check-routing"
  fi
}

json_get() {
  local json="$1" filter="$2"
  printf '%s\n' "$json" | jq -r "$filter // empty" 2>/dev/null || true
}

file_json_or_empty() {
  local file="$1"
  if [ -r "$file" ]; then
    cat "$file"
  else
    printf '{}'
  fi
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

num_or_default() {
  local value="${1:-}" fallback="${2:-0}"
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

float_or_default() {
  local value="${1:-}" fallback="${2:-0}"
  case "$value" in
    ''|*[!0-9.]*|.*|*.*.*) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

ts_epoch() {
  local ts="$1"
  [ -n "$ts" ] || { printf '0\n'; return 0; }
  ts_to_epoch "$ts" 2>/dev/null || printf '0\n'
}

major_version() {
  printf '%s' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p'
}

append_reason() {
  local reason="$1"
  if [ -z "$REASONS" ]; then
    REASONS="$reason"
  else
    REASONS="${REASONS}
$reason"
  fi
}

operation_is_expensive() {
  case "$OPERATION" in
    build|full-green|xcodebuild|test|test:unit|test:ui|xcodebuild-test|ui-test|unit-test) return 0 ;;
    *) return 1 ;;
  esac
}

operation_needs_simulator() {
  case "$OPERATION:$ROLE" in
    test*:*|ui-test:*|unit-test:*|*:swift-test) return 0 ;;
    *) [ -n "$SIMULATOR_RUNTIME" ] ;;
  esac
}

envelope_field() {
  local field="$1" envelope
  [ -n "$WORKTREE" ] || return 0
  envelope="$WORKTREE/.studio/chain-task-start.json"
  [ -r "$envelope" ] || return 0
  jq -r --arg field "$field" '.[$field] // empty' "$envelope" 2>/dev/null || true
}

envelope_ownership_field() {
  local field="$1" envelope
  [ -n "$WORKTREE" ] || return 0
  envelope="$WORKTREE/.studio/chain-task-start.json"
  [ -r "$envelope" ] || return 0
  jq -r --arg field "$field" '.ownership[$field] // empty' "$envelope" 2>/dev/null || true
}

START_MS=$(now_ms)
NOW_EPOCH=$(date -u +%s)
CREATED_AT=$(iso_now)
STATE_ROOT=$(state_root)
mkdir -p "$STATE_ROOT" 2>/dev/null || true

[ -n "$CHAIN" ] || CHAIN=$(envelope_ownership_field chain)
[ -n "$CHAIN" ] || CHAIN=$(envelope_field chain)
[ -n "$CHAIN" ] || CHAIN="standalone"
[ -n "$RUN_ID" ] || RUN_ID=$(envelope_field run_id)
[ -n "$CHAIN_RUN_ID" ] || CHAIN_RUN_ID=$(envelope_field chain_run_id)
[ -n "$ISSUE_RUN_ID" ] || ISSUE_RUN_ID=$(envelope_field issue_run_id)
[ -n "$SOURCE_BRANCH" ] || SOURCE_BRANCH=$(envelope_ownership_field source_branch)
if [ -z "$SOURCE_BRANCH" ] && [ -n "$WORKTREE" ]; then
  SOURCE_BRANCH=$(git -C "$WORKTREE" symbolic-ref --short HEAD 2>/dev/null || true)
fi
[ -n "$SOURCE_BRANCH" ] || SOURCE_BRANCH="unknown"
if [ -z "$WORKTREE_SHA" ] && [ -n "$WORKTREE" ]; then
  WORKTREE_SHA=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
fi
if [ -z "$BASE_SHA" ] && [ -n "$WORKTREE" ]; then
  BASE_SHA=$(git -C "$WORKTREE" merge-base HEAD "origin/$SOURCE_BRANCH" 2>/dev/null || true)
fi

CHAIN_SAFE=$(safe_segment "$CHAIN")
SOURCE_SAFE=$(safe_segment "$SOURCE_BRANCH")
ROLE_SAFE=$(safe_segment "$ROLE")
AFFINITY_DIR="$STATE_ROOT/affinity"
AFFINITY_FILE="$AFFINITY_DIR/$CHAIN_SAFE-$SOURCE_SAFE-$ROLE_SAFE.json"
SOURCE_PROOF_DIR="${STUDIO_IOS_SOURCE_SYNC_PROOF_DIR:-$STATE_ROOT/source-sync/$CHAIN_SAFE}"
CANDIDATE_STATE_DIR="${STUDIO_IOS_ROUTER_CANDIDATE_DIR:-$STATE_ROOT/candidates}"
mkdir -p "$AFFINITY_DIR" "$SOURCE_PROOF_DIR" "$CANDIDATE_STATE_DIR" 2>/dev/null || true

MAX_AFFINITY_WAIT_S=$(num_or_default "${STUDIO_IOS_MAX_AFFINITY_QUEUE_WAIT_SEC:-${STUDIO_IOS_ROUTER_MAX_QUEUE_WAIT_S:-900}}" 900)
PROBE_TTL_S=$(num_or_default "${STUDIO_IOS_ROUTER_PROBE_TTL_S:-600}" 600)
SOURCE_SYNC_TTL_S=$(num_or_default "${STUDIO_IOS_ROUTER_SOURCE_SYNC_TTL_S:-3600}" 3600)
QUEUE_SLOT_SECONDS=$(num_or_default "${STUDIO_IOS_ROUTER_QUEUE_SLOT_SECONDS:-300}" 300)
REMOTE_SETUP_COST_S=$(num_or_default "${STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S:-120}" 120)
RETRY_COST_S=$(num_or_default "${STUDIO_IOS_ROUTER_RETRY_COST_S:-180}" 180)
MIN_SAVINGS_S=$(num_or_default "${STUDIO_IOS_ROUTER_MIN_SAVINGS_S:-120}" 120)
MIN_RAM_GIB=$(num_or_default "${STUDIO_IOS_ROUTER_MIN_RAM_GIB:-8}" 8)
MAX_LOAD=$(float_or_default "${STUDIO_IOS_ROUTER_MAX_LOAD:-6}" 6)
OVERHEAD_BUDGET_MS=$(num_or_default "${STUDIO_IOS_ROUTER_OVERHEAD_BUDGET_MS:-2000}" 2000)
AFFINITY_TTL_S=$(num_or_default "${STUDIO_IOS_ROUTER_AFFINITY_TTL_S:-86400}" 86400)

if [ "$CLEAR_AFFINITY" = "1" ] || [ "$COMMAND" = "clear-affinity" ]; then
  previous="null"
  if [ -r "$AFFINITY_FILE" ]; then
    previous=$(cat "$AFFINITY_FILE")
    rm -f "$AFFINITY_FILE" 2>/dev/null || true
  fi
  clear_doc=$(jq -n \
    --arg ts "$CREATED_AT" \
    --arg chain "$CHAIN" \
    --arg source_branch "$SOURCE_BRANCH" \
    --arg role "$ROLE" \
    --argjson previous "$previous" \
    '{schema_version:1,kind:"studio-ios-affinity-cleared",created_at:$ts,chain:$chain,source_branch:$source_branch,role:$role,previous:$previous,reason:"user_override"}')
  [ "$COMMAND" = "clear-affinity" ] && { printf '%s\n' "$clear_doc"; exit 0; }
fi

status_view() {
  local filter_chain="$CHAIN" affinities_file queues_file locks_file candidates_file artifacts_file
  affinities_file=$(mktemp 2>/dev/null || printf '/tmp/ios-affinities-%s' "$$")
  queues_file=$(mktemp 2>/dev/null || printf '/tmp/ios-queues-%s' "$$")
  locks_file=$(mktemp 2>/dev/null || printf '/tmp/ios-locks-%s' "$$")
  candidates_file=$(mktemp 2>/dev/null || printf '/tmp/ios-candidates-%s' "$$")
  artifacts_file=$(mktemp 2>/dev/null || printf '/tmp/ios-artifacts-%s' "$$")
  : >"$affinities_file"; : >"$queues_file"; : >"$locks_file"; : >"$candidates_file"; : >"$artifacts_file"

  find "$AFFINITY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | while IFS= read -r f; do
    [ -r "$f" ] || continue
    if [ -n "$filter_chain" ] && [ "$filter_chain" != "standalone" ]; then
      jq -e --arg chain "$filter_chain" '.chain == $chain' "$f" >/dev/null 2>&1 || continue
    fi
    jq -c '{chain,source_branch,preferred_executor,cache_key,cache_warmth,set_at,expires_at,last_break_reason}' "$f" 2>/dev/null
  done >"$affinities_file"

  find "$(resolve_runtime_global)/build-queue" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r qdir; do
    executor=$(basename "$qdir")
    depth=$(find "$qdir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    jq -n --arg executor "$executor" --argjson depth "$(num_or_default "$depth" 0)" \
      '{executor:$executor,queued_build_test_jobs:$depth}'
  done >"$queues_file"

  find "$(resolve_runtime_global)/xcodebuild-lock" -mindepth 1 -maxdepth 2 -type d -name 'slot-*' 2>/dev/null | sort | while IFS= read -r lock_dir; do
    executor=$(basename "$(dirname "$lock_dir")")
    slot=$(basename "$lock_dir")
    owner=$(cat "$lock_dir/pid" 2>/dev/null || true)
    jq -n --arg executor "$executor" --arg slot "$slot" --arg owner "$owner" \
      '{executor:$executor,slot:$slot,owner:$owner}'
  done >"$locks_file"

  find "$CANDIDATE_STATE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | while IFS= read -r f; do
    id=$(basename "$f" .json)
    jq -c --arg id "$id" '{executor:$id,active_job:(.active_job // null),cache_warmth:(.cache_warmth // "unknown"),disk_pressure:(.disk_pressure // "unknown"),simulator_slots:(.simulator_slots // []),stale:(.stale // false)}' "$f" 2>/dev/null
  done >"$candidates_file"

  if [ -n "${STUDIO_CHAIN_ARTIFACT_ROOT:-}" ] && [ -d "$STUDIO_CHAIN_ARTIFACT_ROOT/retention" ]; then
    find "$STUDIO_CHAIN_ARTIFACT_ROOT/retention" -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do
      jq -c '{retention_class:(.retention_class // .class // "unknown"),state:(.state // "unknown")}' "$f" 2>/dev/null
    done >"$artifacts_file"
  fi

  jq -n \
    --arg ts "$CREATED_AT" \
    --arg chain "$filter_chain" \
    --argjson active_chains "$(jq -s '.' "$affinities_file")" \
    --argjson queues "$(jq -s '.' "$queues_file")" \
    --argjson locks "$(jq -s '.' "$locks_file")" \
    --argjson workers "$(jq -s '.' "$candidates_file")" \
    --argjson artifacts "$(jq -s '.' "$artifacts_file")" \
    '{schema_version:1,kind:"studio-ios-routing-status",created_at:$ts,chain:$chain,active_chains:$active_chains,queues:$queues,active_locks:$locks,active_jobs:($workers | map(select(.active_job != null)) | map({executor,active_job})),workers:$workers,simulator_slots:($workers | map({executor,simulator_slots})),disk_pressure:($workers | map({executor,disk_pressure})),stale_workers:($workers | map(select(.stale == true))),retained_artifacts:$artifacts,affinity_break_reasons:($active_chains | map(.last_break_reason) | map(select(. != null and . != "")))}'
  rm -f "$affinities_file" "$queues_file" "$locks_file" "$candidates_file" "$artifacts_file" 2>/dev/null || true
}

if [ "$COMMAND" = "status" ]; then
  status_view
  exit 0
fi

CANDIDATES_FILE=$(mktemp 2>/dev/null || printf '/tmp/ios-router-candidates-%s' "$$")
trap 'rm -f "$CANDIDATES_FILE" 2>/dev/null || true' EXIT INT TERM
: >"$CANDIDATES_FILE"

source_sync_check() {
  local id="$1" is_local="$2"
  if [ "$is_local" = "true" ]; then
    jq -n '{fresh:true,state:"local",age_s:0,reason:null,proof:null}'
    return 0
  fi
  local proof_file proof synced_at synced_epoch age_s reason fresh
  proof_file="$SOURCE_PROOF_DIR/$(safe_segment "$id").json"
  proof=$(file_json_or_empty "$proof_file")
  reason=""
  fresh=true
  if [ ! -r "$proof_file" ]; then
    fresh=false
    reason="source_sync_missing"
  fi
  if [ "$fresh" = "true" ]; then
    for pair in \
      "source_branch:$SOURCE_BRANCH" \
      "base_sha:$BASE_SHA" \
      "worktree_sha:$WORKTREE_SHA" \
      "run_id:$RUN_ID" \
      "chain_run_id:$CHAIN_RUN_ID" \
      "issue_run_id:$ISSUE_RUN_ID" \
      "manifest_version:$MANIFEST_VERSION"; do
      key=${pair%%:*}
      expected=${pair#*:}
      [ -n "$expected" ] || continue
      observed=$(json_get "$proof" ".${key}")
      if [ "$observed" != "$expected" ]; then
        fresh=false
        reason="source_sync_${key}_mismatch"
        break
      fi
    done
  fi
  synced_at=$(json_get "$proof" '.synced_at')
  synced_epoch=$(ts_epoch "$synced_at")
  age_s=0
  if [ "$synced_epoch" -gt 0 ]; then
    age_s=$((NOW_EPOCH - synced_epoch))
    [ "$age_s" -lt 0 ] && age_s=0
  elif [ "$fresh" = "true" ]; then
    fresh=false
    reason="source_sync_timestamp_missing"
  fi
  if [ "$fresh" = "true" ] && [ "$age_s" -gt "$SOURCE_SYNC_TTL_S" ]; then
    fresh=false
    reason="source_sync_stale"
  fi
  jq -n \
    --argjson fresh "$fresh" \
    --arg state "$([ "$fresh" = "true" ] && printf fresh || printf stale)" \
    --argjson age_s "$age_s" \
    --arg reason "$reason" \
    --arg proof "$proof_file" \
    '{fresh:$fresh,state:$state,age_s:$age_s,reason:(if $reason == "" then null else $reason end),proof:$proof}'
}

queue_depth_for() {
  local id="$1" qdir
  qdir="$(resolve_runtime_global)/build-queue/$id"
  find "$qdir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

active_locks_for() {
  local id="$1" lock_dir
  lock_dir="$(resolve_runtime_global)/xcodebuild-lock/$id"
  find "$lock_dir" -mindepth 1 -maxdepth 1 -type d -name 'slot-*' 2>/dev/null | wc -l | tr -d ' '
}

slots_for_json() {
  local id="$1" node_json="$2" slots
  if [ "$id" = "local" ]; then
    printf '1\n'
    return 0
  fi
  slots=$(json_get "$node_json" '.parallel_build_slots')
  slots=$(num_or_default "$slots" 1)
  [ "$slots" -lt 1 ] && slots=1
  printf '%s\n' "$slots"
}

add_candidate() {
  local id="$1" node_json="$2" is_local="$3"
  local state_json parity_json health_status probed_at probed_epoch probe_age_s status_fresh
  local enabled role_ok secret_ok xcode_candidate xcode_ok swift_version simulator_available
  local ram_gib load1 load_ok ram_ok queue_depth queue_wait_s slots active_locks lock_state lock_ok
  local source_json cache_warmth disk_pressure REASONS reasons_json eligible reason_class remote_total_s

  state_json=$(file_json_or_empty "$CANDIDATE_STATE_DIR/$(safe_segment "$id").json")
  parity_json="{}"
  if [ -r "$(resolve_runtime_global)/node-parity-cache.json" ]; then
    parity_json=$(jq -c --arg id "$id" '.nodes[$id] // {}' "$(resolve_runtime_global)/node-parity-cache.json" 2>/dev/null || printf '{}')
  fi

  REASONS=""
  enabled=true
  if [ "$is_local" != "true" ]; then
    enabled=$(printf '%s\n' "$node_json" | jq -r 'if .enabled == false then "false" else "true" end' 2>/dev/null || printf false)
  fi
  [ "$enabled" = "true" ] || append_reason "disabled"

  role_ok=true
  if [ "$is_local" != "true" ]; then
    role_ok=$(printf '%s\n' "$node_json" | jq -r --arg role "$ROLE" '(.roles // [] | index($role)) != null' 2>/dev/null || printf false)
  fi
  [ "$role_ok" = "true" ] || append_reason "role_mismatch"

  secret_ok=true
  if [ -n "$REQUIRED_SECRET_SCOPES" ] && [ "$REQUIRED_SECRET_SCOPES" != "none" ]; then
    if [ "$is_local" = "true" ]; then
      secret_ok=true
    else
      secret_ok=$(printf '%s\n' "$node_json" | jq -r --arg req "$REQUIRED_SECRET_SCOPES" \
        '($req | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $r | (($r - (.secret_scopes // [])) == [])' 2>/dev/null || printf false)
    fi
  fi
  [ "$secret_ok" = "true" ] || append_reason "secret_scope_mismatch"

  health_status=$(json_get "$state_json" '.health_status')
  [ -n "$health_status" ] || health_status=$(json_get "$state_json" '.health.status')
  [ -n "$health_status" ] || health_status=$(json_get "$node_json" '.ios_routing.health_status')
  [ -n "$health_status" ] || health_status=$(json_get "$node_json" '.health_status')
  if [ -z "$health_status" ] && [ "$(json_get "$parity_json" '.reachable')" = "true" ]; then
    health_status="healthy"
  fi
  [ "$is_local" = "true" ] && health_status="healthy"
  [ -n "$health_status" ] || health_status="unknown"

  probed_at=$(json_get "$state_json" '.probed_at')
  [ -n "$probed_at" ] || probed_at=$(json_get "$state_json" '.observed_at')
  [ -n "$probed_at" ] || probed_at=$(json_get "$node_json" '.ios_routing.probed_at')
  [ -n "$probed_at" ] || probed_at=$(json_get "$parity_json" '.probed_at')
  [ -n "$probed_at" ] || probed_at=$(jq -r '.generated_at // empty' "$(resolve_runtime_global)/node-parity-cache.json" 2>/dev/null || true)
  [ "$is_local" = "true" ] && probed_at="$CREATED_AT"
  probed_epoch=$(ts_epoch "$probed_at")
  probe_age_s=0
  status_fresh=true
  if [ "$probed_epoch" -gt 0 ]; then
    probe_age_s=$((NOW_EPOCH - probed_epoch))
    [ "$probe_age_s" -lt 0 ] && probe_age_s=0
    [ "$probe_age_s" -le "$PROBE_TTL_S" ] || status_fresh=false
  else
    status_fresh=false
  fi

  case "$health_status" in
    healthy|moved) ;;
    *) append_reason "health_$health_status" ;;
  esac
  [ "$status_fresh" = "true" ] || append_reason "health_cache_stale"

  xcode_candidate=$(json_get "$state_json" '.xcode_version')
  [ -n "$xcode_candidate" ] || xcode_candidate=$(json_get "$node_json" '.ios_routing.xcode_version')
  [ -n "$xcode_candidate" ] || xcode_candidate=$(json_get "$parity_json" '.xcodebuild.version')
  [ "$is_local" = "true" ] && [ -z "$xcode_candidate" ] && xcode_candidate="$XCODE_VERSION"
  xcode_ok=true
  if [ -n "$XCODE_VERSION" ]; then
    required_major=$(major_version "$XCODE_VERSION")
    candidate_major=$(major_version "$xcode_candidate")
    if [ -z "$candidate_major" ]; then
      xcode_ok=false
      append_reason "xcode_version_unknown"
    elif [ -n "$required_major" ] && [ "$required_major" != "$candidate_major" ]; then
      xcode_ok=false
      append_reason "xcode_version_mismatch"
    fi
  fi

  swift_version=$(json_get "$state_json" '.swift_version')
  [ -n "$swift_version" ] || swift_version=$(json_get "$node_json" '.ios_routing.swift_version')
  [ -n "$swift_version" ] || swift_version=$(json_get "$parity_json" '.swift')

  simulator_available=$(json_get "$state_json" '.simulator_available')
  [ -n "$simulator_available" ] || simulator_available=$(json_get "$node_json" '.ios_routing.simulator_available')
  if [ -z "$simulator_available" ] && [ -n "$SIMULATOR_RUNTIME" ]; then
    simulator_available=$(printf '%s\n' "$parity_json" | jq -r --arg runtime "$SIMULATOR_RUNTIME" '(.simctl_ios_runtimes // [] | index($runtime)) != null' 2>/dev/null || printf false)
  fi
  [ "$is_local" = "true" ] && [ -z "$simulator_available" ] && simulator_available=true
  [ -n "$simulator_available" ] || simulator_available=false
  if operation_needs_simulator && [ "$simulator_available" != "true" ]; then
    append_reason "simulator_unavailable"
  fi

  ram_gib=$(json_get "$state_json" '.ram_available_gib')
  [ -n "$ram_gib" ] || ram_gib=$(json_get "$node_json" '.ios_routing.ram_available_gib')
  [ -n "$ram_gib" ] || ram_gib=$(json_get "$node_json" '.ram_available_gib')
  [ "$is_local" = "true" ] && [ -z "$ram_gib" ] && ram_gib="$MIN_RAM_GIB"
  ram_gib=$(num_or_default "$ram_gib" 0)
  ram_ok=true
  [ "$ram_gib" -ge "$MIN_RAM_GIB" ] || { ram_ok=false; append_reason "ram_low"; }

  load1=$(json_get "$state_json" '.load1')
  [ -n "$load1" ] || load1=$(json_get "$node_json" '.ios_routing.load1')
  [ -n "$load1" ] || load1=$(json_get "$node_json" '.load1')
  [ "$is_local" = "true" ] && [ -z "$load1" ] && load1="0"
  load1=$(float_or_default "$load1" 999)
  load_ok=$(awk -v load="$load1" -v max="$MAX_LOAD" 'BEGIN { print (load <= max) ? "true" : "false" }')
  [ "$load_ok" = "true" ] || append_reason "load_high"

  slots=$(slots_for_json "$id" "$node_json")
  queue_depth=$(json_get "$state_json" '.queue_depth')
  [ -n "$queue_depth" ] || queue_depth=$(queue_depth_for "$id")
  queue_depth=$(num_or_default "$queue_depth" 0)
  queue_wait_s=$(json_get "$state_json" '.queue_wait_s')
  if [ -z "$queue_wait_s" ]; then
    queue_wait_s=$((queue_depth * QUEUE_SLOT_SECONDS / slots))
  fi
  queue_wait_s=$(num_or_default "$queue_wait_s" 0)

  active_locks=$(json_get "$state_json" '.active_locks')
  [ -n "$active_locks" ] || active_locks=$(active_locks_for "$id")
  active_locks=$(num_or_default "$active_locks" 0)
  lock_state="available"
  lock_ok=true
  if [ "$active_locks" -ge "$slots" ]; then
    lock_state="queued"
  fi
  if [ "$queue_wait_s" -gt "$MAX_AFFINITY_WAIT_S" ]; then
    lock_ok=false
    append_reason "queue_delay_threshold"
  fi

  if [ "$is_local" = "true" ]; then
    manager_responsive="${STUDIO_IOS_MANAGER_RESPONSIVE:-1}"
    if ! truthy "$manager_responsive" && [ "$ALLOW_MANAGER_IMPACT" != "1" ]; then
      append_reason "manager_responsiveness_risk"
    fi
    if truthy "${STUDIO_IOS_MANAGER_BUSY_BUILD_TEST:-0}"; then
      local env_wait
      env_wait=$(num_or_default "${STUDIO_IOS_MANAGER_QUEUE_WAIT_S:-}" 0)
      [ "$env_wait" -gt "$queue_wait_s" ] && queue_wait_s="$env_wait"
      lock_state="busy"
    fi
  fi

  source_json=$(source_sync_check "$id" "$is_local")
  source_fresh=$(printf '%s\n' "$source_json" | jq -r '.fresh')
  if [ "$source_fresh" != "true" ]; then
    append_reason "$(printf '%s\n' "$source_json" | jq -r '.reason // "source_sync_unfresh"')"
  fi

  cache_warmth=$(json_get "$state_json" '.cache_warmth')
  [ -n "$cache_warmth" ] || cache_warmth=$(json_get "$node_json" '.ios_routing.cache_warmth')
  [ -n "$cache_warmth" ] || cache_warmth="unknown"
  disk_pressure=$(json_get "$state_json" '.disk_pressure')
  [ -n "$disk_pressure" ] || disk_pressure=$(json_get "$node_json" '.ios_routing.disk_pressure')
  [ "$disk_pressure" = "high" ] && append_reason "disk_pressure"
  [ -n "$disk_pressure" ] || disk_pressure="unknown"

  reasons_json=$(printf '%s\n' "$REASONS" | sed '/^$/d' | json_lines_to_array)
  eligible=false
  reason_class="eligible"
  if [ "$(printf '%s\n' "$reasons_json" | jq 'length')" -eq 0 ]; then
    eligible=true
  else
    reason_class=$(printf '%s\n' "$reasons_json" | jq -r '.[0]')
  fi

  remote_total_s=$((queue_wait_s + REMOTE_SETUP_COST_S + RETRY_COST_S))
  jq -n \
    --arg id "$id" \
    --argjson is_local "$is_local" \
    --argjson eligible "$eligible" \
    --arg reason_class "$reason_class" \
    --argjson reasons "$reasons_json" \
    --argjson enabled "$enabled" \
    --argjson role_ok "$role_ok" \
    --arg health_status "$health_status" \
    --argjson status_fresh "$status_fresh" \
    --argjson probe_age_s "$probe_age_s" \
    --arg xcode_version "$xcode_candidate" \
    --arg swift_version "$swift_version" \
    --argjson xcode_ok "$xcode_ok" \
    --argjson simulator_available "$simulator_available" \
    --argjson ram_available_gib "$ram_gib" \
    --argjson load1 "$load1" \
    --argjson load_ok "$load_ok" \
    --argjson ram_ok "$ram_ok" \
    --arg lock_state "$lock_state" \
    --argjson lock_ok "$lock_ok" \
    --argjson active_locks "$active_locks" \
    --argjson slots "$slots" \
    --argjson queue_depth "$queue_depth" \
    --argjson queue_wait_s "$queue_wait_s" \
    --argjson secret_ok "$secret_ok" \
    --argjson source_sync "$source_json" \
    --arg cache_warmth "$cache_warmth" \
    --arg disk_pressure "$disk_pressure" \
    --argjson remote_total_s "$remote_total_s" \
    '{id:$id,is_local:$is_local,eligible:$eligible,reason_class:$reason_class,reasons:$reasons,predicates:{role:$role_ok,health:{status:$health_status,fresh:$status_fresh,age_s:$probe_age_s},xcode_toolchain:{ok:$xcode_ok,xcode_version:$xcode_version,swift_version:$swift_version},simulator_available:$simulator_available,ram_load:{ram_available_gib:$ram_available_gib,ram_ok:$ram_ok,load1:$load1,load_ok:$load_ok},lock_state:{state:$lock_state,ok:$lock_ok,active_locks:$active_locks,slots:$slots},queue:{depth:$queue_depth,wait_s:$queue_wait_s},secret_scope:$secret_ok,source_sync:$source_sync,disk_pressure:$disk_pressure},queue:{depth:$queue_depth,wait_s:$queue_wait_s,slots:$slots},cache:{warmth:$cache_warmth},economics:{remote_total_s:$remote_total_s,remote_setup_cost_s:'"$REMOTE_SETUP_COST_S"',retry_cost_s:'"$RETRY_COST_S"'}}' \
    >>"$CANDIDATES_FILE"
}

add_candidate "local" "{}" true

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ -r "$REGISTRY" ]; then
  while IFS= read -r node_json; do
    [ -n "$node_json" ] || continue
    id=$(printf '%s\n' "$node_json" | jq -r '.id // empty')
    [ -n "$id" ] || continue
    node_is_self "$id" && continue
    add_candidate "$id" "$node_json" false
  done <<EOF
$(jq -c '.nodes[]?' "$REGISTRY" 2>/dev/null)
EOF
fi

CANDIDATES_JSON=$(jq -s '.' "$CANDIDATES_FILE")
LOCAL_QUEUE_WAIT_S=$(printf '%s\n' "$CANDIDATES_JSON" | jq -r '.[] | select(.id == "local") | .queue.wait_s // 0')
LOCAL_ELIGIBLE=$(printf '%s\n' "$CANDIDATES_JSON" | jq -r '.[] | select(.id == "local") | .eligible')
WORKER_ELIGIBLE_COUNT=$(printf '%s\n' "$CANDIDATES_JSON" | jq '[.[] | select(.is_local == false and .eligible == true)] | length')
SELECTED="local"
REASON_CLASS="local_first"
REASON="local manager selected"
AFFINITY_DECISION="none"
AFFINITY_PREFERRED=""
AFFINITY_BREAK_REASON=""
BENEFICIAL=false

select_worker_by_id() {
  local id="$1"
  printf '%s\n' "$CANDIDATES_JSON" | jq -e -r --arg id "$id" '.[] | select(.id == $id and .eligible == true) | .id' 2>/dev/null | head -1
}

best_worker() {
  printf '%s\n' "$CANDIDATES_JSON" | jq -r '
    [.[] | select(.is_local == false and .eligible == true)]
    | sort_by(.economics.remote_total_s, .queue.wait_s, .predicates.ram_load.load1)
    | .[0].id // ""
  '
}

affinity_candidate_reason() {
  local id="$1"
  printf '%s\n' "$CANDIDATES_JSON" | jq -r --arg id "$id" '.[] | select(.id == $id) | .reason_class // "missing_candidate"' 2>/dev/null | head -1
}

affinity_json="{}"
if [ -r "$AFFINITY_FILE" ]; then
  affinity_json=$(cat "$AFFINITY_FILE")
  AFFINITY_PREFERRED=$(json_get "$affinity_json" '.preferred_executor')
fi

if [ "$FORCE_LOCAL" = "1" ]; then
  SELECTED="local"
  REASON_CLASS="user_force_local"
  REASON="user override forced local manager"
elif [ -n "$FORCE_WORKER" ]; then
  forced=$(select_worker_by_id "$FORCE_WORKER")
  if [ -n "$forced" ]; then
    SELECTED="$forced"
    REASON_CLASS="user_force_worker"
    REASON="user override forced named eligible worker"
    AFFINITY_DECISION="forced"
  else
    SELECTED="local"
    REASON_CLASS="user_force_worker_ineligible_fallback"
    REASON="named worker failed eligibility checks; local manager fallback"
  fi
elif ! operation_is_expensive; then
  SELECTED="local"
  REASON_CLASS="local_first_light_check"
  REASON="normal implementation or light check stays local"
elif [ -n "$AFFINITY_PREFERRED" ] && [ "$BREAK_AFFINITY" != "1" ]; then
  expires_at=$(json_get "$affinity_json" '.expires_at')
  expires_epoch=$(ts_epoch "$expires_at")
  affinity_cache=$(json_get "$affinity_json" '.cache_key')
  if [ "$expires_epoch" -gt 0 ] && [ "$expires_epoch" -lt "$NOW_EPOCH" ]; then
    AFFINITY_DECISION="stale"
    AFFINITY_BREAK_REASON="stale_affinity"
  elif [ -n "$CACHE_KEY" ] && [ -n "$affinity_cache" ] && [ "$CACHE_KEY" != "$affinity_cache" ]; then
    AFFINITY_DECISION="broken"
    AFFINITY_BREAK_REASON="cold_or_invalid_cache"
  elif affinity_selected=$(select_worker_by_id "$AFFINITY_PREFERRED"); [ -n "$affinity_selected" ]; then
    SELECTED="$affinity_selected"
    REASON_CLASS="affinity_reused"
    REASON="chain build/test affinity reused warm executor"
    AFFINITY_DECISION="reused"
  else
    AFFINITY_DECISION="broken"
    AFFINITY_BREAK_REASON=$(affinity_candidate_reason "$AFFINITY_PREFERRED")
  fi
elif [ -n "$AFFINITY_PREFERRED" ] && [ "$BREAK_AFFINITY" = "1" ]; then
  AFFINITY_DECISION="broken"
  AFFINITY_BREAK_REASON="user_override"
fi

if [ "$REASON_CLASS" = "local_first" ]; then
  if [ "$LOCAL_ELIGIBLE" != "true" ] && [ "$WORKER_ELIGIBLE_COUNT" -gt 0 ]; then
    SELECTED=$(best_worker)
    REASON_CLASS="manager_responsiveness_offload"
    REASON="manager local execution failed responsiveness eligibility"
    AFFINITY_DECISION="${AFFINITY_DECISION:-set}"
  elif [ "$LOCAL_QUEUE_WAIT_S" -le 0 ]; then
    SELECTED="local"
    REASON_CLASS="local_first_manager_available"
    REASON="manager is eligible and has no build/test wait"
  elif [ "$WORKER_ELIGIBLE_COUNT" -eq 0 ]; then
    SELECTED="local"
    REASON_CLASS="no_eligible_worker_fallback"
    REASON="no worker passed capability, health, load, queue, secret, and source-sync checks"
  else
    candidate=$(best_worker)
    worker_total=$(printf '%s\n' "$CANDIDATES_JSON" | jq -r --arg id "$candidate" '.[] | select(.id == $id) | .economics.remote_total_s')
    manager_savings=$((LOCAL_QUEUE_WAIT_S - worker_total))
    if [ "$manager_savings" -ge "$MIN_SAVINGS_S" ]; then
      SELECTED="$candidate"
      REASON_CLASS="worker_offload_beneficial"
      REASON="worker offload beats manager wait by the configured threshold"
      BENEFICIAL=true
      [ -z "$AFFINITY_DECISION" ] || [ "$AFFINITY_DECISION" = "none" ] && AFFINITY_DECISION="set"
    else
      SELECTED="local"
      REASON_CLASS="cost_threshold_refusal"
      REASON="remote setup and retry costs erase the manager-wait savings"
    fi
  fi
fi

SELECTED_CANDIDATE=$(printf '%s\n' "$CANDIDATES_JSON" | jq -c --arg id "$SELECTED" '.[] | select(.id == $id)' | head -1)
[ -n "$SELECTED_CANDIDATE" ] || SELECTED_CANDIDATE=$(printf '%s\n' "$CANDIDATES_JSON" | jq -c '.[] | select(.id == "local")' | head -1)
SELECTED_QUEUE_WAIT_S=$(printf '%s\n' "$SELECTED_CANDIDATE" | jq -r '.queue.wait_s // 0')
SELECTED_REMOTE_TOTAL_S=$(printf '%s\n' "$SELECTED_CANDIDATE" | jq -r '.economics.remote_total_s // 0')
MANAGER_SAVINGS_S=$((LOCAL_QUEUE_WAIT_S - SELECTED_REMOTE_TOTAL_S))
[ "$SELECTED" = "local" ] && MANAGER_SAVINGS_S=0
[ "$MANAGER_SAVINGS_S" -lt 0 ] && MANAGER_SAVINGS_S=0

if [ "$SELECTED" != "local" ] && operation_is_expensive && [ "$DRY_RUN_FLAG" != "1" ]; then
  set_at="$CREATED_AT"
  expires_at=$(date -u -r $((NOW_EPOCH + AFFINITY_TTL_S)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((NOW_EPOCH + AFFINITY_TTL_S))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
  affinity_doc=$(jq -n \
    --arg chain "$CHAIN" \
    --arg source_branch "$SOURCE_BRANCH" \
    --arg executor "$SELECTED" \
    --arg cache_key "$CACHE_KEY" \
    --arg job "$TASK_ID" \
    --arg set_at "$set_at" \
    --arg expires_at "$expires_at" \
    --arg reason "$REASON_CLASS" \
    '{schema_version:1,kind:"ios-chain-affinity",chain:$chain,source_branch:$source_branch,preferred_executor:$executor,derived_data_cache_key:$cache_key,cache_key:$cache_key,set_by_job:$job,set_at:$set_at,expires_at:$expires_at,last_reused_at:null,last_break_reason:null,set_reason:$reason}')
  tmp_affinity=$(mktemp "${AFFINITY_FILE}.XXXXXX" 2>/dev/null || printf '%s.tmp' "$AFFINITY_FILE")
  printf '%s\n' "$affinity_doc" >"$tmp_affinity" && mv "$tmp_affinity" "$AFFINITY_FILE"
elif [ -n "$AFFINITY_BREAK_REASON" ] && [ -r "$AFFINITY_FILE" ] && [ "$DRY_RUN_FLAG" != "1" ]; then
  tmp_affinity=$(mktemp "${AFFINITY_FILE}.XXXXXX" 2>/dev/null || printf '%s.tmp' "$AFFINITY_FILE")
  jq --arg reason "$AFFINITY_BREAK_REASON" --arg ts "$CREATED_AT" '.last_break_reason = $reason | .last_break_at = $ts' "$AFFINITY_FILE" >"$tmp_affinity" \
    && mv "$tmp_affinity" "$AFFINITY_FILE"
fi

END_MS=$(now_ms)
OVERHEAD_MS=$((END_MS - START_MS))
[ "$OVERHEAD_MS" -lt 0 ] && OVERHEAD_MS=0

REJECTED=$(printf '%s\n' "$CANDIDATES_JSON" | jq --arg selected "$SELECTED" '[.[] | select(.id != $selected and .eligible == false) | {id,reason_class,reasons,predicates:{role:.predicates.role,health:.predicates.health,xcode_toolchain:.predicates.xcode_toolchain,simulator_available:.predicates.simulator_available,ram_load:.predicates.ram_load,lock_state:.predicates.lock_state,queue:.predicates.queue,secret_scope:.predicates.secret_scope,source_sync:.predicates.source_sync,cache:.cache,disk_pressure:.predicates.disk_pressure}}]')
SYNC_REMEDIATION=$(printf '%s\n' "$CANDIDATES_JSON" | jq \
  --arg selected "$SELECTED" \
  --arg reason "$REASON_CLASS" \
  --argjson manager_wait "$LOCAL_QUEUE_WAIT_S" \
  --argjson min_savings "$MIN_SAVINGS_S" '
    [.[] | select(.is_local == false and .eligible == false and (.reasons | length > 0) and (all(.reasons[]; startswith("source_sync_"))))]
    | sort_by(.economics.remote_total_s, .queue.wait_s)
    | .[0] as $candidate
    | if ($selected == "local" and $reason == "no_eligible_worker_fallback" and $candidate != null and (($manager_wait - ($candidate.economics.remote_total_s // 0)) >= $min_savings)) then
        {required:true,candidate_executor:$candidate.id,reason:"source_sync_bootstrap_required",candidate_queue_wait_s:($candidate.queue.wait_s // 0),candidate_remote_total_s:($candidate.economics.remote_total_s // 0)}
      else
        {required:false,candidate_executor:null,reason:null,candidate_queue_wait_s:null,candidate_remote_total_s:null}
      end')

DECISION=$(jq -n \
  --arg ts "$CREATED_AT" \
  --arg operation "$OPERATION" \
  --arg role "$ROLE" \
  --arg chain "$CHAIN" \
  --arg task "$TASK_ID" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg selected "$SELECTED" \
  --arg reason_class "$REASON_CLASS" \
  --arg reason "$REASON" \
  --argjson user_blocked "$(truthy "$USER_BLOCKED" && printf true || printf false)" \
  --argjson beneficial "$BENEFICIAL" \
  --argjson manager_savings_s "$MANAGER_SAVINGS_S" \
  --argjson manager_queue_wait_s "$LOCAL_QUEUE_WAIT_S" \
  --argjson selected_queue_wait_s "$SELECTED_QUEUE_WAIT_S" \
  --argjson remote_latency_cost_s "$REMOTE_SETUP_COST_S" \
  --argjson retry_cost_s "$RETRY_COST_S" \
  --argjson cost_threshold_s "$MIN_SAVINGS_S" \
  --argjson max_affinity_queue_wait_s "$MAX_AFFINITY_WAIT_S" \
  --arg affinity_decision "$AFFINITY_DECISION" \
  --arg affinity_preferred "$AFFINITY_PREFERRED" \
  --arg affinity_break_reason "$AFFINITY_BREAK_REASON" \
  --arg cache_key "$CACHE_KEY" \
  --argjson selected_candidate "$SELECTED_CANDIDATE" \
  --argjson candidates "$CANDIDATES_JSON" \
  --argjson rejected "$REJECTED" \
  --argjson source_sync_remediation "$SYNC_REMEDIATION" \
  --argjson overhead_ms "$OVERHEAD_MS" \
  --argjson overhead_budget_ms "$OVERHEAD_BUDGET_MS" \
  '{schema_version:1,kind:"studio-ios-routing-decision",created_at:$ts,operation:$operation,role:$role,chain:$chain,task_id:$task,source_branch:$source_branch,selected_executor:$selected,selected_is_local:($selected == "local"),reason_class:$reason_class,reason:$reason,user_blocked:$user_blocked,eligibility_predicates:["role","health","xcode_toolchain_version","simulator_availability","ram_load","lock_state","queue_depth","secret_scope","source_sync_freshness"],economics:{manager_savings_s:$manager_savings_s,manager_queue_wait_s:$manager_queue_wait_s,selected_queue_wait_s:$selected_queue_wait_s,remote_latency_cost_s:$remote_latency_cost_s,retry_cost_s:$retry_cost_s,cost_threshold_s:$cost_threshold_s,beneficial:$beneficial,user_blocked:$user_blocked},affinity:{decision:$affinity_decision,preferred_executor:(if $affinity_preferred == "" then null else $affinity_preferred end),break_reason:(if $affinity_break_reason == "" then null else $affinity_break_reason end),max_queue_wait_s:$max_affinity_queue_wait_s},cache:{key:$cache_key,selected_warmth:$selected_candidate.cache.warmth},source_sync_remediation:$source_sync_remediation,selected_candidate:$selected_candidate,rejected_executors:$rejected,candidates:$candidates,scheduler:{overhead_ms:$overhead_ms,overhead_budget_ms:$overhead_budget_ms,over_budget:($overhead_ms > $overhead_budget_ms)}}')

if [ "$NO_TELEMETRY" != "1" ] && [ "$DRY_RUN_FLAG" != "1" ] && command -v emit_event_keyed >/dev/null 2>&1; then
  EVENT_PAYLOAD=$(printf '%s\n' "$DECISION" | jq -c '{selected_executor,reason_class,operation,role,chain,task_id,economics,affinity,source_sync_remediation,rejected_executors:([.rejected_executors[] | {id,reason_class,reasons}]),scheduler}')
  emit_event_keyed studio scheduler ios_check_routing_decision "$TASK_ID" "$EVENT_PAYLOAD" \
    --idem-key "ios-route:${CHAIN}:${TASK_ID}:${OPERATION}:${SELECTED}:${REASON_CLASS}" >/dev/null 2>&1 || true
fi

if [ -n "${STUDIO_IOS_ROUTING_DECISION_FILE:-}" ]; then
  mkdir -p "$(dirname "$STUDIO_IOS_ROUTING_DECISION_FILE")" 2>/dev/null || true
  printf '%s\n' "$DECISION" >"$STUDIO_IOS_ROUTING_DECISION_FILE" 2>/dev/null || true
fi

case "$COMMAND" in
  pick)
    printf '%s\n' "$SELECTED"
    ;;
  explain)
    if [ "$JSON_OUTPUT" = "1" ]; then
      printf '%s\n' "$DECISION"
    else
      printf '%s: %s (%s)\n' "$SELECTED" "$REASON_CLASS" "$REASON"
    fi
    ;;
esac
