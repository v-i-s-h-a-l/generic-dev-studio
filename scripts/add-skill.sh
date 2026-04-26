#!/usr/bin/env bash
# add-skill.sh — add a skill from a git URL (or local path) to the studio.
#
# Clones the upstream, finds the SKILL.md, detects license + author,
# generates a recipe YAML, and delegates to install-recipe.sh for the
# actual vendoring + host fan-out. One command → skill available on every
# installed AI provider.
#
# Usage:
#   scripts/add-skill.sh <git-url> [options]
#   scripts/add-skill.sh <git-url> --path=skills/my-skill/
#   scripts/add-skill.sh <git-url> --name=my-skill
#   scripts/add-skill.sh <git-url> --dry-run
#   scripts/add-skill.sh <git-url> --auto-approve
#
# Options:
#   --path=<subpath>          Path within the repo to the skill dir (default: auto-detect)
#   --name=<name>             Override the skill name (default: from SKILL.md frontmatter)
#   --domain=<d1,d2>          Comma-separated domains (default: inferred from SKILL.md)
#   --auto-approve            Skip author trust prompt (adds to trusted-authors.yaml)
#   --dry-run                 Show what would happen; no filesystem changes
#
# Exit:
#   0  skill added + synced to all hosts
#   1  validation or fetch failure
#   2  bad invocation

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RECIPES_DIR="$REPO_ROOT/recipes"
TRUSTED_AUTHORS="$RECIPES_DIR/trusted-authors.yaml"

for dep in git yq jq; do
  command -v "$dep" >/dev/null 2>&1 || { printf 'add-skill: %s is required\n' "$dep" >&2; exit 2; }
done

URL=""
SUBPATH=""
SKILL_NAME=""
DOMAINS=""
AUTO_APPROVE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --path=*)          SUBPATH="${1#*=}" ;;
    --name=*)          SKILL_NAME="${1#*=}" ;;
    --domain=*)        DOMAINS="${1#*=}" ;;
    --auto-approve)    AUTO_APPROVE=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    -h|--help)         sed -n '2,23p' "$0"; exit 0 ;;
    -*)                printf 'add-skill: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$URL" ]; then URL="$1"
      else printf 'add-skill: extra argument "%s"\n' "$1" >&2; exit 2
      fi ;;
  esac
  shift
done

if [ -z "$URL" ]; then
  printf 'usage: add-skill.sh <git-url> [--path=<subpath>] [--name=<name>] [--domain=<d1,d2>] [--auto-approve] [--dry-run]\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Step 1: Parse the URL → author + repo + clone URL
# ---------------------------------------------------------------------------
# Normalize: strip trailing .git, strip trailing /
CLEAN_URL="${URL%.git}"
CLEAN_URL="${CLEAN_URL%/}"

# Extract author and repo from GitHub-style URLs
# Handles: https://github.com/author/repo, github.com/author/repo, git@github.com:author/repo
case "$CLEAN_URL" in
  git@*:*/*)
    _hostpath="${CLEAN_URL#git@*:}"
    AUTHOR=$(printf '%s' "$_hostpath" | cut -d/ -f1)
    REPO_NAME=$(printf '%s' "$_hostpath" | cut -d/ -f2)
    CLONE_URL="$URL"
    UPSTREAM="github.com/$AUTHOR/$REPO_NAME"
    ;;
  *github.com/*/*)
    _path="${CLEAN_URL#*github.com/}"
    AUTHOR=$(printf '%s' "$_path" | cut -d/ -f1)
    REPO_NAME=$(printf '%s' "$_path" | cut -d/ -f2)
    CLONE_URL="https://github.com/$AUTHOR/$REPO_NAME.git"
    UPSTREAM="github.com/$AUTHOR/$REPO_NAME"
    ;;
  *)
    printf 'add-skill: only GitHub URLs are supported in this version\n' >&2
    printf '  Got: %s\n' "$URL" >&2
    exit 2
    ;;
esac

printf 'add-skill: author=%s repo=%s\n' "$AUTHOR" "$REPO_NAME" >&2

# ---------------------------------------------------------------------------
# Step 2: Clone into temp dir
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d -t add-skill.XXXXXX) || { printf 'add-skill: mktemp failed\n' >&2; exit 1; }
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

printf 'add-skill: cloning %s …\n' "$CLONE_URL" >&2
if ! git clone -q --depth 1 "$CLONE_URL" "$TMPDIR/repo" 2>/dev/null; then
  printf 'add-skill: git clone failed for %s\n' "$CLONE_URL" >&2
  exit 1
fi

# Capture HEAD SHA for pinning
PINNED_SHA=$(git -C "$TMPDIR/repo" rev-parse HEAD)
printf 'add-skill: pinned_sha=%s\n' "$PINNED_SHA" >&2

# ---------------------------------------------------------------------------
# Step 3: Find SKILL.md
# ---------------------------------------------------------------------------
SKILL_DIRS=""
if [ -n "$SUBPATH" ]; then
  _sd="$TMPDIR/repo/${SUBPATH%/}"
  if [ ! -f "$_sd/SKILL.md" ]; then
    printf 'add-skill: no SKILL.md at specified path %s\n' "$SUBPATH" >&2
    exit 1
  fi
  SKILL_DIRS="$_sd"
else
  SKILL_DIRS=$(find "$TMPDIR/repo" -name 'SKILL.md' -type f 2>/dev/null \
    | while IFS= read -r f; do dirname "$f"; done | sort)
  if [ -z "$SKILL_DIRS" ]; then
    printf 'add-skill: no SKILL.md found in %s\n' "$CLONE_URL" >&2
    exit 1
  fi
fi

_count=$(printf '%s\n' "$SKILL_DIRS" | wc -l | tr -d ' ')
if [ "$_count" -gt 1 ]; then
  printf 'add-skill: found %s skills in this repo:\n' "$_count" >&2
  printf '%s\n' "$SKILL_DIRS" | while IFS= read -r sd; do
    rel="${sd#"$TMPDIR/repo/"}"
    _n=$(yq -r '.name // ""' "$sd/SKILL.md" 2>/dev/null | head -1)
    [ -z "$_n" ] || [ "$_n" = "null" ] && _n="$rel"
    printf '  %s (%s)\n' "$_n" "$rel" >&2
  done
  printf '\nUse --path=<subpath> to pick one, or re-run once per skill.\n' >&2
  if [ -z "$SUBPATH" ]; then
    printf 'add-skill: installing all %s skills found\n' "$_count" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Process each skill
# ---------------------------------------------------------------------------
overall_rc=0
_rc_file="$TMPDIR/.rc"
printf '0' > "$_rc_file"

while IFS= read -r SKILL_DIR; do
  [ -z "$SKILL_DIR" ] && continue
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SKILL_REL="${SKILL_DIR#"$TMPDIR/repo/"}"
  [ "$SKILL_REL" = "$SKILL_DIR" ] && SKILL_REL="."

  # Extract metadata from SKILL.md frontmatter (YAML between --- fences)
  frontmatter=$(sed -n '/^---$/,/^---$/p' "$SKILL_FILE" | sed '1d;$d')
  fm_name=$(printf '%s' "$frontmatter" | yq -r '.name // ""' 2>/dev/null)
  fm_desc=$(printf '%s' "$frontmatter" | yq -r '.description // ""' 2>/dev/null)

  # Resolve skill name: --name flag > frontmatter > directory name
  if [ -n "$SKILL_NAME" ]; then
    name="$SKILL_NAME"
  elif [ -n "$fm_name" ] && [ "$fm_name" != "null" ]; then
    name="$fm_name"
  else
    name=$(basename "$SKILL_DIR")
  fi

  printf '\nadd-skill: processing "%s" from %s\n' "$name" "$SKILL_REL" >&2

  # Check if recipe already exists
  existing_recipe=$(find "$RECIPES_DIR" -type f -name "${name}.yaml" -not -path "*/profiles/*" 2>/dev/null | head -1)
  if [ -n "$existing_recipe" ]; then
    printf 'add-skill: recipe "%s" already exists at %s\n' "$name" "${existing_recipe#"$REPO_ROOT/"}" >&2
    printf '  To update, bump pinned_sha in the recipe and run: scripts/install-recipe.sh %s\n' "$name" >&2
    printf '1' > "$_rc_file"
    continue
  fi

  # Detect license
  LICENSE_SPDX=""
  for lf in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md; do
    if [ -f "$TMPDIR/repo/$lf" ]; then
      content=$(head -5 "$TMPDIR/repo/$lf")
      case "$content" in
        *"MIT License"*|*"MIT "*)           LICENSE_SPDX="MIT" ;;
        *"Apache License"*|*"Apache-2.0"*)  LICENSE_SPDX="Apache-2.0" ;;
        *"BSD 2-Clause"*)                   LICENSE_SPDX="BSD-2-Clause" ;;
        *"BSD 3-Clause"*)                   LICENSE_SPDX="BSD-3-Clause" ;;
        *"ISC License"*)                    LICENSE_SPDX="ISC" ;;
        *"Unlicense"*)                      LICENSE_SPDX="Unlicense" ;;
        *"CC0"*)                            LICENSE_SPDX="CC0-1.0" ;;
      esac
      break
    fi
  done

  if [ -z "$LICENSE_SPDX" ]; then
    printf 'add-skill: could not detect license for %s\n' "$name" >&2
    printf '  Add a LICENSE file to the upstream repo, or create the recipe manually.\n' >&2
    printf '1' > "$_rc_file"
    continue
  fi

  # Validate license against allowlist
  if ! yq -r '.allowed[]' "$REPO_ROOT/_shared/standards/license-allowlist.yaml" 2>/dev/null \
      | grep -Fxq "$LICENSE_SPDX"; then
    printf 'add-skill: license "%s" not in allowlist for %s\n' "$LICENSE_SPDX" "$name" >&2
    printf '1' > "$_rc_file"
    continue
  fi

  printf 'add-skill: license=%s\n' "$LICENSE_SPDX" >&2

  # Resolve path for recipe (relative to repo root)
  skill_path="$SKILL_REL/"
  [ "$skill_path" = "./" ] && skill_path=""

  # Resolve domains
  recipe_domains="[]"
  if [ -n "$DOMAINS" ]; then
    recipe_domains="[$(printf '%s' "$DOMAINS" | sed 's/,/, /g')]"
  fi

  # Build description for attribution
  desc_short=""
  if [ -n "$fm_desc" ] && [ "$fm_desc" != "null" ]; then
    desc_short=$(printf '%s' "$fm_desc" | head -c 120)
  fi

  # Create author directory under recipes/ if needed
  author_dir="$RECIPES_DIR/$AUTHOR"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] would create recipe: recipes/%s/%s.yaml\n' "$AUTHOR" "$name" >&2
    printf '[dry-run] would run: install-recipe.sh %s\n' "$name" >&2
    continue
  fi

  mkdir -p "$author_dir"

  # Write recipe YAML
  recipe_file="$author_dir/$name.yaml"
  cat > "$recipe_file" <<RECIPE_EOF
schema_version: 1
name: $name
domain: $recipe_domains
strategy: verbatim
sources:
  - upstream: $UPSTREAM
    path: ${skill_path:-.}
    pinned_sha: $PINNED_SHA
    license: $LICENSE_SPDX
update_policy: auto-pr
authoring_standard: exempt
portability:
  hosts: [all]
  scope: global
attribution: |
  ${desc_short:-$name} by $AUTHOR. Vendored verbatim under $LICENSE_SPDX.
  Source: $UPSTREAM
routing:
  triggers:
    - "/$name"
  domains: $recipe_domains
RECIPE_EOF

  printf 'add-skill: recipe written → %s\n' "${recipe_file#"$REPO_ROOT/"}" >&2

  # Delegate to install-recipe.sh
  install_flags=""
  [ "$AUTO_APPROVE" -eq 1 ] && install_flags="--auto-approve-author"
  if ! "$SCRIPT_DIR/install-recipe.sh" "$name" $install_flags; then
    printf 'add-skill: install-recipe.sh failed for %s\n' "$name" >&2
    printf '1' > "$_rc_file"
    continue
  fi

  printf 'add-skill: %s installed and synced to all detected hosts\n' "$name" >&2
done <<< "$SKILL_DIRS"

overall_rc=$(cat "$_rc_file")

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\nadd-skill: dry-run complete — no changes made\n' >&2
elif [ "$overall_rc" -eq 0 ]; then
  printf '\nadd-skill: done — all skills installed\n' >&2
  printf 'Run "scripts/verify-install.sh" to confirm host fan-out.\n' >&2
fi

exit "$overall_rc"
