#!/usr/bin/env bash
# pr-merge-finalize.sh — merge a reviewed PR through GitHub and refresh refs.
#
# Usage:
#   scripts/pr-merge-finalize.sh <pr-number-or-url> [--method auto|merge|squash|rebase] \
#       [--expected-head-sha <sha>] [--bypass-review --user-approved-bypass <url>]
#
# This script intentionally performs GitHub PR flow only. It never pushes a
# base branch directly. Branch deletion is delegated to gh pr merge
# --delete-branch, then local refs are refreshed with fetch --prune.

set -eu
umask 022

usage() {
  printf 'usage: pr-merge-finalize.sh <pr-number-or-url> [--method auto|merge|squash|rebase] [--expected-head-sha <sha>] [--bypass-review --user-approved-bypass <url>]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift

METHOD="auto"
EXPECTED_HEAD_SHA=""
BYPASS_REVIEW=0
USER_APPROVED_BYPASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method)
      METHOD="${2:?}"
      shift 2
      ;;
    --expected-head-sha)
      EXPECTED_HEAD_SHA="${2:?}"
      shift 2
      ;;
    --bypass-review)
      BYPASS_REVIEW=1
      shift
      ;;
    --user-approved-bypass)
      USER_APPROVED_BYPASS="${2:?}"
      shift 2
      ;;
    *)
      printf 'pr-merge-finalize: unknown flag %s\n' "$1" >&2
      usage
      ;;
  esac
done

case "$METHOD" in
  auto|merge|squash|rebase) ;;
  *) printf 'pr-merge-finalize: --method must be auto|merge|squash|rebase\n' >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

command -v gh >/dev/null 2>&1 || { printf 'pr-merge-finalize: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'pr-merge-finalize: jq is required\n' >&2; exit 1; }

STARTED_AT=$(date -u +%s)
number=""
url=""
head_sha=""
cleanup_failed=0
cleanup_notes=""
remote_merge_warning=""
commit_count=""
base_ref=""
head_ref=""

emit_pr_merge_event() {
  local event="$1" status="${2:-}" rc="${3:-0}" duration_s cleanup_json
  duration_s=$(( $(date -u +%s) - STARTED_AT ))
  cleanup_json=false
  [ "$cleanup_failed" = "0" ] || cleanup_json=true
  data=$(printf '{"pr":"%s","pr_number":"%s","pr_url":"%s","method":"%s","base_ref":"%s","head_ref":"%s","head_sha":"%s","commit_count":"%s","status":"%s","exit_code":%s,"duration_s":%s,"cleanup_failed":%s,"cleanup_notes":"%s","remote_merge_warning":"%s"}' \
    "$(_json_escape "$PR")" \
    "$(_json_escape "$number")" \
    "$(_json_escape "$url")" \
    "$(_json_escape "$METHOD")" \
    "$(_json_escape "$base_ref")" \
    "$(_json_escape "$head_ref")" \
    "$(_json_escape "$head_sha")" \
    "$(_json_escape "$commit_count")" \
    "$(_json_escape "$status")" \
    "$rc" \
    "$duration_s" \
    "$cleanup_json" \
    "$(_json_escape "$cleanup_notes")" \
    "$(_json_escape "$remote_merge_warning")")
  emit_event_keyed studio pr "$event" "$PR" "$data" \
    --idem-key "pr-merge-finalize:$event:$PR:$head_sha:$STARTED_AT" >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  local status="failed"
  [ "$rc" -eq 0 ] && status="completed"
  emit_pr_merge_event pr_merge_finalize_completed "$status" "$rc"
}
trap on_exit EXIT

current_worktree_path() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

worktree_path_for_branch() {
  local branch="$1"
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    /^worktree / { wt=substr($0, 10) }
    /^branch / && substr($0, 8) == b { print wt; exit }
  '
}

remove_stale_worktrees_for_branch() {
  local branch="$1" current_path="$2" cleanup_paths path
  cleanup_paths=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    /^worktree / { wt=substr($0, 10) }
    /^branch / && substr($0, 8) == b { print wt }
  ')
  [ -n "$cleanup_paths" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$path" = "$current_path" ] && continue
    git worktree remove "$path"
  done <<EOF
$cleanup_paths
EOF
}

detach_current_head_worktree_before_merge() {
  local current_branch
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current_branch" = "$head_ref" ] || return 0
  if [ -n "$(git status --porcelain)" ]; then
    cleanup_failed=1
    cleanup_notes="${cleanup_notes}head_worktree_detach_skipped_dirty;"
    return 0
  fi
  if ! git -c advice.detachedHead=false checkout --detach HEAD >/dev/null; then
    cleanup_failed=1
    cleanup_notes="${cleanup_notes}head_worktree_detach_failed;"
  fi
}

delete_remote_head_branch_after_merge() {
  [ -n "$head_ref" ] || return 0
  [ "$head_ref" != "$base_ref" ] || return 0
  if with_login_home_for_github git push origin --delete "$head_ref" >/dev/null 2>&1; then
    return 0
  fi
  if with_login_home_for_github git ls-remote --exit-code --heads origin "$head_ref" >/dev/null 2>&1; then
    cleanup_failed=1
    cleanup_notes="${cleanup_notes}remote_branch_delete_failed;"
  fi
}

json=$(with_login_home_for_github gh pr view "$PR" --json number,state,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,headRepositoryOwner,baseRefName,url,commits) \
  || { printf 'pr-merge-finalize: failed to read PR %s\n' "$PR" >&2; exit 1; }

state=$(printf '%s' "$json" | jq -r '.state')
is_draft=$(printf '%s' "$json" | jq -r '.isDraft')
mergeable=$(printf '%s' "$json" | jq -r '.mergeable')
merge_state=$(printf '%s' "$json" | jq -r '.mergeStateStatus')
base_ref=$(printf '%s' "$json" | jq -r '.baseRefName')
head_ref=$(printf '%s' "$json" | jq -r '.headRefName')
url=$(printf '%s' "$json" | jq -r '.url')
number=$(printf '%s' "$json" | jq -r '.number')
head_sha=$(printf '%s' "$json" | jq -r '.headRefOid')
commit_count=$(printf '%s' "$json" | jq -r '.commits | length')
emit_pr_merge_event pr_merge_finalize_started started 0
[ -z "$EXPECTED_HEAD_SHA" ] || [ "$head_sha" = "$EXPECTED_HEAD_SHA" ] || {
  printf 'pr-merge-finalize: refusing merge for PR #%s; reviewed HEAD_SHA=%s but current HEAD_SHA=%s\n' "$number" "$EXPECTED_HEAD_SHA" "$head_sha" >&2
  exit 1
}

[ "$state" = "OPEN" ] || { printf 'pr-merge-finalize: PR is not open (state=%s)\n' "$state" >&2; exit 1; }
[ "$is_draft" = "false" ] || { printf 'pr-merge-finalize: PR is draft\n' >&2; exit 1; }

case "$mergeable" in
  MERGEABLE|UNKNOWN) ;;
  *) printf 'pr-merge-finalize: PR is not mergeable (mergeable=%s)\n' "$mergeable" >&2; exit 1 ;;
esac

case "$merge_state" in
  CLEAN|HAS_HOOKS|UNSTABLE|UNKNOWN) ;;
  BLOCKED|DIRTY|DRAFT)
    printf 'pr-merge-finalize: PR has blocking merge state: %s\n' "$merge_state" >&2
    exit 1
    ;;
  *)
    printf 'pr-merge-finalize: refusing unknown merge state: %s\n' "$merge_state" >&2
    exit 1
    ;;
esac

gate_comment=$(with_login_home_for_github gh pr view "$PR" --json comments --jq '
  [.comments[]?
   | select(.body | contains("<!-- studio:pr-review-gate v1 -->"))
   | select(.body | test("STUDIO_REVIEW_GATE=(approved|approved_with_fixes)"))
   | select(.body | contains("HEAD_SHA='"$head_sha"'"))
  ] | last | .body // ""
') || { printf 'pr-merge-finalize: failed to read PR review gate comments\n' >&2; exit 1; }

if [ -z "$gate_comment" ]; then
  if [ "$BYPASS_REVIEW" -ne 1 ]; then
    printf 'pr-merge-finalize: refusing merge for PR #%s; no approved studio review gate comment found\n' "$number" >&2
    printf 'Run scripts/pr-autopilot.sh with a reviewer verdict for HEAD_SHA=%s, or pass --bypass-review --user-approved-bypass <url> after explicit user approval.\n' "$head_sha" >&2
    exit 1
  fi
  [ -n "$USER_APPROVED_BYPASS" ] || {
    printf 'pr-merge-finalize: --bypass-review requires --user-approved-bypass <url>\n' >&2
    exit 1
  }
  case "$USER_APPROVED_BYPASS" in
    https://github.com/*/issues/*|https://github.com/*/pull/*|https://github.com/*/discussions/*) ;;
    *) printf 'pr-merge-finalize: user-approved bypass must be a GitHub issue, PR, comment, or discussion URL\n' >&2; exit 1 ;;
  esac
  with_login_home_for_github gh pr comment "$PR" --body "$(cat <<EOF
<!-- studio:pr-review-gate v1 -->
STUDIO_REVIEW_GATE=bypassed
USER_APPROVED_BYPASS=$USER_APPROVED_BYPASS
NOTE=Review gate bypass was explicitly user-approved. Parent studio session performed the GitHub action.
EOF
)"
fi

if [ "$METHOD" = "auto" ]; then
  if [ "$commit_count" -lt 4 ]; then
    METHOD="rebase"
  elif [ "$base_ref" = "main" ]; then
    METHOD="merge"
  else
    METHOD="rebase"
  fi
fi

detach_current_head_worktree_before_merge

printf 'Merging PR via GitHub: %s\n' "$url"
remote_merge_warning=""
case "$METHOD" in
  merge)  merge_cmd=(with_login_home_for_github gh pr merge "$PR" --merge) ;;
  squash) merge_cmd=(with_login_home_for_github gh pr merge "$PR" --squash) ;;
  rebase) merge_cmd=(with_login_home_for_github gh pr merge "$PR" --rebase) ;;
esac
if ! "${merge_cmd[@]}"; then
  merged_state=$(with_login_home_for_github gh pr view "$PR" --json state --jq '.state' 2>/dev/null || true)
  if [ "$merged_state" != "MERGED" ]; then
    printf 'pr-merge-finalize: GitHub merge failed and PR is not merged (state=%s)\n' "${merged_state:-unknown}" >&2
    exit 1
  fi
  remote_merge_warning="gh_merge_returned_nonzero_after_remote_merge"
fi
delete_remote_head_branch_after_merge

current_path=$(current_worktree_path)
control_path=""
if ! with_login_home_for_github git fetch --prune origin; then
  cleanup_failed=1
  cleanup_notes="${cleanup_notes}fetch_prune_failed;"
fi
if ! with_login_home_for_github git fetch origin "$base_ref"; then
  cleanup_failed=1
  cleanup_notes="${cleanup_notes}fetch_base_failed;"
fi
current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
base_worktree=$(worktree_path_for_branch "$base_ref")
if [ -n "$base_worktree" ]; then
  control_path="$base_worktree"
elif [ "$current_branch" = "$base_ref" ]; then
  control_path="$current_path"
else
  if [ -z "$(git status --porcelain)" ]; then
    if git show-ref --verify --quiet "refs/heads/$base_ref"; then
      if ! git checkout "$base_ref"; then
        cleanup_failed=1
        cleanup_notes="${cleanup_notes}checkout_base_failed;"
      else
        current_branch="$base_ref"
      fi
    else
      if ! git checkout -b "$base_ref" "origin/$base_ref"; then
        cleanup_failed=1
        cleanup_notes="${cleanup_notes}checkout_base_failed;"
      else
        current_branch="$base_ref"
      fi
    fi
    if [ "$current_branch" = "$base_ref" ]; then
      control_path="$current_path"
    fi
  else
    cleanup_notes="${cleanup_notes}base_sync_skipped_dirty_worktree;"
  fi
fi
if [ -n "$control_path" ]; then
  if ! git -C "$control_path" merge --ff-only "origin/$base_ref"; then
    cleanup_failed=1
    cleanup_notes="${cleanup_notes}base_ff_failed;"
  fi
else
  cleanup_notes="${cleanup_notes}base_sync_skipped_no_control_worktree;"
fi
if ! remove_stale_worktrees_for_branch "$head_ref" "$current_path"; then
  cleanup_failed=1
  cleanup_notes="${cleanup_notes}local_worktree_remove_failed;"
fi
if git show-ref --verify --quiet "refs/heads/$head_ref"; then
  branch_repo="${control_path:-$current_path}"
  if git -C "$branch_repo" branch --merged "origin/$base_ref" 2>/dev/null | sed 's/^[* ]*//' | grep -Fx "$head_ref" >/dev/null; then
    if ! git -C "$branch_repo" branch -d "$head_ref"; then
      cleanup_failed=1
      cleanup_notes="${cleanup_notes}local_branch_delete_failed;"
    fi
  else
    cleanup_notes="${cleanup_notes}local_branch_not_merged;"
  fi
fi

printf 'PR_MERGED=1\n'
printf 'BASE_REF=%s\n' "$base_ref"
printf 'PR_COMMITS=%s\n' "$commit_count"
printf 'MERGE_METHOD=%s\n' "$METHOD"
[ -n "$remote_merge_warning" ] && printf 'REMOTE_MERGE_WARNING=%s\n' "$remote_merge_warning"
printf 'LOCAL_CLEANUP_FAILED=%s\n' "$cleanup_failed"
[ -n "$cleanup_notes" ] && printf 'LOCAL_CLEANUP_NOTES=%s\n' "$cleanup_notes"
exit 0
