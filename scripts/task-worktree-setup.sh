#!/usr/bin/env bash
# task-worktree-setup.sh — Step 3 of the Achilles task mode.
#
# Captures the explicit dispatch base, or falls back to the pre-dispatch
# ORIG_BRANCH + ORIG_HEAD from the shared main checkout, and creates the
# isolated worktree at `~/.dev-studio/<project>/worktrees/<task-id>`. Prints
# eval-able export lines the caller sources — matches argus-setup.sh's
# contract so downstream steps can pick up PROJECT/ORIG_BRANCH/ORIG_HEAD/
# WORKTREE without re-forking git.
#
# Usage:
#   eval "$(scripts/task-worktree-setup.sh <task-id> <repo-root> [base-branch])"
#
# Exit codes:
#   0  worktree created (or simulated under DRY_RUN=1)
#   4  feature-branch merge-commit policy blocked the selected base branch
#   2  missing args, repo-root not a git repo, or worktree add failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-feature-branch-policy.sh
. "$SCRIPT_DIR/lib-feature-branch-policy.sh"
# shellcheck source=lib-worktree-marker.sh
. "$SCRIPT_DIR/lib-worktree-marker.sh"

TASK_ID="${1:?usage: task-worktree-setup.sh <task-id> <repo-root>}"
REPO_ROOT="${2:?repo-root required}"
BASE_BRANCH="${3:-}"

[ -d "$REPO_ROOT/.git" ] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'error: %s is not a git repo\n' "$REPO_ROOT" >&2
  exit 2
}

PROJECT=$(basename "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)") \
  || { printf 'error: cannot resolve project slug from %s\n' "$REPO_ROOT" >&2; exit 2; }
if [ -n "$BASE_BRANCH" ]; then
  ORIG_BRANCH="$BASE_BRANCH"
  if ! ORIG_HEAD=$(git -C "$REPO_ROOT" rev-parse "$BASE_BRANCH" 2>/dev/null); then
    if ! ORIG_HEAD=$(git -C "$REPO_ROOT" rev-parse "origin/$BASE_BRANCH" 2>/dev/null); then
      printf 'error: dispatch base branch %s not found locally or at origin/%s\n' "$BASE_BRANCH" "$BASE_BRANCH" >&2
      exit 2
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
      printf 'DRY-RUN git branch %s origin/%s\n' "$BASE_BRANCH" "$BASE_BRANCH" >&2
    elif ! git -C "$REPO_ROOT" branch "$BASE_BRANCH" "origin/$BASE_BRANCH" >/dev/null 2>&1; then
      printf 'error: dispatch base branch %s exists only at origin/%s, but local branch creation failed\n' "$BASE_BRANCH" "$BASE_BRANCH" >&2
      exit 2
    fi
  fi
else
  ORIG_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) \
    || { printf 'error: git rev-parse --abbrev-ref HEAD failed\n' >&2; exit 2; }
  ORIG_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) \
    || { printf 'error: git rev-parse HEAD failed\n' >&2; exit 2; }
fi

if ! feature_branch_policy_evaluate "$REPO_ROOT" "$ORIG_BRANCH" "" "worktree base branch"; then
  if [ "${STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE:-0}" = "1" ]; then
    printf 'warning: %s (override STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1)\n' "$FEATURE_BRANCH_POLICY_DETAIL" >&2
  else
    printf 'error: %s\n' "$FEATURE_BRANCH_POLICY_DETAIL" >&2
    printf 'error: rebase or retarget the dependent branch before creating the task worktree, or set STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1 for an explicit escape hatch\n' >&2
    exit 4
  fi
fi

WORKTREE="$HOME/.dev-studio/$PROJECT/worktrees/$TASK_ID"
BRANCH="achilles/$TASK_ID"

if [ "${DRY_RUN:-0}" = "1" ]; then
  # Honors patterns/dry-run.md — log the mutation, still export the variables
  # so downstream dry-run steps have a stable $WORKTREE value to log against.
  printf 'DRY-RUN git worktree add %s -b %s %s\n' "$WORKTREE" "$BRANCH" "$ORIG_HEAD" >&2
else
  mkdir -p "$(dirname "$WORKTREE")" || {
    printf 'error: mkdir -p %s failed\n' "$(dirname "$WORKTREE")" >&2
    exit 2
  }
  # If the branch already exists (retry after crash), -B would clobber it;
  # prefer to fail loudly and let the caller decide. Keeping behavior parity
  # with the prose pre-extraction.
  if ! git -C "$REPO_ROOT" worktree add "$WORKTREE" -b "$BRANCH" "$ORIG_HEAD" >/dev/null 2>&1; then
    printf 'error: git worktree add %s -b %s %s failed\n' "$WORKTREE" "$BRANCH" "$ORIG_HEAD" >&2
    exit 2
  fi
  worktree_marker_write "$WORKTREE" worker --project "$PROJECT" --task-id "$TASK_ID" --host "${STUDIO_HOST:-}" --pid "$$" || {
    printf 'error: writing worktree marker for %s failed\n' "$WORKTREE" >&2
    exit 2
  }
fi

printf 'export PROJECT=%s\n' "$PROJECT"
printf 'export ORIG_BRANCH=%s\n' "$ORIG_BRANCH"
printf 'export ORIG_HEAD=%s\n' "$ORIG_HEAD"
printf 'export WORKTREE=%s\n' "$WORKTREE"
