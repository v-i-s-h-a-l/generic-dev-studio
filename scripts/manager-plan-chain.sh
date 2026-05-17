#!/usr/bin/env bash
# manager-plan-chain.sh - manager-owned plan to reviewed work-chain orchestration.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
_lp_load_project_env 2>/dev/null || true

PROJECT="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT:-}"
ISSUE_NUMBER=""
ISSUE_SET=""
ISSUE_REPO=""
PARENT_ISSUE_NUMBER=""
SOURCE_FILE=""
SOURCE_TEXT=""
INCLUDE_COMMENTS=0
COMMENT_PACKET_DIR=""
COMMENT_PACKET_MD=""
COMMENT_PACKET_JSON=""
FROM_PLAN=""
FROM_PLAN_JSON=""
FROM_PLAN_KIND=""
TITLE=""
CHAIN_NAME=""
SOURCE_BRANCH="main"
BASE_SHA_EXPECTED="${STUDIO_PLAN_CHAIN_EXPECTED_BASE_SHA:-}"
PARENT_BRANCH=""
PARENT_SHA=""
INDEPENDENT="false"
TARGET_REPO_ROOT=""
HOST="auto"
REVIEW_HOST="${STUDIO_REVIEW_HOST:-claude-reviewer}"
AUTOMATION_MODE="${STUDIO_MANAGER_PLAN_CHAIN_MODE:-unattended}"
EXECUTE_AFTER_PLAN=0
WORK_CHAIN_EXECUTOR="${STUDIO_MANAGER_PLAN_CHAIN_EXECUTOR:-}"
POPULATE_PROJECT_FIELDS="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_FIELDS:-1}"
LINK_SUB_ISSUES="${STUDIO_MANAGER_PLAN_CHAIN_SUB_ISSUES:-1}"
CREATE_PARENT_ISSUE="${STUDIO_MANAGER_PLAN_CHAIN_PARENT_ISSUE:-auto}"
PROJECT_OWNER="${STUDIO_PROJECT_OWNER:-v-i-s-h-a-l}"
PROJECT_NUMBER="${STUDIO_PROJECT_NUMBER:-1}"
PROJECT_STATUS="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_STATUS:-Todo}"
PROJECT_TRACK="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_TRACK:-}"
PROJECT_PHASE="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_PHASE:-}"
PROJECT_SIZE="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_SIZE:-S}"
PROJECT_REVIEW_STATE="${STUDIO_MANAGER_PLAN_CHAIN_PROJECT_REVIEW_STATE:-Plan clean}"
PLAN_CHAIN_RETENTION_DAYS="${STUDIO_MANAGER_PLAN_CHAIN_RETENTION_DAYS:-30}"
PLAN_CHAIN_ARTIFACT_MAX_BYTES="${STUDIO_MANAGER_PLAN_CHAIN_ARTIFACT_MAX_BYTES:-1048576}"
DRY_RUN=0
ALLOW_MISSING_DETAILS=0
POSITIONAL=()
SCRIPT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SCRIPT_STARTED_EPOCH=$(date -u +%s)
EXECUTION_STATUS="not_requested"
EXECUTION_EXIT_CODE="null"
EXECUTION_STARTED_AT=""
EXECUTION_ENDED_AT=""
EXECUTION_DURATION_S="null"
EXECUTION_COMMAND_JSON="[]"

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-plan-chain.sh [--issue N] [--repo owner/repo] [--chain name] [goal text]
  scripts/manager-plan-chain.sh --issue-set N,N [--include-comments] [--repo owner/repo] [--chain name]
  scripts/manager-plan-chain.sh --source-file source.md [--chain name]
  scripts/manager-plan-chain.sh --from-plan task-graph.json [--chain name]
  scripts/manager-plan-chain.sh --source-file prd.md --execute [--interactive]

Normalizes a shaped goal or issue brief, synthesizes a planner task graph,
runs same-host self-review plus scripts/phase-review.sh, creates durable
GitHub issues for reviewed worker contracts, links them as native sub-issues
when a parent is available, populates configured Project fields, writes a
runnable chain manifest under ~/.dev-studio/<project>/plan-chains, and prints
the clean-session manager work-chain command.

Default automation mode is unattended. Use --execute to launch the generated
work-chain after a clean plan review. Use --interactive/--attended when the
runner should pause only for material design, permission, implementation, or
test blockers.

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

duration_since_epoch() {
  local started_epoch="$1" ended_epoch
  ended_epoch=$(date -u +%s)
  printf '%s\n' $((ended_epoch - started_epoch))
}

json_string_array_from_argv() {
  jq -cn '$ARGS.positional' --args "$@"
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

gh_api_json() {
  "$SCRIPT_DIR/studio-gh.sh" api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "$@"
}

issue_api_json() {
  local issue_number="$1"
  gh_api_json "/repos/$ISSUE_REPO/issues/$issue_number"
}

issue_database_id() {
  local issue_number="$1"
  issue_api_json "$issue_number" | jq -r '.id // empty'
}

issue_url_for_number() {
  local issue_number="$1"
  printf 'https://github.com/%s/issues/%s\n' "$ISSUE_REPO" "$issue_number"
}

extract_source_field() {
  local field="$1" target
  target=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')
  awk -v target="$target" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      line = $0
      gsub(/`/, "", line)
      gsub(/^[[:space:]>*-]+/, "", line)
      lower = tolower(line)
      if (index(lower, target ":") == 1) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        print trim(line)
        exit
      }
    }
  ' "$SOURCE_MD"
}

default_project_fields_from_source() {
  local extracted
  if [ -z "$PROJECT_TRACK" ]; then
    extracted=$(extract_source_field "Track" || true)
    PROJECT_TRACK="${extracted:-backlog}"
  fi
  if [ -z "$PROJECT_PHASE" ]; then
    extracted=$(extract_source_field "Phase" || true)
    PROJECT_PHASE="${extracted:-D}"
  fi
  [ -n "$PROJECT_SIZE" ] || PROJECT_SIZE="S"
  [ -n "$PROJECT_REVIEW_STATE" ] || PROJECT_REVIEW_STATE="Plan clean"
  [ -n "$PROJECT_STATUS" ] || PROJECT_STATUS="Todo"
}

init_project_fields_artifact() {
  jq -n \
    --argjson enabled "$POPULATE_PROJECT_FIELDS" \
    --arg owner "$PROJECT_OWNER" \
    --argjson number "$PROJECT_NUMBER" \
    --arg status "$PROJECT_STATUS" \
    --arg track "$PROJECT_TRACK" \
    --arg phase "$PROJECT_PHASE" \
    --arg size "$PROJECT_SIZE" \
    --arg review "$PROJECT_REVIEW_STATE" \
    '{
      enabled: ($enabled == 1),
      owner: $owner,
      project_number: $number,
      planned_fields: {
        Status: $status,
        Track: $track,
        Phase: $phase,
        Size: $size,
        "Sibling host reviewed": $review
      },
      items: []
    }' > "$PROJECT_FIELDS_JSON"
}

field_id_from_meta() {
  local field_name="$1"
  jq -r --arg field "$field_name" '
    (.fields // .)[]?
    | select(.name == $field)
    | .id
  ' "$PROJECT_FIELDS_META" | head -1
}

field_option_id_from_meta() {
  local field_name="$1" value="$2"
  jq -r --arg field "$field_name" --arg value "$value" '
    (.fields // .)[]?
    | select(.name == $field)
    | (.options // [])[]?
    | select(.name == $value)
    | .id
  ' "$PROJECT_FIELDS_META" | head -1
}

require_project_field_option() {
  local field_name="$1" value="$2" field_id option_id
  field_id=$(field_id_from_meta "$field_name")
  [ -n "$field_id" ] || {
    printf 'manager-plan-chain: Project field not found: %s\n' "$field_name" >&2
    exit 1
  }
  option_id=$(field_option_id_from_meta "$field_name" "$value")
  [ -n "$option_id" ] || {
    printf 'manager-plan-chain: Project field %s has no option %s\n' "$field_name" "$value" >&2
    exit 1
  }
}

prepare_project_field_metadata() {
  [ "$POPULATE_PROJECT_FIELDS" -eq 1 ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0

  "$SCRIPT_DIR/studio-gh.sh" project view "$PROJECT_NUMBER" \
    --owner "$PROJECT_OWNER" \
    --format json > "$PROJECT_VIEW_JSON" || {
      printf 'manager-plan-chain: failed to read Project %s/%s; Project field writes require GitHub project scope\n' "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
      exit 1
    }
  PROJECT_ID=$(jq -r '.id // empty' "$PROJECT_VIEW_JSON")
  [ -n "$PROJECT_ID" ] || {
    printf 'manager-plan-chain: Project %s/%s did not expose an id\n' "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
    exit 1
  }

  "$SCRIPT_DIR/studio-gh.sh" project field-list "$PROJECT_NUMBER" \
    --owner "$PROJECT_OWNER" \
    --limit 100 \
    --format json > "$PROJECT_FIELDS_META" || {
      printf 'manager-plan-chain: failed to read Project fields for %s/%s\n' "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
      exit 1
    }

  require_project_field_option "Status" "$PROJECT_STATUS"
  require_project_field_option "Track" "$PROJECT_TRACK"
  require_project_field_option "Phase" "$PROJECT_PHASE"
  require_project_field_option "Size" "$PROJECT_SIZE"
  require_project_field_option "Sibling host reviewed" "$PROJECT_REVIEW_STATE"
}

append_project_field_item() {
  local issue_number="$1" issue_url="$2" item_id="$3" kind="$4" tmp
  tmp="$PROJECT_FIELDS_JSON.tmp"
  jq \
    --argjson issue_number "$issue_number" \
    --arg issue_url "$issue_url" \
    --arg item_id "$item_id" \
    --arg kind "$kind" \
    --arg status "$PROJECT_STATUS" \
    --arg track "$PROJECT_TRACK" \
    --arg phase "$PROJECT_PHASE" \
    --arg size "$PROJECT_SIZE" \
    --arg review "$PROJECT_REVIEW_STATE" \
    '.items += [{
      issue_number: $issue_number,
      issue_url: $issue_url,
      project_item_id: $item_id,
      kind: $kind,
      fields: {
        Status: $status,
        Track: $track,
        Phase: $phase,
        Size: $size,
        "Sibling host reviewed": $review
      }
    }]' "$PROJECT_FIELDS_JSON" > "$tmp"
  mv "$tmp" "$PROJECT_FIELDS_JSON"
}

set_project_single_select() {
  local item_id="$1" field_name="$2" value="$3" field_id option_id
  field_id=$(field_id_from_meta "$field_name")
  option_id=$(field_option_id_from_meta "$field_name" "$value")
  "$SCRIPT_DIR/studio-gh.sh" project item-edit \
    --id "$item_id" \
    --project-id "$PROJECT_ID" \
    --field-id "$field_id" \
    --single-select-option-id "$option_id" \
    --format json >/dev/null
}

add_issue_to_project_and_set_fields() {
  local issue_number="$1" issue_url="$2" kind="$3" item_json item_id
  [ "$POPULATE_PROJECT_FIELDS" -eq 1 ] || return 0
  item_json=$("$SCRIPT_DIR/studio-gh.sh" project item-add "$PROJECT_NUMBER" \
    --owner "$PROJECT_OWNER" \
    --url "$issue_url" \
    --format json) || {
      printf 'manager-plan-chain: failed to add issue #%s to Project %s/%s\n' "$issue_number" "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
      exit 1
    }
  item_id=$(printf '%s\n' "$item_json" | jq -r '.id // .item.id // empty')
  [ -n "$item_id" ] || {
    printf 'manager-plan-chain: Project item-add did not return an item id for issue #%s\n' "$issue_number" >&2
    exit 1
  }
  set_project_single_select "$item_id" "Status" "$PROJECT_STATUS"
  set_project_single_select "$item_id" "Track" "$PROJECT_TRACK"
  set_project_single_select "$item_id" "Phase" "$PROJECT_PHASE"
  set_project_single_select "$item_id" "Size" "$PROJECT_SIZE"
  set_project_single_select "$item_id" "Sibling host reviewed" "$PROJECT_REVIEW_STATE"
  append_project_field_item "$issue_number" "$issue_url" "$item_id" "$kind"
  printf '%s\n' "$item_id"
}

sweep_plan_chain_artifacts() {
  local root="$1" removed_dirs=0 gzipped_files=0 file dir tmp
  mkdir -p "$root"
  case "$PLAN_CHAIN_RETENTION_DAYS" in
    ''|*[!0-9]*) PLAN_CHAIN_RETENTION_DAYS=30 ;;
  esac
  case "$PLAN_CHAIN_ARTIFACT_MAX_BYTES" in
    ''|*[!0-9]*) PLAN_CHAIN_ARTIFACT_MAX_BYTES=1048576 ;;
  esac

  while IFS= read -r dir; do
    [ "$dir" = "$ARTIFACT_ROOT" ] && continue
    rm -rf "$dir"
    removed_dirs=$((removed_dirs + 1))
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +"$PLAN_CHAIN_RETENTION_DAYS" 2>/dev/null | sort)

  if command -v gzip >/dev/null 2>&1; then
    while IFS= read -r file; do
      case "$file" in
        "$ARTIFACT_ROOT"/*) continue ;;
      esac
      gzip -f "$file"
      gzipped_files=$((gzipped_files + 1))
    done < <(find "$root" -type f ! -name '*.gz' -size +"${PLAN_CHAIN_ARTIFACT_MAX_BYTES}c" 2>/dev/null | sort)
  fi

  tmp="$CLEANUP_JSON.tmp"
  jq -n \
    --arg created_at "$(now_utc)" \
    --arg root "$root" \
    --argjson retention_days "$PLAN_CHAIN_RETENTION_DAYS" \
    --argjson max_bytes "$PLAN_CHAIN_ARTIFACT_MAX_BYTES" \
    --argjson removed_dirs "$removed_dirs" \
    --argjson gzipped_files "$gzipped_files" \
    '{
      created_at: $created_at,
      root: $root,
      retention_class: "plan-chain-private-runtime",
      retention_days: $retention_days,
      artifact_max_bytes: $max_bytes,
      outcome: "completed",
      removed_stale_run_dirs: $removed_dirs,
      gzipped_oversized_files: $gzipped_files
    }' > "$tmp"
  mv "$tmp" "$CLEANUP_JSON"
}

create_parent_issue_body() {
  local body_file="$1"
  {
    printf '## PRD-to-chain Parent\n\n'
    printf 'This issue tracks the reviewed PRD-to-chain decomposition for `%s`.\n\n' "$SUBJECT_REF"
    printf '## Artifacts\n\n'
    printf -- '- Planner artifact: `%s`\n' "$PLANNER_ARTIFACT"
    printf -- '- Review artifact: `%s`\n' "$REVIEW_ARTIFACT"
    printf -- '- Source: `%s`\n\n' "$SOURCE_LABEL"
    printf '## Acceptance\n\n'
    printf -- '- Worker sub-issues remain bounded to the reviewed planner decomposition.\n'
    printf -- '- The generated work-chain manifest is the execution source for scheduler dependencies.\n'
    printf -- '- Missing PRD coverage is tracked as a planning gap, not invented in worker scope.\n\n'
    printf '## Non-Goals\n\n'
    printf -- '- Do not execute implementation work in this parent issue.\n'
    printf -- '- Do not replace private review or worker summary artifacts with issue-body prose.\n'
  } > "$body_file"
}

parse_issue_number_from_create_output() {
  local create_out="$1" issue_url
  if printf '%s\n' "$create_out" | jq -e '.number' >/dev/null 2>&1; then
    printf '%s\n' "$create_out" | jq -r '.number'
    return 0
  fi
  issue_url=$(printf '%s\n' "$create_out" | tail -1)
  printf '%s\n' "$issue_url" | sed -n -E 's#.*issues/([0-9]+).*#\1#p' | tail -1
}

parse_issue_url_from_create_output() {
  local create_out="$1"
  if printf '%s\n' "$create_out" | jq -e '.url' >/dev/null 2>&1; then
    printf '%s\n' "$create_out" | jq -r '.url // ""'
    return 0
  fi
  printf '%s\n' "$create_out" | tail -1
}

create_or_resolve_parent_issue() {
  local body_file create_out issue_number issue_url issue_api issue_id project_item_id parent_title
  if [ "$CREATE_PARENT_ISSUE" = "0" ]; then
    printf 'null\n' > "$PARENT_ISSUE_JSON"
    return 0
  fi
  if [ -n "$PARENT_ISSUE_NUMBER" ]; then
    issue_number="$PARENT_ISSUE_NUMBER"
    issue_url=$(issue_url_for_number "$issue_number")
    issue_api=$(issue_api_json "$issue_number")
    issue_id=$(printf '%s\n' "$issue_api" | jq -r '.id // empty')
    parent_title=$(printf '%s\n' "$issue_api" | jq -r '.title // empty')
    project_item_id=$(add_issue_to_project_and_set_fields "$issue_number" "$issue_url" "parent")
    jq -n \
      --argjson number "$issue_number" \
      --arg url "$issue_url" \
      --arg id "$issue_id" \
      --arg project_item_id "$project_item_id" \
      --arg title "$parent_title" \
      '{number:$number, url:$url, id:$id, created:false, project_item_id:$project_item_id, title:$title}' > "$PARENT_ISSUE_JSON"
    return 0
  fi
  [ "$CREATE_PARENT_ISSUE" = "auto" ] || {
    printf 'null\n' > "$PARENT_ISSUE_JSON"
    return 0
  }

  body_file="$ARTIFACT_ROOT/parent-issue.md"
  create_parent_issue_body "$body_file"
  parent_title=$(truncate_title "$CHAIN_NAME: PRD-to-chain parent")
  create_out=$("$SCRIPT_DIR/studio-gh.sh" issue create --repo "$ISSUE_REPO" --title "$parent_title" --body-file "$body_file") || {
    printf 'manager-plan-chain: failed to create parent issue for %s\n' "$SUBJECT_REF" >&2
    exit 1
  }
  issue_number=$(parse_issue_number_from_create_output "$create_out")
  case "$issue_number" in
    ''|*[!0-9]*)
      printf 'manager-plan-chain: could not parse parent issue number from create output: %s\n' "$create_out" >&2
      exit 1
      ;;
  esac
  issue_url=$(parse_issue_url_from_create_output "$create_out")
  [ -n "$issue_url" ] || issue_url=$(issue_url_for_number "$issue_number")
  issue_id=$(issue_database_id "$issue_number")
  project_item_id=$(add_issue_to_project_and_set_fields "$issue_number" "$issue_url" "parent")
  PARENT_ISSUE_NUMBER="$issue_number"
  jq -n \
    --argjson number "$issue_number" \
    --arg url "$issue_url" \
    --arg id "$issue_id" \
    --arg project_item_id "$project_item_id" \
    --arg title "$parent_title" \
    '{number:$number, url:$url, id:$id, created:true, project_item_id:$project_item_id, title:$title}' > "$PARENT_ISSUE_JSON"
}

verify_sub_issue_api_for_parent() {
  [ "$LINK_SUB_ISSUES" -eq 1 ] || return 0
  [ -n "$PARENT_ISSUE_NUMBER" ] || return 0
  gh_api_json "/repos/$ISSUE_REPO/issues/$PARENT_ISSUE_NUMBER/sub_issues" >/dev/null || {
    printf 'manager-plan-chain: failed to read native sub-issues for parent issue #%s\n' "$PARENT_ISSUE_NUMBER" >&2
    exit 1
  }
}

link_sub_issue_to_parent() {
  local child_issue_number="$1" child_issue_id="$2"
  [ "$LINK_SUB_ISSUES" -eq 1 ] || { printf 'false\n'; return 0; }
  [ -n "$PARENT_ISSUE_NUMBER" ] || { printf 'false\n'; return 0; }
  [ -n "$child_issue_id" ] || {
    printf 'manager-plan-chain: cannot link issue #%s as sub-issue without database id\n' "$child_issue_number" >&2
    exit 1
  }
  gh_api_json -X POST \
    "/repos/$ISSUE_REPO/issues/$PARENT_ISSUE_NUMBER/sub_issues" \
    -F "sub_issue_id=$child_issue_id" >/dev/null || {
      printf 'manager-plan-chain: failed to link issue #%s as sub-issue of #%s\n' "$child_issue_number" "$PARENT_ISSUE_NUMBER" >&2
      exit 1
    }
  printf 'true\n'
}

clean_session_command_for_manifest() {
  if [ "$AUTOMATION_MODE" = "interactive" ]; then
    printf '/dev-studio manager work-chain %s --attended --yes\n' "$WORK_CHAIN"
  else
    printf '/dev-studio manager work-chain %s\n' "$WORK_CHAIN"
  fi
}

execute_work_chain() {
  local cmd=() rc
  [ -n "$WORK_CHAIN_EXECUTOR" ] || WORK_CHAIN_EXECUTOR="$SCRIPT_DIR/manager-work-chain.sh"
  if [ "$AUTOMATION_MODE" = "interactive" ]; then
    cmd=("$WORK_CHAIN_EXECUTOR" "$WORK_CHAIN" "--attended" "--yes")
  else
    cmd=("$WORK_CHAIN_EXECUTOR" "$WORK_CHAIN")
  fi
  EXECUTION_COMMAND_JSON=$(json_string_array_from_argv "${cmd[@]}")
  EXECUTION_STARTED_AT=$(now_utc)
  local started_epoch
  started_epoch=$(date -u +%s)
  set +e
  "${cmd[@]}" > "$EXECUTION_OUT" 2> "$EXECUTION_ERR"
  rc=$?
  set -e
  EXECUTION_ENDED_AT=$(now_utc)
  EXECUTION_DURATION_S=$(duration_since_epoch "$started_epoch")
  EXECUTION_EXIT_CODE="$rc"
  if [ "$rc" -eq 0 ]; then
    EXECUTION_STATUS="completed"
  else
    EXECUTION_STATUS="failed"
  fi
  return "$rc"
}

write_telemetry_artifact() {
  local status="$1" file_count=0 total_bytes=0 file bytes duration_s review_passes created_issue_count project_item_count
  duration_s=$(duration_since_epoch "$SCRIPT_STARTED_EPOCH")
  review_passes=0
  [ -s "$REVIEW_META" ] && review_passes=1
  created_issue_count=$(jq 'length' "$ISSUE_MAP" 2>/dev/null || printf '0')
  project_item_count=$(jq '.items | length' "$PROJECT_FIELDS_JSON" 2>/dev/null || printf '0')
  while IFS= read -r -d '' file; do
    bytes=$(wc -c < "$file" | tr -d '[:space:]')
    total_bytes=$((total_bytes + bytes))
    file_count=$((file_count + 1))
  done < <(find "$ARTIFACT_ROOT" -type f ! -name 'telemetry.json' -print0 2>/dev/null)
  jq -n \
    --arg created_at "$(now_utc)" \
    --arg started_at "$SCRIPT_STARTED_AT" \
    --arg status "$status" \
    --arg mode "$AUTOMATION_MODE" \
    --arg source_ref "$SOURCE_LABEL" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg execution_status "$EXECUTION_STATUS" \
    --arg execution_started_at "$EXECUTION_STARTED_AT" \
    --arg execution_ended_at "$EXECUTION_ENDED_AT" \
    --argjson execution_exit_code "$EXECUTION_EXIT_CODE" \
    --argjson execution_duration_s "$EXECUTION_DURATION_S" \
    --argjson execution_command "$EXECUTION_COMMAND_JSON" \
    --argjson duration_s "$duration_s" \
    --argjson review_passes "$review_passes" \
    --argjson created_issue_count "$created_issue_count" \
    --argjson project_item_count "$project_item_count" \
    --argjson artifact_file_count "$file_count" \
    --argjson artifact_bytes "$total_bytes" \
    --slurpfile cleanup "$CLEANUP_JSON" \
    '{
      schema_version: 1,
      kind: "manager-plan-chain-telemetry",
      created_at: $created_at,
      started_at: $started_at,
      duration_s: $duration_s,
      status: $status,
      automation_mode: $mode,
      source_ref: $source_ref,
      subject_ref: $subject_ref,
      counters: {
        review_passes: $review_passes,
        retries: 0,
        created_issues: $created_issue_count,
        project_items_populated: $project_item_count,
        tests_run: 0
      },
      artifact_size: {
        file_count: $artifact_file_count,
        bytes: $artifact_bytes
      },
      execution: {
        requested: ($execution_status != "not_requested"),
        status: $execution_status,
        exit_code: $execution_exit_code,
        started_at: (if $execution_started_at == "" then null else $execution_started_at end),
        ended_at: (if $execution_ended_at == "" then null else $execution_ended_at end),
        duration_s: $execution_duration_s,
        command: $execution_command
      },
      bottlenecks: (
        []
        + (if $review_passes > 0 then [{kind:"plan_review_gate", count:$review_passes}] else [] end)
        + (if $execution_status == "failed" then [{kind:"work_chain_execution_failed"}] else [] end)
      ),
      cleanup: ($cleanup[0] // null),
      telemetry_gaps: ["tokens"]
    }' > "$TELEMETRY_JSON"
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
      + [(.validation.empty_allowed_paths[]? | "Empty allowed paths for \(.node_id): \(.text)")]
      + [(.validation.fragment_labels[]? | "Fragment-shaped task label for \(.node_id): \(.text)")]
      + [(.validation.unresolved_missing_details[]? | "Missing detail \(.source_id): \(.text)")]
      + (if task_count == 0 then ["No executable task nodes were produced."] else [] end)
    ) | unique
  ' "$TASK_GRAPH"
}

expected_task_count_from_source() {
  awk '
    function lower(s) { return tolower(s) }
    function word_number(s) {
      s = lower(s)
      if (s == "one") return 1
      if (s == "two") return 2
      if (s == "three") return 3
      if (s == "four") return 4
      if (s == "five") return 5
      if (s == "six") return 6
      if (s == "seven") return 7
      if (s == "eight") return 8
      if (s == "nine") return 9
      if (s == "ten") return 10
      return ""
    }
    {
      line = lower($0)
      if (match(line, /[0-9]+[ -]?(component|sub-task|subtask|sub-issue|subissue|contract|task)s?/)) {
        print substr(line, RSTART, RLENGTH) + 0
        exit
      }
      if (match(line, /(one|two|three|four|five|six|seven|eight|nine|ten)[ -]?(component|sub-task|subtask|sub-issue|subissue|contract|task)s?/)) {
        cue = substr(line, RSTART, RLENGTH)
        sub(/[ -]?(component|sub-task|subtask|sub-issue|subissue|contract|task)s?.*/, "", cue)
        print word_number(cue)
        exit
      }
    }
  ' "$SOURCE_MD"
}

write_generated_planner_artifact() {
  local status="$1" blocked_json="$2"
  local expected_task_count produced_task_count cardinality_findings
  expected_task_count=$(expected_task_count_from_source || true)
  case "$expected_task_count" in
    ''|*[!0-9]*) expected_task_count=null ;;
  esac
  produced_task_count=$(jq '[.nodes[]? | select(.kind == "task")] | length' "$TASK_GRAPH")
  cardinality_findings=$(jq -cn \
    --argjson expected "$expected_task_count" \
    --argjson produced "$produced_task_count" \
    'if $expected == null then []
     elif $expected == $produced then ["Cardinality cue expected \($expected) worker contracts; produced \($produced)."]
     else ["WARNING: Cardinality cue expected \($expected) worker contracts; produced \($produced)."]
     end')
  jq -n \
    --slurpfile graph "$TASK_GRAPH" \
    --arg created_at "$(now_utc)" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg source_ref "$SOURCE_LABEL" \
    --arg source_path "$SOURCE_MD" \
    --arg requirement_packet "$REQUIREMENT_PACKET" \
    --arg task_graph "$TASK_GRAPH" \
    --arg review_input "$REVIEW_INPUT" \
    --argjson include_comments "$INCLUDE_COMMENTS" \
    --arg comment_packet "$COMMENT_PACKET_MD" \
    --arg comment_sidecar "$COMMENT_PACKET_JSON" \
    --arg status "$status" \
    --argjson blocked "$blocked_json" \
    --argjson cardinality_findings "$cardinality_findings" \
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
          source_context: {
            comments_included: ($include_comments == 1),
            mode: (if $include_comments == 1 then "issue-context-packet" else "body-only" end),
            packet_path: (if $comment_packet == "" then null else $comment_packet end),
            comment_sidecar_path: (if $comment_sidecar == "" then null else $comment_sidecar end),
            body_only_explicit: ($include_comments != 1)
          },
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
          self_review_findings: ([
            ("Task graph validation status: " + ($g.validation.status // "unknown")),
            ("Worker contract count: " + (($tasks | length) | tostring)),
            "Checked that missing details, packet conflicts, and parallel write races block issue creation."
          ] + $cardinality_findings),
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
        evidence_refs: ([$source_path, $requirement_packet, $task_graph, $review_input, $comment_packet, $comment_sidecar] | map(select(. != "")) | unique),
        privacy_classification: "private-runtime",
        status: $status
      }
  ' > "$PLANNER_ARTIFACT"
}

write_planner_artifact() {
  local status="$1" blocked_json="$2"
  if [ "$FROM_PLAN_KIND" = "planner-output" ] && [ -n "$FROM_PLAN_JSON" ] && [ -r "$FROM_PLAN_JSON" ]; then
    jq -S \
      --arg status "$status" \
      --arg source_path "$SOURCE_MD" \
      --arg requirement_packet "$REQUIREMENT_PACKET" \
      --arg task_graph "$TASK_GRAPH" \
      --arg review_input "$REVIEW_INPUT" \
      --argjson blocked "$blocked_json" \
      '
        .status = $status
        | .evidence_refs = (((.evidence_refs // []) + [$source_path, $requirement_packet, $task_graph, $review_input]) | unique)
        | .payload.self_review_findings = (
            (.payload.self_review_findings // [])
            + [
                "Task graph validation status: ready for reviewed planner-output ingest.",
                "Preserved planner-output contract-specific checks, stop conditions, non-goals, acceptance criteria, and follow-up notes."
              ]
            | unique
          )
        | .payload.self_review_fixes = (
            (.payload.self_review_fixes // [])
            + (if ($blocked | length) > 0
               then ["Stopped before review, issue creation, and manifest creation because the source needs more context."]
               else []
               end)
            | unique
          )
      ' "$FROM_PLAN_JSON" > "$PLANNER_ARTIFACT"
    return 0
  fi

  write_generated_planner_artifact "$status" "$blocked_json"
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
    --arg automation_mode "$AUTOMATION_MODE" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg source_ref "$SOURCE_LABEL" \
    --arg artifact_root "$ARTIFACT_ROOT" \
    --arg planner_artifact "$PLANNER_ARTIFACT" \
    --argjson include_comments "$INCLUDE_COMMENTS" \
    --arg comment_packet "$COMMENT_PACKET_MD" \
    --arg comment_sidecar "$COMMENT_PACKET_JSON" \
    --arg review_artifact "$review_path" \
    --arg work_chain "$manifest_path" \
    --arg clean_session_command "$clean_command" \
    --arg review_meta "$review_meta_path" \
    --arg telemetry "$TELEMETRY_JSON" \
    --arg cleanup "$CLEANUP_JSON" \
    --arg execution_status "$EXECUTION_STATUS" \
    --argjson execute_after_plan "$EXECUTE_AFTER_PLAN" \
    --argjson execution_exit_code "$EXECUTION_EXIT_CODE" \
    --argjson execution_duration_s "$EXECUTION_DURATION_S" \
    --argjson execution_command "$EXECUTION_COMMAND_JSON" \
    --argjson blocked "$blocked_json" \
    --slurpfile issues "$issue_map" \
    --slurpfile parent "$PARENT_ISSUE_JSON" \
    --slurpfile project_fields "$PROJECT_FIELDS_JSON" \
    '{
      schema_version: 1,
      kind: "manager-plan-chain-result",
      created_at: $created_at,
      status: $status,
      automation_mode: $automation_mode,
      subject_ref: $subject_ref,
      source_ref: $source_ref,
      artifact_root: $artifact_root,
      planner_artifact: $planner_artifact,
      source_context: {
        comments_included: ($include_comments == 1),
        mode: (if $include_comments == 1 then "issue-context-packet" else "body-only" end),
        packet_path: (if $comment_packet == "" then null else $comment_packet end),
        comment_sidecar_path: (if $comment_sidecar == "" then null else $comment_sidecar end),
        body_only_explicit: ($include_comments != 1)
      },
      review_artifact: (if $review_artifact == "" then null else $review_artifact end),
      work_chain: (if $work_chain == "" then null else $work_chain end),
      blocked_decisions: $blocked,
      clean_session_command: (if $clean_session_command == "" then null else $clean_session_command end),
      created_issues: ($issues[0] // []),
      parent_issue: ($parent[0] // null),
      project_fields: ($project_fields[0] // null),
      review_meta: (if $review_meta == "" then null else $review_meta end),
      telemetry: $telemetry,
      cleanup: $cleanup,
      execution: {
        requested: ($execute_after_plan == 1),
        status: $execution_status,
        exit_code: $execution_exit_code,
        duration_s: $execution_duration_s,
        command: $execution_command
      }
    }' > "$RESULT_JSON"
}

print_result() {
  local status="$1" blocked_json="$2" review_path="$3" manifest_path="$4" clean_command="$5"
  printf '# Manager Plan-Chain Result\n\n'
  printf -- '- Status: `%s`\n' "$status"
  printf -- '- Planner artifact: `%s`\n' "$PLANNER_ARTIFACT"
  if [ "$INCLUDE_COMMENTS" -eq 1 ]; then
    printf -- '- Source context: `comments included` (packet `%s`, sidecar `%s`)\n' "$COMMENT_PACKET_MD" "$COMMENT_PACKET_JSON"
  else
    printf -- '- Source context: `body-only`\n'
  fi
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
  printf -- '- Automation mode: `%s`\n' "$AUTOMATION_MODE"
  if jq -e 'type == "object"' "$PARENT_ISSUE_JSON" >/dev/null 2>&1; then
    jq -r '"- Parent issue: `#\(.number)`"' "$PARENT_ISSUE_JSON"
  else
    printf -- '- Parent issue: `not created`\n'
  fi
  if [ "$POPULATE_PROJECT_FIELDS" -eq 1 ]; then
    printf -- '- Project fields: `%s` items in `%s`\n' "$(jq '.items | length' "$PROJECT_FIELDS_JSON")" "$PROJECT_FIELDS_JSON"
  else
    printf -- '- Project fields: `disabled`\n'
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
  printf -- '- Telemetry: `%s`\n' "$TELEMETRY_JSON"
  if [ "$EXECUTION_STATUS" != "not_requested" ]; then
    printf -- '- Execution: `%s` (exit `%s`, log `%s`)\n' "$EXECUTION_STATUS" "$EXECUTION_EXIT_CODE" "$EXECUTION_OUT"
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

source_from_comment_packet() {
  local packet_args=()
  COMMENT_PACKET_DIR="$ARTIFACT_ROOT/issue-context-packet"
  COMMENT_PACKET_MD="$COMMENT_PACKET_DIR/packet.md"
  COMMENT_PACKET_JSON="$COMMENT_PACKET_DIR/packet.json"
  packet_args=(--repo "$ISSUE_REPO" --out-dir "$COMMENT_PACKET_DIR")
  if [ -n "$ISSUE_SET" ]; then
    packet_args+=(--issue-set "$ISSUE_SET")
  else
    packet_args+=(--issue "$ISSUE_NUMBER")
  fi
  "$SCRIPT_DIR/issue-context-packet.sh" "${packet_args[@]}" > "$COMMENT_PACKET_DIR.run"
  [ -s "$COMMENT_PACKET_MD" ] || {
    printf 'manager-plan-chain: comment packet builder did not write %s\n' "$COMMENT_PACKET_MD" >&2
    exit 1
  }
  cp "$COMMENT_PACKET_MD" "$SOURCE_MD"
  if [ -z "$TITLE" ]; then
    TITLE=$(jq -r '.source_issue.title // "Issue Context Packet"' "$COMMENT_PACKET_JSON")
  fi
  {
    printf '# Comment-Aware Planning Source\n\n'
    jq -r '
      (if type == "array" then .[] else . end)
      | "## Issue #\(.number): \(.title // "Untitled")\n\n"
        + (.body // "_No issue body provided._")
        + "\n"
    ' "$COMMENT_PACKET_DIR/raw/issue.json"
    printf '\n## Edges and References\n\n'
    printf 'The issue-context packet below is public-safe planning context. Issue bodies remain the source of truth for worker scope; comments supply decisions, constraints, failures, acceptance changes, conflicts, and open questions with provenance.\n\n'
    sed -n '/^## Included Comment Range/,$p' "$COMMENT_PACKET_MD"
  } > "$SOURCE_MD"
}

source_from_issue_set_body_only() {
  local old_ifs issue_ref issue_json issue_url issue_state first_title
  : > "$SOURCE_MD"
  printf '# Issue Set\n\n' > "$SOURCE_MD"
  old_ifs=$IFS
  IFS=,
  for issue_ref in $ISSUE_SET; do
    IFS=$old_ifs
    issue_ref=$(printf '%s' "$issue_ref" | sed -E 's/^[[:space:]]*#?//; s/[[:space:]]*$//')
    case "$issue_ref" in
      *[!0-9]*|"") printf 'manager-plan-chain: --issue-set entries must be numeric issue refs: %s\n' "$issue_ref" >&2; exit 2 ;;
    esac
    issue_json=$("$SCRIPT_DIR/studio-gh.sh" issue view "$issue_ref" --repo "$ISSUE_REPO" --json number,title,body,url,state) || {
      printf 'manager-plan-chain: failed to read issue #%s from %s\n' "$issue_ref" "$ISSUE_REPO" >&2
      exit 1
    }
    [ -n "${first_title:-}" ] || first_title=$(printf '%s\n' "$issue_json" | jq -r '.title // ("Issue " + (.number | tostring))')
    issue_url=$(printf '%s\n' "$issue_json" | jq -r '.url // ""')
    issue_state=$(printf '%s\n' "$issue_json" | jq -r '.state // "unknown"')
    {
      printf '## Issue #%s: %s\n\n' "$issue_ref" "$(printf '%s\n' "$issue_json" | jq -r '.title // ""')"
      [ -z "$issue_url" ] || printf 'Source URL: %s\n' "$issue_url"
      printf 'Issue state: %s\n\n' "$issue_state"
      printf '%s\n\n' "$issue_json" | jq -r '.body // ""'
    } >> "$SOURCE_MD"
    IFS=,
  done
  IFS=$old_ifs
  [ -n "$TITLE" ] || TITLE="Issue cluster ${ISSUE_SET}"
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
    | (
        ($items | map({key: (.contract_id // ""), value: (.task_graph_node_id // "")}))
        + ($items | map({key: (.task_graph_node_id // ""), value: (.task_graph_node_id // "")}))
        | map(select(.key != "" and .value != ""))
        | from_entries
      ) as $id_map
    | def normalized_deps($item):
        [($item.dependencies // $item.depends_on // [])[]?
         | select(type == "string")
         | ($id_map[.] // .)];
      (
        $items
        | to_entries
        | map(
            .value as $item
            | (.value.task_graph_node_id // ("T-W" + ((.key + 1) | tostring))) as $id
            | normalized_deps($item) as $deps
            | {
                id: $id,
                kind: "task",
                source_id: (.value.contract_id // ("worker-contract:" + ((.key + 1) | tostring))),
                label: (.value.summary // .value.contract_id // "Worker contract"),
                dependencies: $deps,
                read_resources: [],
                write_resources: (.value.allowed_paths // []),
                status: (if ($deps | length) > 0 then "blocked" else "ready" end)
              }
          )
      ) as $nodes
    | ($nodes | map(.id)) as $node_ids
    | (
        [$nodes[] as $node
         | $node.dependencies[]?
         | select(($node_ids | index(.)) | not)
         | {node_id: $node.id, missing_source_id: .}]
      ) as $missing_dependencies
    | {
        schema_version: 1,
        kind: "task-graph",
        source: {
          title: (.subject_ref // .artifact_id // "planner-output"),
          source_label: (.artifact_id // "planner-output"),
          fingerprint_sha256: "",
          generator: {name:"manager-plan-chain", version:1}
        },
        nodes: $nodes,
        edges: (
          [$nodes[] as $node
           | $node.dependencies[]?
           | {from: ., to: $node.id, reason: "planner-output dependency"}]
        ),
        ready_node_ids: ($nodes | map(select((.dependencies // []) | length == 0) | .id)),
        validation: {
          status: (if (($items | length) > 0 and ($missing_dependencies | length) == 0) then "valid" else "invalid" end),
          missing_dependencies: $missing_dependencies,
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
    FROM_PLAN_JSON="$from_plan_json"
    FROM_PLAN_KIND="$plan_kind"
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
  local issue_bodies_dir idx contract_json node_id label title body_file create_out issue_number issue_url issue_id project_item_id sub_issue_linked tmp
  issue_bodies_dir="$ARTIFACT_ROOT/issue-bodies"
  mkdir -p "$issue_bodies_dir"
  printf '[]\n' > "$ISSUE_MAP"
  create_or_resolve_parent_issue
  verify_sub_issue_api_for_parent
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
      issue_id="$issue_number"
      project_item_id=""
      sub_issue_linked=false
    else
      create_out=$("$SCRIPT_DIR/studio-gh.sh" issue create --repo "$ISSUE_REPO" --title "$title" --body-file "$body_file") || {
        printf 'manager-plan-chain: failed to create issue for %s\n' "$node_id" >&2
        exit 1
      }
      issue_number=$(parse_issue_number_from_create_output "$create_out")
      issue_url=$(parse_issue_url_from_create_output "$create_out")
      case "$issue_number" in
        ''|*[!0-9]*)
          printf 'manager-plan-chain: could not parse issue number from create output: %s\n' "$create_out" >&2
          exit 1
          ;;
      esac
      [ -n "$issue_url" ] || issue_url=$(issue_url_for_number "$issue_number")
      issue_id=$(issue_database_id "$issue_number")
      project_item_id=$(add_issue_to_project_and_set_fields "$issue_number" "$issue_url" "worker")
      sub_issue_linked=$(link_sub_issue_to_parent "$issue_number" "$issue_id")
    fi
    tmp="$ISSUE_MAP.tmp"
    jq \
      --arg node_id "$node_id" \
      --arg title "$title" \
      --arg url "$issue_url" \
      --arg id "$issue_id" \
      --arg project_item_id "$project_item_id" \
      --argjson number "$issue_number" \
      --argjson sub_issue_linked "$sub_issue_linked" \
      '. + [{
        node_id:$node_id,
        number:$number,
        id:$id,
        title:$title,
        url:$url,
        project_item_id:$project_item_id,
        sub_issue_linked:$sub_issue_linked
      }]' \
      "$ISSUE_MAP" > "$tmp"
    mv "$tmp" "$ISSUE_MAP"
  done < <(jq -c '.payload.decomposition[]' "$PLANNER_ARTIFACT")
}

resolve_origin_base_sha() {
  local repo="$1" ref="$2" sha
  sha=$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" 2>/dev/null || true)
  if [ -z "$sha" ]; then
    sha=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$ref^{commit}" 2>/dev/null || true)
  fi
  printf '%s\n' "$sha"
}

resolve_base_sha_or_halt() {
  local resolved
  resolved=$(resolve_origin_base_sha "$TARGET_REPO_ROOT" "$SOURCE_BRANCH" || true)
  if [ -z "$resolved" ]; then
    BASE_SHA=""
    if [ -n "$BASE_SHA_EXPECTED" ]; then
      case "${STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT:-0}" in
        1|true|TRUE|yes|YES)
          printf 'manager-plan-chain: STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1 — proceeding without verifying origin/%s (expected %s)\n' \
            "$SOURCE_BRANCH" "$BASE_SHA_EXPECTED" >&2
          BASE_SHA="$BASE_SHA_EXPECTED"
          return 0
          ;;
      esac
      printf 'manager-plan-chain: base_branch_advanced: cannot resolve origin/%s in %s to verify expected base SHA %s; rerun after `git fetch origin %s` or set STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1\n' \
        "$SOURCE_BRANCH" "$TARGET_REPO_ROOT" "$BASE_SHA_EXPECTED" "$SOURCE_BRANCH" >&2
      exit 2
    fi
    return 0
  fi
  BASE_SHA="$resolved"
  if [ -n "$BASE_SHA_EXPECTED" ] && [ "$BASE_SHA" != "$BASE_SHA_EXPECTED" ]; then
    case "${STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT:-0}" in
      1|true|TRUE|yes|YES)
        printf 'manager-plan-chain: STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1 — accepting origin/%s drift (expected %s, got %s)\n' \
          "$SOURCE_BRANCH" "$BASE_SHA_EXPECTED" "$BASE_SHA" >&2
        return 0
        ;;
    esac
    printf 'manager-plan-chain: base_branch_advanced: origin/%s for chain %s changed since plan was reviewed: expected %s, got %s; rerun the planner or set STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1\n' \
      "$SOURCE_BRANCH" "$CHAIN_NAME" "$BASE_SHA_EXPECTED" "$BASE_SHA" >&2
    exit 2
  fi
}

validate_branch_discipline_inputs() {
  if [ "$INDEPENDENT" = "true" ]; then
    if [ -n "$PARENT_BRANCH" ] || [ -n "$PARENT_SHA" ]; then
      printf 'manager-plan-chain: manifest_branch_discipline_conflict: --independent cannot be combined with --parent-branch/--parent-sha\n' >&2
      exit 2
    fi
  fi
}

write_chain_manifest() {
  local manifest_json branch
  branch="feature/$CHAIN_NAME"
  manifest_json="$ARTIFACT_ROOT/work-chain.json"
  jq -n \
    --slurpfile graph "$TASK_GRAPH" \
    --slurpfile issues "$ISSUE_MAP" \
    --slurpfile parent "$PARENT_ISSUE_JSON" \
    --arg target_repo_root "$TARGET_REPO_ROOT" \
    --arg issue_repo "$ISSUE_REPO" \
    --arg chain_name "$CHAIN_NAME" \
    --arg source_branch "$SOURCE_BRANCH" \
    --arg base_sha "${BASE_SHA:-}" \
    --arg parent_branch "$PARENT_BRANCH" \
    --arg parent_sha "$PARENT_SHA" \
    --argjson independent "$INDEPENDENT" \
    --arg branch "$branch" \
    --arg host "$HOST" \
    --arg planner_artifact "$PLANNER_ARTIFACT" \
    --arg review_artifact "$REVIEW_ARTIFACT" \
    --argjson include_comments "$INCLUDE_COMMENTS" \
    --arg comment_packet "$COMMENT_PACKET_MD" \
    --arg comment_sidecar "$COMMENT_PACKET_JSON" \
    --arg generated_at "$(now_utc)" \
    '
      def issue_url_for_number($number):
        if $number == null then null else "https://github.com/" + $issue_repo + "/issues/" + ($number | tostring) end;
      def issue_number_from_url($url):
        ($url // "" | capture("/issues/(?<number>[0-9]+)")? | .number | tonumber?) // null;
      def empty_to_null($value):
        if ($value // "") == "" then null else $value end;
      def normalize_parent_issue($value):
        if $value == null then null
        elif ($value | type) == "object" then
          ($value.url // $value.html_url // $value.issue_url // null) as $url
          | ($value.number // $value.issue_number // issue_number_from_url($url)) as $number
          | if $number == null and $url == null then null else {
              number: $number,
              url: ($url // issue_url_for_number($number)),
              id: empty_to_null($value.id),
              project_item_id: empty_to_null($value.project_item_id),
              title: empty_to_null($value.title)
            } end
        elif ($value | type) == "string" then
          (issue_number_from_url($value)) as $number
          | if $number == null then null else {
              number: $number,
              url: $value,
              id: null,
              project_item_id: null,
              title: null
            } end
        else null
        end;
      def issue_number_for($id):
        ($issues[0][]? | select(.node_id == $id) | .number) // null;
      $graph[0] as $g
      | (normalize_parent_issue(
          [$parent[0], $g.parent_issue, $g.parent_issue_url, $g.source.parent_issue, $g.source.parent_issue_url]
          | map(select(. != null and . != ""))
          | .[0] // null
        )) as $parent_issue
      | ($g.nodes // [] | map(select(.kind == "task"))) as $tasks
      | {
          schema_version: 1,
          target_repo_root: $target_repo_root,
          issue_repo: $issue_repo,
          generated_by: {
            script: "scripts/manager-plan-chain.sh",
            generated_at: $generated_at,
            planner_artifact: $planner_artifact,
            review_artifact: $review_artifact,
            source_context: {
              comments_included: ($include_comments == 1),
              mode: (if $include_comments == 1 then "issue-context-packet" else "body-only" end),
              packet_path: (if $comment_packet == "" then null else $comment_packet end),
              comment_sidecar_path: (if $comment_sidecar == "" then null else $comment_sidecar end)
            }
          },
          chains: [
            ({
              name: $chain_name,
              base_ref: $source_branch,
              source_branch: $source_branch,
              independent: $independent,
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
            | (if $base_sha == "" then . else . + {base_sha:$base_sha} end)
            | (if $parent_branch == "" then . else . + {parent_branch:$parent_branch} end)
            | (if $parent_sha == "" then . else . + {parent_sha:$parent_sha} end)
            | (if $parent_issue == null then . else . + {parent_issue:$parent_issue} end))
          ]
        }
    ' > "$manifest_json"
  yq -P '.' "$manifest_json" > "$WORK_CHAIN"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_NUMBER="${2:?--issue requires a number}"; shift 2 ;;
    --issue=*) ISSUE_NUMBER="${1#--issue=}"; shift ;;
    --issue-set) ISSUE_SET="${2:?--issue-set requires a csv list}"; shift 2 ;;
    --issue-set=*) ISSUE_SET="${1#--issue-set=}"; shift ;;
    --include-comments) INCLUDE_COMMENTS=1; shift ;;
    --body-only) INCLUDE_COMMENTS=0; shift ;;
    --parent-issue) PARENT_ISSUE_NUMBER="${2:?--parent-issue requires a number}"; CREATE_PARENT_ISSUE=manual; shift 2 ;;
    --parent-issue=*) PARENT_ISSUE_NUMBER="${1#--parent-issue=}"; CREATE_PARENT_ISSUE=manual; shift ;;
    --no-parent-issue) CREATE_PARENT_ISSUE=0; PARENT_ISSUE_NUMBER=""; shift ;;
    --sub-issues) LINK_SUB_ISSUES=1; shift ;;
    --no-sub-issues) LINK_SUB_ISSUES=0; shift ;;
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
    --source-branch|--base|--base-ref) SOURCE_BRANCH="${2:?--source-branch requires a branch}"; shift 2 ;;
    --source-branch=*|--base=*|--base-ref=*) SOURCE_BRANCH="${1#*=}"; shift ;;
    --base-sha) BASE_SHA_EXPECTED="${2:?--base-sha requires a sha}"; shift 2 ;;
    --base-sha=*) BASE_SHA_EXPECTED="${1#--base-sha=}"; shift ;;
    --parent-branch) PARENT_BRANCH="${2:?--parent-branch requires a branch}"; shift 2 ;;
    --parent-branch=*) PARENT_BRANCH="${1#--parent-branch=}"; shift ;;
    --parent-sha) PARENT_SHA="${2:?--parent-sha requires a sha}"; shift 2 ;;
    --parent-sha=*) PARENT_SHA="${1#--parent-sha=}"; shift ;;
    --independent) INDEPENDENT="true"; shift ;;
    --no-independent) INDEPENDENT="false"; shift ;;
    --host) HOST="${2:?--host requires a host}"; shift 2 ;;
    --host=*) HOST="${1#--host=}"; shift ;;
    --review-host) REVIEW_HOST="${2:?--review-host requires a profile}"; shift 2 ;;
    --review-host=*) REVIEW_HOST="${1#--review-host=}"; shift ;;
    --execute|--run) EXECUTE_AFTER_PLAN=1; shift ;;
    --no-execute|--plan-only) EXECUTE_AFTER_PLAN=0; shift ;;
    --interactive|--attended) AUTOMATION_MODE="interactive"; shift ;;
    --unattended) AUTOMATION_MODE="unattended"; shift ;;
    --project-owner) PROJECT_OWNER="${2:?--project-owner requires owner}"; shift 2 ;;
    --project-owner=*) PROJECT_OWNER="${1#--project-owner=}"; shift ;;
    --project-number) PROJECT_NUMBER="${2:?--project-number requires number}"; shift 2 ;;
    --project-number=*) PROJECT_NUMBER="${1#--project-number=}"; shift ;;
    --project-status) PROJECT_STATUS="${2:?--project-status requires value}"; shift 2 ;;
    --project-status=*) PROJECT_STATUS="${1#--project-status=}"; shift ;;
    --project-track) PROJECT_TRACK="${2:?--project-track requires value}"; shift 2 ;;
    --project-track=*) PROJECT_TRACK="${1#--project-track=}"; shift ;;
    --project-phase) PROJECT_PHASE="${2:?--project-phase requires value}"; shift 2 ;;
    --project-phase=*) PROJECT_PHASE="${1#--project-phase=}"; shift ;;
    --project-size) PROJECT_SIZE="${2:?--project-size requires value}"; shift 2 ;;
    --project-size=*) PROJECT_SIZE="${1#--project-size=}"; shift ;;
    --project-review-state) PROJECT_REVIEW_STATE="${2:?--project-review-state requires value}"; shift 2 ;;
    --project-review-state=*) PROJECT_REVIEW_STATE="${1#--project-review-state=}"; shift ;;
    --project-fields) POPULATE_PROJECT_FIELDS=1; shift ;;
    --no-project-fields) POPULATE_PROJECT_FIELDS=0; shift ;;
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

case "$AUTOMATION_MODE" in
  unattended|interactive) ;;
  *) printf 'manager-plan-chain: automation mode must be unattended or interactive: %s\n' "$AUTOMATION_MODE" >&2; exit 2 ;;
esac
case "$INDEPENDENT" in
  true|false) ;;
  *) printf 'manager-plan-chain: --independent value must be true/false: %s\n' "$INDEPENDENT" >&2; exit 2 ;;
esac
case "$POPULATE_PROJECT_FIELDS" in
  0|1) ;;
  *) printf 'manager-plan-chain: project field mode must be 0 or 1: %s\n' "$POPULATE_PROJECT_FIELDS" >&2; exit 2 ;;
esac
case "$LINK_SUB_ISSUES" in
  0|1) ;;
  *) printf 'manager-plan-chain: sub-issue mode must be 0 or 1: %s\n' "$LINK_SUB_ISSUES" >&2; exit 2 ;;
esac
case "$INCLUDE_COMMENTS" in
  0|1) ;;
  *) printf 'manager-plan-chain: include-comments mode must be 0 or 1: %s\n' "$INCLUDE_COMMENTS" >&2; exit 2 ;;
esac
PARENT_ISSUE_NUMBER="${PARENT_ISSUE_NUMBER#\#}"
case "$PROJECT_NUMBER" in
  ''|*[!0-9]*) printf 'manager-plan-chain: --project-number must be numeric: %s\n' "$PROJECT_NUMBER" >&2; exit 2 ;;
esac
[ -z "$ISSUE_NUMBER" ] || [ -z "$ISSUE_SET" ] || {
  printf 'manager-plan-chain: --issue and --issue-set are mutually exclusive\n' >&2
  exit 2
}
[ "$INCLUDE_COMMENTS" -eq 0 ] || [ -n "$ISSUE_NUMBER" ] || [ -n "$ISSUE_SET" ] || {
  printf 'manager-plan-chain: --include-comments requires --issue or --issue-set\n' >&2
  exit 2
}

if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  if [ -z "$SOURCE_FILE" ] && [ -z "$ISSUE_NUMBER" ] && [ -z "$ISSUE_SET" ] && [ -z "$FROM_PLAN" ] && [ "${#POSITIONAL[@]}" -eq 1 ] && [ -r "${POSITIONAL[0]}" ]; then
    SOURCE_FILE="${POSITIONAL[0]}"
  elif [ -z "$SOURCE_FILE" ] && [ -z "$ISSUE_NUMBER" ] && [ -z "$ISSUE_SET" ] && [ -z "$FROM_PLAN" ] && [ "${#POSITIONAL[@]}" -eq 1 ] && [[ "${POSITIONAL[0]}" =~ ^#?[0-9]+$ ]]; then
    ISSUE_NUMBER="${POSITIONAL[0]#\#}"
  else
    SOURCE_TEXT="${POSITIONAL[*]}"
  fi
fi

# #823: inline refinement prompts that *reference* prior plan/review artifacts
# previously got synthesized as a single worker task with empty allowed_paths
# and stopped later as needs_context with no actionable instruction. Detect
# this class early — if the inline goal text contains readable file paths, the
# user almost certainly meant to feed those files as structured input. Fail
# fast with a clear redirect to --source-file / --from-plan instead of
# producing a bogus one-task decomposition.
#
# Bypass: STUDIO_PLAN_CHAIN_ALLOW_INLINE_PATHS=1 (for prompts that legitimately
# mention paths as prose, not as input artifacts).
if [ -z "$SOURCE_FILE" ] && [ -z "$ISSUE_NUMBER" ] && [ -z "$ISSUE_SET" ] && [ -z "$FROM_PLAN" ] && [ -n "$SOURCE_TEXT" ]; then
  case "${STUDIO_PLAN_CHAIN_ALLOW_INLINE_PATHS:-0}" in
    1|true|TRUE|yes|YES) ;;
    *)
      _inline_path_hits=""
      for _tok in $SOURCE_TEXT; do
        case "$_tok" in
          /*.md|/*.yaml|/*.yml|/*.json|/*.txt \
          |\~/*.md|\~/*.yaml|\~/*.yml|\~/*.json|\~/*.txt \
          |./*.md|./*.yaml|./*.yml|./*.json|./*.txt \
          |../*.md|../*.yaml|../*.yml|../*.json|../*.txt)
            _expanded="${_tok/#\~/$HOME}"
            if [ -r "$_expanded" ]; then
              _inline_path_hits="${_inline_path_hits}${_inline_path_hits:+ }$_tok"
            fi
            ;;
        esac
      done
      if [ -n "$_inline_path_hits" ]; then
        cat >&2 <<EOF
manager-plan-chain: inline goal text references readable file path(s):
  $_inline_path_hits

Inline prompts get synthesized as a single worker task with empty
allowed_paths and stop later as needs_context. If those paths are the
intended input, rerun with structured input:

  --source-file <path>     for a PRD / brief / refinement doc
  --from-plan <path>       for an existing planner / task-graph artifact
  --issue <n>              to load from a GitHub issue

If the path text is prose (not input), bypass with:
  STUDIO_PLAN_CHAIN_ALLOW_INLINE_PATHS=1
EOF
        exit 2
      fi
      unset _inline_path_hits _tok _expanded
      ;;
  esac
fi

TARGET_REPO_ROOT=${TARGET_REPO_ROOT:-$(git -C "${PWD:-$REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$REPO_ROOT")}
TARGET_REPO_ROOT=$(cd "$TARGET_REPO_ROOT" && pwd -P)
[ -n "$PROJECT" ] || PROJECT=$(basename "$TARGET_REPO_ROOT")
[ -n "$PROJECT" ] || PROJECT="generic-dev-studio"
ISSUE_REPO=$(resolve_issue_repo "$TARGET_REPO_ROOT")

if [ -n "$ISSUE_NUMBER" ]; then
  SUBJECT_REF="issue:$ISSUE_NUMBER"
  SOURCE_LABEL="$ISSUE_REPO#$ISSUE_NUMBER"
elif [ -n "$ISSUE_SET" ]; then
  SUBJECT_REF="issue-set:$(printf '%s' "$ISSUE_SET" | tr -d '[:space:]')"
  SOURCE_LABEL="$ISSUE_REPO#$(printf '%s' "$ISSUE_SET" | tr -d '[:space:]')"
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
    issue-set:*) TITLE="Issue set ${ISSUE_SET}" ;;
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
PLAN_CHAINS_ROOT="$project_root/plan-chains"
ARTIFACT_ROOT="$PLAN_CHAINS_ROOT/$run_id"
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
PARENT_ISSUE_JSON="$ARTIFACT_ROOT/parent-issue.json"
PROJECT_VIEW_JSON="$ARTIFACT_ROOT/project-view.json"
PROJECT_FIELDS_META="$ARTIFACT_ROOT/project-fields-meta.json"
PROJECT_FIELDS_JSON="$ARTIFACT_ROOT/project-fields.json"
CLEANUP_JSON="$ARTIFACT_ROOT/cleanup.json"
TELEMETRY_JSON="$ARTIFACT_ROOT/telemetry.json"
EXECUTION_OUT="$ARTIFACT_ROOT/work-chain-run.out"
EXECUTION_ERR="$ARTIFACT_ROOT/work-chain-run.err"
printf '[]\n' > "$ISSUE_MAP"
printf 'null\n' > "$PARENT_ISSUE_JSON"
printf '{"enabled":false,"items":[]}\n' > "$PROJECT_FIELDS_JSON"
printf '{"outcome":"not_run"}\n' > "$CLEANUP_JSON"

if [ "$INCLUDE_COMMENTS" -eq 1 ]; then
  source_from_comment_packet
elif [ -n "$ISSUE_NUMBER" ]; then
  source_from_issue
elif [ -n "$ISSUE_SET" ]; then
  source_from_issue_set_body_only
elif [ -n "$FROM_PLAN" ]; then
  printf '# From Plan\n\n- Source: `%s`\n' "$FROM_PLAN" > "$SOURCE_MD"
else
  source_from_file_or_text
fi

if [ -z "$PARENT_ISSUE_NUMBER" ] && [ -n "$ISSUE_NUMBER" ] && [ "$CREATE_PARENT_ISSUE" != "0" ]; then
  PARENT_ISSUE_NUMBER="$ISSUE_NUMBER"
  CREATE_PARENT_ISSUE=manual
fi
default_project_fields_from_source
init_project_fields_artifact
sweep_plan_chain_artifacts "$PLAN_CHAINS_ROOT"

prepare_task_graph

blocked_json=$(blocked_decisions_json)
graph_status=$(jq -r '.validation.status // "invalid"' "$TASK_GRAPH")
if [ "$graph_status" != "valid" ] || [ "$(printf '%s\n' "$blocked_json" | jq 'length')" -gt 0 ]; then
  write_review_input_placeholder="$REVIEW_INPUT"
  printf '# Manager Plan-Chain Needs Context\n\nTask graph validation blocked review and issue creation.\n' > "$write_review_input_placeholder"
  write_planner_artifact "needs_context" "$blocked_json"
  write_telemetry_artifact "needs_context"
  write_result_json "needs_context" "$blocked_json" "" "" "" "$ISSUE_MAP" ""
  print_result "needs_context" "$blocked_json" "" "" ""
  exit 0
fi

write_planner_artifact "ready_for_review" "$blocked_json"
write_review_input

if [ "$DRY_RUN" -eq 1 ]; then
  write_telemetry_artifact "dry_run"
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
  write_telemetry_artifact "blocked"
  write_result_json "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" "" "$ISSUE_MAP" "$REVIEW_META"
  print_result "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" ""
  exit 1
fi

review_verdict=$(sed -n 's/^PHASE_REVIEW_VERDICT=//p' "$REVIEW_META" | tail -1)
[ -n "$review_verdict" ] || review_verdict="ambiguous"
if ! review_allows_manifest "$review_verdict"; then
  blocked_json=$(jq -cn --arg verdict "$review_verdict" '["Plan review verdict was " + $verdict + "; rerun after addressing the review artifact."]')
  write_telemetry_artifact "blocked"
  write_result_json "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" "" "$ISSUE_MAP" "$REVIEW_META"
  print_result "blocked" "$blocked_json" "$REVIEW_ARTIFACT" "" ""
  exit 1
fi

validate_branch_discipline_inputs
resolve_base_sha_or_halt

prepare_project_field_metadata
create_worker_issues
write_chain_manifest

clean_command=$(clean_session_command_for_manifest)
result_status="ready"
execution_rc=0
if [ "$EXECUTE_AFTER_PLAN" -eq 1 ]; then
  set +e
  execute_work_chain
  execution_rc=$?
  set -e
  if [ "$execution_rc" -eq 0 ]; then
    result_status="executed"
  else
    result_status="execution_failed"
  fi
fi
write_telemetry_artifact "$result_status"
write_result_json "$result_status" "$blocked_json" "$REVIEW_ARTIFACT" "$WORK_CHAIN" "$clean_command" "$ISSUE_MAP" "$REVIEW_META"
print_result "$result_status" "$blocked_json" "$REVIEW_ARTIFACT" "$WORK_CHAIN" "$clean_command"
exit "$execution_rc"
