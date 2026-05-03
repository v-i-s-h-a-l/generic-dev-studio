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
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

OWNER="${STUDIO_PROJECT_OWNER:-v-i-s-h-a-l}"
PROJECT_NUMBER="${STUDIO_PROJECT_NUMBER:-1}"
LIMIT="${STUDIO_PROJECT_LIMIT:-200}"
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
