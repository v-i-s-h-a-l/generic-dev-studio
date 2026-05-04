#!/usr/bin/env bash
# Run a deterministic Studio v2 worker + qa-engineer multi-spawn pilot.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUDGETS="$REPO_ROOT/core/v2/pilots/multispawn-budgets.yaml"
TOPOLOGY="$SCRIPT_DIR/v2-topology-event.sh"

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

RUNTIME_ROOT=""
PILOT_ID=""
SUBTASK_ID=""
TASK_CLASS=""
WORKER_DURATION_S=""
QA_DURATION_S=""
WORKER_EXIT=0
QA_EXIT=0
LAUNCH_DELAY_S=0
FORMAT="json"
OUTPUT=""

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/v2-multispawn-pilot.sh run --runtime-root <dir> --pilot-id <id> --subtask-id <id> --task-class <xs|s|m> --worker-duration-s <n> --qa-duration-s <n> [--worker-exit <n>] [--qa-exit <n>] [--launch-delay-s <n>] [--output <file>] [--format json|markdown]
USAGE
}

require_tools() {
  command -v jq >/dev/null 2>&1 || { printf 'v2-multispawn-pilot: jq is required\n' >&2; exit 3; }
  command -v yq >/dev/null 2>&1 || { printf 'v2-multispawn-pilot: yq is required\n' >&2; exit 3; }
  [ -x "$TOPOLOGY" ] || { printf 'v2-multispawn-pilot: v2-topology-event.sh is required\n' >&2; exit 3; }
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_epoch_s() {
  date -u +%s
}

parse_run_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires dir}"; shift 2 ;;
      --pilot-id=*) PILOT_ID="${1#--pilot-id=}"; shift ;;
      --pilot-id) PILOT_ID="${2:?--pilot-id requires value}"; shift 2 ;;
      --subtask-id=*) SUBTASK_ID="${1#--subtask-id=}"; shift ;;
      --subtask-id) SUBTASK_ID="${2:?--subtask-id requires value}"; shift 2 ;;
      --task-class=*) TASK_CLASS="${1#--task-class=}"; shift ;;
      --task-class) TASK_CLASS="${2:?--task-class requires value}"; shift 2 ;;
      --worker-duration-s=*) WORKER_DURATION_S="${1#--worker-duration-s=}"; shift ;;
      --worker-duration-s) WORKER_DURATION_S="${2:?--worker-duration-s requires value}"; shift 2 ;;
      --qa-duration-s=*) QA_DURATION_S="${1#--qa-duration-s=}"; shift ;;
      --qa-duration-s) QA_DURATION_S="${2:?--qa-duration-s requires value}"; shift 2 ;;
      --worker-exit=*) WORKER_EXIT="${1#--worker-exit=}"; shift ;;
      --worker-exit) WORKER_EXIT="${2:?--worker-exit requires value}"; shift 2 ;;
      --qa-exit=*) QA_EXIT="${1#--qa-exit=}"; shift ;;
      --qa-exit) QA_EXIT="${2:?--qa-exit requires value}"; shift 2 ;;
      --launch-delay-s=*) LAUNCH_DELAY_S="${1#--launch-delay-s=}"; shift ;;
      --launch-delay-s) LAUNCH_DELAY_S="${2:?--launch-delay-s requires value}"; shift 2 ;;
      --format=*) FORMAT="${1#--format=}"; shift ;;
      --format) FORMAT="${2:?--format requires value}"; shift 2 ;;
      --output=*) OUTPUT="${1#--output=}"; shift ;;
      --output) OUTPUT="${2:?--output requires path}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'v2-multispawn-pilot: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
}

require_number() {
  case "$2" in
    ""|*[!0-9]*)
      printf 'v2-multispawn-pilot: %s must be a non-negative integer\n' "$1" >&2
      exit 2
      ;;
  esac
}

task_budget_s() {
  TASK_CLASS="$TASK_CLASS" yq -r '.task_classes[] | select(.task_class == strenv(TASK_CLASS)) | .coordination_budget_s' "$BUDGETS"
}

lane_run() {
  local role="$1" duration="$2" exit_code="$3" out="$4"
  local start_epoch start_iso end_epoch end_iso
  start_epoch=$(now_epoch_s)
  start_iso=$(now_iso)
  sleep "$duration"
  end_epoch=$(now_epoch_s)
  end_iso=$(now_iso)
  jq -n \
    --arg role "$role" \
    --arg started_at "$start_iso" \
    --arg ended_at "$end_iso" \
    --argjson start_epoch_s "$start_epoch" \
    --argjson end_epoch_s "$end_epoch" \
    --argjson duration_s "$duration" \
    --argjson exit_code "$exit_code" \
    '{
      role: $role,
      started_at: $started_at,
      ended_at: $ended_at,
      start_epoch_s: $start_epoch_s,
      end_epoch_s: $end_epoch_s,
      requested_duration_s: $duration_s,
      exit_code: $exit_code,
      terminal_state: (if $exit_code == 0 then "completed" else "failed" end)
    }' > "$out"
  return "$exit_code"
}

render_markdown() {
  jq -r '
    "# Studio v2 Multi-Spawn Pilot",
    "",
    "- Pilot: `\(.pilot_id)`",
    "- Subtask: `\(.subtask_id)`",
    "- Task class: `\(.task_class)`",
    "- Terminal state: `\(.terminal_state)`",
    "- Budget: \(.coordination_budget_s)s",
    "- Coordination overhead: \(.coordination_overhead_s)s",
    "- Budget result: `\(.budget_result)`",
    "- QA stable contract: `\(.qa_started_from_stable_contract)`",
    "- Lane overlap: \(.overlap_s)s",
    "",
    "## Lanes",
    "",
    (.lanes[] | "- `\(.role)`: \(.started_at) -> \(.ended_at), exit \(.exit_code), state `\(.terminal_state)`"),
    "",
    "## Artifacts",
    "",
    "- Contract: `\(.contract_ref)`",
    "- JSON report: `\(.json_report_ref)`",
    "- Markdown report: `\(.markdown_report_ref)`"
  '
}

write_output() {
  if [ -n "$OUTPUT" ]; then
    cat > "$OUTPUT"
  else
    cat
  fi
}

emit_topology_if_needed() {
  local report="$1" terminal subject evidence_ref budget completed_count
  terminal=$(jq -r '.terminal_state' "$report")
  subject=$(jq -r '.subject_ref' "$report")
  evidence_ref=$(jq -r '.markdown_report_ref' "$report")
  case "$terminal" in
    completed)
      return 0
      ;;
    budget_missed)
      "$TOPOLOGY" emit --runtime-root "$RUNTIME_ROOT" --quiet \
        --failure-mode budget_exhaustion \
        --subject "$subject" \
        --producer-role qa-engineer \
        --data-json "$(jq -c '{
          status: "blocked",
          evidence_ref: .markdown_report_ref,
          budget_kind: "coordination_overhead_s",
          budget_limit: .coordination_budget_s,
          observed_value: .coordination_overhead_s
        }' "$report")"
      ;;
    partial|failed)
      completed_count=$(jq '[.lanes[] | select(.exit_code == 0)] | length' "$report")
      "$TOPOLOGY" emit --runtime-root "$RUNTIME_ROOT" --quiet \
        --failure-mode partial_multi_spawn \
        --subject "$subject" \
        --producer-role qa-engineer \
        --data-json "$(jq -c --argjson completed_count "$completed_count" '{
          status: (if .terminal_state == "failed" then "blocked" else "partial" end),
          evidence_ref: .markdown_report_ref,
          completed_count: $completed_count,
          expected_count: 2
        }' "$report")"
      ;;
  esac
}

cmd_run() {
  parse_run_args "$@"
  require_tools
  [ -n "$RUNTIME_ROOT" ] || { usage; exit 2; }
  [ -n "$PILOT_ID" ] || { usage; exit 2; }
  [ -n "$SUBTASK_ID" ] || { usage; exit 2; }
  [ -n "$TASK_CLASS" ] || { usage; exit 2; }
  [ -n "$WORKER_DURATION_S" ] || { usage; exit 2; }
  [ -n "$QA_DURATION_S" ] || { usage; exit 2; }
  require_number --worker-duration-s "$WORKER_DURATION_S"
  require_number --qa-duration-s "$QA_DURATION_S"
  require_number --worker-exit "$WORKER_EXIT"
  require_number --qa-exit "$QA_EXIT"
  require_number --launch-delay-s "$LAUNCH_DELAY_S"
  case "$FORMAT" in json|markdown) ;; *) usage; exit 2 ;; esac

  local budget
  budget=$(task_budget_s)
  case "$budget" in ""|null) printf 'v2-multispawn-pilot: unknown task class: %s\n' "$TASK_CLASS" >&2; exit 2 ;; esac

  local dir contract worker_json qa_json report_json report_md contract_epoch contract_iso
  dir="$RUNTIME_ROOT/analysis/multispawn-pilots/$PILOT_ID"
  mkdir -p "$dir" || exit 1
  contract="$dir/task-contract.json"
  worker_json="$dir/worker.json"
  qa_json="$dir/qa-engineer.json"
  report_json="$dir/report.json"
  report_md="$dir/report.md"

  contract_epoch=$(now_epoch_s)
  contract_iso=$(now_iso)
  jq -n \
    --arg pilot_id "$PILOT_ID" \
    --arg subtask_id "$SUBTASK_ID" \
    --arg task_class "$TASK_CLASS" \
    --arg stable_at "$contract_iso" \
    --argjson stable_epoch_s "$contract_epoch" \
    '{
      pilot_id: $pilot_id,
      subtask_id: $subtask_id,
      task_class: $task_class,
      stable_at: $stable_at,
      stable_epoch_s: $stable_epoch_s,
      stable: true,
      worker_role: "worker",
      qa_role: "qa-engineer"
    }' > "$contract"

  sleep "$LAUNCH_DELAY_S"

  lane_run worker "$WORKER_DURATION_S" "$WORKER_EXIT" "$worker_json" &
  local worker_pid=$!
  lane_run qa-engineer "$QA_DURATION_S" "$QA_EXIT" "$qa_json" &
  local qa_pid=$!

  local worker_rc qa_rc
  wait "$worker_pid"; worker_rc=$?
  wait "$qa_pid"; qa_rc=$?

  local worker_start qa_start worker_end qa_end overhead overlap completed_count terminal budget_result
  worker_start=$(jq -r '.start_epoch_s' "$worker_json")
  qa_start=$(jq -r '.start_epoch_s' "$qa_json")
  worker_end=$(jq -r '.end_epoch_s' "$worker_json")
  qa_end=$(jq -r '.end_epoch_s' "$qa_json")
  if [ "$worker_start" -gt "$qa_start" ]; then overhead=$((worker_start - contract_epoch)); else overhead=$((qa_start - contract_epoch)); fi
  local latest_start earliest_end
  if [ "$worker_start" -gt "$qa_start" ]; then latest_start="$worker_start"; else latest_start="$qa_start"; fi
  if [ "$worker_end" -lt "$qa_end" ]; then earliest_end="$worker_end"; else earliest_end="$qa_end"; fi
  overlap=$((earliest_end - latest_start))
  [ "$overlap" -ge 0 ] || overlap=0
  completed_count=0
  [ "$worker_rc" -eq 0 ] && completed_count=$((completed_count + 1))
  [ "$qa_rc" -eq 0 ] && completed_count=$((completed_count + 1))
  if [ "$completed_count" -eq 2 ]; then
    if [ "$overhead" -gt "$budget" ]; then terminal="budget_missed"; budget_result="missed"; else terminal="completed"; budget_result="met"; fi
  elif [ "$completed_count" -eq 1 ]; then
    terminal="partial"; budget_result="not_measurable"
  else
    terminal="failed"; budget_result="not_measurable"
  fi

  local qa_stable_contract
  if [ "$qa_start" -ge "$contract_epoch" ]; then qa_stable_contract=true; else qa_stable_contract=false; fi

  jq -n \
    --slurpfile worker "$worker_json" \
    --slurpfile qa "$qa_json" \
    --arg pilot_id "$PILOT_ID" \
    --arg subject_ref "#548/C7/$PILOT_ID" \
    --arg subtask_id "$SUBTASK_ID" \
    --arg task_class "$TASK_CLASS" \
    --arg contract_ref "$contract" \
    --arg json_report_ref "$report_json" \
    --arg markdown_report_ref "$report_md" \
    --arg terminal_state "$terminal" \
    --arg budget_result "$budget_result" \
    --argjson coordination_budget_s "$budget" \
    --argjson coordination_overhead_s "$overhead" \
    --argjson overlap_s "$overlap" \
    --argjson completed_count "$completed_count" \
    --argjson contract_stable_epoch_s "$contract_epoch" \
    --argjson qa_started_from_stable_contract "$qa_stable_contract" \
    '{
      schema_version: {"name": "multispawn-pilot-report", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
      pilot_id: $pilot_id,
      subject_ref: $subject_ref,
      subtask_id: $subtask_id,
      task_class: $task_class,
      expected_count: 2,
      completed_count: $completed_count,
      contract_ref: $contract_ref,
      json_report_ref: $json_report_ref,
      markdown_report_ref: $markdown_report_ref,
      contract_stable_epoch_s: $contract_stable_epoch_s,
      qa_started_from_stable_contract: $qa_started_from_stable_contract,
      coordination_budget_s: $coordination_budget_s,
      coordination_overhead_s: $coordination_overhead_s,
      budget_kind: "coordination_overhead_s",
      budget_result: $budget_result,
      overlap_s: $overlap_s,
      terminal_state: $terminal_state,
      lanes: [$worker[0], $qa[0]]
    }' > "$report_json"
  render_markdown < "$report_json" > "$report_md"

  emit_topology_if_needed "$report_json"

  if [ "$FORMAT" = "json" ]; then
    cat "$report_json" | write_output
  else
    cat "$report_md" | write_output
  fi
}

case "$COMMAND" in
  run) cmd_run "$@" ;;
  -h|--help|"") usage; [ -n "$COMMAND" ] && exit 0 || exit 2 ;;
  *) printf 'v2-multispawn-pilot: unknown command: %s\n' "$COMMAND" >&2; usage; exit 2 ;;
esac
