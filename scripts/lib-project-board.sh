#!/usr/bin/env bash
# Shared helpers for Studio GitHub Projects v2 reads/writes.

project_board_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

PROJECT_BOARD_SCRIPT_DIR="${PROJECT_BOARD_SCRIPT_DIR:-$(project_board_script_dir)}"

project_board_repo_slug_from_git() {
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
      return 1
      ;;
  esac
  printf '%s\n' "$remote"
}

project_board_issue_number_from_ref() {
  local ref="$1"
  case "$ref" in
    *github.com/*/issues/[0-9]*)
      ref=${ref##*/issues/}
      ref=${ref%%[^0-9]*}
      ;;
    \#*)
      ref=${ref#\#}
      ;;
  esac
  case "$ref" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$ref" ;;
  esac
}

project_board_repo_slug_from_issue_url() {
  local ref="$1" slug
  case "$ref" in
    https://github.com/*/*/issues/[0-9]*)
      slug=${ref#https://github.com/}
      slug=${slug%/issues/*}
      printf '%s\n' "$slug"
      return 0
      ;;
  esac
  return 1
}

project_board_issue_url() {
  local repo_slug="$1" issue_number="$2"
  printf 'https://github.com/%s/issues/%s\n' "$repo_slug" "$issue_number"
}

project_board_issue_labels_json() {
  local repo_slug="$1" issue_number="$2"
  "$PROJECT_BOARD_SCRIPT_DIR/studio-gh.sh" issue view "$issue_number" \
    --repo "$repo_slug" \
    --json labels |
    jq -c '[.labels[].name]'
}

project_board_infer_track_from_labels() {
  jq -r '
    def mapped:
      if . == "track:pm-surface" then "B PM surface"
      elif . == "track:apollo" then "v1 apollo"
      elif . == "track:forge-safety" then "v1 forge-safety"
      else empty
      end;
    [ .[] | mapped ] | unique
    | if length == 1 then .[0] else "" end
  '
}

project_board_field_id() {
  local fields_file="$1" field_name="$2"
  jq -r --arg field "$field_name" '
    (.fields // .)[]?
    | select(.name == $field)
    | .id
  ' "$fields_file" | head -1
}

project_board_field_option_id() {
  local fields_file="$1" field_name="$2" value="$3"
  jq -r --arg field "$field_name" --arg value "$value" '
    (.fields // .)[]?
    | select(.name == $field)
    | (.options // [])[]?
    | select(.name == $value)
    | .id
  ' "$fields_file" | head -1
}

project_board_existing_item_id() {
  local repo_slug="$1" issue_number="$2" project_owner="$3" project_number="$4"
  local repo_owner repo_name
  repo_owner=${repo_slug%%/*}
  repo_name=${repo_slug#*/}

  "$PROJECT_BOARD_SCRIPT_DIR/studio-gh.sh" api graphql \
    -f query='
      query($owner:String!,$repo:String!,$number:Int!){
        repository(owner:$owner,name:$repo){
          issue(number:$number){
            projectItems(first:50){
              nodes {
                id
                project {
                  number
                  owner {
                    ... on User { login }
                    ... on Organization { login }
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
    jq -r --arg owner "$project_owner" --argjson project_number "$project_number" '
      .data.repository.issue.projectItems.nodes[]?
      | select((.project.number == $project_number) and (.project.owner.login == $owner))
      | .id
    ' | head -1
}

project_board_set_single_select() {
  local project_id="$1" item_id="$2" fields_file="$3" field_name="$4" value="$5"
  local field_id option_id
  [ -n "$value" ] || return 0
  field_id=$(project_board_field_id "$fields_file" "$field_name")
  option_id=$(project_board_field_option_id "$fields_file" "$field_name" "$value")
  [ -n "$field_id" ] || {
    printf 'project-board: Project field not found: %s\n' "$field_name" >&2
    return 1
  }
  [ -n "$option_id" ] || {
    printf 'project-board: Project field %s has no option %s\n' "$field_name" "$value" >&2
    return 1
  }
  "$PROJECT_BOARD_SCRIPT_DIR/studio-gh.sh" project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$field_id" \
    --single-select-option-id "$option_id" \
    --format json >/dev/null
}
