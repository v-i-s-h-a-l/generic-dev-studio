#!/usr/bin/env bash
# pr-headless-review.sh — run an eligible no-secret reviewer, then autopilot PR.
#
# Usage:
#   scripts/pr-headless-review.sh <pr> [--review-host <host>] [--method auto|merge|squash|rebase]
#       [--require-cross-host-when-available|--no-require-cross-host]
#       [--allow-same-host-review --user-approved-bypass <github-url>]
#       [--allow-target-repo-auto-merge --user-approved-bypass <github-url>]
#
# The parent studio session owns GitHub access. This script materializes the
# PR metadata/diff into a temp file, spawns the reviewer with an env-scrubbed
# process, parses STUDIO_REVIEW_VERDICT, then delegates the gate comment and
# merge to pr-autopilot.sh.

set -eu
umask 022

usage() {
  printf 'usage: pr-headless-review.sh <pr> [--review-host <host>] [--method auto|merge|squash|rebase] [--require-cross-host-when-available|--no-require-cross-host] [--allow-same-host-review --user-approved-bypass <github-url>] [--allow-target-repo-auto-merge --user-approved-bypass <github-url>]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift
PR_REVIEW_STARTED_AT=$(date +%s)
PR_URL_FOR_EVENT=""
PR_HEAD_SHA_FOR_EVENT=""
PR_REVIEW_VERDICT_FOR_EVENT=""
PR_REVIEW_TOKENS_JSON="null"
PR_REVIEW_CONTEXT_JSON="null"
TMPDIR_TO_CLEAN=""
REVIEW_SESSION_SCAN_STARTED_AT=$(date +%s)
PARENT_HOST=""
ELIGIBLE_REVIEW_HOSTS_CSV=""
CROSS_HOST_FOR_EVENT="false"
FALLBACK_FROM_CSV=""
FALLBACK_FAILURES_TEXT=""
CROSS_HOST_REQUIRED="${STUDIO_REQUIRE_CROSS_HOST_REVIEW:-1}"
CROSS_HOST_BYPASS_URL=""
REVIEW_MODEL_KEY_FOR_EVENT=""
REVIEW_MODEL_ID_FOR_EVENT=""
REVIEW_MODEL_PROVIDER_FAMILY_FOR_EVENT=""
REVIEW_MODEL_REASONING_EFFORT_FOR_EVENT=""

REVIEW_HOST="${STUDIO_REVIEW_HOST:-}"
METHOD="auto"
EXPLICIT_REVIEW_HOST=0
ALLOW_SAME_HOST_REVIEW=0
ALLOW_TARGET_REPO_AUTO_MERGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; EXPLICIT_REVIEW_HOST=1; shift 2 ;;
    --method) METHOD="${2:?--method requires a value}"; shift 2 ;;
    --require-cross-host-when-available) CROSS_HOST_REQUIRED=1; shift ;;
    --no-require-cross-host) CROSS_HOST_REQUIRED=0; shift ;;
    --allow-same-host-review) ALLOW_SAME_HOST_REVIEW=1; shift ;;
    --allow-target-repo-auto-merge) ALLOW_TARGET_REPO_AUTO_MERGE=1; shift ;;
    --user-approved-bypass) CROSS_HOST_BYPASS_URL="${2:?--user-approved-bypass requires a value}"; shift 2 ;;
    *) printf 'pr-headless-review: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

case "$METHOD" in
  auto|merge|squash|rebase) ;;
  *) printf 'pr-headless-review: --method must be auto|merge|squash|rebase\n' >&2; exit 2 ;;
esac
case "$CROSS_HOST_REQUIRED" in
  1|true|yes) CROSS_HOST_REQUIRED=1 ;;
  0|false|no|"") CROSS_HOST_REQUIRED=0 ;;
  *) printf 'pr-headless-review: STUDIO_REQUIRE_CROSS_HOST_REVIEW must be 0/1/true/false\n' >&2; exit 2 ;;
esac
[ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ] || [ -n "$CROSS_HOST_BYPASS_URL" ] || {
  printf 'pr-headless-review: --allow-same-host-review requires --user-approved-bypass <github-url>\n' >&2
  exit 2
}
[ "$ALLOW_TARGET_REPO_AUTO_MERGE" -eq 0 ] || [ -n "$CROSS_HOST_BYPASS_URL" ] || {
  printf 'pr-headless-review: --allow-target-repo-auto-merge requires --user-approved-bypass <github-url>\n' >&2
  exit 2
}
if [ -n "$CROSS_HOST_BYPASS_URL" ]; then
  case "$CROSS_HOST_BYPASS_URL" in
    https://github.com/*/issues/*|https://github.com/*/pull/*|https://github.com/*/discussions/*) ;;
    *) printf 'pr-headless-review: user-approved bypass must be a GitHub issue, PR, comment, or discussion URL\n' >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AUTOPILOT="${PR_HEADLESS_REVIEW_AUTOPILOT:-$SCRIPT_DIR/pr-autopilot.sh}"

# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=scripts/lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"
# shellcheck source=scripts/lib-review-host.sh
. "$SCRIPT_DIR/lib-review-host.sh"
# shellcheck source=scripts/lib-review-budget.sh
. "$SCRIPT_DIR/lib-review-budget.sh"
# shellcheck source=scripts/lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

PARENT_HOST=$(resolve_current_studio_host unknown)

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
      --arg parent_host "$PARENT_HOST" \
      --arg eligible_hosts "$ELIGIBLE_REVIEW_HOSTS_CSV" \
      --arg cross_host "$CROSS_HOST_FOR_EVENT" \
      --arg fallback_from "$FALLBACK_FROM_CSV" \
      --arg fallback_failures "$FALLBACK_FAILURES_TEXT" \
      --arg cross_host_required "$CROSS_HOST_REQUIRED" \
      --arg cross_host_bypass_url "$CROSS_HOST_BYPASS_URL" \
      --arg review_model_key "$REVIEW_MODEL_KEY_FOR_EVENT" \
      --arg review_model_id "$REVIEW_MODEL_ID_FOR_EVENT" \
      --arg review_model_provider_family "$REVIEW_MODEL_PROVIDER_FAMILY_FOR_EVENT" \
      --arg review_model_reasoning_effort "$REVIEW_MODEL_REASONING_EFFORT_FOR_EVENT" \
      --argjson duration_s "$duration_s" \
      --argjson exit_code "$rc" \
      --argjson tokens "$PR_REVIEW_TOKENS_JSON" \
      --argjson review_context "$PR_REVIEW_CONTEXT_JSON" \
      '{pr:$pr,pr_url:$pr_url,head:$head,review_host:$host,selected_review_host:$host,verdict:$verdict,method:$method,status:$status,duration_s:$duration_s,exit_code:$exit_code,
        parent_host:$parent_host,
        eligible_review_hosts:($eligible_hosts | split(",") | map(select(length > 0))),
        cross_host:($cross_host == "true"),
        cross_host_required:($cross_host_required == "1"),
        fallback_from:($fallback_from | split(",") | map(select(length > 0)))}
       + (if $fallback_failures == "" then {} else {fallback_failures:$fallback_failures} end)
       + (if $cross_host_bypass_url == "" then {} else {cross_host_bypass_url:$cross_host_bypass_url} end)
       + (if $review_model_id == "" then {} else {review_model_key:$review_model_key,review_model_id:$review_model_id,review_model_provider_family:$review_model_provider_family,review_model_reasoning_effort:$review_model_reasoning_effort} end)
       + (if $tokens == null then {} else {tokens:$tokens} end)
       + (if $review_context == null then {} else {review_context:$review_context} end)')
  else
    data=$(printf '{"pr":"%s","review_host":"%s","selected_review_host":"%s","verdict":"%s","method":"%s","status":"%s","parent_host":"%s","eligible_review_hosts":"%s","cross_host":"%s","cross_host_required":"%s","fallback_from":"%s","fallback_failures":"%s","duration_s":%s,"exit_code":%s}' \
      "$PR" "$REVIEW_HOST" "$REVIEW_HOST" "$PR_REVIEW_VERDICT_FOR_EVENT" "$METHOD" "$status" "$PARENT_HOST" "$ELIGIBLE_REVIEW_HOSTS_CSV" "$CROSS_HOST_FOR_EVENT" "$CROSS_HOST_REQUIRED" "$FALLBACK_FROM_CSV" "$FALLBACK_FAILURES_TEXT" "$duration_s" "$rc")
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

join_csv() {
  local sep="" item
  for item in "$@"; do
    [ -n "$item" ] || continue
    printf '%s%s' "$sep" "$item"
    sep=","
  done
}

append_failure() {
  local host="$1" stdout_file="$2" stderr_file="$3" detail
  detail=$(sed -n '1p' "$stderr_file" 2>/dev/null | tr '\n' ' ' | cut -c 1-180)
  [ -n "$detail" ] || detail=$(sed -n '1p' "$stdout_file" 2>/dev/null | tr '\n' ' ' | cut -c 1-180)
  [ -n "$detail" ] || detail="no reviewer output"
  if [ -n "$FALLBACK_FAILURES_TEXT" ]; then
    FALLBACK_FAILURES_TEXT="${FALLBACK_FAILURES_TEXT}; ${host}: ${detail}"
  else
    FALLBACK_FAILURES_TEXT="${host}: ${detail}"
  fi
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

collect_codex_review_tokens() {
  [ -n "${REVIEW_HOST_CODEX_HOME:-}" ] || return 0
  local session_dir="$REVIEW_HOST_CODEX_HOME/sessions"
  [ -d "$session_dir" ] || return 0

  local best_file="" best_mtime=0 candidate mtime
  while IFS= read -r -d '' candidate; do
    mtime=$(stat -f %m "$candidate" 2>/dev/null || printf '')
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$mtime" -ge "$REVIEW_SESSION_SCAN_STARTED_AT" ] || continue
    if jq -e --arg cwd "$REPO_ROOT" 'select(.type == "session_meta" and .payload.cwd == $cwd)' "$candidate" >/dev/null 2>&1; then
      if [ -z "$best_file" ] || [ "$mtime" -ge "$best_mtime" ]; then
        best_file="$candidate"
        best_mtime="$mtime"
      fi
    fi
  done < <(find "$session_dir" -type f -name '*.jsonl' -print0 2>/dev/null)

  [ -n "$best_file" ] || return 0

  jq -rs '
    [ .[]
      | select(.type == "event_msg" and .payload.type == "token_count" and (.payload.info.total_token_usage // null) != null)
      | (.payload.info.total_token_usage // .payload.info.last_token_usage)
    ]
    | last
    | if . == null then empty else {
        input: (.input_tokens // 0),
        output: (.output_tokens // 0),
        cache_read: (.cached_input_tokens // 0),
        cache_write: 0
      } end
  ' "$best_file"
}

eligible_hosts() {
  local registry="$REPO_ROOT/hosts/registry.yaml" host manifest reviewer_profile eligibility_rc hosts_file
  [ -f "$registry" ] || return 1
  hosts_file=$(mktemp -t pr-review-hosts.XXXXXX) || return 1
  yq -r 'keys | .[]' "$registry" >"$hosts_file" 2>/dev/null || {
    rm -f "$hosts_file"
    return 1
  }
  while IFS= read -r host <&3; do
    [ -n "$host" ] || continue
    manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT" 2>/dev/null || true)
    [ -n "$manifest" ] && [ -f "$manifest" ] || continue
    reviewer_profile=$(yaml_field "$manifest" reviewer_profile)
    [ "$reviewer_profile" = "true" ] || continue
    set +e
    "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$host" >/dev/null 2>&1
    eligibility_rc=$?
    set -e
    if [ "$eligibility_rc" -eq 0 ]; then
      printf '%s\n' "$host"
    else
      :
    fi
  done 3< "$hosts_file"
  rm -f "$hosts_file"
}

pr_json=$("$SCRIPT_DIR/studio-gh.sh" pr view "$PR" --json number,title,url,baseRefName,headRefName,headRefOid,author,commits) \
  || { printf 'pr-headless-review: failed to read PR %s\n' "$PR" >&2; exit 1; }
pr_num=$(printf '%s' "$pr_json" | jq -r '.number')
pr_url=$(printf '%s' "$pr_json" | jq -r '.url')
head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
PR_URL_FOR_EVENT="$pr_url"
PR_HEAD_SHA_FOR_EVENT="$head_sha"

hosts=()
if [ "$EXPLICIT_REVIEW_HOST" -eq 1 ] && [ "$CROSS_HOST_REQUIRED" -eq 0 ]; then
  eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
    printf '%s\n' "$eligibility" >&2
    printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
    exit 1
  }
  hosts+=("$REVIEW_HOST")
else
  while IFS= read -r host; do
    [ -n "$host" ] && hosts+=("$host")
  done < <(eligible_hosts)
fi
if [ "${#hosts[@]}" -gt 0 ]; then
  ELIGIBLE_REVIEW_HOSTS_CSV=$(join_csv "${hosts[@]}")
else
  ELIGIBLE_REVIEW_HOSTS_CSV=""
fi

if [ "$EXPLICIT_REVIEW_HOST" -eq 1 ]; then
  case ",$ELIGIBLE_REVIEW_HOSTS_CSV," in
    *,"$REVIEW_HOST",*) ;;
    *)
      eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
        printf '%s\n' "$eligibility" >&2
        printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
        exit 1
      }
      hosts+=("$REVIEW_HOST")
      ELIGIBLE_REVIEW_HOSTS_CSV=$(join_csv "${hosts[@]}")
      ;;
  esac
elif [ "${#hosts[@]}" -eq 0 ]; then
  printf 'pr-headless-review: no eligible reviewer hosts found\n' >&2
  exit 1
fi

cross_host_available=0
if [ "${#hosts[@]}" -gt 0 ]; then
  for host in "${hosts[@]}"; do
    if review_host_is_cross_family "$PARENT_HOST" "$host"; then
      cross_host_available=1
      break
    fi
  done
fi
if [ "$CROSS_HOST_REQUIRED" -eq 1 ] && [ "$PARENT_HOST" = "unknown" ] && [ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ]; then
  printf 'pr-headless-review: cross-host review required but PARENT_HOST is unknown; set STUDIO_PARENT_HOST or pass --allow-same-host-review --user-approved-bypass <url>\n' >&2
  exit 1
fi
if [ "$CROSS_HOST_REQUIRED" -eq 1 ] && [ "$cross_host_available" -eq 0 ] && [ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ]; then
  printf 'pr-headless-review: cross-host review required but no independent eligible reviewer exists for parent host %s\n' "$PARENT_HOST" >&2
  printf 'Add an independent reviewer adapter, or pass --allow-same-host-review --user-approved-bypass <url> after explicit user approval.\n' >&2
  exit 1
fi
if [ "$CROSS_HOST_REQUIRED" -eq 1 ] && [ "$EXPLICIT_REVIEW_HOST" -eq 1 ] \
    && ! review_host_is_cross_family "$PARENT_HOST" "$REVIEW_HOST" \
    && [ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ]; then
  printf 'pr-headless-review: cross-host review required; %s is same-family as parent host %s\n' "$REVIEW_HOST" "$PARENT_HOST" >&2
  printf 'Use an alternate --review-host, or pass --allow-same-host-review --user-approved-bypass <url> after explicit user approval.\n' >&2
  exit 1
fi

review_tmp_root="$REPO_ROOT/.studio-runtime/pr-headless-review"
mkdir -p "$review_tmp_root"
tmpdir=$(mktemp -d "$review_tmp_root/run.XXXXXX")
TMPDIR_TO_CLEAN="$tmpdir"
payload="$tmpdir/review-payload.md"
diff_payload="$tmpdir/pr.diff"
summary="$tmpdir/reviewer-summary.md"
reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"

"$SCRIPT_DIR/studio-gh.sh" pr diff "$PR" --patch > "$diff_payload"

write_pr_payload() {
  local mode="$1" policy_json="$2"
  local line_cap
  line_cap=$(printf '%s\n' "$policy_json" | jq -r '.budget.payload_diff_line_cap')
  printf '# Studio PR Review Payload\n\n'
  # shellcheck disable=SC2016
  printf 'Review context policy:\n\n```json\n%s\n```\n\n' "$(printf '%s' "$policy_json" | jq -c '.')"
  # shellcheck disable=SC2016
  printf 'Metadata:\n\n```json\n%s\n```\n\n' "$(printf '%s' "$pr_json" | jq -c '{number,title,url,baseRefName,headRefName,headRefOid,author}')"
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

This payload is diff-scoped by default. If the context is insufficient for a
safe verdict, print REVIEW_CONTEXT_FALLBACK=expanded and do not print a verdict;
the wrapper will rerun once with expanded context.

PROMPT
  if [ "$mode" = "expanded" ]; then
    printf '\nExpanded repo review rules:\n\n```md\n'
    sed -n '1,260p' "$REPO_ROOT/REVIEW.md"
    printf '\n```\n'
  fi
  printf '\nPR diff:\n\n```diff\n'
  if [ "$mode" = "summarized" ]; then
    sed -n "1,${line_cap}p" "$diff_payload"
    printf '\n--- diff summarized at %s lines; rerun with STUDIO_REVIEW_PAYLOAD_MODE=expanded for full context ---\n' "$line_cap"
  else
    cat "$diff_payload"
  fi
  printf '\n```\n'
}

policy_json=$(review_budget_policy_json pr "$diff_payload" "${STUDIO_REVIEW_PAYLOAD_MODE:-auto}")
write_pr_payload "$(printf '%s\n' "$policy_json" | jq -r '.mode')" "$policy_json" > "$payload"
PR_REVIEW_CONTEXT_JSON=$(review_budget_payload_stats_json "$payload" "$policy_json")
review_budget_emit_context_event studio "$PR" review_context_budget_resolved "$PR_REVIEW_CONTEXT_JSON" "pr-review-context:$pr_num:$head_sha"

run_review_candidate() {
  local candidate="$1" eligibility spawn_command verdict_count model_resolution
  local -a resolver_args
  REVIEW_HOST="$candidate"
  eligibility=$(STUDIO_INTERNAL_REVIEWER_SKIP_SMOKE=1 "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
    printf '%s\n' "$eligibility" > "$summary"
    printf 'pr-headless-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" > "$summary.err"
    append_failure "$REVIEW_HOST" "$summary" "$summary.err"
    return 1
  }
  manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
  spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
  [ -n "$spawn_command" ] || {
    printf 'pr-headless-review: missing spawn command for %s\n' "$REVIEW_HOST" > "$summary.err"
    append_failure "$REVIEW_HOST" "$summary" "$summary.err"
    return 1
  }
  resolver_args=(--review-host "$REVIEW_HOST" --implementation-host "$PARENT_HOST" --role reviewer.heavyweight)
  [ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ] || resolver_args+=(--allow-same-family)
  model_resolution=$("$SCRIPT_DIR/resolve-reviewer-model.sh" "${resolver_args[@]}" 2>&1) || {
    printf 'pr-headless-review: failed to resolve reviewer model for %s\n%s\n' "$REVIEW_HOST" "$model_resolution" > "$summary.err"
    append_failure "$REVIEW_HOST" "$summary" "$summary.err"
    return 1
  }
  # resolve-reviewer-model.sh is repo-owned and emits only %q-quoted shell assignments.
  eval "$model_resolution"

  # shellcheck disable=SC2206
  spawn_argv=( $spawn_command )
  case "$REVIEW_HOST" in
    codex*|*codex*)
      spawn_argv+=(-m "$REVIEWER_MODEL_ID" -c "model_reasoning_effort=$REVIEWER_MODEL_REASONING_EFFORT")
      ;;
    claude*|*claude*)
      spawn_argv+=(--model "$REVIEWER_MODEL_ID")
      ;;
  esac
  review_prompt="Read $payload, review PR $pr_url at HEAD $head_sha, and print STUDIO_REVIEW_VERDICT=<approved|approved_with_fixes|blocked>. If context is insufficient, print REVIEW_CONTEXT_FALLBACK=expanded instead."
  review_argv=("${spawn_argv[@]}")
  case "$REVIEW_HOST" in
    claude*|*claude*) review_argv+=("--add-dir=$tmpdir") ;;
  esac
  if review_host_run_command "$REVIEW_HOST" "$reviewer_home" \
      --env STUDIO_REVIEW_MODEL_ID "$REVIEWER_MODEL_ID" \
      --env STUDIO_REVIEW_REASONING_EFFORT "$REVIEWER_MODEL_REASONING_EFFORT" \
      --env STUDIO_REVIEW_PROVIDER_FAMILY "$REVIEWER_MODEL_PROVIDER_FAMILY" \
      --env REVIEW_PAYLOAD "$payload" \
      --env PR_URL "$pr_url" \
      --env PR_HEAD_SHA "$head_sha" \
      -- "${review_argv[@]}" "$review_prompt" > "$summary" 2>"$summary.err"; then
    review_rc=0
  else
    review_rc=$?
  fi
  if [ "$review_rc" -ne 0 ]; then
    append_failure "$REVIEW_HOST" "$summary" "$summary.err"
    return 1
  fi

  verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary" | wc -l | tr -d ' ')
  verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary")
  if [ "$verdict_count" = "0" ] \
      && grep -Eq '^REVIEW_CONTEXT_FALLBACK=expanded|INSUFFICIENT_CONTEXT' "$summary" \
      && [ "$(printf '%s\n' "$PR_REVIEW_CONTEXT_JSON" | jq -r '.mode')" != "expanded" ]; then
    policy_json=$(review_budget_policy_json pr "$diff_payload" expanded)
    write_pr_payload expanded "$policy_json" > "$payload"
    PR_REVIEW_CONTEXT_JSON=$(review_budget_payload_stats_json "$payload" "$policy_json")
    review_budget_emit_context_event studio "$PR" review_context_budget_resolved "$PR_REVIEW_CONTEXT_JSON" "pr-review-context-expanded:$pr_num:$head_sha"
    return 2
  fi
  if [ "$verdict_count" != "1" ]; then
    printf 'pr-headless-review: reviewer must emit exactly one STUDIO_REVIEW_VERDICT line (found %s)\n' "$verdict_count" > "$summary.err"
    append_failure "$REVIEW_HOST" "$summary" "$summary.err"
    return 1
  fi
  case "$verdict" in
    approved|approved_with_fixes|blocked) ;;
    *)
      printf 'pr-headless-review: reviewer did not emit a valid STUDIO_REVIEW_VERDICT line\n' > "$summary.err"
      append_failure "$REVIEW_HOST" "$summary" "$summary.err"
      return 1
      ;;
  esac
  REVIEW_MODEL_KEY_FOR_EVENT="$REVIEWER_MODEL_KEY"
  REVIEW_MODEL_ID_FOR_EVENT="$REVIEWER_MODEL_ID"
  REVIEW_MODEL_PROVIDER_FAMILY_FOR_EVENT="$REVIEWER_MODEL_PROVIDER_FAMILY"
  REVIEW_MODEL_REASONING_EFFORT_FOR_EVENT="$REVIEWER_MODEL_REASONING_EFFORT"
  return 0
}

candidates=()
if [ "$EXPLICIT_REVIEW_HOST" -eq 1 ]; then
  candidates=("$REVIEW_HOST")
else
  rotated=()
  start=$(( pr_num % ${#hosts[@]} ))
  i=0
  while [ "$i" -lt "${#hosts[@]}" ]; do
    rotated+=("${hosts[$(((start + i) % ${#hosts[@]}))]}")
    i=$((i + 1))
  done
  if [ "$CROSS_HOST_REQUIRED" -eq 1 ] && [ "$cross_host_available" -eq 1 ]; then
    for host in "${rotated[@]}"; do
      review_host_is_cross_family "$PARENT_HOST" "$host" && candidates+=("$host")
    done
    if [ "$ALLOW_SAME_HOST_REVIEW" -eq 1 ]; then
      for host in "${rotated[@]}"; do
        review_host_is_cross_family "$PARENT_HOST" "$host" || candidates+=("$host")
      done
    fi
  else
    candidates=("${rotated[@]}")
  fi
fi

selected=0
failed_hosts=()
for candidate in "${candidates[@]}"; do
  set +e
  run_review_candidate "$candidate"
  candidate_rc=$?
  set -e
  if [ "$candidate_rc" -eq 2 ]; then
    set +e
    run_review_candidate "$candidate"
    candidate_rc=$?
    set -e
  fi
  if [ "$candidate_rc" -eq 0 ]; then
    selected=1
    break
  fi
  failed_hosts+=("$candidate")
done
[ "$selected" -eq 1 ] || {
  printf 'pr-headless-review: no reviewer host produced a usable verdict\n' >&2
  print_reviewer_failure "$summary" "$summary.err"
  [ -n "$FALLBACK_FAILURES_TEXT" ] && printf 'pr-headless-review: failures: %s\n' "$FALLBACK_FAILURES_TEXT" >&2
  if [ "$CROSS_HOST_REQUIRED" -eq 1 ] && [ "$cross_host_available" -eq 1 ] && [ "$ALLOW_SAME_HOST_REVIEW" -eq 0 ]; then
    printf 'Use --allow-same-host-review --user-approved-bypass <url> after explicit user approval to fall back to same-host review.\n' >&2
  fi
  exit 1
}
if [ "${#failed_hosts[@]}" -gt 0 ]; then
  FALLBACK_FROM_CSV=$(join_csv "${failed_hosts[@]}")
else
  FALLBACK_FROM_CSV=""
fi
if review_host_is_cross_family "$PARENT_HOST" "$REVIEW_HOST"; then
  CROSS_HOST_FOR_EVENT="true"
else
  CROSS_HOST_FOR_EVENT="false"
fi
PR_REVIEW_VERDICT_FOR_EVENT="$verdict"
PR_REVIEW_TOKENS_JSON=$(collect_codex_review_tokens 2>/dev/null || true)
[ -n "$PR_REVIEW_TOKENS_JSON" ] || PR_REVIEW_TOKENS_JSON="null"

printf 'PR_REVIEW_HOST=%s\n' "$REVIEW_HOST"
printf 'PR_REVIEW_MANIFEST=%s\n' "$manifest"
printf 'PR_REVIEW_VERDICT=%s\n' "$verdict"
printf 'PR_REVIEW_PARENT_HOST=%s\n' "$PARENT_HOST"
printf 'PR_REVIEW_ELIGIBLE_HOSTS=%s\n' "$ELIGIBLE_REVIEW_HOSTS_CSV"
printf 'PR_REVIEW_CROSS_HOST=%s\n' "$CROSS_HOST_FOR_EVENT"
printf 'PR_REVIEW_MODEL_ID=%s\n' "$REVIEW_MODEL_ID_FOR_EVENT"
printf 'PR_REVIEW_REASONING_EFFORT=%s\n' "$REVIEW_MODEL_REASONING_EFFORT_FOR_EVENT"
[ -z "$FALLBACK_FROM_CSV" ] || printf 'PR_REVIEW_FALLBACK_FROM=%s\n' "$FALLBACK_FROM_CSV"

autopilot_args=(
  "$PR"
  --verdict "$verdict"
  --review-host "$REVIEW_HOST"
  --parent-host "$PARENT_HOST"
  --eligible-review-hosts "$ELIGIBLE_REVIEW_HOSTS_CSV"
  --cross-host "$CROSS_HOST_FOR_EVENT"
  --cross-host-required "$CROSS_HOST_REQUIRED"
  --review-model-id "$REVIEW_MODEL_ID_FOR_EVENT"
  --review-model-provider-family "$REVIEW_MODEL_PROVIDER_FAMILY_FOR_EVENT"
  --review-reasoning-effort "$REVIEW_MODEL_REASONING_EFFORT_FOR_EVENT"
  --reviewer-smoke-passed
  --summary-file "$summary"
  --expected-head-sha "$head_sha"
  --method "$METHOD"
)
[ -z "$FALLBACK_FROM_CSV" ] || autopilot_args+=(--fallback-from "$FALLBACK_FROM_CSV")
[ -z "$FALLBACK_FAILURES_TEXT" ] || autopilot_args+=(--fallback-failures "$FALLBACK_FAILURES_TEXT")
[ -z "$CROSS_HOST_BYPASS_URL" ] || autopilot_args+=(--cross-host-bypass-url "$CROSS_HOST_BYPASS_URL")
if [ "$ALLOW_TARGET_REPO_AUTO_MERGE" -eq 1 ]; then
  autopilot_args+=(--allow-target-repo-auto-merge --user-approved-bypass "$CROSS_HOST_BYPASS_URL")
fi
"$AUTOPILOT" "${autopilot_args[@]}"
