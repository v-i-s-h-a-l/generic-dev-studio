#!/usr/bin/env bash
# manager-composite-chain.sh — explicit composite-chain init/status front door.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VALIDATE_CONTRACT="$SCRIPT_DIR/validate-contract.sh"

# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=scripts/lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=scripts/lib-manager-context-header.sh
. "$SCRIPT_DIR/lib-manager-context-header.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-composite-chain.sh init --manifest <composite.yaml> [--run-id <uuidv7>] [--json]
  scripts/manager-composite-chain.sh plan-active-child (--state <path>|--run-id <uuidv7>) [--json]
  scripts/manager-composite-chain.sh status (--state <path>|--run-id <uuidv7>) [--json]
  scripts/manager-composite-chain.sh validate-state --state <path>
  scripts/manager-composite-chain.sh validate-manifest --manifest <composite.yaml>

MVP input is an explicit `kind: composite-chain` manifest. Parent issue text
parsing is unsupported; pass a manifest instead.

Preferred user-facing entrypoint:
  /dev-studio manager composite-chain ...
EOF
  exit 2
}

fail() {
  printf 'manager-composite-chain: %s\n' "$1" >&2
  exit "${2:-1}"
}

require_tools() {
  command -v jq >/dev/null 2>&1 || fail "jq required" 2
  command -v yq >/dev/null 2>&1 || fail "yq required" 2
}

reject_parent_issue_parsing() {
  fail "parent issue parsing is unsupported in the composite-chain MVP; pass --manifest <kind: composite-chain>." 2
}

state_root() {
  local queue state_dir
  queue=$(resolve_push_queue) || return 1
  state_dir=$(dirname "$queue")
  printf '%s\n' "$state_dir/composite-chains"
}

state_path_for_run_id() {
  local run_id="${1:?usage: state_path_for_run_id <run-id>}" root
  validate_run_id "$run_id"
  root=$(state_root) || return 1
  printf '%s/%s/state.json\n' "$root" "$run_id"
}

github_repo_slug_from_hint() {
  local hint="$1" slug owner repo
  [ -n "$hint" ] && [ "$hint" != "null" ] || return 1
  slug=$(printf '%s' "$hint" \
    | sed -E 's#^[[:space:]]+|[[:space:]]+$##g; s#^git@github\.com:##; s#^ssh://git@github\.com/##; s#^https://github\.com/##; s#^http://github\.com/##; s#\.git$##; s#/$##')
  case "$slug" in
    */*)
      owner=${slug%%/*}
      repo=${slug#*/}
      repo=${repo%%/*}
      [ -n "$owner" ] && [ -n "$repo" ] || return 1
      printf '%s/%s\n' "$owner" "$repo"
      return 0
      ;;
  esac
  return 1
}

resolve_issue_repo_slug() {
  local remote slug
  remote=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)
  slug=$(github_repo_slug_from_hint "$remote" 2>/dev/null || true)
  if [ -n "$slug" ]; then
    printf '%s\n' "$slug"
    return 0
  fi
  printf 'v-i-s-h-a-l/generic-dev-studio\n'
}

validate_run_id() {
  local run_id="${1:?usage: validate_run_id <run-id>}"
  if [[ ! "$run_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
    fail "run id must be a lowercase UUIDv7: $run_id" 2
  fi
}

manifest_json() {
  local manifest="${1:?usage: manifest_json <manifest>}"
  yq -o=json '.' "$manifest"
}

validate_manifest() {
  local manifest="${1:?usage: validate_manifest <manifest>}" data
  [ -f "$manifest" ] || fail "manifest not found: $manifest" 2
  data=$(manifest_json "$manifest") || fail "manifest is not valid YAML: $manifest" 1

  printf '%s\n' "$data" | jq -e '
    .kind == "composite-chain" and
    .schema_version == 1 and
    .mode == "sequential" and
    (.name | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
    (.children | type == "array" and length > 0) and
    all(.children[];
      (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
      (.source_type == "issue" or .source_type == "manifest") and
      ((.source_type == "issue" and (.issue | type == "number" and . >= 1)) or
       (.source_type == "manifest" and (.manifest_path | type == "string" and length > 0)))
    )
  ' >/dev/null || fail "manifest must be kind: composite-chain, schema_version: 1, mode: sequential, with explicit issue or manifest children" 1

  printf '%s\n' "$data" | jq -e '(.children | map(.id) | unique | length) == (.children | length)' >/dev/null \
    || fail "manifest child ids must be unique" 1
}

validate_state_invariants() {
  local state_file="${1:?usage: validate_state_invariants <state>}"
  jq -e '
    . as $root
    | def terminal_before_next: .status == "completed" or .status == "skipped";
    def active_status: .status == "planning" or .status == "running";

    (.children | map(.id) | unique | length) == (.children | length)
    and ([.children[] | select(active_status)] | length) <= 1
    and ([
      range(0; (.children | length)) as $i
      | select(.children[$i].status != "pending")
      | select([range(0; $i) | $root.children[.]] | all(terminal_before_next) | not)
    ] | length == 0)
    and (
      ([.children[] | select(active_status)] | length) == 0
      or (
        .current_child_index != null
        and .current_child_id != null
        and .children[.current_child_index].id == .current_child_id
        and .children[.current_child_index] == ([.children[] | select(active_status)][0])
      )
    )
  ' "$state_file" >/dev/null || fail "state invariant validation failed: child ids, active child, ordering, or current child pointer is invalid" 1
}

validate_state() {
  local state_file="${1:?usage: validate_state <state>}"
  [ -f "$state_file" ] || fail "state not found: $state_file" 2
  "$VALIDATE_CONTRACT" composite-chain-state "$state_file" >/dev/null
  validate_state_invariants "$state_file"
}

atomic_update_state() {
  local state_file="${1:?usage: atomic_update_state <state> <jq-filter> [jq-args...]}" filter="${2:?missing jq filter}" tmp
  shift 2
  tmp="$state_file.tmp.$$"
  jq "$@" "$filter" "$state_file" > "$tmp"
  validate_state "$tmp"
  mv "$tmp" "$state_file"
}

active_child_status_count() {
  local state_file="${1:?usage: active_child_status_count <state>}"
  jq '[.children[] | select(.status == "planning" or .status == "running")] | length' "$state_file"
}

eligible_pending_child_tsv() {
  local state_file="${1:?usage: eligible_pending_child_tsv <state>}"
  jq -r '
    . as $root
    | def terminal: .status == "completed" or .status == "skipped";
    first(
      range(0; (.children | length)) as $i
      | select(
          $root.children[$i].status == "pending"
          and ([range(0; $i) as $j | $root.children[$j]] | all(terminal))
        )
      | "\($i)\t\($root.children[$i].id)"
    ) // empty
  ' "$state_file"
}

plan_result_path_for() {
  local plan_run_id="${1:?usage: plan_result_path_for <plan-run-id>}" project_root artifact_home project
  project="${STUDIO_COMPOSITE_PLAN_CHAIN_PROJECT:-generic-dev-studio}"
  artifact_home=$(resolve_parent_home_for_github)
  project_root=$(HOME="$artifact_home" resolve_project_root_for "$project")
  printf '%s/plan-chains/%s/result.json\n' "$project_root" "$plan_run_id"
}

write_halt_record() {
  local state_file="$1" child_id="$2" reason_id="$3" summary="$4" details_ref="$5" halt_record now
  now=$(iso_ts_now)
  halt_record="$(dirname "$state_file")/halts/$child_id-$reason_id.json"
  mkdir -p "$(dirname "$halt_record")"
  jq -n \
    --arg created_at "$now" \
    --arg reason_id "$reason_id" \
    --arg child_id "$child_id" \
    --arg summary "$summary" \
    --arg details_ref "$details_ref" \
    '{
      schema_version: 1,
      kind: "composite-chain-halt",
      created_at: $created_at,
      reason_id: $reason_id,
      child_id: $child_id,
      summary: $summary,
      details_ref: (if $details_ref == "" then null else $details_ref end)
    }' > "$halt_record"
  printf '%s\n' "$halt_record"
}

child_plan_command_json() {
  local state_file="$1" child_index="$2" child_id="$3" issue_repo="$4" source_type issue manifest_path project
  project="${STUDIO_COMPOSITE_PLAN_CHAIN_PROJECT:-generic-dev-studio}"
  source_type=$(jq -r --argjson idx "$child_index" '.children[$idx].source.source_type' "$state_file")
  case "$source_type" in
    issue)
      issue=$(jq -r --argjson idx "$child_index" '.children[$idx].source.issue' "$state_file")
      jq -cn \
        --arg script "${STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT:-$SCRIPT_DIR/manager-plan-chain.sh}" \
        --arg issue "$issue" \
        --arg issue_repo "$issue_repo" \
        --arg child_id "$child_id" \
        --arg repo_root "$REPO_ROOT" \
        --arg project "$project" \
        '[$script, "--issue", $issue, "--repo", $issue_repo, "--chain", $child_id, "--project", $project, "--target-repo-root", $repo_root, "--no-execute"]'
      ;;
    manifest)
      manifest_path=$(jq -r --argjson idx "$child_index" '.children[$idx].source.manifest_path' "$state_file")
      jq -cn \
        --arg script "${STUDIO_COMPOSITE_PLAN_CHAIN_SCRIPT:-$SCRIPT_DIR/manager-plan-chain.sh}" \
        --arg manifest_path "$manifest_path" \
        --arg child_id "$child_id" \
        --arg repo_root "$REPO_ROOT" \
        --arg project "$project" \
        '[$script, "--source-file", $manifest_path, "--chain", $child_id, "--project", $project, "--target-repo-root", $repo_root, "--no-execute"]'
      ;;
    *)
      fail "unsupported child source_type for planning: $source_type" 1
      ;;
  esac
}

run_child_plan_command() {
  local plan_run_id="$1" command_json="$2" stdout_path="$3" stderr_path="$4"
  local -a cmd=()
  while IFS= read -r arg; do
    cmd+=("$arg")
  done < <(printf '%s\n' "$command_json" | jq -r '.[]')
  [ "${#cmd[@]}" -gt 0 ] || fail "empty child plan command" 1
  STUDIO_MANAGER_PLAN_CHAIN_RUN_ID="$plan_run_id" "${cmd[@]}" > "$stdout_path" 2> "$stderr_path"
}

persist_planned_child_state() {
  local state_file="$1" child_index="$2" result_json="$3" now next_command
  now=$(iso_ts_now)
  next_command="/dev-studio manager composite-chain status --run-id $(jq -r '.composite_run_id' "$state_file")"
  # shellcheck disable=SC2016
  atomic_update_state "$state_file" '
    ($result[0]) as $r
    |
    .state = "child_planned"
    | .children[$idx].status = "planned"
    | .children[$idx].refs.planner_artifact = ($r.planner_artifact // null)
    | .children[$idx].refs.review_artifact = ($r.review_artifact // null)
    | .children[$idx].refs.work_chain_manifest = ($r.work_chain // null)
    | .children[$idx].refs.child_run_id = null
    | .children[$idx].refs.child_issues = ($r.created_issues // [])
    | .children[$idx].refs.parent_issue = ($r.parent_issue // null)
    | .children[$idx].refs.plan_result = $result_path
    | .children[$idx].blocked_reason = null
    | .children[$idx].updated_at = $now
    | .updated_at = $now
    | .blocked_reason = null
    | .active_halt_ref = null
    | .next_command = $next_command
  ' --argjson idx "$child_index" --slurpfile result "$result_json" --arg result_path "$result_json" --arg now "$now" --arg next_command "$next_command"
}

persist_planning_halt_state() {
  local state_file="$1" child_index="$2" child_id="$3" reason_id="$4" summary="$5" details_ref="$6" halt_record now next_command
  now=$(iso_ts_now)
  halt_record=$(write_halt_record "$state_file" "$child_id" "$reason_id" "$summary" "$details_ref")
  next_command="/dev-studio manager composite-chain status --run-id $(jq -r '.composite_run_id' "$state_file")"
  # shellcheck disable=SC2016
  atomic_update_state "$state_file" '
    .state = "halted"
    | .children[$idx].status = "halted"
    | .children[$idx].blocked_reason = {reason_id: $reason_id, summary: $summary, details_ref: (if $details_ref == "" then null else $details_ref end)}
    | .children[$idx].updated_at = $now
    | .blocked_reason = {reason_id: $reason_id, summary: $summary, details_ref: (if $details_ref == "" then null else $details_ref end)}
    | .active_halt_ref = {reason_id: $reason_id, halt_record: $halt_record, child_id: $child_id}
    | .next_command = $next_command
    | .updated_at = $now
  ' --argjson idx "$child_index" --arg reason_id "$reason_id" --arg summary "$summary" --arg details_ref "$details_ref" --arg halt_record "$halt_record" --arg child_id "$child_id" --arg now "$now" --arg next_command "$next_command"
}

write_initial_state() {
  local manifest="$1" run_id="$2" state_file="$3" now manifest_abs manifest_data next_command tmp
  manifest_abs=$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")
  now=$(iso_ts_now)
  manifest_data=$(manifest_json "$manifest")
  next_command="/dev-studio manager composite-chain status --run-id $run_id"
  tmp="$state_file.tmp.$$"
  mkdir -p "$(dirname "$state_file")"

  printf '%s\n' "$manifest_data" | jq \
    --arg run_id "$run_id" \
    --arg manifest_path "$manifest_abs" \
    --arg now "$now" \
    --arg next_command "$next_command" '
    {
      schema_version: 1,
      kind: "composite-chain-state",
      composite_run_id: $run_id,
      source_ref: {
        source_type: "manifest",
        parent_issue_url: null,
        manifest_path: $manifest_path,
        manifest_ref: .name
      },
      manifest: .,
      state: "child_ready",
      children: [
        .children
        | to_entries[]
        | {
            id: .value.id,
            ordinal: .key,
            source: (
              if .value.source_type == "issue" then
                {source_type:"issue", issue:.value.issue, issue_url:("https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/" + (.value.issue | tostring)), manifest_path:null}
              else
                {source_type:"manifest", issue:null, issue_url:null, manifest_path:.value.manifest_path}
              end
            ),
            status: "pending",
            refs: {
              planner_artifact: null,
              review_artifact: null,
              work_chain_manifest: null,
              child_run_id: null,
              issue_url: (
                if .value.source_type == "issue" then
                  "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/" + (.value.issue | tostring)
                else
                  null
                end
              ),
              pr_url: null,
              completion_summary: null
            },
            blocked_reason: null,
            idempotency_keys: {
              planning: ("composite:" + $run_id + ":child:" + .value.id + ":planning")
            },
            created_at: $now,
            updated_at: $now,
            completed_at: null
          }
      ],
      current_child_index: 0,
      current_child_id: .children[0].id,
      active_halt_ref: null,
      blocked_reason: null,
      next_command: $next_command,
      idempotency_keys: {
        state_update: ("composite:" + $run_id + ":state")
      },
      created_at: $now,
      updated_at: $now,
      completed_at: null
    }
  ' > "$tmp"

  validate_state "$tmp"
  mv "$tmp" "$state_file"
}

print_status_json() {
  local state_file="$1"
  jq --arg state_path "$state_file" '
    def active_status: .status == "planning" or .status == "running";
    {
      composite_run_id,
      state_path: $state_path,
      state,
      current_child: (
        if .current_child_index == null then null
        else .children[.current_child_index] | {id, ordinal, status, source}
        end
      ),
      completed_children: [.children[] | select(.status == "completed") | {id, ordinal}],
      remaining_children: [.children[] | select(.status == "pending") | {id, ordinal, source}],
      active_child_run_id: ([.children[] | select(active_status) | .refs.child_run_id][0] // null),
      blocked_reason,
      active_halt_ref,
      next_resume_command: .next_command
    }
  ' "$state_file"
}

print_status_text() {
  local state_file="$1"
  jq -r --arg state_path "$state_file" '
    def source_label:
      if .source.source_type == "issue" then "#" + (.source.issue | tostring)
      else .source.manifest_path
      end;
    def child_line: "- " + .id + " (" + (.ordinal | tostring) + ", " + .status + ", " + source_label + ")";
    def active_status: .status == "planning" or .status == "running";

    "Composite chain: " + .composite_run_id,
    "State path: " + $state_path,
    "State: " + .state,
    "Current child: " + (if .current_child_index == null then "none" else (.children[.current_child_index] | .id + " (" + .status + ")") end),
    "Completed children:",
    (([.children[] | select(.status == "completed") | child_line] | if length == 0 then ["- none"] else . end)[]),
    "Remaining children:",
    (([.children[] | select(.status == "pending") | child_line] | if length == 0 then ["- none"] else . end)[]),
    "Active child run id: " + (([.children[] | select(active_status) | .refs.child_run_id][0] // null) // "none"),
    "Blocked/halt reason: " + (if .blocked_reason == null then "none" else (.blocked_reason.reason_id + " — " + .blocked_reason.summary) end),
    "Next resume command: " + (.next_command // "none")
  ' "$state_file"
}

cmd_init() {
  local manifest="" run_id="" state_file="" output_json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="${2:?--manifest requires a path}"; shift 2 ;;
      --manifest=*) manifest="${1#--manifest=}"; shift ;;
      --run-id) run_id="${2:?--run-id requires a uuidv7}"; shift 2 ;;
      --run-id=*) run_id="${1#--run-id=}"; shift ;;
      --json) output_json=1; shift ;;
      --parent-issue|--parent-issue=*|--issue|--issue=*) reject_parent_issue_parsing ;;
      -h|--help) usage ;;
      *) fail "unknown init argument: $1" 2 ;;
    esac
  done
  [ -n "$manifest" ] || fail "init requires --manifest <path>" 2
  validate_manifest "$manifest"
  [ -n "$run_id" ] || run_id=$(mint_uuidv7)
  validate_run_id "$run_id"
  state_file=$(state_path_for_run_id "$run_id")
  if [ -e "$state_file" ]; then
    fail "state already exists: $state_file" 1
  fi
  manager_context_header_emit_text "$REPO_ROOT" >&2
  write_initial_state "$manifest" "$run_id" "$state_file"
  if [ "$output_json" -eq 1 ]; then
    jq -n --arg run_id "$run_id" --arg state_path "$state_file" '{composite_run_id:$run_id,state_path:$state_path,status:"initialized"}'
  else
    printf 'initialized composite chain %s\nstate: %s\n' "$run_id" "$state_file"
  fi
}

cmd_status() {
  local run_id="" state_file="" output_json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) run_id="${2:?--run-id requires a uuidv7}"; shift 2 ;;
      --run-id=*) run_id="${1#--run-id=}"; shift ;;
      --state) state_file="${2:?--state requires a path}"; shift 2 ;;
      --state=*) state_file="${1#--state=}"; shift ;;
      --json) output_json=1; shift ;;
      --parent-issue|--parent-issue=*|--issue|--issue=*) reject_parent_issue_parsing ;;
      -h|--help) usage ;;
      *) fail "unknown status argument: $1" 2 ;;
    esac
  done
  if [ -z "$state_file" ] && [ -n "$run_id" ]; then
    validate_run_id "$run_id"
    state_file=$(state_path_for_run_id "$run_id")
  fi
  [ -n "$state_file" ] || fail "status requires --state <path> or --run-id <uuidv7>" 2
  validate_state "$state_file"
  if [ "$output_json" -eq 1 ]; then
    print_status_json "$state_file"
  else
    print_status_text "$state_file"
  fi
}

cmd_plan_active_child() {
  local run_id="" state_file="" output_json=0 eligible child_index child_id now issue_repo command_json plan_run_id
  local attempt_dir stdout_path stderr_path result_json rc result_status reason_id summary details_ref final_rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) run_id="${2:?--run-id requires a uuidv7}"; shift 2 ;;
      --run-id=*) run_id="${1#--run-id=}"; shift ;;
      --state) state_file="${2:?--state requires a path}"; shift 2 ;;
      --state=*) state_file="${1#--state=}"; shift ;;
      --json) output_json=1; shift ;;
      --parent-issue|--parent-issue=*|--issue|--issue=*) reject_parent_issue_parsing ;;
      -h|--help) usage ;;
      *) fail "unknown plan-active-child argument: $1" 2 ;;
    esac
  done
  if [ -z "$state_file" ] && [ -n "$run_id" ]; then
    validate_run_id "$run_id"
    state_file=$(state_path_for_run_id "$run_id")
  fi
  [ -n "$state_file" ] || fail "plan-active-child requires --state <path> or --run-id <uuidv7>" 2
  validate_state "$state_file"

  if [ "$(jq -r '.state' "$state_file")" = "halted" ]; then
    fail "composite chain is halted; inspect blocked_reason and active_halt_ref before retrying" 1
  fi
  if [ "$(active_child_status_count "$state_file")" -gt 0 ]; then
    fail "composite chain already has an active planning/running child" 1
  fi

  eligible=$(eligible_pending_child_tsv "$state_file")
  [ -n "$eligible" ] || fail "no eligible pending child to plan" 1
  child_index=${eligible%%$'\t'*}
  child_id=${eligible#*$'\t'}
  now=$(iso_ts_now)
  run_id=$(jq -r '.composite_run_id' "$state_file")
  plan_run_id="composite-$run_id-$child_id-planning"
  attempt_dir="$(dirname "$state_file")/planning/$child_id"
  mkdir -p "$attempt_dir"
  stdout_path="$attempt_dir/manager-plan-chain.out"
  stderr_path="$attempt_dir/manager-plan-chain.err"
  result_json=$(plan_result_path_for "$plan_run_id")
  issue_repo=$(resolve_issue_repo_slug)
  command_json=$(child_plan_command_json "$state_file" "$child_index" "$child_id" "$issue_repo")

  # shellcheck disable=SC2016
  atomic_update_state "$state_file" '
    .state = "planning_child"
    | .current_child_index = $idx
    | .current_child_id = $child_id
    | .children[$idx].status = "planning"
    | .children[$idx].refs.plan_command = $command
    | .children[$idx].refs.plan_run_id = $plan_run_id
    | .children[$idx].refs.plan_stdout = $stdout_path
    | .children[$idx].refs.plan_stderr = $stderr_path
    | .children[$idx].blocked_reason = null
    | .children[$idx].updated_at = $now
    | .updated_at = $now
    | .blocked_reason = null
    | .active_halt_ref = null
    | .next_command = ("/dev-studio manager composite-chain status --run-id " + .composite_run_id)
  ' --argjson idx "$child_index" --arg child_id "$child_id" --argjson command "$command_json" --arg plan_run_id "$plan_run_id" --arg stdout_path "$stdout_path" --arg stderr_path "$stderr_path" --arg now "$now"

  set +e
  run_child_plan_command "$plan_run_id" "$command_json" "$stdout_path" "$stderr_path"
  rc=$?
  set -e

  details_ref="$result_json"
  if [ ! -f "$result_json" ]; then
    details_ref="$stderr_path"
    reason_id="child_plan_failed"
    summary="Child planning command failed before writing a manager-plan-chain result."
    [ "$rc" -eq 0 ] && summary="Child planning command did not write a manager-plan-chain result."
    persist_planning_halt_state "$state_file" "$child_index" "$child_id" "$reason_id" "$summary" "$details_ref"
    final_rc=1
  else
    result_status=$(jq -r '.status // "unknown"' "$result_json")
    if [ "$rc" -eq 0 ] && { [ "$result_status" = "ready" ] || [ "$result_status" = "executed" ]; }; then
      persist_planned_child_state "$state_file" "$child_index" "$result_json"
    else
      reason_id="child_plan_blocked"
      summary="Child planning stopped with manager-plan-chain status: $result_status."
      [ "$rc" -ne 0 ] && summary="Child planning command exited $rc with manager-plan-chain status: $result_status."
      persist_planning_halt_state "$state_file" "$child_index" "$child_id" "$reason_id" "$summary" "$details_ref"
      final_rc=1
    fi
  fi

  if [ "$output_json" -eq 1 ]; then
    print_status_json "$state_file"
  else
    print_status_text "$state_file"
  fi
  exit "$final_rc"
}

cmd_validate_state() {
  local state_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state_file="${2:?--state requires a path}"; shift 2 ;;
      --state=*) state_file="${1#--state=}"; shift ;;
      -h|--help) usage ;;
      *) fail "unknown validate-state argument: $1" 2 ;;
    esac
  done
  [ -n "$state_file" ] || fail "validate-state requires --state <path>" 2
  validate_state "$state_file"
  printf 'valid composite state: %s\n' "$state_file"
}

cmd_validate_manifest() {
  local manifest=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="${2:?--manifest requires a path}"; shift 2 ;;
      --manifest=*) manifest="${1#--manifest=}"; shift ;;
      -h|--help) usage ;;
      *) fail "unknown validate-manifest argument: $1" 2 ;;
    esac
  done
  [ -n "$manifest" ] || fail "validate-manifest requires --manifest <path>" 2
  validate_manifest "$manifest"
  printf 'valid composite manifest: %s\n' "$manifest"
}

require_tools

if [ "$#" -eq 0 ]; then
  usage
fi

case "$1" in
  init) shift; cmd_init "$@" ;;
  plan-active-child) shift; cmd_plan_active_child "$@" ;;
  status) shift; cmd_status "$@" ;;
  validate-state) shift; cmd_validate_state "$@" ;;
  validate-manifest) shift; cmd_validate_manifest "$@" ;;
  --parent-issue|--parent-issue=*|--issue|--issue=*) reject_parent_issue_parsing ;;
  -h|--help) usage ;;
  *) fail "unknown command: $1" 2 ;;
esac
