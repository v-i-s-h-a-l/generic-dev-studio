#!/usr/bin/env bash
# phase-review.sh — run sibling-host plan/outcome reviews through reviewer profiles.
#
# Usage:
#   scripts/phase-review.sh --review-host claude-reviewer --input plan.md --output review.md
#   scripts/phase-review.sh --kind outcome --input outcome.md --output outcome-review.md
#
# Emergency/debug-only bypass for field-agent wrapper enforcement:
#   STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1
# The bypass is user-controlled and must be recorded in the plan/outcome
# artifact; assistants must not use it silently.
#
# This is deliberately a thin wrapper over pr-reviewer-eligibility.sh. Phase
# gates must not hand-compose raw `claude -p` / `codex exec` calls; those bypass
# the smoke/auth/config checks that keep reviewer sessions reliable.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CALLER_HOME="${HOME:-}"

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() {
  sed -n '3,9p' "$0" >&2
  exit 2
}

fail() {
  printf 'phase-review: %s\n' "$1" >&2
  exit "${2:-1}"
}

first_line() {
  sed -n '1p' "$1" 2>/dev/null | tr '\n' ' ' | cut -c 1-240
}

phase_review_verdict() {
  local review_file="$1" verdict
  verdict=$(sed -n -E 's/^[[:space:]]*(PHASE_REVIEW_VERDICT|STUDIO_REVIEW_VERDICT)[[:space:]]*[:=][[:space:]]*(clean|blocked|ambiguous)[[:space:]]*$/\2/ip' "$review_file" | tail -1 | tr '[:upper:]' '[:lower:]')
  if [ -n "$verdict" ]; then
    printf '%s\n' "$verdict"
    return 0
  fi
  if grep -Eiq 'fatal blockers[[:space:]]*:?[[:space:]]*(present|yes)|verdict[^[:cntrl:]]*(blocked|do not proceed|stop)' "$review_file"; then
    printf 'blocked\n'
    return 0
  fi
  if grep -Eiq 'nothing fatal|no fatal blockers|fatal blockers[[:space:]]*:?[[:space:]]*(none|no)|verdict[^[:cntrl:]]*(clean|proceed)' "$review_file"; then
    printf 'clean\n'
    return 0
  fi
  printf 'ambiguous\n'
}

review_host=""
input=""
output=""
err_output=""
kind="plan"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --review-host)
      review_host="${2:-}"; shift 2 ;;
    --input)
      input="${2:-}"; shift 2 ;;
    --output)
      output="${2:-}"; shift 2 ;;
    --err-output)
      err_output="${2:-}"; shift 2 ;;
    --kind)
      kind="${2:-}"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      fail "unknown argument: $1" 2 ;;
  esac
done

[ -n "$input" ] || usage
[ -n "$output" ] || usage
[ -f "$input" ] || fail "input file not found: $input"

case "$kind" in
  plan|outcome|review|general) ;;
  *) fail "--kind must be plan, outcome, review, or general" 2 ;;
esac

if [ -z "$review_host" ]; then
  parent_host=$(resolve_current_studio_host "")
  case "$parent_host" in
    *codex*) review_host="claude-reviewer" ;;
    *claude*) review_host="codex-reviewer" ;;
    *) review_host="${STUDIO_REVIEW_HOST:-claude-reviewer}" ;;
  esac
fi

eligibility_cache_dir="${STUDIO_PHASE_REVIEW_ELIGIBILITY_CACHE_DIR:-}"
eligibility_cache_file=""
if [ -n "$eligibility_cache_dir" ]; then
  mkdir -p "$eligibility_cache_dir" || fail "failed to create eligibility cache: $eligibility_cache_dir"
  eligibility_cache_file="$eligibility_cache_dir/$review_host.env"
fi

if [ -n "$eligibility_cache_file" ] && [ -s "$eligibility_cache_file" ]; then
  eligibility=$(cat "$eligibility_cache_file")
else
  eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$review_host") || {
    printf '%s\n' "$eligibility" >&2
    fail "reviewer host is not eligible: $review_host"
  }
  [ -z "$eligibility_cache_file" ] || printf '%s\n' "$eligibility" > "$eligibility_cache_file"
fi

spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || fail "missing spawn command for $review_host"

tmpdir=$(mktemp -d -t phase-review.XXXXXX) || fail "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"

LOGIN_HOME=$(resolve_user_login_home 2>/dev/null || true)
reviewer_codex_home=""
reviewer_claude_home=""
reviewer_claude_config_dir=""

case "$review_host" in
  codex*|*codex*)
    reviewer_codex_home="${CODEX_REVIEWER_HOME:-${CODEX_HOME:-}}"
    if [ -z "$reviewer_codex_home" ]; then
      if [ -n "$CALLER_HOME" ] && [ -d "$CALLER_HOME/.codex" ]; then
        reviewer_codex_home="$CALLER_HOME/.codex"
      elif [ -n "$LOGIN_HOME" ] && [ -d "$LOGIN_HOME/.codex" ]; then
        reviewer_codex_home="$LOGIN_HOME/.codex"
      fi
    fi
    [ -n "$reviewer_codex_home" ] && [ -d "$reviewer_codex_home" ] \
      || fail "codex reviewer auth home not found; set CODEX_REVIEWER_HOME or CODEX_HOME"
    ;;
  claude*|*claude*)
    reviewer_claude_home="${CLAUDE_REVIEWER_HOME:-$LOGIN_HOME}"
    [ -n "$reviewer_claude_home" ] && [ -d "$reviewer_claude_home" ] \
      || fail "claude reviewer auth home not found; set CLAUDE_REVIEWER_HOME"
    reviewer_claude_config_dir="${CLAUDE_REVIEWER_CONFIG_DIR:-$reviewer_claude_home/.claude-reviewer}"
    mkdir -p "$reviewer_claude_config_dir" \
      || fail "failed to create claude reviewer config dir: $reviewer_claude_config_dir"
    ;;
esac

# shellcheck disable=SC2206
spawn_argv=( $spawn_command )

input_content=$(cat "$input")

prompt=$(cat <<EOF
Read this $kind-review artifact and perform the required sibling-host review:

Source artifact: $input

----- BEGIN PHASE ARTIFACT -----
$input_content
----- END PHASE ARTIFACT -----

Assess whether the execution may proceed. Be direct: list fatal blockers first,
then warnings, then recommendations or plan adjustments.

End with exactly one stable verdict line:

PHASE_REVIEW_VERDICT=clean

Use:
- PHASE_REVIEW_VERDICT=clean when nothing fatal blocks execution.
- PHASE_REVIEW_VERDICT=blocked when a fatal blocker must be resolved by another
  review round before continuing.
- PHASE_REVIEW_VERDICT=ambiguous when the artifact is too unclear to classify.
EOF
)

mkdir -p "$(dirname "$output")"
[ -n "$err_output" ] || err_output="$output.err"
mkdir -p "$(dirname "$err_output")"

case "$review_host" in
  codex*|*codex*)
    review_cmd=(env -i \
      PATH="$PATH" \
      HOME="$reviewer_home" \
      LANG="${LANG:-C.UTF-8}" \
      USER="${USER:-}" \
      ${reviewer_codex_home:+CODEX_HOME="$reviewer_codex_home"} \
      STUDIO_HOST="$review_host" \
      REVIEW_PAYLOAD="$input" \
      "${spawn_argv[@]}" "$prompt")
    ;;
  *)
    review_cmd=(env -i \
      PATH="$PATH" \
      HOME="$reviewer_claude_home" \
      LANG="${LANG:-C.UTF-8}" \
      USER="${USER:-}" \
      ${reviewer_claude_config_dir:+CLAUDE_CONFIG_DIR="$reviewer_claude_config_dir"} \
      CLAUDE_REVIEWER_HOME="$reviewer_claude_home" \
      STUDIO_HOST="$review_host" \
      REVIEW_PAYLOAD="$input" \
      "${spawn_argv[@]}" "$prompt")
    ;;
esac

if ! ( cd "$REPO_ROOT" && case "$review_host" in
    codex*|*codex*) "${review_cmd[@]}" > "$output" 2>"$err_output" ;;
    *) "${review_cmd[@]}" </dev/null > "$output" 2>"$err_output" ;;
  esac ); then
  detail=$(first_line "$err_output")
  [ -n "$detail" ] || detail=$(first_line "$output")
  fail "reviewer command failed for $review_host${detail:+: $detail}"
fi

[ -s "$output" ] || fail "reviewer produced empty output: $output"

verdict=$(phase_review_verdict "$output")
printf 'PHASE_REVIEW_HOST=%s\n' "$review_host"
printf 'PHASE_REVIEW_OUTPUT=%s\n' "$output"
printf 'PHASE_REVIEW_ERR=%s\n' "$err_output"
printf 'PHASE_REVIEW_VERDICT=%s\n' "$verdict"
