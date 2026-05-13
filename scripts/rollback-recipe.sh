#!/usr/bin/env bash
# rollback-recipe.sh — revert a recipe to its prior pinned SHA and re-vendor.
#
# Operational counterpart to update-recipes.sh. When a bumped upstream breaks
# model behavior or automation, this script reverts the recipe's pinned_sha to
# the value from the prior git commit (or an explicit target), re-vendors via
# install-recipe.sh, triggers sync-host-skills.sh --all, and emits a
# recipe_rolled_back event.
#
# Usage:
#   scripts/rollback-recipe.sh <recipe-name>
#   scripts/rollback-recipe.sh <recipe-name> --to <sha>
#   scripts/rollback-recipe.sh <recipe-name> --dry-run
#   scripts/rollback-recipe.sh <recipe-name> --reason "upstream broke X"
#
# Exit codes:
#   0  rollback applied (or already at target SHA)
#   1  no prior SHA found / upstream missing / install failed
#   2  bad invocation

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RECIPES_DIR="$REPO_ROOT/recipes"

# shellcheck source=lib-github-transport.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-github-transport.sh"

if ! command -v yq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  printf 'rollback-recipe: yq + git required\n' >&2; exit 2
fi

NAME=""
TARGET_SHA=""
DRY_RUN=0
REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --to)       shift; TARGET_SHA="${1:?--to requires a SHA}"; ;;
    --dry-run)  DRY_RUN=1 ;;
    --reason)   shift; REASON="${1:?--reason requires text}"; ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    -*)         printf 'rollback-recipe: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      else printf 'rollback-recipe: extra argument "%s"\n' "$1" >&2; exit 2
      fi ;;
  esac
  shift
done

[ -z "$NAME" ] && { printf 'usage: rollback-recipe.sh <recipe-name> [--to <sha>] [--dry-run] [--reason "..."]\n' >&2; exit 2; }

RECIPE_FILE=$(find "$RECIPES_DIR" -type f -name "${NAME}.yaml" -not -path "*/profiles/*" 2>/dev/null | head -1)
[ -z "$RECIPE_FILE" ] && { printf 'rollback-recipe: recipe "%s" not found\n' "$NAME" >&2; exit 1; }
RECIPE_REL="${RECIPE_FILE#"$REPO_ROOT/"}"

current_sha=$(yq -r '.sources[0].pinned_sha' "$RECIPE_FILE")
[ -z "$current_sha" ] || [ "$current_sha" = "null" ] && {
  printf 'rollback-recipe: no pinned_sha in %s\n' "$RECIPE_REL" >&2; exit 1
}

# Resolve the target SHA (prior commit or explicit).
if [ -n "$TARGET_SHA" ]; then
  rollback_sha="$TARGET_SHA"
else
  prior_commit=$(git -C "$REPO_ROOT" log --format='%H' -- "$RECIPE_REL" | sed -n '2p')
  [ -z "$prior_commit" ] && {
    printf 'rollback-recipe: no prior commit for %s — only one version exists\n' "$RECIPE_REL" >&2
    exit 1
  }
  rollback_sha=$(git -C "$REPO_ROOT" show "$prior_commit:$RECIPE_REL" | yq -r '.sources[0].pinned_sha' 2>/dev/null)
  [ -z "$rollback_sha" ] || [ "$rollback_sha" = "null" ] && {
    printf 'rollback-recipe: could not extract prior pinned_sha from commit %s\n' "${prior_commit:0:8}" >&2
    exit 1
  }
fi

if [ "$current_sha" = "$rollback_sha" ]; then
  printf 'rollback-recipe: %s already at %s (no-op)\n' "$NAME" "$rollback_sha" >&2
  exit 0
fi

# Verify the target SHA exists upstream.
upstream=$(yq -r '.sources[0].upstream' "$RECIPE_FILE")
author=$(printf '%s' "$upstream" | awk -F/ '{print $2}')
repo=$(printf '%s' "$upstream" | awk -F/ '{print $3}')
# Upstream is a third-party repo; route through the shared helper in anonymous
# mode for the stale-helper diagnostic seam without using studio gh creds.
if ! STUDIO_GIT_TRANSPORT_ANONYMOUS=1 \
    studio_git_transport_ls_remote --exit-code "https://github.com/$author/$repo.git" "$rollback_sha" >/dev/null 2>&1; then
  # ls-remote with a SHA doesn't work for all servers; try a shallow fetch probe
  tmpdir=$(mktemp -d -t rollback-probe.XXXXXX)
  if ! ( cd "$tmpdir" && git init -q . && git remote add origin "https://github.com/$author/$repo.git" \
         && STUDIO_GIT_TRANSPORT_ANONYMOUS=1 studio_git_transport_fetch -q --depth 1 origin "$rollback_sha" ) >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    printf 'rollback-recipe: target SHA %s not found upstream at %s/%s\n' "$rollback_sha" "$author" "$repo" >&2
    printf 'hint: upstream may have force-pushed; use --to <known-good-sha> instead\n' >&2
    exit 1
  fi
  rm -rf "$tmpdir"
fi

printf 'rollback-recipe: %s: %s → %s\n' "$NAME" "${current_sha:0:8}" "${rollback_sha:0:8}"

if [ "$DRY_RUN" = "1" ]; then
  printf '[dry-run] would update %s and re-vendor\n' "$RECIPE_REL"
  exit 0
fi

# Update the recipe YAML.
src_count=$(yq -r '.sources | length' "$RECIPE_FILE")
idx=0
while [ "$idx" -lt "$src_count" ]; do
  yq -i ".sources[$idx].pinned_sha = \"$rollback_sha\"" "$RECIPE_FILE"
  idx=$((idx + 1))
done

# Re-vendor.
if ! "$SCRIPT_DIR/install-recipe.sh" "$NAME" --auto-approve-author; then
  printf 'rollback-recipe: install-recipe.sh failed — recipe YAML updated but content not vendored\n' >&2
  exit 1
fi

# Emit event.
if [ -x "$SCRIPT_DIR/emit-event.sh" ]; then
  "$SCRIPT_DIR/emit-event.sh" recipe_rolled_back \
    recipe="$NAME" from_sha="${current_sha:0:8}" to_sha="${rollback_sha:0:8}" \
    reason="${REASON:-manual rollback}" \
    >/dev/null 2>&1 || true
fi

printf 'rollback-recipe: %s rolled back to %s\n' "$NAME" "${rollback_sha:0:8}" >&2
