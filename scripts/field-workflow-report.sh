#!/usr/bin/env bash
# field-workflow-report.sh — summarize Field workflow telemetry from event logs.
#
# Usage:
#   scripts/field-workflow-report.sh --project <slug> --days 14
#   scripts/field-workflow-report.sh --project <slug> --since YYYY-MM-DD --by stage|agent|node|task-size
#
# Reads canonical events via scripts/read-events.sh plus best-effort brief YAML
# metadata resolved through scripts/lib-paths.sh. Missing spans and missing
# token fields are counted as telemetry gaps, never as zero.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

DAYS=14
PROJECT=""
SINCE=""
UNTIL=""
BY="stage"

usage() {
  sed -n '2,/^# Reads/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --days=*) DAYS="${1#--days=}"; shift ;;
    --days) DAYS="${2:?--days requires N}"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --project) PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    --since) SINCE="${2:?--since requires YYYY-MM-DD}"; shift 2 ;;
    --until=*) UNTIL="${1#--until=}"; shift ;;
    --until) UNTIL="${2:?--until requires YYYY-MM-DD}"; shift 2 ;;
    --by=*) BY="${1#--by=}"; shift ;;
    --by) BY="${2:?--by requires stage|agent|node|task-size}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'field-workflow-report: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) printf 'field-workflow-report: --days must be a positive integer\n' >&2; exit 2 ;;
  0) printf 'field-workflow-report: --days must be > 0\n' >&2; exit 2 ;;
esac
case "$BY" in
  stage|agent|node|task-size) ;;
  *) printf 'field-workflow-report: --by must be stage, agent, node, or task-size\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'field-workflow-report: jq required\n' >&2; exit 2; }

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'field-workflow-report: no project resolved. Pass --project <slug> or run inside a git repo.\n' >&2
    exit 2
  }
fi

if [ -z "$SINCE" ]; then
  now_epoch=$(date -u +%s)
  since_epoch=$((now_epoch - (DAYS - 1) * 86400))
  SINCE=$(date -u -r "$since_epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$since_epoch" +%Y-%m-%d)
fi

project_root=$(resolve_project_root_for "$PROJECT") || {
  printf 'field-workflow-report: could not resolve project root for %s\n' "$PROJECT" >&2
  exit 2
}

events_file=$(mktemp -t field-workflow-events.XXXXXX)
norm_file=$(mktemp -t field-workflow-norm.XXXXXX)
brief_file=$(mktemp -t field-workflow-briefs.XXXXXX)
trap 'rm -f "$events_file" "$norm_file" "$brief_file"' EXIT

read_args=(--project "$PROJECT" --since "$SINCE")
[ -n "$UNTIL" ] && read_args+=(--until "$UNTIL")
"$SCRIPT_DIR/read-events.sh" "${read_args[@]}" > "$events_file" || {
  printf 'field-workflow-report: failed to read events for project %s\n' "$PROJECT" >&2
  exit 1
}

event_count=$(wc -l < "$events_file" | tr -d ' ')
if [ "$event_count" -eq 0 ]; then
  printf 'Field workflow report for %s (%s%s)\n(no events in window)\n' \
    "$PROJECT" "$SINCE" "${UNTIL:+..$UNTIL}"
  exit 0
fi

brief_dir="$project_root/plans/briefs"
brief_gap=""
if [ -d "$brief_dir" ]; then
  if command -v yq >/dev/null 2>&1; then
    find "$brief_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
      | sort \
      | while IFS= read -r f; do
          yq -r '
            [
              (.task_id // ""),
              (.legacy_task_id // ""),
              (.id // ""),
              (.size // ""),
              (.type // ""),
              (if (.summary // "") == "" then "0" else "1" end),
              ((.acceptance // []) | length),
              (.recommended_models.best_result.model_id // .recommended_models.fast_turnaround.model_id // "")
            ] | @tsv
          ' "$f" 2>/dev/null || true
        done > "$brief_file"
  else
    # Fallback parser for the top-level fields this report needs. It is not a
    # general YAML parser, but it keeps the report useful on minimal hosts.
    find "$brief_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
      | sort \
      | while IFS= read -r f; do
          awk '
            BEGIN { task=""; legacy=""; id=""; size=""; type=""; summary=0; acc=0; in_acc=0; rec="" }
            /^[[:space:]]*task_id:/ { task=$0; sub(/^[^:]*:[[:space:]]*/, "", task); gsub(/^"|"$/, "", task) }
            /^[[:space:]]*legacy_task_id:/ { legacy=$0; sub(/^[^:]*:[[:space:]]*/, "", legacy); gsub(/^"|"$/, "", legacy) }
            /^[[:space:]]*id:/ && id == "" { id=$0; sub(/^[^:]*:[[:space:]]*/, "", id); gsub(/^"|"$/, "", id) }
            /^[[:space:]]*size:/ { size=$0; sub(/^[^:]*:[[:space:]]*/, "", size); gsub(/^"|"$/, "", size) }
            /^[[:space:]]*type:/ { type=$0; sub(/^[^:]*:[[:space:]]*/, "", type); gsub(/^"|"$/, "", type) }
            /^[[:space:]]*summary:[[:space:]]*[^|>[:space:]]/ { if ($0 !~ /:[[:space:]]*(null)?[[:space:]]*$/) summary=1 }
            /^[[:space:]]*summary:[[:space:]]*[|>]/ { summary=1 }
            /^[[:space:]]*acceptance:/ { in_acc=1; next }
            /^[^[:space:]-][^:]*:/ { in_acc=0 }
            in_acc && /^[[:space:]]*-/ { acc++ }
            /^[[:space:]]*model_id:/ && rec == "" { rec=$0; sub(/^[^:]*:[[:space:]]*/, "", rec); gsub(/^"|"$/, "", rec) }
            END { if (task != "" || legacy != "") print task "\t" legacy "\t" id "\t" size "\t" type "\t" summary "\t" acc "\t" rec }
          ' "$f"
        done > "$brief_file"
    brief_gap="brief_yaml_best_effort_parser"
  fi
else
  : > "$brief_file"
  brief_gap="brief_artifacts_missing"
fi

jq -r '
  def epoch: try (.ts | fromdateiso8601 | floor) catch "";
  def task_id: (.task // .data.task // .data.task_id // .data.legacy_task_id // "");
  def host:
    (.data.host // .data.review_host // ."gen_ai.system" // .data."studio.host" // "");
  def model:
    (.data.model_selected // .data.model // .data.model_id // ."gen_ai.request.model" // "");
  [
    epoch,
    (.ts // ""),
    (.event // ""),
    task_id,
    (.agent // .producer.agent // ""),
    (.data.mode // .mode // ""),
    (.data.stage // .data.phase // ""),
    (.data.duration_s // ""),
    (.data.wait_duration_s // .data.waited_s // ""),
    (.data.attempt // 1),
    (.data.mode // .data.gate // ""),
    (.data.node // .data."studio.dispatch.node" // ""),
    (.data."studio.dispatch.reason" // .data.dispatch_reason // ""),
    (.data.reason // .data.block_reason // ""),
    (.data.status // .data.verdict // ""),
    (.data.size // ""),
    (.data.type // ""),
    host,
    model,
    (.data.model_recommended // .data.recommended_model // ""),
    (.data.model_fallback_reason // ""),
    (.data.tokens.input // .data.input_tokens // ""),
    (.data.tokens.output // .data.output_tokens // ""),
    (.data.tokens.cache_read // .data.cache_read_tokens // .data.cached_input_tokens // ""),
    (.data.tokens.cache_write // .data.cache_write_tokens // ""),
    (.data.position // ""),
    (.data.depth // ""),
    (.data.warning_count // .data.warnings // ""),
    (.data.error_count // .data.errors // ""),
    (.data.finding_count // ""),
    (.data.from // ""),
    (.data.to // ""),
    (.data.brief_uuid // ""),
    (.data.task_id // "")
  ] | @tsv
' "$events_file" > "$norm_file"

printf 'Field workflow report for %s (%s%s)\n' "$PROJECT" "$SINCE" "${UNTIL:+..$UNTIL}"
printf 'Events read: %s\n' "$event_count"
printf 'Group hint: %s\n\n' "$BY"

awk -F'\t' -v brief_gap="$brief_gap" '
function valid_duration(v) { return (v ~ /^[0-9]+$/ && v >= 0 && v <= 86400) }
function valid_num(v) { return (v ~ /^[0-9]+$/ && v >= 0) }
function key_task(task, fallback) { return task != "" ? task : fallback }
function norm_size(v) { return v == "" ? "unknown" : tolower(v) }
function task_size(task) { return (task != "" && size_by_task[task] != "") ? size_by_task[task] : "unknown" }
function task_acceptance(task) { return (task != "" && acc_by_task[task] != "") ? acc_by_task[task] : "" }
function task_summary(task) { return (task != "" && summary_by_task[task] != "") ? summary_by_task[task] : "" }
function remember_stage(stage) {
  if (!(stage in stage_seen)) {
    stage_seen[stage] = 1
    stage_order[++stage_n] = stage
  }
}
function gap(stage, reason, impact) {
  remember_stage(stage)
  gap_count[stage]++
  gap_reason[stage, reason]++
  gap_impact[stage] += (impact == "" ? 1 : impact)
}
function sample_stage(stage, task, start, end, dur, source,    n) {
  remember_stage(stage)
  if (dur == "" && start != "" && end != "") dur = end - start
  if (!valid_duration(dur)) {
    gap(stage, "missing_or_invalid_duration", 1)
    return
  }
  n = ++stage_count[stage]
  stage_values[stage, n] = dur + 0
  stage_total[stage] += dur
  if (task != "") stage_task_seen[stage, task] = 1
}
function close_span(stage, key, end, task) {
  if (span_start[stage, key] == "") {
    gap(stage, "missing_start", 1)
    return
  }
  sample_stage(stage, task, span_start[stage, key], end, "", "paired")
  span_start[stage, key] = ""
}
function percentile(prefix, values, counts, pct,    n, i, j, idx, tmp) {
  n = counts[prefix]
  if (n < 1) return "n/a"
  for (i = 1; i <= n; i++) sorted[i] = values[prefix, i]
  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (sorted[i] > sorted[j]) {
        tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp
      }
    }
  }
  idx = int(n * pct + 0.999)
  if (idx < 1) idx = 1
  if (idx > n) idx = n
  return sorted[idx]
}
function stage_percentile(stage, pct) {
  return percentile(stage, stage_values, stage_count, pct)
}
function token_percentile(group, pct) {
  return percentile(group, token_values, token_count, pct)
}
function gate_kind(event, mode) {
  if (event ~ /^test_run_/) return "xcodebuild-test"
  if (mode != "") return mode
  return "unknown"
}
function node_kind(node, mode) {
  if (node != "") return node
  if (mode == "lsp-only") return "local-lsp"
  return "unknown"
}
function failure_class(event, reason) {
  if (reason ~ /source_sync/) return "source_sync"
  if (reason ~ /remote_shell|PATH/) return "remote_shell_path"
  if (reason ~ /build_invocation|success_marker_absent/) return "build_invocation"
  if (reason ~ /marker|harness/) return "marker_harness_failure"
  if (reason ~ /locked_out|lock/) return "lock_wait"
  if (reason ~ /timeout/) return "timeout"
  if (reason ~ /xcode.*drift/) return "xcode_drift"
  if (event == "test_run_failed") return "test_failure"
  if (event == "build_check_aborted") return "marker_harness_failure"
  if (event == "build_check_failed") return "build_invocation"
  return reason != "" ? reason : "unknown"
}
function add_gate(event, mode, node, attempt, reason, warnings, errors,    gkey, cls) {
  mode = gate_kind(event, mode)
  node = node_kind(node, mode)
  if (!valid_num(attempt)) attempt = 1
  gkey = mode "\t" node
  if (!(gkey in gate_seen)) gate_order[++gate_n] = gkey
  gate_seen[gkey] = 1
  gate_total[gkey]++
  gate_attempts[gkey] += attempt
  if (attempt == 1) gate_first_total[gkey]++
  else gate_retry_total[gkey]++
  if (event ~ /_passed$/) {
    gate_pass[gkey]++
    if (attempt == 1) gate_first_pass[gkey]++
    else gate_retry_pass[gkey]++
  } else {
    gate_fail[gkey]++
    cls = failure_class(event, reason)
    gate_fail_class[gkey, cls]++
    if (!(cls in class_seen)) class_order[++class_n] = cls
  }
  if (valid_num(warnings)) gate_warnings[gkey] += warnings
  if (valid_num(errors)) gate_errors[gkey] += errors
}
function add_review(event, stage, status, reason, duration, task) {
  if (stage == "") stage = "unknown"
  if (!(stage in review_seen)) review_order[++review_n] = stage
  review_seen[stage] = 1
  if (event == "review_requested") review_requested[stage]++
  else if (event == "review_approved") review_approved[stage]++
  else if (event == "review_flagged") review_flagged[stage]++
  else if (event == "review_blocked") review_blocked[stage]++
  else if (event == "argus_gate_skipped") { review_skipped[stage]++; review_skip_reason[stage, reason]++ }
  else if (event == "argus_preflight_failed") { review_infra_failed[stage]++; review_skip_reason[stage, reason]++ }
  if (valid_duration(duration)) sample_stage("argus_review:" stage, task, "", "", duration, "duration_s")
}
function add_tokens(agent, mode, host, model, task, size, recommended, fallback, tin, tout, tc, tcw,    group,total,n) {
  if (mode == "") mode = "unknown"
  if (host == "") host = "unknown"
  if (model == "") model = "unknown"
  size = norm_size(size != "" ? size : task_size(task))
  group = agent "\t" mode "\t" model "\t" host "\t" size
  if (!(group in token_seen)) token_order[++token_n] = group
  token_seen[group] = 1
  token_sessions[group]++
  if (!valid_num(tin) && !valid_num(tout) && !valid_num(tc) && !valid_num(tcw)) {
    token_missing[group]++
    gap("token_usage", "missing_token_fields", 1)
    return
  }
  tin = valid_num(tin) ? tin : 0
  tout = valid_num(tout) ? tout : 0
  tc = valid_num(tc) ? tc : 0
  tcw = valid_num(tcw) ? tcw : 0
  total = tin + tout
  n = ++token_count[group]
  token_values[group, n] = total
  token_input[group] += tin
  token_output[group] += tout
  token_cache_read[group] += tc
  token_cache_write[group] += tcw
  if (recommended != "" && model != "unknown" && recommended != model) model_mismatch[group]++
  if (fallback != "") model_fallback[group, fallback]++
}
function pct(n, d) {
  if (d < 1) return "n/a"
  return sprintf("%.1f%%", (100.0 * n) / d)
}
function sorted_stage_report(    i,j,tmp,stage) {
  for (i = 1; i <= stage_n; i++) {
    stage = stage_order[i]
    stage_rank[i] = sprintf("%012d", stage_total[stage]) "\t" stage
  }
  for (i = 1; i <= stage_n; i++) for (j = i + 1; j <= stage_n; j++) {
    split(stage_rank[i], a, "\t"); split(stage_rank[j], b, "\t")
    if (a[1] + 0 < b[1] + 0) { tmp = stage_rank[i]; stage_rank[i] = stage_rank[j]; stage_rank[j] = tmp }
  }
  print "Stage timing (ranked by total measured time)"
  printf "%-38s %7s %10s %10s %10s %10s\n", "Stage", "samples", "total_s", "p50_s", "p90_s", "gaps"
  for (i = 1; i <= stage_n; i++) {
    split(stage_rank[i], a, "\t"); stage = a[2]
    if (stage_count[stage] + gap_count[stage] < 1) continue
    printf "%-38s %7d %10d %10s %10s %10d\n", stage, stage_count[stage] + 0, stage_total[stage] + 0, stage_percentile(stage, 0.50), stage_percentile(stage, 0.90), gap_count[stage] + 0
  }
}
BEGIN {
  while ((getline line < ARGV[1]) > 0) {
    split(line, b, "\t")
    task=b[1]; legacy=b[2]; brief=b[3]; size=tolower(b[4]); type=b[5]; summary=b[6]; acc=b[7]; rec=b[8]
    if (task != "") {
      if (size != "") size_by_task[task]=size
      type_by_task[task]=type
      summary_by_task[task]=summary
      acc_by_task[task]=acc
      recommended_by_task[task]=rec
    }
    if (legacy != "") {
      if (size != "") size_by_task[legacy]=size
      type_by_task[legacy]=type
      summary_by_task[legacy]=summary
      acc_by_task[legacy]=acc
      recommended_by_task[legacy]=rec
    }
    if (brief != "") {
      if (size != "") size_by_task[brief]=size
      type_by_task[brief]=type
      summary_by_task[brief]=summary
      acc_by_task[brief]=acc
      recommended_by_task[brief]=rec
    }
  }
  close(ARGV[1])
  ARGV[1] = ""
  if (brief_gap != "") gap("brief_artifact_join", brief_gap, 2)
}
{
  epoch=$1; event=$3; task=$4; agent=$5; mode=$6; stage=$7; duration=$8; wait_duration=$9; attempt=$10; gate_mode=$11; node=$12; dispatch_reason=$13; reason=$14; status=$15; ev_size=tolower($16); ev_type=$17; host=$18; model=$19; recommended=$20; fallback=$21; tin=$22; tout=$23; tc=$24; tcw=$25; position=$26; depth=$27; warnings=$28; errors=$29; findings=$30; from_state=$31; to_state=$32; brief_uuid=$33; data_task_id=$34
  if (epoch == "" || event == "") next
  fallback_key = "event:" NR
  ktask = key_task(task, fallback_key)
  if (task != "" && ev_size != "") size_by_task[task] = ev_size
  if (data_task_id != "" && ev_size != "") size_by_task[data_task_id] = ev_size
  if (brief_uuid != "" && ev_size != "") size_by_task[brief_uuid] = ev_size
  if (recommended == "" && task != "") recommended = recommended_by_task[task]

  if (event == "task_created" || event == "feedback_ingested") {
    creation_start[ktask] = epoch
    if (task != "") overall_start[task] = epoch
  }
  if (event == "brief_started") {
    span_start["brief_authoring", ktask] = epoch
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
  }
  if (event == "brief_review_started") span_start["brief_review", ktask] = epoch
  if (event == "brief_review_flagged" || event == "brief_review_completed") {
    if (duration != "" && valid_duration(duration)) sample_stage("brief_review", task, "", "", duration, "duration_s")
    else close_span("brief_review", ktask, epoch, task)
  }
  if (event == "brief_state_changed" && to_state == "ready") {
    ready_at[ktask] = epoch
    if (creation_start[ktask] != "") sample_stage("intake_to_brief_ready", task, creation_start[ktask], epoch, "", "paired")
  }
  if (event == "brief_dispatched") {
    if (duration != "" && valid_duration(duration)) sample_stage("brief_authoring", task, "", "", duration, "duration_s")
    else if (span_start["brief_authoring", ktask] != "") close_span("brief_authoring", ktask, epoch, task)
    else gap("brief_authoring", "missing_start", 1)
    if (ready_at[ktask] != "") sample_stage("briefed_to_dispatched", task, ready_at[ktask], epoch, "", "paired")
    else gap("briefed_to_dispatched", "missing_ready_event", 1)
    dispatch_start[ktask] = epoch
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
  }
  if (event == "task_dispatched" || event == "dispatch_routed") {
    dispatch_start[ktask] = epoch
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
  }
  if (event == "task_started") {
    if (dispatch_start[ktask] != "") sample_stage("dispatch_queue_wait", task, dispatch_start[ktask], epoch, "", "paired")
    else gap("dispatch_queue_wait", "missing_dispatch", 1)
    impl_start[ktask] = epoch
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
  }
  if (event == "self_review_started") span_start["self_review_loop", ktask] = epoch
  if (event == "self_review_iterated") {
    self_review_iterations[task]++
    if (valid_duration(duration)) sample_stage("self_review_loop", task, "", "", duration, "duration_s")
  }
  if (event == "self_review_completed") {
    if (valid_duration(duration)) sample_stage("self_review_loop", task, "", "", duration, "duration_s")
    else close_span("self_review_loop", ktask, epoch, task)
  }
  if (event == "build_queue_position") {
    if (valid_num(position) && position > 1) build_queue_waiters++
    build_queue_events++
  }
  if (event == "build_check_started") {
    if (impl_start[ktask] != "") {
      sample_stage("implementation_until_first_gate", task, impl_start[ktask], epoch, "", "paired")
      impl_start[ktask] = ""
    }
    span_start["build_gate:" gate_kind(event, gate_mode), ktask ":" attempt] = epoch
  }
  if (event == "test_run_started") {
    span_start["test_gate:xcodebuild-test", ktask ":" attempt] = epoch
  }
  if (event == "build_check_passed" || event == "build_check_failed" || event == "build_check_aborted") {
    st = "build_gate:" gate_kind(event, gate_mode)
    if (valid_duration(duration)) sample_stage(st, task, "", "", duration, "duration_s")
    else close_span(st, ktask ":" attempt, epoch, task)
    add_gate(event, gate_mode, node, attempt, reason, warnings, errors)
  }
  if (event == "test_run_passed" || event == "test_run_failed") {
    st = "test_gate:xcodebuild-test"
    if (valid_duration(duration)) sample_stage(st, task, "", "", duration, "duration_s")
    else close_span(st, ktask ":" attempt, epoch, task)
    add_gate(event, "xcodebuild-test", node, attempt, reason, warnings, errors)
  }
  if (event == "review_requested") {
    if (impl_start[ktask] != "") {
      sample_stage("implementation_until_first_gate", task, impl_start[ktask], epoch, "", "paired")
      impl_start[ktask] = ""
    }
    add_review(event, stage, status, reason, duration, task)
    span_start["argus_review:" (stage != "" ? stage : "unknown"), ktask ":" (stage != "" ? stage : "unknown")] = epoch
  }
  if (event == "review_approved" || event == "review_flagged" || event == "review_blocked") {
    rstage = stage != "" ? stage : "unknown"
    add_review(event, rstage, status, reason, duration, task)
    if (!valid_duration(duration)) close_span("argus_review:" rstage, ktask ":" rstage, epoch, task)
  }
  if (event == "argus_gate_skipped" || event == "argus_preflight_failed") add_review(event, stage, status, reason, duration, task)
  if (event == "task_awaiting_user") wait_start[ktask] = epoch
  if (event == "task_awaiting_user_resolved") {
    if (valid_duration(wait_duration)) sample_stage("user_verification_dwell", task, "", "", wait_duration, "wait_duration_s")
    else if (wait_start[ktask] != "") sample_stage("user_verification_dwell", task, wait_start[ktask], epoch, "", "paired")
    else gap("user_verification_dwell", "missing_wait_start", 1)
  }
  if (event == "task_merged") {
    merge_at[ktask] = epoch
    if (task != "" && overall_start[task] != "") sample_stage("end_to_end_to_merge", task, overall_start[task], epoch, "", "paired")
  }
  if (event == "task_completed" || event == "brief_completed") {
    if (duration != "" && valid_duration(duration)) sample_stage("debrief_emit_or_completion", task, "", "", duration, "duration_s")
    if (task != "" && overall_start[task] != "") sample_stage("end_to_end_to_done", task, overall_start[task], epoch, "", "paired")
  }
  if (event == "sweep_phase_completed") {
    sweep_stage = "debrief_sweep:" (stage != "" ? stage : "unknown")
    if (valid_duration(duration)) sample_stage(sweep_stage, task, "", "", duration, "duration_s")
    else gap(sweep_stage, "missing_duration_s", 1)
  }
  if (event == "release_handoff_started") span_start["release_handoff", ktask] = epoch
  if (event == "release_handoff_completed" || event == "appstore_submitted" || event == "appstore_released") {
    if (valid_duration(duration)) sample_stage("release_handoff", task, "", "", duration, "duration_s")
    else if (span_start["release_handoff", ktask] != "") close_span("release_handoff", ktask, epoch, task)
  }
  if (event == "agent_session_completed") {
    session_stage = "agent_session:" agent
    if (valid_duration(duration)) sample_stage(session_stage, task, "", "", duration, "duration_s")
    else gap(session_stage, "missing_duration_s", 1)
    add_tokens(agent, mode, host, model, task, ev_size, recommended, fallback, tin, tout, tc, tcw)
  }
  if (event == "pr_review_completed") {
    add_tokens(agent, mode != "" ? mode : "pr-review", host, model, task, ev_size, recommended, fallback, tin, tout, tc, tcw)
  }
  if (event == "task_redispatched" || event == "task_reopened") {
    rework_count++
    if (task_summary(task) == "0" || task_summary(task) == "") rework_missing_summary++
    if (task_acceptance(task) == "" || task_acceptance(task) == "0") rework_missing_acceptance++
  }
  if (dispatch_reason != "" && dispatch_reason != "healthy") {
    remote_fallbacks++
    remote_fallback_reason[dispatch_reason]++
  }
}
END {
  for (k in span_start) {
    if (span_start[k] != "") {
      split(k, parts, SUBSEP)
      gap(parts[1], "missing_end", 1)
    }
  }
  for (k in dispatch_start) if (dispatch_start[k] != "") gap("dispatch_queue_wait", "missing_worker_start", 1)
  for (k in impl_start) if (impl_start[k] != "") gap("implementation_until_first_gate", "missing_gate_or_review", 1)
  for (k in wait_start) if (wait_start[k] != "") gap("user_verification_dwell", "missing_wait_end", 1)

  sorted_stage_report()

  print ""
  print "Build/test pass rates by mode and node"
  printf "%-18s %-18s %7s %8s %8s %9s %10s %9s %9s %8s\n", "Mode", "Node", "attempts", "pass", "fail", "pass_rate", "first_pass", "retry_pass", "warnings", "errors"
  if (gate_n < 1) print "  unavailable: no build_check_* or test_run_* terminal events"
  for (i = 1; i <= gate_n; i++) {
    split(gate_order[i], g, "\t"); key = gate_order[i]
    printf "%-18s %-18s %7d %8d %8d %9s %10s %9s %9d %8d\n", g[1], g[2], gate_total[key] + 0, gate_pass[key] + 0, gate_fail[key] + 0, pct(gate_pass[key], gate_total[key]), pct(gate_first_pass[key], gate_first_total[key]), pct(gate_retry_pass[key], gate_retry_total[key]), gate_warnings[key] + 0, gate_errors[key] + 0
  }

  print ""
  print "Build/test failure classes"
  if (class_n < 1) print "  none"
  for (i = 1; i <= gate_n; i++) {
    key = gate_order[i]; split(key, g, "\t")
    for (j = 1; j <= class_n; j++) {
      cls = class_order[j]
      if (gate_fail_class[key, cls] + 0 > 0) printf "  %-18s %-18s %-24s %d\n", g[1], g[2], cls, gate_fail_class[key, cls]
    }
  }

  print ""
  print "Review coverage and verdicts"
  printf "%-10s %8s %9s %8s %8s %8s %8s\n", "Stage", "requested", "approved", "flagged", "blocked", "skipped", "infra"
  if (review_n < 1) print "  unavailable: no Argus review events"
  for (i = 1; i <= review_n; i++) {
    st = review_order[i]
    printf "%-10s %8d %9d %8d %8d %8d %8d\n", st, review_requested[st] + 0, review_approved[st] + 0, review_flagged[st] + 0, review_blocked[st] + 0, review_skipped[st] + 0, review_infra_failed[st] + 0
  }

  print ""
  print "Token usage by agent/mode/model/host/task size"
  printf "%-10s %-16s %-24s %-16s %-9s %7s %9s %9s %9s %10s %10s\n", "Agent", "Mode", "Model", "Host", "Size", "samples", "p50_tok", "p90_tok", "p95_tok", "cache_hit", "missing"
  if (token_n < 1) print "  unavailable: no agent_session_completed or pr_review_completed events"
  for (i = 1; i <= token_n; i++) {
    key = token_order[i]; split(key, t, "\t")
    denom = token_input[key] + token_cache_read[key]
    cache_hit = denom > 0 ? sprintf("%.2f", token_cache_read[key] / denom) : "n/a"
    printf "%-10s %-16s %-24s %-16s %-9s %7d %9s %9s %9s %10s %10d\n", t[1], t[2], t[3], t[4], t[5], token_count[key] + 0, token_percentile(key, 0.50), token_percentile(key, 0.90), token_percentile(key, 0.95), cache_hit, token_missing[key] + 0
  }

  print ""
  print "Telemetry gaps ranked by impact"
  for (stage in gap_count) gap_rank[++gap_rank_n] = sprintf("%012d", gap_impact[stage]) "\t" stage
  for (i = 1; i <= gap_rank_n; i++) for (j = i + 1; j <= gap_rank_n; j++) {
    split(gap_rank[i], a, "\t"); split(gap_rank[j], b, "\t")
    if (a[1] + 0 < b[1] + 0) { tmp = gap_rank[i]; gap_rank[i] = gap_rank[j]; gap_rank[j] = tmp }
  }
  if (gap_rank_n < 1) print "  none"
  for (i = 1; i <= gap_rank_n; i++) {
    split(gap_rank[i], a, "\t"); stage = a[2]
    printf "  %-38s impact=%d gaps=%d", stage, gap_impact[stage] + 0, gap_count[stage] + 0
    sep = " ("
    for (r in gap_reason) {
      split(r, rr, SUBSEP)
      if (rr[1] == stage) { printf "%s%s=%d", sep, rr[2], gap_reason[r]; sep = ", " }
    }
    print ")"
  }

  print ""
  print "Improvement candidates"
  any = 0
  total_gate = total_fail = total_retry = 0
  for (i = 1; i <= gate_n; i++) {
    key = gate_order[i]
    total_gate += gate_total[key]
    total_fail += gate_fail[key]
    total_retry += gate_retry_total[key]
  }
  if (total_gate > 0 && (total_fail / total_gate) >= 0.30) {
    print "  - High build/test failure rate: inspect failure-class rows and file reliability work for the dominant abstract class."
    any = 1
  }
  if (total_gate > 0 && (total_retry / total_gate) >= 0.25) {
    print "  - High gate retry rate: tune gate setup, retry policy, or the failure class driving repeated attempts."
    any = 1
  }
  total_requested = total_skipped = total_infra = 0
  for (i = 1; i <= review_n; i++) {
    st = review_order[i]
    total_requested += review_requested[st]
    total_skipped += review_skipped[st]
    total_infra += review_infra_failed[st]
  }
  if ((total_requested + total_skipped + total_infra) > 0 && (total_skipped + total_infra) / (total_requested + total_skipped + total_infra) >= 0.10) {
    print "  - Argus coverage is degraded: file review-gate reliability work for skip or infra-failure patterns."
    any = 1
  }
  for (i = 1; i <= token_n; i++) {
    key = token_order[i]; split(key, t, "\t")
    if ((t[5] == "xs" || t[5] == "s") && token_count[key] >= 1 && token_percentile(key, 0.90) != "n/a" && token_percentile(key, 0.90) + 0 >= 50000) {
      print "  - High token cost on small tasks: improve brief slicing, model recommendation, or selective rule loading."
      any = 1
      break
    }
  }
  if (build_queue_events > 0 && build_queue_waiters / build_queue_events >= 0.25) {
    print "  - Build queue wait is visible: tune worker pool, node capacity, or priority queue policy."
    any = 1
  }
  if (rework_count > 0 && (rework_missing_summary + rework_missing_acceptance) / (2 * rework_count) >= 0.25) {
    print "  - Rework correlates with weak brief shape: tighten brief-quality lint for summary and measurable acceptance criteria."
    any = 1
  }
  if (remote_fallbacks > 0) {
    print "  - Remote dispatch fallback occurred: inspect node health, source sync, and parity before adding capacity."
    any = 1
  }
  if (gap_count["briefed_to_dispatched"] > 0) {
    print "  - briefed -> dispatched latency is under-measured: ensure ready-state and dispatch events share task/brief ids."
    any = 1
  }
  if (!any) print "  none crossed thresholds in this window"

  print ""
  print "Privacy note"
  print "  Safe for public issues: abstract rates, failure classes, missing telemetry fields, and non-identifying workflow patterns."
  print "  Keep private: task IDs, feature names, file paths, branch names, build numbers, release versions, exact private timings, and verbatim debrief/review text."
}
' "$brief_file" "$norm_file"
