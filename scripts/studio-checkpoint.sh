#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"

usage() {
  cat <<'EOF'
usage:
  scripts/studio-checkpoint.sh create [options]
  scripts/studio-checkpoint.sh update [options]
  scripts/studio-checkpoint.sh resume [--checkpoint-id <id>|--latest] [options]
  scripts/studio-checkpoint.sh usefulness --checkpoint-id <id> --outcome helpful|partial|not-helpful [--notes <text>]

common options:
  --project <slug>          override project resolution
  --role <role>             producer role (default: worker)
  --branch <branch>         override current git branch for latest pointers

create/update options:
  --goal <text>             current goal
  --completed <text>        completed work summary; repeatable
  --next <text>             next step; repeatable
  --blocker <text>          blocker summary; repeatable
  --evidence <ref>          evidence pointer; repeatable
  --resume-command <text>   command to resume this checkpoint
  --checkpoint-id <id>      explicit checkpoint id
  --from <id>               update lineage source; defaults to latest pointer
  --budget-max-bytes <n>    default-load byte budget (default: 8192)
  --budget-max-tokens <n>   default-load token budget (default: 1600)
  --warning-ratio <n>       budget warning threshold ratio (default: 0.8)

resume options:
  --latest                  resolve latest pointer for project + role + branch
  --show-next               lazy-load next-steps.json after drift checks
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

json_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

sanitize_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//; s/__/_/g'
}

validate_checkpoint_id() {
  local checkpoint_id="${1:?validate_checkpoint_id <id>}"
  case "$checkpoint_id" in
    *[!A-Za-z0-9._-]*|"") fail "checkpoint id must contain only letters, numbers, dot, underscore, or dash" ;;
  esac
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || printf 'detached'
}

current_head() {
  git rev-parse HEAD 2>/dev/null || printf ''
}

dirty_bool() {
  if git diff --quiet --ignore-submodules -- 2>/dev/null && git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    printf 'false'
  else
    printf 'true'
  fi
}

dirty_summary() {
  git status --short 2>/dev/null | head -40 || true
}

file_bytes() {
  wc -c < "$1" | tr -d ' '
}

estimated_tokens_for_bytes() {
  local bytes="${1:-0}"
  printf '%s\n' $(( (bytes + 3) / 4 ))
}

trace_read() {
  if [ -n "${STUDIO_CHECKPOINT_TRACE_READS:-}" ]; then
    printf '%s\n' "$1" >> "$STUDIO_CHECKPOINT_TRACE_READS"
  fi
}

read_checkpoint_file() {
  local file="${1:?read_checkpoint_file <file>}"
  trace_read "$(basename "$file")"
  cat "$file"
}

append_line() {
  local file="$1" value="$2"
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" >> "$file"
}

checkpoint_dir_for() {
  local root="$1" checkpoint_id="$2"
  printf '%s\n' "$root/sessions/$checkpoint_id"
}

latest_pointer_path() {
  local latest_dir="$1" role="$2" branch="$3"
  local safe_role safe_branch
  safe_role=$(sanitize_component "$role")
  safe_branch=$(sanitize_component "$branch")
  printf '%s/%s/%s.json\n' "$latest_dir" "$safe_role" "$safe_branch"
}

write_manifest() {
  local out="$1" checkpoint_id="$2" session_id="$3" created_at="$4" project="$5" repo_hint="$6"
  local host="$7" role="$8" mode="$9" model="${10}" default_max_bytes="${11}" default_max_tokens="${12}"
  local warning_ratio="${13}" manifest_tokens="${14}" context_tokens="${15}" state_tokens="${16}" next_tokens="${17}" evidence_tokens="${18}" telemetry_tokens="${19}"
  jq -n \
    --arg checkpoint_id "$checkpoint_id" \
    --arg session_id "$session_id" \
    --arg created_at "$created_at" \
    --arg project "$project" \
    --arg repo_hint "$repo_hint" \
    --arg host "$host" \
    --arg role "$role" \
    --arg mode "$mode" \
    --arg model "$model" \
    --argjson default_max_bytes "$default_max_bytes" \
    --argjson default_max_tokens "$default_max_tokens" \
    --argjson warning_ratio "$warning_ratio" \
    --argjson manifest_tokens "$manifest_tokens" \
    --argjson context_tokens "$context_tokens" \
    --argjson state_tokens "$state_tokens" \
    --argjson next_tokens "$next_tokens" \
    --argjson evidence_tokens "$evidence_tokens" \
    --argjson telemetry_tokens "$telemetry_tokens" '
{
  schema_version: {name: "checkpoint-manifest", version: "1.0.0", min_reader: "1.0.0", deprecated_at: null},
  kind: "studio-v2-checkpoint-manifest",
  checkpoint_id: $checkpoint_id,
  session_id: $session_id,
  created_at: $created_at,
  project: {slug: $project, repo_root_hint: (if $repo_hint == "" then null else $repo_hint end)},
  producer: {host: $host, role: $role, mode: (if $mode == "" then null else $mode end), model: (if $model == "" then null else $model end)},
  runtime_layout: {
    root: "~/.dev-studio/<project>/.runtime/v2/checkpoints",
    checkpoint_dir: ("sessions/" + $checkpoint_id),
    index_path: "index.json",
    telemetry_path: "telemetry.jsonl"
  },
  budgets: {
    default_load_max_bytes: $default_max_bytes,
    default_load_max_estimated_tokens: $default_max_tokens,
    warning_ratio: $warning_ratio,
    over_budget_behavior: "emit-warning-telemetry"
  },
  default_load: {files: ["manifest.json", "context.md"], must_measure_bytes: true, must_measure_estimated_tokens: true},
  artifacts: [
    {path: "manifest.json", kind: "manifest", load_policy: "initial", required: true, max_bytes: $default_max_bytes, estimated_tokens: $manifest_tokens, schema_ref: "core/v2/schemas/checkpoint-manifest.schema.json", description: "Storage, budget, ownership, and lazy-load declaration."},
    {path: "context.md", kind: "context", load_policy: "initial", required: true, max_bytes: 4096, estimated_tokens: $context_tokens, schema_ref: null, description: "Compact resume context with lazy-load hints."},
    {path: "state.json", kind: "state", load_policy: "lazy", required: true, max_bytes: 4096, estimated_tokens: $state_tokens, schema_ref: "core/v2/schemas/checkpoint-state.schema.json", description: "Role-owned structured state."},
    {path: "next-steps.json", kind: "next-steps", load_policy: "lazy", required: true, max_bytes: 4096, estimated_tokens: $next_tokens, schema_ref: "core/v2/schemas/checkpoint-next-steps.schema.json", description: "Pending action list."},
    {path: "evidence.json", kind: "evidence", load_policy: "lazy", required: true, max_bytes: 4096, estimated_tokens: $evidence_tokens, schema_ref: "core/v2/schemas/checkpoint-evidence.schema.json", description: "Evidence pointers and short excerpts."},
    {path: "telemetry.jsonl", kind: "telemetry", load_policy: "append-only", required: true, max_bytes: 4096, estimated_tokens: $telemetry_tokens, schema_ref: "core/v2/schemas/checkpoint-telemetry-event.schema.json", description: "Append-only checkpoint telemetry events."}
  ],
  forbidden_content: {transcripts: "forbidden", large_embedded_command_output: "forbidden", max_inline_command_output_bytes: 1000},
  ownership: {shared_schema: ["storage", "index", "telemetry", "budgets", "lazy-load"], role_content: ["manager", "planner", "worker", "reviewer", "qa-engineer", "flow-tester", "perf", "release-manager"]}
}' > "$out"
}

write_context() {
  local out="$1" checkpoint_id="$2" role="$3" goal="$4" completed_file="$5" next_file="$6" blockers_file="$7" resume_command="$8"
  {
    printf '# Studio Checkpoint\n\n'
    printf -- '- Checkpoint: `%s`\n' "$checkpoint_id"
    printf -- '- Role: `%s`\n' "$role"
    printf -- '- Goal: %s\n\n' "$goal"
    printf '## Completed Work\n'
    if [ -s "$completed_file" ]; then
      sed 's/^/- /' "$completed_file"
    else
      printf -- '- No completed work recorded.\n'
    fi
    printf '\n## Next Action\n'
    if [ -s "$next_file" ]; then
      sed -n '1s/^/- /p' "$next_file"
    else
      printf -- '- Inspect lazy `next-steps.json` before continuing.\n'
    fi
    printf '\n## Blockers\n'
    if [ -s "$blockers_file" ]; then
      sed 's/^/- /' "$blockers_file"
    else
      printf -- '- None recorded.\n'
    fi
    printf '\n## Lazy Load Hints\n'
    printf -- '- Load `state.json` for role-owned runtime state and working tree facts.\n'
    printf -- '- Load `next-steps.json` for the full action list.\n'
    printf -- '- Load `evidence.json` only when evidence refs are needed.\n'
    printf '\n## Resume Command\n'
    printf '%s\n' "$resume_command"
  } > "$out"
}

write_state() {
  local out="$1" checkpoint_id="$2" now="$3" role="$4" status="$5" goal="$6" repo="$7" branch="$8" head="$9" dirty="${10}"
  local dirty_file="${11}" completed_file="${12}" blockers_file="${13}" supersedes="${14}"
  jq -n \
    --arg checkpoint_id "$checkpoint_id" \
    --arg now "$now" \
    --arg role "$role" \
    --arg status "$status" \
    --arg goal "$goal" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg head "$head" \
    --argjson dirty "$dirty" \
    --rawfile dirty_summary "$dirty_file" \
    --rawfile completed "$completed_file" \
    --rawfile blockers "$blockers_file" \
    --arg supersedes "$supersedes" '
{
  schema_version: 1,
  kind: "studio-v2-checkpoint-state",
  checkpoint_id: $checkpoint_id,
  updated_at: $now,
  session: {role: $role, status: $status, current_goal: $goal},
  working_tree: {repo: $repo, branch: (if $branch == "" then null else $branch end), commit: (if $head == "" then null else $head end), dirty: $dirty},
  role_state: {
    owner_role: $role,
    summary: ($completed | split("\n") | map(select(length > 0)) | if length == 0 then "Checkpoint created without completed work." else join(" ") end),
    dirty_summary: ($dirty_summary | split("\n") | map(select(length > 0))),
    completed_work: ($completed | split("\n") | map(select(length > 0))),
    blockers: ($blockers | split("\n") | map(select(length > 0))),
    supersedes: (if $supersedes == "" then null else $supersedes end)
  }
}' > "$out"
}

write_next_steps() {
  local out="$1" checkpoint_id="$2" role="$3" next_file="$4" blockers_file="$5"
  jq -n \
    --arg checkpoint_id "$checkpoint_id" \
    --arg role "$role" \
    --rawfile next "$next_file" \
    --rawfile blockers "$blockers_file" '
{
  schema_version: 1,
  kind: "studio-v2-checkpoint-next-steps",
  checkpoint_id: $checkpoint_id,
  items: (
    ($next | split("\n") | map(select(length > 0))) as $items |
    ($blockers | split("\n") | map(select(length > 0))) as $blockers |
    if ($items | length) == 0 then
      [{id: "inspect-checkpoint", status: "pending", summary: "Inspect checkpoint context and decide the next action.", owner_role: $role, blocking_reason: null, evidence_refs: []}]
    else
      [$items | to_entries[] | {id: ("next-" + ((.key + 1) | tostring)), status: (if ($blockers | length) > 0 then "blocked" else "pending" end), summary: .value, owner_role: $role, blocking_reason: (if ($blockers | length) > 0 then ($blockers | join("; ")) else null end), evidence_refs: []}]
    end
  )
}' > "$out"
}

write_evidence() {
  local out="$1" checkpoint_id="$2" evidence_file="$3"
  jq -n \
    --arg checkpoint_id "$checkpoint_id" \
    --rawfile refs "$evidence_file" '
{
  schema_version: 1,
  kind: "studio-v2-checkpoint-evidence",
  checkpoint_id: $checkpoint_id,
  evidence: (
    ($refs | split("\n") | map(select(length > 0))) as $items |
    [$items | to_entries[] | {id: ("evidence-" + ((.key + 1) | tostring)), type: "artifact", summary: "Checkpoint evidence reference.", ref: .value, size_bytes: 0, inline_excerpt: null}]
  )
}' > "$out"
}

telemetry_json() {
  local event="$1" now="$2" checkpoint_id="$3" host="$4" role="$5" default_bytes="$6" total_bytes="$7"
  local default_tokens="$8" total_tokens="$9" drift_status="${10}" base_ref="${11}" observed_ref="${12}" drift_notes="${13}"
  local outcome="${14}" loaded_files_json="${15}" useful_notes="${16}" compact_reason="${17}" resume_success="${18}"
  jq -cn \
    --arg event "$event" \
    --arg now "$now" \
    --arg checkpoint_id "$checkpoint_id" \
    --arg host "$host" \
    --arg role "$role" \
    --argjson default_bytes "$default_bytes" \
    --argjson total_bytes "$total_bytes" \
    --argjson default_tokens "$default_tokens" \
    --argjson total_tokens "$total_tokens" \
    --arg drift_status "$drift_status" \
    --arg base_ref "$base_ref" \
    --arg observed_ref "$observed_ref" \
    --arg drift_notes "$drift_notes" \
    --arg outcome "$outcome" \
    --argjson loaded_files "$loaded_files_json" \
    --arg useful_notes "$useful_notes" \
    --arg compact_reason "$compact_reason" \
    --arg resume_success "$resume_success" '
{
  schema_version: 1,
  event: $event,
  occurred_at: $now,
  checkpoint_id: $checkpoint_id,
  producer: {host: $host, role: $role},
  size: {default_load_bytes: $default_bytes, total_bytes: $total_bytes, estimated_default_load_tokens: $default_tokens, estimated_total_tokens: $total_tokens},
  drift: {status: $drift_status, base_ref: (if $base_ref == "" then null else $base_ref end), observed_ref: (if $observed_ref == "" then null else $observed_ref end), notes: (if $drift_notes == "" then null else $drift_notes end)},
  usefulness: {resume_outcome: $outcome, loaded_files: $loaded_files, notes: (if $useful_notes == "" then null else $useful_notes end)},
  v1_tuning: {compact_reason: (if $compact_reason == "" then null else $compact_reason end), compaction_interval_turns: null, resume_success: (if $resume_success == "" then null else ($resume_success == "true") end), prompt_cacheable_prefix_tokens: null}
}'
}

measure_total_bytes() {
  local dir="$1" total=0 file
  for file in "$dir"/manifest.json "$dir"/context.md "$dir"/state.json "$dir"/next-steps.json "$dir"/evidence.json "$dir"/telemetry.jsonl; do
    [ -f "$file" ] || continue
    total=$(( total + $(file_bytes "$file") ))
  done
  printf '%s\n' "$total"
}

write_index_entry() {
  local index="$1" project="$2" checkpoint_id="$3" created_at="$4" role="$5" default_bytes="$6" default_tokens="$7" supersedes="$8"
  local tmp
  tmp=$(mktemp -t checkpoint-index.XXXXXX)
  mkdir -p "$(dirname "$index")"
  if [ ! -f "$index" ]; then
    jq -n --arg project "$project" --arg updated_at "$created_at" '{schema_version: 1, kind: "studio-v2-checkpoint-index", project: $project, updated_at: $updated_at, checkpoints: []}' > "$index"
  fi
  jq \
    --arg updated_at "$created_at" \
    --arg checkpoint_id "$checkpoint_id" \
    --arg session_dir "sessions/$checkpoint_id" \
    --arg role "$role" \
    --argjson default_bytes "$default_bytes" \
    --argjson default_tokens "$default_tokens" \
    --arg supersedes "$supersedes" '
      .updated_at = $updated_at
      | .checkpoints = (.checkpoints | map(if .checkpoint_id == $supersedes then .status = "superseded" else . end))
      | .checkpoints += [{
          checkpoint_id: $checkpoint_id,
          session_dir: $session_dir,
          created_at: $updated_at,
          producer_role: $role,
          status: "available",
          default_load_bytes: $default_bytes,
          estimated_default_load_tokens: $default_tokens,
          latest_drift_status: "unknown",
          last_usefulness: "unknown"
        }]
    ' "$index" > "$tmp"
  mv "$tmp" "$index"
}

write_latest_pointer() {
  local pointer="$1" checkpoint_id="$2" now="$3" project="$4" role="$5" branch="$6" head="$7"
  mkdir -p "$(dirname "$pointer")"
  jq -n \
    --arg checkpoint_id "$checkpoint_id" \
    --arg now "$now" \
    --arg project "$project" \
    --arg role "$role" \
    --arg branch "$branch" \
    --arg head "$head" \
    '{schema_version: 1, kind: "studio-v2-checkpoint-latest-pointer", project: $project, role: $role, branch: $branch, checkpoint_id: $checkpoint_id, session_dir: ("sessions/" + $checkpoint_id), updated_at: $now, head: (if $head == "" then null else $head end)}' > "$pointer"
}

warn_if_budget() {
  local dir="$1" telemetry="$2" now="$3" checkpoint_id="$4" host="$5" role="$6" max_bytes="$7" max_tokens="$8" warning_ratio="$9" default_bytes="${10}" default_tokens="${11}" total_bytes="${12}" total_tokens="${13}"
  local byte_threshold token_threshold
  byte_threshold=$(jq -n --argjson max "$max_bytes" --argjson ratio "$warning_ratio" '$max * $ratio | floor')
  token_threshold=$(jq -n --argjson max "$max_tokens" --argjson ratio "$warning_ratio" '$max * $ratio | floor')
  if [ "$default_bytes" -lt "$byte_threshold" ] && [ "$default_tokens" -lt "$token_threshold" ]; then
    return 0
  fi
  printf 'checkpoint budget warning: default load %s bytes / %s estimated tokens\n' "$default_bytes" "$default_tokens" >&2
  for f in "$dir"/manifest.json "$dir"/context.md "$dir"/state.json "$dir"/next-steps.json "$dir"/evidence.json; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "$(file_bytes "$f")" "$(basename "$f")"
  done | sort -rn | head -3 | while read -r bytes name; do
    printf 'largest section: %s %s bytes\n' "$name" "$bytes" >&2
  done
  telemetry_json checkpoint_budget_warning "$now" "$checkpoint_id" "$host" "$role" "$default_bytes" "$total_bytes" "$default_tokens" "$total_tokens" unknown "" "" "default load crossed checkpoint budget warning threshold" unknown '["manifest.json","context.md"]' "Budget warning emitted; inspect largest sections." "manual-checkpoint" "" >> "$telemetry"
}

resolve_checkpoint_selection() {
  local latest_dir="$1" role="$2" branch="$3" checkpoint_id="$4" use_latest="$5"
  if [ -n "$checkpoint_id" ]; then
    validate_checkpoint_id "$checkpoint_id"
    printf '%s\n' "$checkpoint_id"
    return 0
  fi
  if [ "$use_latest" = "true" ]; then
    local pointer
    pointer=$(latest_pointer_path "$latest_dir" "$role" "$branch")
    [ -f "$pointer" ] || fail "no latest checkpoint pointer for role=$role branch=$branch"
    checkpoint_id=$(jq -r '.checkpoint_id' "$pointer")
    validate_checkpoint_id "$checkpoint_id"
    printf '%s\n' "$checkpoint_id"
    return 0
  fi
  fail "provide --checkpoint-id or --latest"
}

cmd_create_or_update() {
  local command="$1"; shift
  need_jq
  local project="" role="worker" mode="checkpoint" host="${STUDIO_HOST:-codex}" model="${STUDIO_MODEL:-}" goal=""
  local checkpoint_id="" from_id="" resume_command="" branch_override="" default_max_bytes=8192 default_max_tokens=1600 warning_ratio=0.8
  local tmpdir completed_file next_file blockers_file evidence_file
  tmpdir=$(mktemp -d -t studio-checkpoint.XXXXXX)
  completed_file="$tmpdir/completed.txt"
  next_file="$tmpdir/next.txt"
  blockers_file="$tmpdir/blockers.txt"
  evidence_file="$tmpdir/evidence.txt"
  : > "$completed_file"; : > "$next_file"; : > "$blockers_file"; : > "$evidence_file"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project="${2:?--project needs a value}"; shift 2 ;;
      --role) role="${2:?--role needs a value}"; shift 2 ;;
      --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      --model) model="${2:?--model needs a value}"; shift 2 ;;
      --goal) goal="${2:?--goal needs a value}"; shift 2 ;;
      --completed) append_line "$completed_file" "${2:?--completed needs a value}"; shift 2 ;;
      --next) append_line "$next_file" "${2:?--next needs a value}"; shift 2 ;;
      --blocker) append_line "$blockers_file" "${2:?--blocker needs a value}"; shift 2 ;;
      --evidence) append_line "$evidence_file" "${2:?--evidence needs a value}"; shift 2 ;;
      --resume-command) resume_command="${2:?--resume-command needs a value}"; shift 2 ;;
      --checkpoint-id) checkpoint_id="${2:?--checkpoint-id needs a value}"; shift 2 ;;
      --from) from_id="${2:?--from needs a value}"; shift 2 ;;
      --branch) branch_override="${2:?--branch needs a value}"; shift 2 ;;
      --budget-max-bytes) default_max_bytes="${2:?--budget-max-bytes needs a value}"; shift 2 ;;
      --budget-max-tokens) default_max_tokens="${2:?--budget-max-tokens needs a value}"; shift 2 ;;
      --warning-ratio) warning_ratio="${2:?--warning-ratio needs a value}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "unknown option: $1" ;;
    esac
  done
  [ -n "$project" ] || project=$(resolve_project)
  [ -n "$goal" ] || goal="Resume studio work from compact checkpoint."
  case "$role" in [a-z][a-z0-9-]*) ;; *) fail "role must match ^[a-z][a-z0-9-]*$" ;; esac
  local root latest_dir index now repo_root repo branch head dirty session_id dir pointer
  root=$(resolve_checkpoint_root_for "$project")
  latest_dir=$(resolve_checkpoint_latest_dir_for "$project")
  index=$(resolve_checkpoint_index_for "$project")
  now=$(json_now)
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '')
  repo=$(basename "${repo_root:-$project}")
  branch="${branch_override:-$(current_branch)}"
  head=$(current_head)
  dirty=$(dirty_bool)
  if [ "$command" = "update" ] && [ -z "$from_id" ]; then
    pointer=$(latest_pointer_path "$latest_dir" "$role" "$branch")
    [ -f "$pointer" ] && from_id=$(jq -r '.checkpoint_id' "$pointer")
  fi
  if [ -z "$checkpoint_id" ]; then
    checkpoint_id="ckpt-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  validate_checkpoint_id "$checkpoint_id"
  session_id="${STUDIO_SESSION_ID:-session-$checkpoint_id}"
  [ -n "$resume_command" ] || resume_command="scripts/studio-checkpoint.sh resume --latest --role $role --branch $branch"
  dir=$(checkpoint_dir_for "$root" "$checkpoint_id")
  mkdir -p "$dir"
  dirty_summary > "$tmpdir/dirty.txt"
  write_context "$dir/context.md" "$checkpoint_id" "$role" "$goal" "$completed_file" "$next_file" "$blockers_file" "$resume_command"
  write_state "$dir/state.json" "$checkpoint_id" "$now" "$role" "active" "$goal" "$repo" "$branch" "$head" "$dirty" "$tmpdir/dirty.txt" "$completed_file" "$blockers_file" "$from_id"
  write_next_steps "$dir/next-steps.json" "$checkpoint_id" "$role" "$next_file" "$blockers_file"
  write_evidence "$dir/evidence.json" "$checkpoint_id" "$evidence_file"
  : > "$dir/telemetry.jsonl"
  local context_bytes state_bytes next_bytes evidence_bytes telemetry_tokens manifest_tokens
  context_bytes=$(file_bytes "$dir/context.md")
  state_bytes=$(file_bytes "$dir/state.json")
  next_bytes=$(file_bytes "$dir/next-steps.json")
  evidence_bytes=$(file_bytes "$dir/evidence.json")
  telemetry_tokens=0
  manifest_tokens=600
  write_manifest "$dir/manifest.json" "$checkpoint_id" "$session_id" "$now" "$project" "$repo_root" "$host" "$role" "$mode" "$model" "$default_max_bytes" "$default_max_tokens" "$warning_ratio" "$manifest_tokens" "$(estimated_tokens_for_bytes "$context_bytes")" "$(estimated_tokens_for_bytes "$state_bytes")" "$(estimated_tokens_for_bytes "$next_bytes")" "$(estimated_tokens_for_bytes "$evidence_bytes")" "$telemetry_tokens"
  local manifest_bytes default_bytes total_bytes default_tokens total_tokens
  manifest_bytes=$(file_bytes "$dir/manifest.json")
  default_bytes=$(( manifest_bytes + context_bytes ))
  total_bytes=$(measure_total_bytes "$dir")
  default_tokens=$(estimated_tokens_for_bytes "$default_bytes")
  total_tokens=$(estimated_tokens_for_bytes "$total_bytes")
  telemetry_json checkpoint_created "$now" "$checkpoint_id" "$host" "$role" "$default_bytes" "$total_bytes" "$default_tokens" "$total_tokens" unknown "" "" "" unknown '["manifest.json","context.md"]' "" "manual-checkpoint" "" >> "$dir/telemetry.jsonl"
  warn_if_budget "$dir" "$dir/telemetry.jsonl" "$now" "$checkpoint_id" "$host" "$role" "$default_max_bytes" "$default_max_tokens" "$warning_ratio" "$default_bytes" "$default_tokens" "$total_bytes" "$total_tokens"
  write_index_entry "$index" "$project" "$checkpoint_id" "$now" "$role" "$default_bytes" "$default_tokens" "$from_id"
  pointer=$(latest_pointer_path "$latest_dir" "$role" "$branch")
  write_latest_pointer "$pointer" "$checkpoint_id" "$now" "$project" "$role" "$branch" "$head"
  printf '%s\n' "$checkpoint_id"
}

cmd_resume() {
  need_jq
  local project="" role="worker" checkpoint_id="" use_latest=false branch_override="" show_next=false host="${STUDIO_HOST:-codex}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project="${2:?--project needs a value}"; shift 2 ;;
      --role) role="${2:?--role needs a value}"; shift 2 ;;
      --checkpoint-id) checkpoint_id="${2:?--checkpoint-id needs a value}"; shift 2 ;;
      --latest) use_latest=true; shift ;;
      --branch) branch_override="${2:?--branch needs a value}"; shift 2 ;;
      --show-next) show_next=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) fail "unknown option: $1" ;;
    esac
  done
  [ -n "$project" ] || project=$(resolve_project)
  local root latest_dir branch selected dir manifest context state evidence now saved_branch saved_head saved_dirty head dirty drift notes loaded_files total_bytes default_bytes total_tokens default_tokens telemetry
  root=$(resolve_checkpoint_root_for "$project")
  latest_dir=$(resolve_checkpoint_latest_dir_for "$project")
  branch="${branch_override:-$(current_branch)}"
  selected=$(resolve_checkpoint_selection "$latest_dir" "$role" "$branch" "$checkpoint_id" "$use_latest")
  dir=$(checkpoint_dir_for "$root" "$selected")
  [ -d "$dir" ] || fail "checkpoint directory not found: $dir"
  manifest=$(read_checkpoint_file "$dir/manifest.json")
  context=$(read_checkpoint_file "$dir/context.md")
  printf '%s\n\n' "$context"
  (printf '%s\n' "$manifest" | jq -e '.default_load.files == ["manifest.json", "context.md"]' >/dev/null) || fail "manifest default load is incompatible"
  state=$(read_checkpoint_file "$dir/state.json")
  evidence=$(read_checkpoint_file "$dir/evidence.json")
  saved_branch=$(printf '%s\n' "$state" | jq -r '.working_tree.branch // ""')
  saved_head=$(printf '%s\n' "$state" | jq -r '.working_tree.commit // ""')
  saved_dirty=$(printf '%s\n' "$state" | jq -r '.working_tree.dirty')
  head=$(current_head)
  dirty=$(dirty_bool)
  drift=none
  notes=""
  if [ -n "$saved_branch" ] && [ "$saved_branch" != "$branch" ]; then
    drift=confirmed
    notes="branch changed from $saved_branch to $branch"
  elif [ -n "$saved_head" ] && [ -n "$head" ] && [ "$saved_head" != "$head" ]; then
    drift=confirmed
    notes="head changed from $saved_head to $head"
  elif [ "$saved_dirty" != "$dirty" ]; then
    drift=possible
    notes="dirty state changed from $saved_dirty to $dirty"
  fi
  if printf '%s\n' "$evidence" | jq -e '.evidence[]? | select(.ref | startswith("/") and (test("^/dev/null$") | not))' >/dev/null; then
    if ! printf '%s\n' "$evidence" | jq -r '.evidence[]?.ref | select(startswith("/"))' | while IFS= read -r ref; do [ -e "$ref" ] || exit 9; done; then
      [ "$drift" = "none" ] && drift=possible
      notes="${notes:+$notes; }one or more absolute evidence refs are missing"
    fi
  fi
  printf 'Drift: %s\n' "$drift"
  [ -z "$notes" ] || printf 'Drift notes: %s\n' "$notes"
  printf 'Suggested next step: %s\n' "$(printf '%s\n' "$context" | sed -n '/^## Next Action$/,/^## /p' | sed -n '2s/^- //p' | head -1)"
  loaded_files='["manifest.json","context.md","state.json","evidence.json"]'
  if [ "$show_next" = "true" ]; then
    read_checkpoint_file "$dir/next-steps.json" | jq '.items'
    loaded_files='["manifest.json","context.md","state.json","evidence.json","next-steps.json"]'
  fi
  now=$(json_now)
  default_bytes=$(( $(file_bytes "$dir/manifest.json") + $(file_bytes "$dir/context.md") ))
  total_bytes=$(measure_total_bytes "$dir")
  default_tokens=$(estimated_tokens_for_bytes "$default_bytes")
  total_tokens=$(estimated_tokens_for_bytes "$total_bytes")
  telemetry="$dir/telemetry.jsonl"
  telemetry_json checkpoint_resumed "$now" "$selected" "$host" "$role" "$default_bytes" "$total_bytes" "$default_tokens" "$total_tokens" "$drift" "$saved_head" "$head" "$notes" partial "$loaded_files" "Resume inspected compact default files before lazy drift checks." "" true >> "$telemetry"
}

cmd_usefulness() {
  need_jq
  local project="" role="worker" checkpoint_id="" outcome="" notes="" host="${STUDIO_HOST:-codex}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project="${2:?--project needs a value}"; shift 2 ;;
      --role) role="${2:?--role needs a value}"; shift 2 ;;
      --checkpoint-id) checkpoint_id="${2:?--checkpoint-id needs a value}"; shift 2 ;;
      --outcome) outcome="${2:?--outcome needs a value}"; shift 2 ;;
      --notes) notes="${2:?--notes needs a value}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "unknown option: $1" ;;
    esac
  done
  [ -n "$project" ] || project=$(resolve_project)
  [ -n "$checkpoint_id" ] || fail "--checkpoint-id is required"
  case "$outcome" in helpful|partial|not-helpful) ;; *) fail "--outcome must be helpful, partial, or not-helpful" ;; esac
  local root dir now default_bytes total_bytes default_tokens total_tokens
  root=$(resolve_checkpoint_root_for "$project")
  dir=$(checkpoint_dir_for "$root" "$checkpoint_id")
  [ -d "$dir" ] || fail "checkpoint directory not found: $dir"
  now=$(json_now)
  default_bytes=$(( $(file_bytes "$dir/manifest.json") + $(file_bytes "$dir/context.md") ))
  total_bytes=$(measure_total_bytes "$dir")
  default_tokens=$(estimated_tokens_for_bytes "$default_bytes")
  total_tokens=$(estimated_tokens_for_bytes "$total_bytes")
  telemetry_json checkpoint_usefulness_recorded "$now" "$checkpoint_id" "$host" "$role" "$default_bytes" "$total_bytes" "$default_tokens" "$total_tokens" unknown "" "" "" "$outcome" '["manifest.json","context.md"]' "$notes" "" "" >> "$dir/telemetry.jsonl"
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 2; }
  local command="$1"; shift
  case "$command" in
    create|update) cmd_create_or_update "$command" "$@" ;;
    resume) cmd_resume "$@" ;;
    usefulness) cmd_usefulness "$@" ;;
    --help|-h) usage ;;
    *) fail "unknown command: $command" ;;
  esac
}

main "$@"
