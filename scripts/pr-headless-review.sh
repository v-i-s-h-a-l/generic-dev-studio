#!/usr/bin/env bash
# pr-headless-review.sh — run an eligible no-secret reviewer, then autopilot PR.
#
# Usage:
#   scripts/pr-headless-review.sh <pr> [--review-host <host>] [--method auto|merge|squash|rebase]
#
# The parent studio session owns GitHub access. This script materializes the
# PR metadata/diff into a temp file, spawns the reviewer with an env-scrubbed
# process, parses STUDIO_REVIEW_VERDICT, then delegates the gate comment and
# merge to pr-autopilot.sh.

set -eu
umask 022

usage() {
  printf 'usage: pr-headless-review.sh <pr> [--review-host <host>] [--method auto|merge|squash|rebase]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift
CALLER_HOME="${HOME:-}"
PR_REVIEW_STARTED_AT=$(date +%s)
PR_URL_FOR_EVENT=""
PR_HEAD_SHA_FOR_EVENT=""
PR_REVIEW_VERDICT_FOR_EVENT=""
TMPDIR_TO_CLEAN=""

REVIEW_HOST="${STUDIO_REVIEW_HOST:-}"
METHOD="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --method) METHOD="${2:?--method requires a value}"; shift 2 ;;
    *) printf 'pr-headless-review: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

case "$METHOD" in
  auto|merge|squash|rebase) ;;
  *) printf 'pr-headless-review: --method must be auto|merge|squash|rebase\n' >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AUTOPILOT="${PR_HEADLESS_REVIEW_AUTOPILOT:-$SCRIPT_DIR/pr-autopilot.sh}"

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

emit_pr_review_duration() {
  set +e
  [ -n "$TMPDIR_TO_CLEAN" ] && rm -rf "$TMPDIR_TO_CLEAN"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local rc="${1:-0}" duration_s status data
  duration_s=$(( $(date +%s) - PR_REVIEW_STARTED_AT ))
  [ "$duration_s" -ge 0 ] && [ "$duration_s" -le 86400 ] || return 0
  status="failed"
  [ "$rc" -eq 0 ] && status="passed"
  [ "$PR_REVIEW_VERDICT_FOR_EVENT" = "blocked" ] && status="blocked"
  if command -v jq >/dev/null 2>&1; then
    data=$(jq -cn \
      --arg pr "$PR" \
      --arg pr_url "$PR_URL_FOR_EVENT" \
      --arg head "$PR_HEAD_SHA_FOR_EVENT" \
      --arg host "$REVIEW_HOST" \
      --arg verdict "$PR_REVIEW_VERDICT_FOR_EVENT" \
      --arg method "$METHOD" \
      --arg status "$status" \
      --argjson duration_s "$duration_s" \
      --argjson exit_code "$rc" \
      '{pr:$pr,pr_url:$pr_url,head:$head,review_host:$host,verdict:$verdict,method:$method,status:$status,duration_s:$duration_s,exit_code:$exit_code}')
  else
    data=$(printf '{"pr":"%s","review_host":"%s","verdict":"%s","method":"%s","status":"%s","duration_s":%s,"exit_code":%s}' \
      "$PR" "$REVIEW_HOST" "$PR_REVIEW_VERDICT_FOR_EVENT" "$METHOD" "$status" "$duration_s" "$rc")
  fi
  emit_event_keyed studio pr-review pr_review_completed "" "$data" >/dev/null 2>&1 || true
}

trap 'rc=$?; emit_pr_review_duration "$rc"' EXIT

command -v gh >/dev/null 2>&1 || { printf 'pr-headless-review: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'pr-headless-review: jq is required\n' >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'pr-headless-review: yq is required\n' >&2; exit 1; }

yaml_field() {
  local file="$1" key="$2"
  grep -E "^${key}:[[:space:]]" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | tr -d '"'"'"
}

print_reviewer_failure() {
  local stdout_file="$1" stderr_file="$2"
  printf 'pr-headless-review: reviewer host failed: %s\n' "$REVIEW_HOST" >&2
  if [ -s "$stderr_file" ]; then
    printf 'pr-headless-review: reviewer stderr (first 80 lines):\n' >&2
    sed -n '1,80p' "$stderr_file" >&2 || true
  fi
  if [ -s "$stdout_file" ]; then
    printf 'pr-headless-review: reviewer stdout (first 80 lines):\n' >&2
    sed -n '1,80p' "$stdout_file" >&2 || true
  fi
  if [ ! -s "$stderr_file" ] && [ ! -s "$stdout_file" ]; then
    printf 'pr-headless-review: reviewer produced no stdout/stderr before exit\n' >&2
  fi
}

eligible_hosts() {
  local registry="$REPO_ROOT/hosts/registry.yaml" host manifest reviewer_profile
  [ -f "$registry" ] || return 1
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT" 2>/dev/null || true)
    [ -n "$manifest" ] && [ -f "$manifest" ] || continue
    reviewer_profile=$(yaml_field "$manifest" reviewer_profile)
    [ "$reviewer_profile" = "true" ] || continue
    if "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$host" >/dev/null 2>&1; then
      printf '%s\n' "$host"
    fi
  done < <(yq -r 'keys | .[]' "$registry" 2>/dev/null)
}

if [ -z "$REVIEW_HOST" ]; then
  hosts=()
  while IFS= read -r host; do
    [ -n "$host" ] && hosts+=("$host")
  done < <(eligible_hosts)
  [ "${#hosts[@]}" -gt 0 ] || {
    printf 'pr-headless-review: no eligible reviewer hosts found\n' >&2
    exit 1
  }
  pr_num=$(gh pr view "$PR" --json number --jq '.number') \
    || { printf 'pr-headless-review: failed to read PR %s\n' "$PR" >&2; exit 1; }
  REVIEW_HOST="${hosts[$(( pr_num % ${#hosts[@]} ))]}"
fi

eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
  printf '%s\n' "$eligibility" >&2
  printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
  exit 1
}
manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || { printf 'pr-headless-review: missing spawn command for %s\n' "$REVIEW_HOST" >&2; exit 1; }

pr_json=$(gh pr view "$PR" --json number,title,url,baseRefName,headRefName,headRefOid,author,commits) \
  || { printf 'pr-headless-review: failed to read PR %s\n' "$PR" >&2; exit 1; }
pr_url=$(printf '%s' "$pr_json" | jq -r '.url')
head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
PR_URL_FOR_EVENT="$pr_url"
PR_HEAD_SHA_FOR_EVENT="$head_sha"

tmpdir=$(mktemp -d -t pr-headless-review.XXXXXX)
TMPDIR_TO_CLEAN="$tmpdir"
payload="$tmpdir/review-payload.md"
summary="$tmpdir/reviewer-summary.md"
reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"
reviewer_codex_home=""
case "$REVIEW_HOST" in
  codex*|*codex*)
    reviewer_codex_home="${CODEX_REVIEWER_HOME:-${CODEX_HOME:-${CALLER_HOME:+$CALLER_HOME/.codex}}}"
    [ -n "$reviewer_codex_home" ] && [ -d "$reviewer_codex_home" ] || {
      printf 'pr-headless-review: codex reviewer auth home not found; set CODEX_REVIEWER_HOME or CODEX_HOME\n' >&2
      exit 1
    }
    ;;
esac

{
  printf '# Studio PR Review Payload\n\n'
  printf 'Metadata:\n\n```json\n%s\n```\n\n' "$(printf '%s' "$pr_json" | jq -c '.')"
  cat <<'PROMPT'
Review this studio PR against REVIEW.md and the repository-specific rules.
Grouped feature/reliability PRs are normal when the included issues share a
workflow surface, safety-floor path, test fixture set, or user-facing
capability. Do not block solely because a PR closes multiple issues; block only
when grouping hides traceability, mixes unrelated ownership, or makes the
safety argument unreviewable.

Return a concise report with exactly one machine-readable verdict line:

STUDIO_REVIEW_VERDICT=approved
STUDIO_REVIEW_VERDICT=approved_with_fixes
STUDIO_REVIEW_VERDICT=blocked

Use `blocked` only for critical blockers: data loss, broken routing, unsafe
runtime behavior, permission/auth changes, base-branch bypass, failing required
checks, merge conflicts, or repo-rule violations. Non-critical findings may be
fixed by the reviewer only if the reviewer host has write permissions and the
fix is narrow and confined to the PR branch; summarize any fixes.

PROMPT
  printf '\nPR diff:\n\n```diff\n'
  gh pr diff "$PR" --patch
  printf '\n```\n'
} > "$payload"

# shellcheck disable=SC2206
spawn_argv=( $spawn_command )
review_prompt="Read $payload, review PR $pr_url at HEAD $head_sha, and print STUDIO_REVIEW_VERDICT=<approved|approved_with_fixes|blocked>."

if ! ( cd "$REPO_ROOT" && env -i \
    PATH="$PATH" \
    HOME="$reviewer_home" \
    LANG="${LANG:-C.UTF-8}" \
    USER="${USER:-}" \
    ${reviewer_codex_home:+CODEX_HOME="$reviewer_codex_home"} \
    STUDIO_HOST="$REVIEW_HOST" \
    REVIEW_PAYLOAD="$payload" \
    PR_URL="$pr_url" \
    PR_HEAD_SHA="$head_sha" \
    "${spawn_argv[@]}" "$review_prompt" > "$summary" 2>"$summary.err" ); then
  print_reviewer_failure "$summary" "$summary.err"
  exit 1
fi

verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary" | wc -l | tr -d ' ')
verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary")
if [ "$verdict_count" != "1" ]; then
  printf 'pr-headless-review: reviewer must emit exactly one STUDIO_REVIEW_VERDICT line (found %s)\n' "$verdict_count" >&2
  sed -n '1,120p' "$summary" >&2 || true
  exit 1
fi
case "$verdict" in
  approved|approved_with_fixes|blocked) ;;
  *)
    printf 'pr-headless-review: reviewer did not emit a valid STUDIO_REVIEW_VERDICT line\n' >&2
    sed -n '1,120p' "$summary" >&2 || true
    exit 1
    ;;
esac
PR_REVIEW_VERDICT_FOR_EVENT="$verdict"

printf 'PR_REVIEW_HOST=%s\n' "$REVIEW_HOST"
printf 'PR_REVIEW_MANIFEST=%s\n' "$manifest"
printf 'PR_REVIEW_VERDICT=%s\n' "$verdict"

"$AUTOPILOT" "$PR" \
  --verdict "$verdict" \
  --review-host "$REVIEW_HOST" \
  --summary-file "$summary" \
  --expected-head-sha "$head_sha" \
  --method "$METHOD"
