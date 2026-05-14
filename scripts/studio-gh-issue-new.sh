#!/usr/bin/env bash
# Create a studio issue and add it to the Studio v2 Project board.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=scripts/lib-project-board.sh
. "$SCRIPT_DIR/lib-project-board.sh"
# shellcheck source=scripts/lib-artifact-cleanup.sh
. "$SCRIPT_DIR/lib-artifact-cleanup.sh"

PROJECT_ARGS=()
ISSUE_ARGS=()
MODE=human
PROJECT_OWNER="${STUDIO_PROJECT_OWNER:-v-i-s-h-a-l}"
PROJECT_NUMBER="${STUDIO_PROJECT_NUMBER:-1}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/studio-gh-issue-new.sh [gh issue create options] [Project field options]

Project field options:
  --project-status VALUE
  --project-track VALUE
  --project-phase VALUE
  --project-size VALUE
  --project-review-state VALUE
  --project-owner VALUE
  --project-number N
  --json

All other options are passed to `scripts/studio-gh.sh issue create`.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-status) PROJECT_ARGS+=(--status "${2:?--project-status requires value}"); shift 2 ;;
    --project-track) PROJECT_ARGS+=(--track "${2:?--project-track requires value}"); shift 2 ;;
    --project-phase) PROJECT_ARGS+=(--phase "${2:?--project-phase requires value}"); shift 2 ;;
    --project-size) PROJECT_ARGS+=(--size "${2:?--project-size requires value}"); shift 2 ;;
    --project-review-state) PROJECT_ARGS+=(--review-state "${2:?--project-review-state requires value}"); shift 2 ;;
    --project-owner) PROJECT_OWNER="${2:?--project-owner requires value}"; PROJECT_ARGS+=(--owner "$PROJECT_OWNER"); shift 2 ;;
    --project-number) PROJECT_NUMBER="${2:?--project-number requires value}"; PROJECT_ARGS+=(--project-number "$PROJECT_NUMBER"); shift 2 ;;
    --json) MODE=json; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      ISSUE_ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ISSUE_ARGS[@]}" -gt 0 ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-gh-issue-new: jq required\n' >&2; exit 127; }

tmpdir=$(mktemp -d -t studio-gh-issue-new.XXXXXX); register_artifact tmpdir "$tmpdir"

"$SCRIPT_DIR/studio-gh.sh" project view "$PROJECT_NUMBER" \
  --owner "$PROJECT_OWNER" \
  --format json > "$tmpdir/project.json" || {
    printf 'studio-gh-issue-new: Project %s/%s is not readable; not creating issue\n' "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
    exit 1
  }
"$SCRIPT_DIR/studio-gh.sh" project field-list "$PROJECT_NUMBER" \
  --owner "$PROJECT_OWNER" \
  --limit 100 \
  --format json > "$tmpdir/fields.json" || {
    printf 'studio-gh-issue-new: Project %s/%s fields are not readable; not creating issue\n' "$PROJECT_OWNER" "$PROJECT_NUMBER" >&2
    exit 1
  }

issue_output=$("$SCRIPT_DIR/studio-gh.sh" issue create "${ISSUE_ARGS[@]}")
issue_url=$(printf '%s\n' "$issue_output" | awk '/^https:\/\/github.com\// { print; exit }')
[ -n "$issue_url" ] || {
  printf 'studio-gh-issue-new: could not parse issue URL from issue create output\n' >&2
  printf '%s\n' "$issue_output" >&2
  exit 1
}

if ! project_json=$("$SCRIPT_DIR/studio-project-add.sh" "$issue_url" --json "${PROJECT_ARGS[@]}"); then
  issue_number=$(project_board_issue_number_from_ref "$issue_url" || true)
  issue_repo=$(project_board_repo_slug_from_issue_url "$issue_url" || true)
  if [ -n "$issue_number" ] && [ -n "$issue_repo" ]; then
    if "$SCRIPT_DIR/studio-gh.sh" issue close "$issue_number" \
      --repo "$issue_repo" \
      --comment "Closing because Project board insertion failed during scripts/studio-gh-issue-new.sh; retry after fixing Project access." >/dev/null; then
      printf 'studio-gh-issue-new: closed %s after Project add failure\n' "$issue_url" >&2
    else
      printf 'studio-gh-issue-new: Project add failed and rollback close failed for %s\n' "$issue_url" >&2
    fi
  fi
  exit 1
fi

if [ "$MODE" = json ]; then
  jq -n \
    --arg issue_url "$issue_url" \
    --argjson project "$project_json" \
    '{issue_url: $issue_url, project: $project}'
else
  printf '%s\n' "$issue_url"
  printf 'Project: %s %s\n' \
    "$(printf '%s\n' "$project_json" | jq -r '.disposition')" \
    "$(printf '%s\n' "$project_json" | jq -r '.project_item_id')"
fi
