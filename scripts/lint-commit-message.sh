#!/usr/bin/env bash
# lint-commit-message.sh - validate commit trailers for studio-managed commits.
#
# Supported trailers:
#   Change-Type: <change-type>
#   Studio-Host: <host-id>
#
# Exit 0 on pass (or warnings with explicit env bypass), 1 on hard failures.

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT="${STUDIO_COMMIT_MSG_LINT_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

COMMIT_FILE=""
case "${1:-}" in
  --file) shift; COMMIT_FILE="${1:-}"; shift ;;
  --file=*) COMMIT_FILE="${1#--file=}"; shift ;;
  *) COMMIT_FILE="${1:-}" ;;
esac

if [ -z "$COMMIT_FILE" ] || [ ! -f "$COMMIT_FILE" ]; then
  printf 'lint-commit-message: --file <path> required and must be readable\n' >&2
  exit 2
fi

if [ "${STUDIO_BYPASS_COMMIT_TRAILER_LINT:-0}" = "1" ]; then
  printf 'commit trailer lint bypassed via STUDIO_BYPASS_COMMIT_TRAILER_LINT=1 (manual/emergency use only)\n'
  exit 0
fi

# Keep merge commits unopinionated by default to avoid unrelated breakage.
first_line=""
if [ -s "$COMMIT_FILE" ]; then
  # shellcheck disable=SC2162
  IFS= read -r first_line < "$COMMIT_FILE" || true
fi
case "$first_line" in
  Merge\ *) exit 0 ;;
esac

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

warns=0
errs=0
warn() { warns=$((warns + 1)); printf 'lint-commit-message: WARN: %s\n' "$1" >&2; }
fail() { errs=$((errs + 1)); printf 'lint-commit-message: ERROR: %s\n' "$1" >&2; }

change_type=""
studio_host=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    Change-Type:*) change_type=$(trim "${line#Change-Type:}") ;;
    Studio-Host:*) studio_host=$(trim "${line#Studio-Host:}") ;;
  esac
done < "$COMMIT_FILE"

valid_change_type() {
  case "$1" in
    feature|bugfix-shipped|bugfix-wip|regression-fix|refactor|docs|test|chore|release) return 0 ;;
    *) return 1 ;;
  esac
}

strict_for_hosted=0
known_host=""
start_host=""
if [ -f "$REPO_ROOT/.studio/chain-task-start.json" ] && command -v jq >/dev/null 2>&1; then
  start_host=$(jq -r '.ownership.host // empty' "$REPO_ROOT/.studio/chain-task-start.json" 2>/dev/null || true)
fi
if [ -n "$start_host" ] && [ "$start_host" != "null" ]; then
  strict_for_hosted=1
  known_host="$start_host"
elif [ -n "${STUDIO_HOST:-}" ] && [ "${STUDIO_HOST:-}" != "unknown" ]; then
  strict_for_hosted=1
  known_host="${STUDIO_HOST:-}"
fi

if [ -z "$change_type" ]; then
  if [ "$strict_for_hosted" -eq 1 ]; then
    fail "missing trailer Change-Type: feature|bugfix-shipped|bugfix-wip|regression-fix|refactor|docs|test|chore|release (fix: add Change-Type: <value> to the commit message)"
  else
    warn "missing trailer Change-Type: feature|bugfix-shipped|bugfix-wip|regression-fix|refactor|docs|test|chore|release (human commits are warned; add one for consistent release tooling)"
  fi
elif ! valid_change_type "$change_type"; then
  if [ "$strict_for_hosted" -eq 1 ]; then
    fail "invalid Change-Type trailer: ${change_type}. Valid values: feature, bugfix-shipped, bugfix-wip, regression-fix, refactor, docs, test, chore, release"
  else
    warn "invalid Change-Type trailer: ${change_type}. Valid values: feature, bugfix-shipped, bugfix-wip, regression-fix, refactor, docs, test, chore, release"
  fi
fi

if [ -z "$studio_host" ]; then
  if [ "$strict_for_hosted" -eq 1 ]; then
    fail "missing trailer Studio-Host: <host-id> (strict for host-authored automation; e.g., Studio-Host: ${known_host})"
  else
    warn "missing trailer Studio-Host: <host-id>. Add it for automation attribution (human-authored commits are warned)"
  fi
fi

if [ "$warns" -gt 0 ] && [ "$errs" -eq 0 ]; then
  warn "Co-authored-by is for human-visible credit and is not used for host attribution."
fi

if [ "$errs" -gt 0 ]; then
  printf 'commit message must include valid Change-Type and Studio-Host trailers\n' >&2
  printf 'To bypass only in emergency, set STUDIO_BYPASS_COMMIT_TRAILER_LINT=1\n' >&2
  exit 1
fi

if [ "$warns" -gt 0 ]; then
  printf 'lint-commit-message: passed with %s warning(s)\n' "$warns" >&2
fi

exit 0
