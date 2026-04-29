#!/usr/bin/env bash
# pr-headless-review.sh — run an eligible no-secret reviewer, then autopilot PR.
#
# Usage:
#   scripts/pr-headless-review.sh <pr> [--review-host <host>] [--impl-host <host>] \
#                                       [--method auto|merge|squash|rebase]
#
# The parent studio session owns GitHub access. This script materializes the
# PR metadata/diff into a temp file, spawns the reviewer with an env-scrubbed
# process, parses STUDIO_REVIEW_VERDICT, then delegates the gate comment and
# merge to pr-autopilot.sh.
#
# Reviewer host + model + reasoning effort are resolved through
# scripts/resolve-reviewer.sh (catalog-driven, zero LLM tokens). Reviewer host
# family is forced different from the implementer's by default; same-family
# collisions escalate the intelligence tier instead of blocking. Hard block
# fires only when no reviewer host is eligible at all (issue #322).
#
# Implementation host signal — first non-empty wins:
#   1. --impl-host flag
#   2. STUDIO_IMPL_HOST env var
#   3. Studio-Impl-Host: trailer on the most recent non-merge PR commit
#   4. unknown (no exclusion is applied)

set -eu
umask 022

usage() {
  printf 'usage: pr-headless-review.sh <pr> [--review-host <host>] [--impl-host <host>] [--method auto|merge|squash|rebase]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift
CALLER_HOME="${HOME:-}"

REVIEW_HOST="${STUDIO_REVIEW_HOST:-}"
IMPL_HOST="${STUDIO_IMPL_HOST:-}"
METHOD="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --impl-host)   IMPL_HOST="${2:?--impl-host requires a value}"; shift 2 ;;
    --method)      METHOD="${2:?--method requires a value}"; shift 2 ;;
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

pr_num=$(gh pr view "$PR" --json number --jq '.number') \
  || { printf 'pr-headless-review: failed to read PR %s\n' "$PR" >&2; exit 1; }

# Implementer-host detection: --impl-host / env wins; otherwise read the
# Studio-Impl-Host: trailer from the most recent non-merge commit on the PR.
# Forward-compatible — Achilles emits this trailer in a future change; until
# then the field is empty and we fall through to "unknown".
if [ -z "$IMPL_HOST" ]; then
  pr_commits_json=$(gh pr view "$PR" --json commits --jq '.commits' 2>/dev/null) || pr_commits_json=""
  if [ -n "$pr_commits_json" ]; then
    IMPL_HOST=$(printf '%s' "$pr_commits_json" \
      | jq -r '
          [.[] | select((.parents // [{},{}]) | length < 2)]
          | (.[-1].messageBody // "")
        ' 2>/dev/null \
      | sed -n 's/^Studio-Impl-Host:[[:space:]]*//Ip' \
      | head -1 \
      | tr -d "\"'\r ")
  fi
fi
[ -n "$IMPL_HOST" ] || IMPL_HOST="unknown"

resolver_args=( --seed "$pr_num" --impl-host "$IMPL_HOST" )
[ -n "$REVIEW_HOST" ] && resolver_args+=( --force-host "$REVIEW_HOST" )

resolution=$("$SCRIPT_DIR/resolve-reviewer.sh" "${resolver_args[@]}") || {
  printf 'pr-headless-review: reviewer resolution failed:\n' >&2
  printf '%s\n' "$resolution" >&2
  exit 1
}

REVIEW_HOST=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_HOST=//p' | head -1)
REVIEW_MODEL=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_MODEL=//p' | head -1)
REVIEW_EFFORT=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_REASONING_EFFORT=//p' | head -1)
REVIEW_TIER=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_TIER=//p' | head -1)
REVIEW_COLLISION=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_FAMILY_COLLISION=//p' | head -1)
REVIEW_ESCALATED=$(printf '%s\n' "$resolution" | sed -n 's/^STUDIO_REVIEWER_ESCALATED=//p' | head -1)
[ -n "$REVIEW_HOST" ] && [ -n "$REVIEW_MODEL" ] || {
  printf 'pr-headless-review: resolver did not return host+model\n' >&2
  printf '%s\n' "$resolution" >&2
  exit 1
}

eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
  printf '%s\n' "$eligibility" >&2
  printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
  exit 1
}
manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || { printf 'pr-headless-review: missing spawn command for %s\n' "$REVIEW_HOST" >&2; exit 1; }

# Append catalog-driven model + reasoning-effort args to the spawn command.
# Codex consumes -c model_reasoning_effort=<level>; Claude has no effort flag
# (thinking is request-side), so we only pin --model.
model_args=()
case "$REVIEW_HOST" in
  codex*|*codex*)
    model_args+=( --model "$REVIEW_MODEL" )
    [ -n "$REVIEW_EFFORT" ] && model_args+=( -c "model_reasoning_effort=$REVIEW_EFFORT" )
    ;;
  claude*|*claude*)
    model_args+=( --model "$REVIEW_MODEL" )
    ;;
esac

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
spawn_argv+=( "${model_args[@]}" )
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
printf 'PR_REVIEW_MODEL=%s\n' "$REVIEW_MODEL"
printf 'PR_REVIEW_REASONING_EFFORT=%s\n' "$REVIEW_EFFORT"
printf 'PR_REVIEW_TIER=%s\n' "$REVIEW_TIER"
printf 'PR_REVIEW_FAMILY_COLLISION=%s\n' "$REVIEW_COLLISION"
printf 'PR_REVIEW_ESCALATED=%s\n' "$REVIEW_ESCALATED"
printf 'PR_REVIEW_IMPL_HOST=%s\n' "$IMPL_HOST"
printf 'PR_REVIEW_VERDICT=%s\n' "$verdict"

"$AUTOPILOT" "$PR" \
  --verdict "$verdict" \
  --review-host "$REVIEW_HOST" \
  --summary-file "$summary" \
  --expected-head-sha "$head_sha" \
  --method "$METHOD"
