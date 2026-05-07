#!/usr/bin/env bash

feature_branch_policy_resolve_compare_ref() {
  local repo="${1:?usage: feature_branch_policy_resolve_compare_ref <repo> <base-ref>}"
  local base_ref="${2:?base ref required}"

  if git -C "$repo" rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$base_ref"
    return 0
  fi
  if git -C "$repo" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    printf '%s\n' "$base_ref"
    return 0
  fi
  return 1
}

feature_branch_policy_default_base_ref() {
  local repo="${1:?usage: feature_branch_policy_default_base_ref <repo> <branch>}"
  local branch="${2:?branch required}"
  local candidate origin_head

  origin_head=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$origin_head" ]; then
    origin_head="${origin_head#origin/}"
    if [ "$origin_head" != "$branch" ] && feature_branch_policy_resolve_compare_ref "$repo" "$origin_head" >/dev/null 2>&1; then
      printf '%s\n' "$origin_head"
      return 0
    fi
  fi

  for candidate in main master trunk develop; do
    [ "$candidate" = "$branch" ] && continue
    if feature_branch_policy_resolve_compare_ref "$repo" "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

feature_branch_policy_evaluate() {
  local repo="${1:?usage: feature_branch_policy_evaluate <repo> <branch> [base-ref] [context-label]}"
  local branch="${2:?branch required}"
  local base_hint="${3:-}"
  local context_label="${4:-feature branch}"
  local compare_ref=""

  FEATURE_BRANCH_POLICY_STATUS="passed"
  FEATURE_BRANCH_POLICY_BASE_REF=""
  FEATURE_BRANCH_POLICY_COMPARE_REF=""
  FEATURE_BRANCH_POLICY_DETAIL=""

  if is_protected_branch "$branch"; then
    FEATURE_BRANCH_POLICY_STATUS="skipped"
    FEATURE_BRANCH_POLICY_DETAIL="$context_label $branch is a protected integration/release branch; feature-branch merge-commit history is not audited here"
    return 0
  fi

  if [ -n "$base_hint" ]; then
    FEATURE_BRANCH_POLICY_BASE_REF="$base_hint"
  else
    FEATURE_BRANCH_POLICY_BASE_REF=$(feature_branch_policy_default_base_ref "$repo" "$branch" 2>/dev/null || true)
    if [ -z "$FEATURE_BRANCH_POLICY_BASE_REF" ]; then
      FEATURE_BRANCH_POLICY_STATUS="skipped"
      FEATURE_BRANCH_POLICY_DETAIL="$context_label $branch has no explicit integration base; skipped feature-branch merge-commit audit"
      return 0
    fi
  fi

  compare_ref=$(feature_branch_policy_resolve_compare_ref "$repo" "$FEATURE_BRANCH_POLICY_BASE_REF" 2>/dev/null || true)
  if [ -z "$compare_ref" ]; then
    FEATURE_BRANCH_POLICY_STATUS="skipped"
    FEATURE_BRANCH_POLICY_DETAIL="$context_label $branch could not resolve base ref $FEATURE_BRANCH_POLICY_BASE_REF locally or at origin/$FEATURE_BRANCH_POLICY_BASE_REF"
    return 0
  fi
  FEATURE_BRANCH_POLICY_COMPARE_REF="$compare_ref"

  if git -C "$repo" rev-list --merges "${compare_ref}..${branch}" 2>/dev/null | grep -q .; then
    FEATURE_BRANCH_POLICY_STATUS="failed"
    FEATURE_BRANCH_POLICY_DETAIL="$context_label $branch contains merge commits since $compare_ref; rebase or retarget dependent feature branches instead of merging feature-to-feature"
    return 1
  fi

  FEATURE_BRANCH_POLICY_DETAIL="$context_label $branch has no merge commits since $compare_ref"
  return 0
}
