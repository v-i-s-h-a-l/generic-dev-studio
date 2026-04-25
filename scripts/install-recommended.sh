#!/usr/bin/env bash
# install-recommended.sh — install every recipe in a profile.
#
# One-shot bootstrap for new machines: read recipes/profiles/<profile>.yaml,
# call install-recipe.sh for each entry, then sync-host-skills.sh --all.
#
# Usage:
#   scripts/install-recommended.sh                # uses ios profile by default
#   scripts/install-recommended.sh <profile>      # named profile
#   scripts/install-recommended.sh --list         # list available profiles
#   scripts/install-recommended.sh <profile> --auto-approve-author
#                                                 # batch mode for CI / cron
#
# Exit codes:
#   0  every recipe in the profile vendored cleanly
#   1  one or more recipes failed; remaining recipes still attempted
#   2  bad invocation (unknown profile, etc.)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROFILES_DIR="$REPO_ROOT/recipes/profiles"

if ! command -v yq >/dev/null 2>&1; then
  printf 'install-recommended: yq required\n' >&2; exit 2
fi

PROFILE="ios"
LIST=0
PASS_THROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --auto-approve-author|--dry-run) PASS_THROUGH+=("$1") ;;
    --override-license=*) PASS_THROUGH+=("$1") ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) printf 'install-recommended: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) PROFILE="$1" ;;
  esac
  shift
done

if [ "$LIST" -eq 1 ]; then
  printf 'Available profiles (recipes/profiles/):\n'
  for f in "$PROFILES_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    printf '  - %s\n' "$(basename "$f" .yaml)"
  done
  exit 0
fi

PROFILE_FILE="$PROFILES_DIR/$PROFILE.yaml"
if [ ! -f "$PROFILE_FILE" ]; then
  printf 'install-recommended: profile "%s" not found at %s\n' "$PROFILE" "$PROFILE_FILE" >&2
  exit 2
fi

display_name=$(yq -r '.display_name // .name // ""' "$PROFILE_FILE")
recipe_count=$(yq -r '.recipes | length' "$PROFILE_FILE" 2>/dev/null)

printf 'install-recommended: profile=%s display=%s recipes=%s\n' "$PROFILE" "$display_name" "$recipe_count" >&2

if [ "$recipe_count" -eq 0 ]; then
  printf 'install-recommended: profile "%s" has 0 recipes — nothing to install\n' "$PROFILE" >&2
  printf '  Edit %s and add recipe names; then re-run.\n' "${PROFILE_FILE#"$REPO_ROOT/"}" >&2
  exit 0
fi

overall_rc=0
i=0
while [ "$i" -lt "$recipe_count" ]; do
  recipe=$(yq -r ".recipes[$i]" "$PROFILE_FILE")
  if [ -z "$recipe" ] || [ "$recipe" = "null" ]; then
    i=$((i + 1)); continue
  fi
  printf '\ninstall-recommended: [%d/%d] installing %s\n' "$((i + 1))" "$recipe_count" "$recipe" >&2
  if ! "$SCRIPT_DIR/install-recipe.sh" "$recipe" "${PASS_THROUGH[@]+"${PASS_THROUGH[@]}"}"; then
    printf 'install-recommended: install of "%s" failed; continuing\n' "$recipe" >&2
    overall_rc=1
  fi
  i=$((i + 1))
done

# Single fan-out at the end so multiple installs share one pass.
if [ -x "$SCRIPT_DIR/sync-host-skills.sh" ]; then
  "$SCRIPT_DIR/sync-host-skills.sh" --all >/dev/null 2>&1 || \
    printf 'install-recommended: post-install sync-host-skills.sh --all reported drift; run manually to inspect\n' >&2
fi

if [ "$overall_rc" -eq 0 ]; then
  printf '\ninstall-recommended: profile "%s" installed cleanly (%d recipes)\n' "$PROFILE" "$recipe_count" >&2
else
  printf '\ninstall-recommended: profile "%s" had failures (rerun with --auto-approve-author or check recipes manually)\n' "$PROFILE" >&2
fi

exit "$overall_rc"
