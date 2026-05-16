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
#
# If a cross-host reviewer fails eligibility, execution, timeout, or verdict
# parsing, the wrapper tries another cross-host reviewer profile first. If no
# cross-host reviewer returns usable output, phase gates may fall back to the
# parent host's reviewer profile as a degraded continuity path. Same-host
# fallback is loud: it does not satisfy cross-host review and emits retry
# metadata for the next independent boundary. Disable same-host continuity with:
#   STUDIO_DISABLE_PHASE_REVIEW_DEGRADED_SAME_HOST=1
#
# Claude Code subscription/403 failures keep the existing explicit opt-out:
#   STUDIO_DISABLE_PHASE_REVIEW_CLAUDE_403_FALLBACK=1

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=scripts/lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"
# shellcheck source=scripts/lib-review-host.sh
. "$SCRIPT_DIR/lib-review-host.sh"
# shellcheck source=scripts/lib-review-budget.sh
. "$SCRIPT_DIR/lib-review-budget.sh"

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

failure_detail() {
  local detail
  detail=$(sed -n 's/^DETAIL=//p' "$1" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c 1-240)
  [ -n "$detail" ] || detail=$(first_line "$1")
  printf '%s\n' "$detail"
}

text_mentions_claude_subscription_403() {
  grep -Eiq 'disabled Claude subscription access|Claude subscription access|subscription access for Claude Code|((^|[^0-9])403([^0-9]|$).*(Claude|subscription|access|Anthropic))|((Claude|subscription|access|Anthropic).*(^|[^0-9])403([^0-9]|$))'
}

claude_subscription_403_present() {
  local file
  case "$review_host" in
    claude*|*claude*) ;;
    *) return 1 ;;
  esac
  for file in "$err_output" "$output"; do
    [ -f "$file" ] || continue
    if text_mentions_claude_subscription_403 < "$file"; then
      return 0
    fi
  done
  return 1
}

phase_review_has_usable_verdict() {
  local review_file="$1"
  if sed -n -E 's/^[[:space:]]*(PHASE_REVIEW_VERDICT|STUDIO_REVIEW_VERDICT)[[:space:]]*[:=][[:space:]]*(clean|blocked|ambiguous)[[:space:]]*$/\2/ip' "$review_file" | grep -q .; then
    return 0
  fi
  if grep -Eiq 'fatal blockers[[:space:]]*:?[[:space:]]*(present|yes)|verdict[^[:cntrl:]]*(blocked|do not proceed|stop)' "$review_file"; then
    return 0
  fi
  if grep -Eiq 'nothing fatal|no fatal blockers|fatal blockers[[:space:]]*:?[[:space:]]*(none|no)|verdict[^[:cntrl:]]*(clean|proceed)' "$review_file"; then
    return 0
  fi
  return 1
}

fallback_host_list() {
  local parent_host="$1" preferred_host="$2" configured candidate seen same_host parent_family
  configured="${STUDIO_PHASE_REVIEW_FALLBACK_HOSTS:-claude-reviewer,codex-reviewer}"
  parent_family=$(review_host_family "$parent_host")
  seen=" $preferred_host "
  IFS=',' read -r -a configured_hosts <<< "$configured"
  for candidate in "${configured_hosts[@]}"; do
    [ -n "$candidate" ] || continue
    case "$seen" in *" $candidate "*) continue ;; esac
    if [ "$parent_family" = "unknown" ] || review_host_is_cross_family "$parent_host" "$candidate"; then
      printf '%s\t0\n' "$candidate"
      seen="$seen$candidate "
    fi
  done
  if [ "${STUDIO_DISABLE_PHASE_REVIEW_DEGRADED_SAME_HOST:-0}" != "1" ]; then
    same_host=$(review_host_same_family_reviewer_for_parent "$parent_host" 2>/dev/null || true)
    if [ -n "$same_host" ]; then
      case "$seen" in
        *" $same_host "*) ;;
        *) printf '%s\t1\n' "$same_host" ;;
      esac
    fi
  fi
}

save_failed_outputs_for_host() {
  local host="$1" saved_output saved_err
  saved_output="$output.$host"
  saved_err="$err_output.$host"
  [ ! -f "$output" ] || mv "$output" "$saved_output"
  [ ! -f "$err_output" ] || mv "$err_output" "$saved_err"
}

try_review_fallbacks() {
  local reason="$1" detail="$2" parent_host fallback_host degraded fallback_meta fallback_rc failures
  [ "${STUDIO_PHASE_REVIEW_NO_FALLBACK:-0}" != "1" ] || return 1
  if [ "$reason" = "claude_subscription_403" ] && [ "${STUDIO_DISABLE_PHASE_REVIEW_CLAUDE_403_FALLBACK:-0}" = "1" ]; then
    return 1
  fi
  parent_host=$(resolve_current_studio_host unknown)
  failures=""
  save_failed_outputs_for_host "$review_host"
  while IFS=$'\t' read -r fallback_host degraded; do
    [ -n "$fallback_host" ] || continue
    set +e
    fallback_meta=$(STUDIO_PHASE_REVIEW_NO_FALLBACK=1 STUDIO_PARENT_HOST="$parent_host" "$0" \
      --review-host "$fallback_host" \
      --kind "$kind" \
      --input "$input" \
      --output "$output" \
      --err-output "$err_output" 2>&1)
    fallback_rc=$?
    set -e
    if [ "$fallback_rc" -eq 0 ]; then
      printf '%s\n' "$fallback_meta"
      printf 'PHASE_REVIEW_FALLBACK_FROM=%s\n' "$review_host"
      printf 'PHASE_REVIEW_FALLBACK_TO=%s\n' "$fallback_host"
      printf 'PHASE_REVIEW_FALLBACK_REASON=%s\n' "$reason"
      printf 'PHASE_REVIEW_FALLBACK_DETAIL=%s\n' "$detail"
      if [ "$degraded" = "1" ]; then
        printf 'PHASE_REVIEW_DEGRADED=1\n'
        printf 'PHASE_REVIEW_DEGRADED_REASON=no_cross_host_reviewer_usable\n'
        printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=false\n'
        printf 'PHASE_REVIEW_NEXT_CROSS_HOST_RETRY=next_boundary\n'
      fi
      exit 0
    fi
    failures="${failures}${failures:+; }${fallback_host}: $(printf '%s\n' "$fallback_meta" | tail -1 | cut -c 1-180)"
    save_failed_outputs_for_host "$fallback_host"
  done < <(fallback_host_list "$parent_host" "$review_host")
  [ -z "$failures" ] || printf 'PHASE_REVIEW_FALLBACK_FAILURES=%s\n' "$failures" >&2
  return 1
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
  review_host=$(review_host_default_for_parent_host "$parent_host")
fi

mkdir -p "$(dirname "$output")"
[ -n "$err_output" ] || err_output="$output.err"
mkdir -p "$(dirname "$err_output")"
input_dir=$(cd "$(dirname "$input")" && pwd -P) || fail "input directory not readable: $input"

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
    printf '%s\n' "$eligibility" > "$err_output"
    detail=$(failure_detail "$err_output")
    [ -n "$detail" ] || detail="reviewer host is not eligible"
    if claude_subscription_403_present; then
      try_review_fallbacks claude_subscription_403 "$detail"
    else
      try_review_fallbacks reviewer_ineligible "$detail"
    fi
    fail "reviewer host is not eligible: $review_host"
  }
  [ -z "$eligibility_cache_file" ] || printf '%s\n' "$eligibility" > "$eligibility_cache_file"
fi

spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || fail "missing spawn command for $review_host"

parent_host_for_model=$(resolve_current_studio_host unknown)
resolver_args=(--review-host "$review_host" --implementation-host "$parent_host_for_model" --role reviewer.heavyweight)
if ! review_host_is_cross_family "$parent_host_for_model" "$review_host"; then
  resolver_args+=(--allow-same-family)
fi
model_resolution=$("$SCRIPT_DIR/resolve-reviewer-model.sh" "${resolver_args[@]}" 2>&1) \
  || fail "failed to resolve reviewer model for $review_host: $model_resolution"
# resolve-reviewer-model.sh is repo-owned and emits only %q-quoted shell assignments.
eval "$model_resolution"

tmpdir=$(mktemp -d -t phase-review.XXXXXX) || fail "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"

# shellcheck disable=SC2206
spawn_argv=( $spawn_command )
case "$review_host" in
  codex*|*codex*)
    spawn_argv+=(-m "$REVIEWER_MODEL_ID" -c "model_reasoning_effort=$REVIEWER_MODEL_REASONING_EFFORT")
    ;;
  claude*|*claude*)
    spawn_argv+=(--model "$REVIEWER_MODEL_ID")
    ;;
esac

input_content=$(cat "$input")
input_bytes=$(wc -c < "$input" 2>/dev/null | tr -d ' ' || printf '0')
input_lines=$(wc -l < "$input" 2>/dev/null | tr -d ' ' || printf '0')
case "$input_bytes" in ""|*[!0-9]*) input_bytes=0 ;; esac
case "$input_lines" in ""|*[!0-9]*) input_lines=0 ;; esac
input_estimated_tokens=$(((input_bytes + 2) / 3))
phase_budget_tokens=$(review_budget_payload_token_budget)
phase_context_status="ok"
[ "$input_estimated_tokens" -le "$phase_budget_tokens" ] || phase_context_status="over_budget"
phase_context_json=$(jq -n \
  --arg kind "phase-$kind" \
  --arg mode "artifact-scoped" \
  --arg risk_level "phase-gate" \
  --argjson bytes "$input_bytes" \
  --argjson lines "$input_lines" \
  --argjson estimated_tokens "$input_estimated_tokens" \
  --argjson payload_budget_tokens "$phase_budget_tokens" \
  --arg status "$phase_context_status" \
  '{kind:$kind,mode:$mode,risk_level:$risk_level,budget:{payload_budget_tokens:$payload_budget_tokens},payload:{bytes:$bytes,lines:$lines,estimated_tokens:$estimated_tokens,status:$status}}')
review_budget_emit_context_event studio "$input" review_context_budget_resolved "$phase_context_json" "phase-review-context:$kind:$input"

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

review_argv=("${spawn_argv[@]}")
case "$review_host" in
  claude*|*claude*) review_argv+=("--add-dir=$input_dir") ;;
esac
review_cmd=(review_host_run_command "$review_host" "$reviewer_home" \
  --env REVIEW_PAYLOAD "$input" \
  --env STUDIO_REVIEW_MODEL_ID "$REVIEWER_MODEL_ID" \
  --env STUDIO_REVIEW_REASONING_EFFORT "$REVIEWER_MODEL_REASONING_EFFORT" \
  --env STUDIO_REVIEW_PROVIDER_FAMILY "$REVIEWER_MODEL_PROVIDER_FAMILY" \
  -- "${review_argv[@]}" "$prompt")

if ! "${review_cmd[@]}" > "$output" 2>"$err_output"; then
  detail=$(failure_detail "$err_output")
  [ -n "$detail" ] || detail=$(failure_detail "$output")
  if claude_subscription_403_present; then
    try_review_fallbacks claude_subscription_403 "$detail"
  else
    try_review_fallbacks reviewer_command_failed "$detail"
  fi
  fail "reviewer command failed for $review_host${detail:+: $detail}"
fi

[ -s "$output" ] || {
  try_review_fallbacks reviewer_empty_output "reviewer produced empty output"
  fail "reviewer produced empty output: $output"
}

if ! phase_review_has_usable_verdict "$output"; then
  detail=$(first_line "$output")
  [ -n "$detail" ] || detail="reviewer output did not include a stable verdict"
  try_review_fallbacks reviewer_no_usable_verdict "$detail"
  fail "reviewer did not emit a usable verdict for $review_host${detail:+: $detail}"
fi

verdict=$(phase_review_verdict "$output")
parent_host_for_meta=$(resolve_current_studio_host unknown)
printf 'PHASE_REVIEW_HOST=%s\n' "$review_host"
printf 'PHASE_REVIEW_OUTPUT=%s\n' "$output"
printf 'PHASE_REVIEW_ERR=%s\n' "$err_output"
printf 'PHASE_REVIEW_VERDICT=%s\n' "$verdict"
printf 'PHASE_REVIEW_CONTEXT_TOKENS=%s\n' "$input_estimated_tokens"
printf 'PHASE_REVIEW_MODEL_ID=%s\n' "$REVIEWER_MODEL_ID"
printf 'PHASE_REVIEW_REASONING_EFFORT=%s\n' "$REVIEWER_MODEL_REASONING_EFFORT"
if review_host_is_cross_family "$parent_host_for_meta" "$review_host"; then
  printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=true\n'
else
  printf 'PHASE_REVIEW_CROSS_HOST_SATISFIED=false\n'
fi
printf 'PHASE_REVIEW_DEGRADED=0\n'
