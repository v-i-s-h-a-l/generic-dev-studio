#!/usr/bin/env bash
# manager-release-branch.sh - manager-owned release branch preflight workflow.

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-github-transport.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-github-transport.sh"

PROJECT=""
REPO_ROOT=""
REMOTE="origin"
NO_FETCH=0

usage() {
  cat <<'EOF'
Usage:
  scripts/manager-release-branch.sh [--repo <path>] status --source <branch> --target <branch>
  scripts/manager-release-branch.sh [--repo <path>] prepare-release --release <version> --from <branch> [--create]
  scripts/manager-release-branch.sh [--repo <path>] sync --source <branch> --target <branch>
  scripts/manager-release-branch.sh [--repo <path>] pr --source <branch> --target <branch> [--title <title>] [--body <body>] [--create]

Global options:
  --project <slug>   Read project feature config for release branch defaults
  --repo <path>      Git checkout to inspect; default is current repo
  --remote <name>    Remote name; default origin
  --no-fetch         Do not fetch before checks

Preferred user-facing entrypoint:
  /dev-studio manager branch ...
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project requires value}"; shift 2 ;;
    --repo) REPO_ROOT="${2:?--repo requires value}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote requires value}"; shift 2 ;;
    --no-fetch) NO_FETCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
shift

resolve_repo_root() {
  if [ -n "$REPO_ROOT" ]; then
    (cd "$REPO_ROOT" && git rev-parse --show-toplevel) 2>/dev/null
    return $?
  fi
  git rev-parse --show-toplevel 2>/dev/null
}

REPO_ROOT=$(resolve_repo_root) || {
  printf 'manager-release-branch: run inside a git repo or pass --repo <path>\n' >&2
  exit 2
}

resolve_config_project() {
  if [ -n "$PROJECT" ]; then
    printf '%s\n' "$PROJECT"
    return 0
  fi
  ACHILLES_PROJECT="" git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  basename "$REPO_ROOT"
}

PROJECT=$(resolve_config_project || printf '')
if [ -n "$PROJECT" ]; then
  STUDIO_HOME=$(resolve_studio_home_for_login_home "${HOME:?HOME required}")
  FEATURE_CONFIG_FILE="${STUDIO_FEATURE_CONFIG_FILE:-$STUDIO_HOME/$PROJECT/config/features.env}"
  if [ -f "$FEATURE_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$FEATURE_CONFIG_FILE"
  fi
fi

release_pattern="${STUDIO_RELEASE_BRANCH_PATTERN:-release/{version}}"
default_base="${STUDIO_RELEASE_BRANCH_DEFAULT_BASE:-main}"

fetch_remote() {
  [ "$NO_FETCH" -eq 0 ] || return 0
  ( cd "$REPO_ROOT" && studio_git_transport_fetch --quiet "$REMOTE" "+refs/heads/*:refs/remotes/$REMOTE/*" ) 2>/dev/null || {
    printf 'manager-release-branch: fetch failed for remote %s\n' "$REMOTE" >&2
    return 2
  }
}

protected_branch() {
  case "$1" in
    main|master|trunk|develop) return 0 ;;
    *) return 1 ;;
  esac
}

remote_branch_exists() {
  local branch="$1"
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$branch" && return 0
  ( cd "$REPO_ROOT" && studio_git_transport_ls_remote --exit-code --heads "$REMOTE" "$branch" ) >/dev/null 2>&1
}

ref_for_branch() {
  local branch="$1"
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/$REMOTE/$branch^{commit}" >/dev/null; then
    printf 'refs/remotes/%s/%s\n' "$REMOTE" "$branch"
    return 0
  fi
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "$branch^{commit}" >/dev/null; then
    printf '%s\n' "$branch"
    return 0
  fi
  return 1
}

sha_for_ref() {
  git -C "$REPO_ROOT" rev-parse "$1^{commit}" 2>/dev/null
}

derive_target() {
  local release="$1" explicit="$2" target
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  [ -n "$release" ] || return 1
  target="${release_pattern//\{version\}/$release}"
  printf '%s\n' "$target"
}

print_branch_state() {
  local label="$1" branch="$2" ref sha
  if ref=$(ref_for_branch "$branch"); then
    sha=$(sha_for_ref "$ref")
    printf '%s: %s exists yes sha %s\n' "$label" "$branch" "$sha"
  else
    printf '%s: %s exists no\n' "$label" "$branch"
  fi
}

MERGE_STATUS=""
MERGE_CONFLICTS=""

check_mergeability() {
  local source="$1" target="$2" source_ref target_ref tmp wt out rc
  MERGE_STATUS=""
  MERGE_CONFLICTS=""
  source_ref=$(ref_for_branch "$source") || {
    MERGE_STATUS="source-missing"
    return 2
  }
  target_ref=$(ref_for_branch "$target") || {
    MERGE_STATUS="target-missing"
    return 2
  }
  tmp=$(mktemp -d -t studio-release-merge.XXXXXX) || return 2
  wt="$tmp/worktree"
  out="$tmp/merge.out"
  if ! git -C "$REPO_ROOT" worktree add --quiet --detach "$wt" "$target_ref" >"$out" 2>&1; then
    MERGE_STATUS="worktree-failed"
    MERGE_CONFLICTS=$(cat "$out")
    rm -rf "$tmp"
    return 2
  fi
  if git -C "$wt" merge --no-commit --no-ff "$source_ref" >"$out" 2>&1; then
    MERGE_STATUS="clean"
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    return 0
  fi
  MERGE_STATUS="conflicts"
  MERGE_CONFLICTS=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)
  [ -n "$MERGE_CONFLICTS" ] || MERGE_CONFLICTS=$(cat "$out")
  git -C "$wt" merge --abort >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  return 1
}

cmd_status() {
  local source="" target="" release="" rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source="${2:?--source requires value}"; shift 2 ;;
      --target) target="${2:?--target requires value}"; shift 2 ;;
      --release) release="${2:?--release requires value}"; shift 2 ;;
      *) printf 'manager-release-branch: status unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  target=$(derive_target "$release" "$target") || { printf 'manager-release-branch: status requires --target or --release\n' >&2; return 2; }
  fetch_remote || return $?
  printf 'release-branch status\n'
  printf 'repo: %s\n' "$REPO_ROOT"
  [ -n "$source" ] && print_branch_state source "$source"
  print_branch_state target "$target"
  if [ -n "$source" ]; then
    check_mergeability "$source" "$target" || rc=$?
    printf 'mergeability: %s\n' "$MERGE_STATUS"
    if [ "$MERGE_STATUS" = "conflicts" ]; then
      printf 'conflicts:\n%s\n' "$MERGE_CONFLICTS"
    fi
  fi
  return "$rc"
}

cmd_prepare_release() {
  local release="" target="" base="" create=0 base_ref base_sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --release) release="${2:?--release requires value}"; shift 2 ;;
      --target) target="${2:?--target requires value}"; shift 2 ;;
      --from|--base) base="${2:?--from requires value}"; shift 2 ;;
      --create|--yes) create=1; shift ;;
      --dry-run) create=0; shift ;;
      *) printf 'manager-release-branch: prepare-release unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$base" ] || base="$default_base"
  target=$(derive_target "$release" "$target") || { printf 'manager-release-branch: prepare-release requires --target or --release\n' >&2; return 2; }
  fetch_remote || return $?
  base_ref=$(ref_for_branch "$base") || { printf 'manager-release-branch: base branch not found: %s\n' "$base" >&2; return 2; }
  base_sha=$(sha_for_ref "$base_ref")
  printf 'release-branch prepare\n'
  printf 'target: %s\n' "$target"
  printf 'base: %s\n' "$base"
  printf 'base_sha: %s\n' "$base_sha"
  if remote_branch_exists "$target"; then
    printf 'status: exists\n'
    return 0
  fi
  if [ "$create" -eq 0 ]; then
    printf 'status: missing\n'
    printf 'dry-run: would create %s from %s (%s) on %s\n' "$target" "$base" "$base_sha" "$REMOTE"
    return 0
  fi
  if protected_branch "$target"; then
    printf 'manager-release-branch: refusing to create protected base branch: %s\n' "$target" >&2
    return 2
  fi
  ( cd "$REPO_ROOT" && studio_git_transport_push "$REMOTE" "$base_sha:refs/heads/$target" )
  printf 'status: created\n'
}

cmd_sync() {
  local source="" target="" release="" rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source="${2:?--source requires value}"; shift 2 ;;
      --target) target="${2:?--target requires value}"; shift 2 ;;
      --release) release="${2:?--release requires value}"; shift 2 ;;
      *) printf 'manager-release-branch: sync unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$source" ] || { printf 'manager-release-branch: sync requires --source\n' >&2; return 2; }
  target=$(derive_target "$release" "$target") || { printf 'manager-release-branch: sync requires --target or --release\n' >&2; return 2; }
  fetch_remote || return $?
  check_mergeability "$source" "$target" || rc=$?
  printf 'release-branch sync\n'
  printf 'source: %s\n' "$source"
  printf 'target: %s\n' "$target"
  printf 'mergeability: %s\n' "$MERGE_STATUS"
  if [ "$MERGE_STATUS" = "conflicts" ]; then
    printf 'conflicts:\n%s\n' "$MERGE_CONFLICTS"
  fi
  return "$rc"
}

cmd_pr() {
  local source="" target="" release="" title="" body="" create=0 rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source="${2:?--source requires value}"; shift 2 ;;
      --target) target="${2:?--target requires value}"; shift 2 ;;
      --release) release="${2:?--release requires value}"; shift 2 ;;
      --title) title="${2:?--title requires value}"; shift 2 ;;
      --body) body="${2:?--body requires value}"; shift 2 ;;
      --create|--yes) create=1; shift ;;
      --dry-run) create=0; shift ;;
      *) printf 'manager-release-branch: pr unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$source" ] || { printf 'manager-release-branch: pr requires --source\n' >&2; return 2; }
  target=$(derive_target "$release" "$target") || { printf 'manager-release-branch: pr requires --target or --release\n' >&2; return 2; }
  fetch_remote || return $?
  check_mergeability "$source" "$target" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'manager-release-branch: refusing PR; mergeability=%s\n' "$MERGE_STATUS" >&2
    [ "$MERGE_STATUS" = "conflicts" ] && printf 'conflicts:\n%s\n' "$MERGE_CONFLICTS" >&2
    return "$rc"
  fi
  [ -n "$title" ] || title="Merge $source into $target"
  [ -n "$body" ] || body="Prepared by /dev-studio manager branch pr."
  if [ "$create" -eq 0 ]; then
    printf 'release-branch pr\n'
    printf 'dry-run: would open PR head=%s base=%s title=%s\n' "$source" "$target" "$title"
    return 0
  fi
  "$SCRIPT_DIR/studio-gh.sh" pr create --head "$source" --base "$target" --title "$title" --body "$body"
}

case "$COMMAND" in
  status) cmd_status "$@" ;;
  prepare-release) cmd_prepare_release "$@" ;;
  sync) cmd_sync "$@" ;;
  pr) cmd_pr "$@" ;;
  *) printf 'manager-release-branch: unknown command: %s\n' "$COMMAND" >&2; usage >&2; exit 2 ;;
esac
