#!/usr/bin/env bash
# studio-chain-runner.sh - execute issue chains with capacity-scaled fresh host sessions.
#
# Usage:
#   scripts/studio-chain-runner.sh [--discover [<manifest|chain-name>] [--only <chain>]]
#   scripts/studio-chain-runner.sh <manifest|chain-name|chain-id> [--only <chain>] [--host <host>] [--dry-run] [--yes] [--parallel-chains <n|auto|1>] [--checkpoint auto|off] [--attended|--unattended]
#   scripts/studio-chain-runner.sh --auto <manifest|chain-name|chain-id> [--only <chain>] [--host <host>] [--dry-run] [--checkpoint auto|off] [--unattended]
#   scripts/studio-chain-runner.sh --explain-next <manifest|chain-name|chain-id> [--only <chain>]
#   scripts/studio-chain-runner.sh --resume <run_id> [--yes]
#   scripts/studio-chain-runner.sh --regenerate-report <run_id>
#   scripts/studio-chain-runner.sh --list
#
# Manifest shape:
#   schema_version: 1
#   chains:
#     - name: ios-v2-execution
#       source_branch: main
#       # base remains accepted as a backwards-compatible alias for source_branch.
#       branch: feature/ios-v2-execution
#       host: auto
#       approved_release_id: 0190f52a-9000-7f01-8aaa-77fe8fa99bbb
#       sync_strategy: rebase
#       rule_packs:
#         required: [source-branch-integration]
#         optional: [privacy]
#       issues: [384, 313, 223]

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CALLER_HOME="${HOME:-}"
TARGET_REPO_ROOT=""
REPO_SLUG_DEFAULT="v-i-s-h-a-l/generic-dev-studio"
REPO_SLUG="$REPO_SLUG_DEFAULT"
RUN_PATHS_CONFIGURED=0

# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-chain-git.sh
. "$SCRIPT_DIR/lib-chain-git.sh"
# shellcheck source=lib-chain-monitor-notifier.sh
. "$SCRIPT_DIR/lib-chain-monitor-notifier.sh"
# shellcheck source=lib-chain-run-state.sh
. "$SCRIPT_DIR/lib-chain-run-state.sh"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

MANIFEST=""
ONLY_CHAIN=""
HOST_OVERRIDE=""
DRY_RUN=0
YES=0
RESUME_ID=""
REGENERATE_REPORT_ID=""
DISCOVER_MODE=0
ALLOW_CLOSED_ISSUES=0
PARALLEL_CHAINS="auto"
CHECKPOINT_OVERRIDE="${STUDIO_CHAIN_CHECKPOINT:-}"
LIST_RUNS=0
AUTO_MODE=0
EXPLAIN_NEXT=0
SUPERVISOR_LOCK=""
SUPERVISOR_LOCK_ACQUIRED=0
EXECUTION_MODE="${STUDIO_CHAIN_EXECUTION_MODE:-attended}"
EXECUTION_MODE_EXPLICIT=0
RETRY_LIMIT="${STUDIO_CHAIN_RETRY_LIMIT:-2}"
RETRY_BACKOFF_SEC="${STUDIO_CHAIN_RETRY_BACKOFF_SEC:-2}"

if [ $# -eq 0 ]; then
  DISCOVER_MODE=1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_RUNS=1; shift ;;
    --discover) DISCOVER_MODE=1; shift ;;
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
    --regenerate-report) REGENERATE_REPORT_ID="${2:?--regenerate-report requires a run id}"; shift 2 ;;
    --regenerate-report=*) REGENERATE_REPORT_ID="${1#--regenerate-report=}"; shift ;;
    --parallel-chains) PARALLEL_CHAINS="${2:?--parallel-chains requires n, auto, or 1}"; shift 2 ;;
    --parallel-chains=*) PARALLEL_CHAINS="${1#--parallel-chains=}"; shift ;;
    --checkpoint) CHECKPOINT_OVERRIDE="${2:?--checkpoint requires auto or off}"; shift 2 ;;
    --checkpoint=*) CHECKPOINT_OVERRIDE="${1#--checkpoint=}"; shift ;;
    --attended) EXECUTION_MODE="attended"; EXECUTION_MODE_EXPLICIT=1; shift ;;
    --unattended) EXECUTION_MODE="unattended"; EXECUTION_MODE_EXPLICIT=1; shift ;;
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

if [ "$DISCOVER_MODE" -eq 0 ] && [ "$LIST_RUNS" -eq 0 ] && [ -z "$MANIFEST" ] && [ -z "$RESUME_ID" ] && [ -z "$REGENERATE_REPORT_ID" ]; then
  DISCOVER_MODE=1
fi

if [ "$DISCOVER_MODE" -eq 1 ] && {
  [ "$AUTO_MODE" -eq 1 ] ||
  [ "$EXPLAIN_NEXT" -eq 1 ] ||
  [ "$LIST_RUNS" -eq 1 ] ||
  [ -n "$RESUME_ID" ] ||
  [ -n "$REGENERATE_REPORT_ID" ] ||
  [ -n "$HOST_OVERRIDE" ] ||
  [ "$DRY_RUN" -eq 1 ] ||
  [ "$YES" -eq 1 ] ||
  [ "$ALLOW_CLOSED_ISSUES" -eq 1 ] ||
  [ "$PARALLEL_CHAINS" != "auto" ]
}; then
  usage
fi

if [ "$AUTO_MODE" -eq 1 ] && [ "$EXPLAIN_NEXT" -eq 1 ]; then
  printf 'studio-chain-runner: --auto and --explain-next are mutually exclusive\n' >&2
  usage
fi

if [ "$AUTO_MODE" -eq 1 ] && [ "$EXECUTION_MODE_EXPLICIT" -eq 0 ]; then
  EXECUTION_MODE="unattended"
fi

case "$EXECUTION_MODE" in
  attended|unattended) ;;
  *) printf 'studio-chain-runner: execution mode must be attended or unattended: %s\n' "$EXECUTION_MODE" >&2; exit 2 ;;
esac

if [ "$AUTO_MODE" -eq 1 ] && [ "$EXECUTION_MODE" = "attended" ]; then
  printf 'studio-chain-runner: --auto is unattended; use --explain-next for a non-mutating attended decision preview\n' >&2
  exit 2
fi

if { [ "$AUTO_MODE" -eq 1 ] || [ "$EXPLAIN_NEXT" -eq 1 ]; } && [ -n "$RESUME_ID" ]; then
  printf 'studio-chain-runner: supervisor flags cannot be combined with --resume; use --resume <run_id> --yes as the manual override path\n' >&2
  usage
fi

if [ -n "$REGENERATE_REPORT_ID" ] && {
  [ "$AUTO_MODE" -eq 1 ] ||
  [ "$EXPLAIN_NEXT" -eq 1 ] ||
  [ "$LIST_RUNS" -eq 1 ] ||
  [ "$DISCOVER_MODE" -eq 1 ] ||
  [ -n "$RESUME_ID" ] ||
  [ -n "$MANIFEST" ] ||
  [ -n "$HOST_OVERRIDE" ] ||
  [ "$DRY_RUN" -eq 1 ] ||
  [ "$ALLOW_CLOSED_ISSUES" -eq 1 ] ||
  [ "$PARALLEL_CHAINS" != "auto" ]
}; then
  printf 'studio-chain-runner: --regenerate-report cannot be combined with run, resume, discovery, or supervisor flags\n' >&2
  usage
fi

projected_state_for_read() {
  local state="$1" out="$2" events
  events=$(chain_run_state_events_path_for_state "$state")
  if ! chain_run_state_projection_file "$state" "$events" "$out" 2>/dev/null; then
    jq -n --arg run_id "$(jq -r '.run_id // "unknown"' "$state" 2>/dev/null || printf 'unknown')" \
      --arg manifest "$(jq -r '.manifest // "unknown"' "$state" 2>/dev/null || printf 'unknown')" \
      '{run_id:$run_id, manifest:$manifest, status:"projection_invalid"}' > "$out"
  fi
}

list_persisted_runs() {
  command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
  local parent_home project_root chain_root state_count view
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
    view=$(mktemp -t studio-chain-state-view.XXXXXX)
    projected_state_for_read "$state" "$view"
    jq -r --arg state "$state" '
      "| \(.run_id // "unknown") | \(.manifest // "unknown") | \(.status // "unknown") | \(.started_at // "unknown") | \(.updated_at // "unknown") | \(.report // "missing") |"
    ' "$view" 2>/dev/null || printf '| unknown | unknown | unreadable | unknown | unknown | `%s` |\n' "$state"
    rm -f "$view"
  done
}

if [ "$LIST_RUNS" -eq 1 ]; then
  list_persisted_runs
  exit 0
fi

discover_persisted_runs() {
  local parent_home project_root chain_root state_count state run_id status manifest next_command rows_tmp view
  command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
  parent_home=$(resolve_parent_home_for_github)
  project_root=$(HOME="$parent_home" resolve_project_root_for generic-dev-studio)
  chain_root="$project_root/chain-runs"

  printf '## Resumable Runs\n\n'
  if [ ! -d "$chain_root" ]; then
    printf -- '- No persisted chain runs found under `%s`.\n' "$chain_root"
    return 0
  fi

  state_count=$(find "$chain_root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$state_count" -eq 0 ]; then
    printf -- '- No persisted chain runs found under `%s`.\n' "$chain_root"
    return 0
  fi

  rows_tmp=$(mktemp -t studio-chain-discovery-runs.XXXXXX)
  while IFS= read -r state; do
    [ -n "$state" ] || continue
    [ -r "$state" ] || continue
    view=$(mktemp -t studio-chain-discovery-state.XXXXXX)
    projected_state_for_read "$state" "$view"
    run_id=$(jq -r '.run_id // "unknown"' "$view" 2>/dev/null || printf 'unknown')
    status=$(jq -r '.status // "unknown"' "$view" 2>/dev/null || printf 'unknown')
    if [ "$status" = "completed" ] || [ "$status" = "archived" ]; then
      rm -f "$view"
      continue
    fi
    manifest=$(jq -r '.manifest // "unknown"' "$view" 2>/dev/null || printf 'unknown')
    next_command=$(jq -r --arg run_id "$run_id" '
      (.halt_records // []) as $halts
      | if ($halts | length) > 0 and (($halts | last | .next_command // "") != "") then ($halts | last | .next_command)
        elif ($halts | length) > 0 and (($halts | last | .halt_class // "") == "fatal") then "inspect halt record"
        else "/dev-studio manager work-chain --resume \($run_id) --yes"
        end
    ' "$view" 2>/dev/null || printf '/dev-studio manager work-chain --resume %s --yes' "$run_id")
    next_command=$(printf '%s\n' "$next_command" \
      | sed "s#${SCRIPT_DIR}/studio-chain-runner.sh#/dev-studio manager work-chain#g; s#scripts/studio-chain-runner.sh#/dev-studio manager work-chain#g")
    printf '| `%s` | `%s` | `%s` | `%s` |\n' "$run_id" "$status" "$manifest" "$next_command" >> "$rows_tmp"
    rm -f "$view"
  done <<EOF
$(find "$chain_root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort)
EOF
  if [ ! -s "$rows_tmp" ]; then
    printf -- '- No resumable chain runs found.\n'
    rm -f "$rows_tmp"
    return 0
  fi
  printf '| Run ID | Status | Manifest | Suggested command |\n'
  printf '|---|---|---|---|\n'
  cat "$rows_tmp"
  rm -f "$rows_tmp"
}

RESOLVED_MANIFEST_SELECTOR_KIND=""
RESOLVED_MANIFEST_PATH=""
RESOLVED_CHAIN_SELECTOR_NAME=""
RESOLVED_CHAIN_SELECTOR_ID=""

manifest_chain_identifier() {
  local manifest="$1" idx="$2"
  yq -r ".chains[$idx].id // .chains[$idx].chain_id // .chains[$idx].chain_run_id // .chains[$idx].name // \"\"" "$manifest" 2>/dev/null
}

manifest_chain_status() {
  local manifest="$1" idx="$2" raw
  raw=$(yq -r ".chains[$idx].status // .chains[$idx].state // \"available\"" "$manifest" 2>/dev/null || printf 'available')
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_ ' '--'
}

chain_status_hidden_from_default_discovery() {
  case "$1" in
    completed|merged|closed|done|success|archived) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_manifest_by_chain_selector() {
  local input="$1" matches_tmp manifest chain_count idx name chain_id count row
  [ -d "$REPO_ROOT/chains" ] || return 1
  matches_tmp=$(mktemp -t studio-chain-selector.XXXXXX) || return 1
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    [ -f "$manifest" ] || continue
    chain_count=$(yq -r '.chains | length' "$manifest" 2>/dev/null || printf '0')
    case "$chain_count" in ''|null|*[!0-9]*|0) continue ;; esac
    for ((idx = 0; idx < chain_count; idx++)); do
      name=$(yq -r ".chains[$idx].name // \"\"" "$manifest" 2>/dev/null || printf '')
      chain_id=$(manifest_chain_identifier "$manifest" "$idx")
      if [ "$input" = "$name" ] || { [ -n "$chain_id" ] && [ "$input" = "$chain_id" ]; }; then
        printf '%s\t%s\t%s\n' "$manifest" "$name" "$chain_id" >> "$matches_tmp"
      fi
    done
  done <<EOF
$(find "$REPO_ROOT/chains" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)
EOF
  count=$(wc -l < "$matches_tmp" | tr -d ' ')
  case "$count" in
    0)
      rm -f "$matches_tmp"
      return 1
      ;;
    1)
      row=$(cat "$matches_tmp")
      rm -f "$matches_tmp"
      IFS=$'\t' read -r manifest RESOLVED_CHAIN_SELECTOR_NAME RESOLVED_CHAIN_SELECTOR_ID <<EOF
$row
EOF
      RESOLVED_MANIFEST_SELECTOR_KIND="chain"
      RESOLVED_MANIFEST_PATH="$manifest"
      if [ -z "$ONLY_CHAIN" ]; then
        ONLY_CHAIN="$RESOLVED_CHAIN_SELECTOR_NAME"
      fi
      return 0
      ;;
    *)
      printf 'studio-chain-runner: chain selector matched multiple manifests: %s\n' "$input" >&2
      cat "$matches_tmp" >&2
      rm -f "$matches_tmp"
      return 2
      ;;
  esac
}

resolve_manifest() {
  local input="$1" candidate rc
  RESOLVED_MANIFEST_SELECTOR_KIND="manifest"
  RESOLVED_MANIFEST_PATH=""
  RESOLVED_CHAIN_SELECTOR_NAME=""
  RESOLVED_CHAIN_SELECTOR_ID=""
  if [ -f "$input" ]; then
    RESOLVED_MANIFEST_PATH="$input"
    printf '%s\n' "$input"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yaml"
  if [ -f "$candidate" ]; then
    RESOLVED_MANIFEST_PATH="$candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$REPO_ROOT/chains/$input.yml"
  if [ -f "$candidate" ]; then
    RESOLVED_MANIFEST_PATH="$candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  set +e
  resolve_manifest_by_chain_selector "$input"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$RESOLVED_MANIFEST_PATH"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi

  printf 'studio-chain-runner: manifest not found: %s\n' "$input" >&2
  printf 'studio-chain-runner: tried %s and %s\n' "$REPO_ROOT/chains/$input.yaml" "$REPO_ROOT/chains/$input.yml" >&2
  printf 'studio-chain-runner: also searched chain names and chain ids under %s\n' "$REPO_ROOT/chains" >&2
  exit 2
}

manifest_diagnostics_json() {
  local manifest="$1" manifest_json
  if ! manifest_json=$(yq -o=json '.' "$manifest" 2>/dev/null); then
    jq -cn --arg manifest "$manifest" '{
      status: "schema_mismatch",
      reason_id: "manifest_schema_mismatch",
      reason: "manifest is not parseable YAML or JSON",
      manifest: $manifest
    }'
    return 0
  fi

  printf '%s\n' "$manifest_json" | jq -c --arg manifest "$manifest" '
    def issue_entry_valid:
      (type == "number" and . >= 1) or
      (type == "object" and (((.number? // .issue?) | type) == "number") and ((.number? // .issue?) >= 1));
    def chain_valid:
      type == "object"
      and ((.name? | type) == "string")
      and ((.name? | length) > 0)
      and ((.issues? | type) == "array")
      and ((.issues? | length) > 0)
      and ([.issues[]? | select(issue_entry_valid | not)] | length) == 0;
    def planning_markers:
      ((.nodes? | type) == "array")
      or ((.tasks? | type) == "array")
      or ((.ready_node_ids? | type) == "array")
      or ((.validation? | type) == "object")
      or ((.requirements? | type) == "array")
      or ((.work_items? | type) == "array")
      or ((.kind? // "" | tostring) | test("task-graph|requirement|planner|planning|work-chain-plan|chain-plan"; "i"))
      or ((.artifact_kind? // "" | tostring) | test("task-graph|requirement|planner|planning"; "i"));
    def planning_items:
      [
        (if ((.tasks? | type) == "array") then .tasks[] else empty end),
        (if ((.nodes? | type) == "array") then .nodes[] else empty end),
        (if ((.work_items? | type) == "array") then .work_items[] else empty end),
        (if ((.requirements? | type) == "array") then .requirements[] else empty end)
      ];
    def doneish:
      (((.status? // .state? // .stage? // .result? // .report_state? // "") | tostring) | test("done|completed|merged|closed|validated|implemented|shipped"; "i"))
      or (.done? == true)
      or (.completed? == true);
    def issue_mapping_present:
      [
        .issue?,
        .issue_number?,
        .github_issue?,
        .github_issue_number?,
        .gh_issue?,
        .issue_url?,
        .url?
      ]
      | map(select(. != null) | tostring)
      | map(select(test("(^#?[0-9]+$)|(issues/[0-9]+$)")))
      | length > 0;
    def done_without_issue_mapping:
      ([planning_items[]? | select((type == "object") and doneish and (issue_mapping_present | not))] | length) > 0;
    def runnable:
      .schema_version == 1
      and ((.chains? | type) == "array")
      and ((.chains? | length) > 0)
      and ([.chains[]? | select(chain_valid | not)] | length) == 0;
    def mismatch_reason:
      if .schema_version != 1 then "schema_version must be 1"
      elif ((.chains? | type) != "array") then "missing chains[] runnable chain list"
      elif ((.chains? | length) == 0) then "chains[] must contain at least one runnable chain"
      elif ([.chains[]? | select(((.name? | type) != "string") or ((.name? | length) == 0))] | length) > 0 then "each chain must have a non-empty name"
      elif ([.chains[]? | select(((.issues? | type) != "array") or ((.issues? | length) == 0))] | length) > 0 then "each chain must map to chains[].issues[] GitHub issue numbers"
      elif ([.chains[]?.issues[]? | select(issue_entry_valid | not)] | length) > 0 then "chains[].issues[] entries must be issue numbers or objects with number/issue"
      else "manifest does not match chain-manifest@1"
      end;
    if runnable then {
      status: "runnable",
      reason_id: null,
      reason: "runner-compatible chain manifest",
      manifest: $manifest
    }
    elif done_without_issue_mapping then {
      status: "audit_gap",
      reason_id: "planning_done_without_issue_mapping",
      reason: "planning artifact marks work done without durable issue mapping",
      manifest: $manifest
    }
    elif planning_markers then {
      status: "planning",
      reason_id: "manifest_schema_mismatch",
      reason: "planning manifest is not executable by the issue-backed chain runner",
      manifest: $manifest
    }
    else {
      status: "schema_mismatch",
      reason_id: "manifest_schema_mismatch",
      reason: mismatch_reason,
      manifest: $manifest
    }
    end
  '
}

print_manifest_preflight_failure() {
  local diagnostics="$1" status reason manifest
  status=$(jq -r '.status' <<<"$diagnostics")
  reason=$(jq -r '.reason' <<<"$diagnostics")
  manifest=$(jq -r '.manifest' <<<"$diagnostics")

  printf 'studio-chain-runner: manifest/schema mismatch: %s\n' "$reason" >&2
  printf 'studio-chain-runner: manifest: %s\n' "$manifest" >&2
  if [ "$status" = "audit_gap" ]; then
    printf 'studio-chain-runner: audit gap: done/implemented planning tasks without issue mappings are not authoritative. Create or map GitHub issues first, then preserve implementation provenance with the issue number, run/session reference, commit, and validation point.\n' >&2
  elif [ "$status" = "planning" ]; then
    printf 'studio-chain-runner: planning artifacts must be converted before execution: create or map GitHub issues for each task, then write a runner manifest with schema_version: 1, chains[].issues[] issue numbers, target_repo_root, and issue_repo: owner/repo.\n' >&2
  else
    printf 'studio-chain-runner: runnable manifests must follow chain-manifest@1 with schema_version: 1 and non-empty chains[].issues[] issue numbers.\n' >&2
  fi
}

preflight_runnable_manifest() {
  local manifest="$1" diagnostics status
  diagnostics=$(manifest_diagnostics_json "$manifest")
  status=$(jq -r '.status' <<<"$diagnostics")
  if [ "$status" != "runnable" ]; then
    print_manifest_preflight_failure "$diagnostics"
    return 2
  fi
  return 0
}

discover_chain_manifests() {
  local manifest chain_count idx name chain_id chain_status issues command rel_manifest manifest_filter manifest_list_tmp rows_tmp nonrunnable_tmp candidate diagnostics status reason command_selector
  command -v yq >/dev/null 2>&1 || { printf 'studio-chain-runner: yq required\n' >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }
  printf '\n## Runnable Work Chains\n\n'
  if [ ! -d "$REPO_ROOT/chains" ]; then
    printf -- '- No chain manifests found under `%s`.\n' "$REPO_ROOT/chains"
    return 0
  fi

  manifest_filter="${MANIFEST:-}"
  manifest_list_tmp=$(mktemp -t studio-chain-discovery-manifests.XXXXXX)
  if [ -n "$manifest_filter" ]; then
    set +e
    resolve_manifest "$manifest_filter" >/dev/null
    candidate_rc=$?
    set -e
    candidate="$RESOLVED_MANIFEST_PATH"
    if [ "$candidate_rc" -ne 0 ] || [ -z "$candidate" ]; then
      printf 'studio-chain-runner: chain manifest not found for discovery: %s\n' "$manifest_filter" >&2
      rm -f "$manifest_list_tmp"
      exit 2
    fi
    printf '%s\n' "$candidate" > "$manifest_list_tmp"
  else
    find "$REPO_ROOT/chains" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort > "$manifest_list_tmp"
  fi

  rows_tmp=$(mktemp -t studio-chain-discovery-chains.XXXXXX)
  nonrunnable_tmp=$(mktemp -t studio-chain-discovery-nonrunnable.XXXXXX)
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    [ -f "$manifest" ] || continue
    rel_manifest=${manifest#"$REPO_ROOT/"}
    diagnostics=$(manifest_diagnostics_json "$manifest")
    status=$(jq -r '.status' <<<"$diagnostics")
    if [ "$status" != "runnable" ]; then
      if [ -n "$manifest_filter" ]; then
        reason=$(jq -r '.reason' <<<"$diagnostics")
        printf '| `%s` | `%s` | `%s` |\n' "$rel_manifest" "$status" "$reason" >> "$nonrunnable_tmp"
      fi
      continue
    fi
    chain_count=$(yq -r '.chains | length' "$manifest" 2>/dev/null || printf '0')
    case "$chain_count" in
      ''|null|*[!0-9]*|0) continue ;;
    esac
    for ((idx = 0; idx < chain_count; idx++)); do
      name=$(yq -r ".chains[$idx].name" "$manifest")
      chain_id=$(manifest_chain_identifier "$manifest" "$idx")
      [ -n "$chain_id" ] && [ "$chain_id" != "null" ] || chain_id="$name"
      chain_status=$(manifest_chain_status "$manifest" "$idx")
      [ -n "$ONLY_CHAIN" ] && [ "$name" != "$ONLY_CHAIN" ] && continue
      if [ -z "$manifest_filter" ] && chain_status_hidden_from_default_discovery "$chain_status"; then
        continue
      fi
      issues=$(yq -o=json ".chains[$idx].issues // []" "$manifest" \
        | jq -r 'map(if type == "object" then (.number // .issue // .id // empty) else . end) | map(tostring) | join(",")')
      command_selector="$chain_id"
      [ -n "$command_selector" ] && [ "$command_selector" != "null" ] || command_selector="$name"
      command="/dev-studio manager work-chain $command_selector --dry-run"
      printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` |\n' "$rel_manifest" "$name" "$chain_id" "$chain_status" "${issues:-"-"}" "$command" >> "$rows_tmp"
    done
  done < "$manifest_list_tmp"
  rm -f "$manifest_list_tmp"
  if [ ! -s "$rows_tmp" ]; then
    printf -- '- No runnable work chains matched the current filter.\n'
    rm -f "$rows_tmp"
    if [ -s "$nonrunnable_tmp" ]; then
      printf '\n## Non-Runnable Manifest Matches\n\n'
      printf '| Manifest | Classification | Reason |\n'
      printf '|---|---|---|\n'
      cat "$nonrunnable_tmp"
      printf '\nPlanning artifacts must be converted before execution: create or map GitHub issues for each task, then write a runner manifest with `schema_version: 1`, `chains[].issues[]` issue numbers, `target_repo_root`, and `issue_repo: owner/repo`.\n'
    fi
    rm -f "$nonrunnable_tmp"
    return 0
  fi
  printf '| Manifest | Chain | Chain ID | Status | Issues | Suggested command |\n'
  printf '|---|---|---|---|---|---|\n'
  cat "$rows_tmp"
  rm -f "$rows_tmp" "$nonrunnable_tmp"
}

print_discovery() {
  printf '# Studio Chain Discovery\n\n'
  printf -- '- Bare invocation is discovery-only; it never starts or resumes work.\n'
  printf -- '- Preferred user entrypoint: `/dev-studio manager work-chain`.\n'
  printf -- '- Add a manifest, chain name, or chain id to filter suggestions: `/dev-studio manager work-chain --discover ios-v2-execution`.\n\n'
  printf '## Next Actions\n\n'
  printf -- '- Preview a chain: `/dev-studio manager work-chain <chain> --dry-run`\n'
  printf -- '- Attended run: `/dev-studio manager work-chain <manifest|chain-name|chain-id> --attended --yes`\n'
  printf -- '- Unattended run or safe resume: `/dev-studio manager work-chain <manifest|chain-name|chain-id>`\n'
  printf -- '- Resume a known run: `/dev-studio manager work-chain --resume <run_id> --yes`\n\n'
  printf 'Script equivalents remain available for automation: `scripts/manager-work-chain.sh ...` and `scripts/studio-chain-runner.sh ...`.\n\n'
  discover_persisted_runs
  discover_chain_manifests
  printf '\n'
}

if [ "$DISCOVER_MODE" -eq 1 ]; then
  print_discovery
  exit 0
fi

if [ -z "$MANIFEST" ] && [ -z "$RESUME_ID" ] && [ -z "$REGENERATE_REPORT_ID" ]; then
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
case "$RETRY_LIMIT" in
  ''|*[!0-9]*) printf 'studio-chain-runner: STUDIO_CHAIN_RETRY_LIMIT must be a non-negative integer\n' >&2; exit 2 ;;
esac
case "$RETRY_BACKOFF_SEC" in
  ''|*[!0-9]*) printf 'studio-chain-runner: STUDIO_CHAIN_RETRY_BACKOFF_SEC must be a non-negative integer\n' >&2; exit 2 ;;
esac

command -v yq >/dev/null 2>&1 || { printf 'studio-chain-runner: yq required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-chain-runner: jq required\n' >&2; exit 2; }

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
RUN_WORK_ROOT=""
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
  RUN_WORK_ROOT="$RUN_ROOT/$RUN_ID"
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
    RUN_STATE_JSON="$RUN_ROOT/$RUN_ID-state.json"
  fi
  if { [ "$DRY_RUN" -eq 0 ] || [ -n "$RESUME_ID" ]; } && [ "$EXPLAIN_NEXT" -eq 0 ]; then
    mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$PHASE_REVIEW_ROOT"
  else
    EVENTS_JSONL="/dev/null"
  fi
  RUN_PATHS_CONFIGURED=1
}

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
    chain_auth_normalized|chain_host_preflight_*|chain_artifact_validation_failed|chain_rule_gate_completed|chain_stale_lock_removed) printf 'preflight\n' ;;
    chain_started|chain_issue_started|chain_issue_completed|chain_issue_validated|chain_parent_commit_finalized|chain_issue_scheduler_blocked) printf 'execute\n' ;;
    chain_worker_summary_ingested|chain_telemetry_gap|checkpoint_auto_created|checkpoint_auto_loaded|checkpoint_context_savings_estimated|chain_ios_artifact_cleanup_completed) printf 'ingest\n' ;;
    chain_pr_opened|chain_review_completed) printf 'review\n' ;;
    chain_completed|chain_issue_merged) printf 'merge\n' ;;
    chain_issue_closed) printf 'close\n' ;;
    chain_resume_attempt_*|chain_supervisor_decision|chain_state_projection_repaired) printf 'resume\n' ;;
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

chain_efficiency_metrics_json() {
  local status="$1" failure_reason="${2:-}" summaries_file events_file
  summaries_file=$(mktemp -t studio-chain-efficiency-summaries.XXXXXX)
  events_file=$(mktemp -t studio-chain-efficiency-events.XXXXXX)
  : > "$summaries_file"
  : > "$events_file"
  if [ -n "${SUMMARY_ROOT:-}" ] && [ -d "$SUMMARY_ROOT" ]; then
    find "$SUMMARY_ROOT" -type f -name '*.json' 2>/dev/null | sort | while IFS= read -r summary; do
      jq -c . "$summary" >> "$summaries_file" 2>/dev/null || true
    done
  fi
  if [ -n "${EVENTS_JSONL:-}" ] && [ -f "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
    jq -c . "$EVENTS_JSONL" > "$events_file" 2>/dev/null || true
  fi
  jq -n \
    --arg status "$status" \
    --arg failure_reason "$failure_reason" \
    --slurpfile summaries "$summaries_file" \
    --slurpfile events "$events_file" '
    def token_total:
      (.tokens // null) as $t |
      if $t == null then null
      elif ($t | type) == "number" then $t
      elif ($t | type) == "object" then ($t.total // $t.total_tokens // $t.usage.total_tokens // null)
      else null
      end;
    def bad_outcome:
      ((.outcome // .status // "") | tostring | test("fail|error|flaky"; "i"));
    def bad_count($arr): [($arr // [])[]? | select(bad_outcome)] | length;
    def duration: (.duration_s // 0 | tonumber? // 0);
    def numeric_or_length:
      if . == null then 0
      elif (type) == "number" then .
      elif (type) == "array" then length
      else (tonumber? // 0)
      end;
    def counts_by(key):
      reduce .[] as $item ({}; ($item | key // "unknown" | tostring) as $k | .[$k] = ((.[$k] // 0) + 1));
    def timing_value($k):
      (.execution_telemetry.timing[$k]
       // .execution_telemetry.timings[$k]
       // .execution_telemetry.phases[$k]
       // (if $k == "control_plane_overhead_ms" then .execution_telemetry.routing.control_plane.scheduler_overhead_ms else null end)
       // empty)
      | tonumber? // empty;
    [ $summaries[] ] as $rows |
    [ $events[] ] as $events |
    [ $rows[] | token_total | select(. != null) ] as $tokens |
    [ $rows[] | (.tests // [])[]? ] as $tests |
    [ $rows[] | (.lints // [])[]? ] as $lints |
    [ $rows[] | (.builds // [])[]? ] as $builds |
    [ $rows[] | .execution_telemetry? // empty ] as $execution_rows |
    [ $rows[].execution_telemetry.routing.reason_class? // empty ] as $routing_reasons |
    [ $rows[].execution_telemetry.cleanup.outcome? // empty ] as $cleanup_outcomes |
    [ $rows[].execution_telemetry.cleanup.retention_class? // empty ] as $retention_classes |
    [ $rows[].execution_telemetry.artifacts.public_classes[]? ] as $artifact_classes |
    [ $rows[].telemetry_gaps[]? | select(test("executor|worker_routing|artifact_evidence|cleanup_telemetry")) ] as $execution_gaps |
    ($rows | max_by(duration)?) as $slowest |
    {
      schema_version: 1,
      status: $status,
      failure_reason: (if $failure_reason == "" then null else $failure_reason end),
      issues_completed: ([ $rows[] | select((.exit_code // 1) == 0) ] | length),
      issues_failed: ([ $rows[] | select((.exit_code // 0) != 0) ] | length),
      worker_duration_s: ([ $rows[] | duration ] | add // 0),
      avg_worker_duration_s: (if ($rows | length) == 0 then null else (([ $rows[] | duration ] | add // 0) / ($rows | length)) end),
      slowest_issue: (if $slowest == null then null else {issue_number: ($slowest.issue_number // null), duration_s: ($slowest.duration_s // null)} end),
      tokens_total: (if ($tokens | length) == 0 then null else ($tokens | add) end),
      token_reports: ($tokens | length),
      files_changed: ([ $rows[] | (.files_changed // null | numeric_or_length) ] | add // 0),
      additions: ([ $rows[] | (.additions // null | numeric_or_length) ] | add // 0),
      deletions: ([ $rows[] | (.deletions // null | numeric_or_length) ] | add // 0),
      generated_file_count: ([ $rows[] | (.generated_file_count // null | numeric_or_length) ] | add // 0),
      seconds_per_file_changed: (
        ([ $rows[] | (.files_changed // null | numeric_or_length) ] | add // 0) as $file_count
        | if $file_count == 0 then null else (([ $rows[] | duration ] | add // 0) / $file_count) end
      ),
      tokens_per_file_changed: (
        ([ $rows[] | (.files_changed // null | numeric_or_length) ] | add // 0) as $file_count
        | if (($tokens | length) == 0) or ($file_count == 0) then null else (($tokens | add) / $file_count) end
      ),
      retry_events: ([ $events[] | select((.event // "") | test("retry"; "i")) ] | length),
      resume_attempts: ([ $events[] | select((.event // "") | test("^chain_resume_attempt_")) ] | length),
      phase_reviews: ([ $events[] | select((.event // "") == "chain_phase_review_completed") ] | length),
      pr_reviews: ([ $events[] | select((.event // "") == "chain_review_completed") ] | length),
      tests: {total: ($tests | length), bad: ([ $tests[] | select(bad_outcome) ] | length), outcomes: ($tests | counts_by(.outcome // .status))},
      lints: {total: ($lints | length), bad: ([ $lints[] | select(bad_outcome) ] | length), outcomes: ($lints | counts_by(.outcome // .status))},
      builds: {total: ($builds | length), bad: ([ $builds[] | select(bad_outcome) ] | length), outcomes: ($builds | counts_by(.outcome // .status))},
      telemetry_gap_counts: ([ $rows[].telemetry_gaps[]? ] | map({gap: ., one: 1}) | counts_by(.gap)),
      execution_telemetry: {
        reports: ($execution_rows | length),
        implementation_executors: ([ $rows[] | (.execution_telemetry.executors.implementation.executor // .execution_telemetry.executors.implementation.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        build_executors: ([ $rows[] | (.execution_telemetry.executors.build.executor // .execution_telemetry.executors.build.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        test_executors: ([ $rows[] | (.execution_telemetry.executors.test.executor // .execution_telemetry.executors.test.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        review_executors: ([ $rows[] | (.execution_telemetry.executors.review.executor // .execution_telemetry.executors.review.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        release_executors: ([ $rows[] | (.execution_telemetry.executors.release.executor // .execution_telemetry.executors.release.node // empty) ] | map({executor: ., one: 1}) | counts_by(.executor)),
        routing_reason_classes: ($routing_reasons | map({reason: ., one: 1}) | counts_by(.reason)),
        cleanup_outcomes: ($cleanup_outcomes | map({outcome: ., one: 1}) | counts_by(.outcome)),
        retention_classes: ($retention_classes | map({class: ., one: 1}) | counts_by(.class)),
        public_artifact_classes: ($artifact_classes | map({class: ., one: 1}) | counts_by(.class)),
        gap_count: ($execution_gaps | length),
        timing: {
          reports_with_timing: ([ $rows[] | select((.execution_telemetry.timing // .execution_telemetry.timings // .execution_telemetry.phases // .execution_telemetry.routing.control_plane // null) != null) ] | length),
          control_plane_overhead_ms: ([ $rows[] | timing_value("control_plane_overhead_ms") ] | add // 0),
          source_sync_s: ([ $rows[] | timing_value("source_sync_s") ] | add // 0),
          simulator_boot_s: ([ $rows[] | timing_value("simulator_boot_s") ] | add // 0),
          xcodebuild_s: ([ $rows[] | timing_value("xcodebuild_s") ] | add // 0),
          tests_s: ([ $rows[] | timing_value("tests_s") ] | add // 0),
          log_parsing_s: ([ $rows[] | timing_value("log_parsing_s") ] | add // 0),
          cleanup_s: ([ $rows[] | timing_value("cleanup_s") ] | add // 0)
        }
      },
      bottlenecks: ([
        (if $slowest != null then {kind:"slowest_issue", issue_number: ($slowest.issue_number // null), duration_s: ($slowest.duration_s // null)} else empty end),
        (if ([ $tests[] | select(bad_outcome) ] | length) > 0 then {kind:"test_failures_or_flakes", count: ([ $tests[] | select(bad_outcome) ] | length)} else empty end),
        (if ([ $rows[].telemetry_gaps[]? | select(. == "tokens") ] | length) > 0 then {kind:"missing_token_telemetry", count: ([ $rows[].telemetry_gaps[]? | select(. == "tokens") ] | length)} else empty end),
        (if ($execution_gaps | length) > 0 then {kind:"ios_execution_telemetry_gaps", count:($execution_gaps | length)} else empty end)
      ])
    }'
  rm -f "$summaries_file" "$events_file"
}

write_run_state() {
  local status="$1" failure_reason="${2:-}"
  local chains_json="[]" halt_records_json="[]" decision_escrows_json="[]" phase_reviews_json="[]" phase_review_feedback_json="[]" checkpoints_json="[]"
  local report_generated_at=""
  local efficiency_metrics_json
  efficiency_metrics_json=$(chain_efficiency_metrics_json "$status" "$failure_reason")
  if [ -f "$RUN_STATE_JSON" ]; then
    chains_json=$(jq -c '.chains // []' "$RUN_STATE_JSON")
    halt_records_json=$(jq -c '.halt_records // []' "$RUN_STATE_JSON")
    decision_escrows_json=$(jq -c '.decision_escrows // []' "$RUN_STATE_JSON")
    phase_reviews_json=$(jq -c '.phase_reviews // []' "$RUN_STATE_JSON")
    phase_review_feedback_json=$(jq -c '.phase_review_feedback // []' "$RUN_STATE_JSON")
    checkpoints_json=$(jq -c '.checkpoints // []' "$RUN_STATE_JSON")
    report_generated_at=$(jq -r '.report_generated_at // empty' "$RUN_STATE_JSON")
  elif [ -f "$PLAN_JSON" ]; then
    chains_json=$(jq -c '.chains // []' "$PLAN_JSON")
  fi
  local state_tmp
  state_tmp="$RUN_STATE_JSON.write.$$"
  if ! jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest "$MANIFEST" \
    --arg target_repo_root "$TARGET_REPO_ROOT" \
    --arg issue_repo "$REPO_SLUG" \
    --arg status "$status" \
    --arg started_at "$RUN_STARTED_TS" \
    --arg updated_at "$(iso_ts_now)" \
    --arg report "$RUN_REPORT" \
    --arg report_generated_at "$report_generated_at" \
    --arg plan "$PLAN_JSON" \
    --arg parallel_chains "$PARALLEL_CHAINS" \
    --arg execution_mode "$EXECUTION_MODE" \
    --argjson retry_limit "$RETRY_LIMIT" \
    --argjson retry_backoff_sec "$RETRY_BACKOFF_SEC" \
    --arg failure_reason "$failure_reason" \
    --argjson chains "$chains_json" \
    --argjson halt_records "$halt_records_json" \
    --argjson decision_escrows "$decision_escrows_json" \
    --argjson phase_reviews "$phase_reviews_json" \
    --argjson phase_review_feedback "$phase_review_feedback_json" \
    --argjson checkpoints "$checkpoints_json" \
    --argjson efficiency_metrics "$efficiency_metrics_json" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest: $manifest,
      target_repo_root: $target_repo_root,
      issue_repo: $issue_repo,
      status: $status,
      started_at: $started_at,
      updated_at: $updated_at,
      report: $report,
      report_generated_at: (if $report_generated_at == "" then null else $report_generated_at end),
      plan: $plan,
      parallel_chains: $parallel_chains,
      execution_mode: $execution_mode,
      retry_policy: {
        auto_retry_limit: $retry_limit,
        backoff_seconds: $retry_backoff_sec,
        retryable_halt_classes: ["retryable"],
        prompt_after_exhaustion: false
      },
      chains: $chains,
      halt_records: $halt_records,
      decision_escrows: $decision_escrows,
      phase_reviews: $phase_reviews,
      phase_review_feedback: $phase_review_feedback,
      checkpoints: $checkpoints,
      efficiency_metrics: $efficiency_metrics,
      failure_reason: (if $failure_reason == "" then null else $failure_reason end)
    }' > "$state_tmp"; then
    printf 'studio-chain-runner: failed to write run state; leaving prior state intact: %s\n' "$RUN_STATE_JSON" >&2
    rm -f "$state_tmp"
    return 1
  fi
  if ! jq -e . "$state_tmp" >/dev/null 2>&1; then
    printf 'studio-chain-runner: generated run state is invalid JSON; leaving prior state intact: %s\n' "$RUN_STATE_JSON" >&2
    rm -f "$state_tmp"
    return 1
  fi
  mv "$state_tmp" "$RUN_STATE_JSON"
}

update_state_jq() {
  local filter tmp lock acquired=0 spins=0
  [ -f "$RUN_STATE_JSON" ] || return 0
  lock="$RUN_STATE_JSON.update.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    if lock_is_stale "$lock"; then
      record_stale_lock_removed "$lock" state-update
      rm -rf "$lock"
      continue
    fi
    spins=$((spins + 1))
    if [ "$spins" -gt 600 ]; then
      printf 'studio-chain-runner: timed out waiting for state update lock: %s\n' "$lock" >&2
      return 1
    fi
    sleep 0.1
  done
  acquired=1
  if declare -F write_lock_metadata >/dev/null 2>&1; then
    write_lock_metadata "$lock" state-update
  else
    printf '%s\n' "$$" > "$lock/pid"
    printf '%s\n' "$(iso_ts_now)" > "$lock/created_at"
  fi
  filter="${*: -1}"
  set -- "${@:1:$(($# - 1))}"
  tmp="$RUN_STATE_JSON.tmp.$$"
  if ! jq -e . "$RUN_STATE_JSON" >/dev/null 2>&1; then
    printf 'studio-chain-runner: refusing state update because state is missing or invalid JSON: %s\n' "$RUN_STATE_JSON" >&2
    rm -f "$tmp"
    rm -rf "$lock"
    return 1
  fi
  if ! jq "$@" --arg updated_at "$(iso_ts_now)" ".updated_at = \$updated_at | $filter" "$RUN_STATE_JSON" > "$tmp"; then
    printf 'studio-chain-runner: state update jq failed; leaving prior state intact: %s\n' "$RUN_STATE_JSON" >&2
    rm -f "$tmp"
    rm -rf "$lock"
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    printf 'studio-chain-runner: state update produced invalid JSON; leaving prior state intact: %s\n' "$RUN_STATE_JSON" >&2
    rm -f "$tmp"
    rm -rf "$lock"
    return 1
  fi
  mv "$tmp" "$RUN_STATE_JSON"
  if [ "$acquired" -eq 1 ]; then
    rm -rf "$lock"
  fi
}

chain_monitor_notify_state_change() {
  local chain_run_id="${1:-}" issue_run_id="${2:-}" issue_number="${3:-}" mutation="${4:-state-updated}" chain_name="${5:-}"
  [ -f "${RUN_STATE_JSON:-}" ] || return 0
  declare -F chain_monitor_notify_runner_state >/dev/null 2>&1 || return 0
  chain_monitor_notify_runner_state \
    --project generic-dev-studio \
    --run-state "$RUN_STATE_JSON" \
    --run-id "$RUN_ID" \
    --chain-run-id "$chain_run_id" \
    --issue-run-id "$issue_run_id" \
    --chain "$chain_name" \
    --issue-number "$issue_number" \
    --mutation "$mutation" \
    --dry-run "$DRY_RUN" || true
}

chain_monitor_notify_chain_state_change() {
  local chain_run_id="${1:-}" mutation="${2:-state-updated}" chain_name
  [ -n "$chain_run_id" ] || return 0
  [ -f "${RUN_STATE_JSON:-}" ] || return 0
  chain_name=$(jq -r --arg id "$chain_run_id" '.chains[]? | select((.chain_run_id // "") == $id) | .name // ""' "$RUN_STATE_JSON" 2>/dev/null | head -n 1)
  chain_monitor_notify_state_change "$chain_run_id" "" "" "$mutation" "$chain_name"
}

chain_monitor_notify_issue_state_change() {
  local issue_run_id="${1:-}" mutation="${2:-state-updated}" info chain_run_id chain_name issue_number
  [ -n "$issue_run_id" ] || return 0
  [ -f "${RUN_STATE_JSON:-}" ] || return 0
  info=$(jq -r --arg id "$issue_run_id" '
    .chains[]? as $chain
    | $chain.issues[]?
    | select((.issue_run_id // "") == $id)
    | [($chain.chain_run_id // ""), ($chain.name // ""), ((.number // .issue // "") | tostring)] | @tsv
  ' "$RUN_STATE_JSON" 2>/dev/null | head -n 1)
  [ -n "$info" ] || return 0
  IFS=$'\t' read -r chain_run_id chain_name issue_number <<<"$info"
  chain_monitor_notify_state_change "$chain_run_id" "$issue_run_id" "$issue_number" "$mutation" "$chain_name"
}

mark_chain_state() {
  local chain_run_id="$1" status="$2" pr_url="${3:-}"
  update_state_jq \
    --arg chain_run_id "$chain_run_id" \
    --arg status "$status" \
    --arg pr_url "$pr_url" \
    '(.chains[] | select(.chain_run_id == $chain_run_id) | .status) = $status
     | if $pr_url == "" then . else (.chains[] | select(.chain_run_id == $chain_run_id) | .pr_url) = $pr_url end'
  chain_monitor_notify_chain_state_change "$chain_run_id" state-updated
}

mark_issue_state() {
  local issue_run_id="$1" status="$2" before="${3:-}" after="${4:-}" summary="${5:-}" reason="${6:-}"
  local lifecycle transition_at
  transition_at=$(iso_ts_now)
  case "$status" in
    pending) lifecycle="issue-created" ;;
    running) lifecycle="implementation-running" ;;
    completed) lifecycle="smoke-passed" ;;
    failed) lifecycle="failed" ;;
    *) lifecycle="$status" ;;
  esac
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --arg status "$status" \
    --arg lifecycle "$lifecycle" \
    --arg before "$before" \
    --arg after "$after" \
    --arg summary "$summary" \
    --arg reason "$reason" \
    --arg run_id "$RUN_ID" \
    --arg issue_repo "$REPO_SLUG" \
    --arg transition_at "$transition_at" \
    'def append_lifecycle($state; $reason):
       .lifecycle_state = $state
       | .lifecycle_history = (
           (.lifecycle_history // []) as $history
           | if (($history | length) > 0 and ($history[-1].state // "") == $state) then $history
             else $history + [{state:$state, at:$transition_at, reason:$reason}]
             end
         );
     (.chains[].issues[] | select(.issue_run_id == $issue_run_id)) |= (
       .status = $status
       | append_lifecycle($lifecycle; $status)
       | .provenance.issue = ((.provenance.issue // {}) + {
           number:(.number // .issue // null),
           title:(.title // null),
           state:(.state // null),
           url:(.url // .issue_url // null),
           repo:$issue_repo
         })
       | .provenance.session = ((.provenance.session // {}) + {
           run_id:$run_id,
           chain_run_id:(.chain_run_id // null),
           issue_run_id:$issue_run_id,
           issue_branch:(.issue_branch // null),
           issue_worktree:(.issue_worktree // null)
         })
       | if $before == "" then . else .commit_before = $before | .provenance.implementation.commit_before = $before end
       | if $after == "" then . else .commit_after = $after | .provenance.implementation.commit_after = $after end
       | if $summary == "" then . else .summary = $summary | .provenance.implementation.summary = $summary | .provenance.validation.summary = $summary end
       | if $status == "completed" then .provenance.validation = ((.provenance.validation // {}) + {validated_at:$transition_at, validation_point:(if $summary == "" then "runner-state" else "worker-summary" end)}) else . end
       | if $reason == "" then del(.failure_reason) else .failure_reason = $reason end
     )'
  chain_monitor_notify_issue_state_change "$issue_run_id" state-updated
}

mark_issue_implemented_local() {
  local issue_run_id="$1" before="$2" after="$3" summary="${4:-}" parent_finalized="${5:-false}"
  local transition_at
  transition_at=$(iso_ts_now)
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --arg before "$before" \
    --arg after "$after" \
    --arg summary "$summary" \
    --arg run_id "$RUN_ID" \
    --arg transition_at "$transition_at" \
    --argjson parent_finalized "$parent_finalized" \
    'def append_lifecycle($state; $reason):
       .lifecycle_state = $state
       | .lifecycle_history = (
           (.lifecycle_history // []) as $history
           | if (($history | length) > 0 and ($history[-1].state // "") == $state) then $history
             else $history + [{state:$state, at:$transition_at, reason:$reason}]
             end
         );
     (.chains[].issues[] | select(.issue_run_id == $issue_run_id)) |= (
       append_lifecycle("implemented-local"; "worker-commit")
       | .commit_before = $before
       | .commit_after = $after
       | if $summary == "" then . else .summary = $summary end
       | .provenance.implementation = ((.provenance.implementation // {}) + {
           run_id:$run_id,
           chain_run_id:(.chain_run_id // null),
           issue_run_id:$issue_run_id,
           commit_before:$before,
           commit_after:$after,
           summary:(if $summary == "" then null else $summary end),
           implemented_at:$transition_at,
           parent_finalized:$parent_finalized
         })
     )'
  chain_monitor_notify_issue_state_change "$issue_run_id" state-updated
}

mark_issue_retry_attempt() {
  local issue_run_id="$1" retry_reason="$2"
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --arg retry_reason "$retry_reason" \
    '(.chains[].issues[] | select(.issue_run_id == $issue_run_id)) |= (
       .auto_retry_attempts = ((.auto_retry_attempts // 0) + 1)
       | .last_retry_reason = $retry_reason
     )'
}

mark_issue_exit_code() {
  local issue_run_id="$1" exit_code="$2"
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --argjson exit_code "$exit_code" \
    '(.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .exit_code) = $exit_code'
}

mark_issue_integrated() {
  local issue_run_id="$1" chain_commit="${2:-}"
  local transition_at
  transition_at=$(iso_ts_now)
  update_state_jq \
    --arg issue_run_id "$issue_run_id" \
    --arg chain_commit "$chain_commit" \
    --arg transition_at "$transition_at" \
    'def append_lifecycle($state; $reason):
       .lifecycle_state = $state
       | .lifecycle_history = (
           (.lifecycle_history // []) as $history
           | if (($history | length) > 0 and ($history[-1].state // "") == $state) then $history
             else $history + [{state:$state, at:$transition_at, reason:$reason}]
             end
         );
     (.chains[].issues[] | select(.issue_run_id == $issue_run_id)) |= (
       .integrated = true
       | append_lifecycle("merged"; "chain-branch-integration")
       | .provenance.merge = ((.provenance.merge // {}) + {
           merged_at:$transition_at,
           chain_commit:(if $chain_commit == "" then null else $chain_commit end)
         })
     )'
  chain_monitor_notify_issue_state_change "$issue_run_id" state-updated
}

mark_chain_issues_completed_after_pr() {
  local chain_run_id="$1" commit_after="${2:-}"
  local transition_at
  transition_at=$(iso_ts_now)
  update_state_jq \
    --arg chain_run_id "$chain_run_id" \
    --arg after "$commit_after" \
    --arg transition_at "$transition_at" \
    '(.chains[] | select(.chain_run_id == $chain_run_id) | .issues[]) |= (
       .status = "completed"
       | .integrated = true
       | .lifecycle_state = "merged"
       | .lifecycle_history = (
           (.lifecycle_history // []) as $history
           | if (($history | length) > 0 and ($history[-1].state // "") == "merged") then $history
             else $history + [{state:"merged", at:$transition_at, reason:"chain-pr-finalized"}]
             end
         )
       | if $after == "" then . else .commit_after = $after end
       | .provenance.merge = ((.provenance.merge // {}) + {
           finalized_at:$transition_at,
           chain_pr_commit_after:(if $after == "" then null else $after end)
         })
       | del(.failure_reason)
       | del(.exit_code)
     )'
  chain_monitor_notify_chain_state_change "$chain_run_id" state-updated
}

mark_issue_closed() {
  local chain_run_id="$1" issue_run_id="$2" issue="$3" pr_url="${4:-}"
  local transition_at
  transition_at=$(iso_ts_now)
  update_state_jq \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg issue "$issue" \
    --arg pr_url "$pr_url" \
    --arg transition_at "$transition_at" \
    'def append_lifecycle($state; $reason):
       .lifecycle_state = $state
       | .lifecycle_history = (
           (.lifecycle_history // []) as $history
           | if (($history | length) > 0 and ($history[-1].state // "") == $state) then $history
             else $history + [{state:$state, at:$transition_at, reason:$reason}]
             end
         );
     (.chains[] | select(.chain_run_id == $chain_run_id) | .issues[] | select((.issue_run_id // "") == $issue_run_id or ((.number // .issue // 0) | tostring) == $issue)) |= (
       .status = "completed"
       | .integrated = true
       | .closed = true
       | .closed_at = $transition_at
       | append_lifecycle("closed"; "issue-closed")
       | .provenance.closure = {
           closed_at:$transition_at,
           pr_url:(if $pr_url == "" then null else $pr_url end),
           issue_number:(($issue | tonumber?) // (.number // .issue // null))
         }
     )'
  chain_monitor_notify_issue_state_change "$issue_run_id" state-updated
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
  if [ "$pointer_id" != "$checkpoint_id" ]; then
    log "checkpoint latest pointer drift for branch $branch; skipping optional auto-checkpoint load"
    emit_chain_event checkpoint_auto_loaded "" "$RUN_ID" "$chain_run_id" "" skipped 0 \
      "$(jq -cn --arg checkpoint_id "$checkpoint_id" --arg pointer_id "$pointer_id" --arg branch "$branch" '{checkpoint_id:$checkpoint_id, pointer_id:$pointer_id, branch:$branch, skipped_reason:"latest_pointer_drift"}')"
    return 0
  fi
  checkpoint_dir=$(jq -r --arg chain_run_id "$chain_run_id" --arg checkpoint_id "$checkpoint_id" '(.checkpoints // []) | map(select(.chain_run_id == $chain_run_id and .checkpoint_id == $checkpoint_id)) | last | .checkpoint_dir // empty' "$RUN_STATE_JSON")
  case "$checkpoint_dir" in
    /*) ;;
    sessions/*) checkpoint_dir="$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_checkpoint_root_for generic-dev-studio)/$checkpoint_dir" ;;
    *) checkpoint_dir="$(HOME="$PARENT_HOME_FOR_GITHUB" resolve_checkpoint_root_for generic-dev-studio)/sessions/$checkpoint_dir" ;;
  esac
  current_head=$(git -C "$chain_worktree" rev-parse HEAD)
  validate_auto_checkpoint_artifacts "$checkpoint_dir" "$branch" "$checkpoint_id" "$current_head" || abort_run "checkpoint drift verification failed for $checkpoint_id"
  load_out="$CHAIN_RUN_ROOT/checkpoint-load-$chain_run_id.out"
  (
    cd "$chain_worktree" || exit 1
    HOME="$PARENT_HOME_FOR_GITHUB" STUDIO_CHECKPOINT_TRACE_READS="$CHAIN_RUN_ROOT/checkpoint-load-$chain_run_id.reads" \
      "$SCRIPT_DIR/studio-checkpoint.sh" resume --project generic-dev-studio --role manager --branch "$branch" --latest
  ) > "$load_out"
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
    parent_host_unknown|branch_worktree_conflict|base_branch_advanced|missing_child_summary|child_crash|issue_body_changed|partial_github_operation|test_build_infra_unavailable|telemetry_artifact_malformed|telemetry_artifact_missing|manifest_schema_version_mismatch|manifest_schema_mismatch|implementation_scope_blocked|chain_state_projection_invalid|chain_state_projection_repair_failed)
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
    *manifest/schema\ mismatch*|*planning\ manifest*|*chain-manifest*) printf 'manifest_schema_mismatch\n' ;;
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
    --arg execution_mode "$EXECUTION_MODE" \
    --argjson retry_limit "$RETRY_LIMIT" \
    --argjson retry_backoff_sec "$RETRY_BACKOFF_SEC" \
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
      retry_policy: {
        auto_retry_limit: $retry_limit,
        backoff_seconds: $retry_backoff_sec,
        exhausted: ($halt_class == "retryable"),
        retryable: ($halt_class == "retryable")
      },
      escalation: {
        execution_mode: $execution_mode,
        prompt_allowed: ($halt_class == "review-needed" or $halt_class == "human-needed" or $halt_class == "fatal"),
        routine_continue_prompt: false,
        reason: (if ($halt_class == "review-needed") then "review judgment required"
          elif ($halt_class == "human-needed") then "human decision required"
          elif ($halt_class == "fatal") then "hard safety stop"
          else "resume command is available after correcting the typed cause" end)
      },
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

reconcile_resume_state_projection_or_halt() {
  local summary_file reconcile_rc status backup
  [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ] || return 0
  [ -n "${EVENTS_JSONL:-}" ] && [ -s "$EVENTS_JSONL" ] || return 0

  summary_file=$(mktemp -t chain-state-reconcile.XXXXXX)
  set +e
  chain_run_state_reconcile_file "$RUN_STATE_JSON" "$EVENTS_JSONL" resume-startup > "$summary_file"
  reconcile_rc=$?
  set -e
  if [ "$reconcile_rc" -ne 0 ]; then
    write_halt_record "chain_state_projection_invalid" "resume startup could not derive chain run projection from events: $RUN_STATE_JSON" >/dev/null || true
    rm -f "$summary_file"
    exit 2
  fi
  status=$(jq -r '.status // "unknown"' "$summary_file" 2>/dev/null || printf 'unknown')
  if [ "$status" = "repaired" ]; then
    backup=$(jq -r '.backup // ""' "$summary_file")
    log "resume repaired stale state projection from events: $RUN_STATE_JSON"
    emit_chain_event chain_state_projection_repaired "" "$RUN_ID" "" "" completed 0 \
      "$(jq -c --arg backup "$backup" '{backup:$backup, mismatch:(.mismatch.status // "mismatch")}' "$summary_file")"
  fi
  rm -f "$summary_file"
}

supersede_completed_halt_records() {
  local resolved_at tmp
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ -f "$RUN_STATE_JSON" ] || return 0
  resolved_at=$(iso_ts_now)
  tmp="$RUN_STATE_JSON.halts.$$"
  jq \
    --arg resolved_at "$resolved_at" \
    --arg attempt_id "$ATTEMPT_ID" \
    '(.halt_records // []) as $records
     | .halt_records = ($records | map(
         if (.status // "") == "paused" then
           . + {
             status: "superseded",
             next_command: null,
             superseded_at: $resolved_at,
             superseded_by_attempt_id: $attempt_id,
             resolution: "run_completed_after_resume"
           }
         else . end
       ))
     | .halt_record_resolution = {
         resolved_at: $resolved_at,
         attempt_id: $attempt_id,
         active_count: ([.halt_records[]? | select((.status // "") == "paused" or (.status // "") == "terminated")] | length),
         superseded_count: ([.halt_records[]? | select((.status // "") == "superseded")] | length)
       }' "$RUN_STATE_JSON" > "$tmp"
  mv "$tmp" "$RUN_STATE_JSON"
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
       }])
     | if $kind != "outcome" or $issue_run_id == "" then .
       else
         (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .provenance.validation) |= ((. // {}) + {
           phase_review_artifact:$artifact,
           phase_review:$review,
           phase_review_verdict:$verdict,
           review_host:$review_host
         })
       end'
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
  local review_host actual_review_host fallback_from fallback_to fallback_reason cross_host_satisfied degraded_review degraded_reason next_cross_host_retry review_file review_meta review_rc verdict feedback review_started_at review_duration
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
  actual_review_host=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_HOST=//p' | tail -1)
  [ -n "$actual_review_host" ] || actual_review_host="$review_host"
  fallback_from=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_FALLBACK_FROM=//p' | tail -1)
  fallback_to=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_FALLBACK_TO=//p' | tail -1)
  fallback_reason=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_FALLBACK_REASON=//p' | tail -1)
  cross_host_satisfied=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_CROSS_HOST_SATISFIED=//p' | tail -1)
  [ -n "$cross_host_satisfied" ] || cross_host_satisfied="unknown"
  degraded_review=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_DEGRADED=//p' | tail -1)
  [ -n "$degraded_review" ] || degraded_review="0"
  degraded_reason=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_DEGRADED_REASON=//p' | tail -1)
  next_cross_host_retry=$(printf '%s\n' "$review_meta" | sed -n 's/^PHASE_REVIEW_NEXT_CROSS_HOST_RETRY=//p' | tail -1)
  feedback="[]"
  if [ "$kind" = "outcome" ] && [ -f "$review_file" ]; then
    feedback=$(compact_phase_review_feedback_json "$review_file")
  fi
  record_phase_review "$boundary_id" "$kind" "$verdict" "$artifact" "$review_file" "$actual_review_host" "$chain_run_id" "$issue_run_id" "$feedback"
  emit_chain_event chain_phase_review_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" "$verdict" "$review_duration" \
    "$(jq -cn \
      --arg kind "$kind" \
      --arg boundary_id "$boundary_id" \
      --arg verdict "$verdict" \
      --arg requested_review_host "$review_host" \
      --arg review_host "$actual_review_host" \
      --arg fallback_from "$fallback_from" \
      --arg fallback_to "$fallback_to" \
      --arg fallback_reason "$fallback_reason" \
      --arg cross_host_satisfied "$cross_host_satisfied" \
      --arg degraded_review "$degraded_review" \
      --arg degraded_reason "$degraded_reason" \
      --arg next_cross_host_retry "$next_cross_host_retry" \
      --arg artifact "$artifact" \
      --arg review "$review_file" \
      --argjson feedback "$feedback" \
      '{kind:$kind, boundary_id:$boundary_id, verdict:$verdict, requested_review_host:$requested_review_host, review_host:$review_host, cross_host_satisfied:$cross_host_satisfied, degraded_review:($degraded_review == "1"), artifact:$artifact, review:$review, feedback:$feedback}
       | if $fallback_from != "" then . + {fallback_from:$fallback_from, fallback_to:$fallback_to, fallback_reason:$fallback_reason} else . end
       | if $degraded_reason != "" then . + {degraded_reason:$degraded_reason} else . end
       | if $next_cross_host_retry != "" then . + {next_cross_host_retry:$next_cross_host_retry} else . end')"

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
  local chain_name="$1" chain_branch="$2" source_branch="$3" issue_branch="$4" issue_json="$5" host="$6" git_metadata_strategy="$7" worktree="$8" chain_run_id="$9" issue_run_id="${10}" summary_path="${11}" start_path="${12}" phase_review_context="${13:-[]}" rule_pack_resolution="${14:-null}"
  mkdir -p "$(dirname "$start_path")"
  jq -n \
    --argjson source_issue "$issue_json" \
    --arg created_at "$(iso_ts_now)" \
    --arg run_id "$RUN_ID" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg chain "$chain_name" \
    --arg branch "$chain_branch" \
    --arg source_branch "$source_branch" \
    --arg issue_branch "$issue_branch" \
    --arg worktree "$worktree" \
    --arg host "$host" \
    --arg git_metadata_strategy "$git_metadata_strategy" \
    --arg summary_path "$summary_path" \
    --arg execution_mode "$EXECUTION_MODE" \
    --argjson retry_limit "$RETRY_LIMIT" \
    --argjson retry_backoff_sec "$RETRY_BACKOFF_SEC" \
    --argjson phase_review_context "$phase_review_context" \
    --argjson rule_pack_resolution "$rule_pack_resolution" \
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
        source_branch: $source_branch,
        issue_branch: $issue_branch,
        worktree: $worktree,
        host: $host,
        git_metadata_strategy: $git_metadata_strategy
      },
      execution_policy: {
        mode: $execution_mode,
        review_gates: [
          "issue plan phase review before worker launch",
          "worker implementation and summary ingestion",
          "issue outcome phase review over diff and test/lint/build evidence",
          "final chain PR headless review before merge"
        ],
        retry: {
          auto_retry_limit: $retry_limit,
          backoff_seconds: $retry_backoff_sec,
          retryable_halt_classes: ["retryable"],
          prompt_after_exhaustion: false
        },
        escalation: {
          attended_prompts: [
            "reviewer blocked or ambiguous verdict",
            "worker-reported design, implementation, permission, destructive-change, or test blocker",
            "fatal safety or external-state blocker"
          ],
          unattended_behavior: "continue through routine gates; halt only with a typed halt record when a real blocker appears",
          routine_continue_prompts: false
        }
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
        "The chain runner owns PR creation, source-branch merge, issue closure, and worktree cleanup.",
        "Runtime handoff artifacts under .studio are private and disposable.",
        "Prior phase-review feedback in this envelope is private context from a clean outcome review, not human acceptance."
      ],
      rule_pack_resolution: $rule_pack_resolution,
      phase_review_context: $phase_review_context,
      stop_conditions: [
        "Required scope cannot be implemented safely from the source issue.",
        "Verification needed for an unqualified completion claim cannot be run or captured.",
        "The worker would need to change unrelated issues, open a PR, merge to the source branch, close the issue, or commit private .studio artifacts."
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

codex_home_for_worker() {
  local launch_home="$1"
  if [ -n "${CODEX_WORKER_HOME:-}" ]; then
    printf '%s\n' "$CODEX_WORKER_HOME"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
  elif [ -n "${CALLER_HOME:-}" ] && [ -d "$CALLER_HOME/.codex" ]; then
    printf '%s\n' "$CALLER_HOME/.codex"
  elif [ -n "$launch_home" ] && [ -d "$launch_home/.codex" ]; then
    printf '%s\n' "$launch_home/.codex"
  elif [ -n "${HOME:-}" ] && [ -d "$HOME/.codex" ]; then
    printf '%s\n' "$HOME/.codex"
  fi
}

collect_codex_worker_session_telemetry() {
  local host="$1" worktree="$2" started_at="$3" launch_home="$4"
  local codex_home session_dir best_file="" best_mtime=0 candidate mtime
  case "$host" in
    codex*|*codex*) ;;
    *) printf '{}\n'; return 0 ;;
  esac
  codex_home=$(codex_home_for_worker "$launch_home")
  session_dir="$codex_home/sessions"
  [ -n "$codex_home" ] && [ -d "$session_dir" ] || { printf '{}\n'; return 0; }

  while IFS= read -r -d '' candidate; do
    mtime=$(stat -f %m "$candidate" 2>/dev/null || printf '')
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$mtime" -ge "$started_at" ] || continue
    if jq -e --arg cwd "$worktree" '
      select((.type == "session_meta" or .type == "turn_context") and .payload.cwd == $cwd)
    ' "$candidate" >/dev/null 2>&1; then
      if [ -z "$best_file" ] || [ "$mtime" -ge "$best_mtime" ]; then
        best_file="$candidate"
        best_mtime="$mtime"
      fi
    fi
  done < <(find "$session_dir" -type f -name '*.jsonl' -print0 2>/dev/null)

  [ -n "$best_file" ] || { printf '{}\n'; return 0; }
  jq -rs '
    ([ .[] | select(.type == "turn_context") | {model:(.payload.model // null), effort:(.payload.effort // null)} ] | last) as $ctx
    | ([ .[]
        | select(.type == "event_msg" and .payload.type == "token_count" and (.payload.info.total_token_usage // null) != null)
        | .payload.info.total_token_usage
      ] | last) as $usage
    | {
        source: "codex_session_log",
        model: ($ctx.model // null),
        model_version: ($ctx.model // null),
        effort: ($ctx.effort // null),
        tokens: (if $usage == null then null else {
          total: ($usage.total_tokens // null),
          total_tokens: ($usage.total_tokens // null),
          input: ($usage.input_tokens // 0),
          output: ($usage.output_tokens // 0),
          cache_read: ($usage.cached_input_tokens // 0),
          reasoning_output: ($usage.reasoning_output_tokens // 0),
          source: "codex_session_log"
        } end)
      }
    | with_entries(select(.value != null))
  ' "$best_file" 2>/dev/null || printf '{}\n'
}

ingest_worker_summary() {
  local chain_name="$1" issue="$2" host="$3" worktree="$4" before="$5" after="$6" exit_code="$7" started_at="$8" chain_run_id="$9" issue_run_id="${10}" telemetry_file="${11:-}"
  local summary_path="$worktree/.studio/chain-worker-summary.json"
  local dest="$SUMMARY_ROOT/${chain_name}-issue-${issue}-${issue_run_id}.json"
  local ended_at created_at duration_s stats changed_artifacts session_telemetry_json worktree_state next_safe_action
  ended_at=$(now_epoch)
  created_at=$(iso_ts_now)
  duration_s=$(duration_since "$started_at" "$ended_at")
  stats=$(diff_stats_json "$worktree" "$before" "$after")
  changed_artifacts=$(changed_artifacts_json "$worktree" "$before" "$after")
  session_telemetry_json="{}"
  if [ -n "$telemetry_file" ] && [ -f "$telemetry_file" ] && jq -e . "$telemetry_file" >/dev/null 2>&1; then
    session_telemetry_json=$(jq -c . "$telemetry_file")
  fi

  if [ -f "$summary_path" ] && jq -e . "$summary_path" >/dev/null 2>&1; then
    jq -c \
      --arg run_id "$RUN_ID" \
      --arg chain_run_id "$chain_run_id" \
      --arg issue_run_id "$issue_run_id" \
      --arg created_at "$created_at" \
      --arg chain_name "$chain_name" \
      --arg host "$host" \
      --argjson exit_code "$exit_code" \
      --arg before "$before" \
      --arg after "$after" \
      --argjson duration_s "$duration_s" \
      --argjson stats "$stats" \
      --argjson changed_artifacts "$changed_artifacts" \
      --argjson session_telemetry "$session_telemetry_json" \
      '($session_telemetry.tokens // null) as $telemetry_tokens
       | ($session_telemetry.model // $session_telemetry.model_version // null) as $telemetry_model
       | ($session_telemetry.model_version // $session_telemetry.model // null) as $telemetry_model_version
       | ($session_telemetry.effort // $session_telemetry.reasoning_effort // null) as $telemetry_effort
       | (.tokens // $telemetry_tokens) as $final_tokens
       | (.model // .model_name // .model_version // $telemetry_model) as $final_model
       | (.model_version // $telemetry_model_version) as $final_model_version
       | (.effort // .reasoning_effort // $telemetry_effort) as $final_effort
       | (.execution_telemetry // .ios_execution // null) as $exec_telemetry
       | def has_model: ($final_model != null);
       def has_checks: (((.tests // []) | length) + ((.lints // []) | length) + ((.builds // []) | length)) > 0;
       def is_ios_execution:
         (($chain_name | test("ios"; "i"))
          or ((.chain // "") | test("ios"; "i"))
          or (($exec_telemetry.profile // "") | test("ios"; "i"))
          or ($exec_telemetry != null));
       def executor_present($name):
         (($exec_telemetry.executors[$name].executor
           // $exec_telemetry.executors[$name].node
           // $exec_telemetry[($name + "_executor")]
           // null) != null);
       def routing_present:
         (($exec_telemetry.routing.reason_class
           // $exec_telemetry.routing.reason
           // $exec_telemetry.routing.cost_summary
           // null) != null);
       def artifact_present:
         (((($exec_telemetry.artifacts.private_roots
             // $exec_telemetry.private_artifact_roots
             // []) | length)
           + (($exec_telemetry.artifacts.public_classes
             // $exec_telemetry.public_artifact_classes
             // []) | length)) > 0);
       def cleanup_present:
         (($exec_telemetry.cleanup.outcome
           // $exec_telemetry.cleanup.status
           // null) != null
          and (($exec_telemetry.cleanup.retention_class
            // $exec_telemetry.cleanup.ttl_class
            // null) != null));
       def review_applicable:
         ((.review_pass_count // .review_passes // null) != null
          or (((.reviews // []) | length) > 0));
       def release_applicable:
         (($exec_telemetry.executors.release // null) != null
          or (($exec_telemetry.release.applicable // false) == true));
       def ios_execution_gaps:
         if is_ios_execution then
           []
           + (if executor_present("implementation") then [] else ["implementation_executor"] end)
           + (if (((.builds // []) | length) > 0 and (executor_present("build") | not)) then ["build_executor"] else [] end)
           + (if (((.tests // []) | length) > 0 and (executor_present("test") | not)) then ["test_executor"] else [] end)
           + (if (review_applicable and (executor_present("review") | not)) then ["review_executor"] else [] end)
           + (if (release_applicable and (executor_present("release") | not)) then ["release_executor"] else [] end)
           + (if routing_present then [] else ["worker_routing"] end)
           + (if artifact_present then [] else ["artifact_evidence"] end)
           + (if cleanup_present then [] else ["cleanup_telemetry"] end)
         else [] end;
       def normalized_execution_telemetry:
         if $exec_telemetry == null then null
         else $exec_telemetry
           | .schema_version = (.schema_version // 1)
           | .profile = (.profile // (if (($chain_name | test("ios"; "i")) or (((.chain // "") | test("ios"; "i")))) then "ios" else null end))
           | .artifacts.public_classes = ((.artifacts.public_classes // .public_artifact_classes // []) | unique)
           | .artifacts.private_roots = (.artifacts.private_roots // .private_artifact_roots // [])
         end;
       def gap_active($gap):
         if $gap == "tokens" or $gap == "token_usage" then $final_tokens == null
         elif $gap == "model" then (has_model | not)
         elif $gap == "model_version" then $final_model_version == null
         elif $gap == "effort" or $gap == "reasoning_effort" then $final_effort == null
         else true end;
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
        tokens: $final_tokens,
        model: (.model // .model_name // $telemetry_model),
        model_version: $final_model_version,
        effort: $final_effort,
        telemetry_sources: (((.telemetry_sources // []) + (if (($session_telemetry.source // "") == "") then [] else [$session_telemetry.source] end)) | unique),
        execution_telemetry: normalized_execution_telemetry,
        functionality_delivered: (.functionality_delivered // null),
        user_visible_change: (.user_visible_change // .user_facing_change // .change_for_user // .user_change // null),
        carryover: (.carryover // null),
        lessons: (.lessons // null),
        telemetry_gaps: (((.telemetry_gaps // [])
          + ios_execution_gaps
          + (if $final_tokens == null then ["tokens"] else [] end)
          + (if has_model then [] else ["model"] end)
          + (if has_checks then [] else ["tests_lints_builds"] end)) | unique | map(select(gap_active(.))))
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
    worktree_state="clean"
    next_safe_action="retry in a fresh issue worktree is safe only if no public diff exists"
    if chain_git_parent_finalize_has_public_diff "$worktree"; then
      worktree_state="dirty"
      next_safe_action="preserve the issue worktree and inspect uncommitted changes before retry"
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
      --arg worktree_state "$worktree_state" \
      --arg next_safe_action "$next_safe_action" \
      --argjson session_telemetry "$session_telemetry_json" \
      'def ios_execution_gaps:
         if ($chain | test("ios"; "i")) then
           ["implementation_executor", "worker_routing", "artifact_evidence", "cleanup_telemetry"]
         else [] end;
      {
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
        summary_validation: $summary_gap,
        worktree_state: $worktree_state,
        blocked_reason: (if $summary_gap == "worker_summary_missing"
          then "worker exited without writing .studio/chain-worker-summary.json"
          else "worker wrote malformed .studio/chain-worker-summary.json" end),
        failure_summary: "Worker exited without a valid completion summary; parent synthesized this minimal failure summary from exit code, git state, and available telemetry.",
        next_safe_action: $next_safe_action,
        tokens: ($session_telemetry.tokens // null),
        model: ($session_telemetry.model // null),
        model_version: ($session_telemetry.model_version // $session_telemetry.model // null),
        effort: ($session_telemetry.effort // null),
        model_recommendation: null,
        telemetry_sources: (if (($session_telemetry.source // "") == "") then [] else [$session_telemetry.source] end),
        execution_telemetry: null,
        functionality_delivered: null,
        user_visible_change: null,
        carryover: null,
        lessons: null,
        telemetry_gaps: (([$summary_gap, "tests_lints_builds"] + ios_execution_gaps)
          + (if ($session_telemetry.model // $session_telemetry.model_version // null) == null then ["model"] else [] end)
          + (if ($session_telemetry.tokens // null) == null then ["tokens"] else [] end))
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

summary_validation_reason() {
  local summary_file="$1"
  jq -r '.summary_validation // ([.telemetry_gaps[]? | select(. == "worker_summary_missing" or . == "telemetry_artifact_malformed")] | first) // empty' "$summary_file" 2>/dev/null || true
}

missing_summary_retry_eligible() {
  local summary_file="$1" worker_rc="$2" before="$3" after="$4" worktree="$5"
  [ "$worker_rc" -ne 0 ] || return 1
  [ "$before" = "$after" ] || return 1
  [ "$(summary_validation_reason "$summary_file")" = "worker_summary_missing" ] || return 1
  ! chain_git_parent_finalize_has_public_diff "$worktree"
}

issue_failure_summary_text() {
  local issue="$1" worker_rc="$2" summary_file="$3" issue_worktree="$4"
  jq -r \
    --arg issue "$issue" \
    --argjson rc "$worker_rc" \
    --arg summary_file "$summary_file" \
    --arg worktree "$issue_worktree" \
    '"issue #\($issue) worker failed: exit_code=\($rc); summary_status=\(.summary_validation // "valid"); worktree_state=\(.worktree_state // "unknown"); summary=\($summary_file); worktree=\($worktree); next_safe_action=\(.next_safe_action // "inspect the worker summary and halt record before resuming")"' \
    "$summary_file" 2>/dev/null \
    || printf 'issue #%s worker failed: exit_code=%s; summary=%s; worktree=%s' "$issue" "$worker_rc" "$summary_file" "$issue_worktree"
}

generate_run_report() {
  local status="$1" failure_reason="${2:-}" ended_ts ended_epoch duration_s summary_count halt_count halt_dir digest_script
  local latest_event_at state_status state_updated_at tmp_state
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
  latest_event_at=""
  if [ -s "${EVENTS_JSONL:-}" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
    latest_event_at=$(jq -r -s '[ .[] | .created_at? // empty | select(. != "") ] | max // ""' "$EVENTS_JSONL" 2>/dev/null || true)
  fi
  state_status="$status"
  state_updated_at=""
  if [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ]; then
    state_status=$(jq -r '.status // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
    state_updated_at=$(jq -r '.updated_at // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
  fi
  [ -n "$state_status" ] || state_status="$status"
  [ -n "$state_updated_at" ] || state_updated_at="unknown"
  [ -n "$latest_event_at" ] || latest_event_at="none"

  {
    printf '# Studio Chain Run Report\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Manifest: `%s`\n' "$MANIFEST"
    printf -- '- Status: `%s`\n' "$status"
    printf -- '- Report generated: `%s`\n' "$ended_ts"
    printf -- '- Latest event: `%s`\n' "$latest_event_at"
    printf -- '- State status: `%s`\n' "$state_status"
    printf -- '- State updated: `%s`\n' "$state_updated_at"
    printf -- '- Started: `%s`\n' "$RUN_STARTED_TS"
    printf -- '- Ended: `%s`\n' "$ended_ts"
    printf -- '- Duration: `%ss`\n' "$duration_s"
    [ -n "$failure_reason" ] && printf -- '- Failure reason: `%s`\n' "$failure_reason"
    printf '\n'
    render_run_finish_summary "$status" "$failure_reason"
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
    printf '\n## iOS Execution Telemetry\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def et: (.execution_telemetry // .ios_execution // null);
        def cell($v): if $v == null or $v == "" then "missing" else ($v | tostring | gsub("\\|"; "\\|")) end;
        def executor($name): (et.executors[$name].executor // et.executors[$name].node // null);
        def cost_summary:
          (et.routing.cost_summary // (if (et.routing.economics // null) == null then null else (et.routing.economics | tojson) end));
        [
          .[] |
          select((et != null) or (([.telemetry_gaps[]? | select(test("executor|worker_routing|artifact_evidence|cleanup_telemetry"))] | length) > 0))
        ] as $rows |
        if ($rows | length) == 0 then
          "No iOS execution telemetry was supplied."
        else
          "| Issue | Implementation | Build | Test | Review | Release | Routing | Cost/Economics | Public Artifact Classes | Private Roots | Cleanup | Retention | TTL | Gaps |",
          "|---:|---|---|---|---|---|---|---|---|---:|---|---|---|---|",
          ($rows[] |
            "| #\(.issue_number // "unknown") | \(cell(executor("implementation"))) | \(cell(executor("build"))) | \(cell(executor("test"))) | \(cell(executor("review"))) | \(cell(executor("release"))) | \(cell(et.routing.reason_class)) | \(cell(cost_summary)) | \(cell((et.artifacts.public_classes // []) | join(", "))) | \((et.artifacts.private_roots // []) | length) | \(cell(et.cleanup.outcome // et.cleanup.status)) | \(cell(et.cleanup.retention_class)) | \(cell(et.cleanup.ttl_class)) | \((.telemetry_gaps // []) | map(select(test("executor|worker_routing|artifact_evidence|cleanup_telemetry"))) | join(", ")) |"
          )
        end
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No worker summaries were ingested.\n'
    fi
    if [ -s "$EVENTS_JSONL" ] && [ "$EVENTS_JSONL" != "/dev/null" ]; then
      printf '\nEvent counters:\n'
      jq -r -s '
        [.[].event] | group_by(.) | map({event: .[0], count: length}) | sort_by(.event) |
        if length == 0 then "- none" else .[] | "- \(.event): \(.count)" end
      ' "$EVENTS_JSONL" 2>/dev/null || printf -- '- unreadable event log\n'
    fi
    printf '\n## Efficiency Summary\n\n'
    if [ "$summary_count" -gt 0 ]; then
      jq -r -s '
        def token_total:
          (.tokens // null) as $t |
          if $t == null then null
          elif ($t | type) == "number" then $t
          elif ($t | type) == "object" then ($t.total // $t.total_tokens // $t.usage.total_tokens // null)
          else null
          end;
        def bad_outcome:
          ((.outcome // .status // "") | tostring | test("fail|error|flaky"; "i"));
        def bad_count($arr): [($arr // [])[]? | select(bad_outcome)] | length;
        def numeric_or_length:
          if . == null then 0
          elif (type) == "number" then .
          elif (type) == "array" then length
          else (tonumber? // 0)
          end;
        . as $rows |
        ([ $rows[].duration_s? // empty ] | add // 0) as $worker_seconds |
        ([ $rows[] | (.files_changed // null | numeric_or_length) ] | add // 0) as $files |
        ([ $rows[] | token_total | select(. != null) ] | add // null) as $tokens |
        ($rows | max_by(.duration_s // -1)) as $slowest |
        ([ $rows[] | bad_count(.tests) ] | add // 0) as $bad_tests |
        ([ $rows[] | bad_count(.lints) ] | add // 0) as $bad_lints |
        ([ $rows[] | bad_count(.builds) ] | add // 0) as $bad_builds |
        "- Completed issues: \([ $rows[] | select((.exit_code // 1) == 0) ] | length)",
        "- Failed issues: \([ $rows[] | select((.exit_code // 0) != 0) ] | length)",
        "- Average worker duration: \(if ($rows | length) == 0 then "missing" else (($worker_seconds / ($rows | length)) | tostring) end)s",
        "- Seconds per changed file: \(if $files == 0 then "missing" else (($worker_seconds / $files) | tostring) end)",
        "- Tokens per changed file: \(if $tokens == null or $files == 0 then "missing" else (($tokens / $files) | tostring) end)",
        "- Bottleneck: #\($slowest.issue_number // "unknown") at \($slowest.duration_s // "unknown")s",
        "- Rework signals: \($bad_tests) bad/flaky tests, \($bad_lints) bad lints, \($bad_builds) bad builds",
        "",
        "| Issue | Duration | Files | Seconds/File | Tokens/File | Bad Checks | Gaps |",
        "|---:|---:|---:|---:|---:|---:|---|",
        ($rows[] |
          (.files_changed // null | numeric_or_length) as $row_files |
          (token_total) as $row_tokens |
          (bad_count(.tests) + bad_count(.lints) + bad_count(.builds)) as $bad |
          "| #\(.issue_number // "unknown") | \(.duration_s // "unknown")s | \($row_files) | \(if $row_files == 0 or (.duration_s // null) == null then "missing" else (((.duration_s // 0) / $row_files) | tostring) end) | \(if $row_files == 0 or $row_tokens == null then "missing" else (($row_tokens / $row_files) | tostring) end) | \($bad) | \((.telemetry_gaps // []) | join(", ")) |"
        )
      ' "$SUMMARY_ROOT"/*.json
    else
      printf 'No worker summaries were ingested.\n'
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
    if [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ] && [ "$(jq '(.halt_records // []) | length' "$RUN_STATE_JSON" 2>/dev/null || printf 0)" -gt 0 ]; then
      jq -r '
        (.halt_records // []) as $records
        | ($records | map(select((.status // "") == "paused" or (.status // "") == "terminated"))) as $active
        | ($records | map(select((.status // "") == "superseded"))) as $superseded
        | if ($active | length) > 0 then
            ["| Reason | Class | Status | Next Command | Artifact |",
             "|---|---|---|---|---|"],
            ($active[] | "| \(.reason_id) | \(.halt_class) | \(.status) | \(.next_command // "hard stop") | \(.path // "missing") |")
          elif ($superseded | length) > 0 then
            "No active halt records. Superseded halt records: \($superseded | length) (run completed after resume).",
            "",
            "| Reason | Class | Status | Resolution | Artifact |",
            "|---|---|---|---|---|",
            ($superseded[] | "| \(.reason_id) | \(.halt_class) | \(.status) | \(.resolution // "run_completed_after_resume") | \(.path // "missing") |")
          else
            "No active halt records."
          end
      ' "$RUN_STATE_JSON"
    elif [ "$halt_count" -gt 0 ]; then
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
        def gap_regex_count($r): [.[].telemetry_gaps[]? | select(test($r))] | length;
        [
          (if gap_count("worker_summary_missing") > 0 then "- Require worker hosts to write `.studio/chain-worker-summary.json` before exit." else empty end),
          (if gap_count("tokens") > 0 or gap_count("token_usage") > 0 then "- Add host-specific token extraction to worker summaries." else empty end),
          (if gap_count("tests_lints_builds") > 0 then "- Standardize test/lint/build outcome capture in worker summaries." else empty end),
          (if gap_regex_count("executor") > 0 then "- Add iOS executor fields for each applicable implementation, build, test, review, or release role." else empty end),
          (if gap_count("worker_routing") > 0 then "- Attach iOS routing decisions with reason class and economics to worker summaries." else empty end),
          (if gap_count("artifact_evidence") > 0 then "- Attach private iOS artifact roots and public-safe artifact classes to worker summaries." else empty end),
          (if gap_count("cleanup_telemetry") > 0 then "- Attach iOS cleanup outcome and retained TTL class to worker summaries." else empty end)
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
  if [ -n "${RUN_STATE_JSON:-}" ] && [ -f "$RUN_STATE_JSON" ]; then
    tmp_state="$RUN_STATE_JSON.report-generated.$$"
    # Only finish_run and --regenerate-report write reports; any new caller must hold the run-state lock or be fixture-local.
    jq --arg report_generated_at "$ended_ts" \
      '.report_generated_at = $report_generated_at' \
      "$RUN_STATE_JSON" > "$tmp_state"
    mv "$tmp_state" "$RUN_STATE_JSON"
  fi
}

render_run_finish_summary() {
  local status="$1" failure_reason="${2:-}" summary_count run_state_json
  summary_count=0
  [ -n "${SUMMARY_ROOT:-}" ] && summary_count=$(find "$SUMMARY_ROOT" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  run_state_json="${RUN_STATE_JSON:-}"

  printf '## Work-Chain Finish Summary\n\n'
  printf -- '- Status: `%s`\n' "$status"
  printf -- '- Run UUID: `%s`\n' "${RUN_ID:-unknown}"
  [ -n "${FINAL_PR_URL:-}" ] && printf -- '- PR URL: %s\n' "$FINAL_PR_URL"
  [ -n "${RUN_REPORT:-}" ] && printf -- '- Private report: `%s`\n' "$RUN_REPORT"
  [ -n "$failure_reason" ] && printf -- '- Failure reason: `%s`\n' "$failure_reason"
  if [ -n "$run_state_json" ] && [ -f "$run_state_json" ]; then
    jq -r '
      def issue_total: [ .chains[]?.issues[]? ] | length;
      def issue_completed: [ .chains[]?.issues[]? | select((.status // "") == "completed") ] | length;
      def issue_closed: [ .chains[]?.issues[]? | select((.lifecycle_state // "") == "closed") ] | length;
      "- Chains completed: \([ .chains[]? | select((.status // "") == "completed") ] | length)/\((.chains // []) | length)",
      "- Issues completed: \(issue_completed)/\(issue_total)",
      "- Issues closed: \(issue_closed)/\(issue_total)"
    ' "$run_state_json" 2>/dev/null || true
  fi

  printf '\n### What Was Accomplished\n\n'
  if [ "$summary_count" -gt 0 ]; then
    jq -r -s '
      def lines($v):
        if $v == null then []
        elif ($v | type) == "array" then [$v[] | tostring]
        elif ($v | type) == "object" then [$v | tojson]
        else [$v | tostring]
        end;
      [ .[] | {issue:(.issue_number // "unknown"), title:(.issue_title // ""), lines: lines(.functionality_delivered // .summary)} | select(.lines | length > 0) ] as $items |
      if ($items | length) == 0 then "- No accomplishment narrative was supplied by worker summaries."
      else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
      end
    ' "$SUMMARY_ROOT"/*.json
  elif [ -n "$run_state_json" ] && [ -f "$run_state_json" ]; then
    jq -r '
      [ .chains[]?.issues[]? | select((.status // "") == "completed") ] as $issues |
      if ($issues | length) == 0 then "- No completed issues were recorded."
      else $issues[] | "- #\(.number): \(.title // "completed")"
      end
    ' "$run_state_json" 2>/dev/null || printf -- '- No worker summaries were ingested.\n'
  else
    printf -- '- No worker summaries were ingested.\n'
  fi

  printf '\n### User-Facing Change\n\n'
  if [ "$summary_count" -gt 0 ]; then
    jq -r -s '
      def lines($v):
        if $v == null then []
        elif ($v | type) == "array" then [$v[] | tostring]
        elif ($v | type) == "object" then [$v | tojson]
        else [$v | tostring]
        end;
      def user_change:
        .user_visible_change
        // .user_facing_change
        // .change_for_user
        // .user_change
        // .functionality_delivered
        // null;
      [ .[] | {issue:(.issue_number // "unknown"), lines: lines(user_change)} | select(.lines | length > 0) ] as $items |
      if ($items | length) == 0 then "- No user-facing change narrative was supplied by worker summaries."
      else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
      end
    ' "$SUMMARY_ROOT"/*.json
  else
    printf -- '- No user-facing change narrative was supplied by worker summaries.\n'
  fi

  printf '\n### Follow-Up\n\n'
  if [ "$summary_count" -gt 0 ]; then
    jq -r -s '
      def lines($v):
        if $v == null then []
        elif ($v | type) == "array" then [$v[] | tostring]
        elif ($v | type) == "object" then [$v | tojson]
        else [$v | tostring]
        end;
      [ .[] | {issue:(.issue_number // "unknown"), lines: lines(.carryover // .next_recommended_action)} | select(.lines | length > 0) ] as $items |
      if ($items | length) == 0 then "- No carryover was supplied by worker summaries."
      else $items[] | . as $item | $item.lines[] | "- #\($item.issue): \(.)"
      end
    ' "$SUMMARY_ROOT"/*.json
  else
    printf -- '- No carryover was supplied by worker summaries.\n'
  fi
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
  if [ "$status" = "completed" ]; then
    supersede_completed_halt_records
  fi
  duration_s=$(duration_since "$RUN_STARTED_AT")
  emit_chain_event chain_run_completed "" "$RUN_ID" "" "" "$status" "$duration_s" \
    "$(jq -cn --arg report "$RUN_REPORT" --arg reason "$reason" '{report:$report, failure_reason:(if $reason == "" then null else $reason end)}')"
  if [ -n "$RESUME_ID" ]; then
    emit_chain_event chain_resume_attempt_completed "" "$RUN_ID" "" "" "$status" "$duration_s" \
      "$(jq -cn --arg attempt_id "$ATTEMPT_ID" --arg reason "$reason" '{attempt_id:$attempt_id, failure_reason:(if $reason == "" then null else $reason end)}')"
  fi
  generate_run_report "$status" "$reason"
  if [ "$status" = "completed" ] && [ -n "${RUN_WORK_ROOT:-}" ]; then
    rm -rf "$RUN_WORK_ROOT" 2>/dev/null || true
  fi
  log "report written to $RUN_REPORT"
  render_run_finish_summary "$status" "$reason"
}

abort_run() {
  local reason="${1:-failed}"
  write_halt_record "$(halt_reason_for_text "$reason")" "$reason" >/dev/null || log "halt record write failed for: $reason"
  finish_run failed "$reason"
  exit 1
}

abort_run_with_reason() {
  local reason_id="$1" summary="$2"
  write_halt_record "$reason_id" "$summary" >/dev/null || log "halt record write failed for: $summary"
  finish_run failed "$summary"
  exit 1
}

finish_unexpected_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${RUN_FINISHED:-0}" != "1" ] && [ "${DRY_RUN:-0}" -eq 0 ] && [ "${RUN_PATHS_CONFIGURED:-0}" -eq 1 ]; then
    write_halt_record "$(halt_reason_for_text "unexpected_exit_$rc")" "unexpected exit $rc" >/dev/null || log "halt record write failed for unexpected exit $rc"
    finish_run failed "unexpected_exit_$rc"
  fi
  release_state_lock
}

slugify() {
  printf '%s' "$1" | tr '/[:space:]' '--' | tr -cd '[:alnum:]_.-'
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

resolve_existing_path() {
  local path="$1" base="$2" candidate dir base_name
  if [ -z "$path" ] || [ "$path" = "null" ]; then
    return 1
  fi

  case "$path" in
    /*) candidate="$path" ;;
    *)
      if [ -n "$base" ] && [ -e "$base/$path" ]; then
        candidate="$base/$path"
      elif [ -e "$REPO_ROOT/$path" ]; then
        candidate="$REPO_ROOT/$path"
      else
        candidate="$path"
      fi
      ;;
  esac

  [ -e "$candidate" ] || return 1
  dir=$(cd "$(dirname "$candidate")" && pwd -P) || return 1
  base_name=$(basename "$candidate")
  printf '%s/%s\n' "$dir" "$base_name"
}

github_repo_slug_from_hint() {
  local hint="$1" slug owner repo
  [ -n "$hint" ] && [ "$hint" != "null" ] || return 1
  slug=$(printf '%s' "$hint" \
    | sed -E 's#^[[:space:]]+|[[:space:]]+$##g; s#^git@github\.com:##; s#^ssh://git@github\.com/##; s#^https://github\.com/##; s#^http://github\.com/##; s#^git://github\.com/##; s#\.git$##; s#/$##')
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

github_repo_slug_from_remote() {
  local root="$1" remote
  remote=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
  github_repo_slug_from_hint "$remote"
}

same_git_root() {
  local a="$1" b="$2" a_root b_root
  a_root=$(git -C "$a" rev-parse --show-toplevel 2>/dev/null || true)
  b_root=$(git -C "$b" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$a_root" ] && [ -n "$b_root" ] && [ "$a_root" = "$b_root" ]
}

resolve_target_repo_root() {
  local manifest="${1:?usage: resolve_target_repo_root <manifest>}" manifest_dir hint env_hint root
  manifest_dir=$(cd "$(dirname "$manifest")" && pwd -P) || return 1

  hint=$(yq -r '.target_repo_root // .repo_root // .repo.root // ""' "$manifest" 2>/dev/null || true)
  root=$(resolve_existing_path "$hint" "$manifest_dir" 2>/dev/null || true)
  if [ -n "$hint" ] && [ "$hint" != "null" ] && [ -z "$root" ]; then
    printf 'studio-chain-runner: target repo root does not exist: %s\n' "$hint" >&2
    exit 2
  fi
  if [ -z "$root" ]; then
    env_hint="${STUDIO_CHAIN_TARGET_REPO_ROOT:-${STUDIO_CONTEXT_REPO_ROOT:-}}"
    root=$(resolve_existing_path "$env_hint" "$manifest_dir" 2>/dev/null || true)
    if [ -n "$env_hint" ] && [ -z "$root" ]; then
      printf 'studio-chain-runner: target repo root does not exist: %s\n' "$env_hint" >&2
      exit 2
    fi
  fi
  if [ -z "$root" ]; then
    root=$(git -C "$manifest_dir" rev-parse --show-toplevel 2>/dev/null || true)
  fi
  [ -n "$root" ] || root="$REPO_ROOT"

  if ! git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'studio-chain-runner: target repo root is not a git checkout: %s\n' "$root" >&2
    exit 2
  fi
  git -C "$root" rev-parse --show-toplevel
}

resolve_issue_repo_slug() {
  local manifest="${1:?usage: resolve_issue_repo_slug <manifest> <target_repo_root>}" target_root="${2:?usage: resolve_issue_repo_slug <manifest> <target_repo_root>}"
  local hint slug
  hint=$(yq -r '.issue_repo // .repo.issue_repo // .repo.issue // .repo.slug // .repo.name_with_owner // .github.repository // .github.repo // ""' "$manifest" 2>/dev/null || true)
  if [ -n "$hint" ] && [ "$hint" != "null" ]; then
    slug=$(github_repo_slug_from_hint "$hint" || true)
    if [ -z "$slug" ]; then
      printf 'studio-chain-runner: issue_repo must be a GitHub owner/repo slug or github.com URL: %s\n' "$hint" >&2
      exit 2
    fi
    printf '%s\n' "$slug"
    return 0
  fi

  slug=$(github_repo_slug_from_remote "$target_root" || true)
  if [ -n "$slug" ]; then
    printf '%s\n' "$slug"
    return 0
  fi

  if same_git_root "$target_root" "$REPO_ROOT"; then
    printf '%s\n' "$REPO_SLUG_DEFAULT"
    return 0
  fi

  printf 'studio-chain-runner: issue repository is not explicit and could not be resolved for target repo root: %s\n' "$target_root" >&2
  printf 'studio-chain-runner: add issue_repo: owner/repo to the manifest, set repo.issue_repo, or configure origin to a GitHub repository before execution.\n' >&2
  exit 2
}

resolve_new_run_manifest_context() {
  resolve_manifest "$MANIFEST" >/dev/null
  MANIFEST="$RESOLVED_MANIFEST_PATH"
  MANIFEST=$(canonical_path "$MANIFEST")
  preflight_runnable_manifest "$MANIFEST"
  TARGET_REPO_ROOT=$(resolve_target_repo_root "$MANIFEST")
  REPO_SLUG=$(resolve_issue_repo_slug "$MANIFEST" "$TARGET_REPO_ROOT")
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
  [ -n "${CHAIN_RUN_ROOT:-}" ] || return 0
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
  if [ "$action" = "resume" ]; then
    printf -- '- Resume semantics: continue the selected run only; completed and integrated issues are skipped, completed but unintegrated issues are integrated before new work starts, pending dependency-ready issues are relaunched, and failed/halted issues keep their halt record until the cause is corrected.\n'
    printf -- '- Resume command: `scripts/studio-chain-runner.sh --resume %s --yes`\n' "$selected_run_id"
  elif [ "$action" = "start" ]; then
    printf -- '- Namespacing: this run owns `%s/%s/`; chain and issue worktrees are created below that run UUID so concurrent chains cannot share temporary paths.\n' "$RUN_ROOT" "$selected_run_id"
  elif [ "$action" = "refused_hard_stop" ] || [ "$action" = "refused_escrow" ] || [ "$action" = "refused_lock" ]; then
    printf -- '- Resume semantics: automatic resume is refused until the selected run is unlocked or its halt/escrow state is resolved.\n'
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

lock_metadata_json() {
  local reason="$1" lock="$2" pid="${3:-}" created_at="${4:-}" host="${5:-}" process="${6:-}" current_host="${7:-}" current_process="${8:-}"
  jq -cn \
    --arg reason "$reason" \
    --arg lock "$lock" \
    --arg pid "$pid" \
    --arg created_at "$created_at" \
    --arg host "$host" \
    --arg process "$process" \
    --arg current_host "$current_host" \
    --arg current_process "$current_process" \
    '{reason:$reason, lock_path:$lock, pid:(if $pid == "" then null else ($pid|tonumber? // $pid) end), created_at:(if $created_at == "" then null else $created_at end), host:(if $host == "" then null else $host end), process:(if $process == "" then null else $process end), current_host:(if $current_host == "" then null else $current_host end), current_process:(if $current_process == "" then null else $current_process end)}'
}

current_lock_process_name() {
  local pid="$1"
  ps -p "$pid" -o comm= 2>/dev/null | awk '{$1=$1; print}' | head -n 1
}

lock_created_epoch() {
  local created_at="$1"
  [ -n "$created_at" ] || { printf '0\n'; return; }
  jq -nr --arg ts "$created_at" 'try ($ts | fromdateiso8601) catch 0' 2>/dev/null || printf '0\n'
}

write_lock_metadata() {
  local lock="$1" purpose="${2:-state}"
  local process host
  process=$(current_lock_process_name "$$" || true)
  host=$(hostname 2>/dev/null || printf 'unknown')
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "$(iso_ts_now)" > "$lock/created_at"
  printf '%s\n' "$host" > "$lock/host"
  printf '%s\n' "$process" > "$lock/process"
  printf '%s\n' "$purpose" > "$lock/purpose"
}

record_stale_lock_removed() {
  local lock="$1" context="${2:-unknown}" detail
  [ -n "${EVENTS_JSONL:-}" ] && [ "$EVENTS_JSONL" != "/dev/null" ] || return 0
  [ -n "${MANIFEST+x}" ] || return 0
  declare -F emit_chain_event >/dev/null 2>&1 || return 0
  detail="${LOCK_STALE_DETAIL_JSON:-}"
  [ -n "$detail" ] || detail='{}'
  emit_chain_event chain_stale_lock_removed "" "${RUN_ID:-}" "" "" completed 0 \
    "$(jq -cn --arg lock "$lock" --arg context "$context" --arg detail "$detail" '{lock_path:$lock, context:$context, detail:($detail | fromjson? // {})}')"
}

lock_is_stale() {
  local lock="$1" pid created_at host process current_host current_process created_epoch now_epoch max_age age
  LOCK_STALE_DETAIL_JSON=$(lock_metadata_json missing_pid "$lock")
  [ -f "$lock/pid" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  created_at=$(cat "$lock/created_at" 2>/dev/null || true)
  host=$(cat "$lock/host" 2>/dev/null || true)
  process=$(cat "$lock/process" 2>/dev/null || true)
  current_host=$(hostname 2>/dev/null || printf 'unknown')
  case "$pid" in
    ''|*[!0-9]*)
      LOCK_STALE_DETAIL_JSON=$(lock_metadata_json invalid_pid "$lock" "$pid" "$created_at" "$host" "$process" "$current_host")
      return 0
      ;;
  esac
  if [ -n "$host" ] && [ "$host" != "$current_host" ]; then
    max_age=$(positive_int_or_default "${STUDIO_CHAIN_LOCK_STALE_S:-900}" 900)
    created_epoch=$(lock_created_epoch "$created_at")
    now_epoch=$(now_epoch)
    age=$((now_epoch - created_epoch))
    if [ "$created_epoch" -le 0 ] || [ "$age" -ge "$max_age" ]; then
      LOCK_STALE_DETAIL_JSON=$(lock_metadata_json cross_host_expired "$lock" "$pid" "$created_at" "$host" "$process" "$current_host")
      return 0
    fi
    LOCK_STALE_DETAIL_JSON=$(lock_metadata_json cross_host_unverified_live "$lock" "$pid" "$created_at" "$host" "$process" "$current_host")
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    current_process=$(current_lock_process_name "$pid" || true)
    if [ -n "$process" ] && [ -n "$current_process" ] && [ "$process" != "$current_process" ]; then
      LOCK_STALE_DETAIL_JSON=$(lock_metadata_json process_mismatch "$lock" "$pid" "$created_at" "$host" "$process" "$current_host" "$current_process")
      return 0
    fi
    LOCK_STALE_DETAIL_JSON=$(lock_metadata_json pid_live "$lock" "$pid" "$created_at" "$host" "$process" "$current_host" "$current_process")
    return 1
  fi
  LOCK_STALE_DETAIL_JSON=$(lock_metadata_json pid_dead "$lock" "$pid" "$created_at" "$host" "$process" "$current_host")
  return 0
}

positive_int_or_default() {
  local value="$1" fallback="$2"
  case "$value" in
    ''|*[!0-9]*|0) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

chain_artifact_hygiene_sweep() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  local tmp_retention_days run_retention_days max_bytes lock run_dir state status artifact
  tmp_retention_days=$(positive_int_or_default "${STUDIO_CHAIN_TMP_RETENTION_DAYS:-2}" 2)
  run_retention_days=$(positive_int_or_default "${STUDIO_CHAIN_RUN_RETENTION_DAYS:-30}" 30)
  max_bytes=$(positive_int_or_default "${STUDIO_CHAIN_ARTIFACT_MAX_BYTES:-1048576}" 1048576)

  mkdir -p "$RUN_ROOT" "$CHAIN_RUNS_ROOT"

  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    if lock_is_stale "$lock"; then
      record_stale_lock_removed "$lock" startup-hygiene
      rm -rf "$lock"
    fi
  done <<EOF
$(find "$CHAIN_RUNS_ROOT" -type d \( -name 'state.json.lock' -o -name 'state.json.update.lock' \) 2>/dev/null)
EOF

  while IFS= read -r run_dir; do
    [ -n "$run_dir" ] || continue
    [ "$run_dir" = "$RUN_WORK_ROOT" ] && continue
    rm -rf "$run_dir"
  done <<EOF
$(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$tmp_retention_days" 2>/dev/null)
EOF

  if command -v gzip >/dev/null 2>&1; then
    while IFS= read -r artifact; do
      [ -n "$artifact" ] || continue
      case "$artifact" in
        "$CHAIN_RUN_ROOT"/*|*.gz) continue ;;
      esac
      gzip -f "$artifact" 2>/dev/null || true
    done <<EOF
$(find "$CHAIN_RUNS_ROOT" -type f \( -name 'events.jsonl' -o -name 'report.md' -o -name '*.out' \) -size +"$max_bytes"c 2>/dev/null)
EOF
  fi

  while IFS= read -r state; do
    [ -n "$state" ] || continue
    run_dir=$(dirname "$state")
    [ "$run_dir" = "$CHAIN_RUN_ROOT" ] && continue
    status=$(jq -r '.status // "unknown"' "$state" 2>/dev/null || printf 'unknown')
    [ "$status" = "completed" ] || continue
    if [ -n "$(find "$run_dir" -maxdepth 0 -type d -mtime +"$run_retention_days" -print -quit 2>/dev/null)" ]; then
      rm -rf "$run_dir"
    fi
  done <<EOF
$(find "$CHAIN_RUNS_ROOT" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null)
EOF

  ios_artifact_janitor_startup_sweep
}

ios_artifact_tmp_base() {
  local tmp_base
  tmp_base="${TMPDIR:-/tmp}"
  tmp_base="${tmp_base%/}"
  [ -n "$tmp_base" ] || tmp_base="/tmp"
  printf '%s/studio-ios-artifacts\n' "$tmp_base"
}

ios_artifact_janitor_startup_sweep() {
  local janitor tmp_base persisted_base
  janitor="$SCRIPT_DIR/studio-ios-artifact-janitor.sh"
  [ -x "$janitor" ] || return 0
  tmp_base=$(ios_artifact_tmp_base)
  if [ -d "$tmp_base" ]; then
    "$janitor" sweep --base "$tmp_base" --json >/dev/null 2>&1 || true
  fi
  if [ -d "$CHAIN_RUNS_ROOT" ]; then
    while IFS= read -r persisted_base; do
      [ -n "$persisted_base" ] || continue
      "$janitor" sweep --base "$persisted_base" --json >/dev/null 2>&1 || true
    done <<EOF
$(find "$CHAIN_RUNS_ROOT" -mindepth 2 -maxdepth 2 -type d -name ios-artifacts 2>/dev/null)
EOF
  fi
}

ios_chain_artifact_root() {
  local chain_run_id="$1"
  printf '%s/ios-artifacts/%s\n' "$CHAIN_RUN_ROOT" "$chain_run_id"
}

run_ios_artifact_chain_cleanup() {
  local chain_name="$1" chain_run_id="$2" chain_status="$3"
  local janitor root telemetry_file telemetry rc=0
  janitor="$SCRIPT_DIR/studio-ios-artifact-janitor.sh"
  [ -x "$janitor" ] || return 0
  root=$(ios_chain_artifact_root "$chain_run_id")
  [ -d "$root" ] || return 0
  telemetry_file="$CHAIN_RUN_ROOT/ios-artifact-cleanup-$chain_run_id.json"
  set +e
  telemetry=$("$janitor" complete-chain --root "$root" --status "$chain_status" --json 2>/dev/null)
  rc=$?
  set -e
  if [ -n "$telemetry" ]; then
    printf '%s\n' "$telemetry" > "$telemetry_file"
    emit_chain_event chain_ios_artifact_cleanup_completed "" "$RUN_ID" "$chain_run_id" "" completed 0 \
      "$(jq -c --arg chain "$chain_name" --arg artifact "$telemetry_file" --argjson janitor_rc "$rc" '. + {chain:$chain, telemetry_artifact:$artifact, janitor_exit_code:$janitor_rc}' "$telemetry_file")"
  fi
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
    write_lock_metadata "$lock" supervisor
    return 0
  fi
  if lock_is_stale "$lock"; then
    record_stale_lock_removed "$lock" supervisor
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      SUPERVISOR_LOCK="$lock"
      SUPERVISOR_LOCK_ACQUIRED=1
      write_lock_metadata "$lock" supervisor
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
  local state_view state_status
  MANIFEST="$manifest"
  resolve_new_run_manifest_context
  states=$(supervisor_matching_states "$MANIFEST" || true)
  candidates_json='[]'
  while IFS= read -r state; do
    [ -n "$state" ] || continue
    state_view=$(mktemp -t studio-chain-supervisor-state.XXXXXX)
    projected_state_for_read "$state" "$state_view"
    run_id=$(supervisor_state_run_id "$state_view")
    if [ -z "$run_id" ]; then
      rm -f "$state_view"
      continue
    fi
    state_status=$(jq -r '.status // "unknown"' "$state_view")
    if [ "$state_status" = "completed" ]; then
      completed=$((completed + 1))
      rm -f "$state_view"
      continue
    fi
    if state_has_true_hard_stop "$state_view"; then
      hard_stop=$((hard_stop + 1))
      candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
      rm -f "$state_view"
      continue
    fi
    if state_has_open_decision_escrow "$state_view"; then
      escrow=$((escrow + 1))
      candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
      rm -f "$state_view"
      continue
    fi
    eligible=$((eligible + 1))
    selected_state="$state"
    selected_run_id="$run_id"
    candidates_json=$(printf '%s' "$candidates_json" | jq --arg run_id "$run_id" '. + [$run_id]')
    rm -f "$state_view"
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

run_retryable() {
  local reason_id="$1"
  shift
  local attempt=0 rc=0

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN retry[%s] limit=%s backoff=%ss' "$reason_id" "$RETRY_LIMIT" "$RETRY_BACKOFF_SEC"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  while :; do
    set +e
    "$@"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -ge "$RETRY_LIMIT" ]; then
      log "retry exhausted for $reason_id after $attempt retry attempt(s): $*"
      return "$rc"
    fi
    attempt=$((attempt + 1))
    log "retry $attempt/$RETRY_LIMIT for $reason_id after exit $rc: $*"
    [ "$RETRY_BACKOFF_SEC" -gt 0 ] && sleep "$RETRY_BACKOFF_SEC"
  done
}

run_retryable_or_abort() {
  local reason_id="$1" summary="$2"
  shift 2
  run_retryable "$reason_id" "$@" || abort_run_with_reason "$reason_id" "$summary"
}

validate_branch_ref() {
  local ref="$1" label="$2"
  if ! git check-ref-format --branch "$ref" >/dev/null 2>&1; then
    printf 'studio-chain-runner: invalid %s branch name: %s\n' "$label" "$ref" >&2
    exit 2
  fi
}

validate_chain_branch() {
  local branch="$1" source_branch="$2"
  validate_branch_ref "$source_branch" "source"
  validate_branch_ref "$branch" "chain"

  if [ "$branch" = "$source_branch" ]; then
    printf 'studio-chain-runner: chain branch must not equal source branch: %s\n' "$branch" >&2
    exit 2
  fi

  case "$source_branch" in
    feature|production|develop|trunk)
      printf 'studio-chain-runner: protected source branch targets are not allowed: %s\n' "$source_branch" >&2
      exit 2
      ;;
  esac

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
  case "$spawn" in
    /*) ;;
    *[[:space:]]*)
      local first rest
      first=${spawn%%[[:space:]]*}
      rest=${spawn#"$first"}
      case "$first" in
        /*) ;;
        */*) first="$REPO_ROOT/$first" ;;
      esac
      spawn="$first$rest"
      ;;
    */*)
      spawn="$REPO_ROOT/$spawn"
      ;;
  esac
  printf '%s\n' "$spawn"
}

yaml_field() {
  yq -r ".${2} // \"\"" "$1" 2>/dev/null
}

normalize_manifest_value() {
  case "${1:-}" in
    ""|null) return 0 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

manifest_chain_field() {
  local chain_idx="$1" field="$2" value
  value=$(yq -r ".chains[$chain_idx].$field // \"\"" "$MANIFEST")
  normalize_manifest_value "$value"
}

resolve_chain_source_branch() {
  local chain_idx="$1" chain_name="$2"
  local source_branch target_base base selected="" label value
  source_branch=$(manifest_chain_field "$chain_idx" source_branch)
  target_base=$(manifest_chain_field "$chain_idx" target_base)
  base=$(manifest_chain_field "$chain_idx" base)

  for label in source_branch target_base base; do
    case "$label" in
      source_branch) value="$source_branch" ;;
      target_base) value="$target_base" ;;
      base) value="$base" ;;
    esac
    [ -n "$value" ] || continue
    if [ -z "$selected" ]; then
      selected="$value"
    elif [ "$selected" != "$value" ]; then
      printf 'studio-chain-runner: conflicting source branch fields for chain %s: %s=%s conflicts with selected source %s\n' \
        "$chain_name" "$label" "$value" "$selected" >&2
      exit 2
    fi
  done

  [ -n "$selected" ] || selected="main"
  printf '%s\n' "$selected"
}

resolve_chain_expected_source_sha() {
  local chain_idx="$1" value
  value=$(yq -r ".chains[$chain_idx].expected_source_sha // .chains[$chain_idx].source_sha // \"\"" "$MANIFEST")
  normalize_manifest_value "$value"
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

codex_auth_home_for_worker_launch() {
  local launch_home="${1:-}"
  if [ -n "${CODEX_WORKER_HOME:-}" ]; then
    printf '%s\n' "$CODEX_WORKER_HOME"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
  elif [ -n "$CALLER_HOME" ] && [ -d "$CALLER_HOME/.codex" ]; then
    printf '%s\n' "$CALLER_HOME/.codex"
  elif [ -n "$launch_home" ] && [ -d "$launch_home/.codex" ]; then
    printf '%s\n' "$launch_home/.codex"
  elif [ -n "${HOME:-}" ] && [ -d "$HOME/.codex" ]; then
    printf '%s\n' "$HOME/.codex"
  fi
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

chain_node_health_timeout_s() {
  local timeout_s="${STUDIO_CHAIN_NODE_HEALTH_TIMEOUT_S:-12}"
  case "$timeout_s" in ''|*[!0-9]*|0) timeout_s=12 ;; esac
  printf '%s\n' "$timeout_s"
}

chain_node_health_first_row() {
  local health_cmd="$1" id="$2" timeout_s="$3"
  local out pid started rc elapsed
  out=$(mktemp -t studio-chain-node-health.XXXXXX) || return 125
  if (
    set +e
    set -m
    "$health_cmd" "$id" >"$out" 2>/dev/null &
    pid=$!
    started=$(now_epoch)
    rc=""
    while kill -0 "$pid" 2>/dev/null; do
      elapsed=$(( $(now_epoch) - started ))
      if [ "$elapsed" -ge "$timeout_s" ]; then
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
        break
      fi
      sleep 1
    done
    if [ -z "$rc" ]; then
      wait "$pid"
      rc=$?
    fi
    exit "$rc"
  ) 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  sed -n '1p' "$out"
  rm -f "$out"
  return "$rc"
}

healthy_xcodebuild_offload_count() {
  local registry ids id row status health_cmd count=0 timeout_s degraded=0 probe_rc
  registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf '0\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0\n'; return 0; }
  health_cmd="${STUDIO_CHAIN_NODE_HEALTH_CMD:-$SCRIPT_DIR/node-health.sh}"
  timeout_s=$(chain_node_health_timeout_s)

  ids=$(jq -r '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index("xcodebuild")) | .id' "$registry" 2>/dev/null) || ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if node_is_self "$id"; then
      continue
    fi
    if row=$(chain_node_health_first_row "$health_cmd" "$id" "$timeout_s"); then
      :
    else
      probe_rc=$?
      case "$probe_rc" in
        124) log "worker-pool node-health degraded: timed out probing $id after ${timeout_s}s; excluding node from auto pool" ;;
        *) log "worker-pool node-health degraded: probe failed for $id; excluding node from auto pool" ;;
      esac
      degraded=$((degraded + 1))
      continue
    fi
    status=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
    case "$status" in
      healthy|moved) count=$((count + 1)) ;;
      *) degraded=$((degraded + 1)) ;;
    esac
  done <<EOF
$ids
EOF
  if [ "$degraded" -gt 0 ]; then
    log "worker-pool auto sizing: healthy_offload_nodes=$count degraded_offload_nodes=$degraded timeout_s=$timeout_s local_worker_included=1"
  fi
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
  local out="$1" chain_count idx name base source_branch expected_source_sha branch host approved_release_id sync_strategy phase_review_mode checkpoint_mode git_metadata_strategy issue_count i issue issue_json issue_title issue_state issue_url
  local chain_run_id issue_run_id issue_slug issue_branch issue_worktree chain_slug chain_worktree worker_pool issue_kind dependencies_json previous_issue
  local tmp chains_tmp issues_tmp mapped_at
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
    source_branch=$(resolve_chain_source_branch "$idx" "$name")
    base="$source_branch"
    expected_source_sha=$(resolve_chain_expected_source_sha "$idx")
    branch=$(yq -r ".chains[$idx].branch // (\"feature/\" + .chains[$idx].name)" "$MANIFEST")
    host=$(yq -r ".chains[$idx].host // \"auto\"" "$MANIFEST")
    approved_release_id=$(yq -r ".chains[$idx].approved_release_id // \"\"" "$MANIFEST")
    sync_strategy=$(yq -r ".chains[$idx].sync_strategy // \"rebase\"" "$MANIFEST")
    [ -n "$sync_strategy" ] && [ "$sync_strategy" != "null" ] || sync_strategy="rebase"
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
    chain_worktree="$RUN_WORK_ROOT/$chain_slug-feature"
    worker_pool=$(chain_worker_pool_size)
    issues_tmp="$out.issues.$$"
    printf '[]\n' > "$issues_tmp"
    previous_issue=""
    for ((i = 0; i < issue_count; i++)); do
      issue_kind=$(yq -r ".chains[$idx].issues[$i] | type" "$MANIFEST")
      case "$issue_kind" in
        '!!int'|number)
          issue=$(yq -r ".chains[$idx].issues[$i]" "$MANIFEST")
          if [ -n "$previous_issue" ]; then
            dependencies_json=$(jq -cn --argjson dep "$previous_issue" '[$dep]')
          else
            dependencies_json='[]'
          fi
          ;;
        '!!map'|object)
          issue=$(yq -r ".chains[$idx].issues[$i].number // .chains[$idx].issues[$i].issue // \"\"" "$MANIFEST")
          dependencies_json=$(yq -o=json ".chains[$idx].issues[$i].dependencies // .chains[$idx].issues[$i].depends_on // []" "$MANIFEST" | jq -c '
            if type == "array" then map(tonumber)
            elif . == null then []
            else [tonumber]
            end
          ')
          ;;
        *)
          printf 'studio-chain-runner: invalid issue entry in chain %s at index %s\n' "$name" "$i" >&2
          exit 2
          ;;
      esac
      case "$issue" in ''|null|*[!0-9]*)
        printf 'studio-chain-runner: invalid issue id in chain %s: %s\n' "$name" "$issue" >&2
        exit 2
        ;;
      esac
      if ! printf '%s\n' "$dependencies_json" | jq -e 'type == "array" and all(.[]; (type == "number") and . > 0)' >/dev/null; then
        printf 'studio-chain-runner: invalid dependencies for issue #%s in chain %s\n' "$issue" "$name" >&2
        exit 2
      fi
      issue_json=$(with_login_home_for_github gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,state,url)
      issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
      issue_state=$(printf '%s' "$issue_json" | jq -r '.state')
      issue_url=$(printf '%s' "$issue_json" | jq -r '.url // ""')
      if [ "$ALLOW_CLOSED_ISSUES" -eq 0 ] && [ "$issue_state" != "OPEN" ]; then
        printf 'studio-chain-runner: issue #%s is %s; use --allow-closed-issues to include it\n' "$issue" "$issue_state" >&2
        exit 2
      fi
      issue_slug=$(slugify "$issue")
      issue_branch="$branch-issue-$issue_slug"
      validate_branch_ref "$issue_branch" "issue"
      issue_worktree="$RUN_WORK_ROOT/$chain_slug-issue-$issue_slug"
      issue_run_id=$(mint_uuidv7)
      mapped_at=$(iso_ts_now)
      jq \
        --argjson issue "$issue" \
        --arg title "$issue_title" \
        --arg state "$issue_state" \
        --arg url "$issue_url" \
        --arg issue_repo "$REPO_SLUG" \
        --arg chain_run_id "$chain_run_id" \
        --arg branch "$issue_branch" \
        --arg worktree "$issue_worktree" \
        --arg issue_run_id "$issue_run_id" \
        --arg mapped_at "$mapped_at" \
        --argjson dependencies "$dependencies_json" \
        '. + [{
          number:$issue,
          title:$title,
          state:$state,
          url:(if $url == "" then null else $url end),
          issue_repo:$issue_repo,
          dependencies:$dependencies,
          chain_run_id:$chain_run_id,
          issue_branch:$branch,
          issue_worktree:$worktree,
          issue_run_id:$issue_run_id,
          status:"pending",
          lifecycle_state:"issue-created",
          lifecycle_history:[{state:"issue-created", at:$mapped_at, reason:"github-issue-mapping"}],
          provenance:{
            issue:{
              number:$issue,
              title:$title,
              state:$state,
              url:(if $url == "" then null else $url end),
              repo:$issue_repo,
              mapped_at:$mapped_at
            },
            session:{
              chain_run_id:$chain_run_id,
              issue_run_id:$issue_run_id,
              issue_branch:$branch,
              issue_worktree:$worktree
            }
          }
        }]' \
        "$issues_tmp" > "$issues_tmp.next"
      mv "$issues_tmp.next" "$issues_tmp"
      previous_issue="$issue"
    done
    jq \
      --arg name "$name" \
      --arg base "$base" \
      --arg source_branch "$source_branch" \
      --arg expected_source_sha "$expected_source_sha" \
      --arg branch "$branch" \
      --arg host "$host" \
      --arg approved_release_id "$approved_release_id" \
      --arg sync_strategy "$sync_strategy" \
      --arg phase_review_mode "$phase_review_mode" \
      --arg checkpoint_mode "$checkpoint_mode" \
      --arg git_metadata_strategy "$git_metadata_strategy" \
      --arg chain_run_id "$chain_run_id" \
      --arg worktree "$chain_worktree" \
      --argjson worker_pool "$worker_pool" \
      --slurpfile issues "$issues_tmp" \
      '. + [{
        name:$name,
        base:$base,
        source_branch:$source_branch,
        expected_source_sha:(if $expected_source_sha == "" then null else $expected_source_sha end),
        branch:$branch,
        host:$host,
        approved_release_id:(if $approved_release_id == "" then null else $approved_release_id end),
        sync_strategy:$sync_strategy,
        phase_review:$phase_review_mode,
        checkpoint:$checkpoint_mode,
        git_metadata_strategy:$git_metadata_strategy,
        chain_run_id:$chain_run_id,
        chain_worktree:$worktree,
        worker_pool:$worker_pool,
        status:"pending",
        issues:$issues[0]
      }]' \
      "$chains_tmp" > "$chains_tmp.next"
    mv "$chains_tmp.next" "$chains_tmp"
    rm -f "$issues_tmp"
  done

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg manifest "$MANIFEST" \
    --arg target_repo_root "$TARGET_REPO_ROOT" \
    --arg issue_repo "$REPO_SLUG" \
    --arg only_chain "$ONLY_CHAIN" \
    --arg host_override "$HOST_OVERRIDE" \
    --arg parallel_chains "$PARALLEL_CHAINS" \
    --arg checkpoint_override "$CHECKPOINT_OVERRIDE" \
    --arg execution_mode "$EXECUTION_MODE" \
    --argjson retry_limit "$RETRY_LIMIT" \
    --argjson retry_backoff_sec "$RETRY_BACKOFF_SEC" \
    --slurpfile chains "$chains_tmp" \
    '{
      schema_version:1,
      run_id:$run_id,
      manifest:$manifest,
      target_repo_root:$target_repo_root,
      issue_repo:$issue_repo,
      only_chain:(if $only_chain == "" then null else $only_chain end),
      host_override:(if $host_override == "" then null else $host_override end),
      parallel_chains:$parallel_chains,
      checkpoint_override:(if $checkpoint_override == "" then null else $checkpoint_override end),
      execution_mode:$execution_mode,
      retry_policy:{
        auto_retry_limit:$retry_limit,
        backoff_seconds:$retry_backoff_sec,
        retryable_halt_classes:["retryable"],
        prompt_after_exhaustion:false
      },
      review_gates:[
        "issue plan phase review before worker launch",
        "worker implementation and summary ingestion",
        "issue outcome phase review over diff and test/lint/build evidence",
        "final chain PR headless review before merge"
      ],
      escalation_policy:{
        routine_continue_prompts:false,
        prompt_only_for:["review-needed", "human-needed", "fatal"],
        unattended_halt_classes:["review-needed", "human-needed", "fatal"]
      },
      chains:$chains[0]
    }' > "$tmp"
  mv "$tmp" "$out"
  rm -f "$chains_tmp"
}

validate_execution_graph() {
  local plan="$1"
  local provenance_audit_gaps duplicate_issues duplicate_branches protected_targets dependency_conflicts invalid_issue_dependencies
  provenance_audit_gaps=$(jq -r '
    def doneish:
      (((.status? // .lifecycle_state? // .state? // "") | tostring) | test("done|completed|implemented|smoke-passed|merged|closed"; "i"))
      or (.done? == true)
      or (.completed? == true);
    [
      .chains[]? as $chain
      | $chain.issues[]? as $issue
      | select(($issue | type) == "object")
      | select($issue | doneish)
      | select((($issue.number // $issue.issue // $issue.provenance.issue.number // null) == null))
      | "\($chain.name // "unknown"):index-\(([$chain.issues[]?] | index($issue)) // "unknown")"
    ] | join(", ")
  ' "$plan")
  [ -z "$provenance_audit_gaps" ] || {
    printf 'studio-chain-runner: audit gap: completed/imported issue state lacks durable issue mapping: %s\n' "$provenance_audit_gaps" >&2
    printf 'studio-chain-runner: map each done task to a GitHub issue before treating implementation state as authoritative.\n' >&2
    exit 2
  }
  local same_source_chain
  duplicate_issues=$(jq -r '[.chains[].issues[].number] | group_by(.)[] | select(length > 1) | .[0]' "$plan" | paste -sd, -)
  [ -z "$duplicate_issues" ] || { printf 'studio-chain-runner: duplicate issue IDs across chains: %s\n' "$duplicate_issues" >&2; exit 2; }
  duplicate_branches=$(jq -r '[.chains[].branch, (.chains[].issues[].issue_branch)] | group_by(.)[] | select(length > 1) | .[0]' "$plan" | paste -sd, -)
  [ -z "$duplicate_branches" ] || { printf 'studio-chain-runner: duplicate branch refs in plan: %s\n' "$duplicate_branches" >&2; exit 2; }
  protected_targets=$(jq -r '.chains[] | (.source_branch // .base) | select(. == "feature" or . == "production" or . == "develop" or . == "trunk")' "$plan" | paste -sd, -)
  [ -z "$protected_targets" ] || { printf 'studio-chain-runner: protected source branch targets are not allowed: %s\n' "$protected_targets" >&2; exit 2; }
  same_source_chain=$(jq -r '.chains[] | select(.branch == (.source_branch // .base)) | .name' "$plan" | paste -sd, -)
  [ -z "$same_source_chain" ] || { printf 'studio-chain-runner: chain branch must not equal source branch for chains: %s\n' "$same_source_chain" >&2; exit 2; }
  invalid_issue_dependencies=$(jq -r '
    .chains[] as $chain
    | ($chain.issues | map(.number)) as $numbers
    | $chain.issues[]
    | . as $issue
    | (.dependencies // [])[]
    | select(($numbers | index(.)) == null or . == $issue.number)
    | "#\($issue.number)->#\(.)"
  ' "$plan" | paste -sd, -)
  [ -z "$invalid_issue_dependencies" ] || { printf 'studio-chain-runner: invalid issue dependencies: %s\n' "$invalid_issue_dependencies" >&2; exit 2; }
  dependency_conflicts=$(yq -r '[.chains[] | select(has("depends_on") or has("dependencies"))] | length' "$MANIFEST")
  if [ "$dependency_conflicts" != "0" ] && [ "$PARALLEL_CHAINS" != "1" ]; then
    log "dependency metadata present; falling back to sequential chain execution"
    PARALLEL_CHAINS="1"
  fi
}

attach_rule_pack_resolutions() {
  local plan="$1" tmp chain_count idx issue_count issue_idx name issue resolution_file resolver_rc
  [ -x "$SCRIPT_DIR/rule-pack-resolve.sh" ] || return 0
  tmp="$plan.rule-packs.$$"
  cp "$plan" "$tmp"
  chain_count=$(jq -r '.chains | length' "$tmp")
  for ((idx = 0; idx < chain_count; idx++)); do
    name=$(jq -r ".chains[$idx].name" "$tmp")
    resolution_file="$tmp.rule-pack-resolution.$idx.json"
    set +e
    "$SCRIPT_DIR/rule-pack-resolve.sh" \
      --manifest "$MANIFEST" \
      --chain "$name" \
      --role worker \
      --mode chain_runner \
      --phase implementation >"$resolution_file"
    resolver_rc=$?
    set -e
    if [ "$resolver_rc" -ne 0 ] && [ "$resolver_rc" -ne 3 ]; then
      rm -f "$tmp" "$resolution_file"
      printf 'studio-chain-runner: rule-pack resolver failed for chain %s\n' "$name" >&2
      exit "$resolver_rc"
    fi
    jq --argjson idx "$idx" --slurpfile resolution "$resolution_file" \
      '.chains[$idx].rule_pack_resolution = $resolution[0]' \
      "$tmp" >"$tmp.next"
    mv "$tmp.next" "$tmp"
    rm -f "$resolution_file"
    issue_count=$(jq -r ".chains[$idx].issues | length" "$tmp")
    for ((issue_idx = 0; issue_idx < issue_count; issue_idx++)); do
      issue=$(jq -r ".chains[$idx].issues[$issue_idx].number" "$tmp")
      resolution_file="$tmp.rule-pack-resolution.$idx.$issue_idx.json"
      set +e
      "$SCRIPT_DIR/rule-pack-resolve.sh" \
        --manifest "$MANIFEST" \
        --chain "$name" \
        --issue "$issue" \
        --role worker \
        --mode chain_runner \
        --phase implementation >"$resolution_file"
      resolver_rc=$?
      set -e
      if [ "$resolver_rc" -ne 0 ] && [ "$resolver_rc" -ne 3 ]; then
        rm -f "$tmp" "$resolution_file"
        printf 'studio-chain-runner: rule-pack resolver failed for chain %s issue #%s\n' "$name" "$issue" >&2
        exit "$resolver_rc"
      fi
      jq --argjson idx "$idx" --argjson issue_idx "$issue_idx" --slurpfile resolution "$resolution_file" \
        '.chains[$idx].issues[$issue_idx].rule_pack_resolution = $resolution[0]' \
        "$tmp" >"$tmp.next"
      mv "$tmp.next" "$tmp"
      rm -f "$resolution_file"
    done
  done
  mv "$tmp" "$plan"
}

rule_pack_resolution_blocked() {
  local plan="$1"
  jq -e '
    [
      (.chains[].rule_pack_resolution? | select((.status // "ok") == "halt")),
      (.chains[].issues[].rule_pack_resolution? | select((.status // "ok") == "halt"))
    ] | length > 0
  ' "$plan" >/dev/null 2>&1
}

apply_mechanical_rule_gates() {
  local plan="$1" tmp gate_result gate_rc audit_log
  local -a gate_args
  [ -x "$SCRIPT_DIR/studio-chain-rule-gates.sh" ] || return 0
  tmp="$plan.gates.$$"
  gate_result="$plan.gates.result.$$"
  audit_log="$CHAIN_RUN_ROOT/rule-pack-gates.jsonl"
  gate_args=(
    --plan "$plan"
    --manifest "$MANIFEST"
    --repo "$TARGET_REPO_ROOT"
    --expected-run-work-root "$RUN_WORK_ROOT"
  )
  if [ "$DRY_RUN" -eq 0 ]; then
    gate_args+=(--audit-log "$audit_log")
  else
    audit_log=""
    gate_args+=(--dry-run)
  fi

  set +e
  "$SCRIPT_DIR/studio-chain-rule-gates.sh" "${gate_args[@]}" >"$gate_result"
  gate_rc=$?
  set -e
  if [ "$gate_rc" -ne 0 ] && [ "$gate_rc" -ne 4 ]; then
    rm -f "$gate_result"
    printf 'studio-chain-runner: mechanical rule gate failed to run\n' >&2
    exit "$gate_rc"
  fi
  jq --slurpfile gates "$gate_result" '.mechanical_rule_gates = $gates[0]' "$plan" >"$tmp"
  mv "$tmp" "$plan"
  if jq -e '.mechanical_rule_gates.overrides[]? | select(.id == "chain_manifest_sync_strategy")' "$plan" >/dev/null 2>&1; then
    jq '(.chains[] | select((.sync_strategy // "rebase") != "rebase" and (.sync_strategy // "rebase") != "squash") | .sync_strategy) = "rebase"' "$plan" >"$tmp"
    mv "$tmp" "$plan"
  fi
  emit_chain_event chain_rule_gate_completed "" "$RUN_ID" "" "" "$(jq -r '.status' "$gate_result")" 0 \
    "$(jq -c '{audit_log, checks:([.checks[] | {id,status,severity,override_env}]), failure_count:(.failures | length), override_count:(.overrides | length)}' "$gate_result")"
  if [ "$gate_rc" -eq 4 ]; then
    jq -r '.failures[] | "studio-chain-runner: rule gate blocked: \(.id) - \(.detail) (override: \(.override_env // "none"))"' "$gate_result" >&2
    rm -f "$gate_result"
    exit 4
  fi
  rm -f "$gate_result"
}

chain_policy_audit_log() {
  local audit_log=""
  if [ -f "$PLAN_JSON" ]; then
    audit_log=$(jq -r '.mechanical_rule_gates.audit_log // empty' "$PLAN_JSON" 2>/dev/null || true)
  fi
  [ -n "$audit_log" ] || audit_log="$CHAIN_RUN_ROOT/rule-pack-gates.jsonl"
  printf '%s\n' "$audit_log"
}

record_chain_policy_gate() {
  local gate_id="$1" status="$2" severity="$3" override_env="$4" detail="$5" chain_run_id="${6:-}" issue_run_id="${7:-}" issue="${8:-}"
  local audit_log
  [ "$DRY_RUN" -eq 0 ] || return 0
  audit_log=$(chain_policy_audit_log)
  [ -n "$audit_log" ] || return 0
  mkdir -p "$(dirname "$audit_log")"
  jq -cn \
    --arg schema_version "1" \
    --arg kind "studio-chain-rule-gate-audit" \
    --arg created_at "$(iso_ts_now)" \
    --arg gate_id "$gate_id" \
    --arg status "$status" \
    --arg severity "$severity" \
    --arg override_env "$override_env" \
    --arg detail "$detail" \
    --arg manifest "$MANIFEST" \
    --arg plan "$PLAN_JSON" \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg issue "$issue" \
    --argjson dry_run "$DRY_RUN" \
    '{schema_version:($schema_version|tonumber),kind:$kind,created_at:$created_at,gate_id:$gate_id,status:$status,severity:$severity,override_env:(if $override_env == "" then null else $override_env end),detail:$detail,manifest:(if $manifest == "" then null else $manifest end),plan:$plan,chain_run_id:(if $chain_run_id == "" then null else $chain_run_id end),issue_run_id:(if $issue_run_id == "" then null else $issue_run_id end),issue_number:(if $issue == "" then null else ($issue|tonumber) end),dry_run:$dry_run}' \
    >>"$audit_log"
}

release_leaf_gate_failed_or_overridden() {
  local gate_id="$1" override_env="$2" detail="$3" chain_run_id="$4" issue_run_id="$5" issue="$6"
  if [ "${!override_env:-}" = "1" ]; then
    record_chain_policy_gate "$gate_id" override hard "$override_env" "$detail" "$chain_run_id" "$issue_run_id" "$issue"
    return 0
  fi
  record_chain_policy_gate "$gate_id" failed hard "$override_env" "$detail" "$chain_run_id" "$issue_run_id" "$issue"
  return 1
}

validate_release_chain_leaf_policy() {
  local chain_name="$1" issue="$2" issue_worktree="$3" issue_branch="$4" commit_before="$5" approved_release_id="$6" sync_strategy="$7" chain_run_id="$8" issue_run_id="$9"
  local context
  [ -n "$approved_release_id" ] && [ "$approved_release_id" != "null" ] || return 0
  context="release-bearing leaf $issue_branch for chain $chain_name issue #$issue"

  case "$sync_strategy" in
    rebase|squash)
      record_chain_policy_gate release_chain_sync_strategy passed hard STUDIO_BYPASS_CHAIN_SYNC_STRATEGY_GATE "$context uses manifest sync_strategy=$sync_strategy" "$chain_run_id" "$issue_run_id" "$issue"
      ;;
    *)
      release_leaf_gate_failed_or_overridden release_chain_sync_strategy STUDIO_BYPASS_CHAIN_SYNC_STRATEGY_GATE "$context has unsupported sync_strategy=$sync_strategy" "$chain_run_id" "$issue_run_id" "$issue" || return 1
      ;;
  esac

  if chain_git_release_leaf_ancestry_ok "$issue_worktree" "$commit_before" "$context"; then
    record_chain_policy_gate release_chain_leaf_ancestry passed hard STUDIO_BYPASS_CHAIN_LEAF_ANCESTRY_GATE "$CHAIN_GIT_RELEASE_LEAF_DETAIL" "$chain_run_id" "$issue_run_id" "$issue"
  else
    release_leaf_gate_failed_or_overridden release_chain_leaf_ancestry STUDIO_BYPASS_CHAIN_LEAF_ANCESTRY_GATE "$CHAIN_GIT_RELEASE_LEAF_DETAIL" "$chain_run_id" "$issue_run_id" "$issue" || return 1
  fi

  if chain_git_release_leaf_merge_commits_ok "$issue_worktree" "$commit_before" "$context"; then
    record_chain_policy_gate release_chain_leaf_merge_commits passed hard STUDIO_BYPASS_CHAIN_LEAF_MERGE_COMMIT_GATE "$CHAIN_GIT_RELEASE_LEAF_DETAIL" "$chain_run_id" "$issue_run_id" "$issue"
  else
    release_leaf_gate_failed_or_overridden release_chain_leaf_merge_commits STUDIO_BYPASS_CHAIN_LEAF_MERGE_COMMIT_GATE "$CHAIN_GIT_RELEASE_LEAF_DETAIL" "$chain_run_id" "$issue_run_id" "$issue" || return 1
  fi
}

verify_expected_source_sha_or_abort() {
  local chain_name="$1" source_branch="$2" expected_sha="$3" phase="$4"
  local actual_sha
  [ -n "$expected_sha" ] && [ "$expected_sha" != "null" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN verify origin/%q matches expected source SHA %q before %s\n' "$source_branch" "$expected_sha" "$phase"
    return 0
  fi
  actual_sha=$(with_login_home_for_github git ls-remote --heads origin "$source_branch" 2>/dev/null | awk 'NR == 1 { print $1 }') || actual_sha=""
  if [ -z "$actual_sha" ]; then
    abort_run_with_reason network_partition "cannot verify origin/$source_branch before $phase for chain $chain_name"
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    abort_run_with_reason base_branch_advanced "source branch $source_branch for chain $chain_name changed before $phase: expected $expected_sha, got $actual_sha"
  fi
}

live_preflight() {
  local plan="$1" reviewer_host chain_name branch issue_branch base expected_source_sha
  run_retryable_or_abort github_auth_unavailable "GitHub auth is not available" \
    with_login_home_for_github gh auth status
  emit_chain_event chain_auth_normalized "" "$RUN_ID" "" "" completed 0 \
    "$(jq -cn --arg home_source "login-home" --arg github_auth "available" --arg secrets "omitted" '{home_source:$home_source, github_auth:$github_auth, secrets:$secrets}')"
  reviewer_host="${STUDIO_REVIEW_HOST:-claude-reviewer}"
  resolve_capabilities_manifest "$reviewer_host" "$REPO_ROOT" >/dev/null || {
    printf 'studio-chain-runner: reviewer host unavailable: %s\n' "$reviewer_host" >&2
    exit 2
  }
  while IFS=$'\t' read -r chain_name branch base expected_source_sha; do
    [ "$expected_source_sha" = "__none__" ] && expected_source_sha=""
    run_retryable_or_abort network_partition "cannot verify origin/$base" \
      with_login_home_for_github git ls-remote --exit-code --heads origin "$base"
    verify_expected_source_sha_or_abort "$chain_name" "$base" "$expected_source_sha" "chain worktree creation"
    if [ -z "$RESUME_ID" ] && git -C "$TARGET_REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      printf 'studio-chain-runner: local chain branch already exists: %s\n' "$branch" >&2
      exit 2
    fi
    if [ -z "$RESUME_ID" ] && with_login_home_for_github git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      printf 'studio-chain-runner: remote chain branch already exists: %s\n' "$branch" >&2
      exit 2
    fi
  done <<EOF
$(jq -r '.chains[] | [.name, .branch, (.source_branch // .base), (.expected_source_sha // .source_sha // "__none__")] | @tsv' "$plan")
EOF
  while IFS= read -r issue_branch; do
    [ -n "$issue_branch" ] || continue
    if [ -z "$RESUME_ID" ] && git -C "$TARGET_REPO_ROOT" show-ref --verify --quiet "refs/heads/$issue_branch"; then
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
  local plan="$1" effective_parallel risk execution_mode retry_limit retry_backoff gates
  effective_parallel=1
  risk="sequential execution: this runner serializes chain PR/review/issue-closure mutation; preflight still blocks duplicate issues, branch collisions, and declared dependency conflicts before execution"
  execution_mode=$(jq -r '.execution_mode // "attended"' "$plan")
  retry_limit=$(jq -r '.retry_policy.auto_retry_limit // 2' "$plan")
  retry_backoff=$(jq -r '.retry_policy.backoff_seconds // 2' "$plan")
  gates=$(jq -r '(.review_gates // []) | join("; ")' "$plan")
  printf '# Studio Chain Plan\n\n'
  printf -- '- Run UUID: `%s`\n' "$RUN_ID"
  printf -- '- Manifest: `%s`\n' "$MANIFEST"
  printf -- '- Target repo root: `%s`\n' "$TARGET_REPO_ROOT"
  printf -- '- Issue repo: `%s`\n' "$(jq -r '.issue_repo // "unknown"' "$plan")"
  printf -- '- State: `%s`\n' "$RUN_STATE_JSON"
  printf -- '- Parallel chains: `%s` effective `%s`\n' "$PARALLEL_CHAINS" "$effective_parallel"
  printf -- '- Execution mode: `%s`\n' "$execution_mode"
  printf -- '- Retry policy: auto retry retryable operations up to `%s` time(s), backoff `%ss`, then write a typed halt record without asking a routine continuation question\n' "$retry_limit" "$retry_backoff"
  printf -- '- Escalation policy: attended prompts are reserved for review-needed, human-needed, or fatal blockers; unattended mode runs until a typed blocker appears\n'
  [ -z "$gates" ] || printf -- '- Review gates: %s\n' "$gates"
  printf -- '- Mechanical rule gates: `%s`; audit `%s`\n' "$(jq -r '.mechanical_rule_gates.status // "not-run"' "$plan")" "$(jq -r '.mechanical_rule_gates.audit_log // "none"' "$plan")"
  printf -- '- Host/model policy: manifest host, overridden by `--host`; `auto` resolves to `%s`\n' "${HOST_OVERRIDE:-codex}"
  printf -- '- Issue lifecycle: `issue-created -> implementation-running -> implemented-local -> smoke-passed -> merged -> closed`; scheduler status remains separate for resume compatibility\n'
  printf -- '- Risk notes: %s\n\n' "$risk"
  jq -r '
    .chains[] |
    "## Chain \(.name)\n\n" +
    "- Chain-run UUID: `\(.chain_run_id)`\n" +
    "- Base: `\(.base)`\n" +
    "- Source branch: `\(.source_branch // .base)`\n" +
    "- Expected source SHA: `\(.expected_source_sha // .source_sha // "not pinned")`\n" +
    "- Branch: `\(.branch)`\n" +
    "- Approved release: `\(.approved_release_id // "none")`\n" +
    "- Leaf sync strategy: `\(.sync_strategy // "rebase")`\n" +
    "- Worktree: `\(.chain_worktree)`\n" +
    "- Host: `\(.host)`\n" +
    "- Git metadata strategy: `\(.git_metadata_strategy // "linked-worktree")`\n" +
    "- Parent finalize: `git-metadata-only worker blocks can be committed by the parent runner after summary/check validation`\n" +
    "- Phase review: `\(.phase_review // "auto")`\n" +
    "- Checkpoint automation: `\(.checkpoint // "off")`\n" +
    "- Worker pool: `\(.worker_pool)`\n" +
    "- Issue scheduler: `dependency-ready nodes up to worker_pool; scalar issue lists preserve manifest order`\n" +
    "- Rule-pack status: `\(.rule_pack_resolution.status // "not-resolved")`; selected `\((.rule_pack_resolution.selected_packs // []) | length)`, skipped `\((.rule_pack_resolution.skipped_packs // []) | length)`, estimated summary tokens `\(.rule_pack_resolution.estimated_context_cost.summary_tokens_estimated // "unknown")`, skipped full-doc tokens `\(.rule_pack_resolution.context_budget.skipped_full_doc_tokens_estimated // "unknown")`, cold-context delta `\(.rule_pack_resolution.context_budget.cold_context_delta_tokens_estimated // "unknown")`\n" +
    "- Planned PR: base `\(.source_branch // .base)`, head `\(.branch)`, title `studio chain: \(.name)`\n\n" +
    "| Issue | Depends On | Issue State | Runner Status | Lifecycle | Rule Packs | Issue-run UUID | Branch | Worktree |\n|---:|---|---|---|---|---:|---|---|---|\n" +
    ([.issues[] | "| #\(.number) \(.title) | \(if ((.dependencies // []) | length) == 0 then "-" else ((.dependencies // []) | map("#" + tostring) | join(", ")) end) | \(.state) | \(.status) | \(.lifecycle_state // "unknown") | \((.rule_pack_resolution.selected_packs // []) | length) | `\(.issue_run_id)` | `\(.issue_branch)` | `\(.issue_worktree)` |"] | join("\n")) +
    "\n\n### Rule Packs\n\n" +
    "| Scope | Pack | Decision | Reason | Summary |\n|---|---|---|---|---|\n" +
    ([
      (.rule_pack_resolution.selected_packs // [])[]
      | "| chain | \(.id) | selected (\(.requirement // "auto")) | \(.reason) | `\(.summary_path // "")` |"
    ] + [
      (.rule_pack_resolution.skipped_packs // [])[]
      | "| chain | \(.id) | skipped | \(.reason) | `\(.summary_path // "")` |"
    ] + [
      (.rule_pack_resolution.warnings // [])[]
      | "| chain | \(.pack_id) | warning | \(.reason) | - |"
    ] + [
      (.rule_pack_resolution.blockers // [])[]
      | "| chain | \(.pack_id // .summary_path // "unknown") | blocker | \(.reason_id // .type) | - |"
    ] + [
      .issues[] as $issue
      | ($issue.rule_pack_resolution.selected_packs // [])[]
      | "| #\($issue.number) | \(.id) | selected (\(.requirement // "auto")) | \(.reason) | `\(.summary_path // "")` |"
    ] + [
      .issues[] as $issue
      | ($issue.rule_pack_resolution.skipped_packs // [])[]
      | "| #\($issue.number) | \(.id) | skipped | \(.reason) | `\(.summary_path // "")` |"
    ] + [
      .issues[] as $issue
      | ($issue.rule_pack_resolution.warnings // [])[]
      | "| #\($issue.number) | \(.pack_id) | warning | \(.reason) | - |"
    ] + [
      .issues[] as $issue
      | ($issue.rule_pack_resolution.blockers // [])[]
      | "| #\($issue.number) | \(.pack_id // .summary_path // "unknown") | blocker | \(.reason_id // .type) | - |"
    ] | join("\n")) +
    "\n"
  ' "$plan"
}

prepare_plan() {
  if [ -n "$RESUME_ID" ]; then
    resolve_resume_state
    TARGET_REPO_ROOT=$(jq -r '.target_repo_root // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
    if [ -z "$TARGET_REPO_ROOT" ]; then
      TARGET_REPO_ROOT=$(resolve_target_repo_root "$MANIFEST")
    fi
    if ! git -C "$TARGET_REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
      printf 'studio-chain-runner: target repo root is not a git checkout: %s\n' "$TARGET_REPO_ROOT" >&2
      exit 2
    fi
    REPO_SLUG=$(jq -r '.issue_repo // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
    [ -n "$REPO_SLUG" ] || REPO_SLUG=$(resolve_issue_repo_slug "$MANIFEST" "$TARGET_REPO_ROOT")
    cp "$RUN_STATE_JSON" "$PLAN_JSON"
    jq --arg target_repo_root "$TARGET_REPO_ROOT" --arg issue_repo "$REPO_SLUG" '.target_repo_root = $target_repo_root | .issue_repo = $issue_repo' "$PLAN_JSON" > "$PLAN_JSON.tmp.$$"
    mv "$PLAN_JSON.tmp.$$" "$PLAN_JSON"
  else
    if [ -z "$TARGET_REPO_ROOT" ]; then
      resolve_new_run_manifest_context
    fi
    build_plan_json "$PLAN_JSON"
  fi
  attach_rule_pack_resolutions "$PLAN_JSON"
  apply_mechanical_rule_gates "$PLAN_JSON"
  validate_execution_graph "$PLAN_JSON"
  if [ -z "$RESUME_ID" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      write_run_state planned ""
    else
      cp "$PLAN_JSON" "$RUN_STATE_JSON"
    fi
  else
    cp "$PLAN_JSON" "$RUN_STATE_JSON"
  fi
}

trap finish_unexpected_exit EXIT

if [ -n "$REGENERATE_REPORT_ID" ]; then
  RUN_FINISHED=1
  RUN_ID="$REGENERATE_REPORT_ID"
  configure_run_paths
  if [ ! -f "$RUN_STATE_JSON" ]; then
    printf 'studio-chain-runner: regenerate state not found: %s\n' "$RUN_STATE_JSON" >&2
    exit 2
  fi
  acquire_state_lock
  resolve_resume_state
  RUN_STATUS=$(jq -r '.status // "unknown"' "$RUN_STATE_JSON" 2>/dev/null || printf 'unknown')
  RUN_FAILURE_REASON=$(jq -r '.failure_reason // empty' "$RUN_STATE_JSON" 2>/dev/null || true)
  if command -v ts_to_epoch >/dev/null 2>&1; then
    RUN_STARTED_AT=$(ts_to_epoch "$RUN_STARTED_TS" 2>/dev/null || now_epoch)
  else
    RUN_STARTED_AT=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$RUN_STARTED_TS" +%s 2>/dev/null || date -u -d "$RUN_STARTED_TS" +%s 2>/dev/null || now_epoch)
  fi
  generate_run_report "$RUN_STATUS" "$RUN_FAILURE_REASON"
  log "report regenerated for $RUN_ID at $RUN_REPORT"
  exit 0
fi

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
else
  resolve_new_run_manifest_context
  configure_run_paths
  if [ "$YES" -eq 1 ]; then
    acquire_state_lock
  fi
fi

command -v gh >/dev/null 2>&1 || { printf 'studio-chain-runner: gh required\n' >&2; exit 2; }

chain_artifact_hygiene_sweep
if [ -n "$RESUME_ID" ] && [ "$DRY_RUN" -eq 0 ]; then
  reconcile_resume_state_projection_or_halt
fi
prepare_plan
explain_plan "$PLAN_JSON"

if rule_pack_resolution_blocked "$PLAN_JSON"; then
  printf 'studio-chain-runner: rule-pack resolution blocked; fix required rule_packs before execution\n' >&2
  exit 3
fi

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
  local chain_name="$1" chain_branch="$2" issue="$3" host="$4" git_metadata_strategy="$5" worktree="$6" issue_branch="$7" chain_run_id="$8" issue_run_id="$9" before="${10}" phase_review_context="${11:-[]}" rule_pack_resolution="${12:-null}"
  local issue_json issue_title issue_body spawn prompt summary_path start_path source_branch chain_artifact_root
  local -a spawn_argv
  local launch_home="" codex_auth_home=""

  issue_json=$(with_login_home_for_github gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,body,url,state)
  issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
  issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  source_branch=$(jq -r --arg id "$chain_run_id" '.chains[] | select(.chain_run_id == $id) | .source_branch // .base // "main"' "$PLAN_JSON")
  summary_path="$worktree/.studio/chain-worker-summary.json"
  start_path="$worktree/.studio/chain-task-start.json"
  chain_artifact_root=$(ios_chain_artifact_root "$chain_run_id")
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$chain_artifact_root"
    write_chain_task_start_envelope "$chain_name" "$chain_branch" "$source_branch" "$issue_branch" "$issue_json" "$host" "$git_metadata_strategy" "$worktree" "$chain_run_id" "$issue_run_id" "$summary_path" "$start_path" "$phase_review_context" "$rule_pack_resolution"
  fi

  spawn=$(host_spawn_command "$host")
  # shellcheck disable=SC2206
  spawn_argv=( $spawn )
  launch_home=$(host_launch_home)
  case "$host" in
    codex*|*codex*) codex_auth_home=$(codex_auth_home_for_worker_launch "$launch_home") ;;
  esac

  prompt=$(cat <<EOF
Implement this studio issue in a fresh chain-runner session.

You are executing one issue inside an automated chain runner.

Repo: $REPO_SLUG
Run UUID: $RUN_ID
Chain-run UUID: $chain_run_id
Issue-run UUID: $issue_run_id
Chain: $chain_name
Chain branch: $chain_branch
Source branch / PR base: $source_branch
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
- Do not merge to the source branch ($source_branch) or main.
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
- start_envelope_read: true/false
- start_envelope_path: "$start_path"
- source_repo_confirmed: "$REPO_SLUG"
- source_issue_confirmed: $issue
- self_review_performed: true/false
- self_review_findings array; use [] when no findings
- self_review_fixes array; use [] when no fixes were needed
- final_verification_evidence array with the final post-self-review commands and outcomes
- execution_telemetry optional object for iOS work: implementation/build/test/review/release executors when applicable, routing reason class, economics/cost summary, private artifact roots, public artifact classes, cleanup outcome, retained TTL class, and control-plane timing
- tokens object when available, otherwise null
- functionality_delivered optional string or array describing what users/agents can now do
- user_visible_change optional string or array describing what changes for the human user or operator
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
    [ -z "$codex_auth_home" ] || printf 'CODEX_HOME=%q ' "$codex_auth_home"
    printf '%q ' "${spawn_argv[@]}"
    printf '%q\n' "$prompt"
    return 0
  fi

  if [ -n "$launch_home" ] && [ -d "$launch_home" ]; then
    if [ -n "$codex_auth_home" ]; then
      (cd "$worktree" && env \
        HOME="$launch_home" \
        CODEX_HOME="$codex_auth_home" \
        STUDIO_RUN_ID="$RUN_ID" \
        STUDIO_CHAIN_RUN_ID="$chain_run_id" \
        STUDIO_ISSUE_RUN_ID="$issue_run_id" \
        STUDIO_CHAIN_ARTIFACT_ROOT="$chain_artifact_root" \
        "${spawn_argv[@]}" "$prompt")
    else
      (cd "$worktree" && env \
        HOME="$launch_home" \
        STUDIO_RUN_ID="$RUN_ID" \
        STUDIO_CHAIN_RUN_ID="$chain_run_id" \
        STUDIO_ISSUE_RUN_ID="$issue_run_id" \
        STUDIO_CHAIN_ARTIFACT_ROOT="$chain_artifact_root" \
        "${spawn_argv[@]}" "$prompt")
    fi
  else
    if [ -n "$codex_auth_home" ]; then
      (cd "$worktree" && env \
        CODEX_HOME="$codex_auth_home" \
        STUDIO_RUN_ID="$RUN_ID" \
        STUDIO_CHAIN_RUN_ID="$chain_run_id" \
        STUDIO_ISSUE_RUN_ID="$issue_run_id" \
        STUDIO_CHAIN_ARTIFACT_ROOT="$chain_artifact_root" \
        "${spawn_argv[@]}" "$prompt")
    else
      (cd "$worktree" && env \
        STUDIO_RUN_ID="$RUN_ID" \
        STUDIO_CHAIN_RUN_ID="$chain_run_id" \
        STUDIO_ISSUE_RUN_ID="$issue_run_id" \
        STUDIO_CHAIN_ARTIFACT_ROOT="$chain_artifact_root" \
        "${spawn_argv[@]}" "$prompt")
    fi
  fi
}

finalize_chain_pr() {
  local chain_name="$1" chain_branch="$2" chain_worktree="$3" base="$4" chain_run_id="$5" implementation_host="${6:-}" expected_source_sha="${7:-}"
  local pr_url pr_number review_started_at review_rc review_duration review_out review_verdict review_model review_effort review_host review_parent_host
  [ -n "$implementation_host" ] || implementation_host=$(resolve_current_studio_host unknown)

  if [ "$chain_branch" = "$base" ]; then
    abort_run_with_reason branch_worktree_conflict "chain branch $chain_branch must not equal PR base/source branch"
  fi
  log "rebasing $chain_branch on origin/$base"
  run_retryable_or_abort network_partition "fetch origin failed for $chain_branch" \
    with_login_home_for_github git -C "$chain_worktree" fetch origin --prune
  verify_expected_source_sha_or_abort "$chain_name" "$base" "$expected_source_sha" "PR finalization"
  run git -C "$chain_worktree" rebase "origin/$base"
  run_retryable_or_abort network_partition "push failed for $chain_branch" \
    with_login_home_for_github git -C "$chain_worktree" push -u origin "$chain_branch"

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
    "$(jq -cn --arg pr_url "$pr_url" --arg pr_number "$pr_number" --arg branch "$chain_branch" --arg base "$base" '{pr_url:$pr_url, pr_number:$pr_number, branch:$branch, base:$base, source_branch:$base}')"
  if ! with_login_home_for_github gh pr comment "$pr_number" --repo "$REPO_SLUG" --body "Chain run: \`$RUN_ID\`

Private telemetry report: local only; resolve by run ID on the machine that ran the chain.

Public-safe telemetry: run/chain UUIDs and abstract gap names only."; then
    abort_run "PR telemetry comment failed for $pr_url"
  fi
  detach_chain_worktree_for_merge_cleanup "$chain_branch" "$chain_worktree"

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

detach_chain_worktree_for_merge_cleanup() {
  local chain_branch="$1" chain_worktree="$2" current_branch
  [ "$DRY_RUN" -eq 0 ] || {
    printf 'DRY-RUN git -C %q checkout --detach HEAD\n' "$chain_worktree"
    return 0
  }
  [ -d "$chain_worktree/.git" ] || [ -f "$chain_worktree/.git" ] || return 0
  current_branch=$(git -C "$chain_worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current_branch" = "$chain_branch" ] || return 0
  log "detaching $chain_worktree from $chain_branch before PR merge cleanup"
  run git -C "$chain_worktree" checkout --detach HEAD
}

chain_worktree_registered() {
  local chain_worktree="$1"
  git -C "$TARGET_REPO_ROOT" worktree list --porcelain 2>/dev/null | awk -v target="$chain_worktree" '
    /^worktree / && substr($0, 10) == target { found=1 }
    END { exit found ? 0 : 1 }
  '
}

write_issue_phase_plan_artifact() {
  local artifact="$1" chain_name="$2" branch="$3" issue_branch="$4" issue_worktree="$5" issue="$6" issue_run_id="$7" host="$8" before="$9" context="${10}" issue_json="${11:-}"
  local source_number source_title source_url source_state source_body start_path summary_path
  start_path="$issue_worktree/.studio/chain-task-start.json"
  summary_path="$issue_worktree/.studio/chain-worker-summary.json"
  if [ -n "$issue_json" ]; then
    source_number=$(printf '%s' "$issue_json" | jq -r '.number // ""')
    source_title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
    source_url=$(printf '%s' "$issue_json" | jq -r '.url // ""')
    source_state=$(printf '%s' "$issue_json" | jq -r '.state // ""')
    source_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  else
    source_number="$issue"
    source_title=""
    source_url=""
    source_state=""
    source_body=""
  fi
  mkdir -p "$(dirname "$artifact")"
  {
    printf '# Chain Issue Phase Plan\n\n'
    printf -- '- Run UUID: `%s`\n' "$RUN_ID"
    printf -- '- Chain: `%s`\n' "$chain_name"
    printf -- '- Chain branch: `%s`\n' "$branch"
    printf -- '- Issue branch: `%s`\n' "$issue_branch"
    printf -- '- Issue worktree: `%s`\n' "$issue_worktree"
    printf -- '- Issue: `#%s`\n' "$issue"
    printf -- '- Issue-run UUID: `%s`\n' "$issue_run_id"
    printf -- '- Host: `%s`\n' "$host"
    printf -- '- Commit before: `%s`\n\n' "$before"
    printf '## Dependency State\n\n'
    if [ -f "$RUN_STATE_JSON" ]; then
      jq -r --argjson issue "$issue" '
        (.chains[].issues[] | select(.number == $issue) | .dependencies // []) as $deps
        | if ($deps | length) == 0 then
            "No issue dependencies declared."
          else
            [
              .chains[].issues[]
              | select((.number as $n | $deps | index($n)) != null)
              | "- #\(.number): status=\(.status // "unknown"), integrated=\(.integrated // false), commit=\(.commit_after // "unknown"), summary=\(.summary // "unknown")"
            ] | join("\n")
          end
      ' "$RUN_STATE_JSON"
    else
      printf 'Run state unavailable; dependency status must be verified before dispatch.\n'
    fi
    printf '\n'
    printf '## Source Issue\n\n'
    printf -- '- Source repo: `%s`\n' "$REPO_SLUG"
    printf -- '- Source URL: `%s`\n' "$source_url"
    printf -- '- Source issue: `#%s`\n' "$source_number"
    printf -- '- Source title: `%s`\n' "$source_title"
    printf -- '- Source state: `%s`\n\n' "$source_state"
    printf '### Source Issue Body\n\n'
    if [ -n "$source_body" ]; then
      printf '%s\n\n' "$source_body"
    else
      printf 'No issue body was returned by GitHub for the source issue.\n\n'
    fi
    printf '## Worker Handoff\n\n'
    printf -- '- Task start envelope: `%s`\n' "$start_path"
    printf -- '- Required summary artifact: `%s`\n' "$summary_path"
    printf -- '- The worker prompt requires reading the task start envelope before acting.\n'
    printf -- '- The worker summary must include `start_envelope_read: true`, `start_envelope_path`, `source_repo_confirmed`, `source_issue_confirmed`, `self_review_performed`, `self_review_findings`, `self_review_fixes`, and `final_verification_evidence`.\n'
    printf -- '- The source issue body embedded above is the runnable leaf contract for this issue; the task start envelope also includes the canonical source issue JSON.\n\n'
    printf '## Goal\n\n'
    printf 'Execute exactly this issue in its isolated worktree and commit the result on the issue branch.\n\n'
    printf '## Scope\n\n'
    printf -- '- In: bounded issue implementation, private worker summary, focused verification evidence.\n'
    printf -- '- Out: PR creation, merge to the source/base branch, issue closure, unrelated issue work, work from any repository other than the source repo above, public copy of private review prose.\n\n'
    printf '## Prior Clean Outcome Feedback\n\n'
    if [ "$(printf '%s' "$context" | jq 'length')" -gt 0 ]; then
      printf '%s\n' "$context" | jq -r '.[] | "- \(.kind): \(.text)"'
    else
      printf 'None.\n'
    fi
    printf '\n## Acceptance Criteria\n\n'
    printf -- '- After this plan review is clean, the runner writes the task start envelope before launching the worker.\n'
    printf -- '- Worker reads the task start envelope before acting.\n'
    printf -- '- Worker summary is valid JSON and remains uncommitted.\n'
    printf -- '- Issue branch produces a non-empty commit for successful execution.\n'
    printf -- '- Worker executes only the source issue listed in this artifact and does not resolve `#%s` against another repository.\n' "$issue"
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
      def text_item($x):
        if ($x | type) == "object" then
          "\($x.affected_area // "unknown area") - \($x.reason // "no reason supplied") (risk: \($x.risk // "unknown")\(if $x.suggested_timing then ", timing: \($x.suggested_timing)" else "" end))"
        else
          ($x | tostring)
        end;
      def rows($label; $items):
        ($items // []) as $xs |
        if ($xs | length) == 0 then ["- \($label): none"]
        else [ $xs[] | "- \($label): \(text_item(.))" ]
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
    printf '\n## Self Review Evidence\n\n'
    jq -r '
      def rows($name; $items):
        ($items // []) as $xs |
        if ($xs | length) == 0 then ["- \($name): none"]
        else [ $xs[] | "- \($name): \(if type == "object" then tojson else tostring end)" ]
        end;
      "- start_envelope_read: \(.start_envelope_read // "not supplied")",
      "- start_envelope_path: \(.start_envelope_path // "not supplied")",
      "- self_review_performed: \(.self_review_performed // "not supplied")",
      rows("self_review_findings"; .self_review_findings)[],
      rows("self_review_fixes"; .self_review_fixes)[],
      rows("final_verification_evidence"; .final_verification_evidence)[]
    ' "$summary_file"
    printf '\n## Explicit Ask\n\n'
    printf 'Did execution match the plan? Identify stale assumptions, warnings, recommendations, or accepted plan adjustments for upcoming phases. Do not include public-sensitive raw details.\n'
  } > "$artifact"
}

run_issue_job() {
  local name="$1" branch="$2" chain_worktree="$3" issue="$4" host="$5" git_metadata_strategy="$6" issue_worktree="$7" issue_branch="$8" chain_run_id="$9" issue_run_id="${10}" result_file="${11}" phase_review_mode="${12:-auto}" issue_count_for_review="${13:-1}"
  local before after worker_rc child_worker_rc summary_file issue_duration summary_payload issue_started_at child_reason_id child_blocked_reason parent_finalized effective_worker_rc failure_summary
  local phase_context boundary_id phase_plan_artifact phase_outcome_artifact phase_review_rc phase_review_reason worker_telemetry_file worker_launch_home rule_pack_resolution phase_issue_json
  local auto_retry_performed
  issue_started_at=$(now_epoch)
  parent_finalized=false
  auto_retry_performed=false

  log "issue #$issue -> $issue_branch"
  if [ "$DRY_RUN" -eq 0 ]; then
    chain_git_prepare_issue_workspace "$TARGET_REPO_ROOT" "$chain_worktree" "$branch" "$issue_worktree" "$issue_branch" "$git_metadata_strategy"
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
    phase_issue_json=$(with_login_home_for_github gh issue view "$issue" --repo "$REPO_SLUG" --json number,title,body,url,state)
    write_issue_phase_plan_artifact "$phase_plan_artifact" "$name" "$branch" "$issue_branch" "$issue_worktree" "$issue" "$issue_run_id" "$host" "$before" "$phase_context" "$phase_issue_json"
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

  rule_pack_resolution=$(jq -c --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .rule_pack_resolution // null' "$PLAN_JSON")
  set +e
  execute_issue_session "$name" "$branch" "$issue" "$host" "$git_metadata_strategy" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$before" "$phase_context" "$rule_pack_resolution"
  worker_rc=$?
  set -e
  child_worker_rc=$worker_rc

  if [ "$DRY_RUN" -eq 1 ]; then
    mark_issue_implemented_local "$issue_run_id" "$before" "dry-run-after" "" false
    mark_issue_state "$issue_run_id" completed "$before" "dry-run-after"
    jq -n \
      --arg issue "$issue" \
      --arg branch "$issue_branch" \
      --arg worktree "$issue_worktree" \
      '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree, commit_before:"dry-run-before", commit_after:"dry-run-after"}' > "$result_file"
    return 0
  fi

  after=$(git -C "$issue_worktree" rev-parse HEAD)
  worker_telemetry_file="$CHAIN_RUN_ROOT/worker-telemetry-$issue_run_id.json"
  worker_launch_home=$(host_launch_home)
  collect_codex_worker_session_telemetry "$host" "$issue_worktree" "$issue_started_at" "$worker_launch_home" > "$worker_telemetry_file" || printf '{}\n' > "$worker_telemetry_file"
  summary_file=$(ingest_worker_summary "$name" "$issue" "$host" "$issue_worktree" "$before" "$after" "$worker_rc" "$issue_started_at" "$chain_run_id" "$issue_run_id" "$worker_telemetry_file")
  effective_worker_rc=$(chain_git_parent_finalize_effective_worker_rc "$worker_rc" "$summary_file")

  if missing_summary_retry_eligible "$summary_file" "$worker_rc" "$before" "$after" "$issue_worktree"; then
    auto_retry_performed=true
    log "issue #$issue exited $worker_rc with no summary and no public diff; retrying once in a fresh issue worktree"
    mark_issue_retry_attempt "$issue_run_id" "worker_summary_missing_no_changes"
    chain_git_prepare_issue_workspace "$TARGET_REPO_ROOT" "$chain_worktree" "$branch" "$issue_worktree" "$issue_branch" "$git_metadata_strategy"
    before=$(git -C "$issue_worktree" rev-parse HEAD)
    mark_issue_state "$issue_run_id" running "$before"
    issue_started_at=$(now_epoch)
    set +e
    execute_issue_session "$name" "$branch" "$issue" "$host" "$git_metadata_strategy" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$before" "$phase_context" "$rule_pack_resolution"
    worker_rc=$?
    set -e
    child_worker_rc=$worker_rc
    after=$(git -C "$issue_worktree" rev-parse HEAD)
    worker_telemetry_file="$CHAIN_RUN_ROOT/worker-telemetry-$issue_run_id-retry-1.json"
    worker_launch_home=$(host_launch_home)
    collect_codex_worker_session_telemetry "$host" "$issue_worktree" "$issue_started_at" "$worker_launch_home" > "$worker_telemetry_file" || printf '{}\n' > "$worker_telemetry_file"
    summary_file=$(ingest_worker_summary "$name" "$issue" "$host" "$issue_worktree" "$before" "$after" "$worker_rc" "$issue_started_at" "$chain_run_id" "$issue_run_id" "$worker_telemetry_file")
    effective_worker_rc=$(chain_git_parent_finalize_effective_worker_rc "$worker_rc" "$summary_file")
  fi

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
    'def bad_outcome: ((.outcome // .status // "") | tostring | test("fail|error|flaky"; "i"));
     def bad_count($arr): [($arr // [])[]? | select(bad_outcome)] | length;
     def compact_execution:
       (.execution_telemetry // null) as $et |
       if $et == null then null
       else {
         executors: ($et.executors // {}),
         routing: {
           reason_class: ($et.routing.reason_class // null),
           cost_summary: ($et.routing.cost_summary // null),
           economics: ($et.routing.economics // null)
         },
         artifacts: {
           public_classes: ($et.artifacts.public_classes // []),
           private_root_count: (($et.artifacts.private_roots // []) | length)
         },
         cleanup: {
           outcome: ($et.cleanup.outcome // $et.cleanup.status // null),
           retention_class: ($et.cleanup.retention_class // null),
           ttl_class: ($et.cleanup.ttl_class // null)
         }
       }
       end;
     {
       summary:$summary,
       commit_after:$after,
       exit_code:$exit_code,
       child_exit_code:$child_exit_code,
       worker_duration_s:$duration_s,
       parent_finalized:$parent_finalized,
       auto_retry_performed:false,
       check_counts:{
         tests:{total:((.tests // []) | length), bad:bad_count(.tests)},
         lints:{total:((.lints // []) | length), bad:bad_count(.lints)},
         builds:{total:((.builds // []) | length), bad:bad_count(.builds)}
       },
       token_telemetry:(if (.tokens // null) == null then "missing" else "present" end),
       telemetry_gaps:(.telemetry_gaps // []),
       execution_telemetry: compact_execution
     }' "$summary_file")

  if [ "$auto_retry_performed" = "true" ]; then
    summary_payload=$(printf '%s\n' "$summary_payload" | jq -c '.auto_retry_performed = true')
  fi

  if [ "$worker_rc" -ne 0 ]; then
    child_reason_id=$(jq -r '.halt_reason_id // empty' "$summary_file")
    if [ -z "$child_reason_id" ] && [ "$(summary_validation_reason "$summary_file")" = "worker_summary_missing" ]; then
      child_reason_id="missing_child_summary"
    fi
    if [ -z "$child_reason_id" ]; then
      child_blocked_reason=$(jq -r '.blocked_reason // empty' "$summary_file")
      child_reason_id=$(halt_reason_for_text "${child_blocked_reason:-worker exited $worker_rc}")
    fi
    failure_summary=$(issue_failure_summary_text "$issue" "$worker_rc" "$summary_file" "$issue_worktree")
    write_halt_record "$child_reason_id" "$failure_summary" "$chain_run_id" "$issue_run_id" "$name" "$issue" "child-worker" >/dev/null || log "halt record write failed for issue #$issue"
    emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$issue_duration" "$summary_payload"
    mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "worker_exited_$worker_rc"
    mark_issue_exit_code "$issue_run_id" "$worker_rc"
    jq -n --arg issue "$issue" --argjson rc "$worker_rc" --arg reason "$failure_summary" \
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

  mark_issue_implemented_local "$issue_run_id" "$before" "$after" "$summary_file" "$parent_finalized"

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
  local issue_branch issue_worktree result_commit_before result_commit_after approved_release_id sync_strategy

  issue_branch=$(jq -r '.issue_branch' "$result_file")
  issue_worktree=$(jq -r '.issue_worktree' "$result_file")
  CHAIN_INTEGRATION_FAILURE_REASON=""
  result_commit_before=$(jq -r '.commit_before // ""' "$result_file")
  result_commit_after=$(jq -r '.commit_after // ""' "$result_file")
  if [ -z "$result_commit_before" ] || [ "$result_commit_before" = "null" ]; then
    result_commit_before=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .commit_before // ""' "$RUN_STATE_JSON" 2>/dev/null || true)
  fi
  approved_release_id=$(jq -r --arg id "$chain_run_id" '.chains[] | select(.chain_run_id == $id) | .approved_release_id // ""' "$PLAN_JSON" 2>/dev/null || true)
  sync_strategy=$(jq -r --arg id "$chain_run_id" '.chains[] | select(.chain_run_id == $id) | .sync_strategy // "rebase"' "$PLAN_JSON" 2>/dev/null || printf 'rebase')
  [ -n "$sync_strategy" ] && [ "$sync_strategy" != "null" ] || sync_strategy="rebase"

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(jq -r '.resumed // false' "$result_file")" = "true" ]; then
      case "$git_metadata_strategy" in
        linked-worktree)
          if ! git -C "$TARGET_REPO_ROOT" show-ref --verify --quiet "refs/heads/$issue_branch"; then
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
    if ! validate_release_chain_leaf_policy "$chain_name" "$issue" "$issue_worktree" "$issue_branch" "$result_commit_before" "$approved_release_id" "$sync_strategy" "$chain_run_id" "$issue_run_id"; then
      CHAIN_INTEGRATION_FAILURE_REASON="issue #$issue release-bearing leaf policy failed"
      return 1
    fi
    git -C "$chain_worktree" checkout "$branch" || return 1
    chain_git_integrate_issue_workspace "$TARGET_REPO_ROOT" "$chain_worktree" "$branch" "$issue_worktree" "$issue_branch" "$git_metadata_strategy" "$sync_strategy" || return 1
    emit_chain_event chain_issue_merged "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
      "$(jq -cn --arg chain "$chain_name" --arg branch "$branch" --arg issue_branch "$issue_branch" --arg commit_after "$result_commit_after" --arg sync_strategy "$sync_strategy" '{chain:$chain, branch:$branch, issue_branch:$issue_branch, sync_strategy:$sync_strategy, commit_after:(if $commit_after == "" then null else $commit_after end)}')"
  else
    printf 'DRY-RUN git -C %q checkout %q\n' "$chain_worktree" "$branch"
    printf 'DRY-RUN chain leaf sync strategy: %s\n' "$sync_strategy"
    case "$git_metadata_strategy" in
      linked-worktree)
        case "$sync_strategy" in
          rebase)
            printf 'DRY-RUN git -C %q rebase %q\n' "$issue_worktree" "$branch"
            printf 'DRY-RUN git -C %q merge --ff-only %q\n' "$chain_worktree" "$issue_branch"
            ;;
          squash)
            printf 'DRY-RUN git -C %q merge --squash %q\n' "$chain_worktree" "$issue_branch"
            printf 'DRY-RUN git -C %q commit -m %q\n' "$chain_worktree" "Squash $issue_branch into $branch"
            ;;
        esac
        printf 'DRY-RUN git -C %q worktree remove %q\n' "$TARGET_REPO_ROOT" "$issue_worktree"
        printf 'DRY-RUN git -C %q branch -D %q\n' "$TARGET_REPO_ROOT" "$issue_branch"
        ;;
      local-clone)
        case "$sync_strategy" in
          rebase)
            printf 'DRY-RUN git -C %q fetch %q %q\n' "$issue_worktree" "$chain_worktree" "$branch"
            printf 'DRY-RUN git -C %q rebase FETCH_HEAD\n' "$issue_worktree"
            printf 'DRY-RUN git -C %q fetch %q %q\n' "$chain_worktree" "$issue_worktree" "$issue_branch"
            printf 'DRY-RUN git -C %q merge --ff-only FETCH_HEAD\n' "$chain_worktree"
            ;;
          squash)
            printf 'DRY-RUN git -C %q fetch %q %q\n' "$chain_worktree" "$issue_worktree" "$issue_branch"
            printf 'DRY-RUN git -C %q merge --squash FETCH_HEAD\n' "$chain_worktree"
            printf 'DRY-RUN git -C %q commit -m %q\n' "$chain_worktree" "Squash $issue_branch into $branch"
            ;;
        esac
        printf 'DRY-RUN rm -rf %q\n' "$issue_worktree"
        ;;
    esac
  fi
}

print_issue_progress_recap() {
  local chain_name="$1" chain_run_id="$2" issue_run_id="$3" issue="$4" summary_file="${5:-}"
  [ "$DRY_RUN" -eq 0 ] || return 0

  if [ -z "$summary_file" ] || [ ! -f "$summary_file" ]; then
    summary_file=$(summary_for_issue_run "$chain_name" "$issue" "$issue_run_id" 2>/dev/null || true)
  fi

  jq -r \
    --arg chain_run_id "$chain_run_id" \
    --arg issue_run_id "$issue_run_id" \
    --arg run_id "$RUN_ID" \
    --arg summary_file "$summary_file" \
    --slurpfile summary "${summary_file:-/dev/null}" '
      def task_label($task):
        if $task == null then "None"
        else "#\($task.number) \($task.title // "(untitled)") (`\($task.status // "unknown")`)"
        end;
      def summary_text:
        ($summary[0] // {}) as $s
        | ($s.functionality_delivered // $s.summary // null) as $text
        | if $text == null then "Summary artifact: \($summary_file)"
          elif ($text | type) == "array" then ($text | map(tostring) | join("; "))
          else ($text | tostring)
          end;
      def signal_count($name):
        ($summary[0] // {}) as $s
        | (($s[$name] // []) | length);
      (.chains[] | select(.chain_run_id == $chain_run_id)) as $chain
      | ($chain.issues | to_entries) as $items
      | (($items | map(select(.value.issue_run_id == $issue_run_id)) | .[0].key) // 0) as $idx
      | ($items[$idx].value // {}) as $current
      | (if $idx > 0 then $items[$idx - 1].value else null end) as $previous
      | (($items | map(select(.key > $idx and (.value.status // "pending") != "completed")) | .[0].value) // null) as $next
      | ([ $chain.issues[] | select((.status // "") == "completed") ] | length) as $completed
      | ($chain.issues | length) as $total
      | "## Chain Progress Recap\n\n"
        + "- Previous task: \(task_label($previous))\n"
        + "- Just completed: \(task_label($current))\n"
        + "- What changed: \(summary_text)\n"
        + "- Verification signals: tests \(signal_count("tests")), lints \(signal_count("lints")), builds \(signal_count("builds"))\n"
        + "- Next task: \(task_label($next))\n"
        + "- Overall progress: \($completed)/\($total) issues completed in `\($chain.name)`.\n"
        + "- Direction: continue toward the chain goal on branch `\($chain.branch)` with phase review gates intact.\n"
        + "- Preferred command if this session stops: `/dev-studio manager work-chain --resume \($run_id) --yes`\n"
    ' "$RUN_STATE_JSON"
  printf '\n'
}

process_completed_issue_result() {
  local chain_name="$1" branch="$2" chain_worktree="$3" issue="$4" git_metadata_strategy="$5" result_file="$6" chain_run_id="$7" issue_run_id="$8" checkpoint_mode="$9"
  local result_status result_reason summary_file chain_commit

  result_status=$(jq -r '.status // "failed"' "$result_file")
  if [ "$result_status" != "completed" ]; then
    result_reason=$(jq -r '.reason // "issue failed"' "$result_file")
    SCHEDULER_FAILURE_REASON="$result_reason"
    return 1
  fi

  if ! integrate_issue_result "$chain_name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id"; then
    SCHEDULER_FAILURE_REASON="${CHAIN_INTEGRATION_FAILURE_REASON:-issue #$issue integration failed}"
    CHAIN_INTEGRATION_FAILURE_REASON=""
    return 1
  fi
  chain_commit=$(git -C "$chain_worktree" rev-parse HEAD 2>/dev/null || true)
  mark_issue_integrated "$issue_run_id" "$chain_commit"
  summary_file=$(jq -r '.summary // empty' "$result_file" 2>/dev/null || true)
  print_issue_progress_recap "$chain_name" "$chain_run_id" "$issue_run_id" "$issue" "$summary_file"
  if [ "$checkpoint_mode" = "auto" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      create_auto_checkpoint_after_issue "$checkpoint_mode" "$chain_name" "$branch" "$chain_worktree" "$chain_run_id" "$issue_run_id" "$issue" "$result_file"
    else
      printf 'DRY-RUN cd %q && scripts/studio-checkpoint.sh create --project generic-dev-studio --role manager --mode chain-auto --branch %q --checkpoint-id chain-%s-%s-%s --resume-command %q\n' \
        "$chain_worktree" "$branch" "$RUN_ID" "$chain_run_id" "$issue_run_id" "scripts/studio-chain-runner.sh --resume $RUN_ID --yes --checkpoint auto"
    fi
  fi
  return 0
}

summary_for_issue_run() {
  local chain_name="$1" issue="$2" issue_run_id="$3" expected summary
  expected="$SUMMARY_ROOT/${chain_name}-issue-${issue}-${issue_run_id}.json"
  if [ -f "$expected" ]; then
    printf '%s\n' "$expected"
    return 0
  fi
  [ -d "$SUMMARY_ROOT" ] || return 1
  while IFS= read -r summary; do
    [ -n "$summary" ] || continue
    if jq -e --arg issue_run_id "$issue_run_id" '.issue_run_id == $issue_run_id' "$summary" >/dev/null 2>&1; then
      printf '%s\n' "$summary"
      return 0
    fi
  done < <(find "$SUMMARY_ROOT" -type f -name '*.json' 2>/dev/null | sort)
  return 1
}

summary_completed_successfully() {
  local summary_file="$1" issue_run_id="$2"
  jq -e --arg issue_run_id "$issue_run_id" '
    .issue_run_id == $issue_run_id
    and (.status // "") == "completed"
    and ((.exit_code // 1) == 0)
    and ((.commit_after // "") != "")
    and ((.commit_after // "") != "null")
  ' "$summary_file" >/dev/null 2>&1
}

summary_commit_is_recoverable() {
  local issue_worktree="$1" commit_after="$2" head
  [ -n "$commit_after" ] && [ "$commit_after" != "null" ] || return 1
  git_checkout_exists "$issue_worktree" || return 1
  git -C "$issue_worktree" cat-file -e "$commit_after^{commit}" 2>/dev/null || return 1
  head=$(git -C "$issue_worktree" rev-parse HEAD 2>/dev/null || true)
  [ "$head" = "$commit_after" ]
}

summary_reconciliation_payload() {
  local summary_file="$1" commit_after="$2"
  jq -c \
    --arg summary "$summary_file" \
    --arg after "$commit_after" \
    'def bad_outcome: ((.outcome // .status // "") | tostring | test("fail|error|flaky"; "i"));
     def bad_count($arr): [($arr // [])[]? | select(bad_outcome)] | length;
     def compact_execution:
       (.execution_telemetry // null) as $et |
       if $et == null then null
       else {
         executors: ($et.executors // {}),
         routing: {
           reason_class: ($et.routing.reason_class // null),
           cost_summary: ($et.routing.cost_summary // null),
           economics: ($et.routing.economics // null)
         },
         artifacts: {
           public_classes: ($et.artifacts.public_classes // []),
           private_root_count: (($et.artifacts.private_roots // []) | length)
         },
         cleanup: {
           outcome: ($et.cleanup.outcome // $et.cleanup.status // null),
           retention_class: ($et.cleanup.retention_class // null),
           ttl_class: ($et.cleanup.ttl_class // null)
         }
       }
       end;
     {
       summary:$summary,
       commit_after:$after,
       exit_code:(.exit_code // 0),
       child_exit_code:(.exit_code // 0),
       worker_duration_s:(.duration_s // 0),
       parent_finalized:(.parent_finalized // false),
       reconciled_from_summary:true,
       check_counts:{
         tests:{total:((.tests // []) | length), bad:bad_count(.tests)},
         lints:{total:((.lints // []) | length), bad:bad_count(.lints)},
         builds:{total:((.builds // []) | length), bad:bad_count(.builds)}
       },
       token_telemetry:(if (.tokens // null) == null then "missing" else "present" end),
       telemetry_gaps:(.telemetry_gaps // []),
       execution_telemetry: compact_execution
     }' "$summary_file"
}

reconcile_resume_issue_summary() {
  local chain_name="$1" chain_run_id="$2" issue="$3" issue_run_id="$4" issue_worktree="$5" phase_review_mode="$6" issue_count_for_review="$7"
  local summary_file before after duration_s payload boundary_id phase_outcome_artifact phase_review_rc phase_review_reason

  summary_file=$(summary_for_issue_run "$chain_name" "$issue" "$issue_run_id" || true)
  [ -n "$summary_file" ] || return 1
  summary_completed_successfully "$summary_file" "$issue_run_id" || return 1

  before=$(jq -r '.commit_before // ""' "$summary_file")
  after=$(jq -r '.commit_after // ""' "$summary_file")
  summary_commit_is_recoverable "$issue_worktree" "$after" || return 1

  duration_s=$(jq -r '.duration_s // 0' "$summary_file")
  case "$duration_s" in ''|*[!0-9]*) duration_s=0 ;; esac
  payload=$(summary_reconciliation_payload "$summary_file" "$after")

  if phase_review_required_for_issue "$phase_review_mode" "$issue_count_for_review"; then
    boundary_id="$chain_run_id-$issue_run_id"
    phase_outcome_artifact="$PHASE_REVIEW_ROOT/$boundary_id-outcome.md"
    write_issue_phase_outcome_artifact "$phase_outcome_artifact" "$chain_name" "$issue" "$issue_run_id" "$before" "$after" "$summary_file"
    set +e
    run_phase_review_gate outcome "$boundary_id" "$phase_outcome_artifact" "$chain_run_id" "$issue_run_id" "$chain_name" "$issue"
    phase_review_rc=$?
    set -e
    if [ "$phase_review_rc" -ne 0 ]; then
      case "$phase_review_rc" in
        70) phase_review_reason="reviewer_host_ineligible" ;;
        71) phase_review_reason="reviewer_blocked" ;;
        72) phase_review_reason="reviewer_ambiguous" ;;
        *) phase_review_reason="required_review_failed" ;;
      esac
      emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" failed "$duration_s" "$payload"
      mark_issue_state "$issue_run_id" failed "$before" "$after" "$summary_file" "phase_review_failed"
      SCHEDULER_FAILURE_REASON="$phase_review_reason"
      return 2
    fi
  fi

  log "resume reconciled completed issue #$issue from worker summary"
  emit_chain_event chain_issue_completed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed "$duration_s" "$payload"
  mark_issue_state "$issue_run_id" completed "$before" "$after" "$summary_file"
  return 0
}

reconcile_resume_issue_summaries() {
  local chain_idx="$1" chain_name="$2" chain_run_id="$3" phase_review_mode="$4" issue_count="$5"
  local i issue issue_run_id issue_status issue_worktree rc
  [ -n "$RESUME_ID" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0

  for ((i = 0; i < issue_count; i++)); do
    issue=$(jq -r ".chains[$chain_idx].issues[$i].number" "$PLAN_JSON")
    issue_worktree=$(jq -r ".chains[$chain_idx].issues[$i].issue_worktree" "$PLAN_JSON")
    issue_run_id=$(jq -r ".chains[$chain_idx].issues[$i].issue_run_id" "$PLAN_JSON")
    issue_status=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .status // "pending"' "$RUN_STATE_JSON" 2>/dev/null || printf 'pending')
    [ "$issue_status" = "running" ] || continue

    set +e
    reconcile_resume_issue_summary "$chain_name" "$chain_run_id" "$issue" "$issue_run_id" "$issue_worktree" "$phase_review_mode" "$issue_count"
    rc=$?
    set -e
    case "$rc" in
      0|1) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

issue_dependencies_satisfied() {
  local chain_idx="$1" issue_idx="$2"
  jq -e --argjson chain_idx "$chain_idx" --argjson issue_idx "$issue_idx" '
    (.chains[$chain_idx].issues[$issue_idx].dependencies // []) as $deps
    | ([.chains[$chain_idx].issues[] | select((.number as $n | $deps | index($n)) != null) | select((.status // "pending") == "completed")] | length) == ($deps | length)
  ' "$RUN_STATE_JSON" >/dev/null
}

pending_issue_count() {
  local chain_idx="$1"
  jq -r --argjson chain_idx "$chain_idx" '[.chains[$chain_idx].issues[] | select((.status // "pending") == "pending")] | length' "$RUN_STATE_JSON"
}

failed_dependency_blocker_json() {
  local chain_idx="$1"
  jq -c --argjson chain_idx "$chain_idx" '
    (.chains[$chain_idx].issues // []) as $issues
    | [ $issues[] | select((.status // "pending") == "failed") ] as $failed
    | [ $issues[] as $pending
        | select(($pending.status // "pending") == "pending")
        | ($pending.dependencies // [])[]? as $dep
        | $failed[] as $failure
        | select($failure.number == $dep)
        | {
            failed_issue: $failure.number,
            failed_issue_run_id: ($failure.issue_run_id // null),
            failed_reason: ($failure.failure_reason // "failed"),
            exit_code: ($failure.exit_code // null),
            summary: ($failure.summary // null),
            worktree: ($failure.issue_worktree // null),
            blocked_issue: $pending.number,
            blocked_issue_run_id: ($pending.issue_run_id // null)
          }
      ] as $blocked
    | if ($blocked | length) == 0 then empty
      else
        ($blocked[0].failed_issue) as $root
        | ($failed[] | select(.number == $root)) as $failure
        | {
            failed_issue: $root,
            failed_issue_run_id: ($failure.issue_run_id // null),
            failed_reason: ($failure.failure_reason // "failed"),
            exit_code: ($failure.exit_code // null),
            summary: ($failure.summary // null),
            worktree: ($failure.issue_worktree // null),
            blocked_issues: ([ $blocked[] | select(.failed_issue == $root) | .blocked_issue ] | unique)
          }
      end
  ' "$RUN_STATE_JSON" 2>/dev/null || true
}

failed_dependency_blocker_reason() {
  local blocker_json="$1"
  [ -n "$blocker_json" ] || return 1
  jq -r '
    . as $b
    | "chain blocked by failed prerequisite #\($b.failed_issue): failure_reason=\($b.failed_reason // "failed"); exit_code=\($b.exit_code // "unknown"); summary=\($b.summary // "missing"); worktree=\($b.worktree // "unknown"); blocked_by #\($b.failed_issue) -> " + (($b.blocked_issues // []) | map("#" + tostring) | join(", ")) + "; next_safe_action=inspect the failed issue summary/halt record and preserved worktree, then resume after correcting the root cause"
  ' <<<"$blocker_json"
}

issue_job_is_running() {
  local target_pid="$1" pid
  while IFS= read -r pid; do
    [ "$pid" = "$target_pid" ] && return 0
  done <<EOF
$(jobs -pr 2>/dev/null || true)
EOF
  return 1
}

collect_finished_issue_jobs() {
  local chain_name="$1" branch="$2" chain_worktree="$3" git_metadata_strategy="$4" checkpoint_mode="$5"
  local idx pid result_file issue chain_run_id issue_run_id worker_rc
  local -a next_pids next_results next_issues next_chain_run_ids next_issue_run_ids
  next_pids=()
  next_results=()
  next_issues=()
  next_chain_run_ids=()
  next_issue_run_ids=()

  for ((idx = 0; idx < ${#ISSUE_PIDS[@]}; idx++)); do
    pid="${ISSUE_PIDS[$idx]}"
    result_file="${ISSUE_RESULT_FILES[$idx]}"
    issue="${ISSUE_NUMBERS[$idx]}"
    chain_run_id="${ISSUE_CHAIN_RUN_IDS[$idx]}"
    issue_run_id="${ISSUE_RUN_IDS[$idx]}"
    if [ -f "$result_file" ]; then
      wait "$pid" 2>/dev/null || true
      if ! process_completed_issue_result "$chain_name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id" "$checkpoint_mode"; then
        return 1
      fi
    elif ! issue_job_is_running "$pid"; then
      set +e
      wait "$pid" 2>/dev/null
      worker_rc=$?
      set -e
      jq -n \
        --arg issue "$issue" \
        --argjson rc "$worker_rc" \
        --arg reason "issue #$issue worker exited before writing result" \
        '{status:"failed", issue:($issue|tonumber), exit_code:$rc, reason:$reason}' > "$result_file"
      if ! process_completed_issue_result "$chain_name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id" "$checkpoint_mode"; then
        return 1
      fi
    else
      next_pids+=("$pid")
      next_results+=("$result_file")
      next_issues+=("$issue")
      next_chain_run_ids+=("$chain_run_id")
      next_issue_run_ids+=("$issue_run_id")
    fi
  done

  if [ "${#next_pids[@]}" -gt 0 ]; then ISSUE_PIDS=("${next_pids[@]}"); else ISSUE_PIDS=(); fi
  if [ "${#next_results[@]}" -gt 0 ]; then ISSUE_RESULT_FILES=("${next_results[@]}"); else ISSUE_RESULT_FILES=(); fi
  if [ "${#next_issues[@]}" -gt 0 ]; then ISSUE_NUMBERS=("${next_issues[@]}"); else ISSUE_NUMBERS=(); fi
  if [ "${#next_chain_run_ids[@]}" -gt 0 ]; then ISSUE_CHAIN_RUN_IDS=("${next_chain_run_ids[@]}"); else ISSUE_CHAIN_RUN_IDS=(); fi
  if [ "${#next_issue_run_ids[@]}" -gt 0 ]; then ISSUE_RUN_IDS=("${next_issue_run_ids[@]}"); else ISSUE_RUN_IDS=(); fi
  return 0
}

wait_for_running_issue_jobs() {
  local chain_name="$1" branch="$2" chain_worktree="$3" git_metadata_strategy="$4" checkpoint_mode="$5"
  while [ "${#ISSUE_PIDS[@]}" -gt 0 ]; do
    sleep 1
    collect_finished_issue_jobs "$chain_name" "$branch" "$chain_worktree" "$git_metadata_strategy" "$checkpoint_mode" || return 1
  done
}

run_chain_issue_scheduler() {
  local chain_idx="$1" chain_name="$2" branch="$3" chain_worktree="$4" host="$5" git_metadata_strategy="$6" chain_run_id="$7" phase_review_mode="$8" checkpoint_mode="$9" issue_count="${10}" chain_results_dir="${11}"
  local scheduled_any pending_count running_count i issue issue_branch issue_worktree issue_run_id issue_status issue_commit_after result_file result_reason blocker_json blocker_issue blocker_issue_run_id

  ISSUE_PIDS=()
  ISSUE_RESULT_FILES=()
  ISSUE_NUMBERS=()
  ISSUE_CHAIN_RUN_IDS=()
  ISSUE_RUN_IDS=()
  SCHEDULER_FAILURE_REASON=""

  reconcile_resume_issue_summaries "$chain_idx" "$chain_name" "$chain_run_id" "$phase_review_mode" "$issue_count" || abort_run "$SCHEDULER_FAILURE_REASON"

  while :; do
    collect_finished_issue_jobs "$chain_name" "$branch" "$chain_worktree" "$git_metadata_strategy" "$checkpoint_mode" || {
      wait_for_running_issue_jobs "$chain_name" "$branch" "$chain_worktree" "$git_metadata_strategy" "$checkpoint_mode" || true
      abort_run "$SCHEDULER_FAILURE_REASON"
    }

    scheduled_any=0
    running_count=${#ISSUE_PIDS[@]}
    while [ "$running_count" -lt "$CHAIN_WORKER_POOL" ]; do
      scheduled_any=0
      for ((i = 0; i < issue_count; i++)); do
        issue=$(jq -r ".chains[$chain_idx].issues[$i].number" "$PLAN_JSON")
        issue_branch=$(jq -r ".chains[$chain_idx].issues[$i].issue_branch" "$PLAN_JSON")
        issue_worktree=$(jq -r ".chains[$chain_idx].issues[$i].issue_worktree" "$PLAN_JSON")
        issue_run_id=$(jq -r ".chains[$chain_idx].issues[$i].issue_run_id" "$PLAN_JSON")
        issue_status=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .status // "pending"' "$RUN_STATE_JSON" 2>/dev/null || printf 'pending')
        result_file="$chain_results_dir/issue-$issue-$issue_run_id.json"

        if [ "$issue_status" = "completed" ]; then
          if jq -e --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .integrated == true' "$RUN_STATE_JSON" >/dev/null 2>&1; then
            continue
          fi
          issue_commit_after=$(jq -r --arg id "$issue_run_id" '.chains[].issues[] | select(.issue_run_id == $id) | .commit_after // ""' "$RUN_STATE_JSON" 2>/dev/null || true)
          jq -n \
            --arg issue "$issue" \
            --arg branch "$issue_branch" \
            --arg worktree "$issue_worktree" \
            --arg commit_after "$issue_commit_after" \
            '{status:"completed", issue:($issue|tonumber), issue_branch:$branch, issue_worktree:$worktree, commit_after:(if $commit_after == "" then null else $commit_after end), resumed:true}' > "$result_file"
          process_completed_issue_result "$chain_name" "$branch" "$chain_worktree" "$issue" "$git_metadata_strategy" "$result_file" "$chain_run_id" "$issue_run_id" "$checkpoint_mode" || abort_run "$SCHEDULER_FAILURE_REASON"
          continue
        fi

        [ "$issue_status" = "pending" ] || continue
        issue_dependencies_satisfied "$chain_idx" "$i" || continue

        rm -f "$result_file"
        mark_issue_state "$issue_run_id" running
        run_issue_job "$chain_name" "$branch" "$chain_worktree" "$issue" "$host" "$git_metadata_strategy" "$issue_worktree" "$issue_branch" "$chain_run_id" "$issue_run_id" "$result_file" "$phase_review_mode" "$issue_count" &
        ISSUE_PIDS+=("$!")
        ISSUE_RESULT_FILES+=("$result_file")
        ISSUE_NUMBERS+=("$issue")
        ISSUE_CHAIN_RUN_IDS+=("$chain_run_id")
        ISSUE_RUN_IDS+=("$issue_run_id")
        scheduled_any=1
        running_count=${#ISSUE_PIDS[@]}
        break
      done
      [ "$scheduled_any" -eq 1 ] || break
    done

    pending_count=$(pending_issue_count "$chain_idx")
    running_count=${#ISSUE_PIDS[@]}
    if [ "$pending_count" -eq 0 ] && [ "$running_count" -eq 0 ]; then
      return 0
    fi
    if [ "$running_count" -eq 0 ]; then
      blocker_json=$(failed_dependency_blocker_json "$chain_idx")
      if [ -n "$blocker_json" ]; then
        result_reason=$(failed_dependency_blocker_reason "$blocker_json")
        blocker_issue=$(jq -r '.failed_issue // ""' <<<"$blocker_json")
        blocker_issue_run_id=$(jq -r '.failed_issue_run_id // ""' <<<"$blocker_json")
        emit_chain_event chain_issue_scheduler_blocked "$blocker_issue" "$RUN_ID" "$chain_run_id" "$blocker_issue_run_id" blocked 0 \
          "$(jq -cn --arg chain "$chain_name" --arg reason "$result_reason" --argjson blocker "$blocker_json" '{chain:$chain, reason:$reason, blocked_by:$blocker}')"
        write_halt_record "implementation_scope_blocked" "$result_reason" "$chain_run_id" "$blocker_issue_run_id" "$chain_name" "$blocker_issue" "parent-runner" >/dev/null || true
        log "$result_reason"
        abort_run "$result_reason"
      fi
      result_reason="chain graph blocked: no pending issue has all dependencies completed"
      emit_chain_event chain_issue_scheduler_blocked "" "$RUN_ID" "$chain_run_id" "" blocked 0 \
        "$(jq -cn --arg chain "$chain_name" --arg reason "$result_reason" '{chain:$chain, reason:$reason}')"
      write_halt_record "implementation_scope_blocked" "$result_reason" "$chain_run_id" "" "$chain_name" "" "parent-runner" >/dev/null || true
      log "$result_reason"
      abort_run "$result_reason"
    fi
    sleep 1
  done
}

for ((idx = 0; idx < chain_count; idx++)); do
  name=$(jq -r ".chains[$idx].name" "$PLAN_JSON")
  base=$(jq -r ".chains[$idx].source_branch // .chains[$idx].base" "$PLAN_JSON")
  branch=$(jq -r ".chains[$idx].branch" "$PLAN_JSON")
  host=$(jq -r ".chains[$idx].host" "$PLAN_JSON")
  expected_source_sha=$(jq -r ".chains[$idx].expected_source_sha // .chains[$idx].source_sha // \"\"" "$PLAN_JSON")
  approved_release_id=$(jq -r ".chains[$idx].approved_release_id // \"\"" "$PLAN_JSON")
  sync_strategy=$(jq -r ".chains[$idx].sync_strategy // \"rebase\"" "$PLAN_JSON")
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
  chain_results_dir="$RUN_WORK_ROOT/$chain_slug-results-$chain_run_id"
  CHAIN_WORKER_POOL=$(jq -r ".chains[$idx].worker_pool" "$PLAN_JSON")

  log "starting chain $name on $branch from latest $base using host=$host git_metadata_strategy=$git_metadata_strategy sync_strategy=$sync_strategy checkpoint=$checkpoint_mode worker_pool=$CHAIN_WORKER_POOL"
  mark_chain_state "$chain_run_id" running
  emit_chain_event chain_started "" "$RUN_ID" "$chain_run_id" "" running 0 \
    "$(jq -cn --arg name "$name" --arg branch "$branch" --arg base "$base" --arg host "$host" --arg git_metadata_strategy "$git_metadata_strategy" --arg sync_strategy "$sync_strategy" --arg approved_release_id "$approved_release_id" --argjson issue_count "$issue_count" --argjson worker_pool "$CHAIN_WORKER_POOL" '{chain:$name, branch:$branch, base:$base, source_branch:$base, host:$host, git_metadata_strategy:$git_metadata_strategy, sync_strategy:$sync_strategy, approved_release_id:(if $approved_release_id == "" then null else $approved_release_id end), issue_count:$issue_count, worker_pool:$worker_pool}')"
  host_preflight "$host" "$TARGET_REPO_ROOT" || abort_run "host preflight failed for $host"
  run_retryable_or_abort network_partition "fetch origin failed before chain $name" \
    with_login_home_for_github git -C "$TARGET_REPO_ROOT" fetch origin --prune
  verify_expected_source_sha_or_abort "$name" "$base" "$expected_source_sha" "chain worktree creation"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$chain_results_dir"
    if [ -n "$RESUME_ID" ] && git_checkout_exists "$chain_worktree"; then
      git -C "$chain_worktree" checkout "$branch"
    elif ! git_checkout_exists "$chain_worktree"; then
      git -C "$TARGET_REPO_ROOT" worktree add -B "$branch" "$chain_worktree" "origin/$base"
      git -C "$chain_worktree" checkout "$branch"
      git -C "$chain_worktree" reset --hard "origin/$base"
    else
      git -C "$chain_worktree" checkout "$branch"
      git -C "$chain_worktree" reset --hard "origin/$base"
    fi
  else
    mkdir -p "$chain_results_dir"
    printf 'DRY-RUN git -C %q worktree add -B %q %q origin/%q\n' "$TARGET_REPO_ROOT" "$branch" "$chain_worktree" "$base"
    if [ "$checkpoint_mode" = "auto" ]; then
      printf 'DRY-RUN scripts/studio-checkpoint.sh resume --project generic-dev-studio --role manager --branch %q --latest\n' "$branch"
    fi
  fi

  load_auto_checkpoint_for_chain "$checkpoint_mode" "$chain_run_id" "$branch" "$chain_worktree"

  run_chain_issue_scheduler "$idx" "$name" "$branch" "$chain_worktree" "$host" "$git_metadata_strategy" "$chain_run_id" "$phase_review_mode" "$checkpoint_mode" "$issue_count" "$chain_results_dir"

  finalize_chain_pr "$name" "$branch" "$chain_worktree" "$base" "$chain_run_id" "$host" "$expected_source_sha"
  chain_duration=$(duration_since "$chain_started_at")
  final_chain_head=$(git -C "$chain_worktree" rev-parse HEAD 2>/dev/null || true)
  mark_chain_state "$chain_run_id" completed "$FINAL_PR_URL"
  mark_chain_issues_completed_after_pr "$chain_run_id" "$final_chain_head"
  emit_chain_event chain_completed "" "$RUN_ID" "$chain_run_id" "" completed "$chain_duration" \
    "$(jq -cn --arg name "$name" --arg pr_url "$FINAL_PR_URL" --arg commit_after "$final_chain_head" '{chain:$name, pr_url:(if $pr_url == "" then null else $pr_url end), commit_after:(if $commit_after == "" then null else $commit_after end)}')"
  run_ios_artifact_chain_cleanup "$name" "$chain_run_id" completed

  for ((i = 0; i < issue_count; i++)); do
    issue=$(jq -r ".chains[$idx].issues[$i].number" "$PLAN_JSON")
    issue_run_id=$(jq -r ".chains[$idx].issues[$i].issue_run_id" "$PLAN_JSON")
    if [ "$DRY_RUN" -eq 0 ]; then
      issue_comment="Chain issue integrated.

Chain run: $RUN_ID"
      [ -n "$FINAL_PR_URL" ] && issue_comment="$issue_comment

PR: $FINAL_PR_URL"
      with_login_home_for_github gh issue close "$issue" --repo "$REPO_SLUG" --comment "$issue_comment" \
        || with_login_home_for_github gh issue comment "$issue" --repo "$REPO_SLUG" --body "$issue_comment"
      emit_chain_event chain_issue_closed "$issue" "$RUN_ID" "$chain_run_id" "$issue_run_id" completed 0 \
        "$(jq -cn --arg pr_url "$FINAL_PR_URL" --arg issue_number "$issue" '{pr_url:(if $pr_url == "" then null else $pr_url end), issue_number:($issue_number|tonumber)}')"
    else
      printf 'DRY-RUN gh issue close %q --repo %q --comment %q\n' "$issue" "$REPO_SLUG" "Merged through chain PR: ${FINAL_PR_URL:-<pr-url>}"
    fi
    mark_issue_closed "$chain_run_id" "$issue_run_id" "$issue" "$FINAL_PR_URL"
  done

  if [ "$DRY_RUN" -eq 0 ]; then
    run_retryable_or_abort network_partition "fetch origin failed during chain cleanup" \
      with_login_home_for_github git -C "$TARGET_REPO_ROOT" fetch origin --prune
    if chain_worktree_registered "$chain_worktree"; then
      git -C "$TARGET_REPO_ROOT" worktree remove "$chain_worktree" || true
    else
      log "chain worktree already removed: $chain_worktree"
    fi
    git -C "$TARGET_REPO_ROOT" branch -D "$branch" 2>/dev/null || true
  else
    printf 'DRY-RUN git -C %q fetch origin --prune\n' "$TARGET_REPO_ROOT"
    printf 'DRY-RUN git -C %q worktree remove %q\n' "$TARGET_REPO_ROOT" "$chain_worktree"
    printf 'DRY-RUN git -C %q branch -D %q\n' "$TARGET_REPO_ROOT" "$branch"
  fi
done

finish_run completed ""
log "all requested chains processed"
