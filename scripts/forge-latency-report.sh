#!/usr/bin/env bash
# forge-latency-report.sh — summarize Forge task latency from event logs.
#
# Usage:
#   scripts/forge-latency-report.sh                 # last 14 days, current project
#   scripts/forge-latency-report.sh --days 30
#   scripts/forge-latency-report.sh --project turnip-ios --since 2026-04-01
#   scripts/forge-latency-report.sh --cutover 2026-04-28T00:00:00Z
#
# Reads canonical events via scripts/read-events.sh and reports only durations
# backed by explicit duration_s fields or paired start/end timestamps. Missing
# pairs are counted as telemetry gaps rather than treated as zero.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

DAYS=14
PROJECT=""
SINCE=""
UNTIL=""
CUTOVER=""

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
    --cutover=*) CUTOVER="${1#--cutover=}"; shift ;;
    --cutover) CUTOVER="${2:?--cutover requires ISO8601 or YYYY-MM-DD}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'forge-latency-report: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) printf 'forge-latency-report: --days must be a positive integer\n' >&2; exit 2 ;;
  0) printf 'forge-latency-report: --days must be > 0\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'forge-latency-report: jq required\n' >&2; exit 2; }

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'forge-latency-report: no project resolved. Pass --project <slug> or run inside a git repo.\n' >&2
    exit 2
  }
fi

if [ -z "$SINCE" ]; then
  now_epoch=$(date -u +%s)
  since_epoch=$((now_epoch - (DAYS - 1) * 86400))
  SINCE=$(date -u -r "$since_epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$since_epoch" +%Y-%m-%d)
fi

events_file=$(mktemp -t forge-latency-events.XXXXXX)
norm_file=$(mktemp -t forge-latency-norm.XXXXXX)
trap 'rm -f "$events_file" "$norm_file"' EXIT

read_args=(--project "$PROJECT" --since "$SINCE")
[ -n "$UNTIL" ] && read_args+=(--until "$UNTIL")

"$SCRIPT_DIR/read-events.sh" "${read_args[@]}" > "$events_file" || {
  printf 'forge-latency-report: failed to read events for project %s\n' "$PROJECT" >&2
  exit 1
}

event_count=$(wc -l < "$events_file" | tr -d ' ')
if [ "$event_count" -eq 0 ]; then
  printf 'Forge latency report for %s (%s%s)\n(no events in window)\n' \
    "$PROJECT" "$SINCE" "${UNTIL:+..$UNTIL}"
  exit 0
fi

cutover_epoch=""
if [ -n "$CUTOVER" ]; then
  case "$CUTOVER" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) CUTOVER="${CUTOVER}T00:00:00Z" ;;
  esac
  cutover_epoch=$(jq -nr --arg ts "$CUTOVER" 'try ($ts | fromdateiso8601 | floor) catch empty')
  [ -n "$cutover_epoch" ] || {
    printf 'forge-latency-report: --cutover must be ISO8601 UTC or YYYY-MM-DD\n' >&2
    exit 2
  }
else
  cutover_epoch=$(jq -sr '
    [.[]
     | select(.event == "precommit_hook_completed" or .event == "precommit_review_passed" or .event == "precommit_review_blocked" or .event == "precommit_review_bypassed" or .event == "precommit_review_failed")
     | try (.ts | fromdateiso8601 | floor) catch empty
    ] | min // empty
  ' "$events_file")
fi

jq -r '
  def epoch: try (.ts | fromdateiso8601 | floor) catch "";
  def task_id: (.task // .data.task // .data.task_id // .data.legacy_task_id // "");
  [
    epoch,
    (.ts // ""),
    (.event // ""),
    task_id,
    (.agent // .producer.agent // ""),
    (.mode // .data.mode // ""),
    (.data.stage // .data.phase // ""),
    (.data.attempt // 1),
    (.data.duration_s // ""),
    (.data.wait_duration_s // ""),
    (.data.patch_id // ""),
    (.data.review_host // ""),
    (.data.reason // .data.block_reason // ""),
    (.data.tokens.input // .data.input_tokens // ""),
    (.data.tokens.output // .data.output_tokens // ""),
    (.data.tokens.cache_read // .data.cache_read_tokens // .data.cached_input_tokens // "")
  ] | @tsv
' "$events_file" > "$norm_file"

printf 'Forge latency report for %s (%s%s)\n' "$PROJECT" "$SINCE" "${UNTIL:+..$UNTIL}"
printf 'Events read: %s\n' "$event_count"
if [ -n "$cutover_epoch" ]; then
  cutover_label=$(date -u -r "$cutover_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$cutover_epoch" +%Y-%m-%dT%H:%M:%SZ)
  printf 'Comparison cutover: %s\n' "$cutover_label"
else
  printf 'Comparison cutover: unavailable (no precommit hook/review events in window; pass --cutover)\n'
fi
printf '\n'

awk -F'\t' -v cutover="$cutover_epoch" '
function valid_duration(v) {
  return (v ~ /^[0-9]+$/ && v >= 0 && v <= 86400)
}
function sample(stage, task, start, end, dur, source, bucket,    n) {
  if (dur == "" && start != "" && end != "") dur = end - start
  if (!valid_duration(dur)) {
    sanity[stage]++
    return
  }
  if (dur < 0 || dur > 86400) {
    sanity[stage]++
    return
  }
  n = ++count[stage]
  values[stage, n] = dur + 0
  total[stage] += dur
  if (!(stage in seen_stage)) {
    seen_stage[stage] = 1
    stage_order[++stage_n] = stage
  }
  if (task != "") task_seen[stage, task] = 1
  if (bucket != "" && stage == "end_to_end_task") {
    bn = ++bucket_count[bucket]
    bucket_values[bucket, bn] = dur + 0
    bucket_total[bucket] += dur
  }
}
function missing(stage, reason) {
  missing_count[stage]++
  missing_reason[stage, reason]++
  if (!(stage in seen_stage)) {
    seen_stage[stage] = 1
    stage_order[++stage_n] = stage
  }
}
function percentile(stage, pct,    n, i, j, idx, tmp) {
  n = count[stage]
  if (n < 1) return "n/a"
  for (i = 1; i <= n; i++) sorted[i] = values[stage, i]
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
function bucket_percentile(bucket, pct,    n, i, j, idx, tmp) {
  n = bucket_count[bucket]
  if (n < 1) return "n/a"
  for (i = 1; i <= n; i++) bsorted[i] = bucket_values[bucket, i]
  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (bsorted[i] > bsorted[j]) {
        tmp = bsorted[i]; bsorted[i] = bsorted[j]; bsorted[j] = tmp
      }
    }
  }
  idx = int(n * pct + 0.999)
  if (idx < 1) idx = 1
  if (idx > n) idx = n
  return bsorted[idx]
}
function close_span(stage, key, end, task, bucket) {
  if (span_start[stage, key] == "") {
    missing(stage, "missing_start")
    return
  }
  sample(stage, task, span_start[stage, key], end, "", "paired", bucket)
  span_start[stage, key] = ""
}
function bucket_for_task(task) {
  if (cutover == "" || task == "" || overall_start[task] == "") return ""
  return (overall_start[task] < cutover) ? "pre" : "post"
}
function task_key(task, fallback) {
  return task != "" ? task : fallback
}
function valid_tokens(v) {
  return (v ~ /^[0-9]+$/ && v >= 0)
}
{
  epoch=$1; event=$3; task=$4; agent=$5; mode=$6; stage=$7; attempt=$8; duration=$9; wait_duration=$10; patch_id=$11; review_host=$12; reason=$13; token_input=$14; token_output=$15; token_cache_read=$16
  if (epoch == "" || event == "") next
  fallback = "event:" NR
  key_task = task_key(task, fallback)

  if (event == "brief_dispatched" || event == "task_dispatched" || event == "dispatch_routed") {
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
    if (task != "" && claim_start[task] == "") claim_start[task] = epoch
  }

  if (event == "brief_started" || event == "task_started") {
    if (task != "" && overall_start[task] == "") overall_start[task] = epoch
    if (task != "" && claim_start[task] != "") {
      sample("brief/claim", task, claim_start[task], epoch, "", "paired", bucket_for_task(task))
      claim_start[task] = ""
    } else if (task != "") {
      missing("brief/claim", "missing_dispatch")
    }
    if (task != "" && impl_start[task] == "") impl_start[task] = epoch
  }

  if (event == "build_check_started" || event == "test_run_started") {
    if (task != "" && impl_start[task] != "") {
      sample("implementation_before_first_gate", task, impl_start[task], epoch, "", "paired", bucket_for_task(task))
      impl_start[task] = ""
    }
    span_start["build/test", key_task ":" event ":" attempt] = epoch
  }
  if (event == "build_check_passed" || event == "build_check_failed" || event == "build_check_aborted") {
    if (duration != "" && valid_duration(duration)) {
      sample("build/test", task, "", "", duration, "duration_s", bucket_for_task(task))
      span_start["build/test", key_task ":build_check_started:" attempt] = ""
    }
    else close_span("build/test", key_task ":build_check_started:" attempt, epoch, task, bucket_for_task(task))
  }
  if (event == "test_run_passed" || event == "test_run_failed") {
    if (duration != "" && valid_duration(duration)) {
      sample("build/test", task, "", "", duration, "duration_s", bucket_for_task(task))
      span_start["build/test", key_task ":test_run_started:" attempt] = ""
    }
    else close_span("build/test", key_task ":test_run_started:" attempt, epoch, task, bucket_for_task(task))
  }

  if (event == "review_requested") {
    if (stage == "") stage = "unknown"
    if (task != "" && impl_start[task] != "") {
      sample("implementation_before_first_gate", task, impl_start[task], epoch, "", "paired", bucket_for_task(task))
      impl_start[task] = ""
    }
    span_start["argus_review:" stage, key_task ":" stage] = epoch
  }
  if (event == "review_approved" || event == "review_flagged" || event == "review_blocked") {
    if (stage == "") stage = "unknown"
    close_span("argus_review:" stage, key_task ":" stage, epoch, task, bucket_for_task(task))
  }

  if (event == "task_awaiting_user") {
    if (task != "") wait_start[task] = epoch
  }
  if (event == "task_awaiting_user_resolved") {
    if (valid_duration(wait_duration)) sample("user_wait", task, "", "", wait_duration, "wait_duration_s", bucket_for_task(task))
    else if (task != "" && wait_start[task] != "") sample("user_wait", task, wait_start[task], epoch, "", "paired", bucket_for_task(task))
    else missing("user_wait", "missing_wait_start")
  }

  if (event == "precommit_review_passed" || event == "precommit_review_blocked" || event == "precommit_review_bypassed") {
    if (duration != "" && valid_duration(duration)) sample("pre-commit_review", patch_id, "", "", duration, "duration_s", "")
    else missing("pre-commit_review", "missing_duration_or_start_end")
  }
  if (event == "precommit_review_failed") {
    if (duration != "" && valid_duration(duration)) sample("pre-commit_review_infra_failure", patch_id, "", "", duration, "duration_s", "")
    else missing("pre-commit_review_infra_failure", "missing_duration_or_start_end")
    precommit_infra_failures++
    infra_host = review_host != "" ? review_host : "unknown"
    infra_reason = reason != "" ? reason : "unknown"
    if (!(infra_host in precommit_infra_host_seen)) {
      precommit_infra_host_seen[infra_host] = 1
      precommit_infra_host_order[++precommit_infra_host_n] = infra_host
    }
    precommit_infra_host_count[infra_host]++
    precommit_infra_reason_count[infra_reason]++
  }
  if (event == "precommit_hook_completed") {
    if (duration != "" && valid_duration(duration)) sample("pre-commit_hook", "", "", "", duration, "duration_s", "")
    else missing("pre-commit_hook", "missing_duration_s")
  }
  if (event == "pr_review_completed") {
    if (duration != "" && valid_duration(duration)) sample("pr_review", "", "", "", duration, "duration_s", "")
    else missing("pr_review", "missing_duration_s")
    if (valid_tokens(token_input) && valid_tokens(token_output) && valid_tokens(token_cache_read)) {
      pr_review_token_samples++
      pr_review_input_total += token_input + 0
      pr_review_output_total += token_output + 0
      pr_review_cache_read_total += token_cache_read + 0
      if (!(review_host in pr_review_host_seen)) {
        pr_review_host_seen[review_host] = 1
        pr_review_host_order[++pr_review_host_n] = review_host
      }
      pr_review_host_samples[review_host]++
      pr_review_host_input[review_host] += token_input + 0
      pr_review_host_output[review_host] += token_output + 0
    } else {
      missing("pr_review_tokens", "missing_tokens")
    }
  }
  if (event == "pr_autopilot_completed") {
    if (duration != "" && valid_duration(duration)) sample("pr_autopilot", task, "", "", duration, "duration_s", "")
    else missing("pr_autopilot", "missing_duration_s")
  }
  if (event == "pr_merge_finalize_completed") {
    if (duration != "" && valid_duration(duration)) sample("pr_merge_finalize", task, "", "", duration, "duration_s", "")
    else missing("pr_merge_finalize", "missing_duration_s")
  }
  if (event == "sweep_phase_completed") {
    sweep_stage = "sweep:" (stage != "" ? stage : "unknown")
    if (duration != "" && valid_duration(duration)) sample(sweep_stage, task, "", "", duration, "duration_s", "")
    else missing(sweep_stage, "missing_duration_s")
  }
  if (event == "session_start_completed") {
    if (duration != "" && valid_duration(duration)) sample("session_start", task, "", "", duration, "duration_s", "")
    else missing("session_start", "missing_duration_s")
  }

  if (event == "agent_session_completed") {
    session_stage = "agent_session:" agent
    if (duration != "" && valid_duration(duration)) sample(session_stage, task, "", "", duration, "duration_s", bucket_for_task(task))
    else missing(session_stage, "missing_duration_s")
  }

  if (event == "task_completed" || event == "brief_completed" || event == "task_merged" || event == "task_cancelled" || event == "task_rescued" || event == "brief_failed" || event == "merge_conflict") {
    if (task != "" && overall_start[task] != "" && overall_done[task] == "") {
      overall_done[task] = epoch
      sample("end_to_end_task", task, overall_start[task], epoch, "", "paired", bucket_for_task(task))
    } else if (task != "" && overall_start[task] == "") {
      missing("end_to_end_task", "missing_start")
    }
  }
}
END {
  for (k in span_start) {
    if (span_start[k] != "") {
      split(k, parts, SUBSEP)
      missing(parts[1], "missing_end")
    }
  }
  for (task in claim_start) if (claim_start[task] != "") missing("brief/claim", "missing_start_or_end")
  for (task in impl_start) if (impl_start[task] != "") missing("implementation_before_first_gate", "missing_gate_or_end")
  for (task in wait_start) if (wait_start[task] != "") missing("user_wait", "missing_wait_end")

  print "Stage latency (ranked by total measured time)"
  printf "%-36s %7s %10s %10s %10s %10s\n", "Stage", "samples", "total_s", "p50_s", "p90_s", "gaps"
  for (i = 1; i <= stage_n; i++) {
    stage = stage_order[i]
    rank_key = sprintf("%012d", total[stage]) "\t" stage
    ranks[++rank_n] = rank_key
  }
  for (i = 1; i <= rank_n; i++) {
    for (j = i + 1; j <= rank_n; j++) {
      split(ranks[i], ai, "\t"); split(ranks[j], aj, "\t")
      if (ai[1] + 0 < aj[1] + 0) {
        tmp = ranks[i]; ranks[i] = ranks[j]; ranks[j] = tmp
      }
    }
  }
  for (i = 1; i <= rank_n; i++) {
    split(ranks[i], r, "\t")
    stage = r[2]
    if (count[stage] == "" && missing_count[stage] == "") continue
    printf "%-36s %7d %10d %10s %10s %10d\n", stage, count[stage] + 0, total[stage] + 0, percentile(stage, 0.50), percentile(stage, 0.90), missing_count[stage] + 0
  }

  print ""
  print "Pre-commit reviewer infrastructure failures"
  if (precommit_infra_failures + 0 < 1) {
    print "  none"
  } else {
    printf "  total=%d\n", precommit_infra_failures
    if (precommit_infra_host_n > 0) {
      print "  by host:"
      for (i = 1; i <= precommit_infra_host_n; i++) {
        host = precommit_infra_host_order[i]
        printf "    %-20s failures=%d\n", host, precommit_infra_host_count[host] + 0
      }
    }
    print "  by reason:"
    for (reason in precommit_infra_reason_count) {
      printf "    %-32s failures=%d\n", reason, precommit_infra_reason_count[reason] + 0
    }
  }

  print ""
  print "PR review token usage"
  if (pr_review_token_samples + 0 < 1) {
    print "  unavailable: no pr_review_completed token telemetry in window"
  } else {
    printf "  samples=%d input_tokens=%d output_tokens=%d cache_read_tokens=%d total_tokens=%d\n", \
      pr_review_token_samples, pr_review_input_total, pr_review_output_total, pr_review_cache_read_total, pr_review_input_total + pr_review_output_total
    if (pr_review_host_n > 0) {
      print "  by host:"
      for (i = 1; i <= pr_review_host_n; i++) {
        host = pr_review_host_order[i]
        printf "    %-20s samples=%d input_tokens=%d output_tokens=%d\n", host, pr_review_host_samples[host] + 0, pr_review_host_input[host] + 0, pr_review_host_output[host] + 0
      }
    }
  }

  print ""
  print "Comparison: end-to-end task duration"
  if (cutover == "") {
    print "  unavailable: no cutover"
  } else if (bucket_count["pre"] < 2 || bucket_count["post"] < 2) {
    printf "  insufficient samples: pre=%d post=%d (need at least 2 each)\n", bucket_count["pre"] + 0, bucket_count["post"] + 0
  } else {
    printf "  %-6s samples=%d total_s=%d p50_s=%s p90_s=%s\n", "pre", bucket_count["pre"], bucket_total["pre"], bucket_percentile("pre", 0.50), bucket_percentile("pre", 0.90)
    printf "  %-6s samples=%d total_s=%d p50_s=%s p90_s=%s\n", "post", bucket_count["post"], bucket_total["post"], bucket_percentile("post", 0.50), bucket_percentile("post", 0.90)
  }

  print ""
  print "Telemetry gaps"
  any_gap = 0
  for (stage in missing_count) {
    if (missing_count[stage] + 0 < 1) continue
    any_gap = 1
    printf "  %s: %d gap(s)", stage, missing_count[stage]
    sep = " ("
    for (reason in missing_reason) {
      split(reason, rr, SUBSEP)
      if (rr[1] == stage) {
        printf "%s%s=%d", sep, rr[2], missing_reason[reason]
        sep = ", "
      }
    }
    print ")"
  }
  for (stage in sanity) {
    any_gap = 1
    printf "  %s: %d duration_sanity_fail-equivalent sample(s)\n", stage, sanity[stage]
  }
  if (!any_gap) print "  none"
}
' "$norm_file"

cat <<'EOF'

Minimum new telemetry fields still needed
- self-review: emit self_review_started/self_review_completed or add duration_s to self_review_iterated.
- Argus dispatch wait vs review work: stamp dispatch_review_started, reviewer_spawned_at, verdict_observed_at, and duration_s on dispatch-review outcomes.
- Sweep phases: emit duration_s per major inbox-sweep phase so queue drain, event reconciliation, follow-up detection, and status rendering can be separated.
- user wait: keep pairing task_awaiting_user with task_awaiting_user_resolved.wait_duration_s; missing pairs stay excluded from totals.
EOF
