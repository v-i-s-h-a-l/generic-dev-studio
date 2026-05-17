#!/usr/bin/env bash
# studio-chain-doctor.sh - read-only recovery recommendation for a chain run.
#
# Usage:
#   scripts/studio-chain-doctor.sh --run <run_id> [--format markdown|json] [--public-safe]
#   scripts/studio-chain-doctor.sh --chain-run-root <dir> [--format markdown|json] [--public-safe]

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

RUN_ID=""
CHAIN_RUN_ROOT=""
CHAIN_RUNS_ROOT=""
FORMAT="markdown"
PUBLIC_SAFE=0

usage() {
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

file_mtime_epoch() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || printf '0\n'
}

epoch_to_iso() {
  local epoch="$1"
  [ -n "$epoch" ] || epoch=0
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN_ID="${2:?--run requires a run id}"; shift 2 ;;
    --run=*) RUN_ID="${1#--run=}"; shift ;;
    --chain-run-root) CHAIN_RUN_ROOT="${2:?--chain-run-root requires a directory}"; shift 2 ;;
    --chain-run-root=*) CHAIN_RUN_ROOT="${1#--chain-run-root=}"; shift ;;
    --chain-runs-root) CHAIN_RUNS_ROOT="${2:?--chain-runs-root requires a directory}"; shift 2 ;;
    --chain-runs-root=*) CHAIN_RUNS_ROOT="${1#--chain-runs-root=}"; shift ;;
    --format) FORMAT="${2:?--format requires markdown or json}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --public-safe) PUBLIC_SAFE=1; shift ;;
    -h|--help) usage ;;
    *)
      if [ -z "$RUN_ID" ] && [ -z "$CHAIN_RUN_ROOT" ]; then
        RUN_ID="$1"
        shift
      else
        printf 'studio-chain-doctor: unknown arg: %s\n' "$1" >&2
        usage
      fi
      ;;
  esac
done

case "$FORMAT" in
  markdown|json) ;;
  *) printf 'studio-chain-doctor: --format must be markdown or json\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'studio-chain-doctor: jq required\n' >&2; exit 2; }

if [ -z "$CHAIN_RUN_ROOT" ]; then
  [ -n "$RUN_ID" ] || usage
  if [ -z "$CHAIN_RUNS_ROOT" ]; then
    parent_home=$(resolve_parent_home_for_github)
    project_root=$(HOME="$parent_home" resolve_project_root_for generic-dev-studio)
    CHAIN_RUNS_ROOT="$project_root/chain-runs"
  fi
  CHAIN_RUN_ROOT="$CHAIN_RUNS_ROOT/$RUN_ID"
fi

STATE_JSON="$CHAIN_RUN_ROOT/state.json"
EVENTS_JSONL="$CHAIN_RUN_ROOT/events.jsonl"
HALT_DIR="$CHAIN_RUN_ROOT/halt-records"
[ -f "$STATE_JSON" ] || { printf 'studio-chain-doctor: run state not found: %s\n' "$STATE_JSON" >&2; exit 2; }

[ -n "$RUN_ID" ] || RUN_ID=$(jq -r '.run_id // empty' "$STATE_JSON")
[ -n "$RUN_ID" ] || { printf 'studio-chain-doctor: run state has no run_id: %s\n' "$STATE_JSON" >&2; exit 2; }

TMPDIR_DOCTOR=$(mktemp -d -t studio-chain-doctor.XXXXXX)
trap 'rm -rf "$TMPDIR_DOCTOR"' EXIT

events_jsonl="$TMPDIR_DOCTOR/events.jsonl"
halts_jsonl="$TMPDIR_DOCTOR/halts.jsonl"
drifts_jsonl="$TMPDIR_DOCTOR/drifts.jsonl"
warnings_jsonl="$TMPDIR_DOCTOR/read-warnings.jsonl"
native_children_jsonl="$TMPDIR_DOCTOR/native-parent-children.jsonl"
doctor_json="$TMPDIR_DOCTOR/doctor.json"
: > "$events_jsonl"
: > "$halts_jsonl"
: > "$drifts_jsonl"
: > "$warnings_jsonl"
: > "$native_children_jsonl"

record_read_warning() {
  local artifact="$1" reason_id="$2" summary="$3"
  jq -cn --arg artifact "$artifact" --arg reason_id "$reason_id" --arg summary "$summary" \
    '{artifact:$artifact, reason_id:$reason_id, summary:$summary}' >> "$warnings_jsonl"
  printf 'studio-chain-doctor: warning: %s: %s\n' "$reason_id" "$artifact" >&2
}

record_native_parent_children() {
  local parent_issue="$1" repo="$2" parent_state="$3" status="$4" reason_id="$5" summary="$6" children_file="${7:-}"
  if [ -n "$children_file" ] && [ -f "$children_file" ]; then
    jq -cn \
      --argjson parent_issue "$parent_issue" \
      --arg repo "$repo" \
      --arg parent_state "$parent_state" \
      --arg status "$status" \
      --arg reason_id "$reason_id" \
      --arg summary "$summary" \
      --slurpfile children "$children_file" \
      '{
        parent_issue:$parent_issue,
        repo:(if $repo == "" then null else $repo end),
        parent_state:(if $parent_state == "" then null else $parent_state end),
        status:$status,
        reason_id:(if $reason_id == "" then null else $reason_id end),
        summary:(if $summary == "" then null else $summary end),
        children:($children[0] // [])
      }' >> "$native_children_jsonl"
  else
    jq -cn \
      --argjson parent_issue "$parent_issue" \
      --arg repo "$repo" \
      --arg parent_state "$parent_state" \
      --arg status "$status" \
      --arg reason_id "$reason_id" \
      --arg summary "$summary" \
      '{
        parent_issue:$parent_issue,
        repo:(if $repo == "" then null else $repo end),
        parent_state:(if $parent_state == "" then null else $parent_state end),
        status:$status,
        reason_id:(if $reason_id == "" then null else $reason_id end),
        summary:(if $summary == "" then null else $summary end),
        children:[]
      }' >> "$native_children_jsonl"
  fi
}

if [ -f "$EVENTS_JSONL" ]; then
  if ! jq -c . "$EVENTS_JSONL" > "$events_jsonl" 2>/dev/null; then
    : > "$events_jsonl"
    record_read_warning "$EVENTS_JSONL" telemetry_artifact_malformed "event log was not parseable JSONL"
  fi
fi

jq -c '(.halt_records // [])[]? | . + {__source:"state"}' "$STATE_JSON" >> "$halts_jsonl"
if [ -d "$HALT_DIR" ]; then
  while IFS= read -r halt; do
    [ -n "$halt" ] || continue
    if ! jq -c --arg path "$halt" '. + {path:(.path // $path), __artifact_path:$path, __source:"file"}' "$halt" >> "$halts_jsonl" 2>/dev/null; then
      record_read_warning "$halt" telemetry_artifact_malformed "halt record was not parseable JSON"
    fi
  done <<EOF
$(find "$HALT_DIR" -type f -name '*.json' 2>/dev/null | sort)
EOF
fi

if [ -d "$CHAIN_RUN_ROOT" ]; then
  while IFS= read -r drift; do
    [ -n "$drift" ] || continue
    if ! jq -c --arg path "$drift" '. + {path:(.path // $path), __artifact_path:$path}' "$drift" >> "$drifts_jsonl" 2>/dev/null; then
      record_read_warning "$drift" telemetry_artifact_malformed "checkpoint drift artifact was not parseable JSON"
    fi
  done <<EOF
$(find "$CHAIN_RUN_ROOT" -maxdepth 1 -type f -name 'checkpoint-drift-*.json' 2>/dev/null | sort)
EOF
fi
while IFS= read -r drift; do
  [ -n "$drift" ] || continue
  [ -r "$drift" ] || continue
  if ! jq -c --arg path "$drift" '. + {path:(.path // $path), __artifact_path:$path}' "$drift" >> "$drifts_jsonl" 2>/dev/null; then
    record_read_warning "$drift" telemetry_artifact_malformed "checkpoint drift artifact was not parseable JSON"
  fi
done <<EOF
$(jq -r '(.halt_records // [])[]? | .details.drift_artifact? // empty' "$STATE_JSON" 2>/dev/null | sort -u)
EOF

report_path=$(jq -r '.report // empty' "$STATE_JSON")
report_exists=false
report_mtime_epoch=0
report_mtime_iso=""
if [ -n "$report_path" ] && [ -f "$report_path" ]; then
  report_exists=true
  report_mtime_epoch=$(file_mtime_epoch "$report_path")
  report_mtime_iso=$(epoch_to_iso "$report_mtime_epoch")
fi
now_epoch="${STUDIO_CHAIN_DOCTOR_NOW_EPOCH:-$(date -u +%s)}"
case "$now_epoch" in
  ''|*[!0-9]*) now_epoch=$(date -u +%s) ;;
esac

issue_repo=$(jq -r '.issue_repo // empty' "$STATE_JSON" 2>/dev/null || true)
while IFS= read -r parent_issue; do
  [ -n "$parent_issue" ] || continue
  if [ -n "${STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE:-}" ]; then
    fixture_parent="$TMPDIR_DOCTOR/native-fixture-$parent_issue.json"
    if jq --argjson parent_issue "$parent_issue" '[.[]? | select((.parent_issue // null) == $parent_issue)][0] // empty' \
      "$STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE" > "$fixture_parent" 2>/dev/null &&
      [ -s "$fixture_parent" ]; then
      fixture_children="$TMPDIR_DOCTOR/native-fixture-$parent_issue-children.json"
      fixture_parent_state=$(jq -r '.parent_state // empty' "$fixture_parent")
      jq '[.children[]? | {number:(.number // null), state:(.state // null), title:(.title // null), url:(.url // null)}]' "$fixture_parent" > "$fixture_children"
      record_native_parent_children "$parent_issue" "$issue_repo" "$fixture_parent_state" "readable" "" "" "$fixture_children"
    else
      record_native_parent_children "$parent_issue" "$issue_repo" "" "unreadable" "parent_native_children_fixture_missing" "native sub-issues fixture did not include this parent"
      record_read_warning "$STUDIO_CHAIN_DOCTOR_NATIVE_CHILDREN_FIXTURE" "parent_native_children_fixture_missing" "native sub-issues fixture did not include parent issue #$parent_issue"
    fi
    continue
  fi
  if [ -z "$issue_repo" ]; then
    record_native_parent_children "$parent_issue" "" "" "unreadable" "parent_native_children_repo_missing" "run state did not include issue_repo, so native sub-issues could not be read"
    record_read_warning "parent_issue#$parent_issue" "parent_native_children_repo_missing" "run state did not include issue_repo, so native sub-issues could not be read"
    continue
  fi

  parent_state=""
  if ! parent_state=$("$SCRIPT_DIR/studio-gh.sh" issue view "$parent_issue" --repo "$issue_repo" --json state --jq '.state' 2>/dev/null); then
    record_native_parent_children "$parent_issue" "$issue_repo" "" "unreadable" "parent_issue_unreadable" "parent issue state could not be read"
    record_read_warning "parent_issue#$parent_issue" "parent_issue_unreadable" "parent issue state could not be read"
    continue
  fi

  native_tmp="$TMPDIR_DOCTOR/native-$parent_issue.json"
  if ! "$SCRIPT_DIR/studio-gh.sh" api "/repos/$issue_repo/issues/$parent_issue/sub_issues" > "$native_tmp" 2>/dev/null; then
    record_native_parent_children "$parent_issue" "$issue_repo" "$parent_state" "unreadable" "parent_native_children_unreadable" "native sub-issues API membership could not be read"
    record_read_warning "parent_issue#$parent_issue/sub_issues" "parent_native_children_unreadable" "native sub-issues API membership could not be read"
    continue
  fi
  if ! jq -e 'type == "array"' "$native_tmp" >/dev/null 2>&1; then
    record_native_parent_children "$parent_issue" "$issue_repo" "$parent_state" "unreadable" "parent_native_children_malformed" "native sub-issues API response was not an array"
    record_read_warning "parent_issue#$parent_issue/sub_issues" "parent_native_children_malformed" "native sub-issues API response was not an array"
    continue
  fi
  children_tmp="$TMPDIR_DOCTOR/native-$parent_issue-children.json"
  jq '[.[] | {number:(.number // null), state:(.state // null), title:(.title // null), url:(.html_url // .url // null)}]' "$native_tmp" > "$children_tmp"
  record_native_parent_children "$parent_issue" "$issue_repo" "$parent_state" "readable" "" "" "$children_tmp"
done <<EOF
$(jq -r '.chains[]? | .parent_issue.number? // empty' "$STATE_JSON" 2>/dev/null | sort -n -u)
EOF

jq -n \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run_id "$RUN_ID" \
  --arg chain_run_root "$CHAIN_RUN_ROOT" \
  --arg state_path "$STATE_JSON" \
  --arg events_path "$EVENTS_JSONL" \
  --arg report_path "$report_path" \
  --arg report_mtime "$report_mtime_iso" \
  --argjson report_exists "$report_exists" \
  --argjson report_mtime_epoch "$report_mtime_epoch" \
  --argjson public_safe "$PUBLIC_SAFE" \
  --argjson now_epoch "$now_epoch" \
  --slurpfile state "$STATE_JSON" \
  --slurpfile events "$events_jsonl" \
  --slurpfile halts "$halts_jsonl" \
  --slurpfile drifts "$drifts_jsonl" \
  --slurpfile warnings "$warnings_jsonl" \
  --slurpfile native_parent_children "$native_children_jsonl" '
  def safe_path:
    if $public_safe then
      if . == null or . == "" then .
      else (. | tostring) as $p |
        if ($p | startswith("/")) then "<redacted>/" + ($p | split("/")[-1])
        else $p
        end
      end
    else .
    end;
  def ts_epoch: try ((. // "") | fromdateiso8601) catch 0;
  def clean: if . == null or . == "" then null else . end;
  def halt_active($run_status): ($run_status != "completed") and ((.status // "") == "paused" or (.status // "") == "terminated");
  def halt_historical($run_status): ($run_status == "completed") and ((.status // "") == "paused" or (.status // "") == "terminated");
  def halt_priority:
    if (.halt_class // "") == "fatal" then 50
    elif (.halt_class // "") == "human-needed" then 40
    elif (.halt_class // "") == "review-needed" then 30
    elif (.halt_class // "") == "recoverable" then 20
    elif (.halt_class // "") == "retryable" then 10
    else 0
    end;
  def retry_state:
    if ((.halt_class // "") != "retryable") then null
    elif (((.retry_count // 1) | tonumber? // 1) >= ((.retry_policy.human_inspection_retry_count // 3) | tonumber? // 3)) then "needs_human_inspection"
    elif (((.retry_policy.cooldown_until // .cooldown_until // .last_seen // .created_at // "") | ts_epoch) > $now_epoch) then "cooling_down"
    else "retrying"
    end;
  def issue_label:
    (.issue_context // {}) as $ctx
    | if ($ctx.issue_number // .issue_number // null) == null then null
      else "#\($ctx.issue_number // .issue_number)\(if ($ctx.title // "") == "" then "" else " " + ($ctx.title | tostring) end)"
      end;
  def details_value:
    if $public_safe then null else (.details // null) end;
  def public_halt:
    {
      path: ((.path // .__artifact_path // null) | safe_path),
      created_at: (.created_at // null),
      reason_id: (.reason_id // "unknown"),
      halt_class: (.halt_class // "unknown"),
      status: (.status // "unknown"),
      summary: (.summary // null),
      issue: issue_label,
      issue_run_id: (.issue_context.issue_run_id // .issue_run_id // null),
      retry_count: (.retry_count // null),
      retry_state: retry_state,
      cooldown_until: (.retry_policy.cooldown_until // .cooldown_until // null),
      next_safe_action: (.next_safe_action // null),
      next_command: (.next_command // null),
      details: details_value,
      details_present: ((.details // null) != null),
      coalesce_key_present: ((.coalesce_key // null) != null),
      last_observed_command: (if $public_safe then null else (.last_observed_command // null) end),
      last_observed_error: (if $public_safe then null else (.last_observed_error // null) end),
      normalized_origin: (.normalized_origin // .coalesce_key.normalized_origin // null),
      normalized_error: (if $public_safe then null else (.normalized_error // .coalesce_key.normalized_error // null) end)
    };
  def phase_public:
    {
      kind: (.kind // .data.kind // "phase"),
      boundary_id: (.boundary_id // .data.boundary_id // null),
      verdict: (.verdict // .data.verdict // .status // "unknown"),
      review_host: (.review_host // .data.review_host // null),
      review: ((.review // .data.review // .phase_review_artifact // null) | safe_path),
      artifact: ((.artifact // .data.artifact // .phase_review_artifact // null) | safe_path),
      issue_run_id: (.issue_run_id // .data.issue_run_id // null)
    };
  def drift_public:
    {
      path: ((.path // .__artifact_path // null) | safe_path),
      checkpoint_id: (.checkpoint_id // .details.checkpoint_id // null),
      drift_status: (.drift_status // .status // null),
      reason_id: (.reason_id // .reason // null),
      expected_commit: (if $public_safe then null else (.expected_commit // .details.expected_commit // null) end),
      observed_commit: (if $public_safe then null else (.observed_commit // .details.observed_commit // null) end),
      read_set_artifact: ((.read_set_artifact // .details.read_set_artifact // null) | safe_path),
      summary: (.summary // null)
    };
  def warning_public:
    {
      artifact: ((.artifact // null) | safe_path),
      reason_id: (.reason_id // "unknown"),
      summary: (.summary // null)
    };
  def issue_number: ((.number // .issue // .issue_number // null) | tonumber?);
  def generated_child_public:
    issue_number as $n
    | {
      issue_number:$n,
      issue_run_id:(.issue_run_id // null),
      status:(.status // "unknown"),
      lifecycle_state:(.lifecycle_state // null),
      closed: (((.closed // false) == true) or ((.lifecycle_state // "") == "closed")),
      integrated: ((.integrated // false) == true),
      closeout_ready: (
        ($n != null)
        and (((.closed // false) == true) or ((.lifecycle_state // "") == "closed"))
        and ((.status // "") == "completed")
        and ((.integrated // false) == true)
      ),
      blocker_reason: (
        if $n == null then "missing_issue_number"
        elif (((.closed // false) == true) or ((.lifecycle_state // "") == "closed")) | not then "child_not_closed"
        elif ((.status // "") != "completed") then "child_not_completed"
        elif ((.integrated // false) != true) then "child_unmerged"
        else null
        end
      )
    };
  def native_child_public:
    {
      issue_number:((.number // null) | tonumber?),
      state:(.state // null),
      title:(.title // null),
      url:(.url // null),
      closed:((.state // "") == "CLOSED"),
      blocker_reason:(if ((.number // null) | tonumber?) == null then "missing_issue_number" elif ((.state // "") == "CLOSED") then null else "child_not_closed" end)
    };
  def native_parent_public:
    {
      parent_issue:.parent_issue,
      repo:(.repo // null),
      parent_state:(.parent_state // null),
      status:(.status // "unreadable"),
      reason_id:(.reason_id // null),
      summary:(.summary // null),
      children:([(.children // [])[]? | native_child_public])
    };
  def report_freshness($generated_at; $latest_source_at):
    if ($report_exists | not) then "missing"
    elif (($generated_at // "") == "") then "unknown"
    elif ($latest_source_at != "" and (($generated_at // "") < $latest_source_at)) then "stale"
    else "fresh"
    end;
  def recommend($report; $active; $retry; $blocked_phase; $ambiguous_phase; $checkpoint_drift_count; $read_warning_count; $parent_closeout_drift_count):
    if $active != null then
      ($active.reason_id // "unknown") as $reason |
      ($active.halt_class // "unknown") as $class |
      if ($reason == "reviewer_blocked" or $reason == "reviewer_ambiguous" or $class == "review-needed") then
        {
          action: "review_phase_artifact",
          priority: "blocker",
          likely_root_cause: "Phase review gate requires operator judgment.",
          safest_next_action: ($active.next_safe_action // "Inspect the phase review artifact, resolve reviewer findings, rerun sibling review, then resume."),
          safest_next_command: ("inspect phase review artifact " + (($blocked_phase.review // $ambiguous_phase.review // (($active.path // "missing") | safe_path)) | tostring)),
          deferred_resume_command: ($active.next_command // null),
          reason_id: $reason
        }
      elif ($reason == "checkpoint_drift_detected" or $checkpoint_drift_count > 0) then
        {
          action: "inspect_checkpoint_drift",
          priority: "blocker",
          likely_root_cause: "Checkpoint state drift was detected before or during resume.",
          safest_next_action: ($active.next_safe_action // "Inspect the checkpoint drift artifact and read-set, realign the chain worktree or checkpoint, then resume."),
          safest_next_command: ("inspect checkpoint drift artifact " + (($active.details.drift_artifact // $active.path // "missing") | safe_path | tostring)),
          deferred_resume_command: ($active.next_command // null),
          reason_id: $reason
        }
      elif $class == "retryable" then
        ($active.retry_policy.cooldown_until // $active.cooldown_until // null) as $cooldown_until |
        if $retry == "cooling_down" then {
          action: "wait_for_cooldown",
          priority: "blocker",
          likely_root_cause: "Repeated retryable origin or network failure is still cooling down.",
          safest_next_action: "Wait for the cooldown window or inspect the origin/network before resuming.",
          safest_next_command: ("wait until " + (($cooldown_until // "cooldown expiry") | tostring) + (if ($active.next_command // null) == null then "" else "; then " + $active.next_command end)),
          deferred_resume_command: ($active.next_command // null),
          reason_id: $reason
        }
        elif $retry == "needs_human_inspection" then {
          action: "inspect_retryable_failure",
          priority: "blocker",
          likely_root_cause: "Equivalent retryable failures reached the human-inspection threshold.",
          safest_next_action: "Inspect the coalesced retry evidence before any resume.",
          safest_next_command: ("inspect halt record " + (($active.path // "missing") | safe_path | tostring)),
          deferred_resume_command: ($active.next_command // null),
          reason_id: $reason
        }
        else {
          action: "retry_after_transient_check",
          priority: "blocker",
          likely_root_cause: "Retryable infrastructure failure is no longer cooling down.",
          safest_next_action: ($active.next_safe_action // "Confirm the transient cause has recovered, then resume."),
          safest_next_command: ($active.next_command // "scripts/studio-chain-runner.sh --resume \($run_id) --yes"),
          deferred_resume_command: null,
          reason_id: $reason
        }
        end
      elif $class == "fatal" then
        {
          action: "recreate_or_replan",
          priority: "blocker",
          likely_root_cause: "Fatal halt requires a fresh human-authored recovery plan.",
          safest_next_action: ($active.next_safe_action // "Do not resume automatically; inspect the halt and prepare a fresh plan."),
          safest_next_command: "prepare fresh plan; do not resume this run automatically",
          deferred_resume_command: null,
          reason_id: $reason
        }
      else
        {
          action: "inspect_halt_then_resume",
          priority: "blocker",
          likely_root_cause: "Active typed halt blocks automatic chain progress.",
          safest_next_action: ($active.next_safe_action // "Inspect the halt record and affected artifacts before resuming."),
          safest_next_command: ($active.next_command // "scripts/studio-chain-runner.sh --resume \($run_id) --yes"),
          deferred_resume_command: null,
          reason_id: $reason
        }
      end
    elif $read_warning_count > 0 then
      {
        action: "inspect_malformed_artifacts",
        priority: "artifact",
        likely_root_cause: "One or more chain-run artifacts could not be parsed.",
        safest_next_action: "Inspect malformed private artifacts before trusting derived state or resuming.",
        safest_next_command: "inspect read warnings in the doctor output",
        deferred_resume_command: null,
        reason_id: "telemetry_artifact_malformed"
      }
    elif $checkpoint_drift_count > 0 then
      {
        action: "inspect_checkpoint_drift",
        priority: "artifact",
        likely_root_cause: "Checkpoint drift artifacts exist for this run.",
        safest_next_action: "Inspect checkpoint drift artifacts before resuming or regenerating reports.",
        safest_next_command: "inspect checkpoint drift records in the doctor output",
        deferred_resume_command: null,
        reason_id: "checkpoint_drift_detected"
      }
    elif $parent_closeout_drift_count > 0 then
      {
        action: "close_parent_issue",
        priority: "operator",
        likely_root_cause: "A chain parent remains open or Todo after all generated and native children are closed.",
        safest_next_action: "Inspect parent closeout drift records, then run the chain parent closeout path or close/update the parent issue idempotently.",
        safest_next_command: "inspect parent closeout drift records in the doctor output",
        deferred_resume_command: null,
        reason_id: "parent_closeout_drift_detected"
      }
    elif $report.freshness == "stale" then
      {
        action: "regenerate_report",
        priority: "artifact",
        likely_root_cause: "Report was generated before later state or events landed.",
        safest_next_action: "Regenerate the private report or inspect state.json/events.jsonl directly before making a resume decision.",
        safest_next_command: "scripts/studio-chain-runner.sh --regenerate-report \($run_id)",
        deferred_resume_command: null,
        reason_id: "stale_report"
      }
    elif $report.freshness == "missing" then
      {
        action: "regenerate_report",
        priority: "artifact",
        likely_root_cause: "Report artifact is missing from run state.",
        safest_next_action: "Regenerate the private report before relying on summaries.",
        safest_next_command: "scripts/studio-chain-runner.sh --regenerate-report \($run_id)",
        deferred_resume_command: null,
        reason_id: "missing_report"
      }
    else
      {
        action: "no_recovery_needed",
        priority: "none",
        likely_root_cause: "No active blocker or stale report was detected.",
        safest_next_action: "Use the current state and report; no recovery command is recommended.",
        safest_next_command: null,
        deferred_resume_command: null,
        reason_id: null
      }
    end;

  ($state[0] // {}) as $s |
  ($s.status // "unknown") as $run_status |
  [ $events[] | .created_at? // empty | select(. != "") ] as $event_times |
  ($event_times | max // "") as $latest_event_at |
  ([($s.updated_at // ""), $latest_event_at] | map(select(. != "")) | max // "") as $latest_source_at |
  ($s.report_generated_at // (if $report_mtime == "" then null else $report_mtime end)) as $report_generated_at |
  {
    path: ($report_path | clean | safe_path),
    exists: $report_exists,
    mtime: (if $report_mtime == "" then null else $report_mtime end),
    mtime_epoch: $report_mtime_epoch,
    generated_at: $report_generated_at,
    generated_at_source: (if ($s.report_generated_at // "") != "" then "state.report_generated_at" elif $report_mtime != "" then "filesystem_mtime" else null end),
    latest_event_at: (if $latest_event_at == "" then null else $latest_event_at end),
    latest_source_at: (if $latest_source_at == "" then null else $latest_source_at end),
    freshness: report_freshness($report_generated_at; $latest_source_at),
    stale: (report_freshness($report_generated_at; $latest_source_at) == "stale")
  } as $report |
  [ $halts[] | . as $h | ($h.path // $h.__artifact_path // "\($h.reason_id // "unknown"):\($h.created_at // "")") as $key | $h + {__key:$key} ] as $halt_raw |
  (reduce $halt_raw[] as $h ({}; .[$h.__key] = $h) | [.[]]) as $halt_rows |
  [ $halt_rows | to_entries[] | .value + {__index:.key} ] as $halt_rows_i |
  [ $halt_rows_i[] | select(halt_active($run_status)) ] as $active_halts_raw |
  [ $active_halts_raw[] | . + {__priority: halt_priority} ] as $active_halts_scored |
  ($active_halts_scored | sort_by(.__priority, (.created_at // ""), .__index) | last) as $active_raw |
  (if $active_raw == null then null else ($active_raw | public_halt) end) as $active_blocker |
  (if $active_raw == null then null else ($active_raw | retry_state) end) as $active_retry_state |
  [ $halt_rows_i[] | select(halt_active($run_status)) | public_halt ] as $active_halts |
  [ $halt_rows_i[] | select(halt_historical($run_status)) | public_halt ] as $historical_halts |
  [ $halt_rows_i[] | select((.status // "") == "superseded") | public_halt ] as $superseded_halts |
  ([($s.phase_reviews // [])[]? | . + {__source:"state"}]
    + [ $events[] | select((.event // "") == "chain_phase_review_completed") | {
          __source:"event",
          kind:(.data.kind // .kind // "phase"),
          boundary_id:(.data.boundary_id // null),
          verdict:(.data.verdict // .status // "unknown"),
          review:(.data.review // null),
          review_host:(.data.review_host // null),
          issue_run_id:(.issue_run_id // .data.issue_run_id // null)
        }]) as $phase_rows_raw |
  [ $phase_rows_raw[] | phase_public ] as $phase_reviews |
  ([ $phase_reviews[] | select((.verdict // "") == "blocked") ] | last) as $blocked_phase |
  ([ $phase_reviews[] | select((.verdict // "") == "ambiguous") ] | last) as $ambiguous_phase |
  [ $drifts[] | . as $d | ($d.path // $d.__artifact_path // "\($d.checkpoint_id // "unknown")") as $key | $d + {__key:$key} ] as $drift_raw |
  (reduce $drift_raw[] as $d ({}; .[$d.__key] = $d) | [.[] | drift_public]) as $checkpoint_drifts |
  ($checkpoint_drifts | length) as $checkpoint_drift_count |
  [ $warnings[] | warning_public ] as $read_warnings |
  ($read_warnings | length) as $read_warning_count |
  [ $native_parent_children[] | native_parent_public ] as $native_parent_rows |
  [ $s.chains[]?
    | select((.parent_issue.number // null) != null)
    | . as $chain
    | ($chain.parent_issue.number | tonumber?) as $parent_number
    | ([ $chain.issues[]? | generated_child_public ]) as $generated_children
    | (($native_parent_rows[]? | select(.parent_issue == $parent_number)) // {
        parent_issue:$parent_number,
        repo:($s.issue_repo // null),
        parent_state:($chain.parent_issue.state // null),
        status:"unreadable",
        reason_id:"parent_native_children_missing",
        summary:"native sub-issues were not read for this parent",
        children:[]
      }) as $native
    | ([
        $generated_children[]? | select((.closeout_ready // false) | not) | {
          set:"generated",
          issue_number:.issue_number,
          reason_id:.blocker_reason,
          status:.status,
          lifecycle_state:.lifecycle_state,
          integrated:.integrated
        }
      ] + [
        if (($native.status // "") != "readable") then {
          set:"native",
          issue_number:null,
          reason_id:($native.reason_id // "parent_native_children_unreadable"),
          status:($native.status // "unreadable"),
          lifecycle_state:null,
          integrated:null
        } else empty end
      ] + [
        $native.children[]? | select((.closed // false) | not) | {
          set:"native",
          issue_number:.issue_number,
          reason_id:.blocker_reason,
          status:.state,
          lifecycle_state:null,
          integrated:null
        }
      ]) as $blockers
    | ($chain.parent_closeout.status // "") as $closeout_status
    | ($native.parent_state // $chain.parent_issue.state // null) as $parent_state
    | ($chain.parent_issue.project_status // $chain.parent_closeout.project.fields.Status // null) as $project_status
    | {
        chain_name:($chain.name // null),
        chain_run_id:($chain.chain_run_id // null),
        parent_issue:$parent_number,
        parent_state:$parent_state,
        project_status:$project_status,
        parent_closeout_status:(if $closeout_status == "" then null else $closeout_status end),
        generated_children:$generated_children,
        native_children:$native.children,
        native_children_status:($native.status // "unreadable"),
        native_children_reason_id:($native.reason_id // null),
        blockers:$blockers,
        all_children_closeout_ready:(($blockers | length) == 0 and ($generated_children | length) > 0 and (($native.status // "") == "readable")),
        drift_detected:(
          ($closeout_status != "completed")
          and (($blockers | length) == 0)
          and (($generated_children | length) > 0)
          and (($native.status // "") == "readable")
          and (($parent_state == "OPEN") or ($project_status == "Todo"))
        )
      }
  ] as $parent_closeout_records |
  [ $parent_closeout_records[] | select(.drift_detected == true) ] as $parent_closeout_drifts |
  ($parent_closeout_drifts | length) as $parent_closeout_drift_count |
  (recommend($report; $active_raw; $active_retry_state; $blocked_phase; $ambiguous_phase; $checkpoint_drift_count; $read_warning_count; $parent_closeout_drift_count)) as $recommendation |
  {
    schema_version: 1,
    kind: "studio-chain-doctor",
    created_at: $created_at,
    source: {
      chain_run_root: ($chain_run_root | safe_path),
      state: ($state_path | safe_path),
      events: ($events_path | safe_path),
      public_safe: ($public_safe == true or $public_safe == 1)
    },
    run: {
      run_id: ($s.run_id // $run_id),
      manifest: (($s.manifest // null) | safe_path),
      status: ($s.status // "unknown"),
      failure_reason: ($s.failure_reason // null),
      started_at: ($s.started_at // null),
      updated_at: ($s.updated_at // null),
      execution_mode: ($s.execution_mode // null),
      chains: ([ $s.chains[]? ] | length),
      issues: ([ $s.chains[]?.issues[]? ] | length)
    },
    truth_state: {
      status: ($s.status // "unknown"),
      state_updated_at: ($s.updated_at // null),
      latest_event_at: (if $latest_event_at == "" then null else $latest_event_at end),
      latest_source_at: (if $latest_source_at == "" then null else $latest_source_at end),
      active_halt_count: ($active_halts | length),
      historical_halt_count: ($historical_halts | length),
      superseded_halt_count: ($superseded_halts | length),
      phase_review_counts: ($phase_reviews | group_by(.verdict) | map({key:.[0].verdict, value:length}) | from_entries),
      checkpoint_drift_count: $checkpoint_drift_count,
      parent_closeout_drift_count: $parent_closeout_drift_count,
      read_warning_count: $read_warning_count
    },
    report: $report,
    stale_artifacts: ([
      if $report.freshness == "stale" then {
        artifact:"report",
        freshness:$report.freshness,
        generated_at:$report.generated_at,
        latest_source_at:$report.latest_source_at,
        path:$report.path
      } else empty end,
      if $report.freshness == "missing" then {
        artifact:"report",
        freshness:$report.freshness,
        generated_at:null,
        latest_source_at:$report.latest_source_at,
        path:$report.path
      } else empty end
    ]),
    active_blocker: $active_blocker,
    active_halts: $active_halts,
    historical_halts: $historical_halts,
    superseded_halts: $superseded_halts,
    retry_coalescing: {
      active_retry_state: $active_retry_state,
      retry_count: ($active_blocker.retry_count // null),
      cooldown_until: ($active_blocker.cooldown_until // null),
      coalesce_key_present: ($active_blocker.coalesce_key_present // false),
      normalized_origin: ($active_blocker.normalized_origin // null)
    },
    phase_reviews: $phase_reviews,
    checkpoint_drift_records: $checkpoint_drifts,
    parent_closeout_records: $parent_closeout_records,
    parent_closeout_drifts: $parent_closeout_drifts,
    read_warnings: $read_warnings,
    recommendation: $recommendation,
    privacy: {
      classification: (if $public_safe then "public-safe-redacted" else "private-local" end),
      notes: (if $public_safe then ["local paths and private halt details are redacted"] else ["private runtime paths and details are visible"] end)
    }
  }' > "$doctor_json"

if [ "$FORMAT" = "json" ]; then
  cat "$doctor_json"
  exit 0
fi

jq -r '
  def cell($v): if $v == null or $v == "" then "missing" else ($v | tostring | gsub("\\|"; "\\|")) end;
  "# Studio Chain Doctor",
  "",
  "- Run: `\(.run.run_id)`",
  "- State: `\(.run.status)`",
  "- Report: `\(.report.freshness)` (generated `\(cell(.report.generated_at))`, latest source `\(cell(.report.latest_source_at))`)",
  "- Active blocker: `\(if .active_blocker == null then "none" else (.active_blocker.reason_id + " / " + .active_blocker.halt_class) end)`",
  "- Recommended action: `\(.recommendation.action)`",
  "- Likely root cause: \(.recommendation.likely_root_cause)",
  "- Safest next action: \(.recommendation.safest_next_action)",
  "- Safest next command: `\(cell(.recommendation.safest_next_command))`",
  (if .recommendation.deferred_resume_command == null then empty else "- Deferred resume command: `\(.recommendation.deferred_resume_command)`" end),
  "",
  "## Truth State",
  "",
  "- Updated: `\(cell(.truth_state.state_updated_at))`",
  "- Latest event: `\(cell(.truth_state.latest_event_at))`",
  "- Active halts: `\(.truth_state.active_halt_count)`",
  "- Historical halts: `\(.truth_state.historical_halt_count)`",
  "- Superseded halts: `\(.truth_state.superseded_halt_count)`",
  "- Checkpoint drift records: `\(.truth_state.checkpoint_drift_count)`",
  "- Parent closeout drift records: `\(.truth_state.parent_closeout_drift_count)`",
  "- Read warnings: `\(.truth_state.read_warning_count)`",
  "",
  "## Stale Artifacts",
  "",
  (if (.stale_artifacts | length) == 0 then "- none"
   else .stale_artifacts[] | "- \(.artifact): \(.freshness) at `\(cell(.path))`; generated `\(cell(.generated_at))`, latest source `\(cell(.latest_source_at))`"
   end),
  "",
  "## Read Warnings",
  "",
  (if (.read_warnings | length) == 0 then "- none"
   else .read_warnings[] | "- \(.reason_id): \(cell(.artifact)) - \(cell(.summary))"
   end),
  "",
  "## Active Halt Records",
  "",
  (if (.active_halts | length) == 0 then "- none"
   else
     "| Reason | Class | Retry State | Count | Cooldown Until | Issue | Next Safe Action | Artifact |",
     "|---|---|---|---:|---|---|---|---|",
     (.active_halts[] | "| \(.reason_id) | \(.halt_class) | \(cell(.retry_state)) | \(cell(.retry_count)) | \(cell(.cooldown_until)) | \(cell(.issue)) | \(cell(.next_safe_action)) | \(cell(.path)) |")
   end),
  "",
  "## Historical Halt Records",
  "",
  (if (.historical_halts | length) == 0 then "- none"
   else
     "| Reason | Class | Status | Issue | Artifact |",
     "|---|---|---|---|---|",
     (.historical_halts[] | "| \(.reason_id) | \(.halt_class) | \(.status) | \(cell(.issue)) | \(cell(.path)) |")
   end),
  "",
  "## Phase Reviews",
  "",
  (if (.phase_reviews | length) == 0 then "- none"
   else
     "| Kind | Boundary | Verdict | Review |",
     "|---|---|---|---|",
     (.phase_reviews[] | "| \(cell(.kind)) | \(cell(.boundary_id)) | \(cell(.verdict)) | \(cell(.review)) |")
   end),
  "",
  "## Checkpoint Drift",
  "",
  (if (.checkpoint_drift_records | length) == 0 then "- none"
   else
     "| Checkpoint | Status | Artifact | Read Set | Summary |",
     "|---|---|---|---|---|",
     (.checkpoint_drift_records[] | "| \(cell(.checkpoint_id)) | \(cell(.drift_status // .reason_id)) | \(cell(.path)) | \(cell(.read_set_artifact)) | \(cell(.summary)) |")
   end),
  "",
  "## Parent Closeout Drift",
  "",
  (if (.parent_closeout_records | length) == 0 then "- none"
   else
     "| Parent | Chain | Parent State | Project Status | Generated | Native | Blockers | Drift |",
     "|---|---|---|---|---:|---:|---:|---|",
     (.parent_closeout_records[] | "| #\(.parent_issue) | \(cell(.chain_name)) | \(cell(.parent_state)) | \(cell(.project_status)) | \((.generated_children // []) | length) | \((.native_children // []) | length) | \((.blockers // []) | length) | \(.drift_detected) |")
   end),
  "",
  "## Privacy",
  "",
  "- Classification: `\(.privacy.classification)`"
' "$doctor_json"
