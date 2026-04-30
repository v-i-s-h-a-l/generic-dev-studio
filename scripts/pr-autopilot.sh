#!/usr/bin/env bash
# pr-autopilot.sh — post a reviewer gate verdict, then merge eligible PRs.
#
# Usage:
#   scripts/pr-autopilot.sh <pr> --verdict approved|approved_with_fixes|blocked \
#       [--review-host <host>] [--summary-file <path>] [--expected-head-sha <sha>] [--method auto|merge|squash|rebase]
#   scripts/pr-autopilot.sh <pr> --bypass-review --user-approved-bypass <url>
#
# The reviewer itself runs without GitHub/API tokens. This parent-side wrapper
# owns PR comments and merge actions through gh, leaving a machine-readable
# marker that pr-merge-finalize.sh requires before integration.

set -eu
umask 022

usage() {
  printf 'usage: pr-autopilot.sh <pr> --verdict approved|approved_with_fixes|blocked [--review-host <host>] [--summary-file <path>] [--expected-head-sha <sha>] [--method auto|merge|squash|rebase]\n' >&2
  printf '   or: pr-autopilot.sh <pr> --bypass-review --user-approved-bypass <url>\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift

VERDICT=""
REVIEW_HOST="${STUDIO_REVIEW_HOST:-codex-reviewer}"
SUMMARY_FILE=""
EXPECTED_HEAD_SHA=""
METHOD="auto"
BYPASS_REVIEW=0
USER_APPROVED_BYPASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verdict) VERDICT="${2:?}"; shift 2 ;;
    --review-host) REVIEW_HOST="${2:?}"; shift 2 ;;
    --summary-file) SUMMARY_FILE="${2:?}"; shift 2 ;;
    --expected-head-sha) EXPECTED_HEAD_SHA="${2:?}"; shift 2 ;;
    --method) METHOD="${2:?}"; shift 2 ;;
    --bypass-review) BYPASS_REVIEW=1; shift ;;
    --user-approved-bypass) USER_APPROVED_BYPASS="${2:?}"; shift 2 ;;
    *) printf 'pr-autopilot: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

STARTED_AT=$(date -u +%s)
PR_URL=""
HEAD_SHA=""

emit_pr_autopilot_event() {
  local event="$1" status="${2:-}" rc="${3:-0}" duration_s
  duration_s=$(( $(date -u +%s) - STARTED_AT ))
  data=$(printf '{"pr":"%s","pr_url":"%s","method":"%s","verdict":"%s","review_host":"%s","status":"%s","exit_code":%s,"duration_s":%s}' \
    "$(_json_escape "$PR")" \
    "$(_json_escape "$PR_URL")" \
    "$(_json_escape "$METHOD")" \
    "$(_json_escape "$VERDICT")" \
    "$(_json_escape "$REVIEW_HOST")" \
    "$(_json_escape "$status")" \
    "$rc" \
    "$duration_s")
  emit_event_keyed studio pr "$event" "$PR" "$data" \
    --idem-key "pr-autopilot:$event:$PR:$HEAD_SHA:$STARTED_AT" >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  local status="failed"
  if [ "$rc" -eq 0 ]; then
    status="completed"
  elif [ "$VERDICT" = "blocked" ]; then
    status="blocked"
  fi
  emit_pr_autopilot_event pr_autopilot_completed "$status" "$rc"
}
trap on_exit EXIT

command -v gh >/dev/null 2>&1 || { printf 'pr-autopilot: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'pr-autopilot: jq is required\n' >&2; exit 1; }

if [ "$BYPASS_REVIEW" -eq 1 ]; then
  [ -n "$USER_APPROVED_BYPASS" ] || {
    printf 'pr-autopilot: --bypass-review requires --user-approved-bypass <url>\n' >&2
    exit 1
  }
  "$SCRIPT_DIR/pr-merge-finalize.sh" "$PR" --method "$METHOD" --bypass-review --user-approved-bypass "$USER_APPROVED_BYPASS"
  exit $?
fi

case "$VERDICT" in
  approved|approved_with_fixes|blocked) ;;
  "") printf 'pr-autopilot: --verdict is required unless --bypass-review is used\n' >&2; exit 2 ;;
  *) printf 'pr-autopilot: verdict must be approved|approved_with_fixes|blocked\n' >&2; exit 2 ;;
esac

if ! "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST" >/dev/null; then
  printf 'pr-autopilot: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
  exit 1
fi

pr_json=$(gh pr view "$PR" --json headRefOid,url) \
  || { printf 'pr-autopilot: failed to read PR %s\n' "$PR" >&2; exit 1; }
HEAD_SHA=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
PR_URL=$(printf '%s' "$pr_json" | jq -r '.url')
emit_pr_autopilot_event pr_autopilot_started started 0
[ -z "$EXPECTED_HEAD_SHA" ] || [ "$HEAD_SHA" = "$EXPECTED_HEAD_SHA" ] || {
  printf 'pr-autopilot: refusing gate for PR %s; reviewed HEAD_SHA=%s but current HEAD_SHA=%s\n' "$PR" "$EXPECTED_HEAD_SHA" "$HEAD_SHA" >&2
  exit 1
}

summary="No reviewer summary file supplied."
if [ -n "$SUMMARY_FILE" ]; then
  [ -f "$SUMMARY_FILE" ] || { printf 'pr-autopilot: summary file not found: %s\n' "$SUMMARY_FILE" >&2; exit 1; }
  summary=$(sed -n '1,120p' "$SUMMARY_FILE")
fi

gh pr comment "$PR" --body "$(cat <<EOF
<!-- studio:pr-review-gate v1 -->
STUDIO_REVIEW_GATE=$VERDICT
REVIEW_HOST=$REVIEW_HOST
HEAD_SHA=$HEAD_SHA
PR_URL=$PR_URL
POSTED_BY=parent-studio-session

$summary
EOF
)"

if [ "$VERDICT" = "blocked" ]; then
  printf 'pr-autopilot: reviewer blocked PR %s; merge not attempted\n' "$PR" >&2
  exit 1
fi

"$SCRIPT_DIR/pr-merge-finalize.sh" "$PR" --method "$METHOD" --expected-head-sha "$HEAD_SHA"
