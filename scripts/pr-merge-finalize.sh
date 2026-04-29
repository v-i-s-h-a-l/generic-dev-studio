#!/usr/bin/env bash
# pr-merge-finalize.sh — merge a reviewed PR through GitHub and refresh refs.
#
# Usage:
#   scripts/pr-merge-finalize.sh <pr-number-or-url> [--method merge|squash|rebase]
#
# This script intentionally performs GitHub PR flow only. It never pushes a
# base branch directly. Branch deletion is delegated to gh pr merge
# --delete-branch, then local refs are refreshed with fetch --prune.

set -u
umask 022

usage() {
  printf 'usage: pr-merge-finalize.sh <pr-number-or-url> [--method merge|squash|rebase]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
PR="$1"
shift

METHOD="squash"
while [ $# -gt 0 ]; do
  case "$1" in
    --method)
      METHOD="${2:?}"
      shift 2
      ;;
    *)
      printf 'pr-merge-finalize: unknown flag %s\n' "$1" >&2
      usage
      ;;
  esac
done

case "$METHOD" in
  merge|squash|rebase) ;;
  *) printf 'pr-merge-finalize: --method must be merge|squash|rebase\n' >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { printf 'pr-merge-finalize: gh is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'pr-merge-finalize: jq is required\n' >&2; exit 1; }

json=$(gh pr view "$PR" --json number,state,isDraft,mergeable,mergeStateStatus,headRefName,headRepositoryOwner,baseRefName,url) \
  || { printf 'pr-merge-finalize: failed to read PR %s\n' "$PR" >&2; exit 1; }

state=$(printf '%s' "$json" | jq -r '.state')
is_draft=$(printf '%s' "$json" | jq -r '.isDraft')
mergeable=$(printf '%s' "$json" | jq -r '.mergeable')
merge_state=$(printf '%s' "$json" | jq -r '.mergeStateStatus')
base_ref=$(printf '%s' "$json" | jq -r '.baseRefName')
url=$(printf '%s' "$json" | jq -r '.url')

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

printf 'Merging PR via GitHub: %s\n' "$url"
case "$METHOD" in
  merge)  gh pr merge "$PR" --merge --delete-branch ;;
  squash) gh pr merge "$PR" --squash --delete-branch ;;
  rebase) gh pr merge "$PR" --rebase --delete-branch ;;
esac

git fetch --prune origin
git fetch origin main
printf 'PR_MERGED=1\n'
printf 'BASE_REF=%s\n' "$base_ref"
