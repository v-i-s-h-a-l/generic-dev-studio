#!/usr/bin/env bash
# lint-commit-message.sh - validate commit trailers for studio-managed commits.
#
# Supported compact fields:
#   <change-type>: <developer headline>
#   Impact: <net behavior/workflow change>
#   Areas: <module/surface list>
#   Release-Note: <tester/release-facing bullet source, or none>
#   Why: <cause, trigger, or intent>
#   Risk: <none|low|medium|high> <short reason>
#   Details: <optional deeper implementation notes>
#   Change-Type: <change-type>
#   Studio-Host: <host-id>
#   Co-authored-by: Codex <noreply@openai.com>
#
# Legacy verbose fields remain accepted during the producer migration:
#   Affected-Areas: <module/surface list>
#   Problem: <why this was needed>
#   Solution: <what changed>
#   Changelog: <tester/release-facing bullet source>
#   Implementation notes: <automation/reviewer details>
#   Caveats: <risks, limits, skipped verification, or None>
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
impact=""
areas=""
release_note=""
why=""
risk=""
affected_areas=""
problem=""
solution=""
changelog=""
implementation_notes=""
caveats=""
coauthored_by_seen=0
codex_coauthor_seen=0
bad_codex_coauthor=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    Impact:*) impact=$(trim "${line#Impact:}") ;;
    Areas:*) areas=$(trim "${line#Areas:}") ;;
    Release-Note:*) release_note=$(trim "${line#Release-Note:}") ;;
    Why:*) why=$(trim "${line#Why:}") ;;
    Risk:*) risk=$(trim "${line#Risk:}") ;;
    Problem:*) problem=$(trim "${line#Problem:}") ;;
    Affected-Areas:*) affected_areas=$(trim "${line#Affected-Areas:}") ;;
    Solution:*) solution=$(trim "${line#Solution:}") ;;
    Changelog:*) changelog=$(trim "${line#Changelog:}") ;;
    Implementation\ notes:*) implementation_notes=$(trim "${line#Implementation notes:}") ;;
    Caveats:*) caveats=$(trim "${line#Caveats:}") ;;
    Change-Type:*) change_type=$(trim "${line#Change-Type:}") ;;
    Studio-Host:*) studio_host=$(trim "${line#Studio-Host:}") ;;
    Co-authored-by:*)
      coauthored_by_seen=1
      coauthor=$(trim "${line#Co-authored-by:}")
      case "$coauthor" in
        "Codex <noreply@openai.com>") codex_coauthor_seen=1 ;;
        "Codex <"*) bad_codex_coauthor="$coauthor" ;;
      esac
      ;;
  esac
done < "$COMMIT_FILE"

compact_missing_labels() {
  local labels=""
  [ -n "$impact" ] || labels="${labels} Impact"
  [ -n "$areas" ] || labels="${labels} Areas"
  [ -n "$release_note" ] || labels="${labels} Release-Note"
  [ -n "$why" ] || labels="${labels} Why"
  [ -n "$risk" ] || labels="${labels} Risk"
  printf '%s' "${labels# }"
}

verbose_missing_labels() {
  local labels=""
  [ -n "$affected_areas" ] || labels="${labels} Affected-Areas"
  [ -n "$problem" ] || labels="${labels} Problem"
  [ -n "$solution" ] || labels="${labels} Solution"
  [ -n "$changelog" ] || labels="${labels} Changelog"
  [ -n "$implementation_notes" ] || labels="${labels} Implementation notes"
  [ -n "$caveats" ] || labels="${labels} Caveats"
  printf '%s' "${labels# }"
}

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

if [ -n "$change_type" ] && valid_change_type "$change_type"; then
  case "$first_line" in
    "$change_type":\ ?*) ;;
    *)
      if [ "$strict_for_hosted" -eq 1 ]; then
        fail "commit subject must start with '${change_type}: ' followed by a developer-readable why/what headline"
      else
        warn "commit subject should start with '${change_type}: ' followed by a developer-readable why/what headline"
      fi
      ;;
  esac
fi

risk_value=""
if [ -n "$risk" ]; then
  risk_value="${risk%%[[:space:]:,-]*}"
  risk_prefix_valid=0
  case "$risk_value" in
    none|low|medium|high) risk_prefix_valid=1 ;;
    *)
      if [ "$strict_for_hosted" -eq 1 ]; then
        fail "invalid Risk field: expected none|low|medium|high plus a short reason"
      else
        warn "invalid Risk field: expected none|low|medium|high plus a short reason"
      fi
      ;;
  esac
  risk_reason="${risk#"$risk_value"}"
  risk_reason="${risk_reason#"${risk_reason%%[![:space:]:,-]*}"}"
  risk_reason=$(trim "$risk_reason")
  if [ "$risk_prefix_valid" -eq 1 ] && [ -z "$risk_reason" ]; then
    if [ "$strict_for_hosted" -eq 1 ]; then
      fail "invalid Risk field: expected none|low|medium|high plus a short reason"
    else
      warn "invalid Risk field: expected none|low|medium|high plus a short reason"
    fi
  fi
fi

compact_missing=$(compact_missing_labels)
verbose_missing=$(verbose_missing_labels)
if [ -z "$compact_missing" ] || [ -z "$verbose_missing" ]; then
  :
else
  if [ "$strict_for_hosted" -eq 1 ]; then
    fail "missing required commit metadata: provide compact fields (Impact, Areas, Release-Note, Why, Risk) or legacy fields (Affected-Areas, Problem, Solution, Changelog, Implementation notes, Caveats). Missing compact: ${compact_missing}; missing legacy: ${verbose_missing}"
  else
    warn "missing recommended commit metadata: provide compact fields (Impact, Areas, Release-Note, Why, Risk) or legacy fields (Affected-Areas, Problem, Solution, Changelog, Implementation notes, Caveats). Missing compact: ${compact_missing}; missing legacy: ${verbose_missing}"
  fi
fi

if [ -z "$studio_host" ]; then
  if [ "$strict_for_hosted" -eq 1 ]; then
    fail "missing trailer Studio-Host: <host-id> (strict for host-authored automation; e.g., Studio-Host: ${known_host})"
  else
    warn "missing trailer Studio-Host: <host-id>. Add it for automation attribution (human-authored commits are warned)"
  fi
fi

if [ "$coauthored_by_seen" -eq 1 ] && [ -z "$studio_host" ] && [ "$errs" -eq 0 ]; then
  warn "Co-authored-by is for human-visible credit and is not used for host attribution."
fi

case "$studio_host" in
  codex|codex-*|*codex*)
    if [ -n "$bad_codex_coauthor" ]; then
      warn "Codex co-author trailer should be exactly: Co-authored-by: Codex <noreply@openai.com> (found: $bad_codex_coauthor)"
    elif [ "$codex_coauthor_seen" -eq 0 ]; then
      warn "Codex-hosted commits should include GitHub-visible credit: Co-authored-by: Codex <noreply@openai.com>"
    fi
    ;;
esac

if [ "$errs" -gt 0 ]; then
  printf 'commit message must include the structured subject, required body fields, and valid Change-Type/Studio-Host trailers\n' >&2
  printf 'To bypass only in emergency, set STUDIO_BYPASS_COMMIT_TRAILER_LINT=1\n' >&2
  exit 1
fi

if [ "$warns" -gt 0 ]; then
  printf 'lint-commit-message: passed with %s warning(s)\n' "$warns" >&2
fi

exit 0
