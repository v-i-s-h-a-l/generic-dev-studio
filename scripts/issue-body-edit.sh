#!/usr/bin/env bash

set -eu
umask 022

usage() {
  local rc="${1:-2}"
  cat >&2 <<'EOF'
usage: issue-body-edit.sh <issue> [--repo owner/repo] [--body-file path|-] [--min-bytes N] [--min-lines N] [--apply] [--bypass-body-guard]

Reads the replacement body from stdin by default and prints a target/size preview
to stderr. Without --apply, no GitHub mutation is attempted.

Guards:
  empty input is always refused
  bodies below --min-bytes or --min-lines are refused unless bypassed
  defaults: --min-bytes 50 --min-lines 3

Bypass:
  STUDIO_BYPASS_ISSUE_BODY_GUARD=1 or --bypass-body-guard bypasses the size
  thresholds for emergency/debug use. This bypass is user-controlled; assistants
  must not set it silently.
EOF
  exit "$rc"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

[ $# -ge 1 ] || usage

ISSUE=""
REPO=""
BODY_FILE="-"
MIN_BYTES="${STUDIO_ISSUE_BODY_MIN_BYTES:-50}"
MIN_LINES="${STUDIO_ISSUE_BODY_MIN_LINES:-3}"
APPLY=0
BYPASS=0

case "${STUDIO_BYPASS_ISSUE_BODY_GUARD:-0}" in
  1|true|TRUE|yes|YES) BYPASS=1 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?}"; shift 2 ;;
    --min-bytes) MIN_BYTES="${2:?}"; shift 2 ;;
    --min-lines) MIN_LINES="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --bypass-body-guard) BYPASS=1; shift ;;
    --help|-h) usage 0 ;;
    --*) printf 'issue-body-edit: unknown flag %s\n' "$1" >&2; usage ;;
    *)
      if [ -n "$ISSUE" ]; then
        printf 'issue-body-edit: unexpected argument %s\n' "$1" >&2
        usage
      fi
      ISSUE="$1"
      shift
      ;;
  esac
done

[ -n "$ISSUE" ] || usage
case "$MIN_BYTES" in
  ''|*[!0-9]*) printf 'issue-body-edit: --min-bytes must be a non-negative integer\n' >&2; exit 2 ;;
esac
case "$MIN_LINES" in
  ''|*[!0-9]*) printf 'issue-body-edit: --min-lines must be a non-negative integer\n' >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { printf 'issue-body-edit: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'issue-body-edit: jq is required\n' >&2; exit 1; }

TMPROOT=$(mktemp -d -t issue-body-edit.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT
NEW_BODY="$TMPROOT/new-body.md"

if [ "$BODY_FILE" = "-" ]; then
  cat > "$NEW_BODY"
else
  [ -f "$BODY_FILE" ] || { printf 'issue-body-edit: body file not found: %s\n' "$BODY_FILE" >&2; exit 1; }
  cp "$BODY_FILE" "$NEW_BODY"
fi

new_bytes=$(wc -c < "$NEW_BODY" | tr -d '[:space:]')
new_lines=$(awk 'END { print NR }' "$NEW_BODY")

if [ "$new_bytes" -eq 0 ]; then
  printf 'issue-body-edit: refusing to replace issue #%s with an empty body\n' "$ISSUE" >&2
  exit 1
fi

if [ "$BYPASS" -ne 1 ]; then
  if [ "$new_bytes" -lt "$MIN_BYTES" ] || [ "$new_lines" -lt "$MIN_LINES" ]; then
    printf 'issue-body-edit: refusing short generated body for issue #%s: new=%s bytes/%s lines, minimum=%s bytes/%s lines\n' \
      "$ISSUE" "$new_bytes" "$new_lines" "$MIN_BYTES" "$MIN_LINES" >&2
    printf 'issue-body-edit: user-controlled bypass: STUDIO_BYPASS_ISSUE_BODY_GUARD=1 or --bypass-body-guard\n' >&2
    exit 1
  fi
fi

repo_args=()
if [ -n "$REPO" ]; then
  repo_args=(--repo "$REPO")
fi

issue_json=$(with_login_home_for_github gh issue view "$ISSUE" "${repo_args[@]}" --json number,title,body,url) \
  || { printf 'issue-body-edit: failed to read issue %s\n' "$ISSUE" >&2; exit 1; }

issue_number=$(printf '%s' "$issue_json" | jq -r '.number')
issue_title=$(printf '%s' "$issue_json" | jq -r '.title')
issue_url=$(printf '%s' "$issue_json" | jq -r '.url')
old_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
old_bytes=$(printf '%s' "$old_body" | wc -c | tr -d '[:space:]')
old_lines=$(printf '%s' "$old_body" | awk 'END { print NR }')

printf 'issue-body-edit: target #%s %s\n' "$issue_number" "$issue_title" >&2
[ -n "$issue_url" ] && [ "$issue_url" != "null" ] && printf 'issue-body-edit: url %s\n' "$issue_url" >&2
printf 'issue-body-edit: old body %s bytes/%s lines; new body %s bytes/%s lines\n' \
  "$old_bytes" "$old_lines" "$new_bytes" "$new_lines" >&2
if [ "$BYPASS" -eq 1 ]; then
  printf 'issue-body-edit: STUDIO_BYPASS_ISSUE_BODY_GUARD active; size thresholds bypassed by user control\n' >&2
fi

if [ "$APPLY" -ne 1 ]; then
  printf 'issue-body-edit: dry run only; pass --apply to edit the issue body\n' >&2
  exit 0
fi

with_login_home_for_github gh issue edit "$ISSUE" "${repo_args[@]}" --body-file "$NEW_BODY"
