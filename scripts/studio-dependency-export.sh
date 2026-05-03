#!/usr/bin/env bash
# Export native GitHub blocked_by issue dependencies as Mermaid.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

REPO=""
ISSUE=""

usage() {
  cat <<'EOF'
Usage:
  scripts/studio-dependency-export.sh --issue <number> [--repo owner/name]

Reads GitHub's native /issues/<n>/dependencies/blocked_by endpoint and emits a
Mermaid graph for human review. It does not parse issue bodies.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires owner/name}"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --issue) ISSUE="${2:?--issue requires number}"; shift 2 ;;
    --issue=*) ISSUE="${1#--issue=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

ISSUE="${ISSUE#\#}"
case "$ISSUE" in
  ''|*[!0-9]*) printf 'error: --issue must be an issue number\n' >&2; exit 2 ;;
esac

if [ -z "$REPO" ]; then
  remote=$(git config --get remote.origin.url 2>/dev/null || true)
  case "$remote" in
    git@github.com:*) REPO="${remote#git@github.com:}"; REPO="${REPO%.git}" ;;
    https://github.com/*) REPO="${remote#https://github.com/}"; REPO="${REPO%.git}" ;;
  esac
fi

case "$REPO" in
  */*) ;;
  *) printf 'error: --repo owner/name is required when origin is not a GitHub repo\n' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  printf 'error: jq is required\n' >&2
  exit 127
}
command -v gh >/dev/null 2>&1 || {
  printf 'error: gh is required\n' >&2
  exit 127
}

gh_api() {
  with_login_home_for_github gh api -H 'Accept: application/vnd.github+json' "$@"
}

root_json=$(gh_api "/repos/$REPO/issues/$ISSUE") || {
  printf 'error: failed to read issue #%s from %s\n' "$ISSUE" "$REPO" >&2
  exit 1
}

deps_json=$(gh_api "/repos/$REPO/issues/$ISSUE/dependencies/blocked_by") || {
  printf 'error: failed to read native dependencies for issue #%s\n' "$ISSUE" >&2
  exit 1
}

printf 'flowchart TD\n'

printf '%s\n' "$root_json" | jq -r '
  "  I\(.number)[\"#\(.number): \((.title // "") | gsub("\""; "\\\""))\"]"
'

printf '%s\n' "$deps_json" | jq -r '
  sort_by(.number)[] |
  "  I\(.number)[\"#\(.number): \((.title // "") | gsub("\""; "\\\""))\"]"
'

dep_count=$(printf '%s\n' "$deps_json" | jq 'length')
if [ "$dep_count" -eq 0 ]; then
  printf '  %% no native blocked_by dependencies found\n'
  exit 0
fi

printf '%s\n' "$deps_json" | jq -r --argjson issue "$ISSUE" '
  sort_by(.number)[] |
  "  I\($issue) -->|blocked by| I\(.number)"
'
