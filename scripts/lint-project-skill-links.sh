#!/usr/bin/env bash
# lint-project-skill-links.sh - enforce repo-local project skill links.
#
# For every skill with portability.yaml scope: project, each declared host must
# have a project_skill_dir entry in hosts/registry.yaml and a repo-local symlink
# at <project_skill_dir>/<skill-name> pointing at the canonical skill dir.
#
# Usage:
#   scripts/lint-project-skill-links.sh [--staged] [--host <host>] [--repair]
#
# Exit 0: all project links are present. Exit 1: invariant drift. Exit 2: bad
# invocation or missing tooling.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/hosts/registry.yaml"

STAGED=0
HOST_FILTER=""
REPAIR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --staged) STAGED=1 ;;
    --repair) REPAIR=1 ;;
    --host)
      shift
      [ $# -gt 0 ] || { printf 'lint-project-skill-links: --host needs a value\n' >&2; exit 2; }
      HOST_FILTER="$1"
      ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      printf 'lint-project-skill-links: unknown argument %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v yq >/dev/null 2>&1; then
  printf 'lint-project-skill-links: yq is required\n' >&2
  exit 2
fi
[ -f "$REGISTRY" ] || { printf 'lint-project-skill-links: %s missing\n' "$REGISTRY" >&2; exit 2; }

ERRORS=0

emit_error() {
  printf '%s\n' "$1" >&2
  ERRORS=$((ERRORS + 1))
}

candidate_roots() {
  ( cd "$REPO_ROOT" && {
      find core/v2/skills skills/owned skills/vendored \
        -maxdepth 4 -name 'SKILL.md' -type f 2>/dev/null
    } \
    | while IFS= read -r f; do dirname "$f"; done \
    | sort -u )
}

resolve_symlink_target() {
  # $1 = symlink path. Prints an absolute target path, resolving relative
  # symlinks from the link's containing directory.
  local link="$1" raw dir base
  raw=$(readlink "$link") || return 1
  case "$raw" in
    /*) printf '%s\n' "$raw" ;;
    *)
      dir=$(dirname "$link")
      base=$(basename "$raw")
      ( cd "$dir" && cd "$(dirname "$raw")" && printf '%s/%s\n' "$(pwd -P)" "$base" )
      ;;
  esac
}

canonical_path() {
  # $1 = existing absolute path. Prints the path with a physical parent, so
  # macOS /var and /private/var spellings compare equal.
  local path="$1" dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  ( cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base" )
}

symlink_points_to() {
  # $1 = symlink path, $2 = expected absolute target path.
  local actual expected
  [ -L "$1" ] || return 1
  actual=$(resolve_symlink_target "$1" 2>/dev/null || true)
  [ -e "$actual" ] && actual=$(canonical_path "$actual" 2>/dev/null || printf '%s\n' "$actual")
  expected=$(canonical_path "$2" 2>/dev/null || printf '%s\n' "$2")
  [ "$actual" = "$expected" ]
}

link_target_for() {
  # $1 = canonical absolute source, $2 = absolute destination. Project-scoped
  # links inside this repo are relative so committed host links survive cloned
  # checkouts and worktree cleanup.
  local src="$1" dst="$2" src_rel dst_dir dst_rel ups n i
  case "$src:$dst" in
    "$REPO_ROOT"/*:"$REPO_ROOT"/*)
      src_rel="${src#"$REPO_ROOT/"}"
      dst_dir=$(dirname "$dst")
      dst_rel="${dst_dir#"$REPO_ROOT/"}"
      if [ "$dst_rel" = "$dst_dir" ] || [ -z "$dst_rel" ]; then
        printf '%s\n' "$src_rel"
        return
      fi
      n=$(printf '%s\n' "$dst_rel" | awk -F/ '{print NF}')
      ups=""
      i=0
      while [ "$i" -lt "$n" ]; do
        ups="../$ups"
        i=$((i + 1))
      done
      printf '%s%s\n' "$ups" "$src_rel"
      ;;
    *)
      printf '%s\n' "$src"
      ;;
  esac
}

repair_missing_link() {
  # $1 = canonical absolute source, $2 = absolute destination.
  local src="$1" dst="$2" link_target
  [ "$REPAIR" -eq 1 ] || return 1
  [ ! -e "$dst" ] && [ ! -L "$dst" ] || return 1
  mkdir -p "$(dirname "$dst")" || return 1
  link_target=$(link_target_for "$src" "$dst")
  ln -s "$link_target" "$dst" || return 1
  symlink_points_to "$dst" "$src"
}

registry_hosts() {
  yq -r 'keys | .[]' "$REGISTRY" 2>/dev/null
}

skill_scope() {
  local rel="$1"
  local portability="$REPO_ROOT/$rel/portability.yaml"
  local scope
  [ -f "$portability" ] || { printf 'global\n'; return; }
  scope=$(yq -r '.scope // "global"' "$portability" 2>/dev/null)
  [ -z "$scope" ] || [ "$scope" = "null" ] && scope="global"
  printf '%s\n' "$scope"
}

skill_declared_hosts() {
  local rel="$1"
  local portability="$REPO_ROOT/$rel/portability.yaml"
  local host all_hosts
  [ -f "$portability" ] || return 0
  while IFS= read -r host; do
    [ -z "$host" ] || [ "$host" = "null" ] && continue
    if [ "$host" = "all" ]; then
      all_hosts=$(registry_hosts)
      printf '%s\n' "$all_hosts"
    else
      printf '%s\n' "$host"
    fi
  done < <(yq -r '.hosts[]?' "$portability" 2>/dev/null)
}

project_skill_dir_for_host() {
  local host="$1" path
  path=$(yq -r ".\"$host\".project_skill_dir // \"\"" "$REGISTRY" 2>/dev/null)
  [ -z "$path" ] || [ "$path" = "null" ] && return 1
  printf '%s\n' "$REPO_ROOT/$path"
}

host_exists() {
  local host="$1"
  registry_hosts | grep -Fxq "$host"
}

check_project_skill() {
  local rel="$1" name host project_dir target
  name=$(basename "$rel")
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    if [ -n "$HOST_FILTER" ] && [ "$host" != "$HOST_FILTER" ]; then continue; fi
    if ! host_exists "$host"; then
      emit_error "E_PROJECT_SKILL_HOST:$rel declares unknown host=$host | add host to hosts/registry.yaml or remove it from portability.yaml"
      continue
    fi
    project_dir=$(project_skill_dir_for_host "$host" || true)
    if [ -z "$project_dir" ]; then
      emit_error "E_PROJECT_SKILL_HOST:$rel declares host=$host scope=project but hosts/registry.yaml has no project_skill_dir | add project_skill_dir or remove the host"
      continue
    fi
    target="$project_dir/$name"
    # Canonical skill already lives at this host's project discovery path.
    [ "$REPO_ROOT/$rel" = "$target" ] && continue
    if repair_missing_link "$REPO_ROOT/$rel" "$target"; then
      continue
    fi
    if ! symlink_points_to "$target" "$REPO_ROOT/$rel"; then
      emit_error "E_PROJECT_SKILL_LINK:$rel declares host=$host scope=project but $target is missing or wrong | repair: scripts/sync-host-skills.sh $host"
    fi
  done < <(skill_declared_hosts "$rel")
}

main() {
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    [ "$(skill_scope "$rel")" = "project" ] || continue
    check_project_skill "$rel"
  done < <(candidate_roots)

  if [ "$ERRORS" -gt 0 ]; then
    printf 'lint-project-skill-links: %d error(s)%s\n' \
      "$ERRORS" "$([ "$STAGED" -eq 1 ] && printf ' (staged)' || printf '')" >&2
    return 1
  fi
  printf 'lint-project-skill-links: OK%s\n' \
    "$([ "$STAGED" -eq 1 ] && printf ' (staged)' || printf '')" >&2
}

main
