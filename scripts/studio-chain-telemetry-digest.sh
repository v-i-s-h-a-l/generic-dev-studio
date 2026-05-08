#!/usr/bin/env bash
# studio-chain-telemetry-digest.sh - v1 counters and weekly digest for Studio chain runs.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

FORMAT="markdown"
RUN_ID=""
CHAIN_RUN_ROOT=""
CHAIN_RUNS_ROOT=""
DAYS=7
SINCE=""
UNTIL=""
PROJECT_FILTER=""
PUBLIC_SAFE=0
PUBLIC_SAFE_TRIGGER=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/studio-chain-telemetry-digest.sh [--days N] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--format markdown|json]
  scripts/studio-chain-telemetry-digest.sh --project <slug|repo|path> [--public-safe] [--format markdown|json]
  scripts/studio-chain-telemetry-digest.sh --run <run_id> [--format markdown|json]
  scripts/studio-chain-telemetry-digest.sh --chain-run-root <dir> [--format markdown|json]

Reads private chain-run state under ~/.dev-studio/generic-dev-studio/chain-runs
and emits aggregate v1 counters plus a compact operator digest. --project uses
explicit project/repo metadata when present and reports path fallback matches.
--public-safe redacts local private paths from emitted JSON/markdown.
EOF
  exit 2
}

date_days_ago() {
  local days="$1"
  if date -u -v-"$days"d +%Y-%m-%d >/dev/null 2>&1; then
    date -u -v-"$days"d +%Y-%m-%d
  else
    date -u -d "$days days ago" +%Y-%m-%d
  fi
}

file_mtime_epoch() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || printf '0\n'
}

epoch_to_iso() {
  local epoch="$1"
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:?--format requires markdown|json}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --project) PROJECT_FILTER="${2:?--project requires slug, repo, or path}"; shift 2 ;;
    --project=*) PROJECT_FILTER="${1#--project=}"; shift ;;
    --target-project) PROJECT_FILTER="${2:?--target-project requires slug, repo, or path}"; shift 2 ;;
    --target-project=*) PROJECT_FILTER="${1#--target-project=}"; shift ;;
    --public-safe) PUBLIC_SAFE=1; PUBLIC_SAFE_TRIGGER="flag"; shift ;;
    --run) RUN_ID="${2:?--run requires run id}"; shift 2 ;;
    --run=*) RUN_ID="${1#--run=}"; shift ;;
    --chain-run-root) CHAIN_RUN_ROOT="${2:?--chain-run-root requires dir}"; shift 2 ;;
    --chain-run-root=*) CHAIN_RUN_ROOT="${1#--chain-run-root=}"; shift ;;
    --chain-runs-root) CHAIN_RUNS_ROOT="${2:?--chain-runs-root requires dir}"; shift 2 ;;
    --chain-runs-root=*) CHAIN_RUNS_ROOT="${1#--chain-runs-root=}"; shift ;;
    --days) DAYS="${2:?--days requires N}"; shift 2 ;;
    --days=*) DAYS="${1#--days=}"; shift ;;
    --since) SINCE="${2:?--since requires YYYY-MM-DD}"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    --until) UNTIL="${2:?--until requires YYYY-MM-DD}"; shift 2 ;;
    --until=*) UNTIL="${1#--until=}"; shift ;;
    -h|--help) usage ;;
    *) printf 'studio-chain-telemetry-digest: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

case "${STUDIO_CHAIN_TELEMETRY_PUBLIC_SAFE:-}" in
  1|true|yes)
    PUBLIC_SAFE=1
    [ -n "$PUBLIC_SAFE_TRIGGER" ] || PUBLIC_SAFE_TRIGGER="env"
    ;;
esac
[ -n "$PUBLIC_SAFE_TRIGGER" ] || PUBLIC_SAFE_TRIGGER="off"

case "$FORMAT" in
  markdown|json) ;;
  *) printf 'studio-chain-telemetry-digest: --format must be markdown or json\n' >&2; exit 2 ;;
esac
case "$DAYS" in
  ''|*[!0-9]*) printf 'studio-chain-telemetry-digest: --days must be a positive integer\n' >&2; exit 2 ;;
  0) printf 'studio-chain-telemetry-digest: --days must be a positive integer\n' >&2; exit 2 ;;
esac
case "$SINCE" in ""|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) printf 'studio-chain-telemetry-digest: --since must be YYYY-MM-DD\n' >&2; exit 2 ;; esac
case "$UNTIL" in ""|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) printf 'studio-chain-telemetry-digest: --until must be YYYY-MM-DD\n' >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { printf 'studio-chain-telemetry-digest: jq required\n' >&2; exit 2; }

if [ -z "$CHAIN_RUNS_ROOT" ]; then
  parent_home=$(resolve_parent_home_for_github)
  project_root=$(HOME="$parent_home" resolve_project_root_for generic-dev-studio)
  CHAIN_RUNS_ROOT="$project_root/chain-runs"
fi
if [ -n "$RUN_ID" ] && [ -z "$CHAIN_RUN_ROOT" ]; then
  CHAIN_RUN_ROOT="$CHAIN_RUNS_ROOT/$RUN_ID"
fi
[ -n "$SINCE" ] || SINCE=$(date_days_ago "$DAYS")
[ -n "$UNTIL" ] || UNTIL=$(date -u +%Y-%m-%d)

TMPDIR_DIGEST=$(mktemp -d -t studio-chain-telemetry.XXXXXX)
trap 'rm -rf "$TMPDIR_DIGEST"' EXIT
states_jsonl="$TMPDIR_DIGEST/states.jsonl"
events_jsonl="$TMPDIR_DIGEST/events.jsonl"
summaries_jsonl="$TMPDIR_DIGEST/summaries.jsonl"
halts_jsonl="$TMPDIR_DIGEST/halts.jsonl"
reports_jsonl="$TMPDIR_DIGEST/reports.jsonl"
digest_json="$TMPDIR_DIGEST/digest.json"
: > "$states_jsonl"
: > "$events_jsonl"
: > "$summaries_jsonl"
: > "$halts_jsonl"
: > "$reports_jsonl"

append_run() {
  local run_root="$1" state events summaries halts report_path report_exists report_mtime_epoch report_mtime_iso report_size report_generated_at report_generated_at_source latest_event_at
  state="$run_root/state.json"
  events="$run_root/events.jsonl"
  summaries="$run_root/worker-summaries"
  halts="$run_root/halt-records"
  [ -f "$state" ] || return 0
  jq -c --arg run_root "$run_root" '. + {__run_root: $run_root}' "$state" >> "$states_jsonl"
  if [ -f "$events" ]; then
    jq -c --arg run_root "$run_root" '. + {__run_root: $run_root}' "$events" >> "$events_jsonl"
  fi
  if [ -d "$summaries" ]; then
    find "$summaries" -type f -name '*.json' | sort | while IFS= read -r summary; do
      jq -c --arg run_root "$run_root" --arg path "$summary" '. + {__run_root: $run_root, __artifact_path: $path}' "$summary" >> "$summaries_jsonl"
    done
  fi
  if [ -d "$halts" ]; then
    find "$halts" -type f -name '*.json' | sort | while IFS= read -r halt; do
      jq -c --arg run_root "$run_root" --arg path "$halt" '. + {__run_root: $run_root, __artifact_path: $path}' "$halt" >> "$halts_jsonl"
    done
  fi
  report_path=$(jq -r '.report // empty' "$state")
  report_exists=false
  report_mtime_epoch=0
  report_mtime_iso=""
  report_size=0
  report_generated_at=$(jq -r '.report_generated_at // empty' "$state" 2>/dev/null || true)
  report_generated_at_source=""
  latest_event_at=""
  if [ -n "$report_path" ] && [ -f "$report_path" ]; then
    report_exists=true
    report_mtime_epoch=$(file_mtime_epoch "$report_path")
    report_mtime_iso=$(epoch_to_iso "$report_mtime_epoch")
    report_size=$(wc -c < "$report_path" | tr -d ' ')
  fi
  if [ -z "$report_generated_at" ] && [ "$report_exists" = true ] && [ -n "$report_mtime_iso" ]; then
    report_generated_at="$report_mtime_iso"
    report_generated_at_source="filesystem_mtime"
  elif [ -n "$report_generated_at" ]; then
    report_generated_at_source="state.report_generated_at"
  fi
  if [ -f "$events" ]; then
    latest_event_at=$(jq -r -s '[ .[] | .created_at? // empty | select(. != "") ] | max // ""' "$events" 2>/dev/null || true)
  fi
  jq -cn \
    --arg run_root "$run_root" \
    --arg path "$report_path" \
    --arg mtime "$report_mtime_iso" \
    --arg generated_at "$report_generated_at" \
    --arg generated_at_source "$report_generated_at_source" \
    --arg latest_event_at "$latest_event_at" \
    --argjson exists "$report_exists" \
    --argjson mtime_epoch "$report_mtime_epoch" \
    --argjson size "$report_size" \
    '{__run_root:$run_root, path:(if $path == "" then null else $path end), exists:$exists, mtime:(if $mtime == "" then null else $mtime end), mtime_epoch:$mtime_epoch, generated_at:(if $generated_at == "" then null else $generated_at end), generated_at_source:(if $generated_at_source == "" then null else $generated_at_source end), latest_event_at:(if $latest_event_at == "" then null else $latest_event_at end), size_bytes:$size}' \
    >> "$reports_jsonl"
}

if [ -n "$CHAIN_RUN_ROOT" ]; then
  append_run "$CHAIN_RUN_ROOT"
elif [ -d "$CHAIN_RUNS_ROOT" ]; then
  find "$CHAIN_RUNS_ROOT" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort | while IFS= read -r state; do
    append_run "$(dirname "$state")"
  done
fi

jq -n \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --arg source_root "${CHAIN_RUN_ROOT:-$CHAIN_RUNS_ROOT}" \
  --arg project_filter "$PROJECT_FILTER" \
  --arg public_safe_trigger "$PUBLIC_SAFE_TRIGGER" \
  --argjson public_safe "$PUBLIC_SAFE" \
  --slurpfile states "$states_jsonl" \
  --slurpfile events "$events_jsonl" \
  --slurpfile summaries "$summaries_jsonl" \
  --slurpfile halts "$halts_jsonl" \
  --slurpfile reports "$reports_jsonl" '
  def date_part: (. // "")[0:10];
  def in_window: (date_part >= $since and date_part <= $until);
  def counts_by(key):
    reduce .[] as $item ({}; ($item | key // "unknown" | tostring) as $k | .[$k] = ((.[$k] // 0) + 1));
  def safe_path:
    if $public_safe then
      if . == null then null
      else (. | tostring) as $p |
        if $p == "" then $p
        elif ($p | startswith("/")) then "<redacted>/" + ($p | split("/")[-1])
        else $p
        end
      end
    else . end;
  def repo_leaf: tostring | split(":")[-1] | split("/")[-1] | sub("[.]git$"; "");
  def maybe_number:
    if . == null or . == "" then null else (tonumber? // .) end;
  def matches_project($v):
    if $project_filter == "" or $v == null then false
    else
      ($project_filter | tostring | ascii_downcase) as $needle |
      ($project_filter | repo_leaf | ascii_downcase) as $needle_leaf |
      ($v | tostring) as $raw |
      (($raw | ascii_downcase) == $needle
       or ($raw | repo_leaf | ascii_downcase) == $needle
       or ($raw | repo_leaf | ascii_downcase) == $needle_leaf)
    end;
  def project_match:
    if $project_filter == "" then {matched:true, match_type:"unfiltered", source:null, value:null}
    else
      ([
        {match_type:"canonical", source:"target_project", value:(.target_project // .target_project_slug // .project // .project_slug // .run_project // .target.project // null)},
        {match_type:"canonical", source:"target_repo", value:(.target_repo // .target_repo_slug // .repo_slug // .repository // .issue_repo // null)}
      ] | map(select(matches_project(.value))) | .[0]) as $canonical |
      if $canonical != null then $canonical + {matched:true}
      else
        ([
          {match_type:"fallback_path", source:"target_repo_root", value:(.target_repo_root // null)}
        ] | map(select(matches_project(.value))) | .[0]) as $fallback |
        if $fallback != null then $fallback + {matched:true}
        else {matched:false, match_type:"none", source:null, value:null}
        end
      end
    end;
  def timing_value($k):
    (.execution_telemetry.timing[$k]
     // .execution_telemetry.timings[$k]
     // .execution_telemetry.phases[$k]
     // (if $k == "control_plane_overhead_ms" then .execution_telemetry.routing.control_plane.scheduler_overhead_ms else null end)
     // empty)
    | tonumber? // empty;
  def token_total:
    (.tokens // null) as $t |
    if $t == null then null
    elif ($t | type) == "number" then $t
    elif ($t | type) == "object" then ($t.total // $t.total_tokens // $t.usage.total_tokens // null)
    else null
    end;
  def bad_outcome:
    ((.outcome // .status // "") | tostring | test("fail|error"; "i"));
  def lines($v):
    if $v == null then []
    elif ($v | type) == "array" then [$v[] | tostring]
    elif ($v | type) == "object" then [$v | tojson]
    else [$v | tostring]
    end;
  def latest_report_source_at($state; $report):
    [($state.updated_at // ""), ($report.latest_event_at // "")]
    | map(select(. != ""))
    | max // "";
  def report_freshness($state; $report):
    if (($report.exists // false) | not) then "missing"
    elif (($report.generated_at // "") == "") then "unknown"
    elif (latest_report_source_at($state; $report) != "" and (($report.generated_at // "") < latest_report_source_at($state; $report))) then "stale"
    else "fresh"
    end;

  [ $states[] | select((.started_at // .updated_at // .created_at // "") | in_window) ] as $window_states |
  [ $window_states[] | project_match as $match | select($match.matched) | . + {__project_match:$match} ] as $selected_states |
  [ $selected_states[].__run_root ] as $roots |
  [ $events[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_events |
  [ $summaries[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_summaries |
  [ $halts[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_halts |
  [ $reports[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_reports |
  [ $selected_states[].chains[]?.issues[]? ] as $issues |
  [ $selected_events[] | select((.event // "") == "chain_review_completed") ] as $reviews |
  [ $reviews[] | {__run_root, task, status:(.status // .data.status // "unknown"), verdict:(.data.verdict // .status // .data.status // "unknown"), pr_url:(.data.pr_url // null), duration_s:(.data.duration_s // null)} ] as $review_rows |
  [ $selected_states[] as $state |
    ([ ($state.phase_reviews // [])[]? ]) as $state_reviews |
    if ($state_reviews | length) > 0 then
      $state_reviews[] | . + {__run_root:$state.__run_root}
    else
      $selected_events[]
      | select(.__run_root == $state.__run_root and (.event // "") == "chain_phase_review_completed")
      | {
          __run_root:$state.__run_root,
          kind:(.data.kind // .kind // "phase"),
          boundary_id:(.data.boundary_id // null),
          verdict:(.data.verdict // .status // "unknown"),
          review:(.data.review // null),
          review_host:(.data.review_host // null),
          issue_run_id:(.issue_run_id // .data.issue_run_id // null)
        }
    end
  ] as $phase_review_rows |
  [ $selected_states[] as $state |
    ([ $selected_halts[] | select(.__run_root == $state.__run_root) ]) as $file_halts |
    if ($file_halts | length) > 0 then
      $file_halts[]
    else
      (($state.halt_records // [])[]? | . + {__run_root:$state.__run_root})
    end
  ] as $halt_rows |
  [ $selected_states[] as $state |
    $state.__run_root as $root |
    $state.chains[]? as $chain |
    $chain.issues[]? as $issue |
    (($issue.issue_run_id // $issue.provenance.session.issue_run_id // "") | tostring) as $issue_run_id |
    (($issue.issue_number // $issue.number // $issue.issue // "") | tostring) as $issue_no_s |
    [ $selected_summaries[]
      | select(.__run_root == $root)
      | select(
          ($issue_run_id != "" and ((.issue_run_id // "") | tostring) == $issue_run_id)
          or ($issue_no_s != "" and ((.issue_number // .number // .issue // "") | tostring) == $issue_no_s)
        )
    ] as $issue_summaries |
    [ $halt_rows[]
      | select(.__run_root == $root)
      | select(
          ($issue_run_id != "" and ((.issue_run_id // "") | tostring) == $issue_run_id)
          or ($issue_no_s != "" and ((.issue_number // .number // .issue // "") | tostring) == $issue_no_s)
        )
    ] as $issue_halts |
    [ $phase_review_rows[]
      | select(.__run_root == $root)
      | select($issue_run_id != "" and ((.issue_run_id // "") | tostring) == $issue_run_id)
    ] as $issue_phase_reviews |
    {
      run_id:($state.run_id // "unknown"),
      chain:($chain.name // $chain.chain // "unknown"),
      issue_number:($issue_no_s | maybe_number),
      issue_run_id:(if $issue_run_id == "" then null else $issue_run_id end),
      status:($issue.status // "unknown"),
      lifecycle_state:($issue.lifecycle_state // null),
      exit_code:($issue.exit_code // $issue_summaries[-1].exit_code // null),
      retry_count:(($issue.auto_retry_attempts // 0) | tonumber? // 0),
      halt_count:($issue_halts | length),
      summary_present:(($issue_summaries | length) > 0),
      summary_path:(($issue.summary // $issue_summaries[-1].__artifact_path // null) | safe_path),
      telemetry_gaps:([ $issue_summaries[].telemetry_gaps[]? ] | unique),
      phase_review_verdicts:([ $issue_phase_reviews[] | "\(.kind // "phase"):\(.verdict // "unknown")" ]),
      failure_reason:($issue.failure_reason // $issue_summaries[-1].blocked_reason // null)
    }
  ] as $issue_rows |
  [ $selected_events[] | select((.event // "") == "checkpoint_auto_created") ] as $checkpoint_creates |
  [ $selected_events[] | select((.event // "") == "checkpoint_auto_loaded") ] as $checkpoint_loads |
  [ $selected_events[] | select((.event // "") == "checkpoint_context_savings_estimated") ] as $checkpoint_savings |
  [ $selected_summaries[] | token_total | select(. != null) ] as $tokens |
  [ $selected_summaries[].telemetry_gaps[]? ] as $summary_gaps |
  [ $selected_events[] | select((.event // "") == "chain_telemetry_gap") | (.data.gap_kind // .gap_kind // "unknown") ] as $event_gaps |
  [ $selected_summaries[] | (.tests // [])[]? ] as $tests |
  [ $selected_summaries[] | (.lints // [])[]? ] as $lints |
  [ $selected_summaries[] | (.builds // [])[]? ] as $builds |
  [ $selected_summaries[].execution_telemetry? // empty ] as $execution_rows |
  [ $selected_summaries[].execution_telemetry.routing.reason_class? // empty ] as $routing_reasons |
  [ $selected_summaries[].execution_telemetry.cleanup.outcome? // empty ] as $cleanup_outcomes |
  [ $selected_summaries[].execution_telemetry.cleanup.retention_class? // empty ] as $retention_classes |
  [ $selected_summaries[].execution_telemetry.artifacts.public_classes[]? ] as $artifact_classes |
  [ $selected_summaries[].telemetry_gaps[]? | select(test("executor|worker_routing|artifact_evidence|cleanup_telemetry")) ] as $execution_gaps |
  ($selected_summaries | max_by(.duration_s // -1)?) as $slowest_summary |
  ([ $selected_summaries[].duration_s? // empty ] | add // 0) as $worker_duration_s |
  ([ $selected_summaries[].files_changed? // empty ] | add // 0) as $files_changed |
  (if ($tokens | length) == 0 then null else ($tokens | add) end) as $tokens_total |
  {
    schema_version: 1,
    kind: "studio_chain_telemetry_digest",
    created_at: $created_at,
    window: {since: $since, until: $until},
    source: {root: ($source_root | safe_path), public_safe: ($public_safe == true or $public_safe == 1), public_safe_trigger: $public_safe_trigger},
    filter: {
      project: (if $project_filter == "" then null else ($project_filter | safe_path) end),
      matched_runs: ($selected_states | length),
      excluded_runs: (($window_states | length) - ($selected_states | length)),
      match_sources: ([ $selected_states[].__project_match | select(.match_type != "unfiltered") | {source:(.match_type + ":" + .source)} ] | counts_by(.source)),
      fallback_path_matches: ([ $selected_states[].__project_match | select(.match_type == "fallback_path") ] | length),
      path_fallback_reported: ([ $selected_states[].__project_match | select(.match_type == "fallback_path") ] | length > 0)
    },
    counters: {
      runs_total: ($selected_states | length),
      runs_by_status: ($selected_states | counts_by(.status)),
      issues_total: ($issues | length),
      issues_by_status: ($issues | counts_by(.status)),
      worker_summaries_total: ($selected_summaries | length),
      worker_exit_nonzero: ([ $selected_summaries[] | select((.exit_code // 0) != 0) ] | length),
      hosts: ($selected_summaries | counts_by(.host)),
      models_missing: ([ $selected_summaries[] | select((.model // .model_name // null) == null) ] | length),
      tokens_total: $tokens_total,
      token_reports: ($tokens | length),
      worker_duration_s: $worker_duration_s,
      avg_worker_duration_s: (if ($selected_summaries | length) == 0 then null else ($worker_duration_s / ($selected_summaries | length)) end),
      files_changed: $files_changed,
      additions: ([ $selected_summaries[].additions? // empty ] | add // 0),
      deletions: ([ $selected_summaries[].deletions? // empty ] | add // 0),
      generated_file_count: ([ $selected_summaries[].generated_file_count? // empty ] | add // 0),
      seconds_per_file_changed: (if $files_changed == 0 then null else ($worker_duration_s / $files_changed) end),
      tokens_per_file_changed: (if $tokens_total == null or $files_changed == 0 then null else ($tokens_total / $files_changed) end),
      slowest_issue: (if $slowest_summary == null then null else {issue_number: ($slowest_summary.issue_number // null), duration_s: ($slowest_summary.duration_s // null), run_id: ($slowest_summary.run_id // null)} end),
      reviews_total: ($reviews | length),
      review_passes: ([ $reviews[] | select((.status // .data.status // "") == "completed") ] | length),
      review_failures: ([ $reviews[] | select((.status // .data.status // "") != "completed") ] | length),
      review_verdict_counts: ($review_rows | counts_by(.verdict)),
      phase_reviews_total: ($phase_review_rows | length),
      phase_review_verdict_counts: ($phase_review_rows | counts_by(.verdict)),
      halt_records_total: ($halt_rows | length),
      halt_records_active: ([ $halt_rows[] | select((.status // "") == "paused" or (.status // "") == "terminated") ] | length),
      halt_records_by_class: ($halt_rows | counts_by(.halt_class)),
      retry_counts: {
        issue_auto_retries: ([ $issues[].auto_retry_attempts? // empty | tonumber? ] | add // 0),
        chain_retry_events: ([ $selected_events[] | select((.event // "") == "chain_retry_attempt") ] | length),
        resume_attempts: ([ $selected_events[] | select((.event // "") == "chain_resume_attempt_started") ] | length)
      },
      reports: {
        total: ($selected_reports | length),
        fresh: ([ $selected_states[] as $state | ($selected_reports[] | select(.__run_root == $state.__run_root)) as $report | select(report_freshness($state; $report) == "fresh") ] | length),
        stale: ([ $selected_states[] as $state | ($selected_reports[] | select(.__run_root == $state.__run_root)) as $report | select(report_freshness($state; $report) == "stale") ] | length),
        missing: ([ $selected_states[] as $state | ($selected_reports[] | select(.__run_root == $state.__run_root)) as $report | select(report_freshness($state; $report) == "missing") ] | length),
        unknown: ([ $selected_states[] as $state | ($selected_reports[] | select(.__run_root == $state.__run_root)) as $report | select(report_freshness($state; $report) == "unknown") ] | length)
      },
      checkpoint_auto_created: ($checkpoint_creates | length),
      checkpoint_auto_loaded: ($checkpoint_loads | length),
      checkpoint_drift_confirmed: ([ $checkpoint_loads[] | select((.data.drift_status // "") == "confirmed") ] | length),
      checkpoint_estimated_saved_tokens: ([ $checkpoint_savings[].data.estimated_saved_tokens? // empty ] | add // 0),
      tests_total: ($tests | length),
      tests_bad: ([ $tests[] | select(bad_outcome) ] | length),
      lints_total: ($lints | length),
      lints_bad: ([ $lints[] | select(bad_outcome) ] | length),
      builds_total: ($builds | length),
      builds_bad: ([ $builds[] | select(bad_outcome) ] | length),
      event_counts: ($selected_events | counts_by(.event)),
      stage_counts: ($selected_events | counts_by(.stage)),
      telemetry_gap_counts: (($summary_gaps + $event_gaps) | map({gap: ., one: 1}) | counts_by(.gap)),
      execution_telemetry: {
        reports: ($execution_rows | length),
        implementation_executors: ([ $selected_summaries[] | (.execution_telemetry.executors.implementation.executor // .execution_telemetry.executors.implementation.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        build_executors: ([ $selected_summaries[] | (.execution_telemetry.executors.build.executor // .execution_telemetry.executors.build.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        test_executors: ([ $selected_summaries[] | (.execution_telemetry.executors.test.executor // .execution_telemetry.executors.test.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        review_executors: ([ $selected_summaries[] | (.execution_telemetry.executors.review.executor // .execution_telemetry.executors.review.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        release_executors: ([ $selected_summaries[] | (.execution_telemetry.executors.release.executor // .execution_telemetry.executors.release.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        routing_reason_classes: ($routing_reasons | map({reason: ., one: 1}) | counts_by(.reason)),
        cleanup_outcomes: ($cleanup_outcomes | map({outcome: ., one: 1}) | counts_by(.outcome)),
        retention_classes: ($retention_classes | map({class: ., one: 1}) | counts_by(.class)),
        public_artifact_classes: ($artifact_classes | map({class: ., one: 1}) | counts_by(.class)),
        gap_count: ($execution_gaps | length),
        timing: {
          reports_with_timing: ([ $selected_summaries[] | select((.execution_telemetry.timing // .execution_telemetry.timings // .execution_telemetry.phases // .execution_telemetry.routing.control_plane // null) != null) ] | length),
          control_plane_overhead_ms: ([ $selected_summaries[] | timing_value("control_plane_overhead_ms") ] | add // 0),
          source_sync_s: ([ $selected_summaries[] | timing_value("source_sync_s") ] | add // 0),
          simulator_boot_s: ([ $selected_summaries[] | timing_value("simulator_boot_s") ] | add // 0),
          xcodebuild_s: ([ $selected_summaries[] | timing_value("xcodebuild_s") ] | add // 0),
          tests_s: ([ $selected_summaries[] | timing_value("tests_s") ] | add // 0),
          log_parsing_s: ([ $selected_summaries[] | timing_value("log_parsing_s") ] | add // 0),
          cleanup_s: ([ $selected_summaries[] | timing_value("cleanup_s") ] | add // 0)
        }
      },
      carryover_items: ([ $selected_summaries[] | lines(.carryover)[] ] | length),
      lesson_items: ([ $selected_summaries[] | lines(.lessons)[] ] | length)
    },
    bottlenecks: ([
      (if $slowest_summary != null then {kind:"slowest_issue", issue_number: ($slowest_summary.issue_number // null), duration_s: ($slowest_summary.duration_s // null), run_id: ($slowest_summary.run_id // null)} else empty end),
      (if ([ $tests[] | select(bad_outcome) ] | length) > 0 then {kind:"test_failures_or_flakes", count: ([ $tests[] | select(bad_outcome) ] | length)} else empty end),
      (if ([ ($summary_gaps + $event_gaps)[] | select(. == "tokens") ] | length) > 0 then {kind:"missing_token_telemetry", count: ([ ($summary_gaps + $event_gaps)[] | select(. == "tokens") ] | length)} else empty end),
      (if ($execution_gaps | length) > 0 then {kind:"ios_execution_telemetry_gaps", count:($execution_gaps | length)} else empty end)
    ]),
    runs: [
      $selected_states[] as $state |
      $state.__run_root as $root |
      [ $selected_events[] | select(.__run_root == $root) ] as $run_events |
      [ $selected_summaries[] | select(.__run_root == $root) ] as $run_summaries |
      [ $halt_rows[] | select(.__run_root == $root) ] as $run_halts |
      [ $phase_review_rows[] | select(.__run_root == $root) ] as $run_phase_reviews |
      [ $review_rows[] | select(.__run_root == $root) ] as $run_reviews |
      [ $selected_reports[] | select(.__run_root == $root) ] as $run_reports |
      ($run_reports[0] // {path:($state.report // null), exists:false, mtime:null, generated_at:null, generated_at_source:null, latest_event_at:null, size_bytes:0}) as $report |
      (report_freshness($state; $report)) as $report_freshness |
      [ $run_summaries[].telemetry_gaps[]? ] as $run_summary_gaps |
      [ $run_events[] | select((.event // "") == "chain_telemetry_gap") | (.data.gap_kind // .gap_kind // "unknown") ] as $run_event_gaps |
      {
        run_id: ($state.run_id // "unknown"),
        manifest: ($state.manifest // "unknown" | safe_path),
        target_repo_root: ($state.target_repo_root // null | safe_path),
        issue_repo: ($state.issue_repo // null),
        project_match: {
          type:($state.__project_match.match_type // "unknown"),
          source:($state.__project_match.source // null),
          value:($state.__project_match.value | safe_path)
        },
        status: ($state.status // "unknown"),
        started_at: ($state.started_at // null),
        updated_at: ($state.updated_at // null),
        report: {
          path:($report.path | safe_path),
          exists:($report.exists // false),
          mtime:($report.mtime // null),
          generated_at:($report.generated_at // null),
          generated_at_source:($report.generated_at_source // null),
          latest_event_at:($report.latest_event_at // null),
          state_status:($state.status // null),
          state_updated_at:($state.updated_at // null),
          latest_source_at:(latest_report_source_at($state; $report)),
          stale:($report_freshness == "stale"),
          freshness:$report_freshness
        },
        issues: ([ $state.chains[]?.issues[]? ] | length),
        halt_counts: {
          total:($run_halts | length),
          active:([ $run_halts[] | select((.status // "") == "paused" or (.status // "") == "terminated") ] | length),
          by_class:($run_halts | counts_by(.halt_class))
        },
        retry_counts: {
          issue_auto_retries:([ $state.chains[]?.issues[]?.auto_retry_attempts? // empty | tonumber? ] | add // 0),
          chain_retry_events:([ $run_events[] | select((.event // "") == "chain_retry_attempt") ] | length),
          resume_attempts:([ $run_events[] | select((.event // "") == "chain_resume_attempt_started") ] | length)
        },
        telemetry_gap_counts:(($run_summary_gaps + $run_event_gaps) | map({gap: .}) | counts_by(.gap)),
        review_verdict_counts:($run_reviews | counts_by(.verdict)),
        phase_review_verdict_counts:($run_phase_reviews | counts_by(.verdict))
      }
    ],
    issues: $issue_rows
  }
' > "$digest_json"

if [ "$FORMAT" = "json" ]; then
  cat "$digest_json"
  exit 0
fi

jq -r '
  def count_table($obj):
    if (($obj // {}) | length) == 0 then "- none"
    else ($obj | to_entries | sort_by(.key)[] | "- \(.key): \(.value)")
    end;
  "# Studio Chain Telemetry Digest",
  "",
  "- Window: \(.window.since) through \(.window.until)",
  "- Project filter: \(.filter.project // "none")",
  "- Public-safe: \(.source.public_safe) (\(.source.public_safe_trigger))",
  (if .filter.path_fallback_reported then "- Project match fallback: path-derived target repo root used for at least one run" else empty end),
  "- Runs: \(.counters.runs_total)",
  "- Issues: \(.counters.issues_total)",
  "- Worker summaries: \(.counters.worker_summaries_total)",
  "- Worker wall-clock: \(.counters.worker_duration_s)s",
  "- Reviews: \(.counters.review_passes) pass / \(.counters.review_failures) fail",
  "- Halt records: \(.counters.halt_records_total) total / \(.counters.halt_records_active) active",
  "- Retries: \(.counters.retry_counts.issue_auto_retries) issue auto / \(.counters.retry_counts.chain_retry_events) chain / \(.counters.retry_counts.resume_attempts) resume",
  "- Reports: \(.counters.reports.fresh) fresh / \(.counters.reports.stale) stale / \(.counters.reports.missing) missing / \(.counters.reports.unknown) unknown",
  "- Checkpoints: \(.counters.checkpoint_auto_created) created / \(.counters.checkpoint_auto_loaded) loaded, \(.counters.checkpoint_drift_confirmed) confirmed drift, ~\(.counters.checkpoint_estimated_saved_tokens) tokens saved",
  "- Tests/lints/builds: \(.counters.tests_bad)/\(.counters.tests_total) bad tests, \(.counters.lints_bad)/\(.counters.lints_total) bad lints, \(.counters.builds_bad)/\(.counters.builds_total) bad builds",
  "- Tokens: \(if .counters.tokens_total == null then "missing" else (.counters.tokens_total | tostring) end) across \(.counters.token_reports) summaries",
  "- Churn: \(.counters.files_changed) files, +\(.counters.additions)/-\(.counters.deletions), generated \(.counters.generated_file_count)",
  "- Efficiency: avg \(.counters.avg_worker_duration_s // "missing")s/issue, \(if .counters.seconds_per_file_changed == null then "missing" else (.counters.seconds_per_file_changed | tostring) end)s/file, \(if .counters.tokens_per_file_changed == null then "missing" else (.counters.tokens_per_file_changed | tostring) end) tokens/file",
  "- iOS execution telemetry: \(.counters.execution_telemetry.reports) reports, \(.counters.execution_telemetry.gap_count) routing/cleanup/executor/artifact gaps",
  "",
  "## Bottlenecks",
  "",
  (if (.bottlenecks | length) == 0 then "- none"
   else .bottlenecks[] |
     if .kind == "slowest_issue" then "- slowest issue: #\(.issue_number // "unknown") at \(.duration_s // "unknown")s"
     elif .kind == "test_failures_or_flakes" then "- test failures/flakes: \(.count)"
     elif .kind == "missing_token_telemetry" then "- missing token telemetry: \(.count)"
     else "- \(.kind): \(.count // "n/a")"
     end
   end),
  "",
  "## iOS Execution",
  "",
  "Implementation executors:",
  count_table(.counters.execution_telemetry.implementation_executors),
  "",
  "Build executors:",
  count_table(.counters.execution_telemetry.build_executors),
  "",
  "Test executors:",
  count_table(.counters.execution_telemetry.test_executors),
  "",
  "Review executors:",
  count_table(.counters.execution_telemetry.review_executors),
  "",
  "Release executors:",
  count_table(.counters.execution_telemetry.release_executors),
  "",
  "Routing reason classes:",
  count_table(.counters.execution_telemetry.routing_reason_classes),
  "",
  "Cleanup outcomes:",
  count_table(.counters.execution_telemetry.cleanup_outcomes),
  "",
  "Retention classes:",
  count_table(.counters.execution_telemetry.retention_classes),
  "",
  "Public artifact classes:",
  count_table(.counters.execution_telemetry.public_artifact_classes),
  "",
  "## Status Counters",
  "",
  "Runs:",
  count_table(.counters.runs_by_status),
  "",
  "Issues:",
  count_table(.counters.issues_by_status),
  "",
  "Halts:",
  count_table(.counters.halt_records_by_class),
  "",
  "Review verdicts:",
  count_table(.counters.review_verdict_counts),
  "",
  "Phase review verdicts:",
  count_table(.counters.phase_review_verdict_counts),
  "",
  "## Event Counters",
  "",
  count_table(.counters.event_counts),
  "",
  "## Telemetry Gaps",
  "",
  count_table(.counters.telemetry_gap_counts),
  "",
  "## Runs",
  "",
  (if (.runs | length) == 0 then "No chain runs matched the window."
   else
     "| Run | Status | Manifest | Issues | Halts | Retries | Gaps | Report | Report Generated | Latest Event | State Status | Project Match |",
     "|---|---|---|---:|---:|---:|---|---|---|---|---|---|",
     (.runs[] |
       ([.telemetry_gap_counts // {} | to_entries[] | "\(.key):\(.value)"] | join(", ")) as $gaps |
       "| \(.run_id) | \(.status) | \(.manifest // "missing") | \(.issues) | \(.halt_counts.total) | \(.retry_counts.issue_auto_retries + .retry_counts.chain_retry_events + .retry_counts.resume_attempts) | \(if $gaps == "" then "none" else $gaps end) | \(.report.freshness) | \(.report.generated_at // "missing") | \(.report.latest_event_at // "none") | \(.report.state_status // "unknown") | \(.project_match.type):\(.project_match.source // "none") |")
   end)
  ,
  "",
  "## Issues",
  "",
  (if (.issues | length) == 0 then "No issues matched the selected runs."
   else
     "| Run | Chain | Issue | Status | Retries | Halts | Gaps | Phase Reviews | Summary |",
     "|---|---|---:|---|---:|---:|---|---|---|",
     (.issues[] |
       "| \(.run_id) | \(.chain) | #\(.issue_number // "unknown") | \(.status) | \(.retry_count) | \(.halt_count) | \(if ((.telemetry_gaps // []) | length) == 0 then "none" else ((.telemetry_gaps // []) | join(", ")) end) | \(if ((.phase_review_verdicts // []) | length) == 0 then "none" else ((.phase_review_verdicts // []) | join(", ")) end) | \(if .summary_present then "present" else "missing" end) |")
   end)
' "$digest_json"
