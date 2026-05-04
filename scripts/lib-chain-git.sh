#!/usr/bin/env bash
# Git workspace helpers for studio-chain-runner issue sessions.

chain_git_prepare_issue_workspace() {
  local repo_root="${1:?usage: chain_git_prepare_issue_workspace <repo-root> <chain-worktree> <chain-branch> <issue-worktree> <issue-branch> <strategy>}"
  local chain_worktree="${2:?chain worktree required}"
  local chain_branch="${3:?chain branch required}"
  local issue_worktree="${4:?issue worktree required}"
  local issue_branch="${5:?issue branch required}"
  local strategy="${6:?git metadata strategy required}"

  case "$strategy" in
    linked-worktree)
      git -C "$repo_root" worktree remove --force "$issue_worktree" 2>/dev/null || rm -rf "$issue_worktree"
      git -C "$repo_root" worktree add -B "$issue_branch" "$issue_worktree" "$chain_branch"
      ;;
    local-clone)
      rm -rf "$issue_worktree"
      git clone --quiet --no-local --branch "$chain_branch" "$chain_worktree" "$issue_worktree"
      git -C "$issue_worktree" checkout -q -B "$issue_branch" "$chain_branch"
      ;;
    *)
      printf 'chain-git: unknown git metadata strategy: %s\n' "$strategy" >&2
      return 2
      ;;
  esac
}

chain_git_integrate_issue_workspace() {
  local repo_root="${1:?usage: chain_git_integrate_issue_workspace <repo-root> <chain-worktree> <chain-branch> <issue-worktree> <issue-branch> <strategy>}"
  local chain_worktree="${2:?chain worktree required}"
  local chain_branch="${3:?chain branch required}"
  local issue_worktree="${4:?issue worktree required}"
  local issue_branch="${5:?issue branch required}"
  local strategy="${6:?git metadata strategy required}"

  case "$strategy" in
    linked-worktree)
      git -C "$issue_worktree" rebase "$chain_branch"
      git -C "$chain_worktree" merge --ff-only "$issue_branch"
      git -C "$repo_root" worktree remove "$issue_worktree"
      git -C "$repo_root" branch -D "$issue_branch"
      ;;
    local-clone)
      git -C "$issue_worktree" fetch "$chain_worktree" "$chain_branch"
      git -C "$issue_worktree" rebase FETCH_HEAD
      git -C "$chain_worktree" fetch "$issue_worktree" "$issue_branch"
      git -C "$chain_worktree" merge --ff-only FETCH_HEAD
      rm -rf "$issue_worktree"
      ;;
    *)
      printf 'chain-git: unknown git metadata strategy: %s\n' "$strategy" >&2
      return 2
      ;;
  esac
}
