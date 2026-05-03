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
  [ $selected_summaries[] | token_total | select(. != null) ] as $tokens |
  [ $selected_summaries[].telemetry_gaps[]? ] as $summary_gaps |
  [ $selected_events[] | select((.event // "") == "chain_telemetry_gap") | (.data.gap_kind // .gap_kind // "unknown") ] as $event_gaps |
  [ $selected_summaries[] | (.tests // [])[]? ] as $tests |
  [ $selected_summaries[] | (.lints // [])[]? ] as $lints |
  [ $selected_summaries[] | (.builds // [])[]? ] as $builds |
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
      tokens_total: (if ($tokens | length) == 0 then null else ($tokens | add) end),
      token_reports: ($tokens | length),
      worker_duration_s: ([ $selected_summaries[].duration_s? // empty ] | add // 0),
      files_changed: ([ $selected_summaries[].files_changed? // empty ] | add // 0),
      additions: ([ $selected_summaries[].additions? // empty ] | add // 0),
      deletions: ([ $selected_summaries[].deletions? // empty ] | add // 0),
      generated_file_count: ([ $selected_summaries[].generated_file_count? // empty ] | add // 0),
      reviews_total: ($reviews | length),
      review_passes: ([ $reviews[] | select((.status // .data.status // "") == "completed") ] | length),
      review_failures: ([ $reviews[] | select((.status // .data.status // "") != "completed") ] | length),
      phase_reviews_total: (($phase_reviews | length) + ([ $selected_states[].phase_reviews[]? ] | length)),
      tests_total: ($tests | length),
      tests_bad: ([ $tests[] | select(bad_outcome) ] | length),
      lints_total: ($lints | length),
      lints_bad: ([ $lints[] | select(bad_outcome) ] | length),
      builds_total: ($builds | length),
      builds_bad: ([ $builds[] | select(bad_outcome) ] | length),
      event_counts: ($selected_events | counts_by(.event)),
      stage_counts: ($selected_events | counts_by(.stage)),
      telemetry_gap_counts: (($summary_gaps + $event_gaps) | map({gap: ., one: 1}) | counts_by(.gap)),
      carryover_items: ([ $selected_summaries[] | lines(.carryover)[] ] | length),
      lesson_items: ([ $selected_summaries[] | lines(.lessons)[] ] | length)
    },
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
  "- Tests/lints/builds: \(.counters.tests_bad)/\(.counters.tests_total) bad tests, \(.counters.lints_bad)/\(.counters.lints_total) bad lints, \(.counters.builds_bad)/\(.counters.builds_total) bad builds",
  "- Tokens: \(if .counters.tokens_total == null then "missing" else (.counters.tokens_total | tostring) end) across \(.counters.token_reports) summaries",
  "- Churn: \(.counters.files_changed) files, +\(.counters.additions)/-\(.counters.deletions), generated \(.counters.generated_file_count)",
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
