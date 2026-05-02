#!/usr/bin/env bash
# pr-autopilot.sh — post a reviewer gate verdict, then merge eligible PRs.
#
# Usage:
#   scripts/pr-autopilot.sh <pr> --verdict approved|approved_with_fixes|blocked \
#       [--review-host <host>] [--summary-file <path>] [--expected-head-sha <sha>] [--method auto|merge|squash|rebase]
#       [--parent-host <host>] [--eligible-review-hosts <csv>] [--cross-host true|false]
#   scripts/pr-autopilot.sh <pr> --bypass-review --user-approved-bypass <url>
#
# The reviewer itself runs without GitHub/API tokens. This parent-side wrapper
# owns PR comments and merge actions through gh, leaving a machine-readable
# marker that pr-merge-finalize.sh requires before integration.

set -eu
umask 022

usage() {
  printf 'usage: pr-autopilot.sh <pr> --verdict approved|approved_with_fixes|blocked [--review-host <host>] [--summary-file <path>] [--expected-head-sha <sha>] [--method auto|merge|squash|rebase] [--parent-host <host>] [--eligible-review-hosts <csv>] [--cross-host true|false]\n' >&2
  printf '   or: pr-autopilot.sh <pr> --bypass-review --user-approved-bypass <url>\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift

VERDICT=""
REVIEW_HOST="${STUDIO_REVIEW_HOST:-codex-reviewer}"
PARENT_HOST="${STUDIO_PARENT_HOST:-${STUDIO_HOST:-unknown}}"
ELIGIBLE_REVIEW_HOSTS=""
CROSS_HOST="false"
CROSS_HOST_REQUIRED="0"
FALLBACK_FROM=""
FALLBACK_FAILURES=""
CROSS_HOST_BYPASS_URL=""
REVIEWER_SMOKE_PASSED=0
SUMMARY_FILE=""
EXPECTED_HEAD_SHA=""
METHOD="auto"
BYPASS_REVIEW=0
USER_APPROVED_BYPASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verdict) VERDICT="${2:?}"; shift 2 ;;
    --review-host) REVIEW_HOST="${2:?}"; shift 2 ;;
    --parent-host) PARENT_HOST="${2:?}"; shift 2 ;;
    --eligible-review-hosts) ELIGIBLE_REVIEW_HOSTS="${2:?}"; shift 2 ;;
    --cross-host) CROSS_HOST="${2:?}"; shift 2 ;;
    --cross-host-required) CROSS_HOST_REQUIRED="${2:?}"; shift 2 ;;
    --fallback-from) FALLBACK_FROM="${2:?}"; shift 2 ;;
    --fallback-failures) FALLBACK_FAILURES="${2:?}"; shift 2 ;;
    --cross-host-bypass-url) CROSS_HOST_BYPASS_URL="${2:?}"; shift 2 ;;
    --reviewer-smoke-passed) REVIEWER_SMOKE_PASSED=1; shift ;;
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
  data=$(jq -cn \
    --arg pr "$PR" \
    --arg pr_url "$PR_URL" \
    --arg method "$METHOD" \
    --arg verdict "$VERDICT" \
    --arg review_host "$REVIEW_HOST" \
    --arg parent_host "$PARENT_HOST" \
    --arg eligible_hosts "$ELIGIBLE_REVIEW_HOSTS" \
    --arg cross_host "$CROSS_HOST" \
    --arg cross_host_required "$CROSS_HOST_REQUIRED" \
    --arg fallback_from "$FALLBACK_FROM" \
    --arg fallback_failures "$FALLBACK_FAILURES" \
    --arg cross_host_bypass_url "$CROSS_HOST_BYPASS_URL" \
    --arg status "$status" \
    --argjson exit_code "$rc" \
    --argjson duration_s "$duration_s" \
    '{pr:$pr,pr_url:$pr_url,method:$method,verdict:$verdict,review_host:$review_host,selected_review_host:$review_host,
      parent_host:$parent_host,
      eligible_review_hosts:($eligible_hosts | split(",") | map(select(length > 0))),
      cross_host:($cross_host == "true"),
      cross_host_required:($cross_host_required == "1" or $cross_host_required == "true" or $cross_host_required == "yes"),
      fallback_from:($fallback_from | split(",") | map(select(length > 0))),
      status:$status,exit_code:$exit_code,duration_s:$duration_s}
     + (if $fallback_failures == "" then {} else {fallback_failures:$fallback_failures} end)
     + (if $cross_host_bypass_url == "" then {} else {cross_host_bypass_url:$cross_host_bypass_url} end)')
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
case "$CROSS_HOST" in
  true|false) ;;
  *) printf 'pr-autopilot: --cross-host must be true|false\n' >&2; exit 2 ;;
esac
case "$CROSS_HOST_REQUIRED" in
  1|0|true|false|yes|no) ;;
  *) printf 'pr-autopilot: --cross-host-required must be 0|1|true|false\n' >&2; exit 2 ;;
esac
case "$CROSS_HOST_BYPASS_URL" in
  ""|https://github.com/*/issues/*|https://github.com/*/pull/*|https://github.com/*/discussions/*) ;;
  *) printf 'pr-autopilot: cross-host bypass must be a GitHub issue, PR, comment, or discussion URL\n' >&2; exit 2 ;;
esac

if [ "$REVIEWER_SMOKE_PASSED" -eq 1 ]; then
  if ! STUDIO_INTERNAL_REVIEWER_SKIP_SMOKE=1 "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST" >/dev/null; then
    printf 'pr-autopilot: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
    exit 1
  fi
elif ! "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST" >/dev/null; then
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
SELECTED_REVIEW_HOST=$REVIEW_HOST
PARENT_HOST=$PARENT_HOST
ELIGIBLE_REVIEW_HOSTS=$ELIGIBLE_REVIEW_HOSTS
CROSS_HOST=$CROSS_HOST
CROSS_HOST_REQUIRED=$CROSS_HOST_REQUIRED
FALLBACK_FROM=$FALLBACK_FROM
FALLBACK_FAILURES=$FALLBACK_FAILURES
CROSS_HOST_BYPASS_URL=$CROSS_HOST_BYPASS_URL
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
