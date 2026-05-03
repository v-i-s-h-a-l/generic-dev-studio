#!/usr/bin/env bash
# Reviewed, resumable single-train coordinator for already-briefed Chanakya tasks.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/chanakya-task-train.sh --train <name> [--limit N] [--yes]
  scripts/chanakya-task-train.sh --only T001,T002 --name <name> [--yes]

Options:
  --project <slug>          Project slug. Defaults to ACHILLES_PROJECT or git toplevel basename.
  --train <name>            Select dispatch-ready tasks in this train.
  --only <ids>              Comma-separated task ids/UUIDs. Still requires each task to be dispatch-ready.
  --name <name>             Runtime train name. Defaults to --train or "manual".
  --limit <n>               Cap selected tasks for a new run.
  --state-dir <path>        Override runtime state dir.
  --review-host <profile>   Reviewer profile for phase-review.sh. Defaults via phase-review.sh.
  --dispatch-target <node>  Worker target for achilles-dispatch.sh. Defaults to any.
  --dispatch-flags <flags>  Flags forwarded after "--" to achilles-dispatch.sh.
  --poll-seconds <n>        Watch poll interval. Default 30.
  --timeout-seconds <n>     Per-task watch timeout. Default 7200. Use 0 for no timeout.
  --no-watch                Dispatch the next task, persist state, and exit.
  --yes                     Execute. Without this flag the script is a dry run.
  --dry-run                 Force dry run.
  --reset                   Remove existing state before starting. Ignored in dry run.
USAGE
  exit 2
}

fail() {
  printf 'chanakya-task-train: %s\n' "$1" >&2
  exit "${2:-1}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required" 2
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

json_escape() {
  jq -Rs . <<EOF | tr -d '\n'
$1
EOF
}

PROJECT=""
TRAIN=""
ONLY=""
NAME=""
LIMIT=""
STATE_DIR=""
REVIEW_HOST=""
DISPATCH_TARGET="any"
DISPATCH_FLAGS=""
POLL_SECONDS=30
TIMEOUT_SECONDS=7200
WATCH=1
DRY_RUN=1
RESET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --train) TRAIN="${2:-}"; shift 2 ;;
    --train=*) TRAIN="${1#--train=}"; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --only=*) ONLY="${1#--only=}"; shift ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --name=*) NAME="${1#--name=}"; shift ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --limit=*) LIMIT="${1#--limit=}"; shift ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --state-dir=*) STATE_DIR="${1#--state-dir=}"; shift ;;
    --review-host) REVIEW_HOST="${2:-}"; shift 2 ;;
    --review-host=*) REVIEW_HOST="${1#--review-host=}"; shift ;;
    --dispatch-target) DISPATCH_TARGET="${2:-}"; shift 2 ;;
    --dispatch-target=*) DISPATCH_TARGET="${1#--dispatch-target=}"; shift ;;
    --dispatch-flags) DISPATCH_FLAGS="${2:-}"; shift 2 ;;
    --dispatch-flags=*) DISPATCH_FLAGS="${1#--dispatch-flags=}"; shift ;;
    --poll-seconds) POLL_SECONDS="${2:-}"; shift 2 ;;
    --poll-seconds=*) POLL_SECONDS="${1#--poll-seconds=}"; shift ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --timeout-seconds=*) TIMEOUT_SECONDS="${1#--timeout-seconds=}"; shift ;;
    --no-watch) WATCH=0; shift ;;
    --yes) DRY_RUN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reset) RESET=1; shift ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1" 2 ;;
  esac
done

require_cmd jq
require_cmd yq

[ -n "$TRAIN" ] || [ -n "$ONLY" ] || [ -n "$STATE_DIR" ] || usage
if [ -z "$PROJECT" ] && [ -n "$STATE_DIR" ] && [ -f "$STATE_DIR/state.json" ]; then
  PROJECT=$(jq -r '.project // ""' "$STATE_DIR/state.json")
fi
[ -n "$PROJECT" ] || PROJECT=$(resolve_project 2>/dev/null) || fail "no project resolved; pass --project"
if [ -z "$NAME" ] && [ -n "$STATE_DIR" ] && [ -f "$STATE_DIR/state.json" ]; then
  NAME=$(jq -r '.train // ""' "$STATE_DIR/state.json")
fi
[ -n "$NAME" ] || NAME="${TRAIN:-manual}"
TRAIN_SLUG=$(slugify "$NAME")
[ -n "$TRAIN_SLUG" ] || fail "train name collapses to empty slug" 2
case "${LIMIT:-}" in ""|*[!0-9]*) [ -z "${LIMIT:-}" ] || fail "--limit must be numeric" 2 ;; esac
case "$POLL_SECONDS" in ""|*[!0-9]*) fail "--poll-seconds must be numeric" 2 ;; esac
case "$TIMEOUT_SECONDS" in ""|*[!0-9]*) fail "--timeout-seconds must be numeric" 2 ;; esac
[ -z "$LIMIT" ] || [ "$LIMIT" -gt 0 ] || fail "--limit must be greater than 0" 2
[ "$POLL_SECONDS" -gt 0 ] || fail "--poll-seconds must be greater than 0" 2

PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
BRIEFS_DIR=$(resolve_briefs_dir_for "$PROJECT")
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT")
EVENTS_DIR=$(resolve_events_dir_for "$PROJECT")

[ -d "$TASKS_DIR" ] || fail "tasks dir not found: $TASKS_DIR" 2
[ -d "$BRIEFS_DIR" ] || fail "briefs dir not found: $BRIEFS_DIR" 2

[ -n "$STATE_DIR" ] || STATE_DIR="$PROJECT_ROOT/.runtime/task-trains/$TRAIN_SLUG"
STATE_FILE="$STATE_DIR/state.json"
LOCAL_EVENTS="$STATE_DIR/events.jsonl"
RUN_ID=""

record_runtime_event() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  local event="$1" task="${2:-}" data="${3:-{}}"
  mkdir -p "$STATE_DIR"
  printf '{"ts":"%s","event":"%s","task":"%s","data":%s}\n' \
    "$(iso_now)" "$event" "$task" "$data" >> "$LOCAL_EVENTS"
}

emit_train_event() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  local event="$1" task="${2:-}" data="${3:-{}}"
  local payload idem
  payload=$(jq -nc \
    --arg run_id "$RUN_ID" \
    --arg train "$NAME" \
    --arg state_dir "$STATE_DIR" \
    --argjson data "$data" \
    '$data + {run_id:$run_id, train:$train, state_dir:$state_dir}')
  idem=$(idem_key chanakya task-train "$RUN_ID:$event:$task" "$payload")
  emit_event_keyed chanakya train "$event" "$task" "$payload" \
    --instance-id "$RUN_ID" --idem-key "$idem" >/dev/null 2>&1 || true
  record_runtime_event "$event" "$task" "$payload"
}

task_record_from_file() {
  local file="$1" id legacy title state brief train priority updated
  id=$(yq -r '.id // ""' "$file")
  legacy=$(yq -r '.legacy_task_id // ""' "$file")
  title=$(yq -r '.title // ""' "$file")
  state=$(yq -r '.state // ""' "$file")
  brief=$(yq -r '.links.brief // ""' "$file")
  train=$(yq -r '.train // ""' "$file")
  priority=$(yq -r '.priority // ""' "$file")
  updated=$(yq -r '.updated_at // ""' "$file")
  jq -nc \
    --arg uuid "$id" \
    --arg task_id "${legacy:-$id}" \
    --arg legacy_task_id "$legacy" \
    --arg title "$title" \
    --arg state "$state" \
    --arg brief_id "$brief" \
    --arg train "$train" \
    --arg priority "$priority" \
    --arg updated_at "$updated" \
    --arg task_file "$file" \
    --arg brief_file "$BRIEFS_DIR/$brief.yaml" \
    '{
      uuid:$uuid,
      task_id:$task_id,
      legacy_task_id:$legacy_task_id,
      title:$title,
      state_at_selection:$state,
      brief_id:$brief_id,
      train:($train | select(. != "") // null),
      priority:$priority,
      updated_at:$updated_at,
      task_file:$task_file,
      brief_file:$brief_file,
      status:"pending"
    }'
}

find_task_file() {
  local wanted="$1" file id legacy
  for file in "$TASKS_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    id=$(yq -r '.id // ""' "$file" 2>/dev/null || printf '')
    legacy=$(yq -r '.legacy_task_id // ""' "$file" 2>/dev/null || printf '')
    if [ "$wanted" = "$id" ] || [ "$wanted" = "$legacy" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

task_is_dispatch_ready() {
  local file="$1" state brief_id pred pred_file pred_state duplicate
  state=$(yq -r '.state // ""' "$file" 2>/dev/null || printf '')
  [ "$state" = "briefed" ] || return 1
  brief_id=$(yq -r '.links.brief // ""' "$file" 2>/dev/null || printf '')
  [ -n "$brief_id" ] && [ "$brief_id" != "null" ] || return 1
  [ -f "$BRIEFS_DIR/$brief_id.yaml" ] || return 1
  while IFS= read -r pred; do
    [ -n "$pred" ] || continue
    pred_file="$TASKS_DIR/$pred.yaml"
    [ -f "$pred_file" ] || return 1
    pred_state=$(yq -r '.state // ""' "$pred_file" 2>/dev/null || printf '')
    duplicate=$(yq -r '.duplicate_of // ""' "$pred_file" 2>/dev/null || printf '')
    case "$pred_state" in
      merged|verified|archived) continue ;;
    esac
    [ -n "$duplicate" ] && [ "$duplicate" != "null" ] && continue
    return 1
  done < <(yq -r '.predecessors[]?' "$file" 2>/dev/null || true)
  return 0
}

select_tasks_json() {
  local tmp file id count=0
  tmp=$(mktemp -t chanakya-task-train.tasks.XXXXXX)
  if [ -n "$ONLY" ]; then
    IFS=',' read -r -a ids <<< "$ONLY"
    for id in "${ids[@]}"; do
      id=$(printf '%s' "$id" | sed 's/^ *//; s/ *$//')
      [ -n "$id" ] || continue
      file=$(find_task_file "$id") || fail "task not found: $id" 2
      task_is_dispatch_ready "$file" || fail "task is not dispatch-ready: $id" 2
      task_record_from_file "$file" >> "$tmp"
      count=$((count + 1))
      [ -z "$LIMIT" ] || [ "$count" -lt "$LIMIT" ] || break
    done
  else
    for file in "$TASKS_DIR"/*.yaml; do
      [ -f "$file" ] || continue
      [ "$(yq -r '.train // ""' "$file" 2>/dev/null || printf '')" = "$TRAIN" ] || continue
      task_is_dispatch_ready "$file" || continue
      task_record_from_file "$file" >> "$tmp"
      count=$((count + 1))
      [ -z "$LIMIT" ] || [ "$count" -lt "$LIMIT" ] || break
    done
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    fail "no dispatch-ready tasks selected" 1
  fi
  jq -s '.' "$tmp"
  rm -f "$tmp"
}

state_init() {
  local tasks_json="$1" now
  now=$(iso_now)
  RUN_ID="task-train-$TRAIN_SLUG-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$STATE_DIR/tasks"
  jq -n \
    --arg schema_version "1" \
    --arg run_id "$RUN_ID" \
    --arg project "$PROJECT" \
    --arg train "$NAME" \
    --arg train_filter "$TRAIN" \
    --arg created_at "$now" \
    --arg updated_at "$now" \
    --arg state_dir "$STATE_DIR" \
    --argjson tasks "$tasks_json" \
    '{
      schema_version:($schema_version | tonumber),
      run_id:$run_id,
      project:$project,
      train:$train,
      train_filter:$train_filter,
      status:"running",
      created_at:$created_at,
      updated_at:$updated_at,
      state_dir:$state_dir,
      tasks:$tasks
    }' > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

state_patch() {
  local patch="$1" now
  now=$(iso_now)
  jq --arg now "$now" --argjson patch "$patch" '. + $patch + {updated_at:$now}' \
    "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

state_patch_task() {
  local uuid="$1" patch="$2" now
  now=$(iso_now)
  jq --arg uuid "$uuid" --arg now "$now" --argjson patch "$patch" \
    '.updated_at=$now | .tasks |= map(if .uuid == $uuid then . + $patch else . end)' \
    "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

task_status() {
  local uuid="$1"
  jq -r --arg uuid "$uuid" '.tasks[] | select(.uuid == $uuid) | .status' "$STATE_FILE"
}

task_dir_for() {
  printf '%s/tasks/%s\n' "$STATE_DIR" "$1"
}

write_plan_artifact() {
  local task_json="$1" dir="$2" out="$dir/plan.md"
  local uuid task_id title task_file brief_file
  uuid=$(jq -r '.uuid' <<< "$task_json")
  task_id=$(jq -r '.task_id' <<< "$task_json")
  title=$(jq -r '.title' <<< "$task_json")
  task_file=$(jq -r '.task_file' <<< "$task_json")
  brief_file=$(jq -r '.brief_file' <<< "$task_json")
  mkdir -p "$dir"
  {
    printf '# Task Train Plan Review\n\n'
    printf 'Goal of this task phase\n'
    printf -- '- Dispatch `%s` as part of train `%s` only after sibling-host plan review confirms the brief is executable.\n\n' "$task_id" "$NAME"
    printf 'Scope\n'
    printf -- '- In: one already-briefed, dispatch-ready task. Achilles owns implementation, self-review, Argus invocation, merge, and debrief.\n'
    printf -- '- Out: shell-side brief generation, direct Argus invocation, automatic multi-train spawning, and human-product decisions.\n\n'
    printf 'Task\n'
    printf -- '- task_id: `%s`\n- uuid: `%s`\n- title: %s\n- task_file: `%s`\n- brief_file: `%s`\n\n' \
      "$task_id" "$uuid" "$title" "$task_file" "$brief_file"
    printf 'Task YAML excerpt\n\n```yaml\n'
    sed -n '1,180p' "$task_file"
    printf '\n```\n\nBrief YAML excerpt\n\n```yaml\n'
    sed -n '1,220p' "$brief_file"
    printf '\n```\n\nAcceptance criteria\n'
    printf -- '- Review returns `PHASE_REVIEW_VERDICT=clean` before dispatch.\n'
    printf -- '- Dispatch goes only through `scripts/achilles-dispatch.sh`.\n'
    printf -- '- Runner stops on blocked review, unresolved worker/user blocker, merge conflict, or timeout.\n\n'
    printf 'Explicit ask\n'
    printf -- '- Is this brief ready for unattended Achilles execution inside this train? What is still wrong or missing?\n'
  } > "$out"
  printf '%s\n' "$out"
}

write_outcome_artifact() {
  local task_json="$1" dir="$2" out="$dir/outcome.md" event_json="$3"
  local uuid task_id title task_file debrief_id debrief_file
  uuid=$(jq -r '.uuid' <<< "$task_json")
  task_id=$(jq -r '.task_id' <<< "$task_json")
  title=$(jq -r '.title' <<< "$task_json")
  task_file=$(jq -r '.task_file' <<< "$task_json")
  debrief_id=$(yq -r '.links.debrief // ""' "$task_file" 2>/dev/null || printf '')
  debrief_file=""
  if [ -n "$debrief_id" ] && [ "$debrief_id" != "null" ]; then
    debrief_file="$DEBRIEFS_DIR/$debrief_id.yaml"
  fi
  mkdir -p "$dir"
  {
    printf '# Task Train Outcome Review\n\n'
    printf 'Completed task phase\n'
    printf -- '- task_id: `%s`\n- uuid: `%s`\n- title: %s\n- train: `%s`\n\n' "$task_id" "$uuid" "$title" "$NAME"
    printf 'Observed terminal signal\n\n```json\n'
    printf '%s\n' "$event_json" | jq . 2>/dev/null || printf '%s\n' "$event_json"
    printf '\n```\n\nCurrent task YAML\n\n```yaml\n'
    sed -n '1,220p' "$task_file"
    printf '\n```\n'
    if [ -n "$debrief_file" ] && [ -f "$debrief_file" ]; then
      printf '\nDebrief YAML excerpt\n\n```yaml\n'
      sed -n '1,220p' "$debrief_file"
      printf '\n```\n'
    else
      printf '\nDebrief YAML excerpt\n\nNo linked debrief file was found at outcome-review time.\n'
    fi
    printf '\nVerification evidence\n'
    printf -- '- Outcome review is based on canonical task/debrief YAML and event-log terminal signal, not on runner speculation.\n\n'
    printf 'Explicit ask\n'
    printf -- '- Did execution match the reviewed plan? Any drift, missing acceptance criteria, or next-task blocker before the train continues?\n'
  } > "$out"
  printf '%s\n' "$out"
}

run_phase_review() {
  local kind="$1" input="$2" output="$3" meta verdict
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would run: scripts/phase-review.sh --kind %s --input %s --output %s%s\n' \
      "$kind" "$input" "$output" "${REVIEW_HOST:+ --review-host $REVIEW_HOST}"
    printf 'dry-run\n'
    return 0
  fi
  local args
  args=(--kind "$kind" --input "$input" --output "$output")
  [ -z "$REVIEW_HOST" ] || args=(--review-host "$REVIEW_HOST" "${args[@]}")
  meta=$("$SCRIPT_DIR/phase-review.sh" "${args[@]}")
  printf '%s\n' "$meta"
  verdict=$(printf '%s\n' "$meta" | sed -n 's/^PHASE_REVIEW_VERDICT=//p' | tail -1)
  [ -n "$verdict" ] || verdict="ambiguous"
  printf '%s\n' "$verdict"
}

latest_terminal_event() {
  local uuid="$1" legacy="$2"
  [ -d "$EVENTS_DIR" ] || return 1
  local file
  for file in "$EVENTS_DIR"/*.jsonl; do
    [ -f "$file" ] || continue
    jq -c --arg uuid "$uuid" --arg legacy "$legacy" '
      select((.task == $uuid) or (.task == $legacy) or (.data.task_id == $uuid) or (.data.task_id == $legacy))
      | select(.event | IN(
          "brief_completed",
          "task_completed",
          "task_merged",
          "review_blocked",
          "merge_conflict",
          "task_awaiting_user",
          "task_rescued",
          "brief_failed",
          "build_check_failed",
          "test_run_failed"
        ))
    ' "$file" 2>/dev/null || true
  done | tail -1
}

task_done_from_yaml() {
  local task_file="$1" state
  state=$(yq -r '.state // ""' "$task_file" 2>/dev/null || printf '')
  case "$state" in
    merged|verified|archived) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_task() {
  local task_json="$1" start_s now_s elapsed event event_name uuid legacy task_file
  uuid=$(jq -r '.uuid' <<< "$task_json")
  legacy=$(jq -r '.task_id' <<< "$task_json")
  task_file=$(jq -r '.task_file' <<< "$task_json")
  start_s=$(date -u +%s)
  while :; do
    event=$(latest_terminal_event "$uuid" "$legacy" || true)
    event_name=""
    [ -z "$event" ] || event_name=$(jq -r '.event // ""' <<< "$event")
    case "$event_name" in
      review_blocked|merge_conflict|task_awaiting_user|task_rescued|brief_failed|build_check_failed|test_run_failed)
        printf '%s\n' "$event"
        return 3
        ;;
      brief_completed|task_completed|task_merged)
        printf '%s\n' "$event"
        return 0
        ;;
    esac
    if task_done_from_yaml "$task_file"; then
      jq -nc --arg event "task_state_done" --arg task "$legacy" --arg state "$(yq -r '.state // ""' "$task_file")" \
        '{event:$event, task:$task, data:{state:$state}}'
      return 0
    fi
    if [ "$TIMEOUT_SECONDS" -gt 0 ]; then
      now_s=$(date -u +%s)
      elapsed=$((now_s - start_s))
      if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
        jq -nc --arg event "task_train_timeout" --arg task "$legacy" --argjson timeout "$TIMEOUT_SECONDS" \
          '{event:$event, task:$task, data:{timeout_s:$timeout}}'
        return 4
      fi
    fi
    sleep "$POLL_SECONDS"
  done
}

print_dry_run() {
  local tasks_json="$1"
  printf 'DRY RUN: no state writes, events, reviews, or dispatches will run.\n'
  printf 'project: %s\ntrain: %s\nstate_dir: %s\nwatch: %s\n\n' "$PROJECT" "$NAME" "$STATE_DIR" "$WATCH"
  printf 'selected tasks:\n'
  printf '%s\n' "$tasks_json" | jq -r '.[] | "- \(.task_id) [\(.priority)] \(.title) (\(.uuid))"'
  printf '\nper task command shape:\n'
  printf '%s\n' "$tasks_json" | jq -r --arg target "$DISPATCH_TARGET" --arg flags "$DISPATCH_FLAGS" \
    '.[] | "scripts/phase-review.sh --kind plan --input <state>/tasks/\(.uuid)/plan.md --output <state>/tasks/\(.uuid)/plan-review.md\nscripts/achilles-dispatch.sh \(.task_id) \($target)" + (if $flags == "" then "" else " -- " + $flags end) + "\nscripts/phase-review.sh --kind outcome --input <state>/tasks/\(.uuid)/outcome.md --output <state>/tasks/\(.uuid)/outcome-review.md\n"'
}

if [ "$DRY_RUN" -eq 1 ]; then
  if [ -f "$STATE_FILE" ]; then
    print_dry_run "$(jq '.tasks' "$STATE_FILE")"
  else
    print_dry_run "$(select_tasks_json)"
  fi
  exit 0
fi

mkdir -p "$STATE_DIR"
LOCK_DIR="$STATE_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "state dir is already in use: $STATE_DIR" 3
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [ "$RESET" -eq 1 ]; then
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name .lock -exec rm -rf {} +
fi

if [ -f "$STATE_FILE" ]; then
  RUN_ID=$(jq -r '.run_id // ""' "$STATE_FILE")
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || fail "state file missing run_id: $STATE_FILE" 2
  state_patch '{"status":"running"}'
  emit_train_event task_train_resume_started "" "$(jq -nc --arg state_file "$STATE_FILE" '{state_file:$state_file}')"
else
  state_init "$(select_tasks_json)"
  emit_train_event task_train_run_started "" "$(jq -nc --arg state_file "$STATE_FILE" '{state_file:$state_file}')"
fi

TASK_ROWS_FILE=$(mktemp -t chanakya-task-train.rows.XXXXXX)
jq -c '.tasks[]' "$STATE_FILE" > "$TASK_ROWS_FILE"

while IFS= read -r task_json; do
  uuid=$(jq -r '.uuid' <<< "$task_json")
  task_id=$(jq -r '.task_id' <<< "$task_json")
  task_file=$(jq -r '.task_file' <<< "$task_json")
  status=$(task_status "$uuid")
  dir=$(task_dir_for "$uuid")

  case "$status" in
    outcome_reviewed)
      continue
      ;;
    halted)
      state_patch '{"status":"halted","halt_reason":"task_already_halted"}'
      emit_train_event task_train_halted "$task_id" "$(jq -nc --arg uuid "$uuid" '{uuid:$uuid, reason:"task_already_halted"}')"
      fail "task $task_id is already halted; inspect $STATE_FILE or rerun with --reset"
      ;;
    pending)
      emit_train_event task_train_task_started "$task_id" "$(jq -nc --arg uuid "$uuid" '{uuid:$uuid, stage:"plan_review"}')"
      plan_file=$(write_plan_artifact "$task_json" "$dir")
      review_output="$dir/plan-review.md"
      review_meta=$(run_phase_review plan "$plan_file" "$review_output")
      verdict=$(printf '%s\n' "$review_meta" | tail -1)
      state_patch_task "$uuid" "$(jq -nc --arg verdict "$verdict" --arg plan "$plan_file" --arg review "$review_output" \
        '{status:(if $verdict == "clean" then "plan_reviewed" else "halted" end), plan_review_verdict:$verdict, plan_file:$plan, plan_review_file:$review}')"
      emit_train_event task_train_plan_review_completed "$task_id" "$(jq -nc --arg uuid "$uuid" --arg verdict "$verdict" --arg review "$review_output" \
        '{uuid:$uuid, verdict:$verdict, review_file:$review}')"
      [ "$verdict" = "clean" ] || {
        state_patch "$(jq -nc --arg reason "plan_review_$verdict" '{status:"halted", halt_reason:$reason}')"
        emit_train_event task_train_halted "$task_id" "$(jq -nc --arg reason "plan_review_$verdict" '{reason:$reason}')"
        fail "plan review for $task_id returned $verdict"
      }
      status="plan_reviewed"
      ;;
    plan_reviewed|dispatched|completed)
      ;;
    *)
      state_patch "$(jq -nc --arg status "$status" '{status:"halted", halt_reason:("unknown_task_status:" + $status)}')"
      emit_train_event task_train_halted "$task_id" "$(jq -nc --arg uuid "$uuid" --arg status "$status" '{uuid:$uuid, reason:"unknown_task_status", status:$status}')"
      fail "task $task_id has unknown train status: $status"
      ;;
  esac

  if [ "$status" = "plan_reviewed" ]; then
    emit_train_event task_dispatched "$task_id" "$(jq -nc --arg worker "$DISPATCH_TARGET" --arg flags "$DISPATCH_FLAGS" '{worker:$worker, flags:$flags, from_brief:true}')"
    emit_train_event task_train_task_dispatched "$task_id" "$(jq -nc --arg uuid "$uuid" --arg target "$DISPATCH_TARGET" '{uuid:$uuid, target:$target}')"
    dispatch_args=("$task_id" "$DISPATCH_TARGET")
    if [ -n "$DISPATCH_FLAGS" ]; then
      # shellcheck disable=SC2206
      extra_flags=( $DISPATCH_FLAGS )
      dispatch_args+=("--" "${extra_flags[@]}")
    fi
    if ! ACHILLES_PROJECT="$PROJECT" "$SCRIPT_DIR/achilles-dispatch.sh" "${dispatch_args[@]}"; then
      state_patch_task "$uuid" '{"status":"halted","halt_reason":"dispatch_failed"}'
      state_patch '{"status":"halted","halt_reason":"dispatch_failed"}'
      emit_train_event task_train_halted "$task_id" '{"reason":"dispatch_failed"}'
      fail "dispatch failed for $task_id"
    fi
    state_patch_task "$uuid" "$(jq -nc --arg at "$(iso_now)" '{status:"dispatched", dispatched_at:$at}')"
    status="dispatched"
  fi

  if [ "$status" = "dispatched" ]; then
    if [ "$WATCH" -eq 0 ]; then
      state_patch '{"status":"waiting"}'
      printf 'dispatched %s; resume with: scripts/chanakya-task-train.sh --state-dir %s --yes\n' "$task_id" "$STATE_DIR"
      exit 0
    fi
    if completion_event=$(wait_for_task "$task_json"); then
      state_patch_task "$uuid" "$(jq -nc --argjson event "$completion_event" '{status:"completed", terminal_event:$event}')"
      emit_train_event task_train_task_completed "$task_id" "$(jq -nc --arg uuid "$uuid" --argjson event "$completion_event" '{uuid:$uuid, terminal_event:$event}')"
      status="completed"
    else
      rc=$?
      state_patch_task "$uuid" "$(jq -nc --argjson event "$completion_event" --argjson rc "$rc" '{status:"halted", halt_reason:"terminal_event_or_timeout", terminal_event:$event, rc:$rc}')"
      state_patch '{"status":"halted","halt_reason":"terminal_event_or_timeout"}'
      emit_train_event task_train_halted "$task_id" "$(jq -nc --argjson event "$completion_event" --argjson rc "$rc" '{reason:"terminal_event_or_timeout", terminal_event:$event, rc:$rc}')"
      fail "task $task_id halted before completion"
    fi
  fi

  if [ "$status" = "completed" ]; then
    task_json=$(jq --arg uuid "$uuid" '.tasks[] | select(.uuid == $uuid)' "$STATE_FILE")
    completion_event=$(jq -c '.terminal_event // {}' <<< "$task_json")
    outcome_file=$(write_outcome_artifact "$task_json" "$dir" "$completion_event")
    outcome_review="$dir/outcome-review.md"
    review_meta=$(run_phase_review outcome "$outcome_file" "$outcome_review")
    verdict=$(printf '%s\n' "$review_meta" | tail -1)
    state_patch_task "$uuid" "$(jq -nc --arg verdict "$verdict" --arg outcome "$outcome_file" --arg review "$outcome_review" \
      '{status:(if $verdict == "clean" then "outcome_reviewed" else "halted" end), outcome_review_verdict:$verdict, outcome_file:$outcome, outcome_review_file:$review}')"
    emit_train_event task_train_outcome_review_completed "$task_id" "$(jq -nc --arg uuid "$uuid" --arg verdict "$verdict" --arg review "$outcome_review" \
      '{uuid:$uuid, verdict:$verdict, review_file:$review}')"
    [ "$verdict" = "clean" ] || {
      state_patch "$(jq -nc --arg reason "outcome_review_$verdict" '{status:"halted", halt_reason:$reason}')"
      emit_train_event task_train_halted "$task_id" "$(jq -nc --arg reason "outcome_review_$verdict" '{reason:$reason}')"
      fail "outcome review for $task_id returned $verdict"
    }
  fi
done < "$TASK_ROWS_FILE"
rm -f "$TASK_ROWS_FILE"

state_patch '{"status":"completed"}'
emit_train_event task_train_run_completed "" "$(jq -nc --arg state_file "$STATE_FILE" '{state_file:$state_file}')"
printf 'task train completed: %s\nstate: %s\n' "$RUN_ID" "$STATE_FILE"
