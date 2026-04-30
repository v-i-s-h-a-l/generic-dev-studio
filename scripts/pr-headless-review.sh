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

host_family() {
  local host="$1" registry="$REPO_ROOT/hosts/registry.yaml" family
  family=$(yq -r ".\"$host\".provider_family // \"\"" "$registry" 2>/dev/null || true)
  [ -n "$family" ] && [ "$family" != "null" ] && { printf '%s\n' "$family"; return 0; }
  yq -r ".adapters.\"$host\".provider_family // \"\"" "$REPO_ROOT/_shared/schemas/model-catalog.yaml" 2>/dev/null || true
}

policy_model_for() {
  local role="$1" family="$2" policy="$REPO_ROOT/_shared/rules/model-policy.yaml" model
  model=$(yq -r ".roles.\"$role\".provider_preferences[] | select(.provider_family == \"$family\") | .model_id" "$policy" 2>/dev/null | head -1)
  [ -n "$model" ] && [ "$model" != "null" ] && { printf '%s\n' "$model"; return 0; }
  yq -r ".adapters.\"$REVIEW_HOST\".default_model_id // \"\"" "$REPO_ROOT/_shared/schemas/model-catalog.yaml" 2>/dev/null || true
}

policy_effort_for() {
  local role="$1" policy="$REPO_ROOT/_shared/rules/model-policy.yaml"
  yq -r ".roles.\"$role\".reasoning_effort // \"\"" "$policy" 2>/dev/null || true
}

resolve_policy_reviewer() {
  local role="reviewer.heavyweight" policy="$REPO_ROOT/_shared/rules/model-policy.yaml"
  local implementation_host="${STUDIO_IMPLEMENTATION_HOST:-${STUDIO_IMPLEMENTER_HOST:-${STUDIO_HOST:-}}}"
  local excluded_family="" host family require_independent allow_same

  [ -f "$policy" ] || return 1
  if [ -n "$implementation_host" ]; then
    excluded_family=$(host_family "$implementation_host")
  fi
  require_independent=$(yq -r ".roles.\"$role\".require_independent_provider_family // false" "$policy")
  allow_same="${STUDIO_REVIEW_ALLOW_SAME_FAMILY:-0}"

  while IFS= read -r host; do
    [ -n "$host" ] && [ "$host" != "null" ] || continue
    family=$(host_family "$host")
    if [ "$require_independent" = "true" ] && [ "$allow_same" != "1" ] && [ -n "$excluded_family" ] && [ "$family" = "$excluded_family" ]; then
      continue
    fi
    if "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$host" >/dev/null 2>&1; then
      printf '%s\n' "$host"
      return 0
    fi
  done < <(yq -r ".roles.\"$role\".candidate_adapters[]" "$policy" 2>/dev/null)

  return 1
}

append_policy_model_args() {
  local host="$1" model="$2" effort="$3"
  [ -n "$model" ] && [ "$model" != "null" ] || return 0
  case "$host" in
    claude*|*claude*)
      spawn_argv+=(--model "$model")
      [ -n "$effort" ] && [ "$effort" != "null" ] && spawn_argv+=(--effort "$effort")
      ;;
    codex*|*codex*)
      spawn_argv+=(--model "$model")
      [ -n "$effort" ] && [ "$effort" != "null" ] && spawn_argv+=(-c "model_reasoning_effort=$effort")
      ;;
  esac
}

enforce_independent_reviewer_family() {
  local implementation_host="${STUDIO_IMPLEMENTATION_HOST:-${STUDIO_IMPLEMENTER_HOST:-${STUDIO_HOST:-}}}"
  local implementation_family=""
  [ -n "$implementation_host" ] || return 0
  implementation_family=$(host_family "$implementation_host")
  [ -n "$implementation_family" ] && [ "$implementation_family" != "null" ] || return 0
  if [ "${STUDIO_REVIEW_ALLOW_SAME_FAMILY:-0}" != "1" ] && [ "$REVIEW_FAMILY" = "$implementation_family" ]; then
    printf 'pr-headless-review: reviewer host family must differ from implementation host family (implementation_host=%s, implementation_family=%s, review_host=%s)\n' \
      "$implementation_host" "$implementation_family" "$REVIEW_HOST" >&2
    printf 'pr-headless-review: explicit user-approved bypass requires STUDIO_REVIEW_ALLOW_SAME_FAMILY=1\n' >&2
    exit 1
  fi
}

if [ -z "$REVIEW_HOST" ]; then
  REVIEW_HOST=$(resolve_policy_reviewer) || {
    printf 'pr-headless-review: no eligible reviewer hosts found\n' >&2
    impl="${STUDIO_IMPLEMENTATION_HOST:-${STUDIO_IMPLEMENTER_HOST:-${STUDIO_HOST:-unknown}}}"
    printf 'pr-headless-review: implementation host family excluded by policy (implementation_host=%s); explicit bypass requires STUDIO_REVIEW_ALLOW_SAME_FAMILY=1\n' "$impl" >&2
    exit 1
  }
fi

eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
  printf '%s\n' "$eligibility" >&2
  printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
  exit 1
}
manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || { printf 'pr-headless-review: missing spawn command for %s\n' "$REVIEW_HOST" >&2; exit 1; }
REVIEW_FAMILY=$(host_family "$REVIEW_HOST")
enforce_independent_reviewer_family
REVIEW_ROLE="reviewer.heavyweight"
REVIEW_MODEL_ID=$(policy_model_for "$REVIEW_ROLE" "$REVIEW_FAMILY")
REVIEW_REASONING_EFFORT=$(policy_effort_for "$REVIEW_ROLE")

pr_json=$(gh pr view "$PR" --json number,title,url,baseRefName,headRefName,headRefOid,author,commits) \
  || { printf 'pr-headless-review: failed to read PR %s\n' "$PR" >&2; exit 1; }
pr_url=$(printf '%s' "$pr_json" | jq -r '.url')
head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')

tmpdir=$(mktemp -d -t pr-headless-review.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
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
append_policy_model_args "$REVIEW_HOST" "$REVIEW_MODEL_ID" "$REVIEW_REASONING_EFFORT"
review_prompt="Read $payload, review PR $pr_url at HEAD $head_sha, and print STUDIO_REVIEW_VERDICT=<approved|approved_with_fixes|blocked>."

if ! env -i \
    PATH="$PATH" \
    HOME="$reviewer_home" \
    LANG="${LANG:-C.UTF-8}" \
    USER="${USER:-}" \
    ${reviewer_codex_home:+CODEX_HOME="$reviewer_codex_home"} \
    STUDIO_HOST="$REVIEW_HOST" \
    REVIEW_PAYLOAD="$payload" \
    PR_URL="$pr_url" \
    PR_HEAD_SHA="$head_sha" \
    "${spawn_argv[@]}" "$review_prompt" > "$summary" 2>"$summary.err"; then
  printf 'pr-headless-review: reviewer host failed: %s\n' "$REVIEW_HOST" >&2
  sed -n '1,80p' "$summary.err" >&2 || true
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

printf 'PR_REVIEW_HOST=%s\n' "$REVIEW_HOST"
printf 'PR_REVIEW_MANIFEST=%s\n' "$manifest"
printf 'PR_REVIEW_PROVIDER_FAMILY=%s\n' "$REVIEW_FAMILY"
printf 'PR_REVIEW_MODEL=%s\n' "$REVIEW_MODEL_ID"
printf 'PR_REVIEW_REASONING_EFFORT=%s\n' "$REVIEW_REASONING_EFFORT"
printf 'PR_REVIEW_VERDICT=%s\n' "$verdict"

"$AUTOPILOT" "$PR" \
  --verdict "$verdict" \
  --review-host "$REVIEW_HOST" \
  --summary-file "$summary" \
  --expected-head-sha "$head_sha" \
  --method "$METHOD"
