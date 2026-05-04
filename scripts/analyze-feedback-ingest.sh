#!/usr/bin/env bash
# analyze-feedback-ingest.sh — durable manager-analyze triage for studio feedback.
#
# Reads studio-feedback records from the generic-dev-studio feedback inbox,
# searches existing GitHub issues first, then either comments on an existing
# issue, creates one consolidated issue for related records, or leaves the
# record unprocessed with a policy reason. Apply mode moves records to
# processed/ only after a durable destination exists.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

REPO="v-i-s-h-a-l/generic-dev-studio"
INBOX_ROOT=""
ISSUES_FILE=""
APPLY=0
ACTIONS_FILE=""
EMIT_EVENTS=1
ANALYSIS_FILE=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/analyze-feedback-ingest.sh [--apply] [--inbox-root <dir>] [--issues-file <json>] [--repo owner/repo] [--actions-file <jsonl>] [--no-event]

Without --apply, prints the same JSON plan without moving files, creating
issues, commenting, appending analysis, or emitting events. --issues-file and
--actions-file make the workflow fixtureable without GitHub network access.
EOF
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'analyze-feedback-ingest: %s required\n' "$1" >&2
    exit 2
  }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --inbox-root) INBOX_ROOT="${2:?--inbox-root requires a value}"; shift 2 ;;
    --inbox-root=*) INBOX_ROOT="${1#--inbox-root=}"; shift ;;
    --issues-file) ISSUES_FILE="${2:?--issues-file requires a value}"; shift 2 ;;
    --issues-file=*) ISSUES_FILE="${1#--issues-file=}"; shift ;;
    --repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --actions-file) ACTIONS_FILE="${2:?--actions-file requires a value}"; shift 2 ;;
    --actions-file=*) ACTIONS_FILE="${1#--actions-file=}"; shift ;;
    --analysis-file) ANALYSIS_FILE="${2:?--analysis-file requires a value}"; shift 2 ;;
    --analysis-file=*) ANALYSIS_FILE="${1#--analysis-file=}"; shift ;;
    --no-event) EMIT_EVENTS=0; shift ;;
    -h|--help) usage ;;
    *) printf 'analyze-feedback-ingest: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

require_tool jq

if [ -z "$INBOX_ROOT" ]; then
  INBOX_ROOT=$(resolve_feedback_inbox_root)
fi

if [ -z "$ANALYSIS_FILE" ]; then
  ANALYSIS_FILE="$(resolve_analysis_root)/$(date -u +%Y-%m-%d).md"
fi

TMPDIR=$(mktemp -d -t analyze-feedback-ingest.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ISSUES_JSON="$TMPDIR/issues.json"
DEST_JSONL="$TMPDIR/destinations.jsonl"
POLICY_JSONL="$TMPDIR/policy.jsonl"
CLUSTERS_TSV="$TMPDIR/clusters.tsv"
touch "$DEST_JSONL" "$POLICY_JSONL" "$CLUSTERS_TSV"

if [ -n "$ACTIONS_FILE" ]; then
  : > "$ACTIONS_FILE"
fi

get_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 {
      if (match($0, "^[[:space:]]*" k "[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RLENGTH+1)
        sub(/[[:space:]]*$/, "", val)
        gsub(/^"|"$/, "", val)
        print val
        exit
      }
    }
  ' "$file"
}

get_title() {
  local file="$1" title
  title=$(awk '
    /^---[[:space:]]*$/ { n++; next }
    n>=2 && /^# / { sub(/^# /, ""); print; exit }
  ' "$file")
  [ -n "$title" ] || title=$(basename "$file" .md)
  printf '%s\n' "$title"
}

body_without_frontmatter() {
  awk '/^---[[:space:]]*$/ { n++; next } n>=2 { print }' "$1"
}

infer_scope() {
  local file="$1" kind="$2" explicit
  explicit=$(get_field "$file" scope)
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return
  fi
  [ -n "$kind" ] && printf 'generic-dev-studio\n'
}

kind_to_label() {
  case "$1" in
    bug|rule-miss) printf 'bug\n' ;;
    idea|rule-gap|friction|recurring-issue|studio) printf 'enhancement\n' ;;
    *) printf 'enhancement\n' ;;
  esac
}

normalize_text() {
  printf '%s\n' "$*" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/ /g' \
    | tr ' ' '\n' \
    | awk '
      length($0) >= 4 &&
      $0 !~ /^(about|after|also|from|have|into|only|should|that|this|when|with|work|workflow|issue|manager|analyze|feedback|record|records|studio|generic|candidate|candidates|public)$/ {
        seen[$0]=1
      }
      END {
        for (w in seen) print w
      }
    ' \
    | sort \
    | paste -sd ' ' -
}

cluster_key_for() {
  local file="$1" title="$2" body="$3" explicit tokens
  explicit=$(get_field "$file" cluster)
  [ -n "$explicit" ] || explicit=$(get_field "$file" dedupe_key)
  if [ -n "$explicit" ]; then
    normalize_text "$explicit"
    return
  fi
  tokens=$(normalize_text "$title" "$body")
  printf '%s\n' "$tokens" | awk '{ for (i=1; i<=NF && i<=6; i++) printf "%s%s", (i==1 ? "" : " "), $i }'
}

has_leaky_tokens() {
  local body="$1"
  printf '%s' "$body" | grep -qE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' && return 0
  printf '%s' "$body" | grep -qE '\bAKIA[0-9A-Z]{16}\b' && return 0
  printf '%s' "$body" | grep -qE '\bgh[pousr]_[A-Za-z0-9]{20,}\b' && return 0
  printf '%s' "$body" | grep -qE '\bxox[abpsr]-[0-9A-Za-z-]{10,}\b' && return 0
  printf '%s' "$body" | grep -qE '\bAIza[0-9A-Za-z_-]{35}\b' && return 0
  printf '%s' "$body" | grep -q -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' && return 0
  printf '%s' "$body" | grep -qE '\b[0-9a-f]{32,}\b' && return 0
  printf '%s' "$body" | grep -qE '(^|[[:space:]`"'"'"'])[A-Za-z0-9+=_-]{40,}([[:space:]`"'"'"']|$)' && return 0
  return 1
}

record_action() {
  [ -n "$ACTIONS_FILE" ] || return 0
  printf '%s\n' "$1" >> "$ACTIONS_FILE"
}

issue_number_from_url() {
  sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p' <<<"$1"
}

if [ -n "$ISSUES_FILE" ]; then
  cp "$ISSUES_FILE" "$ISSUES_JSON"
else
  "$SCRIPT_DIR/studio-gh.sh" issue list \
    --repo "$REPO" \
    --state open \
    --limit 200 \
    --json number,title,body,url,state > "$ISSUES_JSON"
fi

issues_tsv() {
  jq -r '.[] | [.number, (.url // ""), (.title // ""), (.body // "")] | @tsv' "$ISSUES_JSON"
}

score_issue() {
  local tokens="$1" title="$2" body="$3" issue_tokens score token
  issue_tokens=" $(normalize_text "$title" "$body") "
  score=0
  for token in $tokens; do
    case "$issue_tokens" in
      *" $token "*) score=$((score + 1)) ;;
    esac
  done
  printf '%s\n' "$score"
}

find_existing_issue() {
  local tokens="$1" best_score=0 best_number="" best_url="" number url title body score
  while IFS=$'\t' read -r number url title body; do
    [ -n "$number" ] || continue
    score=$(score_issue "$tokens" "$title" "$body")
    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_number="$number"
      best_url="$url"
    fi
  done < <(issues_tsv)

  if [ "$best_score" -ge 2 ]; then
    if [ -z "$best_url" ]; then
      best_url="https://github.com/$REPO/issues/$best_number"
    fi
    printf '%s\t%s\n' "$best_number" "$best_url"
  fi
}

build_public_body() {
  local file="$1" ts="$2" kind="$3" body
  body=$(body_without_frontmatter "$file")
  printf '%s\n\n---\n\nOriginated from a studio-feedback record on %s (kind: %s). Sanitized per CLAUDE.md privacy rules.\n' \
    "$body" "${ts:-unknown}" "$kind"
}

build_comment_body() {
  local file="$1" ts="$2" disposition="$3" body
  body=$(body_without_frontmatter "$file")
  printf 'Additional studio-feedback signal (%s, %s):\n\n%s\n' "${ts:-unknown}" "$disposition" "$body"
}

next_fixture_issue=9000

create_issue() {
  local title="$1" label="$2" body="$3" number url action
  if [ "$APPLY" -eq 0 ] || [ -n "$ACTIONS_FILE" ]; then
    next_fixture_issue=$((next_fixture_issue + 1))
    number="$next_fixture_issue"
    url="https://github.com/$REPO/issues/$number"
    if [ -n "$ACTIONS_FILE" ]; then
      action=$(jq -cn \
        --arg action create_issue \
        --arg title "$title" \
        --arg label "$label" \
        --arg url "$url" \
        --arg body "$body" \
        '{action:$action,title:$title,label:$label,url:$url,body:$body}')
      record_action "$action"
    fi
    printf '%s\t%s\n' "$number" "$url"
    return
  fi

  url=$(printf '%s' "$body" | "$SCRIPT_DIR/studio-gh.sh" issue create \
    --repo "$REPO" \
    --title "$title" \
    --label "$label" \
    --label "theme/internal" \
    --body-file -)
  number=$(issue_number_from_url "$url")
  [ -n "$number" ] || {
    printf 'analyze-feedback-ingest: could not parse issue number from %s\n' "$url" >&2
    return 1
  }
  printf '%s\t%s\n' "$number" "$url"
}

comment_issue() {
  local number="$1" body="$2" action
  if [ -n "$ACTIONS_FILE" ]; then
    action=$(jq -cn \
      --arg action comment_issue \
      --argjson issue_number "$number" \
      --arg body "$body" \
      '{action:$action,issue_number:$issue_number,body:$body}')
    record_action "$action"
    return
  fi
  printf '%s' "$body" | "$SCRIPT_DIR/studio-gh.sh" issue comment "$number" --repo "$REPO" --body-file - >/dev/null
}

append_private_analysis() {
  local file="$1" rel="$2"
  [ "$APPLY" -eq 1 ] || return 0
  mkdir -p "$(dirname "$ANALYSIS_FILE")"
  {
    printf '\n---\n'
    printf '## Ingested: %s\n\n' "$rel"
    cat "$file"
    printf '\n'
  } >> "$ANALYSIS_FILE"
}

move_processed() {
  local file="$1"
  [ "$APPLY" -eq 1 ] || return 0
  local dir fname
  dir=$(dirname "$file")
  fname=$(basename "$file")
  mkdir -p "$dir/processed"
  mv "$file" "$dir/processed/$fname"
}

emit_feedback_event() {
  local rel="$1" number="$2" url="$3" disposition="$4" reason="$5"
  [ "$APPLY" -eq 1 ] || return 0
  [ "$EMIT_EVENTS" -eq 1 ] || return 0
  local data
  data=$(jq -cn \
    --arg source_file "$rel" \
    --arg issue_url "$url" \
    --arg disposition "$disposition" \
    --arg policy_reason "$reason" \
    --argjson destination_issue "${number:-null}" \
    '{
      source_file: $source_file,
      destination_issue: $destination_issue,
      issue_url: (if $issue_url == "" then null else $issue_url end),
      disposition: $disposition,
      policy_reason: (if $policy_reason == "" then null else $policy_reason end)
    }')
  append_event chanakya feedback_ingested "" "$data" 2>/dev/null || true
}

record_destination() {
  local rel="$1" number="$2" url="$3" disposition="$4" moved="$5"
  jq -cn \
    --arg source_file "$rel" \
    --arg issue_url "$url" \
    --arg disposition "$disposition" \
    --arg moved "$moved" \
    --argjson issue_number "$number" \
    '{
      source_file: $source_file,
      destination_issue: $issue_number,
      issue_url: $issue_url,
      disposition: $disposition,
      moved_to_processed: ($moved == "true")
    }' >> "$DEST_JSONL"
}

record_policy_hold() {
  local rel="$1" reason="$2"
  jq -cn \
    --arg source_file "$rel" \
    --arg reason "$reason" \
    '{source_file:$source_file, disposition:"left_unprocessed", policy_reason:$reason}' >> "$POLICY_JSONL"
}

find_cluster_destination() {
  local key="$1"
  awk -F '\t' -v k="$key" '$1 == k { print $2 "\t" $3; exit }' "$CLUSTERS_TSV"
}

remember_cluster_destination() {
  local key="$1" number="$2" url="$3"
  printf '%s\t%s\t%s\n' "$key" "$number" "$url" >> "$CLUSTERS_TSV"
}

inbox_count_before=0
if [ -d "$INBOX_ROOT" ]; then
  inbox_count_before=$(find "$INBOX_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
    -not -path '*/processed/*' 2>/dev/null | wc -l | tr -d ' ')
fi

if [ -d "$INBOX_ROOT" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="${file#$INBOX_ROOT/}"
    kind=$(get_field "$file" kind)
    ts=$(get_field "$file" ts)
    title=$(get_title "$file")
    body=$(body_without_frontmatter "$file")
    scope=$(infer_scope "$file" "$kind")

    if [ "$scope" != "generic-dev-studio" ]; then
      record_policy_hold "$rel" "scope_not_public_studio"
      continue
    fi

    public_body=$(build_public_body "$file" "$ts" "$kind")
    if has_leaky_tokens "$public_body"; then
      record_policy_hold "$rel" "privacy_scrub_required"
      continue
    fi

    tokens=$(normalize_text "$title" "$body")
    cluster_key=$(cluster_key_for "$file" "$title" "$body")
    existing=$(find_existing_issue "$tokens" || true)

    if [ -n "$existing" ]; then
      issue_number=$(printf '%s\n' "$existing" | awk -F '\t' '{print $1}')
      issue_url=$(printf '%s\n' "$existing" | awk -F '\t' '{print $2}')
      comment=$(build_comment_body "$file" "$ts" "matched existing issue")
      if [ "$APPLY" -eq 1 ]; then
        comment_issue "$issue_number" "$comment"
      fi
      append_private_analysis "$file" "$rel"
      move_processed "$file"
      emit_feedback_event "$rel" "$issue_number" "$issue_url" "matched_existing_issue" ""
      record_destination "$rel" "$issue_number" "$issue_url" "matched_existing_issue" "$([ "$APPLY" -eq 1 ] && printf true || printf false)"
      remember_cluster_destination "$cluster_key" "$issue_number" "$issue_url"
      continue
    fi

    clustered=$(find_cluster_destination "$cluster_key" || true)
    if [ -n "$clustered" ]; then
      issue_number=$(printf '%s\n' "$clustered" | awk -F '\t' '{print $1}')
      issue_url=$(printf '%s\n' "$clustered" | awk -F '\t' '{print $2}')
      comment=$(build_comment_body "$file" "$ts" "consolidated with related feedback")
      if [ "$APPLY" -eq 1 ]; then
        comment_issue "$issue_number" "$comment"
      fi
      append_private_analysis "$file" "$rel"
      move_processed "$file"
      emit_feedback_event "$rel" "$issue_number" "$issue_url" "consolidated_with_related_feedback" ""
      record_destination "$rel" "$issue_number" "$issue_url" "consolidated_with_related_feedback" "$([ "$APPLY" -eq 1 ] && printf true || printf false)"
      continue
    fi

    label=$(kind_to_label "$kind")
    created=$(create_issue "$title" "$label" "$public_body")
    issue_number=$(printf '%s\n' "$created" | awk -F '\t' '{print $1}')
    issue_url=$(printf '%s\n' "$created" | awk -F '\t' '{print $2}')
    append_private_analysis "$file" "$rel"
    move_processed "$file"
    emit_feedback_event "$rel" "$issue_number" "$issue_url" "created_issue" ""
    record_destination "$rel" "$issue_number" "$issue_url" "created_issue" "$([ "$APPLY" -eq 1 ] && printf true || printf false)"
    remember_cluster_destination "$cluster_key" "$issue_number" "$issue_url"
  done < <(find "$INBOX_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
    -not -path '*/processed/*' 2>/dev/null | sort)
fi

inbox_count_after=0
if [ -d "$INBOX_ROOT" ]; then
  inbox_count_after=$(find "$INBOX_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
    -not -path '*/processed/*' 2>/dev/null | wc -l | tr -d ' ')
fi

jq -n \
  --arg repo "$REPO" \
  --arg inbox_root "$INBOX_ROOT" \
  --arg mode "$([ "$APPLY" -eq 1 ] && printf apply || printf dry-run)" \
  --argjson before "$inbox_count_before" \
  --argjson after "$inbox_count_after" \
  --slurpfile destinations "$DEST_JSONL" \
  --slurpfile policy_holds "$POLICY_JSONL" \
  '{
    schema_version: 1,
    kind: "manager_analyze_feedback_ingest",
    mode: $mode,
    repo: $repo,
    inbox_root: $inbox_root,
    inbox_count_before: $before,
    inbox_count_after: $after,
    destination_count: ($destinations | length),
    destinations: $destinations,
    policy_holds: $policy_holds
  }'
