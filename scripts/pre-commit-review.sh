#!/usr/bin/env bash
# pre-commit-review.sh — run an eligible no-secret reviewer on the staged diff.
#
# Usage:
#   scripts/pre-commit-review.sh [--review-host <host>] [--bypass-review]
#
# The reviewer sees only a generated payload and the staged patch. The parent
# shell owns the commit and any audit event emission.

set -u
umask 022

usage() {
  printf 'usage: pre-commit-review.sh [--review-host <host>] [--bypass-review]\n' >&2
  exit 2
}

REVIEW_HOST="${STUDIO_REVIEW_HOST:-}"
BYPASS_REVIEW=0
REVIEW_STARTED_AT=$(date +%s)
REVIEW_CONTEXT_JSON="null"
REVIEW_PAYLOAD_STORAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --bypass-review) BYPASS_REVIEW=1; shift ;;
    *) printf 'pre-commit-review: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

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

yaml_field() {
  local file="$1" key="$2"
  grep -E "^${key}:[[:space:]]" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | tr -d '"'"'"
}

print_reviewer_failure() {
  local stdout_file="$1" stderr_file="$2"
  printf 'pre-commit-review: reviewer host failed: %s\n' "$REVIEW_HOST" >&2
  if [ -s "$stderr_file" ]; then
    printf 'pre-commit-review: reviewer stderr (first 80 lines):\n' >&2
    sed -n '1,80p' "$stderr_file" >&2 || true
  fi
  if [ -s "$stdout_file" ]; then
    printf 'pre-commit-review: reviewer stdout (first 80 lines):\n' >&2
    sed -n '1,80p' "$stdout_file" >&2 || true
  fi
  if [ ! -s "$stderr_file" ] && [ ! -s "$stdout_file" ]; then
    printf 'pre-commit-review: reviewer produced no stdout/stderr before exit\n' >&2
  fi
}

emit_gate_event() {
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local event="$1" verdict="$2" host="$3" patch_id="$4" bypass_source="${5:-}" status="${6:-}" failure_kind="${7:-}" reason="${8:-}"
  local data duration_s
  duration_s=$(( $(date +%s) - REVIEW_STARTED_AT ))
  [ "$duration_s" -ge 0 ] && [ "$duration_s" -le 86400 ] || duration_s=""
  if command -v jq >/dev/null 2>&1; then
    data=$(jq -cn \
      --arg verdict "$verdict" \
      --arg host "$host" \
      --arg branch "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" \
      --arg head "$(git rev-parse --short HEAD 2>/dev/null || true)" \
      --arg patch_id "$patch_id" \
      --arg bypass_source "$bypass_source" \
      --arg status "$status" \
      --arg failure_kind "$failure_kind" \
      --arg reason "$reason" \
      --arg payload_storage "$REVIEW_PAYLOAD_STORAGE" \
      --arg duration_s "$duration_s" \
      --argjson review_context "$REVIEW_CONTEXT_JSON" \
      '{verdict:$verdict,review_host:$host,branch:$branch,head:$head,patch_id:$patch_id,bypass_source:$bypass_source}
       + (if $duration_s == "" then {} else {duration_s:($duration_s|tonumber)} end)
       + (if $status == "" then {} else {status:$status} end)
       + (if $failure_kind == "" then {} else {failure_kind:$failure_kind} end)
       + (if $reason == "" then {} else {reason:$reason} end)
       + (if $payload_storage == "" then {} else {payload_storage:$payload_storage} end)
       + (if $review_context == null then {} else {review_context:$review_context} end)')
  else
    data="{\"verdict\":\"$verdict\",\"review_host\":\"$host\",\"patch_id\":\"$patch_id\",\"bypass_source\":\"$bypass_source\""
    [ -n "$duration_s" ] && data="$data,\"duration_s\":$duration_s"
    [ -n "$status" ] && data="$data,\"status\":\"$status\""
    [ -n "$failure_kind" ] && data="$data,\"failure_kind\":\"$failure_kind\""
    [ -n "$reason" ] && data="$data,\"reason\":\"$reason\""
    [ -n "$REVIEW_PAYLOAD_STORAGE" ] && data="$data,\"payload_storage\":\"$REVIEW_PAYLOAD_STORAGE\""
    data="$data}"
  fi
  local idem_key="precommit:$event:$patch_id"
  [ "$event" != "precommit_review_failed" ] || idem_key="$idem_key:$host:$reason"
  emit_event_keyed studio commit "$event" "" "$data" --idem-key "$idem_key" >/dev/null 2>&1 || true
}

fail_gate() {
  local reason="$1" message="$2" code="${3:-1}"
  [ -z "$message" ] || printf 'pre-commit-review: %s\n' "$message" >&2
  emit_gate_event precommit_review_failed infrastructure_failed "${REVIEW_HOST:-unknown}" "${patch_id:-unknown}" "" failed infrastructure "$reason"
  exit "$code"
}

sanitize_runtime_slug() {
  local raw="$1" slug
  slug=$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9._-' '-' | sed -e 's/^-*//' -e 's/-*$//')
  [ -n "$slug" ] && printf '%s\n' "$slug" || printf 'unknown\n'
}

chain_task_project_slug() {
  local start_path source_url repo
  start_path="$PWD/.studio/chain-task-start.json"
  [ -r "$start_path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  source_url=$(jq -r '.source_issue.url // empty' "$start_path" 2>/dev/null || true)
  case "$source_url" in
    https://github.com/*/*/issues/*|https://github.com/*/*/pull/*)
      repo=$(printf '%s\n' "$source_url" | sed -E 's#^https://github.com/[^/]+/([^/]+)/(issues|pull)/.*$#\1#')
      ;;
    *)
      repo=""
      ;;
  esac
  [ -n "$repo" ] || return 1
  sanitize_runtime_slug "$repo"
}

precommit_review_project_slug() {
  local slug
  slug=$(chain_task_project_slug 2>/dev/null || true)
  [ -n "$slug" ] || slug=$(resolve_display_name 2>/dev/null || true)
  [ -n "$slug" ] || slug=$(resolve_project 2>/dev/null || true)
  sanitize_runtime_slug "${slug:-unknown}"
}

precommit_review_payload_parent() {
  local project_slug
  studio_context_resolve runtime-mutation || return 1
  project_slug=$(precommit_review_project_slug)
  printf '%s/%s/.runtime/reviewer-payloads/pre-commit\n' "$STUDIO_CONTEXT_STUDIO_HOME" "$project_slug"
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

if git diff --cached --quiet --exit-code; then
  printf 'pre-commit-review: no staged diff; skipping reviewer gate\n' >&2
  exit 0
fi

patch_id=$(git diff --cached --patch | git patch-id --stable 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$patch_id" ] || patch_id="unknown"

if [ "${STUDIO_BYPASS_REVIEW:-0}" = "1" ] || [ "$BYPASS_REVIEW" -eq 1 ]; then
  source="env"
  [ "$BYPASS_REVIEW" -eq 1 ] && source="flag"
  printf 'pre-commit-review: STUDIO REVIEW GATE BYPASSED by explicit user override (%s)\n' "$source" >&2
  emit_gate_event precommit_review_bypassed bypassed "${REVIEW_HOST:-none}" "$patch_id" "$source" bypassed "" ""
  exit 0
fi

command -v yq >/dev/null 2>&1 || fail_gate missing_yq "yq is required"
command -v jq >/dev/null 2>&1 || fail_gate missing_jq "jq is required"

if [ -z "$REVIEW_HOST" ]; then
  hosts=()
  while IFS= read -r host; do
    [ -n "$host" ] && hosts+=("$host")
  done < <(eligible_hosts)
  [ "${#hosts[@]}" -gt 0 ] || {
    printf 'pre-commit-review: no eligible reviewer hosts found\n' >&2
    printf 'bypass (explicit user override only): STUDIO_BYPASS_REVIEW=1 git commit ...\n' >&2
    emit_gate_event precommit_review_failed infrastructure_failed none "$patch_id" "" failed infrastructure no_eligible_reviewer_hosts
    exit 1
  }
  REVIEW_HOST="${hosts[0]}"
fi

eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
  printf '%s\n' "$eligibility" >&2
  fail_gate reviewer_ineligible "reviewer host is not eligible: $REVIEW_HOST"
}
manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || fail_gate missing_spawn_command "missing spawn command for $REVIEW_HOST"

payload_parent=$(precommit_review_payload_parent) \
  || fail_gate payload_runtime_unavailable "Studio runtime context unavailable for reviewer payload handoff"
mkdir -p "$payload_parent" \
  || fail_gate payload_runtime_unavailable "failed to create reviewer payload root"
tmpdir=$(mktemp -d "$payload_parent/run.XXXXXX") \
  || fail_gate payload_runtime_unavailable "failed to create reviewer payload directory"
REVIEW_PAYLOAD_STORAGE="studio-runtime"
# shellcheck disable=SC2329
cleanup_tmpdir() {
  [ "${STUDIO_KEEP_REVIEW_PAYLOADS:-0}" = "1" ] || rm -rf "$tmpdir"
}
trap cleanup_tmpdir EXIT
payload="$tmpdir/review-payload.md"
diff_payload="$tmpdir/staged.diff"
summary="$tmpdir/reviewer-summary.md"
reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"

git diff --cached --patch > "$diff_payload"

write_precommit_payload() {
  local mode="$1" policy_json="$2"
  local line_cap
  line_cap=$(printf '%s\n' "$policy_json" | jq -r '.budget.payload_diff_line_cap')
  printf '# Studio Pre-Commit Review Payload\n\n'
  # shellcheck disable=SC2016
  printf 'Review context policy:\n\n```json\n%s\n```\n\n' "$(printf '%s' "$policy_json" | jq -c '.')"
  printf 'Metadata:\n\n'
  printf '%s\n' "- repository: $(basename "$REPO_ROOT")"
  printf '%s\n' "- branch: $(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf unknown)"
  printf '%s\n' "- head: $(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf '%s\n\n' "- patch_id: $patch_id"
  cat <<'PROMPT'
Review this staged studio diff against REVIEW.md and the repository-specific rules.

Return a concise report with exactly one machine-readable verdict line:

STUDIO_REVIEW_VERDICT=approved
STUDIO_REVIEW_VERDICT=approved_with_fixes
STUDIO_REVIEW_VERDICT=blocked

Use `blocked` only for critical blockers: data loss, broken routing, unsafe
runtime behavior, permission/auth changes, base-branch bypass, failing required
checks, merge conflicts, or repo-rule violations. This is a pre-commit review:
do not edit files, do not stage files, do not commit, and do not bypass this
gate.

This payload is diff-scoped by default. If the context is insufficient for a
safe verdict, print REVIEW_CONTEXT_FALLBACK=expanded and do not print a verdict;
the wrapper will rerun once with expanded context.

PROMPT
  if [ "$mode" = "expanded" ]; then
    printf '\nExpanded repo review rules:\n\n```md\n'
    sed -n '1,260p' "$REPO_ROOT/REVIEW.md"
    printf '\n```\n'
  fi
  printf '\nStaged diff:\n\n```diff\n'
  if [ "$mode" = "summarized" ]; then
    sed -n "1,${line_cap}p" "$diff_payload"
    printf '\n--- diff summarized at %s lines; rerun with STUDIO_REVIEW_PAYLOAD_MODE=expanded for full context ---\n' "$line_cap"
  else
    cat "$diff_payload"
  fi
  printf '\n```\n'
}

policy_json=$(review_budget_policy_json precommit "$diff_payload" "${STUDIO_REVIEW_PAYLOAD_MODE:-auto}")
write_precommit_payload "$(printf '%s\n' "$policy_json" | jq -r '.mode')" "$policy_json" > "$payload"
REVIEW_CONTEXT_JSON=$(review_budget_payload_stats_json "$payload" "$policy_json")
review_budget_emit_context_event studio "$patch_id" review_context_budget_resolved "$REVIEW_CONTEXT_JSON" "precommit-review-context:$patch_id"

# shellcheck disable=SC2206
spawn_argv=( $spawn_command )
review_prompt="Read $payload, review the staged studio diff, and print STUDIO_REVIEW_VERDICT=<approved|approved_with_fixes|blocked>. If context is insufficient, print REVIEW_CONTEXT_FALLBACK=expanded instead."
review_argv=("${spawn_argv[@]}")
case "$REVIEW_HOST" in
  codex*|*codex*) review_argv+=(--add-dir "$tmpdir") ;;
  claude*|*claude*) review_argv+=("--add-dir=$tmpdir") ;;
esac
review_cmd=(review_host_run_command "$REVIEW_HOST" "$reviewer_home" --env REVIEW_PAYLOAD "$payload" --env STAGED_PATCH_ID "$patch_id" -- "${review_argv[@]}" "$review_prompt")

run_precommit_reviewer() {
  "${review_cmd[@]}" > "$summary" 2>"$summary.err"
}

if ! run_precommit_reviewer; then
  print_reviewer_failure "$summary" "$summary.err"
  fail_gate reviewer_command_failed ""
fi

verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary" | wc -l | tr -d ' ')
verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary")
if [ "$verdict_count" = "0" ] \
    && grep -Eq '^REVIEW_CONTEXT_FALLBACK=expanded|INSUFFICIENT_CONTEXT' "$summary" \
    && [ "$(printf '%s\n' "$REVIEW_CONTEXT_JSON" | jq -r '.mode')" != "expanded" ]; then
  policy_json=$(review_budget_policy_json precommit "$diff_payload" expanded)
  write_precommit_payload expanded "$policy_json" > "$payload"
  REVIEW_CONTEXT_JSON=$(review_budget_payload_stats_json "$payload" "$policy_json")
  review_budget_emit_context_event studio "$patch_id" review_context_budget_resolved "$REVIEW_CONTEXT_JSON" "precommit-review-context-expanded:$patch_id"
  if ! run_precommit_reviewer; then
    print_reviewer_failure "$summary" "$summary.err"
    fail_gate reviewer_command_failed ""
  fi
  verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary" | wc -l | tr -d ' ')
  verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary")
fi
if [ "$verdict_count" != "1" ]; then
  printf 'pre-commit-review: reviewer must emit exactly one STUDIO_REVIEW_VERDICT line (found %s)\n' "$verdict_count" >&2
  sed -n '1,120p' "$summary" >&2 || true
  fail_gate reviewer_no_verdict ""
fi

case "$verdict" in
  approved|approved_with_fixes)
    printf 'PRECOMMIT_REVIEW_HOST=%s\n' "$REVIEW_HOST"
    printf 'PRECOMMIT_REVIEW_MANIFEST=%s\n' "$manifest"
    printf 'PRECOMMIT_REVIEW_VERDICT=%s\n' "$verdict"
    printf 'PRECOMMIT_REVIEW_STATUS=passed\n'
    printf 'PRECOMMIT_REVIEW_PAYLOAD_STORAGE=%s\n' "$REVIEW_PAYLOAD_STORAGE"
    sed -n '1,120p' "$summary"
    emit_gate_event precommit_review_passed "$verdict" "$REVIEW_HOST" "$patch_id" "" passed "" ""
    ;;
  blocked)
    printf 'pre-commit-review: reviewer blocked commit\n' >&2
    sed -n '1,120p' "$summary" >&2 || true
    emit_gate_event precommit_review_blocked "$verdict" "$REVIEW_HOST" "$patch_id" "" blocked "" ""
    exit 1
    ;;
  *)
    printf 'pre-commit-review: reviewer did not emit a valid STUDIO_REVIEW_VERDICT line\n' >&2
    sed -n '1,120p' "$summary" >&2 || true
    fail_gate reviewer_invalid_verdict ""
    ;;
esac

exit 0
