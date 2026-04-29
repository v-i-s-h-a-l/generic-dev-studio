#!/usr/bin/env bash
# pr-merge-finalize.sh — merge a reviewed PR through GitHub and refresh refs.
#
# Usage:
#   scripts/pr-merge-finalize.sh <pr-number-or-url> [--method auto|merge|squash|rebase] \
#       [--bypass-review --user-approved-bypass <url>]
#
# This script intentionally performs GitHub PR flow only. It never pushes a
# base branch directly. Branch deletion is delegated to gh pr merge
# --delete-branch, then local refs are refreshed with fetch --prune.

set -eu
umask 022

usage() {
  printf 'usage: pr-merge-finalize.sh <pr-number-or-url> [--method auto|merge|squash|rebase] [--bypass-review --user-approved-bypass <url>]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift

METHOD="auto"
BYPASS_REVIEW=0
USER_APPROVED_BYPASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method)
      METHOD="${2:?}"
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

command -v gh >/dev/null 2>&1 || { printf 'pr-merge-finalize: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'pr-merge-finalize: jq is required\n' >&2; exit 1; }

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

json=$(gh pr view "$PR" --json number,state,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,headRepositoryOwner,baseRefName,url,commits) \
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

gate_comment=$(gh pr view "$PR" --json comments --jq '
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
  gh pr comment "$PR" --body "$(cat <<EOF
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

printf 'Merging PR via GitHub: %s\n' "$url"
remote_merge_warning=""
case "$METHOD" in
  merge)  merge_cmd=(gh pr merge "$PR" --merge --delete-branch) ;;
  squash) merge_cmd=(gh pr merge "$PR" --squash --delete-branch) ;;
  rebase) merge_cmd=(gh pr merge "$PR" --rebase --delete-branch) ;;
esac
if ! "${merge_cmd[@]}"; then
  merged_state=$(gh pr view "$PR" --json state --jq '.state' 2>/dev/null || true)
  if [ "$merged_state" != "MERGED" ]; then
    printf 'pr-merge-finalize: GitHub merge failed and PR is not merged (state=%s)\n' "${merged_state:-unknown}" >&2
    exit 1
  fi
  remote_merge_warning="gh_merge_returned_nonzero_after_remote_merge"
fi

cleanup_failed=0
cleanup_notes=""
current_path=$(current_worktree_path)
control_path=""
if ! git fetch --prune origin; then
  cleanup_failed=1
  cleanup_notes="${cleanup_notes}fetch_prune_failed;"
fi
if ! git fetch origin "$base_ref"; then
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
