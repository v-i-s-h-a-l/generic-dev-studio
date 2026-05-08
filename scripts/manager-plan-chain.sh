#!/usr/bin/env bash
# manager-plan-chain.sh - manager-owned plan to reviewed work-chain orchestration.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT:-}"
ISSUE_NUMBER=""
ISSUE_REPO=""
SOURCE_FILE=""
SOURCE_TEXT=""
FROM_PLAN=""
TITLE=""
CHAIN_NAME=""
SOURCE_BRANCH="main"
TARGET_REPO_ROOT=""
HOST="auto"
REVIEW_HOST="${STUDIO_REVIEW_HOST:-claude-reviewer}"
DRY_RUN=0
ALLOW_MISSING_DETAILS=0
POSITIONAL=()

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-plan-chain.sh [--issue N] [--repo owner/repo] [--chain name] [goal text]
  scripts/manager-plan-chain.sh --source-file source.md [--chain name]
  scripts/manager-plan-chain.sh --from-plan task-graph.json [--chain name]

Normalizes a shaped goal or issue brief, synthesizes a planner task graph,
runs same-host self-review plus scripts/phase-review.sh, creates durable
GitHub issues for reviewed worker contracts, writes a runnable chain manifest
under ~/.dev-studio/<project>/plan-chains, and prints the clean-session
manager work-chain command.

If the source is too rough, the command returns status needs_context and stops
before review, issue creation, or manifest creation.
EOF
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'manager-plan-chain: %s required\n' "$1" >&2
    exit 2
  }
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

slugify() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c 1-80
}

truncate_title() {
  printf '%s\n' "$1" | tr '\n' ' ' | cut -c 1-120
}

hash_text_12() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,12)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,12)}'
  else
    printf 'manager-plan-chain: shasum or sha256sum required\n' >&2
    exit 2
  fi
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

resolve_issue_repo() {
  local root="$1" remote slug
  if [ -n "$ISSUE_REPO" ]; then
    github_repo_slug_from_hint "$ISSUE_REPO" || {
      printf 'manager-plan-chain: --repo must be a GitHub owner/repo slug: %s\n' "$ISSUE_REPO" >&2
      exit 2
    }
    return 0
  fi
  remote=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
  slug=$(github_repo_slug_from_hint "$remote" 2>/dev/null || true)
  if [ -n "$slug" ]; then
    printf '%s\n' "$slug"
    return 0
  fi
  printf 'v-i-s-h-a-l/generic-dev-studio\n'
}

review_allows_manifest() {
  case "$1" in
    clean|approved|approved_with_fixes|proceed) return 0 ;;
    *) return 1 ;;
  esac
}

blocked_decisions_json() {
  jq -c '
    def task_count: ([.nodes[]? | select(.kind == "task")] | length);
    ([]
      + [(.validation.missing_dependencies[]? | "Missing dependency for \(.node_id): \(.missing_source_id)")]
      + [(.validation.parallel_write_races[]? | "Parallel write race on \(.resource): \(.node_ids | join(", "))")]
      + [(.validation.packet_conflicts[]? | "Packet conflict \(.source_id): \(.text)")]
      + [(.validation.unresolved_missing_details[]? | "Missing detail \(.source_id): \(.text)")]
      + (if task_count == 0 then ["No executable task nodes were produced."] else [] end)
    ) | unique
  ' "$TASK_GRAPH"
}

write_planner_artifact() {
  local status="$1" blocked_json="$2"
  jq -n \
    --slurpfile graph "$TASK_GRAPH" \
    --arg created_at "$(now_utc)" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg source_ref "$SOURCE_LABEL" \
    --arg source_path "$SOURCE_MD" \
    --arg requirement_packet "$REQUIREMENT_PACKET" \
    --arg task_graph "$TASK_GRAPH" \
    --arg review_input "$REVIEW_INPUT" \
    --arg status "$status" \
    --argjson blocked "$blocked_json" \
    '
    $graph[0] as $g
    | ($g.nodes // [] | map(select(.kind == "task"))) as $tasks
    | {
        schema_version: 1,
        artifact_kind: "planner-output",
        artifact_id: ("planner-output:" + ($subject_ref | gsub("[^A-Za-z0-9._:-]"; "-"))),
        created_at: $created_at,
        producer_role: "planner",
        consumer_role: "reviewer",
        subject_ref: $subject_ref,
        idempotency_key: ("manager-plan-chain:" + $subject_ref),
        payload: {
          scope: ($tasks | map(.label)),
          non_goals: ["Do not execute implementation work inside the planning session."],
          dependencies: ($g.edges // []),
          reusable_api_findings: [
            "scripts/prd-intake-normalize.sh normalizes the source into a requirement packet.",
            "scripts/prd-task-graph-synthesize.sh validates dependency and write-race shape.",
            "scripts/phase-review.sh owns sibling-host review gating.",
            "scripts/studio-chain-runner.sh executes only issue-backed chain manifests."
          ],
          risks: [
            "Generated worker issues must stay bounded to the reviewed planner decomposition.",
            "The manager must stop with needs_context when validation exposes missing inputs."
          ],
          acceptance_criteria: [
            "Planner artifact records self-review findings before phase review.",
            "Clean phase review is required before issue creation and manifest creation.",
            "Final response prints the planner artifact, review artifact, work-chain manifest, blocked decisions, and clean-session command."
          ],
          decomposition: (
            $tasks
            | map({
                contract_id: ("worker-contract:" + .id),
                task_graph_node_id: .id,
                summary: .label,
                owner_role: "worker",
                allowed_paths: (.write_resources // []),
                required_checks: [
                  "Run the narrowest relevant test/lint/build checks for the files changed by this worker contract."
                ],
                stop_conditions: [
                  "The contract requires files or behavior outside the reviewed issue body.",
                  "Required checks cannot be run or interpreted.",
                  "Implementation would need a different role owner."
                ],
                summary_artifact: ".studio/chain-worker-summary.json"
              })
          ),
          refactoring_follow_ups: [],
          self_review_performed: true,
          self_review_findings: [
            ("Task graph validation status: " + ($g.validation.status // "unknown")),
            ("Worker contract count: " + (($tasks | length) | tostring)),
            "Checked that missing details, packet conflicts, and parallel write races block issue creation."
          ],
          self_review_fixes: (
            if $status == "needs_context"
            then ["Stopped before review, issue creation, and manifest creation because the source needs more context."]
            else []
            end
          ),
          review_ask: "Verify whether the planner artifact is ready to ingest into durable GitHub issues and a runnable work-chain manifest. What is still wrong or missing?",
          escalation: {
            required: ($status == "needs_context"),
            reason: (if $status == "needs_context" then ($blocked | join("; ")) else "" end),
            manager_decision_needed: (if $status == "needs_context" then "Provide or refine the missing context, then rerun manager plan-chain." else "" end)
          }
        },
        evidence_refs: [$source_path, $requirement_packet, $task_graph, $review_input],
        privacy_classification: "private-runtime",
        status: $status
      }
  ' > "$PLANNER_ARTIFACT"
}

write_review_input() {
  {
    printf '# Manager Plan-Chain Phase Plan\n\n'
    printf '## Goal\n\n'
    printf 'Create a reviewed, issue-backed work-chain from `%s` without executing worker implementation.\n\n' "$SUBJECT_REF"
    printf '## Scope\n\n'
    printf 'In:\n'
    printf -- '- Use the planner artifact at `%s`.\n' "$PLANNER_ARTIFACT"
    printf -- '- Review the planner decomposition before any GitHub issue creation.\n'
    printf -- '- If clean, create one durable GitHub issue per worker contract and write a runnable chain manifest under `%s`.\n' "$ARTIFACT_ROOT"
    printf -- '- Print the clean-session command for `/dev-studio manager work-chain`.\n\n'
    printf 'Out:\n'
    printf -- '- Do not execute worker implementation in this planning session.\n'
    printf -- '- Do not bypass role authority boundaries; manager orchestrates, planner plans, reviewer reviews, worker executes.\n\n'
    printf '## Planner Self-Review\n\n'
    jq -r '.payload.self_review_findings[] | "- " + .' "$PLANNER_ARTIFACT"
    printf '\n## Worker Contracts\n\n'
    jq -r '
      .payload.decomposition[]
      | "- `" + .contract_id + "`: " + .summary
        + (if ((.allowed_paths // []) | length) > 0 then " (writes " + ((.allowed_paths // []) | join(", ")) + ")" else "" end)
    ' "$PLANNER_ARTIFACT"
    printf '\n## Acceptance Criteria\n\n'
    jq -r '.payload.acceptance_criteria[] | "- " + .' "$PLANNER_ARTIFACT"
    printf '\n## Explicit Ask\n\n'
    printf "Review whether this planner artifact is safe to ingest into GitHub issues and a runnable work-chain. What's still wrong or missing?\n"
  } > "$REVIEW_INPUT"
}

write_result_json() {
  local status="$1" blocked_json="$2" review_path="$3" manifest_path="$4" clean_command="$5" issue_map="$6" review_meta_path="$7"
  jq -n \
    --arg created_at "$(now_utc)" \
    --arg status "$status" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg source_ref "$SOURCE_LABEL" \
    --arg artifact_root "$ARTIFACT_ROOT" \
    --arg planner_artifact "$PLANNER_ARTIFACT" \
    --arg review_artifact "$review_path" \
    --arg work_chain "$manifest_path" \
    --arg clean_session_command "$clean_command" \
    --arg review_meta "$review_meta_path" \
    --argjson blocked "$blocked_json" \
    --slurpfile issues "$issue_map" \
    '{
      schema_version: 1,
      kind: "manager-plan-chain-result",
      created_at: $created_at,
      status: $status,
      subject_ref: $subject_ref,
      source_ref: $source_ref,
      artifact_root: $artifact_root,
      planner_artifact: $planner_artifact,
      review_artifact: (if $review_artifact == "" then null else $review_artifact end),
      work_chain: (if $work_chain == "" then null else $work_chain end),
      blocked_decisions: $blocked,
      clean_session_command: (if $clean_session_command == "" then null else $clean_session_command end),
      created_issues: ($issues[0] // []),
      review_meta: (if $review_meta == "" then null else $review_meta end)
    }' > "$RESULT_JSON"
}

print_result() {
  local status="$1" blocked_json="$2" review_path="$3" manifest_path="$4" clean_command="$5"
  printf '# Manager Plan-Chain Result\n\n'
  printf -- '- Status: `%s`\n' "$status"
  printf -- '- Planner artifact: `%s`\n' "$PLANNER_ARTIFACT"
  if [ -n "$review_path" ]; then
    printf -- '- Review artifact: `%s`\n' "$review_path"
  else
    printf -- '- Review artifact: `not run`\n'
  fi
  if [ -n "$manifest_path" ]; then
    printf -- '- Work-chain: `%s`\n' "$manifest_path"
  else
    printf -- '- Work-chain: `not created`\n'
  fi
  printf -- '- Blocked decisions:\n'
  if [ "$(printf '%s\n' "$blocked_json" | jq 'length')" -eq 0 ]; then
    printf '  - None\n'
  else
    printf '%s\n' "$blocked_json" | jq -r '.[] | "  - " + .'
  fi
  if [ -n "$clean_command" ]; then
    printf -- '- Clean-session command: `%s`\n' "$clean_command"
  else
    printf -- '- Clean-session command: `not available`\n'
  fi
}

source_from_issue() {
  local issue_json issue_url issue_state
  issue_json=$("$SCRIPT_DIR/studio-gh.sh" issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json number,title,body,url,state) || {
    printf 'manager-plan-chain: failed to read issue #%s from %s\n' "$ISSUE_NUMBER" "$ISSUE_REPO" >&2
    exit 1
  }
  TITLE=${TITLE:-$(printf '%s\n' "$issue_json" | jq -r '.title // ("Issue " + (.number | tostring))')}
  issue_url=$(printf '%s\n' "$issue_json" | jq -r '.url // ""')
  issue_state=$(printf '%s\n' "$issue_json" | jq -r '.state // "unknown"')
  {
    printf '# %s\n\n' "$TITLE"
    printf 'Source issue: #%s\n' "$ISSUE_NUMBER"
    [ -z "$issue_url" ] || printf 'Source URL: %s\n' "$issue_url"
    printf 'Issue state: %s\n\n' "$issue_state"
    printf '%s\n' "$issue_json" | jq -r '.body // ""'
  } > "$SOURCE_MD"
}

source_from_file_or_text() {
  if [ -n "$SOURCE_FILE" ]; then
    [ -r "$SOURCE_FILE" ] || {
      printf 'manager-plan-chain: cannot read source file: %s\n' "$SOURCE_FILE" >&2
      exit 2
    }
    cp "$SOURCE_FILE" "$SOURCE_MD"
    [ -n "$TITLE" ] || TITLE=$(basename "$SOURCE_FILE")
    return 0
  fi
  [ -n "$SOURCE_TEXT" ] || {
    printf 'manager-plan-chain: provide --issue, --source-file, --from-plan, or goal text\n' >&2
    usage
  }
  [ -n "$TITLE" ] || TITLE=$(truncate_title "$SOURCE_TEXT")
  printf '%s\n' "$SOURCE_TEXT" > "$SOURCE_MD"
}

task_graph_from_planner_output() {
  local plan_json="$1"
  jq -S '
    (.payload.decomposition // []) as $items
    | {
        schema_version: 1,
        kind: "task-graph",
        source: {
          title: (.subject_ref // .artifact_id // "planner-output"),
          source_label: (.artifact_id // "planner-output"),
          fingerprint_sha256: "",
          generator: {name:"manager-plan-chain", version:1}
        },
        nodes: (
          $items
          | to_entries
          | map({
              id: (.value.task_graph_node_id // ("T-W" + ((.key + 1) | tostring))),
              kind: "task",
              source_id: (.value.contract_id // ("worker-contract:" + ((.key + 1) | tostring))),
              label: (.value.summary // .value.contract_id // "Worker contract"),
              dependencies: [],
              read_resources: [],
              write_resources: (.value.allowed_paths // []),
              status: "ready"
            })
        ),
        edges: [],
        ready_node_ids: (
          $items
          | to_entries
          | map(.value.task_graph_node_id // ("T-W" + ((.key + 1) | tostring)))
        ),
        validation: {
          status: (if ($items | length) > 0 then "valid" else "invalid" end),
          missing_dependencies: [],
          parallel_write_races: [],
          packet_conflicts: [],
          unresolved_missing_details: (if ($items | length) > 0 then [] else [{source_id:"M001", text:"Planner output has no decomposition entries."}] end)
        }
      }
  ' "$plan_json" > "$TASK_GRAPH"
}

prepare_task_graph() {
  local from_plan_json plan_kind graph_rc
  if [ -n "$FROM_PLAN" ]; then
    [ -r "$FROM_PLAN" ] || {
      printf 'manager-plan-chain: cannot read planner artifact: %s\n' "$FROM_PLAN" >&2
      exit 2
    }
    cp "$FROM_PLAN" "$SOURCE_MD"
    from_plan_json="$ARTIFACT_ROOT/from-plan.json"
    yq -o=json '.' "$FROM_PLAN" > "$from_plan_json"
    plan_kind=$(jq -r '.kind // .artifact_kind // ""' "$from_plan_json")
    case "$plan_kind" in
      task-graph)
        jq -S '.' "$from_plan_json" > "$TASK_GRAPH"
        [ -n "$TITLE" ] || TITLE=$(jq -r '.source.title // "Task Graph"' "$TASK_GRAPH")
        ;;
      planner-output)
        [ -n "$TITLE" ] || TITLE=$(jq -r '.subject_ref // .artifact_id // "Planner Output"' "$from_plan_json")
        task_graph_from_planner_output "$from_plan_json"
        ;;
      *)
        printf 'manager-plan-chain: --from-plan expects kind task-graph or planner-output, got %s\n' "${plan_kind:-unknown}" >&2
        exit 2
        ;;
    esac
    printf '# From Plan\n\n- Source: `%s`\n- Kind: `%s`\n' "$FROM_PLAN" "$plan_kind" > "$REQUIREMENT_PACKET"
    return 0
  fi

  "$SCRIPT_DIR/prd-intake-normalize.sh" \
    --title "$TITLE Requirement Packet" \
    --source "$SOURCE_LABEL" \
    "$SOURCE_MD" > "$REQUIREMENT_PACKET"

  set +e
  if [ "$ALLOW_MISSING_DETAILS" -eq 1 ]; then
    "$SCRIPT_DIR/prd-task-graph-synthesize.sh" --allow-missing-details "$REQUIREMENT_PACKET" > "$TASK_GRAPH" 2> "$TASK_GRAPH_ERR"
  else
    "$SCRIPT_DIR/prd-task-graph-synthesize.sh" "$REQUIREMENT_PACKET" > "$TASK_GRAPH" 2> "$TASK_GRAPH_ERR"
  fi
  graph_rc=$?
  set -e
  if [ "$graph_rc" -ne 0 ] && [ ! -s "$TASK_GRAPH" ]; then
    cat "$TASK_GRAPH_ERR" >&2
    exit "$graph_rc"
  fi
}

create_worker_issue_body() {
  local contract_json="$1" body_file="$2" node_id label allowed_paths required_checks stop_conditions
  node_id=$(printf '%s\n' "$contract_json" | jq -r '.task_graph_node_id')
  label=$(printf '%s\n' "$contract_json" | jq -r '.summary')
  allowed_paths=$(printf '%s\n' "$contract_json" | jq -r 'if ((.allowed_paths // []) | length) == 0 then "- Not specified by planner; worker must keep changes bounded to the issue." else (.allowed_paths[] | "- `" + . + "`") end')
  required_checks=$(printf '%s\n' "$contract_json" | jq -r '.required_checks[] | "- " + .')
  stop_conditions=$(printf '%s\n' "$contract_json" | jq -r '.stop_conditions[] | "- " + .')
  {
    printf '## Worker Contract\n\n'
    printf '**Task graph node:** `%s`\n\n' "$node_id"
    printf '%s\n\n' "$label"
    printf '## Allowed Paths Or Resources\n\n%s\n\n' "$allowed_paths"
    printf '## Required Checks\n\n%s\n\n' "$required_checks"
    printf '## Stop Conditions\n\n%s\n\n' "$stop_conditions"
    printf '## Planner And Review Artifacts\n\n'
    printf -- '- Planner artifact: `%s`\n' "$PLANNER_ARTIFACT"
    printf -- '- Review artifact: `%s`\n' "$REVIEW_ARTIFACT"
    printf -- '- Source: `%s`\n\n' "$SOURCE_LABEL"
    printf '## Non-Goals\n\n'
    printf -- '- Do not execute unrelated cleanup.\n'
    printf -- '- Do not bypass the chain worker summary artifact.\n'
  } > "$body_file"
}

create_worker_issues() {
  local issue_bodies_dir idx contract_json node_id label title body_file create_out issue_number issue_url tmp
  issue_bodies_dir="$ARTIFACT_ROOT/issue-bodies"
  mkdir -p "$issue_bodies_dir"
  printf '[]\n' > "$ISSUE_MAP"
  idx=0
  while IFS= read -r contract_json; do
    [ -n "$contract_json" ] || continue
    idx=$((idx + 1))
    node_id=$(printf '%s\n' "$contract_json" | jq -r '.task_graph_node_id')
    label=$(printf '%s\n' "$contract_json" | jq -r '.summary')
    title=$(truncate_title "$CHAIN_NAME: $label")
    body_file="$issue_bodies_dir/$node_id.md"
    create_worker_issue_body "$contract_json" "$body_file"
    if [ "$DRY_RUN" -eq 1 ]; then
      issue_number=$((900000 + idx))
      issue_url="dry-run:$node_id"
    else
      create_out=$("$SCRIPT_DIR/studio-gh.sh" issue create --repo "$ISSUE_REPO" --title "$title" --body-file "$body_file") || {
        printf 'manager-plan-chain: failed to create issue for %s\n' "$node_id" >&2
        exit 1
      }
      issue_url=$(printf '%s\n' "$create_out" | tail -1)
      if printf '%s\n' "$create_out" | jq -e '.number' >/dev/null 2>&1; then
        issue_number=$(printf '%s\n' "$create_out" | jq -r '.number')
        issue_url=$(printf '%s\n' "$create_out" | jq -r '.url // ""')
      else
        issue_number=$(printf '%s\n' "$issue_url" | sed -n -E 's#.*issues/([0-9]+).*#\1#p' | tail -1)
      fi
      case "$issue_number" in
        ''|*[!0-9]*)
          printf 'manager-plan-chain: could not parse issue number from create output: %s\n' "$create_out" >&2
          exit 1
          ;;
      esac
    fi
    tmp="$ISSUE_MAP.tmp"
    jq \
      --arg node_id "$node_id" \
      --arg title "$title" \
      --arg url "$issue_url" \
      --argjson number "$issue_number" \
      '. + [{node_id:$node_id, number:$number, title:$title, url:$url}]' \
      "$ISSUE_MAP" > "$tmp"
    mv "$tmp" "$ISSUE_MAP"
  done < <(jq -c '.payload.decomposition[]' "$PLANNER_ARTIFACT")
}

write_chain_manifest() {
  local manifest_json branch
  branch="feature/$CHAIN_NAME"
  manifest_json="$ARTIFACT_ROOT/work-chain.json"
  jq -n \
    --slurpfile graph "$TASK_GRAPH" \
    --slurpfile issues "$ISSUE_MAP" \
    --arg target_repo_root "$TARGET_REPO_ROOT" \
    --arg issue_repo "$ISSUE_REPO" \
    --arg chain_name "$CHAIN_NAME" \
    --arg source_branch "$SOURCE_BRANCH" \
    --arg branch "$branch" \
    --arg host "$HOST" \
    --arg planner_artifact "$PLANNER_ARTIFACT" \
    --arg review_artifact "$REVIEW_ARTIFACT" \
    --arg generated_at "$(now_utc)" \
    '
      def issue_number_for($id):
        ($issues[0][]? | select(.node_id == $id) | .number) // null;
      $graph[0] as $g
      | ($g.nodes // [] | map(select(.kind == "task"))) as $tasks
      | {
          schema_version: 1,
          target_repo_root: $target_repo_root,
          issue_repo: $issue_repo,
          generated_by: {
            script: "scripts/manager-plan-chain.sh",
            generated_at: $generated_at,
            planner_artifact: $planner_artifact,
            review_artifact: $review_artifact
          },
          chains: [
            {
              name: $chain_name,
              source_branch: $source_branch,
              branch: $branch,
              host: $host,
              phase_review: "required",
              issues: (
                $tasks
                | map(. as $node | {
                    number: issue_number_for($node.id),
                    dependencies: ([
                      $g.edges[]?
                      | select(.to == $node.id)
                      | issue_number_for(.from)
                    ] | map(select(. != null)))
                  })
              )
            }
          ]
        }
    ' > "$manifest_json"
  yq -P '.' "$manifest_json" > "$WORK_CHAIN"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_NUMBER="${2:?--issue requires a number}"; shift 2 ;;
    --issue=*) ISSUE_NUMBER="${1#--issue=}"; shift ;;
    --repo|--issue-repo) ISSUE_REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --repo=*|--issue-repo=*) ISSUE_REPO="${1#*=}"; shift ;;
    --source-file) SOURCE_FILE="${2:?--source-file requires a path}"; shift 2 ;;
    --source-file=*) SOURCE_FILE="${1#--source-file=}"; shift ;;
    --from-plan) FROM_PLAN="${2:?--from-plan requires a path}"; shift 2 ;;
    --from-plan=*) FROM_PLAN="${1#--from-plan=}"; shift ;;
    --title) TITLE="${2:?--title requires text}"; shift 2 ;;
    --title=*) TITLE="${1#--title=}"; shift ;;
    --chain) CHAIN_NAME="${2:?--chain requires a name}"; shift 2 ;;
    --chain=*) CHAIN_NAME="${1#--chain=}"; shift ;;
    --project) PROJECT="${2:?--project requires a slug}"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --target-repo-root) TARGET_REPO_ROOT="${2:?--target-repo-root requires a path}"; shift 2 ;;
    --target-repo-root=*) TARGET_REPO_ROOT="${1#--target-repo-root=}"; shift ;;
    --source-branch|--base) SOURCE_BRANCH="${2:?--source-branch requires a branch}"; shift 2 ;;
    --source-branch=*|--base=*) SOURCE_BRANCH="${1#*=}"; shift ;;
    --host) HOST="${2:?--host requires a host}"; shift 2 ;;
    --host=*) HOST="${1#--host=}"; shift ;;
    --review-host) REVIEW_HOST="${2:?--review-host requires a profile}"; shift 2 ;;
    --review-host=*) REVIEW_HOST="${1#--review-host=}"; shift ;;
    --allow-missing-details) ALLOW_MISSING_DETAILS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'manager-plan-chain: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

require_tool jq
require_tool yq

if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  if [ -z "$SOURCE_FILE" ] && [ -z "$ISSUE_NUMBER" ] && [ -z "$FROM_PLAN" ] && [ "${#POSITIONAL[@]}" -eq 1 ] && [ -r "${POSITIONAL[0]}" ]; then
    SOURCE_FILE="${POSITIONAL[0]}"
  elif [ -z "$SOURCE_FILE" ] && [ -z "$ISSUE_NUMBER" ] && [ -z "$FROM_PLAN" ] && [ "${#POSITIONAL[@]}" -eq 1 ] && [[ "${POSITIONAL[0]}" =~ ^#?[0-9]+$ ]]; then
    ISSUE_NUMBER="${POSITIONAL[0]#\#}"
  else
    SOURCE_TEXT="${POSITIONAL[*]}"
  fi
fi

TARGET_REPO_ROOT=${TARGET_REPO_ROOT:-$(git -C "${PWD:-$REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$REPO_ROOT")}
TARGET_REPO_ROOT=$(cd "$TARGET_REPO_ROOT" && pwd -P)
[ -n "$PROJECT" ] || PROJECT=$(basename "$TARGET_REPO_ROOT")
[ -n "$PROJECT" ] || PROJECT="generic-dev-studio"
ISSUE_REPO=$(resolve_issue_repo "$TARGET_REPO_ROOT")

if [ -n "$ISSUE_NUMBER" ]; then
  SUBJECT_REF="issue:$ISSUE_NUMBER"
  SOURCE_LABEL="$ISSUE_REPO#$ISSUE_NUMBER"
elif [ -n "$FROM_PLAN" ]; then
  SUBJECT_REF="plan:$(basename "$FROM_PLAN")"
  SOURCE_LABEL="$FROM_PLAN"
elif [ -n "$SOURCE_FILE" ]; then
  SUBJECT_REF="source:$(basename "$SOURCE_FILE")"
  SOURCE_LABEL="$SOURCE_FILE"
else
  SUBJECT_REF="goal:$(hash_text_12 "$SOURCE_TEXT")"
  SOURCE_LABEL="inline-goal"
fi

if [ -z "$TITLE" ]; then
  case "$SUBJECT_REF" in
    issue:*) TITLE="Issue ${ISSUE_NUMBER}" ;;
    plan:*) TITLE=$(basename "$FROM_PLAN") ;;
    source:*) TITLE=$(basename "$SOURCE_FILE") ;;
    *) TITLE=$(truncate_title "$SOURCE_TEXT") ;;
  esac
fi

title_slug=$(slugify "$TITLE")
[ -n "$title_slug" ] || title_slug="plan-chain"
[ -n "$CHAIN_NAME" ] || CHAIN_NAME="$title_slug"
CHAIN_NAME=$(slugify "$CHAIN_NAME")
[ -n "$CHAIN_NAME" ] || CHAIN_NAME="plan-chain"

artifact_home=$(resolve_parent_home_for_github)
project_root=$(HOME="$artifact_home" resolve_project_root_for "$PROJECT")
run_id="${STUDIO_MANAGER_PLAN_CHAIN_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$CHAIN_NAME}"
ARTIFACT_ROOT="$project_root/plan-chains/$run_id"
mkdir -p "$ARTIFACT_ROOT"

SOURCE_MD="$ARTIFACT_ROOT/source.md"
REQUIREMENT_PACKET="$ARTIFACT_ROOT/requirement-packet.md"
TASK_GRAPH="$ARTIFACT_ROOT/task-graph.json"
TASK_GRAPH_ERR="$ARTIFACT_ROOT/task-graph.err"
PLANNER_ARTIFACT="$ARTIFACT_ROOT/planner-output.json"
REVIEW_INPUT="$ARTIFACT_ROOT/phase-plan.md"
REVIEW_ARTIFACT="$ARTIFACT_ROOT/plan-review.md"
REVIEW_META="$ARTIFACT_ROOT/phase-review.env"
ISSUE_MAP="$ARTIFACT_ROOT/issues.json"
WORK_CHAIN="$ARTIFACT_ROOT/work-chain.yaml"
RESULT_JSON="$ARTIFACT_ROOT/result.json"
printf '[]\n' > "$ISSUE_MAP"

if [ -n "$ISSUE_NUMBER" ]; then
  source_from_issue
elif [ -n "$FROM_PLAN" ]; then
  printf '# From Plan\n\n- Source: `%s`\n' "$FROM_PLAN" > "$SOURCE_MD"
else
  source_from_file_or_text
fi

prepare_task_graph

blocked_json=$(blocked_decisions_json)
graph_status=$(jq -r '.validation.status // "invalid"' "$TASK_GRAPH")
if [ "$graph_status" != "valid" ] || [ "$(printf '%s\n' "$blocked_json" | jq 'length')" -gt 0 ]; then
  write_review_input_placeholder="$REVIEW_INPUT"
  printf '# Manager Plan-Chain Needs Context\n\nTask graph validation blocked review and issue creation.\n' > "$write_review_input_placeholder"
  write_planner_artifact "needs_context" "$blocked_json"
  write_result_json "needs_context" "$blocked_json" "" "" "" "$ISSUE_MAP" ""
  print_result "needs_context" "$blocked_json" "" "" ""
  exit 0
fi

write_planner_artifact "ready_for_review" "$blocked_json"
write_review_input

if [ "$DRY_RUN" -eq 1 ]; then
  write_result_json "dry_run" "$blocked_json" "" "" "Run without --dry-run to review, create issues, and write the work-chain manifest." "$ISSUE_MAP" ""
  print_result "dry_run" "$blocked_json" "" "" "Run without --dry-run to review, create issues, and write the work-chain manifest."
  exit 0
fi

set +e
HOME="$artifact_home" "$SCRIPT_DIR/phase-review.sh" \
  --review-host "$REVIEW_HOST" \
  --kind plan \
  --input "$REVIEW_INPUT" \
  --output "$REVIEW_ARTIFACT" > "$REVIEW_META" 2> "$REVIEW_META.err"
review_rc=$?
set -e

if [ "$review_rc" -ne 0 ]; then
  cat "$REVIEW_META.err" >&2 || true
  blocked_json=$(jq -cn --arg reason "Plan review wrapper failed; inspect $REVIEW_META and $REVIEW_META.err." '[$reason]')
  write_result_json "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" "" "$ISSUE_MAP" "$REVIEW_META"
  print_result "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" ""
  exit 1
fi

review_verdict=$(sed -n 's/^PHASE_REVIEW_VERDICT=//p' "$REVIEW_META" | tail -1)
[ -n "$review_verdict" ] || review_verdict="ambiguous"
if ! review_allows_manifest "$review_verdict"; then
  blocked_json=$(jq -cn --arg verdict "$review_verdict" '["Plan review verdict was " + $verdict + "; rerun after addressing the review artifact."]')
  write_result_json "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" "" "$ISSUE_MAP" "$REVIEW_META"
  print_result "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" ""
  exit 1
fi

create_worker_issues
write_chain_manifest

clean_command="/dev-studio manager work-chain $WORK_CHAIN --attended --yes"
write_result_json "ready" "$blocked_json" "$REVIEW_ARTIFACT" "$WORK_CHAIN" "$clean_command" "$ISSUE_MAP" "$REVIEW_META"
print_result "ready" "$blocked_json" "$REVIEW_ARTIFACT" "$WORK_CHAIN" "$clean_command"
