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
  status) shift; cmd_status "$@" ;;
  validate-state) shift; cmd_validate_state "$@" ;;
  validate-manifest) shift; cmd_validate_manifest "$@" ;;
  --parent-issue|--parent-issue=*|--issue|--issue=*) reject_parent_issue_parsing ;;
  -h|--help) usage ;;
  *) fail "unknown command: $1" 2 ;;
esac
