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

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/studio-chain-telemetry-digest.sh [--days N] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--format markdown|json]
  scripts/studio-chain-telemetry-digest.sh --run <run_id> [--format markdown|json]
  scripts/studio-chain-telemetry-digest.sh --chain-run-root <dir> [--format markdown|json]

Reads private chain-run state under ~/.dev-studio/generic-dev-studio/chain-runs
and emits aggregate v1 counters plus a compact operator digest.
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

while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:?--format requires markdown|json}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
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
digest_json="$TMPDIR_DIGEST/digest.json"
: > "$states_jsonl"
: > "$events_jsonl"
: > "$summaries_jsonl"

append_run() {
  local run_root="$1" state events summaries
  state="$run_root/state.json"
  events="$run_root/events.jsonl"
  summaries="$run_root/worker-summaries"
  [ -f "$state" ] || return 0
  jq -c --arg run_root "$run_root" '. + {__run_root: $run_root}' "$state" >> "$states_jsonl"
  if [ -f "$events" ]; then
    jq -c --arg run_root "$run_root" '. + {__run_root: $run_root}' "$events" >> "$events_jsonl"
  fi
  if [ -d "$summaries" ]; then
    find "$summaries" -type f -name '*.json' | sort | while IFS= read -r summary; do
      jq -c --arg run_root "$run_root" '. + {__run_root: $run_root}' "$summary" >> "$summaries_jsonl"
    done
  fi
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
  --slurpfile states "$states_jsonl" \
  --slurpfile events "$events_jsonl" \
  --slurpfile summaries "$summaries_jsonl" '
  def date_part: (. // "")[0:10];
  def in_window: (date_part >= $since and date_part <= $until);
  def counts_by(key):
    reduce .[] as $item ({}; ($item | key // "unknown" | tostring) as $k | .[$k] = ((.[$k] // 0) + 1));
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

  [ $states[] | select((.started_at // .updated_at // .created_at // "") | in_window) ] as $selected_states |
  [ $selected_states[].__run_root ] as $roots |
  [ $events[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_events |
  [ $summaries[] | select(.__run_root as $r | $roots | index($r)) ] as $selected_summaries |
  [ $selected_states[].chains[]?.issues[]? ] as $issues |
  [ $selected_events[] | select((.event // "") == "chain_review_completed") ] as $reviews |
  [ $selected_events[] | select((.event // "") == "chain_phase_review_completed") ] as $phase_reviews |
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
    source: {root: $source_root},
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
      phase_reviews_total: (($phase_reviews | length) + ([ $selected_states[].phase_reviews[]? ] | length)),
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
        gap_count: ($execution_gaps | length)
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
      $selected_states[] |
      {
        run_id: (.run_id // "unknown"),
        manifest: (.manifest // "unknown"),
        status: (.status // "unknown"),
        started_at: (.started_at // null),
        updated_at: (.updated_at // null),
        report: (.report // null),
        issues: ([.chains[]?.issues[]?] | length)
      }
    ]
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
  "- Runs: \(.counters.runs_total)",
  "- Issues: \(.counters.issues_total)",
  "- Worker summaries: \(.counters.worker_summaries_total)",
  "- Worker wall-clock: \(.counters.worker_duration_s)s",
  "- Reviews: \(.counters.review_passes) pass / \(.counters.review_failures) fail",
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
     "| Run | Status | Issues | Report |",
     "|---|---|---:|---|",
     (.runs[] | "| \(.run_id) | \(.status) | \(.issues) | \(.report // "missing") |")
   end)
' "$digest_json"
