#!/usr/bin/env bash
# studio-ios-check-failover.sh - typed failover decisions for routed iOS build/test checks.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || { printf 'studio-ios-check-failover: jq required\n' >&2; exit 2; }

COMMAND="decide"
if [ $# -gt 0 ]; then
  case "$1" in
    decide)
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
SELECTED_EXECUTOR=""
FAILURE_SIGNAL=""
EXIT_CODE=""
LOG_PATH=""
ARTIFACT_PATH=""
ARTIFACT_KIND=""
ROUTE_DECISION_FILE=""
ATTEMPT="1"
RETRY_COUNT=""
RETRY_COUNT_EXPLICIT=0
MAX_RETRIES="${STUDIO_IOS_FAILOVER_MAX_RETRIES:-2}"
NO_TELEMETRY=0
PRESERVE_ARTIFACTS=1
ROUTE_STATUS="ok"
ROUTE_ERROR=""

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/studio-ios-check-failover.sh decide [options]

Options:
  --operation <build|test|test:unit|test:ui>
  --role <xcodebuild|swift-test>
  --chain <name> --task-id <id> --worktree <path>
  --source-branch <branch> --base-sha <sha> --worktree-sha <sha>
  --run-id <id> --chain-run-id <id> --issue-run-id <id> --manifest-version <n>
  --selected-executor <node-id>
  --failure-signal <worker_unavailable|remote_timeout|build_invocation_failed|artifact_missing|artifact_malformed|source_sync_worktree_sha_mismatch|...>
  --exit-code <n> --log <path> --artifact <path> --artifact-kind <name>
  --route-decision-file <path>
  --attempt <n> --retry-count <n> --max-retries <n>
  --no-telemetry
  --no-preserve-artifacts
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
    --worktree) WORKTREE="${2:?--worktree requires a path}"; shift 2 ;;
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
    --selected-executor) SELECTED_EXECUTOR="${2:?--selected-executor requires a value}"; shift 2 ;;
    --selected-executor=*) SELECTED_EXECUTOR="${1#--selected-executor=}"; shift ;;
    --failure-signal) FAILURE_SIGNAL="${2:?--failure-signal requires a value}"; shift 2 ;;
    --failure-signal=*) FAILURE_SIGNAL="${1#--failure-signal=}"; shift ;;
    --exit-code) EXIT_CODE="${2:?--exit-code requires a value}"; shift 2 ;;
    --exit-code=*) EXIT_CODE="${1#--exit-code=}"; shift ;;
    --log) LOG_PATH="${2:?--log requires a path}"; shift 2 ;;
    --log=*) LOG_PATH="${1#--log=}"; shift ;;
    --artifact) ARTIFACT_PATH="${2:?--artifact requires a path}"; shift 2 ;;
    --artifact=*) ARTIFACT_PATH="${1#--artifact=}"; shift ;;
    --artifact-kind) ARTIFACT_KIND="${2:?--artifact-kind requires a value}"; shift 2 ;;
    --artifact-kind=*) ARTIFACT_KIND="${1#--artifact-kind=}"; shift ;;
    --route-decision-file) ROUTE_DECISION_FILE="${2:?--route-decision-file requires a path}"; shift 2 ;;
    --route-decision-file=*) ROUTE_DECISION_FILE="${1#--route-decision-file=}"; shift ;;
    --attempt) ATTEMPT="${2:?--attempt requires a value}"; shift 2 ;;
    --attempt=*) ATTEMPT="${1#--attempt=}"; shift ;;
    --retry-count) RETRY_COUNT="${2:?--retry-count requires a value}"; RETRY_COUNT_EXPLICIT=1; shift 2 ;;
    --retry-count=*) RETRY_COUNT="${1#--retry-count=}"; RETRY_COUNT_EXPLICIT=1; shift ;;
    --max-retries) MAX_RETRIES="${2:?--max-retries requires a value}"; shift 2 ;;
    --max-retries=*) MAX_RETRIES="${1#--max-retries=}"; shift ;;
    --no-telemetry) NO_TELEMETRY=1; shift ;;
    --no-preserve-artifacts) PRESERVE_ARTIFACTS=0; shift ;;
    -h|--help) usage ;;
    *) printf 'studio-ios-check-failover: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[ "$COMMAND" = "decide" ] || usage
[ -n "$TASK_ID" ] || TASK_ID="unknown"
[ -n "$SELECTED_EXECUTOR" ] || SELECTED_EXECUTOR="unknown"
case "$ATTEMPT" in ''|*[!0-9]*) ATTEMPT=1 ;; esac
case "$MAX_RETRIES" in ''|*[!0-9]*) MAX_RETRIES=2 ;; esac
case "$EXIT_CODE" in ''|*[!0-9]*) EXIT_CODE=1 ;; esac

safe_segment() {
  local value="${1:-unknown}" safe
  safe=$(printf '%s' "$value" | sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  [ -n "$safe" ] || safe="unknown"
  printf '%s\n' "$safe"
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

chain_envelope_field() {
  local field="$1" envelope
  [ -n "$WORKTREE" ] || return 0
  envelope="$WORKTREE/.studio/chain-task-start.json"
  [ -r "$envelope" ] || return 0
  jq -r --arg field "$field" '.[$field] // empty' "$envelope" 2>/dev/null || true
}

chain_ownership_field() {
  local field="$1" envelope
  [ -n "$WORKTREE" ] || return 0
  envelope="$WORKTREE/.studio/chain-task-start.json"
  [ -r "$envelope" ] || return 0
  jq -r --arg field "$field" '.ownership[$field] // empty' "$envelope" 2>/dev/null || true
}

[ -n "$CHAIN" ] || CHAIN=$(chain_ownership_field chain)
[ -n "$CHAIN" ] || CHAIN=$(chain_envelope_field chain)
[ -n "$CHAIN" ] || CHAIN="standalone"
[ -n "$RUN_ID" ] || RUN_ID=$(chain_envelope_field run_id)
[ -n "$CHAIN_RUN_ID" ] || CHAIN_RUN_ID=$(chain_envelope_field chain_run_id)
[ -n "$ISSUE_RUN_ID" ] || ISSUE_RUN_ID=$(chain_envelope_field issue_run_id)
[ -n "$SOURCE_BRANCH" ] || SOURCE_BRANCH=$(chain_ownership_field source_branch)
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

failover_state_dir() {
  local project root
  project=$(resolve_project 2>/dev/null || printf unknown)
  root=$(resolve_project_root_for "$project" 2>/dev/null || printf '')
  if [ -n "$root" ]; then
    printf '%s/.runtime/state/ios-check-failover\n' "$root"
  else
    printf '%s/ios-check-failover\n' "$(resolve_runtime_global)"
  fi
}

failover_state_file_for() {
  local key safe
  key="${CHAIN_RUN_ID:-$CHAIN}:${ISSUE_RUN_ID:-$TASK_ID}:$TASK_ID:$OPERATION"
  safe=$(printf '%s' "$key" | sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  [ -n "$safe" ] || safe="unknown"
  printf '%s/%s.json\n' "$(failover_state_dir)" "$safe"
}

STATE_FILE=""
if [ "$RETRY_COUNT_EXPLICIT" = "1" ]; then
  case "$RETRY_COUNT" in ''|*[!0-9]*) RETRY_COUNT=0 ;; esac
else
  STATE_FILE=$(failover_state_file_for)
  if [ -r "$STATE_FILE" ]; then
    RETRY_COUNT=$(jq -r '.next_retry_count // .retry_count // 0' "$STATE_FILE" 2>/dev/null || printf 0)
  else
    RETRY_COUNT=0
  fi
  case "$RETRY_COUNT" in ''|*[!0-9]*) RETRY_COUNT=0 ;; esac
fi

log_contains() {
  local pattern="$1"
  [ -n "$LOG_PATH" ] && [ -r "$LOG_PATH" ] || return 1
  tail -n 250 "$LOG_PATH" 2>/dev/null | grep -Eiq "$pattern"
}

classify_failure() {
  if [ -n "$ARTIFACT_PATH" ] && [ ! -e "$ARTIFACT_PATH" ]; then
    printf 'artifact_missing\n'
    return 0
  fi
  if [ -n "$ARTIFACT_PATH" ] && [ -f "$ARTIFACT_PATH" ] && [ "${ARTIFACT_KIND:-}" = "json" ]; then
    jq empty "$ARTIFACT_PATH" >/dev/null 2>&1 || {
      printf 'artifact_malformed\n'
      return 0
    }
  fi
  case "$FAILURE_SIGNAL" in
    worker_unavailable|node_unreachable|ssh_unreachable|connection_lost|worker_disappeared|source_sync_failed|remote_shell_path_failed|remote_harness_failure)
      printf 'worker_unavailable' ;;
    worker_timeout|remote_timeout|timeout)
      printf 'worker_timeout' ;;
    remote_command_failed|build_invocation_failed|xcodebuild_failed|test_failed)
      printf 'remote_command_failed' ;;
    artifact_missing|result_bundle_missing|summary_missing|log_missing|publication_missing)
      printf 'artifact_missing' ;;
    artifact_malformed|remote_marker_writer_failed|success_marker_absent|result_reporting_failed|invalid_json|publication_malformed)
      printf 'artifact_malformed' ;;
    sync_drift|source_drift|source_sync_*_mismatch|source_sync_stale|source_sync_missing|source_branch_changed)
      printf 'sync_drift' ;;
    cache_poisoning|metadata_mismatch|cache_metadata_mismatch)
      printf 'cache_poisoning' ;;
    stale_lock|scheduler_stale_lock|source_branch_stale_lock|worker_slot_stale_lock|simulator_slot_stale_lock|artifact_publication_stale_lock|cleanup_stale_lock)
      printf 'stale_lock' ;;
    simulator_slot_timeout|simulator_stuck_boot|simulator_erase_failure|simulator_runtime_mismatch|simulator_stale_slot_reclaimed)
      printf '%s' "$FAILURE_SIGNAL" ;;
    "")
      if [ "$EXIT_CODE" -eq 124 ]; then
        printf 'worker_timeout'
      elif log_contains 'Connection (to .* )?(closed|timed out)|Broken pipe|No route to host|Operation timed out|worker disappeared'; then
        printf 'worker_unavailable'
      elif log_contains 'exit marker missing|success marker missing|invalid json|parse error'; then
        printf 'artifact_malformed'
      elif log_contains 'source_sync_.*mismatch|source branch changed|sync drift'; then
        printf 'sync_drift'
      elif [ "$EXIT_CODE" -ne 0 ]; then
        printf 'remote_command_failed'
      else
        printf 'artifact_malformed'
      fi
      ;;
    *)
      if [ "$EXIT_CODE" -eq 124 ]; then
        printf 'worker_timeout'
      elif log_contains 'Connection (to .* )?(closed|timed out)|Broken pipe|No route to host|Operation timed out|worker disappeared'; then
        printf 'worker_unavailable'
      elif log_contains 'exit marker missing|success marker missing|invalid json|parse error'; then
        printf 'artifact_malformed'
      elif log_contains 'source_sync_.*mismatch|source branch changed|sync drift'; then
        printf 'sync_drift'
      elif [ "$EXIT_CODE" -ne 0 ]; then
        printf 'remote_command_failed'
      else
        printf 'artifact_malformed'
      fi
      ;;
  esac
}

ROUTE_JSON='{"candidates":[]}'
load_route_decision_json() {
  if [ -n "$ROUTE_DECISION_FILE" ]; then
    if [ ! -r "$ROUTE_DECISION_FILE" ]; then
      ROUTE_STATUS="route_decision_file_unreadable"
      ROUTE_ERROR="route decision file is not readable"
      return 0
    fi
    if ! jq -e 'type == "object" and (.candidates | type == "array")' "$ROUTE_DECISION_FILE" >/dev/null 2>&1; then
      ROUTE_STATUS="route_decision_file_malformed"
      ROUTE_ERROR="route decision file is not valid routing context"
      return 0
    fi
    ROUTE_JSON=$(jq -c '.' "$ROUTE_DECISION_FILE")
    return 0
  fi
  if [ -z "$WORKTREE" ]; then
    ROUTE_STATUS="missing_routing_context"
    ROUTE_ERROR="worktree or route decision file is required to prove retry eligibility"
    return 0
  fi
  local args route_json
  args=(explain --operation "$OPERATION" --role "$ROLE" --chain "$CHAIN" --task-id "$TASK_ID" --worktree "$WORKTREE" --source-branch "$SOURCE_BRANCH" --manifest-version "$MANIFEST_VERSION" --break-affinity --no-telemetry)
  [ -n "$BASE_SHA" ] && args+=(--base-sha "$BASE_SHA")
  [ -n "$WORKTREE_SHA" ] && args+=(--worktree-sha "$WORKTREE_SHA")
  [ -n "$RUN_ID" ] && args+=(--run-id "$RUN_ID")
  [ -n "$CHAIN_RUN_ID" ] && args+=(--chain-run-id "$CHAIN_RUN_ID")
  [ -n "$ISSUE_RUN_ID" ] && args+=(--issue-run-id "$ISSUE_RUN_ID")
  if ! route_json=$(STUDIO_IOS_ROUTER_EXCLUDE_WORKERS="$SELECTED_EXECUTOR" "$SCRIPT_DIR/studio-ios-check-router.sh" "${args[@]}" 2>/dev/null); then
    ROUTE_STATUS="router_failed"
    ROUTE_ERROR="router command failed while computing failover eligibility"
    return 0
  fi
  if ! printf '%s\n' "$route_json" | jq -e 'type == "object" and (.candidates | type == "array")' >/dev/null 2>&1; then
    ROUTE_STATUS="router_output_malformed"
    ROUTE_ERROR="router command returned malformed routing context"
    return 0
  fi
  ROUTE_JSON=$(printf '%s\n' "$route_json" | jq -c '.')
}

FAILURE_CLASS=$(classify_failure)
load_route_decision_json

ALT_EXECUTOR=$(printf '%s\n' "$ROUTE_JSON" | jq -r --arg selected "$SELECTED_EXECUTOR" '
  [.candidates[]? | select(.is_local == false and .eligible == true and .id != $selected)]
  | sort_by(.economics.remote_total_s // 999999, .queue.wait_s // 999999)
  | .[0].id // ""
' 2>/dev/null || true)
LOCAL_ELIGIBLE=$(printf '%s\n' "$ROUTE_JSON" | jq -r '
  ([.candidates[]? | select(.id == "local") | .eligible] | .[0]) // false
' 2>/dev/null || printf false)
[ "$LOCAL_ELIGIBLE" = "true" ] || LOCAL_ELIGIBLE=false
ROUTE_CONTEXT_VALID=true
[ "$ROUTE_STATUS" = "ok" ] || ROUTE_CONTEXT_VALID=false

SYNC_MISMATCH=false
case "$FAILURE_SIGNAL" in
  source_sync_*_mismatch|source_branch_changed|source_drift|sync_drift) SYNC_MISMATCH=true ;;
esac

retryable=true
case "$FAILURE_CLASS" in
  remote_command_failed|artifact_malformed|simulator_erase_failure|simulator_runtime_mismatch)
    retryable=false ;;
  sync_drift)
    [ "$SYNC_MISMATCH" = "true" ] && retryable=false ;;
esac

RETRY_EXHAUSTED=false
[ "$RETRY_COUNT" -ge "$MAX_RETRIES" ] && RETRY_EXHAUSTED=true

SELECTED_PATH="halt_operator_review"
TARGET_EXECUTOR=""
POLICY_REASON=""
FINAL_OUTCOME="halted"

if [ "$retryable" != "true" ]; then
  case "$FAILURE_CLASS" in
    remote_command_failed)
      SELECTED_PATH="no_retry_terminal_failure"
      FINAL_OUTCOME="terminal_failure"
      POLICY_REASON="remote command reached xcodebuild/test and failed; retrying would duplicate cost without evidence of infrastructure failure"
      ;;
    sync_drift)
      SELECTED_PATH="halt_source_drift"
      POLICY_REASON="expected branch, sha, or run identity drifted; human review must realign source before retry"
      ;;
    artifact_malformed)
      SELECTED_PATH="halt_operator_review"
      POLICY_REASON="published result is malformed or reporting disagrees with publication; preserve evidence and reconcile before rerun"
      ;;
    simulator_runtime_mismatch)
      SELECTED_PATH="halt_operator_review"
      POLICY_REASON="requested simulator runtime does not match executor capability"
      ;;
    simulator_erase_failure)
      SELECTED_PATH="halt_operator_review"
      POLICY_REASON="simulator erase failed; automatic retry could damage shared simulator state"
      ;;
    *)
      SELECTED_PATH="halt_operator_review"
      POLICY_REASON="failure class is not automatically retryable"
      ;;
  esac
elif [ "$ROUTE_CONTEXT_VALID" != "true" ]; then
  SELECTED_PATH="halt_operator_review"
  POLICY_REASON="routing policy could not prove an eligible retry executor: $ROUTE_ERROR"
elif [ "$RETRY_EXHAUSTED" = "true" ]; then
  SELECTED_PATH="halt_retry_exhausted"
  POLICY_REASON="finite retry budget exhausted"
elif [ "$FAILURE_CLASS" = "sync_drift" ]; then
  SELECTED_PATH="retry_same_worker_after_source_sync"
  TARGET_EXECUTOR="$SELECTED_EXECUTOR"
  FINAL_OUTCOME="retry_planned"
  POLICY_REASON="source-sync proof is missing or stale; refresh proof under the same run identity before retry"
elif [ "$FAILURE_CLASS" = "stale_lock" ]; then
  SELECTED_PATH="reclaim_stale_lock_then_retry"
  TARGET_EXECUTOR="$SELECTED_EXECUTOR"
  FINAL_OUTCOME="retry_planned"
  POLICY_REASON="lock may be reclaimed only after lease expiry plus dead owner or stale heartbeat proof"
elif [ "$FAILURE_CLASS" = "cache_poisoning" ]; then
  if [ "$LOCAL_ELIGIBLE" = "true" ]; then
    SELECTED_PATH="quarantine_cache_then_retry_local_cold"
    TARGET_EXECUTOR="local"
  elif [ -n "$ALT_EXECUTOR" ]; then
    SELECTED_PATH="quarantine_cache_then_retry_another_worker_cold"
    TARGET_EXECUTOR="$ALT_EXECUTOR"
  else
    SELECTED_PATH="halt_operator_review"
  fi
  [ -n "$TARGET_EXECUTOR" ] && FINAL_OUTCOME="retry_planned"
  POLICY_REASON="cache evidence must be quarantined before a cold retry"
elif [ "$FAILURE_CLASS" = "artifact_missing" ]; then
  if [ "$LOCAL_ELIGIBLE" = "true" ]; then
    SELECTED_PATH="retry_local"
    TARGET_EXECUTOR="local"
    FINAL_OUTCOME="retry_planned"
    POLICY_REASON="required artifact was missing; retry locally once to avoid another publication gap"
  elif [ -n "$ALT_EXECUTOR" ]; then
    SELECTED_PATH="retry_another_worker"
    TARGET_EXECUTOR="$ALT_EXECUTOR"
    FINAL_OUTCOME="retry_planned"
    POLICY_REASON="required artifact was missing and another eligible worker is available"
  else
    SELECTED_PATH="halt_operator_review"
    POLICY_REASON="required artifact missing and no eligible retry executor is available"
  fi
elif [ -n "$ALT_EXECUTOR" ]; then
  SELECTED_PATH="retry_another_worker"
  TARGET_EXECUTOR="$ALT_EXECUTOR"
  FINAL_OUTCOME="retry_planned"
  POLICY_REASON="attempted worker failed and another eligible worker can run the same bounded job"
elif [ "$LOCAL_ELIGIBLE" = "true" ]; then
  SELECTED_PATH="retry_local"
  TARGET_EXECUTOR="local"
  FINAL_OUTCOME="retry_planned"
  POLICY_REASON="attempted worker failed and local manager remains eligible under routing policy"
else
  SELECTED_PATH="halt_operator_review"
  POLICY_REASON="no eligible alternate worker or local manager retry path remains"
fi

RETENTION_CLASS="failed-retain"
case "$FAILURE_CLASS" in
  worker_unavailable|worker_timeout|stale_lock|simulator_slot_timeout|simulator_stuck_boot|simulator_stale_slot_reclaimed)
    RETENTION_CLASS="aborted-retain" ;;
  sync_drift|artifact_malformed|simulator_erase_failure|simulator_runtime_mismatch)
    RETENTION_CLASS="blocked-retain" ;;
  cache_poisoning)
    RETENTION_CLASS="cache-quarantined" ;;
esac

PARTIAL_ARTIFACTS='[]'
preserve_partial_artifacts() {
  [ "$PRESERVE_ARTIFACTS" = "1" ] || return 0
  local root="${STUDIO_CHAIN_ARTIFACT_ROOT:-${STUDIO_IOS_ARTIFACT_ROOT:-}}" issue attempt op dest summary telemetry_dir telemetry_file tmp_dir artifacts
  local janitor_log_path janitor_result_path janitor_derived_path
  [ -n "$root" ] || return 0
  mkdir -p "$root" 2>/dev/null || return 0
  issue=$(safe_segment "${ISSUE_RUN_ID:-standalone}")
  attempt=$(safe_segment "$ATTEMPT")
  op=$(safe_segment "$OPERATION")
  artifacts='[]'
  if [ -n "$LOG_PATH" ] && [ -r "$LOG_PATH" ]; then
    dest="$root/logs/$issue/$attempt-$op-failover.log"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 0
    cp -p "$LOG_PATH" "$dest" 2>/dev/null || return 0
    artifacts=$(printf '%s\n' "$artifacts" | jq -c --arg kind log --arg path "$dest" '. + [{kind:$kind,path:$path}]')
  fi
  if [ -n "$ARTIFACT_PATH" ] && [ -e "$ARTIFACT_PATH" ]; then
    artifacts=$(printf '%s\n' "$artifacts" | jq -c --arg kind "${ARTIFACT_KIND:-artifact}" --arg path "$ARTIFACT_PATH" '. + [{kind:$kind,path:$path}]')
  fi
  [ "$(printf '%s\n' "$artifacts" | jq 'length')" -gt 0 ] || return 0
  summary="$root/summaries/$issue/$attempt-$op-failover.summary.txt"
  tmp_dir="$root/tmp/$issue/$attempt-$op-failover"
  mkdir -p "$(dirname "$summary")" "$tmp_dir" 2>/dev/null || return 0
  {
    printf 'operation=%s\n' "$OPERATION"
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'failure_class=%s\n' "$FAILURE_CLASS"
    printf 'selected_retry_path=%s\n' "$SELECTED_PATH"
    printf 'final_outcome=%s\n' "$FINAL_OUTCOME"
    printf 'attempted_executor=%s\n' "$SELECTED_EXECUTOR"
    printf 'target_executor=%s\n' "${TARGET_EXECUTOR:-}"
  } >"$summary" 2>/dev/null || true
  if [ -x "$SCRIPT_DIR/studio-ios-artifact-janitor.sh" ]; then
    telemetry_dir="$root/cleanup-telemetry/$issue"
    telemetry_file="$telemetry_dir/$attempt-$op-failover-cleanup.json"
    mkdir -p "$telemetry_dir" 2>/dev/null || true
    janitor_log_path=$(printf '%s\n' "$artifacts" | jq -r '.[] | select(.kind == "log") | .path' | head -1)
    [ -n "$janitor_log_path" ] || janitor_log_path="$root/logs/$issue/$attempt-$op-failover.log"
    janitor_result_path="${ARTIFACT_PATH:-$root/result-bundles/$issue/$attempt-$op-failover.xcresult}"
    janitor_derived_path="$root/DerivedData/failover/$issue/$attempt-$op"
    STUDIO_IOS_ARTIFACT_RETENTION_CLASS="$RETENTION_CLASS" \
      "$SCRIPT_DIR/studio-ios-artifact-janitor.sh" finalize-operation \
        --root "$root" \
        --summary "$summary" \
        --result-bundle "$janitor_result_path" \
        --log "$janitor_log_path" \
        --tmp "$tmp_dir" \
        --derived-data "$janitor_derived_path" \
        --exit-code "$EXIT_CODE" \
        --operation "$OPERATION-failover" \
        --attempt "$attempt-$op-failover" \
        --issue-run-id "$issue" \
        --json >"$telemetry_file" 2>/dev/null || true
  fi
  printf '%s\n' "$artifacts"
}

PARTIAL_ARTIFACTS=$(preserve_partial_artifacts)
[ -n "$PARTIAL_ARTIFACTS" ] || PARTIAL_ARTIFACTS='[]'
PRESERVE_PARTIAL_JSON=true
[ "$PRESERVE_ARTIFACTS" = "1" ] || PRESERVE_PARTIAL_JSON=false

RETRY_REMAINING=$((MAX_RETRIES - RETRY_COUNT))
[ "$RETRY_REMAINING" -lt 0 ] && RETRY_REMAINING=0

IDEMPOTENCY_ROOT="ios-check:${CHAIN_RUN_ID:-$CHAIN}:${ISSUE_RUN_ID:-$TASK_ID}:$TASK_ID:$OPERATION"
RETRY_IDEM_SEQUENCE="r$RETRY_COUNT"
FAILOVER_IDEM="$IDEMPOTENCY_ROOT:failover:$RETRY_IDEM_SEQUENCE:$FAILURE_CLASS"
RESULT_IDEM="$IDEMPOTENCY_ROOT:result:$RETRY_IDEM_SEQUENCE"
ARTIFACT_IDEM="$IDEMPOTENCY_ROOT:artifact:$RETRY_IDEM_SEQUENCE"

DECISION=$(jq -n \
  --arg ts "$(iso_now)" \
  --arg operation "$OPERATION" \
  --arg role "$ROLE" \
  --arg chain "$CHAIN" \
  --arg task "$TASK_ID" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg run_id "$RUN_ID" \
  --arg chain_run_id "$CHAIN_RUN_ID" \
  --arg issue_run_id "$ISSUE_RUN_ID" \
  --arg attempted "$SELECTED_EXECUTOR" \
  --arg failure_signal "$FAILURE_SIGNAL" \
  --arg failure_class "$FAILURE_CLASS" \
  --argjson exit_code "$EXIT_CODE" \
  --arg retryable "$retryable" \
  --arg retry_exhausted "$RETRY_EXHAUSTED" \
  --arg selected_path "$SELECTED_PATH" \
  --arg target "$TARGET_EXECUTOR" \
  --arg final_outcome "$FINAL_OUTCOME" \
  --arg policy_reason "$POLICY_REASON" \
  --argjson attempt "$ATTEMPT" \
  --argjson retry_count "$RETRY_COUNT" \
  --argjson max_retries "$MAX_RETRIES" \
  --argjson retry_remaining "$RETRY_REMAINING" \
  --arg alternate "$ALT_EXECUTOR" \
  --argjson local_eligible "$LOCAL_ELIGIBLE" \
  --arg route_status "$ROUTE_STATUS" \
  --arg route_error "$ROUTE_ERROR" \
  --arg retention_class "$RETENTION_CLASS" \
  --argjson preserve_partial "$PRESERVE_PARTIAL_JSON" \
  --argjson partial_artifacts "$PARTIAL_ARTIFACTS" \
  --arg failover_idem "$FAILOVER_IDEM" \
  --arg result_idem "$RESULT_IDEM" \
  --arg artifact_idem "$ARTIFACT_IDEM" \
  '{
    schema_version: 1,
    kind: "studio-ios-check-failover-decision",
    created_at: $ts,
    operation: $operation,
    role: $role,
    chain: $chain,
    task_id: $task,
    source_branch: $source_branch,
    run_identity: {
      run_id: (if $run_id == "" then null else $run_id end),
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end)
    },
    attempted_executor: $attempted,
    failure: {
      class: $failure_class,
      signal: (if $failure_signal == "" then null else $failure_signal end),
      exit_code: $exit_code,
      retryable: ($retryable == "true"),
      retry_exhausted: ($retry_exhausted == "true")
    },
    retry: {
      selected_path: $selected_path,
      target_executor: (if $target == "" then null else $target end),
      retry_count: $retry_count,
      max_retries: $max_retries,
      remaining_retries_after_decision: $retry_remaining,
      reason: $policy_reason,
      finite: true,
      preserves_original_run_identity: true
    },
    routing_considered: {
      status: $route_status,
      error: (if $route_error == "" then null else $route_error end),
      alternate_worker: (if $alternate == "" then null else $alternate end),
      local_eligible: $local_eligible
    },
    final_outcome: $final_outcome,
    retention: {
      preserve_partial_artifacts: $preserve_partial,
      retention_class: $retention_class,
      partial_artifacts: $partial_artifacts,
      cleaned_by: "studio-ios-artifact-janitor.sh"
    },
    idempotency_keys: {
      failover: $failover_idem,
      result_reporting: $result_idem,
      artifact_publication: $artifact_idem
    },
    side_effect_guards: {
      issue_commits: "parent-runner-only-after-reviewed-integration",
      issue_closure: "parent-runner-only-after-chain-integration",
      pr_comments: "idempotency-keyed-parent-surface",
      branch_history: "no-shared-branch-rewrite-during-failover"
    },
    lock_recovery: {
      lease_fields: ["lock_kind","owner_host","owner_pid","owner_run_id","owner_chain_run_id","owner_issue_run_id","acquired_at","expires_at","heartbeat_at"],
      lock_order: ["scheduler_queue","source_branch","worker_slot","simulator_slot","artifact_publication","cleanup"],
      safe_reclamation_rule: "lease expired AND owner pid is dead or heartbeat is stale; otherwise wait or halt",
      lock_kinds: ["scheduler","source_branch","worker_slot","simulator_slot","artifact_publication","cleanup"]
    },
    simulator_recovery: {
      slot_timeout: "retry another eligible executor or local manager within retry budget",
      stuck_boot: "release stale lease, retry once, then reroute or halt",
      erase_failure: "halt for operator review",
      runtime_mismatch: "halt for operator review",
      stale_slot_reclamation: "lease expiry plus dead owner or stale heartbeat only"
    }
  }')

record_retry_state() {
  [ "$RETRY_COUNT_EXPLICIT" = "0" ] || return 0
  [ -n "$STATE_FILE" ] || return 0
  local next_count tmp
  next_count="$RETRY_COUNT"
  if [ "$FINAL_OUTCOME" = "retry_planned" ]; then
    next_count=$((RETRY_COUNT + 1))
  fi
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 1
  tmp="$STATE_FILE.tmp.$$"
  jq -n \
    --arg updated_at "$(iso_now)" \
    --arg chain "$CHAIN" \
    --arg task "$TASK_ID" \
    --arg operation "$OPERATION" \
    --arg run_id "$RUN_ID" \
    --arg chain_run_id "$CHAIN_RUN_ID" \
    --arg issue_run_id "$ISSUE_RUN_ID" \
    --arg failure_class "$FAILURE_CLASS" \
    --arg selected_path "$SELECTED_PATH" \
    --arg final_outcome "$FINAL_OUTCOME" \
    --arg attempted "$SELECTED_EXECUTOR" \
    --arg target "$TARGET_EXECUTOR" \
    --argjson retry_count "$RETRY_COUNT" \
    --argjson next_retry_count "$next_count" \
    --argjson max_retries "$MAX_RETRIES" \
    '{
      schema_version: 1,
      kind: "studio-ios-check-failover-state",
      updated_at: $updated_at,
      chain: $chain,
      task_id: $task,
      operation: $operation,
      run_identity: {
        run_id: (if $run_id == "" then null else $run_id end),
        chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
        issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end)
      },
      attempted_executor: $attempted,
      target_executor: (if $target == "" then null else $target end),
      failure_class: $failure_class,
      selected_retry_path: $selected_path,
      final_outcome: $final_outcome,
      retry_count: $retry_count,
      next_retry_count: $next_retry_count,
      max_retries: $max_retries
    }' >"$tmp" && mv "$tmp" "$STATE_FILE"
}

record_retry_state || {
  printf 'studio-ios-check-failover: failed to persist retry state; converting decision to operator halt\n' >&2
  DECISION=$(printf '%s\n' "$DECISION" | jq -c '.retry.selected_path = "halt_operator_review" | .retry.target_executor = null | .retry.reason = "failover retry state could not be persisted" | .final_outcome = "halted"')
}

if [ "$NO_TELEMETRY" != "1" ] && command -v emit_event_keyed >/dev/null 2>&1; then
  EVENT_PAYLOAD=$(printf '%s\n' "$DECISION" | jq -c '{
    operation,
    role,
    chain,
    task_id,
    attempted_executor,
    failure_class: .failure.class,
    failure_signal: .failure.signal,
    selected_retry_path: .retry.selected_path,
    target_executor: .retry.target_executor,
    retry_count: .retry.retry_count,
    max_retries: .retry.max_retries,
    final_outcome,
    retention_class: .retention.retention_class,
    preserve_partial_artifacts: .retention.preserve_partial_artifacts,
    idempotency_key: .idempotency_keys.failover
  }')
  emit_event_keyed studio scheduler ios_check_failover_decision "$TASK_ID" "$EVENT_PAYLOAD" \
    --idem-key "$FAILOVER_IDEM" >/dev/null 2>&1 || true
fi

printf '%s\n' "$DECISION"
