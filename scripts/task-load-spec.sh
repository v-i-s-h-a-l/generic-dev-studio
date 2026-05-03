#!/usr/bin/env bash
# task-load-spec.sh — Step 1 of the Achilles task mode.
#
# Resolves a brief for <task-id> through the post-2.6 task YAML
# links.brief pointer. Empty task-id → direct mode (no brief). Legacy markdown
# is checked only to make migration failures diagnostic; it is never returned
# as BRIEF_PATH.
#
# Output is eval-able (key=value per line), same contract as argus-diff-extract.sh:
#   TASK_MODE=brief|direct
#   BRIEF_PATH=<path>          (empty on direct mode)
#   BRIEF_UUID=<uuid>          (empty on direct mode)
#   SIZE=<xs|s|m|l>
#   TYPE=<feature|bugfix|...>
#   ACCEPTANCE_JSON='<json-array>'
#   BASE_BRANCH=<branch>        (optional explicit dispatch base from brief)
#   BRIEF_SUMMARY=<string>      (only when BRIEF_SLICE=summary)
#   BRIEF_SUMMARY_TOKENS=<n>    (only when BRIEF_SLICE=summary)
#
# Usage:
#   eval "$(scripts/task-load-spec.sh <task-id-or-empty>)"
#
# Exit codes:
#   0  spec resolved (or direct mode)
#   2  brief requested but canonical task/brief YAML is missing or mismatched
#   5  task is in a terminal state (#263) — refusing re-dispatch. Override
#      with ACHILLES_REOPEN=1 (writes a follow-up debrief) or run
#      `/chanakya reopen <task-id>` for a formal state-machine reopen.
#   6  brief exists but is not ready for dispatch. Override with
#      ACHILLES_ALLOW_NON_READY_BRIEF=1 only for intentional recovery.
#   7  BRIEF_SLICE=summary requested but no summary slice exists.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

TASK_ID="${1:-}"

emit_assign() {
  local key="${1:?}" value="${2:-}"
  printf '%s=%q\n' "$key" "$value"
}

# Direct mode short-circuit — no brief, no resolution.
if [ -z "$TASK_ID" ]; then
  emit_assign TASK_MODE direct
  emit_assign BRIEF_PATH ""
  emit_assign BRIEF_UUID ""
  emit_assign SIZE ""
  emit_assign TYPE ""
  emit_assign BASE_BRANCH ""
  emit_assign BRIEF_SUMMARY ""
  emit_assign BRIEF_SUMMARY_TOKENS ""
  printf "ACCEPTANCE_JSON='[]'\n"
  exit 0
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }

BRIEF_PATH=""
BRIEF_UUID=""
SIZE=""
TYPE=""
ACCEPTANCE_JSON='[]'
BASE_BRANCH=""
BRIEF_SUMMARY=""
BRIEF_SUMMARY_TOKENS=""
NON_READY_STATE=""
TASK_YAML=""
TASK_UUID=""

emit_legacy_markdown_diagnostic() {
  local reason="$1" legacy_tasks_dir legacy_match data
  legacy_tasks_dir="$(resolve_plans_dir_for "$PROJECT")/chanakya-tasks"
  [ -d "$legacy_tasks_dir" ] || return 1
  legacy_match=$(find "$legacy_tasks_dir" -maxdepth 1 -type f -name "$TASK_ID-*.md" -print 2>/dev/null | sort | head -1)
  [ -n "$legacy_match" ] || return 1
  data=$(jq -nc \
    --arg domain "briefs" \
    --arg reason "$reason" \
    --arg caller "task-load-spec.sh" \
    --arg legacy_path "$legacy_match" \
    '{domain:$domain, reason:$reason, caller:$caller, diagnostic:true, legacy_path:$legacy_path}' 2>/dev/null \
    || printf '{"domain":"briefs","reason":"%s","caller":"task-load-spec.sh","diagnostic":true}' "$reason")
  emit_event_keyed achilles task legacy_artifact_read "$TASK_ID" "$data" \
    >/dev/null 2>&1 || true
  printf '  Legacy markdown exists at %s, but markdown is diagnostic-only; backfill canonical YAML instead.\n' "$legacy_match" >&2
}

# _try_brief_candidate — test one brief YAML for dispatchable state, populate
# globals on match. Returns 0 if matched, 1 otherwise.
_try_brief_candidate() {
  local candidate="$1"
  local strict="${2:-0}"
  [ -r "$candidate" ] || return 1
  local state
  state=$(yq -r '.state // "null"' "$candidate" 2>/dev/null || echo null)
  if [ "$state" != "ready" ] && [ "${ACHILLES_ALLOW_NON_READY_BRIEF:-0}" != "1" ]; then
    NON_READY_STATE="$state"
    if [ "$strict" = "1" ]; then
      cat >&2 <<EOF
error: brief for task-id '$TASK_ID' is state '$state', not ready — refusing dispatch.
  Run \`/chanakya brief $TASK_ID\` or the relevant authoring step to mark it
  ready. Set ACHILLES_ALLOW_NON_READY_BRIEF=1 only for intentional recovery.
EOF
      exit 6
    fi
    return 1
  fi
  case "$state" in
    ready|dispatched|draft) ;;
    *) return 1 ;;
  esac
  BRIEF_PATH="$candidate"
  BRIEF_UUID=$(yq -r '.id // ""' "$candidate" 2>/dev/null || echo "")
  SIZE=$(yq -r '.size // ""' "$candidate" 2>/dev/null || echo "")
  TYPE=$(yq -r '.type // ""' "$candidate" 2>/dev/null || echo "")
  ACCEPTANCE_JSON=$(yq -o=json -I=0 '.acceptance // []' "$candidate" 2>/dev/null || echo '[]')
  BASE_BRANCH=$(yq -r '.base_branch // .dispatch.base_branch // ""' "$candidate" 2>/dev/null || echo "")
  return 0
}

if ! command -v yq >/dev/null 2>&1; then
  printf 'error: task brief dispatch requires yq to read canonical task/brief YAML.\n' >&2
  emit_legacy_markdown_diagnostic "yq_unavailable" || true
  exit 2
fi

tasks_dir=$(resolve_tasks_dir_for "$PROJECT")
briefs_dir=$(resolve_briefs_dir_for "$PROJECT")
if [ ! -d "$tasks_dir" ] || [ ! -d "$briefs_dir" ]; then
  cat >&2 <<EOF
error: canonical plans layout incomplete for task-id '$TASK_ID'.
  Expected both:
    $tasks_dir
    $briefs_dir
EOF
  emit_legacy_markdown_diagnostic "canonical_layout_incomplete" || true
  exit 2
fi

task_match_count=0
while IFS= read -r candidate_task; do
  [ -z "$candidate_task" ] && continue
  candidate_legacy_task_id=$(yq -r '.legacy_task_id // ""' "$candidate_task" 2>/dev/null) || {
    printf 'error: failed to parse task YAML: %s\n' "$candidate_task" >&2
    exit 2
  }
  [ "$candidate_legacy_task_id" = "$TASK_ID" ] || continue
  task_match_count=$((task_match_count + 1))
  TASK_YAML="$candidate_task"
done < <(find "$tasks_dir" -maxdepth 1 -type f -name '*.yaml' -print 2>/dev/null | sort)

if [ "$task_match_count" -eq 0 ]; then
  cat >&2 <<EOF
error: no canonical task YAML found for task-id '$TASK_ID'.
  Run \`/chanakya brief $TASK_ID\` to author one, or invoke \`/achilles\` (no
  task-id) for direct mode.
EOF
  emit_legacy_markdown_diagnostic "no_task_yaml_for_legacy_id" || true
  exit 2
fi

if [ "$task_match_count" -gt 1 ]; then
  printf "error: %s canonical task YAML files match legacy task-id '%s'; refusing ambiguous dispatch.\n" "$task_match_count" "$TASK_ID" >&2
  exit 2
fi

TASK_UUID=$(yq -r '.id // ""' "$TASK_YAML" 2>/dev/null) || {
  printf 'error: failed to read task id from %s\n' "$TASK_YAML" >&2
  exit 2
}
brief_uuid_link=$(yq -r '.links.brief // ""' "$TASK_YAML" 2>/dev/null) || {
  printf 'error: failed to read links.brief from %s\n' "$TASK_YAML" >&2
  exit 2
}
if [ -z "$TASK_UUID" ] || [ -z "$brief_uuid_link" ]; then
  cat >&2 <<EOF
error: canonical task YAML for '$TASK_ID' is incomplete.
  task: $TASK_YAML
  required fields: id, links.brief
EOF
  emit_legacy_markdown_diagnostic "task_yaml_missing_brief_link" || true
  exit 2
fi

candidate="$briefs_dir/${brief_uuid_link}.yaml"
if [ ! -r "$candidate" ]; then
  cat >&2 <<EOF
error: task '$TASK_ID' links brief '$brief_uuid_link', but the brief file is missing.
  task:  $TASK_YAML
  brief: $candidate
EOF
  emit_legacy_markdown_diagnostic "linked_brief_yaml_missing" || true
  exit 2
fi

brief_id=$(yq -r '.id // ""' "$candidate" 2>/dev/null) || {
  printf 'error: failed to read brief id from %s\n' "$candidate" >&2
  exit 2
}
brief_task_id=$(yq -r '.task_id // ""' "$candidate" 2>/dev/null) || {
  printf 'error: failed to read brief task_id from %s\n' "$candidate" >&2
  exit 2
}
brief_legacy_task_id=$(yq -r '.legacy_task_id // ""' "$candidate" 2>/dev/null) || {
  printf 'error: failed to read brief legacy_task_id from %s\n' "$candidate" >&2
  exit 2
}

if [ "$brief_id" != "$brief_uuid_link" ] || [ "$brief_task_id" != "$TASK_UUID" ] || [ "$brief_legacy_task_id" != "$TASK_ID" ]; then
  cat >&2 <<EOF
error: task/brief parity failed for task-id '$TASK_ID'.
  task:              $TASK_YAML
  task.id:           $TASK_UUID
  task.links.brief:  $brief_uuid_link
  brief:             $candidate
  brief.id:          $brief_id
  brief.task_id:     $brief_task_id
  brief.legacy_task_id: $brief_legacy_task_id
EOF
  emit_legacy_markdown_diagnostic "task_brief_parity_mismatch" || true
  exit 2
fi

_try_brief_candidate "$candidate" 1

if [ -z "$BRIEF_PATH" ]; then
  cat >&2 <<EOF
error: no dispatchable canonical brief found for task-id '$TASK_ID'.
  Run \`/chanakya brief $TASK_ID\` to author one, or invoke \`/achilles\` (no
  task-id) for direct mode.
EOF
  exit 2
fi

# #263 — terminal-state guard. Brief-state filtering above (ready / dispatched
# / draft) covers brief lifecycle; task lifecycle still needs its own refusal
# so a terminal-history retrieval does not re-run a completed task — fresh
# worktree, second debrief, and in build / push-tf modes a second release
# action. Read the resolved task YAML and refuse when terminal.
# ACHILLES_REOPEN=1 is the explicit user override —
# legacy escape hatch that mints a follow-up debrief on the existing task
# without recording reopen lineage. The formal path is `/chanakya reopen`
# (#252), which transitions the task to `reopened`, stamps reopen_reason,
# appends the prior debrief id to reopen_chain, and emits task_reopened so
# the next brief carries the round-2 context. Prefer the formal path when
# you need provenance; the env-var override remains for one-off recovery.
if [ -z "${ACHILLES_REOPEN:-}" ] && command -v yq >/dev/null 2>&1; then
  if [ -n "$TASK_YAML" ]; then
    task_state=$(yq -r '.state // ""' "$TASK_YAML" 2>/dev/null)
    case "$task_state" in
      merged|user-verifying|verified|archived)
        cat >&2 <<EOF
error: task '$TASK_ID' is in terminal state '$task_state' — refusing to dispatch.
  A second dispatch on a completed task creates a duplicate worktree and a
  second debrief; in build / push-tf modes it can re-run a release action.
  Run \`/chanakya reopen $TASK_ID --reason="<text>"\` for a formal
  state-machine reopen (records reason, appends prior debrief to
  reopen_chain, emits task_reopened). Set ACHILLES_REOPEN=1 for the legacy
  override that mints a follow-up debrief without lineage — prefer the
  formal path when provenance matters.
EOF
        exit 5 ;;
    esac
  fi
fi

# Fill sensible defaults so the caller never trips on an empty var.
[ -z "$SIZE" ] && SIZE=m
[ -z "$TYPE" ] && TYPE=feature

estimate_summary_tokens() {
  local summary="$1" words
  words=$(printf '%s' "$summary" | wc -w | tr -d ' ')
  printf '%d' "$(( (words * 13) / 10 ))"
}

if [ "${BRIEF_SLICE:-}" = "summary" ]; then
  if [ "${BRIEF_PATH##*.}" != "yaml" ]; then
    cat >&2 <<EOF
error: BRIEF_SLICE=summary requested for task '$TASK_ID', but resolved brief is not canonical YAML.
  Re-author or backfill the YAML brief before using the compact slice.
EOF
    exit 7
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'error: BRIEF_SLICE=summary requires yq to read %s\n' "$BRIEF_PATH" >&2
    exit 7
  fi
  BRIEF_SUMMARY=$(yq -r '.summary // ""' "$BRIEF_PATH" 2>/dev/null || echo "")
  if [ -z "$BRIEF_SUMMARY" ]; then
    cat >&2 <<EOF
error: BRIEF_SLICE=summary requested for task '$TASK_ID', but brief '$BRIEF_UUID' has no summary.
  Load the full brief in an interactive context, or backfill summary before using cheap-read mode.
EOF
    exit 7
  fi
  BRIEF_SUMMARY_TOKENS=$(estimate_summary_tokens "$BRIEF_SUMMARY")
  summary_event_data=$(jq -nc \
    --arg brief_uuid "$BRIEF_UUID" \
    --arg reason "caller_request" \
    --argjson summary_tokens_est "$BRIEF_SUMMARY_TOKENS" \
    '{brief_uuid:$brief_uuid, summary_tokens_est:$summary_tokens_est, reason:$reason}' 2>/dev/null \
    || printf '{"brief_uuid":"%s","summary_tokens_est":%s,"reason":"caller_request"}' "$BRIEF_UUID" "$BRIEF_SUMMARY_TOKENS")
  emit_event_keyed achilles task brief_summary_used "$TASK_ID" "$summary_event_data" \
    --idem-key "$(idem_key achilles brief_summary_used "$BRIEF_UUID" "task=$TASK_ID;tokens=$BRIEF_SUMMARY_TOKENS")" \
    >/dev/null 2>&1 || true
fi

emit_assign TASK_MODE brief
emit_assign BRIEF_PATH "$BRIEF_PATH"
emit_assign BRIEF_UUID "$BRIEF_UUID"
emit_assign SIZE "$SIZE"
emit_assign TYPE "$TYPE"
emit_assign BASE_BRANCH "$BASE_BRANCH"
emit_assign BRIEF_SUMMARY "$BRIEF_SUMMARY"
emit_assign BRIEF_SUMMARY_TOKENS "$BRIEF_SUMMARY_TOKENS"
# Single-quote the JSON to survive eval without re-escaping internal quotes.
# ACCEPTANCE_JSON is producer-controlled (yq output); no single quotes possible.
printf "ACCEPTANCE_JSON='%s'\n" "$ACCEPTANCE_JSON"
