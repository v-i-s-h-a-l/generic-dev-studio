#!/usr/bin/env bash
# Add a GitHub issue to the Studio v2 Project board and set planning fields.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=scripts/lib-project-board.sh
. "$SCRIPT_DIR/lib-project-board.sh"
# shellcheck source=scripts/lib-artifact-cleanup.sh
. "$SCRIPT_DIR/lib-artifact-cleanup.sh"

OWNER="${STUDIO_PROJECT_OWNER:-v-i-s-h-a-l}"
PROJECT_NUMBER="${STUDIO_PROJECT_NUMBER:-1}"
REPO_SLUG="${STUDIO_PROJECT_REPO:-}"
STATUS_FIELD=""
TRACK_FIELD=""
PHASE_FIELD=""
SIZE_FIELD=""
REVIEW_FIELD=""
MODE=human
ISSUE_REF=""

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/studio-project-add.sh <issue-number|issue-url> [field options]

Options:
  --repo owner/repo
  --owner user-or-org
  --project-number N
  --status "Todo|In Progress|Done"
  --track "B PM surface|..."
  --phase "B2|..."
  --size "XS|S|M|L|XL"
  --review-state "Not required|Plan clean|Outcome clean|Needs review"
  --json
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO_SLUG="${2:?--repo requires owner/repo}"; shift 2 ;;
    --owner) OWNER="${2:?--owner requires user or org}"; shift 2 ;;
    --project-number) PROJECT_NUMBER="${2:?--project-number requires number}"; shift 2 ;;
    --status) STATUS_FIELD="${2:?--status requires value}"; shift 2 ;;
    --track) TRACK_FIELD="${2:?--track requires value}"; shift 2 ;;
    --phase) PHASE_FIELD="${2:?--phase requires value}"; shift 2 ;;
    --size) SIZE_FIELD="${2:?--size requires value}"; shift 2 ;;
    --review-state) REVIEW_FIELD="${2:?--review-state requires value}"; shift 2 ;;
    --json) MODE=json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      printf 'studio-project-add: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$ISSUE_REF" ]; then
        printf 'studio-project-add: only one issue ref is supported\n' >&2
        exit 2
      fi
      ISSUE_REF="$1"
      shift
      ;;
  esac
done

[ -n "$ISSUE_REF" ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-project-add: jq required\n' >&2; exit 127; }

if [ -z "$REPO_SLUG" ]; then
  REPO_SLUG=$(project_board_repo_slug_from_issue_url "$ISSUE_REF" || true)
fi

if [ -z "$REPO_SLUG" ]; then
  REPO_SLUG=$(project_board_repo_slug_from_git) || {
    printf 'studio-project-add: could not resolve repo; pass --repo owner/repo\n' >&2
    exit 2
  }
fi

ISSUE_NUMBER=$(project_board_issue_number_from_ref "$ISSUE_REF") || {
  printf 'studio-project-add: unsupported issue ref: %s\n' "$ISSUE_REF" >&2
  exit 2
}
ISSUE_URL=$(project_board_issue_url "$REPO_SLUG" "$ISSUE_NUMBER")

tmpdir=$(mktemp -d -t studio-project-add.XXXXXX); register_artifact tmpdir "$tmpdir"

"$SCRIPT_DIR/studio-gh.sh" project view "$PROJECT_NUMBER" \
  --owner "$OWNER" \
  --format json > "$tmpdir/project.json" || {
    printf 'studio-project-add: failed to read Project %s/%s; Project write scope is required\n' "$OWNER" "$PROJECT_NUMBER" >&2
    exit 1
  }
PROJECT_ID=$(jq -r '.id // empty' "$tmpdir/project.json")
[ -n "$PROJECT_ID" ] || {
  printf 'studio-project-add: Project %s/%s did not expose an id\n' "$OWNER" "$PROJECT_NUMBER" >&2
  exit 1
}

"$SCRIPT_DIR/studio-gh.sh" project field-list "$PROJECT_NUMBER" \
  --owner "$OWNER" \
  --limit 100 \
  --format json > "$tmpdir/fields.json" || {
    printf 'studio-project-add: failed to read Project fields for %s/%s\n' "$OWNER" "$PROJECT_NUMBER" >&2
    exit 1
  }

ITEM_ID=$(project_board_existing_item_id "$REPO_SLUG" "$ISSUE_NUMBER" "$OWNER" "$PROJECT_NUMBER")
DISPOSITION=existing
if [ -z "$ITEM_ID" ]; then
  item_json=$("$SCRIPT_DIR/studio-gh.sh" project item-add "$PROJECT_NUMBER" \
    --owner "$OWNER" \
    --url "$ISSUE_URL" \
    --format json) || {
      printf 'studio-project-add: failed to add %s to Project %s/%s\n' "$ISSUE_URL" "$OWNER" "$PROJECT_NUMBER" >&2
      exit 1
    }
  ITEM_ID=$(printf '%s\n' "$item_json" | jq -r '.id // .item.id // empty')
  DISPOSITION=added
fi

[ -n "$ITEM_ID" ] || {
  printf 'studio-project-add: Project item id missing for %s\n' "$ISSUE_URL" >&2
  exit 1
}

if [ "$DISPOSITION" = added ]; then
  [ -n "$STATUS_FIELD" ] || STATUS_FIELD="Todo"
  [ -n "$REVIEW_FIELD" ] || REVIEW_FIELD="Not required"
  if [ -z "$TRACK_FIELD" ]; then
    labels_json=$(project_board_issue_labels_json "$REPO_SLUG" "$ISSUE_NUMBER")
    TRACK_FIELD=$(printf '%s\n' "$labels_json" | project_board_infer_track_from_labels)
  fi
fi

project_board_set_single_select "$PROJECT_ID" "$ITEM_ID" "$tmpdir/fields.json" "Status" "$STATUS_FIELD"
project_board_set_single_select "$PROJECT_ID" "$ITEM_ID" "$tmpdir/fields.json" "Track" "$TRACK_FIELD"
project_board_set_single_select "$PROJECT_ID" "$ITEM_ID" "$tmpdir/fields.json" "Phase" "$PHASE_FIELD"
project_board_set_single_select "$PROJECT_ID" "$ITEM_ID" "$tmpdir/fields.json" "Size" "$SIZE_FIELD"
project_board_set_single_select "$PROJECT_ID" "$ITEM_ID" "$tmpdir/fields.json" "Sibling host reviewed" "$REVIEW_FIELD"

result=$(
  jq -n \
    --arg issue_url "$ISSUE_URL" \
    --argjson issue_number "$ISSUE_NUMBER" \
    --arg item_id "$ITEM_ID" \
    --arg disposition "$DISPOSITION" \
    --arg status "$STATUS_FIELD" \
    --arg track "$TRACK_FIELD" \
    --arg phase "$PHASE_FIELD" \
    --arg size "$SIZE_FIELD" \
    --arg review "$REVIEW_FIELD" \
    '{
      issue_number: $issue_number,
      issue_url: $issue_url,
      project_item_id: $item_id,
      disposition: $disposition,
      fields: {
        Status: $status,
        Track: $track,
        Phase: $phase,
        Size: $size,
        "Sibling host reviewed": $review
      }
    }'
)

if [ "$MODE" = json ]; then
  printf '%s\n' "$result"
else
  printf 'studio-project-add: %s %s (%s)\n' "$DISPOSITION" "$ISSUE_URL" "$ITEM_ID"
fi
