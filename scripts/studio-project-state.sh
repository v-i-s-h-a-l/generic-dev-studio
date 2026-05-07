#!/usr/bin/env bash
# studio-project-state.sh — read the canonical GitHub Projects v2 backlog state.
#
# The studio's v2 PM surface lives on the "Studio v2 transition" Project board.
# This script gives agents a stable, field-aware reader so backlog flows do not
# reconstruct phase/track/review state from raw `gh issue list` output.
#
# Usage:
#   scripts/studio-project-state.sh
#   scripts/studio-project-state.sh --json
#   scripts/studio-project-state.sh --search "host-agnostic workers"
#   scripts/studio-project-state.sh --status "Todo"

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

OWNER="${STUDIO_PROJECT_OWNER:-v-i-s-h-a-l}"
PROJECT_NUMBER="${STUDIO_PROJECT_NUMBER:-1}"
LIMIT="${STUDIO_PROJECT_LIMIT:-200}"
FALLBACK_LIMIT="${STUDIO_PROJECT_SEARCH_FALLBACK_LIMIT:-20}"
REPO_SLUG="${STUDIO_PROJECT_REPO:-}"
MODE=human
QUERY=""
PROJECT_STATUS=""

usage() {
  sed -n '2,14p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) MODE=json; shift ;;
    --search) QUERY="${2:?usage: --search <keywords>}"; shift 2 ;;
    --status) PROJECT_STATUS="${2:?usage: --status <project-status>}"; shift 2 ;;
    --owner) OWNER="${2:?usage: --owner <owner>}"; shift 2 ;;
    --project-number) PROJECT_NUMBER="${2:?usage: --project-number <number>}"; shift 2 ;;
    --limit) LIMIT="${2:?usage: --limit <n>}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'studio-project-state: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || {
  printf 'studio-project-state: gh is required on PATH\n' >&2
  exit 127
}
command -v jq >/dev/null 2>&1 || {
  printf 'studio-project-state: jq is required on PATH\n' >&2
  exit 127
}

resolve_repo_slug() {
  if [ -n "$REPO_SLUG" ]; then
    printf '%s\n' "$REPO_SLUG"
    return 0
  fi

  local remote
  remote=$(git remote get-url origin 2>/dev/null || true)
  case "$remote" in
    git@github.com:*)
      remote=${remote#git@github.com:}
      remote=${remote%.git}
      ;;
    https://github.com/*)
      remote=${remote#https://github.com/}
      remote=${remote%.git}
      ;;
    *)
      printf 'studio-project-state: could not resolve GitHub repo slug from origin; set STUDIO_PROJECT_REPO=owner/repo\n' >&2
      return 2
      ;;
  esac
  printf '%s\n' "$remote"
}

search_terms() {
  printf '%s\n' "$QUERY" | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'length > 0'
}

graphql_project_item_for_issue() {
  local repo_slug="$1"
  local issue_number="$2"
  local repo_owner repo_name
  repo_owner=${repo_slug%%/*}
  repo_name=${repo_slug#*/}

  with_login_home_for_github gh api graphql \
    -f query='
      query($owner:String!,$repo:String!,$number:Int!){
        repository(owner:$owner,name:$repo){
          issue(number:$number){
            number
            title
            url
            repository { nameWithOwner url }
            labels(first:50){ nodes { name } }
            milestone { title }
            projectItems(first:50){
              nodes {
                type
                project {
                  number
                  owner {
                    ... on User { login }
                    ... on Organization { login }
                  }
                }
                fieldValues(first:50){
                  nodes {
                    ... on ProjectV2ItemFieldTextValue {
                      text
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                    ... on ProjectV2ItemFieldNumberValue {
                      number
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                    ... on ProjectV2ItemFieldDateValue {
                      date
                      field { ... on ProjectV2FieldCommon { name } }
                    }
                  }
                }
              }
            }
          }
        }
      }' \
    -f owner="$repo_owner" \
    -f repo="$repo_name" \
    -F number="$issue_number" |
    jq -c --arg owner "$OWNER" --argjson project_number "$PROJECT_NUMBER" '
      def field_value($name):
        [
          .fieldValues.nodes[]
          | select(.field.name == $name)
          | (.name // .text // (.number | tostring) // .date // empty)
        ][0] // "";
      .data.repository.issue as $issue
      | ($issue.projectItems.nodes // [])
      | map(select((.project.number == $project_number) and (.project.owner.login == $owner)))
      | .[0] as $project_item
      | if $issue == null or $project_item == null then empty else
          $project_item
          | {
              issue_number: $issue.number,
              title: ($issue.title // ""),
              url: ($issue.url // ""),
              repository: ($issue.repository.nameWithOwner // $issue.repository.url // ""),
              type: (.type // ""),
              status: field_value("Status"),
              track: field_value("Track"),
              phase: field_value("Phase"),
              size: field_value("Size"),
              sibling_host_reviewed: field_value("Sibling host reviewed"),
              labels: (($issue.labels.nodes // []) | map(.name)),
              milestone: ($issue.milestone.title // null)
            }
        end
    '
}

fallback_items_for_search() {
  [ -n "$QUERY" ] || { printf '[]\n'; return 0; }

  local repo_slug tmp_numbers tmp_items term
  repo_slug=$(resolve_repo_slug)
  tmp_numbers=$(mktemp -t studio-project-state-numbers.XXXXXX)
  tmp_items=$(mktemp -t studio-project-state-items.XXXXXX)
  trap 'rm -f "$tmp_numbers" "$tmp_items"' RETURN
  : > "$tmp_numbers"
  : > "$tmp_items"

  while IFS= read -r term; do
    if [[ "$term" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$term" >> "$tmp_numbers"
    else
      with_login_home_for_github gh issue list \
        --repo "$repo_slug" \
        --search "$term" \
        --limit "$FALLBACK_LIMIT" \
        --json number |
        jq -r '.[].number' >> "$tmp_numbers" || return $?
    fi
  done < <(search_terms)

  while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    graphql_project_item_for_issue "$repo_slug" "$issue_number" >> "$tmp_items" || return $?
  done < <(sort -nu "$tmp_numbers")

  jq -s '.' "$tmp_items"
}

raw_json=$(
  with_login_home_for_github gh project item-list "$PROJECT_NUMBER" \
    --owner "$OWNER" \
    --limit "$LIMIT" \
    --format json
) || exit $?

items_json=$(
  printf '%s\n' "$raw_json" | jq -c --arg q "$QUERY" --arg project_status "$PROJECT_STATUS" '
    def field($name): .[$name] // .[($name | ascii_downcase)] // "";
    def item:
      {
        issue_number: (.content.number // null),
        title: (.title // .content.title // ""),
        url: (.content.url // ""),
        repository: (.repository // .content.repository // ""),
        type: (.type // .content.type // ""),
        status: field("Status"),
        track: field("Track"),
        phase: field("Phase"),
        size: field("Size"),
        sibling_host_reviewed: field("Sibling host reviewed"),
        labels: (.labels // []),
        milestone: (.milestone.title // .milestone // null)
      };
    def haystack:
      [
        (.issue_number // "" | tostring),
        .title,
        .repository,
        .status,
        .track,
        .phase,
        .size,
        .sibling_host_reviewed,
        (.labels // [] | join(" ")),
        (.milestone // "")
      ] | join(" ") | ascii_downcase;
    [
      .items[]
      | item
      | select($project_status == "" or (.status | ascii_downcase) == ($project_status | ascii_downcase))
      | select($q == "" or (. as $item | any(($q | ascii_downcase | split("|") | map(select(length > 0)))[]; . as $term | ($item | haystack | contains($term)))))
    ]
  '
) || exit $?

fallback_json=$(fallback_items_for_search) || exit $?
items_json=$(
  jq -c --arg q "$QUERY" --arg project_status "$PROJECT_STATUS" -s '
    def haystack:
      [
        (.issue_number // "" | tostring),
        .title,
        .repository,
        .status,
        .track,
        .phase,
        .size,
        .sibling_host_reviewed,
        (.labels // [] | join(" ")),
        (.milestone // "")
      ] | join(" ") | ascii_downcase;
    (.[0] + .[1])
    | unique_by((.issue_number // .url // .title) | tostring)
    | [
        .[]
        | select($project_status == "" or (.status | ascii_downcase) == ($project_status | ascii_downcase))
        | select($q == "" or (. as $item | any(($q | ascii_downcase | split("|") | map(select(length > 0)))[]; . as $term | ($item | haystack | contains($term)))))
      ]
  ' <(printf '%s\n' "$items_json") <(printf '%s\n' "$fallback_json")
) || exit $?

if [ "$MODE" = json ]; then
  printf '%s\n' "$items_json"
  exit 0
fi

count=$(printf '%s\n' "$items_json" | jq 'length')
if [ "$count" -eq 0 ]; then
  if [ -n "$QUERY" ]; then
    printf 'studio-project-state: no Project items matched "%s".\n' "$QUERY"
  else
    printf 'studio-project-state: no Project items found.\n'
  fi
  exit 0
fi

printf '%s\n' "$items_json" | jq -r '
  .[]
  | "#\(.issue_number // "-") [\(.status // "No Status")] \(.title)"
    + " -- track=\((.track // "") | if . == "" then "-" else . end)"
    + " phase=\((.phase // "") | if . == "" then "-" else . end)"
    + " size=\((.size // "") | if . == "" then "-" else . end)"
    + " review=\((.sibling_host_reviewed // "") | if . == "" then "-" else . end)"
    + " \(.url)"
'
