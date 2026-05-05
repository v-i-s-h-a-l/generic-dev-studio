#!/usr/bin/env bash
# studio-chain-runner.sh - execute issue chains with capacity-scaled fresh host sessions.
#
# Usage:
#   scripts/studio-chain-runner.sh <manifest|chain-name> [--only <chain>] [--host <host>] [--dry-run] [--yes] [--parallel-chains <n|auto|1>] [--checkpoint auto|off]
#   scripts/studio-chain-runner.sh --auto <manifest|chain-name> [--only <chain>] [--host <host>] [--dry-run] [--checkpoint auto|off]
#   scripts/studio-chain-runner.sh --explain-next <manifest|chain-name> [--only <chain>]
#   scripts/studio-chain-runner.sh --resume <run_id> [--yes]
#   scripts/studio-chain-runner.sh --list
#
# Manifest shape:
#   schema_version: 1
#   chains:
#     - name: field-telemetry-mvp
#       base: main
#       branch: feature/field-telemetry-mvp
#       host: auto
#       issues: [384, 313, 223]

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-chain-git.sh
. "$SCRIPT_DIR/lib-chain-git.sh"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage

MANIFEST=""
ONLY_CHAIN=""
HOST_OVERRIDE=""
DRY_RUN=0
YES=0
RESUME_ID=""
ALLOW_CLOSED_ISSUES=0
PARALLEL_CHAINS="auto"
CHECKPOINT_OVERRIDE="${STUDIO_CHAIN_CHECKPOINT:-}"
LIST_RUNS=0
AUTO_MODE=0
EXPLAIN_NEXT=0
SUPERVISOR_LOCK=""
SUPERVISOR_LOCK_ACQUIRED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_RUNS=1; shift ;;
    --auto) AUTO_MODE=1; MANIFEST="${2:?--auto requires a manifest or chain name}"; shift 2 ;;
    --auto=*) AUTO_MODE=1; MANIFEST="${1#--auto=}"; shift ;;
    --explain-next) EXPLAIN_NEXT=1; MANIFEST="${2:?--explain-next requires a manifest or chain name}"; shift 2 ;;
    --explain-next=*) EXPLAIN_NEXT=1; MANIFEST="${1#--explain-next=}"; shift ;;
    --only) ONLY_CHAIN="${2:?--only requires a chain name}"; shift 2 ;;
    --only=*) ONLY_CHAIN="${1#--only=}"; shift ;;
    --host) HOST_OVERRIDE="${2:?--host requires a host name}"; shift 2 ;;
    --host=*) HOST_OVERRIDE="${1#--host=}"; shift ;;
    --resume) RESUME_ID="${2:?--resume requires a run id}"; shift 2 ;;
    --resume=*) RESUME_ID="${1#--resume=}"; shift ;;
    --parallel-chains) PARALLEL_CHAINS="${2:?--parallel-chains requires n, auto, or 1}"; shift 2 ;;
    --parallel-chains=*) PARALLEL_CHAINS="${1#--parallel-chains=}"; shift ;;
    --checkpoint) CHECKPOINT_OVERRIDE="${2:?--checkpoint requires auto or off}"; shift 2 ;;
    --checkpoint=*) CHECKPOINT_OVERRIDE="${1#--checkpoint=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|--no-confirm) YES=1; shift ;;
    --allow-closed-issues) ALLOW_CLOSED_ISSUES=1; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'studio-chain-runner: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      if [ -n "$MANIFEST" ]; then
        printf 'studio-chain-runner: manifest already set: %s\n' "$MANIFEST" >&2
        usage
      fi
      MANIFEST="$1"
      shift
      ;;
  esac
done

if [ "$AUTO_MODE" -eq 1 ] && [ "$EXPLAIN_NEXT" -eq 1 ]; then
  printf 'studio-chain-runner: --auto and --explain-next are mutually exclusive\n' >&2
  usage
fi

if { [ "$AUTO_MODE" -eq 1 ] || [ "$EXPLAIN_NEXT" -eq 1 ]; } && [ -n "$RESUME_ID" ]; then
  printf 'studio-chain-runner: supervisor flags cannot be combined with --resume; use --resume <run_id> --yes as the manual override path\n' >&2
  usage
fi

list_persisted_runs() {
  command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
  local parent_home project_root chain_root state_count
  parent_home=$(resolve_parent_home_for_github)
  project_root=$(HOME="$parent_home" resolve_project_root_for generic-dev-studio)
  chain_root="$project_root/chain-runs"

  printf '# Studio Chain Runs\n\n'
  printf -- '- Root: `%s`\n\n' "$chain_root"
  if [ ! -d "$chain_root" ]; then
    printf 'No persisted chain runs found.\n'
    return 0
  fi

  state_count=$(find "$chain_root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$state_count" -eq 0 ]; then
    printf 'No persisted chain runs found.\n'
    return 0
  fi

  printf '| Run ID | Manifest | Status | Started | Updated | Report |\n'
  printf '|---|---|---|---|---|---|\n'
  find "$chain_root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort | while IFS= read -r state; do
    jq -r --arg state "$state" '
      "| \(.run_id // "unknown") | \(.manifest // "unknown") | \(.status // "unknown") | \(.started_at // "unknown") | \(.updated_at // "unknown") | \(.report // "missing") |"
    ' "$state" 2>/dev/null || printf '| unknown | unknown | unreadable | unknown | unknown | `%s` |\n' "$state"
  done
}

if [ "$LIST_RUNS" -eq 1 ]; then
  list_persisted_runs
  exit 0
fi

if [ -z "$MANIFEST" ] && [ -z "$RESUME_ID" ]; then
  usage
fi

case "$PARALLEL_CHAINS" in
  auto|1|*[!0-9]*)
    if [ "$PARALLEL_CHAINS" != "auto" ] && [ "$PARALLEL_CHAINS" != "1" ]; then
      printf 'studio-chain-runner: --parallel-chains must be n, auto, or 1\n' >&2
      exit 2
    fi
    ;;
esac
case "$CHECKPOINT_OVERRIDE" in
  ""|auto|off) ;;
  *) printf 'studio-chain-runner: --checkpoint must be auto or off\n' >&2; exit 2 ;;
esac

command -v yq >/dev/null 2>&1 || { printf 'studio-chain-runner: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { printf 'studio-chain-runner: gh required\n' >&2; exit 2; }

REPO_SLUG="v-i-s-h-a-l/generic-dev-studio"
RUN_ROOT="${TMPDIR:-/tmp}/studio-chain-runner"
mkdir -p "$RUN_ROOT"
FINAL_PR_URL=""
RUN_ID="${RESUME_ID:-$(mint_uuidv7)}"
ATTEMPT_ID="$(mint_uuidv7)"
RUN_STARTED_AT=$(date -u +%s)
RUN_STARTED_TS=$(iso_ts_now)
RUN_STATUS="completed"
RUN_FAILURE_REASON=""
RUN_FINISHED=0
PARENT_HOME_FOR_GITHUB=$(resolve_parent_home_for_github)
PARENT_STUDIO_HOST=$(resolve_current_studio_host unknown)
STUDIO_PROJECT_ROOT=$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_project_root_for generic-dev-studio)
CHAIN_RUNS_ROOT="$STUDIO_PROJECT_ROOT/chain-runs"
ANALYSIS_ROOT=$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_analysis_root)
CHAIN_RUN_ROOT=""
SUMMARY_ROOT=""
HALT_ROOT=""
ESCROW_ROOT=""
PHASE_REVIEW_ROOT=""
EVENTS_JSONL="/dev/null"
RUN_STATE_JSON=""
RUN_REPORT=""
PLAN_JSON=""

configure_run_paths() {
  CHAIN_RUN_ROOT="$CHAIN_RUNS_ROOT/$RUN_ID"
  SUMMARY_ROOT="$CHAIN_RUN_ROOT/worker-summaries"
  HALT_ROOT="$CHAIN_RUN_ROOT/halt-records"
  ESCROW_ROOT="$CHAIN_RUN_ROOT/decision-escrows"
  PHASE_REVIEW_ROOT="$ANALYSIS_ROOT/$RUN_ID-phase-reviews"
  EVENTS_JSONL="$CHAIN_RUN_ROOT/events.jsonl"
  RUN_STATE_JSON="$CHAIN_RUN_ROOT/state.json"
  RUN_REPORT="$CHAIN_RUN_ROOT/report.md"
  PLAN_JSON="$CHAIN_RUN_ROOT/plan.json"
  if [ "$DRY_RUN" -eq 1 ] && [ -z "$RESUME_ID" ]; then
    PLAN_JSON="$RUN_ROOT/$RUN_ID-plan.json"
  fi
  if { [ "$DRY_RUN" -eq 0 ] || [ -n "$RESUME_ID" ]; } && [ "$EXPLAIN_NEXT" -eq 0 ]; then
    mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$PHASE_REVIEW_ROOT"
  else
    EVENTS_JSONL="/dev/null"
  fi
}

configure_run_paths

log() {
  printf 'studio-chain-runner: %s\n' "$*" >&2
}

now_epoch() {
  date -u +%s
}

duration_since() {
  local started="$1" ended="${2:-}"
  [ -z "$ended" ] && ended=$(now_epoch)
  printf '%s\n' "$(( ended - started ))"
}

event_data() {
  local event="$1" run_id="$2" chain_run_id="$3" issue_run_id="$4" status="$5" duration_s="${6:-null}" extra="${7:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn \
    --arg run_id "$run_id" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg manifest "$MANIFEST" \
    --arg status "$status" \
    --argjson duration_s "$duration_s" \
    --argjson extra "$extra" \
    '{
      run_id: $run_id,
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      manifest: $manifest,
      status: $status,
      duration_s: $duration_s
    } + $extra'
}

event_stage() {
  case "$1" in
    chain_run_started|chain_plan_prepared|chain_phase_review_completed) printf 'plan\n' ;;
    chain_auth_normalized|chain_host_preflight_*|chain_artifact_validation_failed) printf 'preflight\n' ;;
    chain_started|chain_issue_started|chain_issue_completed|chain_issue_validated|chain_parent_commit_finalized) printf 'execute\n' ;;
    chain_worker_summary_ingested|chain_telemetry_gap|checkpoint_auto_created|checkpoint_auto_loaded|checkpoint_context_savings_estimated) printf 'ingest\n' ;;
    chain_pr_opened|chain_review_completed) printf 'review\n' ;;
    chain_completed|chain_issue_merged) printf 'merge\n' ;;
    chain_issue_closed) printf 'close\n' ;;
    chain_resume_attempt_*|chain_supervisor_decision) printf 'resume\n' ;;
    chain_halt_recorded|chain_decision_escrow_*|chain_run_completed) printf 'finalize\n' ;;
    *) printf 'execute\n' ;;
  esac
}

emit_chain_event() {
  local event="$1" task="$2" run_id="$3" chain_run_id="$4" issue_run_id="$5" status="$6" duration_s="${7:-null}" extra="${8:-}"
  [ -n "$extra" ] || extra='{}'
  local data stage line
  stage=$(event_stage "$event")
  data=$(event_data "$event" "$run_id" "$chain_run_id" "$issue_run_id" "$status" "$duration_s" "$extra")
  emit_event_keyed studio chain "$event" "$task" "$data" \
    --instance-id "$run_id" \
    --idem-key "studio-chain:$run_id:$event:${chain_run_id:-none}:${issue_run_id:-none}:$task" \
    >/dev/null 2>&1 || true
  line=$(jq -cn \
    --arg created_at "$(iso_ts_now)" \
    --arg run_id "$run_id" \
    --arg event "$event" \
    --arg stage "$stage" \
    --arg status "$status" \
    --arg task "$task" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg attempt_id "$ATTEMPT_ID" \
    --argjson data "$data" \
    '{
      schema_version: 1,
      run_id: $run_id,
      created_at: $created_at,
      event: $event,
      stage: $stage,
      status: $status,
      task: $task,
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      attempt_id: $attempt_id,
      data: $data
    }')
  printf '%s\n' "$line" >> "$EVENTS_JSONL"
}

write_run_state() {
  local status="$1" failure_reason="${2:-}"
  local chains_json="[]" halt_records_json="[]" decision_escrows_json="[]" phase_reviews_json="[]" phase_review_feedback_json="[]" checkpoints_json="[]"
  if [ -f "$RUN_STATE_JSON" ]; then
    chains_json=$(jq -c '.chains // []' "$RUN_STATE_JSON")
    halt_records_json=$(jq -c '.halt_records // []' "$RUN_STATE_JSON")
    decision_escrows_json=$(jq -c '.decision_escrows // []' "$RUN_STATE_JSON")
    phase_reviews_json=$(jq -c '.phase_reviews // []' "$RUN_STATE_JSON")
    phase_review_feedback_json=$(jq -c '.phase_review_feedback // []' "$RUN_STATE_JSON")
    checkpoints_json=$(jq -c '.checkpoints // []' "$RUN_STATE_JSON")
  elif [ -f "$PLAN_JSON" ]; then
    chains_json=$(jq -c '.chains // []' "$PLAN_JSON")
  fi
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest "$MANIFEST" \
    --arg status "$status" \
    --arg started_at "$RUN_STARTED_TS" \
    --arg updated_at "$(iso_ts_now)" \
    --arg report "$RUN_REPORT" \
    --arg plan "$PLAN_JSON" \
    --arg parallel_chains "$PARALLEL_CHAINS" \
    --arg failure_reason "$failure_reason" \
    --argjson chains "$chains_json" \
    --argjson halt_records "$halt_records_json" \
    --argjson decision_escrows "$decision_escrows_json" \
    --argjson phase_reviews "$phase_reviews_json" \
    --argjson phase_review_feedback "$phase_review_feedback_json" \
    --argjson checkpoints "$checkpoints_json" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest: $manifest,
      status: $status,
      started_at: $started_at,
      updated_at: $updated_at,
      report: $report,
      plan: $plan,
      parallel_chains: $parallel_chains,
      chains: $chains,
      halt_records: $halt_records,
      decision_escrows: $decision_escrows,
      phase_reviews: $phase_reviews,
      phase_review_feedback: $phase_review_feedback,
      checkpoints: $checkpoints,
      failure_reason: (if $failure_reason == "" then null else $failure_reason end)
    }' > "$RUN_STATE_JSON"
}

update_state_jq() {
  local filter tmp
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ -f "$RUN_STATE_JSON" ] || return 0
  filter="${*: -1}"
  set -- "${@:1:$(($# - 1))}"
  tmp="$RUN_STATE_JSON.tmp.$$"
  jq "$@" --arg updated_at "$(iso_ts_now)" ".updated_at = \$updated_at | $filter" "$RUN_STATE_JSON" > "$tmp"
  mv "$tmp" "$RUN_STATE_JSON"
}

mark_chain_state() {
  local chain_run_id="$1" status="$2" pr_url="${3:-}"
  update_state_jq \
    --arg chain_run_id "$chain_run_id" \
    --arg status "$status" \
    --arg pr_url "$pr_url" \
    '(.chains[] | select(.chain_run_id == $chain_run_id) | .status) = $status
     | if $pr_url == "" then . else (.chains[] | select(.chain_run_id == $chain_run_id) | .pr_url) = $pr_url end'
}

mark_issue_state() {
  local issue_run_id="$1" status="$2" before="${3:-}" after="${4:-}" summary="${5:-}" reason="${6:-}"
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --arg status "$status" \
    --arg before "$before" \
    --arg after "$after" \
    --arg summary "$summary" \
    --arg reason "$reason" \
    '(.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .status) = $status
     | if $before == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .commit_before) = $before end
     | if $after == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .commit_after) = $after end
     | if $summary == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .summary) = $summary end
     | if $reason == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .failure_reason) = $reason end'
}

sanitize_checkpoint_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//; s/__/_/g'
}

checkpoint_latest_pointer_path_for() {
  local project="$1" role="$2" branch="$3" latest_dir safe_role safe_branch
  latest_dir=$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_checkpoint_latest_dir_for "$project")
  safe_role=$(sanitize_checkpoint_component "$role")
  safe_branch=$(sanitize_checkpoint_component "$branch")
  printf '%s/%s/%s.json\n' "$latest_dir" "$safe_role" "$safe_branch"
}

resolve_checkpoint_mode() {
  local chain_idx="$1" mode
  mode="$CHECKPOINT_OVERRIDE"
  if [ -z "$mode" ]; then
    mode=$(yq -r ".chains[$chain_idx].checkpoint // .checkpoint // \"off\"" "$MANIFEST")
  fi
  case "$mode" in
    auto|off) printf '%s\n' "$mode" ;;
    *)
      printf 'studio-chain-runner: checkpoint must be auto or off: %s\n' "$mode" >&2
      exit 2
      ;;
  esac
}

record_auto_checkpoint() {
  local chain_run_id="$1" issue_run_id="$2" issue="$3" checkpoint_id="$4" checkpoint_dir="$5" branch="$6" head="$7"
  local telemetry default_bytes total_bytes default_tokens total_tokens saved_tokens
  telemetry=$(tail -n 1 "$checkpoint_dir/telemetry.jsonl" 2>/dev/null || printf '{}')
  default_bytes=$(printf '%s\n' "$telemetry" | jq -r '.size.default_load_bytes // 0')
  total_bytes=$(printf '%s\n' "$telemetry" | jq -r '.size.total_bytes // 0')
  default_tokens=$(printf '%s\n' "$telemetry" | jq -r '.size.estimated_default_load_tokens // 0')
  total_tokens=$(printf '%s\n' "$telemetry" | jq -r '.size.estimated_total_tokens // 0')
  saved_tokens=$(( total_tokens - default_tokens ))
  [ "$saved_tokens" -lt 0 ] && saved_tokens=0

  update_state_jq \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg checkpoint_id "$checkpoint_id" \
    --arg checkpoint_dir "$checkpoint_dir" \
    --arg branch "$branch" \
    --arg head "$head" \
    --argjson default_bytes "$default_bytes" \
    --argjson total_bytes "$total_bytes" \
    --argjson default_tokens "$default_tokens" \
    --argjson total_tokens "$total_tokens" \
    '(.checkpoints //= [])
     | .checkpoints += [{
        checkpoint_id:$checkpoint_id,
        checkpoint_dir:$checkpoint_dir,
        role:"manager",
        branch:$branch,
        head:$head,
        chain_run_id:$chain_run_id,
        issue_run_id:$issue_run_id,
        default_load_bytes:$default_bytes,
        total_bytes:$total_bytes,
        estimated_default_load_tokens:$default_tokens,
        estimated_total_tokens:$total_tokens
       }]
     | (.chains[] | select(.chain_run_id == $chain_run_id) | .latest_checkpoint) = $checkpoint_id
     | (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .checkpoint_id) = $checkpoint_id'

  emit_chain_event checkpoint_auto_created "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
    "$(jq -cn --arg checkpoint_id "$checkpoint_id" --arg checkpoint_dir "$checkpoint_dir" --arg role manager --arg branch "$branch" --arg head "$head" --argjson default_bytes "$default_bytes" --argjson total_bytes "$total_bytes" --argjson default_tokens "$default_tokens" --argjson total_tokens "$total_tokens" '{checkpoint_id:$checkpoint_id, checkpoint_dir:$checkpoint_dir, role:$role, branch:$branch, head:$head, default_load_bytes:$default_bytes, total_bytes:$total_bytes, estimated_default_load_tokens:$default_tokens, estimated_total_tokens:$total_tokens}')"
  emit_chain_event checkpoint_context_savings_estimated "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
    "$(jq -cn --arg checkpoint_id "$checkpoint_id" --argjson saved_tokens "$saved_tokens" --argjson default_tokens "$default_tokens" --argjson total_tokens "$total_tokens" '{checkpoint_id:$checkpoint_id, estimated_saved_tokens:$saved_tokens, estimated_default_load_tokens:$default_tokens, estimated_total_tokens:$total_tokens, method:"total_artifact_tokens_minus_default_load_tokens"}')"
}

create_auto_checkpoint_after_issue() {
  local mode="$1" chain_name="$2" branch="$3" chain_worktree="$4" chain_run_id="$5" issue_run_id="$6" issue="$7" result_file="$8"
  [ "$mode" = "auto" ] || return 0
  local checkpoint_id checkpoint_dir head summary_path completed next
  local -a checkpoint_cmd
  checkpoint_id="chain-$(sanitize_checkpoint_component "$RUN_ID")-$(sanitize_checkpoint_component "$chain_run_id")-$(sanitize_checkpoint_component "$issue_run_id")"
  head=$(git -C "$chain_worktree" rev-parse HEAD)
  summary_path=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .summary // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
  completed="Issue #$issue completed and integrated into chain $chain_name at $head."
  next="Resume chain runner from run state and continue the next pending issue or final PR/review step."
  checkpoint_cmd=(
    "$SCRIPT_DIR/studio-checkpoint.sh" create
    --project generic-dev-studio
    --role manager
    --mode chain-auto
    --host "$PARENT_STUDIO_HOST"
    --goal "Resume Studio chain $chain_name from compact automated checkpoint."
    --completed "$completed"
    --next "$next"
    --evidence "$RUN_STATE_JSON"
    --evidence "$result_file"
    --resume-command "scripts/studio-chain-runner.sh --resume $RUN_ID --yes --checkpoint auto"
    --checkpoint-id "$checkpoint_id"
    --branch "$branch"
  )
  [ -z "$summary_path" ] || checkpoint_cmd+=(--evidence "$summary_path")
  checkpoint_dir=$(
    cd "$chain_worktree" && HOME="$PARENT_HOME_FOR_GITHUB" "${checkpoint_cmd[@]}"
  )
  record_auto_checkpoint "$chain_run_id" "$issue_run_id" "$issue" "$checkpoint_id" "$checkpoint_dir" "$branch" "$head"
}

validate_auto_checkpoint_artifacts() {
  local dir="$1" branch="$2" expected_checkpoint_id="$3" current_head="$4"
  local state saved_branch saved_head ref missing=""
  [ -d "$dir" ] || { printf 'checkpoint directory missing: %s\n' "$dir" >&2; return 1; }
  [ -f "$dir/manifest.json" ] || { printf 'checkpoint manifest missing: %s\n' "$dir" >&2; return 1; }
  [ -f "$dir/context.md" ] || { printf 'checkpoint context missing: %s\n' "$dir" >&2; return 1; }
  [ -f "$dir/state.json" ] || { printf 'checkpoint state missing: %s\n' "$dir" >&2; return 1; }
  jq -e --arg checkpoint_id "$expected_checkpoint_id" --arg role manager \
    '.checkpoint_id == $checkpoint_id and .producer.role == $role and .default_load.files == ["manifest.json", "context.md"]' \
    "$dir/manifest.json" >/dev/null || return 1
  state=$(cat "$dir/state.json")
  saved_branch=$(printf '%s\n' "$state" | jq -r '.working_tree.branch // ""')
  saved_head=$(printf '%s\n' "$state" | jq -r '.working_tree.commit // ""')
  [ "$saved_branch" = "$branch" ] || { printf 'checkpoint branch drift: %s != %s\n' "$saved_branch" "$branch" >&2; return 1; }
  [ -z "$saved_head" ] || [ "$saved_head" = "$current_head" ] || { printf 'checkpoint head drift: %s != %s\n' "$saved_head" "$current_head" >&2; return 1; }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      /*) [ -e "$ref" ] || missing="${missing:+$missing, }$ref" ;;
    esac
  done <<EOF
$(jq -r '.evidence[]?.ref // empty' "$dir/evidence.json" 2>/dev/null || true)
EOF
  [ -z "$missing" ] || { printf 'checkpoint evidence refs missing: %s\n' "$missing" >&2; return 1; }
}

load_auto_checkpoint_for_chain() {
  local mode="$1" chain_run_id="$2" branch="$3" chain_worktree="$4"
  [ "$mode" = "auto" ] || return 0
  [ -n "$RESUME_ID" ] || return 0
  local checkpoint_id pointer_dir pointer_id checkpoint_dir current_head load_out drift loaded_files
  checkpoint_id=$(jq -r --arg chain_run_id "$chain_run_id" '(.checkpoints // []) | map(select(.chain_run_id == $chain_run_id)) | last | .checkpoint_id // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
  [ -n "$checkpoint_id" ] || return 0
  pointer_dir=$(checkpoint_latest_pointer_path_for generic-dev-studio manager "$branch")
  pointer_id=$(jq -r '.checkpoint_id // empty' "$pointer_dir" 2>/dev/null || true)
  [ "$pointer_id" = "$checkpoint_id" ] || abort_run "checkpoint latest pointer drift for branch $branch"
  checkpoint_dir=$(jq -r --arg chain_run_id "$chain_run_id" --arg checkpoint_id "$checkpoint_id" '(.checkpoints // []) | map(select(.chain_run_id == $chain_run_id and .checkpoint_id == $checkpoint_id)) | last | .checkpoint_dir // empty' "$RUN_STATE_JSON")
  current_head=$(git -C "$chain_worktree" rev-parse HEAD)
  validate_auto_checkpoint_artifacts "$checkpoint_dir" "$branch" "$checkpoint_id" "$current_head" || abort_run "checkpoint drift verification failed for $checkpoint_id"
  load_out="$CHAIN_RUN_ROOT/checkpoint-load-$chain_run_id.out"
  HOME="$PARENT_HOME_FOR_GITHUB" STUDIO_CHECKPOINT_TRACE_READS="$CHAIN_RUN_ROOT/checkpoint-load-$chain_run_id.reads" \
    "$SCRIPT_DIR/studio-checkpoint.sh" resume --project generic-dev-studio --role manager --branch "$branch" --latest > "$load_out"
  drift=$(sed -n 's/^Drift: //p' "$load_out" | tail -1)
  [ "$drift" != "confirmed" ] || abort_run "checkpoint resume drift confirmed for $checkpoint_id"
  loaded_files=$(tr '\n' ' ' < "$CHAIN_RUN_ROOT/checkpoint-load-$chain_run_id.reads" 2>/dev/null | awk '{printf "[\""; for (i=1;i<=NF;i++){if(i>1)printf "\",\""; printf "%s",$i} printf "\"]"}')
  [ -n "$loaded_files" ] || loaded_files='[]'
  emit_chain_event checkpoint_auto_loaded "" "$RUN_ID" "$chain_run_id" "" completed 0 \
    "$(jq -cn --arg checkpoint_id "$checkpoint_id" --arg checkpoint_dir "$checkpoint_dir" --arg branch "$branch" --arg drift "${drift:-unknown}" --arg load_output "$load_out" --argjson loaded_files "$loaded_files" '{checkpoint_id:$checkpoint_id, checkpoint_dir:$checkpoint_dir, role:"manager", branch:$branch, drift_status:$drift, loaded_files:$loaded_files, load_output:$load_output}')"
}

halt_class_for_reason() {
  case "$1" in
    github_auth_unavailable|github_home_mismatch|github_rate_limited|network_partition|child_timeout|disk_runtime_pressure)
      printf 'retryable\n' ;;
    parent_host_unknown|branch_worktree_conflict|base_branch_advanced|missing_child_summary|child_crash|issue_body_changed|partial_github_operation|test_build_infra_unavailable|telemetry_artifact_malformed|telemetry_artifact_missing|manifest_schema_version_mismatch|implementation_scope_blocked)
      printf 'recoverable\n' ;;
    reviewer_blocked|reviewer_ambiguous)
      printf 'review-needed\n' ;;
    reviewer_host_ineligible|model_tool_permission_prompt|context_output_overflow)
      printf 'human-needed\n' ;;
    required_review_failed|secret_detected|destructive_change_required|permission_expansion_required|unsafe_external_state)
      printf 'fatal\n' ;;
    *)
      printf 'recoverable\n' ;;
  esac
}

halt_reason_for_text() {
  case "$1" in
    *GitHub*auth*|*github*auth*) printf 'github_auth_unavailable\n' ;;
    *reviewer_blocked*|*reviewer\ blocked*) printf 'reviewer_blocked\n' ;;
    *reviewer_ambiguous*|*reviewer\ ambiguous*|*ambiguous\ review*) printf 'reviewer_ambiguous\n' ;;
    *reviewer\ host*|*reviewer\ host\ unavailable*|*reviewer\ host\ ineligible*) printf 'reviewer_host_ineligible\n' ;;
    *review\ failed*|*PR\ review\ failed*|*required\ review*) printf 'required_review_failed\n' ;;
    *branch\ already\ exists*|*worktree*conflict*) printf 'branch_worktree_conflict\n' ;;
    *rebase*|*base\ branch*) printf 'base_branch_advanced\n' ;;
    *worker_summary_missing*|*summary*missing*|*produced\ no\ runner\ result*) printf 'missing_child_summary\n' ;;
    *worker\ exited*|*unexpected_exit*) printf 'child_crash\n' ;;
    *gh\ issue\ close*|*PR\ telemetry\ comment*|*GitHub\ operation*) printf 'partial_github_operation\n' ;;
    *host\ preflight*|*test*infra*|*build*infra*) printf 'test_build_infra_unavailable\n' ;;
    *permission*) printf 'model_tool_permission_prompt\n' ;;
    *context*|*overflow*) printf 'context_output_overflow\n' ;;
    *secret*) printf 'secret_detected\n' ;;
    *destructive*) printf 'destructive_change_required\n' ;;
    *) printf 'implementation_scope_blocked\n' ;;
  esac
}

write_halt_record() {
  local reason_id="$1" summary="$2" chain_run_id="${3:-}" issue_run_id="${4:-}" chain="${5:-}" issue_number="${6:-}" writer="${7:-parent-runner}"
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p "$HALT_ROOT"

  local halt_class hard_stop status next_command file rel_file created_at
  halt_class=$(halt_class_for_reason "$reason_id")
  hard_stop=false
  status=paused
  next_command="$SCRIPT_DIR/studio-chain-runner.sh --resume $RUN_ID --yes"
  if [ "$halt_class" = "fatal" ]; then
    hard_stop=true
    status=terminated
    next_command=""
  fi
  created_at=$(iso_ts_now)
  file="$HALT_ROOT/$created_at-$reason_id.json"
  rel_file="$file"

  jq -n \
    --arg created_at "$created_at" \
    --arg run_id "$RUN_ID" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg chain "$chain" \
    --arg issue_number "$issue_number" \
    --arg status "$status" \
    --arg reason_id "$reason_id" \
    --arg halt_class "$halt_class" \
    --arg writer "$writer" \
    --arg summary "$summary" \
    --arg next_command "$next_command" \
    --argjson true_hard_stop "$hard_stop" \
    --arg run_state "$RUN_STATE_JSON" \
    --arg report "$RUN_REPORT" \
    '{
      schema_version: 1,
      kind: "chain-halt-record",
      created_at: $created_at,
      run_id: $run_id,
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      chain: (if $chain == "" then null else $chain end),
      issue_number: (if $issue_number == "" then null else ($issue_number | tonumber) end),
      status: $status,
      reason_id: $reason_id,
      halt_class: $halt_class,
      writer: $writer,
      summary: $summary,
      resumable_state: {
        run_state: $run_state,
        report: $report,
        run_id: $run_id,
        chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
        issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end)
      },
      next_command: (if $next_command == "" then null else $next_command end),
      affected_artifacts: [$run_state, $report],
      rollback_path: "Inspect the halt record and resume with the next_command after correcting the cause; fatal records require a fresh human-authored plan.",
      true_hard_stop: $true_hard_stop,
      human_action_required: ($halt_class == "human-needed" or $halt_class == "fatal"),
      privacy: {classification: "private-runtime"}
    }' > "$file"

  "$SCRIPT_DIR/validate-contract.sh" chain-halt-record "$file" >/dev/null

  if [ -f "$RUN_STATE_JSON" ]; then
    update_state_jq \
      --arg file "$rel_file" \
      --arg reason_id "$reason_id" \
      --arg halt_class "$halt_class" \
      --arg status "$status" \
      --arg next_command "$next_command" \
      '(.halt_records //= []) |
       .halt_records += [{path:$file, reason_id:$reason_id, halt_class:$halt_class, status:$status, next_command:(if $next_command == "" then null else $next_command end)}]'
  fi
  emit_chain_event chain_halt_recorded "$issue_number" "$RUN_ID" "$chain_run_id" "$issue_run_id" "$status" 0 \
    "$(jq -cn --arg reason_id "$reason_id" --arg halt_class "$halt_class" --arg halt_record "$file" '{reason_id:$reason_id, halt_class:$halt_class, halt_record:$halt_record}')"
  printf '%s\n' "$file"
}

default_review_deadline() {
  local epoch
  epoch=$(( $(now_epoch) + 604800 ))
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

write_decision_escrows_from_summary() {
  local summary_file="$1" review_deadline records count idx file created_at decision_id
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ -f "$summary_file" ] || return 0
  mkdir -p "$ESCROW_ROOT"
  review_deadline=$(default_review_deadline)
  records=$(jq -c --arg review_deadline "$review_deadline" '
    def items($v):
      if $v == null then []
      elif ($v | type) == "array" then [$v[] | select(type == "object")]
      elif ($v | type) == "object" then [$v]
      else []
      end;
    (items(.assumptions_escrowed) + items(.decisions_made))
    as $escrows
    | . as $summary
    | $escrows
    | map(select((.decision // "") != "" and (.default_chosen // "") != ""))
    | map({
        schema_version: 1,
        kind: "chain-decision-escrow",
        created_at: "1970-01-01T00:00:00Z",
        run_id: "00000000-0000-7000-8000-000000000000",
        chain_run_id: (.chain_run_id // $summary.chain_run_id // null),
        issue_run_id: (.issue_run_id // $summary.issue_run_id // null),
        decision_id: (.decision_id // .id // ""),
        decision: .decision,
        default_chosen: .default_chosen,
        rationale: (.rationale // "Worker continued with an escrowed default."),
        risk_class: (.risk_class // "low-risk"),
        status: (.status // "continued"),
        affected_artifacts: (.affected_artifacts // []),
        rollback_path: (.rollback_path // "Review the worker summary and amend the follow-up commit if the default was wrong."),
        review_deadline: (.review_deadline // $review_deadline),
        override_command: (.override_command // null),
        privacy: {classification: "private-runtime"}
      })
  ' "$summary_file")
  count=$(printf '%s' "$records" | jq 'length')
  [ "$count" -gt 0 ] || return 0
  for ((idx = 0; idx < count; idx++)); do
    created_at=$(iso_ts_now)
    decision_id=$(printf '%s' "$records" | jq -r --argjson idx "$idx" '.[$idx].decision_id')
    [ -n "$decision_id" ] || decision_id="escrow-$idx"
    decision_id=$(slugify "$decision_id")
    [ -n "$decision_id" ] || decision_id="escrow-$idx"
    file="$ESCROW_ROOT/$created_at-$decision_id.json"
    printf '%s' "$records" | jq \
      --argjson idx "$idx" \
      --arg created_at "$created_at" \
      --arg run_id "$RUN_ID" \
      --arg decision_id "$decision_id" \
      '.[$idx]
       | .created_at = $created_at
       | .run_id = $run_id
       | .decision_id = $decision_id
       | .chain_run_id = (.chain_run_id // null)
       | .issue_run_id = (.issue_run_id // null)' > "$file"
    "$SCRIPT_DIR/validate-contract.sh" chain-decision-escrow "$file" >/dev/null
    if [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ]; then
      update_state_jq \
        --arg file "$file" \
        --arg decision_id "$decision_id" \
        '(.decision_escrows //= []) | .decision_escrows += [{path:$file, decision_id:$decision_id}]'
    fi
    emit_chain_event chain_decision_escrow_opened "$decision_id" "$RUN_ID" \
      "$(jq -r '.chain_run_id // ""' "$file")" \
      "$(jq -r '.issue_run_id // ""' "$file")" \
      "$(jq -r '.status // "continued"' "$file")" 0 \
      "$(jq -c '{decision_id, decision, escrow_record: input_filename, risk_class, status}' "$file")"
  done
}

phase_review_record() {
  local boundary_id="$1" kind="$2"
  [ -f "$RUN_STATE_JSON" ] || return 1
  jq -e --arg boundary_id "$boundary_id" --arg kind "$kind" \
    '(.phase_reviews // [])[]? | select(.boundary_id == $boundary_id and .kind == $kind and (.verdict // "") == "clean")' \
    "$RUN_STATE_JSON" >/dev/null 2>&1
}

compact_phase_review_feedback_json() {
  local review_file="$1"
  awk '
    function review_section(line, lower) {
      lower=tolower(line)
      sub(/^[[:space:]]*#+[[:space:]]*/, "", lower)
      sub(/^[[:space:]]*/, "", lower)
      if (lower ~ /^accepted plan adjustments?([[:space:]:]|$)/) return "accepted plan adjustments"
      if (lower ~ /^plan adjustments?([[:space:]:]|$)/) return "plan adjustments"
      if (lower ~ /^recommendations?([[:space:]:]|$)/) return "recommendations"
      if (lower ~ /^warnings?([[:space:]:]|$)/) return "warnings"
      if (lower ~ /^(fatal blockers?|blockers?)([[:space:]:]|$)/) return "__stop__"
      return ""
    }
    BEGIN { section="" }
    /^[[:space:]]*PHASE_REVIEW_VERDICT[[:space:]]*[:=]/ { next }
    {
      next_section=review_section($0)
      if (next_section == "__stop__") {
        section=""
        next
      }
      if (next_section != "") {
        section=next_section
        next
      }
    }
    section != "" && /^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+/ {
      line=$0
      sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+/, "", line)
      if (line != "") print section "\t" line
      next
    }
  ' "$review_file" | jq -R -s -c '
    split("\n")[:-1]
    | map(capture("^(?<kind>[^\t]+)\t(?<text>.*)$")?)
    | map(select(. != null))
    | map(select(.text != null and .text != ""))
    | .[:8]
  '
}

phase_review_feedback_for_issue_json() {
  local issue_run_id="$1"
  if [ -f "$RUN_STATE_JSON" ]; then
    jq -c --arg issue_run_id "$issue_run_id" '
      (.phase_review_feedback // [])
      | map(select((.consumed_by_issue_run_id // null) == null or .consumed_by_issue_run_id == $issue_run_id))
      | .[:8]
    ' "$RUN_STATE_JSON"
  else
    printf '[]\n'
  fi
}

mark_phase_review_feedback_consumed() {
  local issue_run_id="$1"
  update_state_jq --arg issue_run_id "$issue_run_id" '
    (.phase_review_feedback //= [])
    | (.phase_review_feedback[]? | select((.consumed_by_issue_run_id // null) == null) | .consumed_by_issue_run_id) = $issue_run_id
  '
}

record_phase_review() {
  local boundary_id="$1" kind="$2" verdict="$3" artifact="$4" review="$5" review_host="$6" chain_run_id="$7" issue_run_id="$8" feedback="${9:-[]}"
  update_state_jq \
    --arg boundary_id "$boundary_id" \
    --arg kind "$kind" \
    --arg verdict "$verdict" \
    --arg artifact "$artifact" \
    --arg review "$review" \
    --arg review_host "$review_host" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --argjson feedback "$feedback" \
    '(.phase_reviews //= [])
     | .phase_reviews = ([.phase_reviews[]? | select(.boundary_id != $boundary_id or .kind != $kind)] + [{
        boundary_id: $boundary_id,
        kind: $kind,
        verdict: $verdict,
        artifact: $artifact,
        review: $review,
        review_host: $review_host,
        chain_run_id: $chain_run_id,
        issue_run_id: $issue_run_id,
        feedback: $feedback
       }])'
}

append_phase_review_feedback() {
  local from_issue="$1" from_issue_run_id="$2" review="$3" feedback="$4"
  [ "$(printf '%s' "$feedback" | jq 'length')" -gt 0 ] || return 0
  update_state_jq \
    --arg from_issue "$from_issue" \
    --arg from_issue_run_id "$from_issue_run_id" \
    --arg review "$review" \
    --argjson feedback "$feedback" \
    '(.phase_review_feedback //= [])
     | .phase_review_feedback += ($feedback | map(. + {
        source_issue: ($from_issue | tonumber),
        source_issue_run_id: $from_issue_run_id,
        source_review: $review
       }))
     | .phase_review_feedback = .phase_review_feedback[-12:]'
}

run_phase_review_gate() {
  local kind="$1" boundary_id="$2" artifact="$3" chain_run_id="$4" issue_run_id="$5" chain_name="$6" issue="$7"
  local review_host review_file review_meta review_rc verdict feedback review_started_at review_duration
  review_host="${STUDIO_REVIEW_HOST:-claude-reviewer}"
  review_file="$PHASE_REVIEW_ROOT/$boundary_id-$kind-review.md"

  if phase_review_record "$boundary_id" "$kind"; then
    log "resume skip completed $kind phase review for $boundary_id"
    return 0
  fi

  review_started_at=$(now_epoch)
  set +e
  review_meta=$(HOME="$PARENT_HOME_FOR_GITHUB" STUDIO_PHASE_REVIEW_ELIGIBILITY_CACHE_DIR="$CHAIN_RUN_ROOT/reviewer-eligibility" \
    "$SCRIPT_DIR/phase-review.sh" --review-host "$review_host" --kind "$kind" --input "$artifact" --output "$review_file" 2>&1)
  review_rc=$?
  set -e
  printf '%s\n' "$review_meta"
  review_duration=$(duration_since "$review_started_at")

  if [ "$review_rc" -ne 0 ]; then
    emit_chain_event chain_phase_review_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$review_duration" \
      "$(jq -cn --arg kind "$kind" --arg boundary_id "$boundary_id" --arg review_host "$review_host" --arg exit_code "$review_rc" '{kind:$kind, boundary_id:$boundary_id, review_host:$review_host, exit_code:($exit_code|tonumber), reason_id:"reviewer_host_ineligible"}')"
    write_halt_record "reviewer_host_ineligible" "$kind phase review wrapper failed for $boundary_id" "$chain_run_id" "$issue_run_id" "$chain_name" "$issue" "parent-runner" >/dev/null || true
    return 70
  fi

  verdict=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_VERDICT=//p' | tail -1)
  [ -n "$verdict" ] || verdict="ambiguous"
  feedback="[]"
  if [ "$kind" = "outcome" ] && [ -f "$review_file" ]; then
    feedback=$(compact_phase_review_feedback_json "$review_file")
  fi
  record_phase_review "$boundary_id" "$kind" "$verdict" "$artifact" "$review_file" "$review_host" "$chain_run_id" "$issue_run_id" "$feedback"
  emit_chain_event chain_phase_review_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" "$verdict" "$review_duration" \
    "$(jq -cn --arg kind "$kind" --arg boundary_id "$boundary_id" --arg verdict "$verdict" --arg review_host "$review_host" --arg artifact "$artifact" --arg review "$review_file" --argjson feedback "$feedback" '{kind:$kind, boundary_id:$boundary_id, verdict:$verdict, review_host:$review_host, artifact:$artifact, review:$review, feedback:$feedback}')"

  case "$verdict" in
    clean)
      if [ "$kind" = "outcome" ]; then
        append_phase_review_feedback "$issue" "$issue_run_id" "$review_file" "$feedback"
      fi
      return 0
      ;;
    blocked)
      write_halt_record "reviewer_blocked" "$kind phase review blocked $boundary_id" "$chain_run_id" "$issue_run_id" "$chain_name" "$issue" "parent-runner" >/dev/null || true
      return 71
      ;;
    ambiguous|*)
      write_halt_record "reviewer_ambiguous" "$kind phase review verdict was ambiguous for $boundary_id" "$chain_run_id" "$issue_run_id" "$chain_name" "$issue" "parent-runner" >/dev/null || true
      return 72
      ;;
  esac
}

generated_file_count_between() {
  local worktree="$1" before="$2" after="$3"
  git -C "$worktree" diff --name-only "$before" "$after" 2>/dev/null \
    | awk '
      /(^|\/)(docs-surface[.]json|.*manifest.*[.](json|ya?ml))$/ { count += 1; next }
      /(^|\/)chanakya\/snapshots\// { count += 1; next }
      /(^|\/)_shared\/schemas\/capability-manifest[.]json$/ { count += 1; next }
      END { print count + 0 }
    '
}

resolve_phase_review_mode() {
  local chain_idx="$1" mode
  mode="${STUDIO_CHAIN_PHASE_REVIEW:-}"
  if [ -z "$mode" ]; then
    mode=$(yq -r ".chains[$chain_idx].phase_review // .phase_review // \"auto\"" "$MANIFEST")
  fi
  case "$mode" in
    required|auto|off) printf '%s\n' "$mode" ;;
    *)
      printf 'studio-chain-runner: phase_review must be required, auto, or off: %s\n' "$mode" >&2
      exit 2
      ;;
  esac
}

phase_review_required_for_issue() {
  local mode="$1" issue_count="$2"
  case "$mode" in
    required) return 0 ;;
    auto) [ "$issue_count" -gt 1 ] ;;
    off) return 1 ;;
    *) return 1 ;;
  esac
}

write_chain_task_start_envelope() {
  local chain_name="$1" chain_branch="$2" issue_branch="$3" issue_json="$4" host="$5" git_metadata_strategy="$6" worktree="$7" chain_run_id="$8" issue_run_id="$9" summary_path="${10}" start_path="${11}" phase_review_context="${12:-[]}"
  mkdir -p "$(dirname "$start_path")"
  jq -n \
    --argjson source_issue "$issue_json" \
    --arg created_at "$(iso_ts_now)" \
    --arg run_id "$RUN_ID" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg chain "$chain_name" \
    --arg branch "$chain_branch" \
    --arg issue_branch "$issue_branch" \
    --arg worktree "$worktree" \
    --arg host "$host" \
    --arg git_metadata_strategy "$git_metadata_strategy" \
    --arg summary_path "$summary_path" \
    --argjson phase_review_context "$phase_review_context" \
    '{
      schema_version: 1,
      kind: "start",
      created_at: $created_at,
      run_id: $run_id,
      chain_run_id: $chain_run_id,
      issue_run_id: $issue_run_id,
      source_issue: {
        number: ($source_issue.number | tonumber),
        title: ($source_issue.title // ""),
        body: ($source_issue.body // ""),
        url: ($source_issue.url // ""),
        state: ($source_issue.state // "")
      },
      ownership: {
        chain: $chain,
        branch: $branch,
        issue_branch: $issue_branch,
        worktree: $worktree,
        host: $host,
        git_metadata_strategy: $git_metadata_strategy
      },
      expected_summary_artifact: $summary_path,
      required_checks: [
        "Work only in the issue worktree.",
        "Keep changes scoped to the source issue.",
        "Commit the result on the current issue branch.",
        "Write the expected summary artifact as valid JSON before exit.",
        "Do not commit private .studio artifacts."
      ],
      allowed_assumptions: [
        "The source issue body is the authoritative scoped brief.",
        "The chain runner owns PR creation, main merge, issue closure, and worktree cleanup.",
        "Runtime handoff artifacts under .studio are private and disposable.",
        "Prior phase-review feedback in this envelope is private context from a clean outcome review, not human acceptance."
      ],
      phase_review_context: $phase_review_context,
      stop_conditions: [
        "Required scope cannot be implemented safely from the source issue.",
        "Verification needed for an unqualified completion claim cannot be run or captured.",
        "The worker would need to change unrelated issues, open a PR, merge to main, close the issue, or commit private .studio artifacts."
      ],
      privacy: {
        classification: "private-runtime",
        rules: [
          "Do not store secrets or raw sensitive prompts.",
          "Do not commit .studio artifacts.",
          "Keep public summaries abstract and free of project-private details."
        ]
      }
    }' > "$start_path"
}

diff_stats_json() {
  local worktree="$1" before="$2" after="$3"
  local stats
  stats=$(git -C "$worktree" diff --numstat "$before" "$after" 2>/dev/null \
    | awk '
      BEGIN { files=0; add=0; del=0 }
      { files += 1; if ($1 ~ /^[0-9]+$/) add += $1; if ($2 ~ /^[0-9]+$/) del += $2 }
      END { printf "{\"files_changed\":%d,\"additions\":%d,\"deletions\":%d}", files, add, del }
    ')
  jq -cn --argjson stats "$stats" --argjson generated "$(generated_file_count_between "$worktree" "$before" "$after")" \
    '$stats + {generated_file_count: $generated}'
}

changed_artifacts_json() {
  local worktree="$1" before="$2" after="$3"
  git -C "$worktree" diff --name-only "$before" "$after" 2>/dev/null | jq -R -s -c 'split("\n")[:-1]'
}

refresh_summary_commit_metrics() {
  local summary_file="$1" worktree="$2" before="$3" after="$4" parent_finalized="${5:-false}"
  local stats changed_artifacts tmp
  [ -f "$summary_file" ] || return 0
  stats=$(diff_stats_json "$worktree" "$before" "$after")
  changed_artifacts=$(changed_artifacts_json "$worktree" "$before" "$after")
  tmp="$summary_file.tmp.$$"
  jq \
    --arg after "$after" \
    --argjson stats "$stats" \
    --argjson changed_artifacts "$changed_artifacts" \
    --argjson parent_finalized "$parent_finalized" \
    '.commit_after = $after
     | .commit_or_pr_references.commit_after = $after
     | .files_changed = $stats.files_changed
     | .additions = $stats.additions
     | .deletions = $stats.deletions
     | .generated_file_count = $stats.generated_file_count
     | .changed_artifacts = $changed_artifacts
     | if $parent_finalized then
         .parent_finalized_commit = true
         | .parent_finalized_by = "parent-runner"
       else . end' \
    "$summary_file" > "$tmp"
  mv "$tmp" "$summary_file"
}

emit_summary_telemetry_gaps() {
  local summary_file="$1" chain_run_id="$2" issue_run_id="$3" issue="$4" gap
  [ -f "$summary_file" ] || return 0
  while IFS= read -r gap; do
    [ -n "$gap" ] || continue
    emit_chain_event chain_telemetry_gap "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" missing 0 \
      "$(jq -cn --arg gap_kind "$gap" --arg stage "ingest" --arg reason "missing_or_unavailable" '{gap_kind:$gap_kind, stage:$stage, reason:$reason}')"
  done <<EOF
$(jq -r '.telemetry_gaps[]? | if type == "object" then (.gap_kind // .kind // empty) else . end' "$summary_file" 2>/dev/null)
EOF
}

ingest_worker_summary() {
  local chain_name="$1" issue="$2" host="$3" worktree="$4" before="$5" after="$6" exit_code="$7" started_at="$8" chain_run_id="$9" issue_run_id="${10}"
  local summary_path="$worktree/.studio/chain-worker-summary.json"
  local dest="$SUMMARY_ROOT/${chain_name}-issue-${issue}-${issue_run_id}.json"
  local ended_at created_at duration_s stats changed_artifacts
  ended_at=$(now_epoch)
  created_at=$(iso_ts_now)
  duration_s=$(duration_since "$started_at" "$ended_at")
  stats=$(diff_stats_json "$worktree" "$before" "$after")
  changed_artifacts=$(changed_artifacts_json "$worktree" "$before" "$after")

  if [ -f "$summary_path" ] && jq -e . "$summary_path" >/dev/null 2>&1; then
    jq -c \
      --arg run_id "$RUN_ID" \
      --arg chain_run_id "$chain_run_id" \
      --arg issue_run_id "$issue_run_id" \
      --arg created_at "$created_at" \
      --arg host "$host" \
      --argjson exit_code "$exit_code" \
      --arg before "$before" \
      --arg after "$after" \
      --argjson duration_s "$duration_s" \
      --argjson stats "$stats" \
      --argjson changed_artifacts "$changed_artifacts" \
      'def has_model: ((.model // .model_name // .model_version // null) != null);
       def has_checks: (((.tests // []) | length) + ((.lints // []) | length) + ((.builds // []) | length)) > 0;
       . + {
        schema_version: (.schema_version // 1),
        kind: (.kind // "completion"),
        created_at: (.created_at // $created_at),
        status: (.status // (if $exit_code == 0 then "completed" else "failed" end)),
        run_id: (.run_id // $run_id),
        chain_run_id: (.chain_run_id // $chain_run_id),
        issue_run_id: (.issue_run_id // $issue_run_id),
        host: (.host // $host),
        exit_code: (.exit_code // $exit_code),
        duration_s: (.duration_s // $duration_s),
        commit_before: (.commit_before // $before),
        commit_after: (.commit_after // $after),
        files_changed: (.files_changed // $stats.files_changed),
        additions: (.additions // $stats.additions),
        deletions: (.deletions // $stats.deletions),
        generated_file_count: (.generated_file_count // $stats.generated_file_count),
        changed_artifacts: (.changed_artifacts // $changed_artifacts),
        commit_or_pr_references: (.commit_or_pr_references // {commit_before:$before, commit_after:$after, pr_url:null, pr_number:null}),
        tests: (.tests // []),
        lints: (.lints // []),
        builds: (.builds // []),
        tokens: (.tokens // null),
        functionality_delivered: (.functionality_delivered // null),
        carryover: (.carryover // null),
        lessons: (.lessons // null),
        telemetry_gaps: (((.telemetry_gaps // [])
          + (if (.tokens // null) == null then ["tokens"] else [] end)
          + (if has_model then [] else ["model"] end)
          + (if has_checks then [] else ["tests_lints_builds"] end)) | unique)
      }' "$summary_path" > "$dest"
    emit_chain_event chain_worker_summary_ingested "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed "$duration_s" \
      "$(jq -cn --arg summary "$dest" '{summary:$summary, validation:"valid"}')"
  else
    local summary_gap
    if [ -f "$summary_path" ]; then
      summary_gap="telemetry_artifact_malformed"
    else
      summary_gap="worker_summary_missing"
    fi
    jq -n \
      --arg run_id "$RUN_ID" \
      --arg chain_run_id "$chain_run_id" \
      --arg issue_run_id "$issue_run_id" \
      --arg created_at "$created_at" \
      --arg chain "$chain_name" \
      --argjson issue "$issue" \
      --arg host "$host" \
      --argjson exit_code "$exit_code" \
      --arg before "$before" \
      --arg after "$after" \
      --argjson duration_s "$duration_s" \
      --argjson stats "$stats" \
      --argjson changed_artifacts "$changed_artifacts" \
      --arg summary_gap "$summary_gap" \
      '{
        schema_version: 1,
        kind: "completion",
        created_at: $created_at,
        status: (if $exit_code == 0 then "completed" else "failed" end),
        run_id: $run_id,
        chain_run_id: $chain_run_id,
        issue_run_id: $issue_run_id,
        chain: $chain,
        issue_number: $issue,
        host: $host,
        exit_code: $exit_code,
        duration_s: $duration_s,
        commit_before: $before,
        commit_after: $after,
        files_changed: $stats.files_changed,
        additions: $stats.additions,
        deletions: $stats.deletions,
        generated_file_count: $stats.generated_file_count,
        changed_artifacts: $changed_artifacts,
        commit_or_pr_references: {commit_before:$before, commit_after:$after, pr_url:null, pr_number:null},
        tests: [],
        lints: [],
        builds: [],
        tokens: null,
        model: null,
        model_recommendation: null,
        functionality_delivered: null,
        carryover: null,
        lessons: null,
        telemetry_gaps: [$summary_gap, "model", "tokens", "tests_lints_builds"]
      }' > "$dest"
    emit_chain_event chain_artifact_validation_failed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$duration_s" \
      "$(jq -cn --arg artifact "chain-worker-summary" --arg reason "$summary_gap" --arg summary "$dest" '{artifact:$artifact, reason_id:$reason, summary:$summary}')"
    emit_chain_event chain_worker_summary_ingested "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$duration_s" \
      "$(jq -cn --arg summary "$dest" --arg validation "$summary_gap" '{summary:$summary, validation:$validation}')"
  fi
  emit_summary_telemetry_gaps "$dest" "$chain_run_id" "$issue_run_id" "$issue"

  printf '%s\n' "$dest"
}

worker_summary_tracked() {
  local worktree="$1"
  git -C "$worktree" ls-tree -r --name-only HEAD -- .studio/chain-worker-summary.json 2>/dev/null | grep -q .
}

generate_run_report() {
  local status="$1" failure_reason="${2:-}" ended_ts ended_epoch duration_s summary_count halt_count halt_dir digest_script
  ended_ts=$(iso_ts_now)
  ended_epoch=$(now_epoch)
  duration_s=$(duration_since "$RUN_STARTED_AT" "$ended_epoch")
  summary_count=$(find "$SUMMARY_ROOT" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  halt_dir="${HALT_ROOT:-}"
  digest_script=""
  if [ -n "${SCRIPT_DIR:-}" ]; then
    digest_script="$SCRIPT_DIR/studio-chain-telemetry-digest.sh"
  elif [ -n "${ROOT:-}" ]; then
    digest_script="$ROOT/scripts/studio-chain-telemetry-digest.sh"
  fi

  {
    printf '# Studio Chain Run Report\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Manifest: `%s`\n' "$MANIFEST"
    printf -- '- Status: `%s`\n' "$status"
    printf -- '- Started: `%s`\n' "$RUN_STARTED_TS"
    printf -- '- Ended: `%s`\n' "$ended_ts"
    printf -- '- Duration: `%ss`\n' "$duration_s"
    [ -n "$failure_reason" ] && printf -- '- Failure reason: `%s`\n' "$failure_reason"
    printf '\n## Functionality Delivered\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def lines($v):
          if $v == null then []
          elif ($v | type) == "array" then [$v[] | tostring]
          elif ($v | type) == "object" then [$v | tojson]
          else [$v | tostring]
          end;
        [ .[] | {issue:(.issue_number // "unknown"), lines: lines(.functionality_delivered)} | select(.lines | length > 0) ] as $items |
        if ($items | length) == 0 then "No functionality narrative was supplied by worker summaries."
        else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No worker summaries were ingested.\n'
    fi
    printf '\n## Telemetry Roll-up\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def token_total:
          (.tokens // null) as $t |
          if $t == null then null
          elif ($t | type) == "number" then $t
          elif ($t | type) == "object" then ($t.total // $t.total_tokens // $t.usage.total_tokens // null)
          else null
          end;
        def cache_rate:
          (.tokens // null) as $t |
          if ($t | type) == "object" then ($t.cache_hit_rate // $t.cache_hit_ratio // null) else null end;
        . as $rows |
        ($rows | length) as $issue_count |
        ([ $rows[].duration_s? // empty ] | add // 0) as $worker_seconds |
        ([ $rows[] | token_total | select(. != null) ] | add // null) as $tokens |
        ([ $rows[] | cache_rate | select(. != null) ]) as $cache_rates |
        (if ($cache_rates | length) == 0 then null else (($cache_rates | add) / ($cache_rates | length)) end) as $cache_hit_rate |
        ($rows | max_by(.duration_s // -1)) as $slowest |
        "- Worker summaries: \($issue_count)",
        "- Total worker wall-clock: \($worker_seconds)s",
        "- Slowest issue: #\($slowest.issue_number // "unknown") at \($slowest.duration_s // "unknown")s",
        "- Token total: \(if $tokens == null then "missing" else ($tokens | tostring) end)",
        "- Cache hit rate: \(if $cache_hit_rate == null then "missing" else ($cache_hit_rate | tostring) end)",
        "",
        "| Issue | Host | Model | Duration | Tokens |",
        "|---:|---|---|---:|---|",
        ($rows[] | "| #\(.issue_number // "unknown") | \(.host // "unknown") | \(.model // .model_name // "missing") | \(.duration_s // "unknown")s | \(if (token_total) == null then "missing" else (token_total | tostring) end) |")
      ' "$SUMMARY_ROOT"/*.json
    else
      printf -- '- Worker summaries: 0\n'
      printf -- '- Event counters: unavailable without worker summaries.\n'
    fi
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      printf '\nEvent counters:\n'
      jq -r -s '
        [.[].event] | group_by(.) | map({event: .[0], count: length}) | sort_by(.event) |
        if length == 0 then "- none" else .[] | "- \(.event): \(.count)" end
      ' "$EVENTS_JSONL" 2>/dev/null || printf -- '- unreadable event log\n'
    fi
    printf '\n## Weekly Chain Digest\n\n'
    if [ -n "$digest_script" ] && [ -x "$digest_script" ]; then
      "$digest_script" --chain-run-root "${CHAIN_RUN_ROOT:-$(dirname "$RUN_REPORT")}" --format markdown 2>/dev/null || printf 'Weekly chain digest unavailable: telemetry digest failed.\n'
    else
      printf 'Weekly chain digest unavailable: `scripts/studio-chain-telemetry-digest.sh` not found.\n'
    fi
    printf '\n## Stage Reconstruction\n\n'
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      jq -r -s '
        def stage_of($e):
          $e.stage // (
            if (($e.event // "") | test("review")) then "review"
            elif (($e.event // "") | test("resume")) then "resume"
            elif (($e.event // "") | test("pr_opened")) then "review"
            elif (($e.event // "") | test("completed$")) then "execute"
            else "execute" end
          );
        def dur($e): (($e.data.duration_s // $e.duration_s // 0) | tonumber? // 0);
        [ "plan","preflight","execute","ingest","review","merge","close","resume","finalize" ] as $order |
        [ .[] | {stage: stage_of(.), duration_s: dur(.), event:(.event // ""), status:(.status // .data.status // "")} ] as $rows |
        ($order[] as $stage |
          ($rows | map(select(.stage == $stage)) | length) as $count |
          ($rows | map(select(.stage == $stage) | .duration_s) | add // 0) as $duration |
          select($count > 0) |
          "- \($stage): \($duration)s across \($count) events"
        )
      ' "$EVENTS_JSONL" 2>/dev/null || printf 'Stage durations unavailable: event log unreadable.\n'
    else
      printf 'Stage durations unavailable: no event log was written.\n'
    fi
    printf '\n## Review Summary\n\n'
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      jq -r -s '
        [ .[] | select((.event // "") == "chain_review_completed") ] as $reviews |
        ($reviews | map(select((.status // .data.status // "") == "completed")) | length) as $pass |
        ($reviews | map(select((.status // .data.status // "") != "completed")) | length) as $fail |
        "- Review passes: \($pass)",
        "- Review failures: \($fail)",
        (if ($reviews | length) == 0 then "- Reviewer gate events: none"
         else ($reviews[] | "- PR \(.task // .data.pr_number // "unknown"): \(.status // .data.status // "unknown") in \(.data.duration_s // "unknown")s")
         end)
      ' "$EVENTS_JSONL" 2>/dev/null || printf 'Review summary unavailable: event log unreadable.\n'
    else
      printf 'Review summary unavailable: no event log was written.\n'
    fi
    if [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ]; then
      jq -r '
        "\nPhase reviews:",
        ((.phase_reviews // []) as $reviews |
          if ($reviews | length) == 0 then "- Phase-review gates: none"
          else $reviews[] | "- \(.kind) \(.boundary_id): \(.verdict) (`\(.review)`)"
          end),
        ((.phase_review_feedback // []) as $feedback |
          if ($feedback | length) == 0 then "- Forwarded review feedback: none"
          else "- Forwarded review feedback items: \($feedback | length)"
          end)
      ' "$RUN_STATE_JSON" 2>/dev/null || true
    fi
    printf '\n## Resume Attempts\n\n'
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      jq -r -s '
        [ .[] | select((.event // "") | test("^chain_resume_attempt_")) ] as $attempts |
        if ($attempts | length) == 0 then "No resume attempts were recorded."
        else $attempts[] | "- \(.attempt_id // .data.attempt_id // "unknown"): \(.event) \(.status // .data.status // "unknown")"
        end
      ' "$EVENTS_JSONL" 2>/dev/null || printf 'Resume attempt summary unavailable: event log unreadable.\n'
    else
      printf 'Resume attempt summary unavailable: no event log was written.\n'
    fi
    printf '\n## Validation Failures\n\n'
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      jq -r -s '
        [ .[] | select((.event // "") == "chain_artifact_validation_failed") ] as $failures |
        if ($failures | length) == 0 then "No artifact validation failures were recorded."
        else $failures[] | "- \(.data.artifact // "artifact"): \(.data.reason_id // "unknown")"
        end
      ' "$EVENTS_JSONL" 2>/dev/null || printf 'Validation failure summary unavailable: event log unreadable.\n'
    else
      printf 'Validation failure summary unavailable: no event log was written.\n'
    fi
    printf '\n## Quality Signals\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def outcome_bad($arr): [($arr // [])[]? | select((.outcome // .status // "") | test("fail|error"; "i"))] | length;
        ["| Issue | Exit | Review Passes | Findings Tier | Tests | Lints | Builds | Gaps |",
         "|---:|---:|---:|---|---:|---:|---:|---|"],
        (.[] |
          "| #\(.issue_number // "unknown") | \(.exit_code // "unknown") | \(.review_pass_count // .review_passes // "missing") | \(.review_findings_tier // .findings_tier // "missing") | \((.tests // []) | length) total / \(outcome_bad(.tests)) bad | \((.lints // []) | length) total / \(outcome_bad(.lints)) bad | \((.builds // []) | length) total / \(outcome_bad(.builds)) bad | \((.telemetry_gaps // []) | join(", ")) |"
        )
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No quality signals were ingested.\n'
    fi
    printf '\n## Chains And Issues\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        ["| Chain | Issue | Host | Exit | Duration | Files | LOC | Generated | Model | Token Data | Gaps |",
         "|---|---:|---|---:|---:|---:|---:|---:|---|---|---|"],
        (.[] | "| \(.chain // "unknown") | #\(.issue_number // "unknown") | \(.host // "unknown") | \(.exit_code // "unknown") | \(.duration_s // "unknown")s | \(.files_changed // 0) | +\(.additions // 0)/-\(.deletions // 0) | \(.generated_file_count // 0) | \(.model // .model_name // "missing") | \(if (.tokens // null) == null then "missing" else "present" end) | \((.telemetry_gaps // []) | join(", ")) |")
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No worker summaries were ingested.\n'
    fi
    printf '\n## Carryover\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def lines($v):
          if $v == null then []
          elif ($v | type) == "array" then [$v[] | tostring]
          elif ($v | type) == "object" then [$v | tojson]
          else [$v | tostring]
          end;
        [ .[] | {issue:(.issue_number // "unknown"), lines: lines(.carryover)} | select(.lines | length > 0) ] as $items |
        if ($items | length) == 0 then "No carryover was supplied by worker summaries."
        else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No carryover was ingested.\n'
    fi
    printf '\n## Lessons\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def lines($v):
          if $v == null then []
          elif ($v | type) == "array" then [$v[] | tostring]
          elif ($v | type) == "object" then [$v | tojson]
          else [$v | tostring]
          end;
        [ .[] | {issue:(.issue_number // "unknown"), lines: lines(.lessons)} | select(.lines | length > 0) ] as $items |
        if ($items | length) == 0 then "A4a-enriched lessons were not available for this run."
        else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'A4a-enriched lessons were not available for this run.\n'
    fi
    printf '\n## PRs And Review\n\n'
    if [ -n "$FINAL_PR_URL" ]; then
      printf -- '- PR URL: %s\n' "$FINAL_PR_URL"
    else
      printf -- '- PR URL: not opened\n'
    fi
    printf '\n## Halt Records\n\n'
    halt_count=0
    [ -n "$halt_dir" ] && halt_count=$(find "$halt_dir" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$halt_count" -gt 0 ]; then
      jq -r -s '
        ["| Reason | Class | Status | Next Command | Summary |",
         "|---|---|---|---|---|"],
        (.[] | "| \(.reason_id) | \(.halt_class) | \(.status) | \(.next_command // "hard stop") | \(.summary | gsub("\\|"; "\\|")) |")
      ' "$halt_dir"/*.json
    else
      printf 'No halt records were written.\n'
    fi
    printf '\n## Decision Escrow\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def escrow_lines($v):
          if $v == null then []
          elif ($v | type) == "array" then [$v[] | if type == "object" then (.decision // .summary // .id // tojson) else tostring end]
          elif ($v | type) == "object" then [($v.decision // $v.summary // ($v | tojson))]
          else [$v | tostring]
          end;
        [ .[] | {issue:(.issue_number // "unknown"), lines:(escrow_lines(.assumptions_escrowed) + escrow_lines(.decisions_made))} | select(.lines | length > 0) ] as $items |
        if ($items | length) == 0 then "No escrowed decisions were supplied by worker summaries."
        else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No decision escrow was ingested.\n'
    fi
    printf '\n## Telemetry Gaps\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        [.[].telemetry_gaps[]?] | group_by(.) | map({gap: .[0], count: length}) | sort_by(-.count) |
        if length == 0 then "No worker-declared gaps."
        else .[] | "- \(.gap): \(.count)"
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf -- '- worker_summary_missing: all issues\n'
    fi
    printf '\n## Improvement Candidates\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def gap_count($g): [.[].telemetry_gaps[]? | select(. == $g)] | length;
        [
          (if gap_count("worker_summary_missing") > 0 then "- Require worker hosts to write `.studio/chain-worker-summary.json` before exit." else empty end),
          (if gap_count("tokens") > 0 or gap_count("token_usage") > 0 then "- Add host-specific token extraction to worker summaries." else empty end),
          (if gap_count("tests_lints_builds") > 0 then "- Standardize test/lint/build outcome capture in worker summaries." else empty end)
        ] | if length == 0 then "No threshold-based candidates from this run." else .[] end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf -- '- Add worker summary enforcement before relying on chain metrics.\n'
    fi
    printf '\n## Privacy\n\n'
    printf -- '- Run state: `%s`\n' "${RUN_STATE_JSON:-missing}"
    printf -- '- Event log: `%s`\n' "${EVENTS_JSONL:-missing}"
    printf -- '- Worker summaries: `%s`\n' "${SUMMARY_ROOT:-missing}"
    printf -- '- Halt records: `%s`\n' "${HALT_ROOT:-missing}"
    printf -- '- Decision escrows: `%s`\n' "${ESCROW_ROOT:-missing}"
    printf -- '- Phase reviews: `%s`\n\n' "${PHASE_REVIEW_ROOT:-missing}"
    printf 'This report is private local telemetry under `~/.dev-studio/generic-dev-studio/chain-runs/`. Public PR and issue comments should include run IDs, PR URLs, issue numbers, and abstract gap names only, not private project file paths or velocity details.\n'
  } > "$RUN_REPORT"
}

finish_run() {
  local status="${1:-$RUN_STATUS}" reason="${2:-$RUN_FAILURE_REASON}" duration_s
  RUN_FINISHED=1
  RUN_STATUS="$status"
  RUN_FAILURE_REASON="$reason"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run complete; no chain-run report written"
    return 0
  fi
  write_run_state "$status" "$reason"
  generate_run_report "$status" "$reason"
  duration_s=$(duration_since "$RUN_STARTED_AT")
  emit_chain_event chain_run_completed "" "$RUN_ID" "" "" "$status" "$duration_s" \
    "$(jq -cn --arg report "$RUN_REPORT" --arg reason "$reason" '{report:$report, failure_reason:(if $reason == "" then null else $reason end)}')"
  if [ -n "$RESUME_ID" ]; then
    emit_chain_event chain_resume_attempt_completed "" "$RUN_ID" "" "" "$status" "$duration_s" \
      "$(jq -cn --arg attempt_id "$ATTEMPT_ID" --arg reason "$reason" '{attempt_id:$attempt_id, failure_reason:(if $reason == "" then null else $reason end)}')"
  fi
  log "report written to $RUN_REPORT"
}

abort_run() {
  local reason="${1:-failed}"
  write_halt_record "$(halt_reason_for_text "$reason")" "$reason" >/dev/null || log "halt record write failed for: $reason"
  finish_run failed "$reason"
  exit 1
}

finish_unexpected_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${RUN_FINISHED:-0}" != "1" ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
    write_halt_record "$(halt_reason_for_text "unexpected_exit_$rc")" "unexpected exit $rc" >/dev/null || log "halt record write failed for unexpected exit $rc"
    finish_run failed "unexpected_exit_$rc"
  fi
  release_state_lock
}

slugify() {
  printf '%s' "$1" | tr '/[:space:]' '--' | tr -cd '[:alnum:]_.-'
}

resolve_manifest() {
  local input="$1" candidate
  if [ -f "$input" ]; then
    printf '%s\n' "$input"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yaml"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yml"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf 'studio-chain-runner: manifest not found: %s\n' "$input" >&2
  printf 'studio-chain-runner: tried %s and %s\n' "$REPO_ROOT/chains/$input.yaml" "$REPO_ROOT/chains/$input.yml" >&2
  exit 2
}

canonical_path() {
  local path="$1" dir base
  if [ -z "$path" ]; then
    return 1
  fi
  if [ -e "$path" ]; then
    dir=$(cd "$(dirname "$path")" && pwd -P)
    base=$(basename "$path")
    printf '%s/%s\n' "$dir" "$base"
    return 0
  fi
  if [ -e "$REPO_ROOT/$path" ]; then
    dir=$(cd "$(dirname "$REPO_ROOT/$path")" && pwd -P)
    base=$(basename "$path")
    printf '%s/%s\n' "$dir" "$base"
    return 0
  fi
  printf '%s\n' "$path"
}

state_manifest_matches() {
  local state="$1" manifest="$2" state_manifest
  state_manifest=$(jq -r '.manifest // empty' "$state" 2>/dev/null || true)
  [ -n "$state_manifest" ] || return 1
  [ "$(canonical_path "$state_manifest")" = "$manifest" ]
}

state_has_true_hard_stop() {
  local state="$1" path halt_class
  halt_class=$(jq -r '(.halt_records // [])[]? | select((.halt_class // "") == "fatal") | .halt_class' "$state" 2>/dev/null | head -1)
  [ -z "$halt_class" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -r "$path" ] && jq -e '.true_hard_stop == true' "$path" >/dev/null 2>&1; then
      return 0
    fi
  done <<EOF
$(jq -r '(.halt_records // [])[]? | .path // empty' "$state" 2>/dev/null || true)
EOF
  return 1
}

state_has_open_decision_escrow() {
  local state="$1"
  jq -e '((.decision_escrows // []) | length) > 0' "$state" >/dev/null 2>&1
}

supervisor_matching_states() {
  local manifest="$1" state
  [ -d "$CHAIN_RUNS_ROOT" ] || return 0
  find "$CHAIN_RUNS_ROOT" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort | while IFS= read -r state; do
    if state_manifest_matches "$state" "$manifest"; then
      printf '%s\n' "$state"
    fi
  done
}

supervisor_state_run_id() {
  jq -r '.run_id // empty' "$1"
}

emit_supervisor_decision() {
  local action="$1" reason_id="${2:-}" selected_run_id="${3:-}" candidates_json="${4:-[]}" lock_path="${5:-}"
  [ "$EXPLAIN_NEXT" -eq 0 ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p "$CHAIN_RUN_ROOT"
  emit_chain_event chain_supervisor_decision "" "$RUN_ID" "" "" "$action" 0 \
    "$(jq -cn \
      --arg action "$action" \
      --arg reason_id "$reason_id" \
      --arg selected_run_id "$selected_run_id" \
      --arg manifest "$MANIFEST" \
      --arg lock_path "$lock_path" \
      --argjson candidate_run_ids "$candidates_json" \
      '{action:$action, reason_id:(if $reason_id == "" then null else $reason_id end), selected_run_id:(if $selected_run_id == "" then null else $selected_run_id end), candidate_run_ids:$candidate_run_ids, manifest:$manifest, lock_path:(if $lock_path == "" then null else $lock_path end)}')"
}

print_supervisor_decision() {
  local action="$1" reason_id="${2:-}" selected_run_id="${3:-}" candidates_json="${4:-[]}" lock_path="${5:-}"
  printf '# Studio Chain Supervisor Decision\n\n'
  printf -- '- Manifest: `%s`\n' "$MANIFEST"
  printf -- '- Action: `%s`\n' "$action"
  [ -z "$selected_run_id" ] || printf -- '- Selected run: `%s`\n' "$selected_run_id"
  [ -z "$reason_id" ] || printf -- '- Reason: `%s`\n' "$reason_id"
  if [ "$candidates_json" != "[]" ]; then
    printf -- '- Candidate runs: `%s`\n' "$(printf '%s' "$candidates_json" | jq -r 'join(", ")')"
  fi
  [ -z "$lock_path" ] || printf -- '- Lock: `%s`\n' "$lock_path"
  if [ "$action" = "refused_ambiguous" ]; then
    printf -- '- Manual selector: `scripts/studio-chain-runner.sh --resume <run_id> --yes`\n'
  fi
  printf '\n'
  jq -cn \
    --arg action "$action" \
    --arg reason_id "$reason_id" \
    --arg selected_run_id "$selected_run_id" \
    --arg manifest "$MANIFEST" \
    --arg state "$RUN_STATE_JSON" \
    --arg lock_path "$lock_path" \
    --argjson candidate_run_ids "$candidates_json" \
    '{schema_version:1, kind:"chain-supervisor-decision", action:$action, reason_id:(if $reason_id == "" then null else $reason_id end), selected_run_id:(if $selected_run_id == "" then null else $selected_run_id end), candidate_run_ids:$candidate_run_ids, manifest:$manifest, state:(if $state == "" then null else $state end), lock_path:(if $lock_path == "" then null else $lock_path end)}'
}

release_state_lock() {
  if [ "${SUPERVISOR_LOCK_ACQUIRED:-0}" -eq 1 ] && [ -n "${SUPERVISOR_LOCK:-}" ]; then
    rm -rf "$SUPERVISOR_LOCK"
    SUPERVISOR_LOCK_ACQUIRED=0
  fi
}

lock_is_stale() {
  local lock="$1" pid
  [ -f "$lock/pid" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

acquire_state_lock() {
  local lock="$RUN_STATE_JSON.lock"
  [ "${SUPERVISOR_LOCK_ACQUIRED:-0}" -eq 0 ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then
    SUPERVISOR_LOCK="$lock"
    SUPERVISOR_LOCK_ACQUIRED=1
    printf '%s\n' "$$" > "$lock/pid"
    printf '%s\n' "$(iso_ts_now)" > "$lock/created_at"
    return 0
  fi
  if lock_is_stale "$lock"; then
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      SUPERVISOR_LOCK="$lock"
      SUPERVISOR_LOCK_ACQUIRED=1
      printf '%s\n' "$$" > "$lock/pid"
      printf '%s\n' "$(iso_ts_now)" > "$lock/created_at"
      return 0
    fi
  fi
  emit_supervisor_decision refused_lock state_lock_held "$RUN_ID" '[]' "$lock"
  print_supervisor_decision refused_lock state_lock_held "$RUN_ID" '[]' "$lock" >&2
  exit 2
}

supervisor_decide_next() {
  local manifest="$1" mode="$2" states completed=0 eligible=0 hard_stop=0 escrow=0
  local state run_id selected_state="" selected_run_id="" candidates_json action reason_id
  MANIFEST=$(canonical_path "$(resolve_manifest "$manifest")")
  states=$(supervisor_matching_states "$MANIFEST" || true)
  candidates_json='[]'
  while IFS= read -r state; do
    [ -n "$state" ] || continue
    run_id=$(supervisor_state_run_id "$state")
    [ -n "$run_id" ] || continue
    if [ "$(jq -r '.status // "unknown"' "$state")" = "completed" ]; then
      completed=$((completed + 1))
      continue
    fi
    if state_has_true_hard_stop "$state"; then
      hard_stop=$((hard_stop + 1))
      candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
      continue
    fi
    if state_has_open_decision_escrow "$state"; then
      escrow=$((escrow + 1))
      candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
      continue
    fi
    eligible=$((eligible + 1))
    selected_state="$state"
    selected_run_id="$run_id"
    candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
  done <<EOF
$states
EOF

  if [ "$eligible" -gt 1 ]; then
    action="refused_ambiguous"
    reason_id="multiple_resumable_runs"
  elif [ "$eligible" -eq 1 ]; then
    action="resume"
  elif [ "$hard_stop" -gt 0 ]; then
    action="refused_hard_stop"
    reason_id="true_hard_stop"
  elif [ "$escrow" -gt 0 ]; then
    action="refused_escrow"
    reason_id="open_decision_escrow"
  elif [ "$completed" -gt 0 ]; then
    action="already_complete"
  else
    action="start"
    selected_run_id="$RUN_ID"
  fi

  if [ "$action" = "resume" ]; then
    RESUME_ID="$selected_run_id"
    RUN_ID="$selected_run_id"
    configure_run_paths
  elif [ "$action" = "start" ]; then
    RESUME_ID=""
    configure_run_paths
  fi

  if [ "$mode" = "explain" ]; then
    print_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json"
    exit 0
  fi

  emit_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json"
  case "$action" in
    start)
      YES=1
      acquire_state_lock
      print_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json"
      ;;
    resume)
      YES=1
      acquire_state_lock
      print_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json"
      ;;
    already_complete)
      print_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json"
      exit 0
      ;;
    refused_*)
      print_supervisor_decision "$action" "$reason_id" "$selected_run_id" "$candidates_json" >&2
      exit 2
      ;;
  esac
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

validate_branch_ref() {
  local ref="$1" label="$2"
  if ! git check-ref-format --branch "$ref" >/dev/null 2>&1; then
    printf 'studio-chain-runner: invalid %s branch name: %s\n' "$label" "$ref" >&2
    exit 2
  fi
}

validate_chain_branch() {
  local branch="$1" base="$2"
  validate_branch_ref "$base" "base"
  validate_branch_ref "$branch" "chain"

  if [ "$branch" = "$base" ]; then
    printf 'studio-chain-runner: chain branch must not equal base branch: %s\n' "$branch" >&2
    exit 2
  fi

  case "$branch" in
    main|master|trunk|develop|production)
      printf 'studio-chain-runner: refusing protected chain branch: %s\n' "$branch" >&2
      exit 2
      ;;
  esac
}

host_spawn_command() {
  local host="$1" manifest spawn
  manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT") || {
    printf 'studio-chain-runner: host "%s" has no capabilities manifest\n' "$host" >&2
    return 1
  }
  [ -f "$manifest" ] || {
    printf 'studio-chain-runner: missing host manifest: %s\n' "$manifest" >&2
    return 1
  }
  spawn=$(grep -E '^spawn_command:[[:space:]]' "$manifest" | head -1 | sed 's/^spawn_command:[[:space:]]*//' | tr -d '"'"'")
  [ -n "$spawn" ] || {
    printf 'studio-chain-runner: %s missing spawn_command\n' "$manifest" >&2
    return 1
  }
  printf '%s\n' "$spawn"
}

yaml_field() {
  yq -r ".${2} // \"\"" "$1" 2>/dev/null
}

host_sandbox_profile() {
  local host="$1" manifest
  manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT") || {
    printf 'studio-chain-runner: host "%s" has no capabilities manifest\n' "$host" >&2
    return 1
  }
  yaml_field "$manifest" sandbox_profile
}

git_metadata_strategy_for_host() {
  local host="$1" sandbox
  sandbox=$(host_sandbox_profile "$host") || return 1
  case "$sandbox" in
    workspace-write|full) printf 'local-clone\n' ;;
    host-native|none|"") printf 'linked-worktree\n' ;;
    *)
      printf 'studio-chain-runner: unknown sandbox_profile for %s: %s\n' "$host" "$sandbox" >&2
      return 2
      ;;
  esac
}

host_launch_home() {
  resolve_user_login_home 2>/dev/null || true
}

host_preflight() {
  local host="$1" repo="$2" launch_home
  launch_home=$(host_launch_home)
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
      printf 'DRY-RUN HOME=%q scripts/host-preflight.sh %q %q\n' "$launch_home" "$host" "$repo"
    else
      printf 'DRY-RUN scripts/host-preflight.sh %q %q\n' "$host" "$repo"
    fi
    return 0
  fi
  if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
    HOME="$launch_home" "$SCRIPT_DIR/host-preflight.sh" "$host" "$repo"
  else
    "$SCRIPT_DIR/host-preflight.sh" "$host" "$repo"
  fi
}

available_ram_gib() {
  if [ -n "${STUDIO_CHAIN_AVAILABLE_RAM_GIB:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_AVAILABLE_RAM_GIB"
    return 0
  fi

  if command -v vm_stat >/dev/null 2>&1; then
    vm_stat 2>/dev/null | awk '
      /page size of/ { gsub(/\./, "", $8); page=$8 }
      /Pages free:/ { gsub(/\./, "", $3); free=$3 }
      /Pages inactive:/ { gsub(/\./, "", $3); inactive=$3 }
      /Pages speculative:/ { gsub(/\./, "", $3); speculative=$3 }
      END {
        if (page <= 0) page = 4096
        gib = ((free + inactive + speculative) * page) / 1073741824
        if (gib < 0) gib = 0
        printf "%d\n", gib
      }'
    return 0
  fi

  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ { printf "%d\n", ($2 * 1024) / 1073741824; found=1 } END { if (!found) print 0 }' /proc/meminfo
    return 0
  fi

  printf '4\n'
}

healthy_xcodebuild_offload_count() {
  local registry ids id row status health_cmd count=0
  registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf '0\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0\n'; return 0; }
  health_cmd="${STUDIO_CHAIN_NODE_HEALTH_CMD:-$SCRIPT_DIR/node-health.sh}"

  ids=$(jq -r '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index("xcodebuild")) | .id' "$registry" 2>/dev/null) || ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if node_is_self "$id"; then
      continue
    fi
    row=$("$health_cmd" "$id" 2>/dev/null | head -n 1)
    status=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    case "$status" in
      healthy|moved) count=$((count + 1)) ;;
    esac
  done <<EOF
$ids
EOF
  printf '%s\n' "$count"
}

chain_worker_pool_size() {
  if [ -n "${STUDIO_CHAIN_WORKER_POOL:-}" ]; then
    case "$STUDIO_CHAIN_WORKER_POOL" in
      ''|*[!0-9]*|0) printf 'studio-chain-runner: invalid STUDIO_CHAIN_WORKER_POOL=%s\n' "$STUDIO_CHAIN_WORKER_POOL" >&2; exit 2 ;;
      *) printf '%s\n' "$STUDIO_CHAIN_WORKER_POOL"; return 0 ;;
    esac
  fi

  local offload_count desired ram_gib per_worker_gib ram_cap max_workers
  offload_count=$(healthy_xcodebuild_offload_count)
  desired=$((offload_count + 1))

  ram_gib=$(available_ram_gib)
  case "$ram_gib" in ''|*[!0-9]*) ram_gib=0 ;; esac
  per_worker_gib="${STUDIO_CHAIN_WORKER_RAM_GIB:-6}"
  case "$per_worker_gib" in ''|*[!0-9]*|0) per_worker_gib=6 ;; esac
  ram_cap=$((ram_gib / per_worker_gib))
  [ "$ram_cap" -lt 1 ] && ram_cap=1

  max_workers="${STUDIO_CHAIN_MAX_WORKERS:-}"
  if [ -n "$max_workers" ]; then
    case "$max_workers" in ''|*[!0-9]*|0) max_workers=1 ;; esac
    [ "$desired" -gt "$max_workers" ] && desired="$max_workers"
  fi
  [ "$desired" -gt "$ram_cap" ] && desired="$ram_cap"
  [ "$desired" -lt 1 ] && desired=1
  printf '%s\n' "$desired"
}

resolve_resume_state() {
  MANIFEST=$(jq -r '.manifest' "$RUN_STATE_JSON")
  [ -n "$MANIFEST" ] && [ "$MANIFEST" != "null" ] || {
    printf 'studio-chain-runner: resume state has no manifest: %s\n' "$RUN_STATE_JSON" >&2
    exit 2
  }
  RUN_STARTED_TS=$(jq -r '.started_at // empty' "$RUN_STATE_JSON")
  [ -n "$RUN_STARTED_TS" ] || RUN_STARTED_TS=$(iso_ts_now)
}

build_plan_json() {
  local out="$1" chain_count idx name base branch host phase_review_mode checkpoint_mode git_metadata_strategy issue_count i issue issue_json issue_title issue_state
  local chain_run_id issue_run_id issue_slug issue_branch issue_worktree chain_slug chain_worktree worker_pool
  local tmp chains_tmp issues_tmp
  tmp="$out.tmp.$$"
  chains_tmp="$out.chains.$$"
  printf '[]\n' > "$chains_tmp"

  chain_count=$(yq -r '.chains | length' "$MANIFEST")
  case "$chain_count" in
    ''|null|*[!0-9]*)
      printf 'studio-chain-runner: manifest must contain chains[]\n' >&2
      exit 2
      ;;
  esac
  [ "$chain_count" -gt 0 ] || { printf 'studio-chain-runner: manifest has no chains\n' >&2; exit 2; }

  for ((idx = 0; idx < chain_count; idx++)); do
    name=$(yq -r ".chains[$idx].name" "$MANIFEST")
    [ -n "$ONLY_CHAIN" ] && [ "$name" != "$ONLY_CHAIN" ] && continue
    base=$(yq -r ".chains[$idx].base // \"main\"" "$MANIFEST")
    branch=$(yq -r ".chains[$idx].branch // (\"feature/\" + .chains[$idx].name)" "$MANIFEST")
    host=$(yq -r ".chains[$idx].host // \"auto\"" "$MANIFEST")
    [ "$host" = "auto" ] && host="${HOST_OVERRIDE:-codex}"
    [ -n "$HOST_OVERRIDE" ] && host="$HOST_OVERRIDE"
    phase_review_mode=$(resolve_phase_review_mode "$idx")
    checkpoint_mode=$(resolve_checkpoint_mode "$idx")
    git_metadata_strategy=$(git_metadata_strategy_for_host "$host")
    validate_chain_branch "$branch" "$base"
    issue_count=$(yq -r ".chains[$idx].issues | length" "$MANIFEST")
    case "$issue_count" in
      ''|null|*[!0-9]*|0)
        printf 'studio-chain-runner: chain %s has no issues\n' "$name" >&2
        exit 2
        ;;
    esac
    chain_run_id=$(mint_uuidv7)
    chain_slug=$(slugify "$name")
    chain_worktree="$RUN_ROOT/$chain_slug-feature"
    worker_pool=$(chain_worker_pool_size)
    issues_tmp="$out.issues.$$"
    printf '[]\n' > "$issues_tmp"
    for ((i = 0; i < issue_count; i++)); do
      issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
      case "$issue" in ''|null|*[!0-9]*)
        printf 'studio-chain-runner: invalid issue id in chain %s: %s\n' "$name" "$issue" >&2
        exit 2
        ;;
      esac
      issue_json=$(with_login_home_for_github gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,state,url)
      issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
      issue_state=$(printf '%s' "$issue_json" | jq -r '.state')
      if [ "$ALLOW_CLOSED_ISSUES" -eq 0 ] && [ "$issue_state" != "OPEN" ]; then
        printf 'studio-chain-runner: issue #%s is %s; use --allow-closed-issues to include it\n' "$issue" "$issue_state" >&2
        exit 2
      fi
      issue_slug=$(slugify "$issue")
      issue_branch="$branch-issue-$issue_slug"
      validate_branch_ref "$issue_branch" "issue"
      issue_worktree="$RUN_ROOT/$chain_slug-issue-$issue_slug"
      issue_run_id=$(mint_uuidv7)
      jq \
        --argjson issue "$issue" \
        --arg title "$issue_title" \
        --arg state "$issue_state" \
        --arg branch "$issue_branch" \
        --arg worktree "$issue_worktree" \
        --arg issue_run_id "$issue_run_id" \
        '. + [{number:$issue,title:$title,state:$state,issue_branch:$branch,issue_worktree:$worktree,issue_run_id:$issue_run_id,status:"pending"}]' \
        "$issues_tmp" > "$issues_tmp.next"
      mv "$issues_tmp.next" "$issues_tmp"
    done
    jq \
      --arg name "$name" \
      --arg base "$base" \
      --arg branch "$branch" \
      --arg host "$host" \
      --arg phase_review_mode "$phase_review_mode" \
      --arg checkpoint_mode "$checkpoint_mode" \
      --arg git_metadata_strategy "$git_metadata_strategy" \
      --arg chain_run_id "$chain_run_id" \
      --arg worktree "$chain_worktree" \
      --argjson worker_pool "$worker_pool" \
      --slurpfile issues "$issues_tmp" \
      '. + [{name:$name,base:$base,branch:$branch,host:$host,phase_review:$phase_review_mode,checkpoint:$checkpoint_mode,git_metadata_strategy:$git_metadata_strategy,chain_run_id:$chain_run_id,chain_worktree:$worktree,worker_pool:$worker_pool,status:"pending",issues:$issues[0]}]' \
      "$chains_tmp" > "$chains_tmp.next"
    mv "$chains_tmp.next" "$chains_tmp"
    rm -f "$issues_tmp"
  done

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest "$MANIFEST" \
    --arg only_chain "$ONLY_CHAIN" \
    --arg host_override "$HOST_OVERRIDE" \
    --arg parallel_chains "$PARALLEL_CHAINS" \
    --arg checkpoint_override "$CHECKPOINT_OVERRIDE" \
    --slurpfile chains "$chains_tmp" \
    '{schema_version:1, run_id:$run_id, manifest:$manifest, only_chain:(if $only_chain == "" then null else $only_chain end), host_override:(if $host_override == "" then null else $host_override end), parallel_chains:$parallel_chains, checkpoint_override:(if $checkpoint_override == "" then null else $checkpoint_override end), chains:$chains[0]}' > "$tmp"
  mv "$tmp" "$out"
  rm -f "$chains_tmp"
}

validate_execution_graph() {
  local plan="$1"
  local duplicate_issues duplicate_branches protected_targets dependency_conflicts
  duplicate_issues=$(jq -r '[.chains[].issues[].number] | group_by(.)[] | select(length > 1) | .[0]' "$plan" | paste -sd, -)
  [ -z "$duplicate_issues" ] || { printf 'studio-chain-runner: duplicate issue IDs across chains: %s\n' "$duplicate_issues" >&2; exit 2; }
  duplicate_branches=$(jq -r '[.chains[].branch, (.chains[].issues[].issue_branch)] | group_by(.)[] | select(length > 1) | .[0]' "$plan" | paste -sd, -)
  [ -z "$duplicate_branches" ] || { printf 'studio-chain-runner: duplicate branch refs in plan: %s\n' "$duplicate_branches" >&2; exit 2; }
  protected_targets=$(jq -r '.chains[].base | select(. == "feature" or . == "production" or . == "develop" or . == "trunk")' "$plan" | paste -sd, -)
  [ -z "$protected_targets" ] || { printf 'studio-chain-runner: protected base targets are not allowed: %s\n' "$protected_targets" >&2; exit 2; }
  dependency_conflicts=$(yq -r '[.chains[] | select(has("depends_on") or has("dependencies"))] | length' "$MANIFEST")
  if [ "$dependency_conflicts" != "0" ] && [ "$PARALLEL_CHAINS" != "1" ]; then
    log "dependency metadata present; falling back to sequential chain execution"
    PARALLEL_CHAINS="1"
  fi
}

live_preflight() {
  local plan="$1" reviewer_host branch issue_branch base
  with_login_home_for_github gh auth status >/dev/null 2>&1 || {
    printf 'studio-chain-runner: GitHub auth is not available\n' >&2
    exit 2
  }
  emit_chain_event chain_auth_normalized "" "$RUN_ID" "" "" completed 0 \
    "$(jq -cn --arg home_source "login-home" --arg github_auth "available" --arg secrets "omitted" '{home_source:$home_source, github_auth:$github_auth, secrets:$secrets}')"
  reviewer_host="${STUDIO_REVIEW_HOST:-claude-reviewer}"
  resolve_capabilities_manifest "$reviewer_host" "$REPO_ROOT" >/dev/null || {
    printf 'studio-chain-runner: reviewer host unavailable: %s\n' "$reviewer_host" >&2
    exit 2
  }
  while IFS=$'\t' read -r branch base; do
    with_login_home_for_github git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1 || {
      printf 'studio-chain-runner: cannot verify origin/%s\n' "$base" >&2
      exit 2
    }
    if [ -z "$RESUME_ID" ] && git show-ref --verify --quiet "refs/heads/$branch"; then
      printf 'studio-chain-runner: local chain branch already exists: %s\n' "$branch" >&2
      exit 2
    fi
    if [ -z "$RESUME_ID" ] && with_login_home_for_github git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      printf 'studio-chain-runner: remote chain branch already exists: %s\n' "$branch" >&2
      exit 2
    fi
  done <<EOF
$(jq -r '.chains[] | [.branch, .base] | @tsv' "$plan")
EOF
  while IFS= read -r issue_branch; do
    [ -n "$issue_branch" ] || continue
    if [ -z "$RESUME_ID" ] && git show-ref --verify --quiet "refs/heads/$issue_branch"; then
      printf 'studio-chain-runner: local issue branch already exists: %s\n' "$issue_branch" >&2
      exit 2
    fi
    if [ -z "$RESUME_ID" ] && with_login_home_for_github git ls-remote --exit-code --heads origin "$issue_branch" >/dev/null 2>&1; then
      printf 'studio-chain-runner: remote issue branch already exists: %s\n' "$issue_branch" >&2
      exit 2
    fi
  done <<EOF
$(jq -r '.chains[].issues[].issue_branch' "$plan")
EOF
}

explain_plan() {
  local plan="$1" effective_parallel risk
  effective_parallel=1
  risk="sequential execution: this runner serializes chain PR/review/issue-closure mutation; preflight still blocks duplicate issues, branch collisions, and declared dependency conflicts before execution"
  printf '# Studio Chain Plan\n\n'
  printf -- '- Run UUID: `%s`\n' "$RUN_ID"
  printf -- '- Manifest: `%s`\n' "$MANIFEST"
  printf -- '- State: `%s`\n' "$RUN_STATE_JSON"
  printf -- '- Parallel chains: `%s` effective `%s`\n' "$PARALLEL_CHAINS" "$effective_parallel"
  printf -- '- Host/model policy: manifest host, overridden by `--host`; `auto` resolves to `%s`\n' "${HOST_OVERRIDE:-codex}"
  printf -- '- Risk notes: %s\n\n' "$risk"
  jq -r '
    .chains[] |
    "## Chain \(.name)\n\n" +
    "- Chain-run UUID: `\(.chain_run_id)`\n" +
    "- Base: `\(.base)`\n" +
    "- Branch: `\(.branch)`\n" +
    "- Worktree: `\(.chain_worktree)`\n" +
    "- Host: `\(.host)`\n" +
    "- Git metadata strategy: `\(.git_metadata_strategy // "linked-worktree")`\n" +
    "- Parent finalize: `git-metadata-only worker blocks can be committed by the parent runner after summary/check validation`\n" +
    "- Phase review: `\(.phase_review // "auto")`\n" +
    "- Checkpoint automation: `\(.checkpoint // "off")`\n" +
    "- Worker pool: `\(.worker_pool)`\n" +
    "- Planned PR: base `\(.base)`, head `\(.branch)`, title `studio chain: \(.name)`\n\n" +
    "| Issue | State | Status | Issue-run UUID | Branch | Worktree |\n|---:|---|---|---|---|---|\n" +
    ([.issues[] | "| #\(.number) \(.title) | \(.state) | \(.status) | `\(.issue_run_id)` | `\(.issue_branch)` | `\(.issue_worktree)` |"] | join("\n")) +
    "\n"
  ' "$plan"
}

prepare_plan() {
  if [ -n "$RESUME_ID" ]; then
    resolve_resume_state
    cp "$RUN_STATE_JSON" "$PLAN_JSON"
  else
    MANIFEST=$(resolve_manifest "$MANIFEST")
    MANIFEST=$(canonical_path "$MANIFEST")
    build_plan_json "$PLAN_JSON"
    if [ "$DRY_RUN" -eq 0 ]; then
      write_run_state planned ""
    fi
  fi
  validate_execution_graph "$PLAN_JSON"
}

trap finish_unexpected_exit EXIT

if [ "$EXPLAIN_NEXT" -eq 1 ]; then
  supervisor_decide_next "$MANIFEST" explain
fi

if [ "$AUTO_MODE" -eq 1 ]; then
  supervisor_decide_next "$MANIFEST" auto
fi

if [ -n "$RESUME_ID" ]; then
  RUN_ID="$RESUME_ID"
  configure_run_paths
  if [ ! -f "$RUN_STATE_JSON" ]; then
    printf 'studio-chain-runner: resume state not found: %s\n' "$RUN_STATE_JSON" >&2
    exit 2
  fi
  if [ "$YES" -eq 1 ]; then
    acquire_state_lock
  fi
elif [ "$YES" -eq 1 ]; then
  acquire_state_lock
fi

prepare_plan
explain_plan "$PLAN_JSON"

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run plan follows with non-mutating commands"
elif [ "$YES" -eq 0 ]; then
  log "plan written; rerun with --yes or --no-confirm to execute, or --resume $RUN_ID --yes after a blocked run"
  exit 0
else
  live_preflight "$PLAN_JSON"
  write_run_state running ""
fi

emit_chain_event chain_run_started "" "$RUN_ID" "" "" running 0 \
  "$(jq -cn --arg manifest_arg "$MANIFEST" --arg only_chain "$ONLY_CHAIN" --arg host_override "$HOST_OVERRIDE" --arg resume_id "$RESUME_ID" --arg attempt_id "$ATTEMPT_ID" --arg parent_host "$PARENT_STUDIO_HOST" '{manifest_arg:$manifest_arg, only_chain:(if $only_chain == "" then null else $only_chain end), host_override:(if $host_override == "" then null else $host_override end), resume_id:(if $resume_id == "" then null else $resume_id end), attempt_id:$attempt_id, parent_host:$parent_host}')"
if [ -n "$RESUME_ID" ]; then
  emit_chain_event chain_resume_attempt_started "" "$RUN_ID" "" "" running 0 \
    "$(jq -cn --arg attempt_id "$ATTEMPT_ID" '{attempt_id:$attempt_id}')"
fi

chain_count=$(jq '.chains | length' "$PLAN_JSON")

execute_issue_session() {
  local chain_name="$1" chain_branch="$2" issue="$3" host="$4" git_metadata_strategy="$5" worktree="$6" issue_branch="$7" chain_run_id="$8" issue_run_id="$9" before="${10}" phase_review_context="${11:-[]}"
  local issue_json issue_title issue_body spawn prompt summary_path start_path
  local -a spawn_argv
  local launch_home=""

  issue_json=$(with_login_home_for_github gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,body,url,state)
  issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
  issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  summary_path="$worktree/.studio/chain-worker-summary.json"
  start_path="$worktree/.studio/chain-task-start.json"
  if [ "$DRY_RUN" -eq 0 ]; then
    write_chain_task_start_envelope "$chain_name" "$chain_branch" "$issue_branch" "$issue_json" "$host" "$git_metadata_strategy" "$worktree" "$chain_run_id" "$issue_run_id" "$summary_path" "$start_path" "$phase_review_context"
  fi

  spawn=$(host_spawn_command "$host")
  # shellcheck disable=SC2206
  spawn_argv=( $spawn )
  launch_home=$(host_launch_home)

  prompt=$(cat <<EOF
Implement this studio issue in a fresh chain-runner session.

You are executing one issue inside an automated chain runner.

Repo: $REPO_SLUG
Run UUID: $RUN_ID
Chain-run UUID: $chain_run_id
Issue-run UUID: $issue_run_id
Chain: $chain_name
Chain branch: $chain_branch
Issue: #$issue - $issue_title
Working directory: $worktree
Git metadata strategy: $git_metadata_strategy
Task start envelope: $start_path
Required summary artifact: $summary_path

Rules:
- Work only in this working directory.
- Read $start_path first when present; it is the bounded machine-readable start envelope for this task.
- Implement only issue #$issue.
- Keep changes scoped to this issue.
- Commit the result on the current branch.
- Include "Closes #$issue" in the commit message.
- Before exit, write $summary_path as valid JSON.
- Do not add or commit $summary_path; it is a private parent-runner artifact.
- Do not open a PR.
- Do not merge to main.
- Do not close the issue; the chain runner owns issue closure after integration.
- If blocked, exit non-zero after writing a concise reason.

Summary JSON fields:
- schema_version: 1
- kind: "completion"
- created_at
- status
- run_id: "$RUN_ID"
- chain_run_id: "$chain_run_id"
- issue_run_id: "$issue_run_id"
- chain: "$chain_name"
- issue_number: $issue
- issue_title: "$issue_title"
- host: "$host"
- model/model_version/effort when known, otherwise null
- started_at/ended_at/duration_s
- exit_code
- commit_before: "$before"
- commit_after
- files_changed/additions/deletions/generated_file_count
- tests/lints/builds arrays with command/outcome when run
- tokens object when available, otherwise null
- functionality_delivered optional string or array describing what users/agents can now do
- refactoring_needed_now optional array for cleanup required by this task
- refactoring_follow_ups optional array for deferred design debt with reason, affected area, risk, and suggested timing
- carryover optional string or array for follow-up issues, parking-lot adds, or uncaptured asks
- lessons optional string or array when telemetry supports next-chain recommendations
- telemetry_gaps array listing missing fields such as "tokens" or "model"
- blocked_reason when nonzero

Private phase-review context forwarded from prior clean outcome reviews:
$phase_review_context

Issue body:
$issue_body
EOF
)

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN cd %q && ' "$worktree"
    printf '%q ' "${spawn_argv[@]}"
    printf '%q\n' "$prompt"
    return 0
  fi

  if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
    (cd "$worktree" && env HOME="$launch_home" "${spawn_argv[@]}" "$prompt")
  else
    (cd "$worktree" && "${spawn_argv[@]}" "$prompt")
  fi
}

finalize_chain_pr() {
  local chain_name="$1" chain_branch="$2" chain_worktree="$3" base="$4" chain_run_id="$5" implementation_host="${6:-}"
  local pr_url pr_number review_started_at review_rc review_duration review_out review_verdict review_model review_effort review_host review_parent_host
  [ -n "$implementation_host" ] || implementation_host=$(resolve_current_studio_host unknown)

  log "rebasing $chain_branch on origin/$base"
  run with_login_home_for_github git -C "$chain_worktree" fetch origin --prune
  run git -C "$chain_worktree" rebase "origin/$base"
  run with_login_home_for_github git -C "$chain_worktree" push -u origin "$chain_branch"

  if [ "$DRY_RUN" -eq 1 ]; then
    FINAL_PR_URL="<dry-run-pr-url>"
    printf 'DRY-RUN gh pr create --base %q --head %q --title %q --body ...\n' "$base" "$chain_branch" "$chain_name"
    printf 'DRY-RUN scripts/pr-headless-review.sh <pr> --method auto\n'
    return 0
  fi

  pr_url=$(with_login_home_for_github gh pr create \
    --repo "$REPO_SLUG" \
    --base "$base" \
    --head "$chain_branch" \
    --title "studio chain: $chain_name" \
    --body "Automated chain PR for \`$chain_name\`.

Run by \`scripts/studio-chain-runner.sh\`.

Chain run: \`$RUN_ID\`
Chain-run UUID: \`$chain_run_id\`
Private report: local only; resolve by run ID on the machine that ran the chain.

Review gate: \`scripts/pr-headless-review.sh <pr> --method auto\`.")
  pr_number=$(printf '%s' "$pr_url" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  FINAL_PR_URL="$pr_url"
  log "opened PR $pr_url"
  emit_chain_event chain_pr_opened "$pr_number" "$RUN_ID" "$chain_run_id" "" completed 0 \
    "$(jq -cn --arg pr_url "$pr_url" --arg pr_number "$pr_number" --arg branch "$chain_branch" '{pr_url:$pr_url, pr_number:$pr_number, branch:$branch}')"
  if ! with_login_home_for_github gh pr comment "$pr_number" --repo "$REPO_SLUG" --body "Chain run: \`$RUN_ID\`

Private telemetry report: local only; resolve by run ID on the machine that ran the chain.

Public-safe telemetry: run/chain UUIDs and abstract gap names only."; then
    abort_run "PR telemetry comment failed for $pr_url"
  fi

  review_started_at=$(now_epoch)
  review_out="$CHAIN_RUN_ROOT/review-$pr_number.out"
  set +e
  STUDIO_PARENT_HOST="${STUDIO_PARENT_HOST:-$implementation_host}" "$SCRIPT_DIR/pr-headless-review.sh" "$pr_number" --method auto >"$review_out" 2>&1
  review_rc=$?
  set -e
  cat "$review_out"
  review_duration=$(duration_since "$review_started_at")
  review_verdict=$(sed -n 's/^PR_REVIEW_VERDICT=//p' "$review_out" | tail -1)
  review_model=$(sed -n 's/^PR_REVIEW_MODEL_ID=//p' "$review_out" | tail -1)
  review_effort=$(sed -n 's/^PR_REVIEW_REASONING_EFFORT=//p' "$review_out" | tail -1)
  review_host=$(sed -n 's/^PR_REVIEW_HOST=//p' "$review_out" | tail -1)
  review_parent_host=$(sed -n 's/^PR_REVIEW_PARENT_HOST=//p' "$review_out" | tail -1)
  if [ "$review_rc" -eq 0 ]; then
    emit_chain_event chain_review_completed "$pr_number" "$RUN_ID" "$chain_run_id" "" completed "$review_duration" \
      "$(jq -cn --arg pr_url "$pr_url" --argjson exit_code "$review_rc" --arg verdict "$review_verdict" --arg model "$review_model" --arg effort "$review_effort" --arg review_host "$review_host" --arg parent_host "$review_parent_host" --arg output "$review_out" '{pr_url:$pr_url, exit_code:$exit_code, verdict:(if $verdict == "" then null else $verdict end), model:(if $model == "" then null else $model end), effort:(if $effort == "" then null else $effort end), review_host:(if $review_host == "" then null else $review_host end), parent_host:(if $parent_host == "" then null else $parent_host end), wrapper_output:$output}')"
  else
    emit_chain_event chain_review_completed "$pr_number" "$RUN_ID" "$chain_run_id" "" failed "$review_duration" \
      "$(jq -cn --arg pr_url "$pr_url" --argjson exit_code "$review_rc" --arg verdict "$review_verdict" --arg model "$review_model" --arg effort "$review_effort" --arg review_host "$review_host" --arg parent_host "$review_parent_host" --arg output "$review_out" '{pr_url:$pr_url, exit_code:$exit_code, verdict:(if $verdict == "" then null else $verdict end), model:(if $model == "" then null else $model end), effort:(if $effort == "" then null else $effort end), review_host:(if $review_host == "" then null else $review_host end), parent_host:(if $parent_host == "" then null else $parent_host end), wrapper_output:$output}')"
    abort_run "PR review failed for $pr_url"
  fi
}

write_issue_phase_plan_artifact() {
  local artifact="$1" chain_name="$2" branch="$3" issue="$4" issue_run_id="$5" host="$6" before="$7" context="$8"
  mkdir -p "$(dirname "$artifact")"
  {
    printf '# Chain Issue Phase Plan\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Chain: `%s`\n' "$chain_name"
    printf -- '- Branch: `%s`\n' "$branch"
    printf -- '- Issue: `#%s`\n' "$issue"
    printf -- '- Issue-run UUID: `%s`\n' "$issue_run_id"
    printf -- '- Host: `%s`\n' "$host"
    printf -- '- Commit before: `%s`\n\n' "$before"
    printf '## Goal\n\n'
    printf 'Execute exactly this issue in its isolated worktree and commit the result on the issue branch.\n\n'
    printf '## Scope\n\n'
    printf -- '- In: bounded issue implementation, private worker summary, focused verification evidence.\n'
    printf -- '- Out: PR creation, merge to main, issue closure, unrelated issue work, public copy of private review prose.\n\n'
    printf '## Prior Clean Outcome Feedback\n\n'
    if [ "$(printf '%s' "$context" | jq 'length')" -gt 0 ]; then
      printf '%s\n' "$context" | jq -r '.[] | "- \(.kind): \(.text)"'
    else
      printf 'None.\n'
    fi
    printf '\n## Acceptance Criteria\n\n'
    printf -- '- Worker reads `.studio/chain-task-start.json` before acting.\n'
    printf -- '- Worker summary is valid JSON and remains uncommitted.\n'
    printf -- '- Issue branch produces a non-empty commit for successful execution.\n'
    printf -- '- Any stale assumption from prior outcome feedback is handled or surfaced in the worker summary.\n\n'
    printf '## Explicit Ask\n\n'
    printf "Review whether this issue phase is safe to execute now. What's still wrong or missing?\n"
  } > "$artifact"
}

write_issue_phase_outcome_artifact() {
  local artifact="$1" chain_name="$2" issue="$3" issue_run_id="$4" before="$5" after="$6" summary_file="$7"
  mkdir -p "$(dirname "$artifact")"
  {
    printf '# Chain Issue Phase Outcome\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Chain: `%s`\n' "$chain_name"
    printf -- '- Issue: `#%s`\n' "$issue"
    printf -- '- Issue-run UUID: `%s`\n' "$issue_run_id"
    printf -- '- Commit before: `%s`\n' "$before"
    printf -- '- Commit after: `%s`\n' "$after"
    printf -- '- Worker summary: `%s`\n\n' "$summary_file"
    printf '## What Changed\n\n'
    jq -r '
      def lines($v):
        if $v == null then []
        elif ($v | type) == "array" then [$v[] | tostring]
        elif ($v | type) == "object" then [$v | tojson]
        else [$v | tostring]
        end;
      (lines(.functionality_delivered) | if length == 0 then ["No worker narrative supplied."] else . end)[] | "- \(.)"
    ' "$summary_file"
    printf '\n## Refactoring Pressure\n\n'
    jq -r '
      def rows($label; $items):
        ($items // []) as $xs |
        if ($xs | length) == 0 then ["- \($label): none"]
        else [ $xs[] | "- \($label): \(.affected_area // "unknown area") - \(.reason // "no reason supplied") (risk: \(.risk // "unknown")\(if .suggested_timing then ", timing: \(.suggested_timing)" else "" end))" ]
        end;
      rows("needed now"; .refactoring_needed_now)[],
      rows("follow-up proposed"; .refactoring_follow_ups)[]
    ' "$summary_file"
    printf '\n## Diff Summary\n\n'
    jq -r '"- Files changed: \(.files_changed // 0)\n- Additions: \(.additions // 0)\n- Deletions: \(.deletions // 0)\n- Generated files: \(.generated_file_count // 0)"' "$summary_file"
    printf '\n\n## Changed Artifacts\n\n'
    jq -r '(.changed_artifacts // []) | if length == 0 then "None listed." else .[] | "- `\(.)`" end' "$summary_file"
    printf '\n## Verification Evidence\n\n'
    jq -r '
      def rows($name; $items):
        ($items // []) as $xs |
        if ($xs | length) == 0 then ["- \($name): none supplied"]
        else [ $xs[] | "- \($name): \(.command // .name // "unnamed") -> \(.outcome // .status // "unknown")" ]
        end;
      rows("test"; .tests)[], rows("lint"; .lints)[], rows("build"; .builds)[]
    ' "$summary_file"
    printf '\n## Explicit Ask\n\n'
    printf 'Did execution match the plan? Identify stale assumptions, warnings, recommendations, or accepted plan adjustments for upcoming phases. Do not include public-sensitive raw details.\n'
  } > "$artifact"
}

run_issue_job() {
  local name="$1" branch="$2" chain_worktree="$3" issue="$4" host="$5" git_metadata_strategy="$6" issue_worktree="$7" issue_branch="$8" chain_run_id="$9" issue_run_id="${10}" result_file="${11}" phase_review_mode="${12:-auto}" issue_count_for_review="${13:-1}"
  local before after worker_rc child_worker_rc summary_file issue_duration summary_payload issue_started_at child_reason_id child_blocked_reason parent_finalized effective_worker_rc
  local phase_context boundary_id phase_plan_artifact phase_outcome_artifact phase_review_rc phase_review_reason
  issue_started_at=$(now_epoch)
  parent_finalized=false

  log "issue #$issue -> $issue_branch"
  if [ "$DRY_RUN" -eq 0 ]; then
    chain_git_prepare_issue_workspace "$REPO_ROOT" "$chain_worktree" "$branch" "$issue_worktree" "$issue_branch" "$git_metadata_strategy"
    before=$(git -C "$issue_worktree" rev-parse HEAD)
  else
    printf 'DRY-RUN git metadata strategy for host %q: %s\n' "$host" "$git_metadata_strategy"
    case "$git_metadata_strategy" in
      linked-worktree)
        printf 'DRY-RUN git worktree add -B %q %q %q\n' "$issue_branch" "$issue_worktree" "$branch"
        ;;
      local-clone)
        printf 'DRY-RUN git clone --no-local --branch %q %q %q\n' "$branch" "$chain_worktree" "$issue_worktree"
        printf 'DRY-RUN git -C %q checkout -B %q %q\n' "$issue_worktree" "$issue_branch" "$branch"
        ;;
      *)
        printf 'studio-chain-runner: unknown git metadata strategy: %s\n' "$git_metadata_strategy" >&2
        exit 2
        ;;
    esac
    before="dry-run-before"
  fi

  emit_chain_event chain_issue_started "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" running 0 \
    "$(jq -cn --arg chain "$name" --arg branch "$issue_branch" --arg host "$host" --arg before "$before" --arg git_metadata_strategy "$git_metadata_strategy" '{chain:$chain, issue_branch:$branch, host:$host, commit_before:$before, git_metadata_strategy:$git_metadata_strategy}')"
  mark_issue_state "$issue_run_id" running "$before"
  phase_context=$(phase_review_feedback_for_issue_json "$issue_run_id")
  mark_phase_review_feedback_consumed "$issue_run_id"

  if [ "$DRY_RUN" -eq 0 ] && phase_review_required_for_issue "$phase_review_mode" "$issue_count_for_review"; then
    boundary_id="$chain_run_id-$issue_run_id"
    phase_plan_artifact="$PHASE_REVIEW_ROOT/$boundary_id-plan.md"
    write_issue_phase_plan_artifact "$phase_plan_artifact" "$name" "$branch" "$issue" "$issue_run_id" "$host" "$before" "$phase_context"
    set +e
    run_phase_review_gate plan "$boundary_id" "$phase_plan_artifact" "$chain_run_id" "$issue_run_id" "$name" "$issue"
    phase_review_rc=$?
    set -e
    if [ "$phase_review_rc" -ne 0 ]; then
      case "$phase_review_rc" in
        70) phase_review_reason="reviewer_host_ineligible" ;;
        71) phase_review_reason="reviewer_blocked" ;;
        72) phase_review_reason="reviewer_ambiguous" ;;
        *) phase_review_reason="required_review_failed" ;;
      esac
      mark_issue_state "$issue_run_id" failed "$before" "$before" "" "phase_review_failed"
      jq -n --arg issue "$issue" --arg reason "$phase_review_reason" \
        '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
      return 0
    fi
  fi

  set +e
  execute_issue_session "$name" "$branch" "$issue" "$host" "$git_metadata_strategy" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$before" "$phase_context"
  worker_rc=$?
  set -e
  child_worker_rc=$worker_rc

  if [ "$DRY_RUN" -eq 1 ]; then
    jq -n \
      --arg issue "$issue" \
      --arg branch "$issue_branch" \
      --arg worktree "$issue_worktree" \
      '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree}' > "$result_file"
    return 0
  fi

  after=$(git -C "$issue_worktree" rev-parse HEAD)
  summary_file=$(ingest_worker_summary "$name" "$issue" "$host" "$issue_worktree" "$before" "$after" "$worker_rc" "$issue_started_at" "$chain_run_id" "$issue_run_id")
  effective_worker_rc=$(chain_git_parent_finalize_effective_worker_rc "$worker_rc" "$summary_file")
  write_decision_escrows_from_summary "$summary_file" || log "decision escrow extraction failed for $summary_file"
  issue_duration=$(duration_since "$issue_started_at")

  if worker_summary_tracked "$issue_worktree"; then
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" \
      "$(jq -cn --arg summary "$summary_file" --arg reason "worker_summary_committed" '{summary:$summary, failure_reason:$reason}')"
    mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "worker_summary_committed"
    jq -n --arg issue "$issue" --arg reason "issue #$issue committed private worker summary" \
      '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
    return 0
  fi

  rm -rf "$issue_worktree/.studio"
  if [ "$effective_worker_rc" -ne 0 ] && [ "$after" = "$before" ] \
    && chain_git_parent_finalize_summary_eligible "$summary_file" \
    && chain_git_parent_finalize_has_public_diff "$issue_worktree"; then
    log "issue #$issue worker could not write git metadata; parent finalizing commit"
    if chain_git_parent_finalize_issue_commit "$issue_worktree" "$issue" "$summary_file"; then
      after=$(git -C "$issue_worktree" rev-parse HEAD)
      refresh_summary_commit_metrics "$summary_file" "$issue_worktree" "$before" "$after" true
      parent_finalized=true
      worker_rc=0
      emit_chain_event chain_parent_commit_finalized "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
        "$(chain_git_parent_finalize_event_payload "$summary_file" "$before" "$after" "$host")"
    else
      log "issue #$issue parent finalize declined; preserving worker failure path"
    fi
  fi

  worker_rc=$(chain_git_parent_finalize_reconciled_worker_rc "$worker_rc" "$effective_worker_rc" "$parent_finalized")

  summary_payload=$(jq -c \
    --arg summary "$summary_file" \
    --arg after "$after" \
    --argjson exit_code "$worker_rc" \
    --argjson child_exit_code "$child_worker_rc" \
    --argjson duration_s "$issue_duration" \
    --argjson parent_finalized "$parent_finalized" \
    '{summary:$summary, commit_after:$after, exit_code:$exit_code, child_exit_code:$child_exit_code, worker_duration_s:$duration_s, parent_finalized:$parent_finalized, telemetry_gaps:(.telemetry_gaps // [])}' "$summary_file")

  if [ "$worker_rc" -ne 0 ]; then
    child_reason_id=$(jq -r '.halt_reason_id // empty' "$summary_file")
    if [ -z "$child_reason_id" ]; then
      child_blocked_reason=$(jq -r '.blocked_reason // empty' "$summary_file")
      child_reason_id=$(halt_reason_for_text "${child_blocked_reason:-worker exited $worker_rc}")
    fi
    write_halt_record "$child_reason_id" "issue #$issue worker exited $worker_rc" "$chain_run_id" "$issue_run_id" "$name" "$issue" "child-worker" >/dev/null || log "halt record write failed for issue #$issue"
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" "$summary_payload"
    mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "worker_exited_$worker_rc"
    jq -n --arg issue "$issue" --argjson rc "$worker_rc" --arg reason "issue #$issue worker exited $worker_rc" \
      '{status:"failed", issue:($issue|tonumber), exit_code:$rc, reason:$reason}' > "$result_file"
    return 0
  fi

  if [ "$after" = "$before" ]; then
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" \
      "$(jq -cn --arg summary "$summary_file" --arg reason "no_commit" '{summary:$summary, failure_reason:$reason}')"
    mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "no_commit"
    printf 'studio-chain-runner: issue #%s produced no commit; leaving worktree at %s\n' "$issue" "$issue_worktree" >&2
    jq -n --arg issue "$issue" --arg reason "issue #$issue produced no commit" \
      '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
    return 0
  fi

  if phase_review_required_for_issue "$phase_review_mode" "$issue_count_for_review"; then
    boundary_id="$chain_run_id-$issue_run_id"
    phase_outcome_artifact="$PHASE_REVIEW_ROOT/$boundary_id-outcome.md"
    write_issue_phase_outcome_artifact "$phase_outcome_artifact" "$name" "$issue" "$issue_run_id" "$before" "$after" "$summary_file"
    set +e
    run_phase_review_gate outcome "$boundary_id" "$phase_outcome_artifact" "$chain_run_id" "$issue_run_id" "$name" "$issue"
    phase_review_rc=$?
    set -e
    if [ "$phase_review_rc" -ne 0 ]; then
      case "$phase_review_rc" in
        70) phase_review_reason="reviewer_host_ineligible" ;;
        71) phase_review_reason="reviewer_blocked" ;;
        72) phase_review_reason="reviewer_ambiguous" ;;
        *) phase_review_reason="required_review_failed" ;;
      esac
      emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" "$summary_payload"
      mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "phase_review_failed"
      jq -n --arg issue "$issue" --arg reason "$phase_review_reason" \
        '{status:"failed", issue:($issue|tonumber), reason:$reason}' > "$result_file"
      return 0
    fi
  fi

  emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed "$issue_duration" "$summary_payload"
  mark_issue_state "$issue_run_id" completed "$before" "$after" "$summary_file"
  jq -n \
    --arg issue "$issue" \
    --arg branch "$issue_branch" \
    --arg worktree "$issue_worktree" \
    --arg before "$before" \
    --arg after "$after" \
    '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree, commit_before:$before, commit_after:$after}' > "$result_file"
}

wait_for_issue_slot() {
  local blocking="${1:-0}" running pid
  local -a next_pids
  while :; do
    running=0
    next_pids=()
    for pid in "${ISSUE_PIDS[@]:-}"; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        next_pids+=("$pid")
        running=$((running + 1))
      else
        wait "$pid" 2>/dev/null || true
      fi
    done
    if [ "${#next_pids[@]}" -gt 0 ]; then
      ISSUE_PIDS=("${next_pids[@]}")
    else
      ISSUE_PIDS=()
    fi
    [ "$running" -lt "$CHAIN_WORKER_POOL" ] && return 0
    [ "$blocking" = "1" ] || return 0
    sleep 2
  done
}

wait_for_all_issue_jobs() {
  local pid
  for pid in "${ISSUE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
  ISSUE_PIDS=()
}

git_checkout_exists() {
  local worktree="$1"
  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

integrate_issue_result() {
  local chain_name="$1" branch="$2" chain_worktree="$3" issue="$4" git_metadata_strategy="$5" result_file="$6" chain_run_id="$7" issue_run_id="$8"
  local issue_branch issue_worktree result_commit_after

  issue_branch=$(jq -r '.issue_branch' "$result_file")
  issue_worktree=$(jq -r '.issue_worktree' "$result_file")
  result_commit_after=$(jq -r '.commit_after // ""' "$result_file")

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(jq -r '.resumed // false' "$result_file")" = "true" ]; then
      case "$git_metadata_strategy" in
        linked-worktree)
          if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$issue_branch"; then
            log "resume assumes completed issue #$issue already integrated; issue branch missing"
            return 0
          fi
          ;;
        local-clone)
          if [ ! -d "$issue_worktree/.git" ]; then
            if [ -n "$result_commit_after" ] \
              && git -C "$chain_worktree" cat-file -e "$result_commit_after^{commit}" 2>/dev/null \
              && git -C "$chain_worktree" merge-base --is-ancestor "$result_commit_after" HEAD 2>/dev/null; then
              log "resume confirms completed issue #$issue already integrated"
              return 0
            fi
            abort_run "completed issue #$issue local clone missing before integration"
          fi
          ;;
      esac
    fi
    git -C "$chain_worktree" checkout "$branch"
    chain_git_integrate_issue_workspace "$REPO_ROOT" "$chain_worktree" "$branch" "$issue_worktree" "$issue_branch" "$git_metadata_strategy"
    emit_chain_event chain_issue_merged "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
      "$(jq -cn --arg chain "$chain_name" --arg branch "$branch" --arg issue_branch "$issue_branch" --arg commit_after "$result_commit_after" '{chain:$chain, branch:$branch, issue_branch:$issue_branch, commit_after:(if $commit_after == "" then null else $commit_after end)}')"
  else
    printf 'DRY-RUN git -C %q checkout %q\n' "$chain_worktree" "$branch"
    case "$git_metadata_strategy" in
      linked-worktree)
        printf 'DRY-RUN git -C %q rebase %q\n' "$issue_worktree" "$branch"
        printf 'DRY-RUN git -C %q merge --ff-only %q\n' "$chain_worktree" "$issue_branch"
        printf 'DRY-RUN git -C %q worktree remove %q\n' "$REPO_ROOT" "$issue_worktree"
        printf 'DRY-RUN git -C %q branch -D %q\n' "$REPO_ROOT" "$issue_branch"
        ;;
      local-clone)
        printf 'DRY-RUN git -C %q fetch %q %q\n' "$issue_worktree" "$chain_worktree" "$branch"
        printf 'DRY-RUN git -C %q rebase FETCH_HEAD\n' "$issue_worktree"
        printf 'DRY-RUN git -C %q fetch %q %q\n' "$chain_worktree" "$issue_worktree" "$issue_branch"
        printf 'DRY-RUN git -C %q merge --ff-only FETCH_HEAD\n' "$chain_worktree"
        printf 'DRY-RUN rm -rf %q\n' "$issue_worktree"
        ;;
    esac
  fi
}

for ((idx = 0; idx < chain_count; idx++)); do
  name=$(jq -r ".chains[$idx].name" "$PLAN_JSON")
  base=$(jq -r ".chains[$idx].base" "$PLAN_JSON")
  branch=$(jq -r ".chains[$idx].branch" "$PLAN_JSON")
  host=$(jq -r ".chains[$idx].host" "$PLAN_JSON")
  phase_review_mode=$(jq -r ".chains[$idx].phase_review // \"auto\"" "$PLAN_JSON")
  checkpoint_mode=$(jq -r ".chains[$idx].checkpoint // \"off\"" "$PLAN_JSON")
  git_metadata_strategy=$(jq -r ".chains[$idx].git_metadata_strategy // \"linked-worktree\"" "$PLAN_JSON")
  issue_count=$(jq -r ".chains[$idx].issues | length" "$PLAN_JSON")
  chain_run_id=$(jq -r ".chains[$idx].chain_run_id" "$PLAN_JSON")
  chain_status=$(jq -r ".chains[$idx].status // \"pending\"" "$RUN_STATE_JSON" 2>/dev/null || printf 'pending')
  chain_started_at=$(now_epoch)

  if [ "$chain_status" = "completed" ]; then
    log "resume skip completed chain $name"
    continue
  fi

  chain_slug=$(slugify "$name")
  chain_worktree=$(jq -r ".chains[$idx].chain_worktree" "$PLAN_JSON")
  chain_results_dir="$RUN_ROOT/$chain_slug-results-$chain_run_id"
  CHAIN_WORKER_POOL=$(jq -r ".chains[$idx].worker_pool" "$PLAN_JSON")

  log "starting chain $name on $branch from latest $base using host=$host git_metadata_strategy=$git_metadata_strategy checkpoint=$checkpoint_mode worker_pool=$CHAIN_WORKER_POOL"
  mark_chain_state "$chain_run_id" running
  emit_chain_event chain_started "" "$RUN_ID" "$chain_run_id" "" running 0 \
    "$(jq -cn --arg name "$name" --arg branch "$branch" --arg base "$base" --arg host "$host" --arg git_metadata_strategy "$git_metadata_strategy" --argjson issue_count "$issue_count" --argjson worker_pool "$CHAIN_WORKER_POOL" '{chain:$name, branch:$branch, base:$base, host:$host, git_metadata_strategy:$git_metadata_strategy, issue_count:$issue_count, worker_pool:$worker_pool}')"
  host_preflight "$host" "$REPO_ROOT" || abort_run "host preflight failed for $host"
  run with_login_home_for_github git -C "$REPO_ROOT" fetch origin --prune
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$chain_results_dir"
    if [ -n "$RESUME_ID" ] && git_checkout_exists "$chain_worktree"; then
      git -C "$chain_worktree" checkout "$branch"
    elif ! git_checkout_exists "$chain_worktree"; then
      git -C "$REPO_ROOT" worktree add -B "$branch" "$chain_worktree" "origin/$base"
      git -C "$chain_worktree" checkout "$branch"
      git -C "$chain_worktree" reset --hard "origin/$base"
    else
      git -C "$chain_worktree" checkout "$branch"
      git -C "$chain_worktree" reset --hard "origin/$base"
    fi
  else
    mkdir -p "$chain_results_dir"
    printf 'DRY-RUN git worktree add -B %q %q origin/%q\n' "$branch" "$chain_worktree" "$base"
    if [ "$checkpoint_mode" = "auto" ]; then
      printf 'DRY-RUN scripts/studio-checkpoint.sh resume --project generic-dev-studio --role manager --branch %q --latest\n' "$branch"
    fi
  fi

  load_auto_checkpoint_for_chain "$checkpoint_mode" "$chain_run_id" "$branch" "$chain_worktree"

  ISSUE_PIDS=()
  for ((i = 0; i < issue_count; i++)); do
    issue=$(jq -r ".chains[$idx].issues[$i].number" "$PLAN_JSON")
    issue_branch=$(jq -r ".chains[$idx].issues[$i].issue_branch" "$PLAN_JSON")
    issue_worktree=$(jq -r ".chains[$idx].issues[$i].issue_worktree" "$PLAN_JSON")
    issue_run_id=$(jq -r ".chains[$idx].issues[$i].issue_run_id" "$PLAN_JSON")
    issue_status=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .status // "pending"' "$RUN_STATE_JSON" 2>/dev/null || printf 'pending')
    result_file="$chain_results_dir/issue-$issue-$issue_run_id.json"

    if [ "$issue_status" = "completed" ]; then
      log "resume skip completed issue #$issue"
      issue_commit_after=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .commit_after // ""' "$RUN_STATE_JSON" 2>/dev/null || true)
      jq -n \
        --arg issue "$issue" \
        --arg branch "$issue_branch" \
        --arg worktree "$issue_worktree" \
        --arg commit_after "$issue_commit_after" \
        '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree, commit_after:(if $commit_after == "" then null else $commit_after end), resumed:true}' > "$result_file"
      integrate_issue_result "$name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id"
      if [ "$checkpoint_mode" = "auto" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
          create_auto_checkpoint_after_issue "$checkpoint_mode" "$name" "$branch" "$chain_worktree" "$chain_run_id" "$issue_run_id" "$issue" "$result_file"
        else
          printf 'DRY-RUN cd %q && scripts/studio-checkpoint.sh create --project generic-dev-studio --role manager --mode chain-auto --branch %q --checkpoint-id chain-%s-%s-%s --resume-command %q\n' \
            "$chain_worktree" "$branch" "$RUN_ID" "$chain_run_id" "$issue_run_id" "scripts/studio-chain-runner.sh --resume $RUN_ID --yes --checkpoint auto"
        fi
      fi
      continue
    fi

    run_issue_job "$name" "$branch" "$chain_worktree" "$issue" "$host" "$git_metadata_strategy" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$result_file" "$phase_review_mode" "$issue_count"
    result_status=$(jq -r '.status // "failed"' "$result_file")
    if [ "$result_status" != "completed" ]; then
      result_reason=$(jq -r '.reason // "issue failed"' "$result_file")
      abort_run "$result_reason"
    fi
    integrate_issue_result "$name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id"
    if [ "$checkpoint_mode" = "auto" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        create_auto_checkpoint_after_issue "$checkpoint_mode" "$name" "$branch" "$chain_worktree" "$chain_run_id" "$issue_run_id" "$issue" "$result_file"
      else
        printf 'DRY-RUN cd %q && scripts/studio-checkpoint.sh create --project generic-dev-studio --role manager --mode chain-auto --branch %q --checkpoint-id chain-%s-%s-%s --resume-command %q\n' \
          "$chain_worktree" "$branch" "$RUN_ID" "$chain_run_id" "$issue_run_id" "scripts/studio-chain-runner.sh --resume $RUN_ID --yes --checkpoint auto"
      fi
    fi
  done

  finalize_chain_pr "$name" "$branch" "$chain_worktree" "$base" "$chain_run_id" "$host"
  chain_duration=$(duration_since "$chain_started_at")
  mark_chain_state "$chain_run_id" completed "$FINAL_PR_URL"
  emit_chain_event chain_completed "" "$RUN_ID" "$chain_run_id" "" completed "$chain_duration" \
    "$(jq -cn --arg name "$name" --arg pr_url "$FINAL_PR_URL" '{chain:$name, pr_url:(if $pr_url == "" then null else $pr_url end)}')"

  for ((i = 0; i < issue_count; i++)); do
    issue=$(jq -r ".chains[$idx].issues[$i].number" "$PLAN_JSON")
    if [ "$DRY_RUN" -eq 0 ]; then
      issue_comment="Chain issue integrated.

Chain run: $RUN_ID"
      [ -n "$FINAL_PR_URL" ] && issue_comment="$issue_comment

PR: $FINAL_PR_URL"
      with_login_home_for_github gh issue close "$issue" --repo "$REPO_SLUG" --comment "$issue_comment" \
        || with_login_home_for_github gh issue comment "$issue" --repo "$REPO_SLUG" --body "$issue_comment"
      emit_chain_event chain_issue_closed "$issue" "$RUN_ID" "$chain_run_id" "" completed 0 \
        "$(jq -cn --arg pr_url "$FINAL_PR_URL" --arg issue_number "$issue" '{pr_url:(if $pr_url == "" then null else $pr_url end), issue_number:($issue_number|tonumber)}')"
    else
      printf 'DRY-RUN gh issue close %q --repo %q --comment %q\n' "$issue" "$REPO_SLUG" "Merged through chain PR: ${FINAL_PR_URL:-<pr-url>}"
    fi
  done

  if [ "$DRY_RUN" -eq 0 ]; then
    with_login_home_for_github git -C "$REPO_ROOT" fetch origin --prune
    git -C "$REPO_ROOT" worktree remove "$chain_worktree" || true
    git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
  else
    printf 'DRY-RUN git -C %q fetch origin --prune\n' "$REPO_ROOT"
    printf 'DRY-RUN git -C %q worktree remove %q\n' "$REPO_ROOT" "$chain_worktree"
    printf 'DRY-RUN git -C %q branch -D %q\n' "$REPO_ROOT" "$branch"
  fi
done

finish_run completed ""
log "all requested chains processed"
