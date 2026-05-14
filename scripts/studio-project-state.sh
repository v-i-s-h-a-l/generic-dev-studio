#!/usr/bin/env bash
# studio-project-state.sh — read the per-project GitHub Projects v2 backlog state.
#
# Each studio-managed project owns its own Projects v2 board. This script
# discovers the right board through the per-project portability contract in
# PM-SURFACE.md §Per-Project Project Board Portability Contract and
# _shared/contracts/studio-context.md §Project Board Resolution.
#
# Discovery order (first match wins):
#   1. --project-board <owner_kind>:<owner_login>:<n>  (or legacy
#      --owner + --project-number)
#   2. STUDIO_PROJECT_BOARD_OVERRIDE env (or legacy STUDIO_PROJECT_OWNER /
#      STUDIO_PROJECT_NUMBER env)
#   3. Runtime override at <studio_home>/<project_slug>/config/project-board.yaml
#   4. Durable repo file at profiles/<project_slug>/project-board.yaml
#   5. Loud failure naming the missing config and project slug
#
# Usage:
#   scripts/studio-project-state.sh
#   scripts/studio-project-state.sh --json
#   scripts/studio-project-state.sh --search "host-agnostic workers"
#   scripts/studio-project-state.sh --status "Todo"
#   scripts/studio-project-state.sh --project-board user:v-i-s-h-a-l:1
#   scripts/studio-project-state.sh --owner v-i-s-h-a-l --project-number 1

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"

LIMIT="${STUDIO_PROJECT_LIMIT:-200}"
FALLBACK_LIMIT="${STUDIO_PROJECT_SEARCH_FALLBACK_LIMIT:-20}"
REPO_SLUG="${STUDIO_PROJECT_REPO:-}"
MODE=human
QUERY=""
PROJECT_STATUS=""
CLI_OWNER=""
CLI_PROJECT_NUMBER=""
CLI_PROJECT_BOARD=""

usage() {
  sed -n '2,25p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) MODE=json; shift ;;
    --search) QUERY="${2:?usage: --search <keywords>}"; shift 2 ;;
    --status) PROJECT_STATUS="${2:?usage: --status <project-status>}"; shift 2 ;;
    --owner) CLI_OWNER="${2:?usage: --owner <owner>}"; shift 2 ;;
    --project-number) CLI_PROJECT_NUMBER="${2:?usage: --project-number <number>}"; shift 2 ;;
    --project-board) CLI_PROJECT_BOARD="${2:?usage: --project-board <owner_kind>:<owner_login>:<n>}"; shift 2 ;;
    --limit) LIMIT="${2:?usage: --limit <n>}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'studio-project-state: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

resolve_project_board() {
  # 1. CLI flag — --project-board wins over --owner / --project-number.
  if [ -n "$CLI_PROJECT_BOARD" ]; then
    STUDIO_CONTEXT_PROJECT_BOARD="$CLI_PROJECT_BOARD"
  elif [ -n "$CLI_OWNER" ] && [ -n "$CLI_PROJECT_NUMBER" ]; then
    STUDIO_CONTEXT_PROJECT_BOARD="user:$CLI_OWNER:$CLI_PROJECT_NUMBER"
  elif [ -n "$CLI_OWNER" ] || [ -n "$CLI_PROJECT_NUMBER" ]; then
    printf 'studio-project-state: --owner and --project-number must be used together (or pass --project-board)\n' >&2
    exit 2
  fi

  # 2. Legacy env override — preserved so existing STUDIO_PROJECT_OWNER /
  # STUDIO_PROJECT_NUMBER consumers keep working until they migrate to
  # STUDIO_PROJECT_BOARD_OVERRIDE. The new env is checked inside the
  # context resolver as step 2; the legacy env is treated as a
  # peer step-2 source synthesized into the same canonical token.
  if [ -z "${STUDIO_CONTEXT_PROJECT_BOARD:-}" ] \
      && [ -z "${STUDIO_PROJECT_BOARD_OVERRIDE:-}" ] \
      && [ -n "${STUDIO_PROJECT_OWNER:-}" ] \
      && [ -n "${STUDIO_PROJECT_NUMBER:-}" ]; then
    STUDIO_CONTEXT_PROJECT_BOARD="user:$STUDIO_PROJECT_OWNER:$STUDIO_PROJECT_NUMBER"
  fi

  # Resolve once with the discovery chain; the validator loud-fails for
  # pm-surface when project_board is empty.
  if studio_context_resolve pm-surface; then
    return 0
  fi

  # Transitional fallback: the studio's own board is the seed instance of
  # the portability contract, but profiles/generic-dev-studio/project-board.yaml
  # is not yet seeded (T-R003 territory). Synthesize the legacy default for
  # the studio slug only, with a one-line deprecation notice, so existing
  # usage in generic-dev-studio keeps working. Any other project_slug must
  # configure a board explicitly — the contract's loud-failure stands.
  local project_slug_now
  project_slug_now=$(_studio_context_project_slug "$(_studio_context_repo_root)")
  if [ "$project_slug_now" = "generic-dev-studio" ]; then
    printf 'studio-project-state: no project-board config found for generic-dev-studio; using transitional default user:v-i-s-h-a-l:1 (seed profiles/generic-dev-studio/project-board.yaml to make this explicit)\n' >&2
    STUDIO_CONTEXT_PROJECT_BOARD="user:v-i-s-h-a-l:1"
    # shellcheck disable=SC2034
    STUDIO_CONTEXT_PROJECT_BOARD_SOURCE="transitional_default"
    studio_context_resolve pm-surface || exit 1
    return 0
  fi
  exit 1
}

resolve_project_board

OWNER=$(printf '%s\n' "$STUDIO_CONTEXT_PROJECT_BOARD" | awk -F: '{print $2}')
PROJECT_NUMBER=$(printf '%s\n' "$STUDIO_CONTEXT_PROJECT_BOARD" | awk -F: '{print $3}')

if [ -z "$OWNER" ] || [ -z "$PROJECT_NUMBER" ]; then
  printf 'studio-project-state: failed to parse resolved project_board token: %s\n' \
    "$STUDIO_CONTEXT_PROJECT_BOARD" >&2
  exit 1
fi

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
