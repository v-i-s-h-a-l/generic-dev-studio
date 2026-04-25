#!/usr/bin/env bash
# lint-recipe.sh — validate recipe YAML files against the recipe schema and
# the studio's license/author allowlists.
#
# Usage:
#   scripts/lint-recipe.sh                      # lint every recipe under recipes/
#   scripts/lint-recipe.sh <file_or_dir> ...    # lint specific files / dirs
#   scripts/lint-recipe.sh --staged             # lint staged recipes only
#
# Exit 0: all recipes pass. Exit 1: any block-level violation.
# Findings format: <CODE>:<file>[:<line>]:<detail>
#
# Codes:
#   E_INVALID_SCHEMA          recipe.yaml fails schema validation
#   E_LICENSE_NOT_ALLOWED     license not in license-allowlist.yaml
#   E_AUTHOR_NOT_ALLOWED      upstream author not in trusted-authors.yaml
#   E_PROFILE_BAD_REF         profile references a recipe that does not exist
#   W_AUTHOR_FIRST_TIME       (informational) author present but not in
#                             trusted set; install-recipe.sh would prompt.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
STANDARDS_DIR="$REPO_ROOT/_shared/standards"
RECIPES_DIR="$REPO_ROOT/recipes"

if ! command -v yq >/dev/null 2>&1; then
  printf 'lint-recipe: yq is required\n' >&2; exit 2
fi

ERRORS=0
WARNINGS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

HAVE_JSCHEMA=0
command -v check-jsonschema >/dev/null 2>&1 && HAVE_JSCHEMA=1

filter_jsonschema_output() {
  awk '
    /Library\/Python|warnings\.warn|NotOpenSSL/ { next }
    /^[[:space:]]*$/ { next }
    /^Schema validation errors/ { next }
    { sub(/^[[:space:]]+/, "", $0); sub(/^[^:]+::/, "", $0); print }
  '
}

# Load license allowlist (cache on stdout).
load_allowed_licenses() {
  yq -r '.allowed[]' "$STANDARDS_DIR/license-allowlist.yaml" 2>/dev/null
}

load_trusted_authors() {
  yq -r '.trusted[]' "$RECIPES_DIR/trusted-authors.yaml" 2>/dev/null
}

ALLOWED_LICENSES=$(load_allowed_licenses)
TRUSTED_AUTHORS=$(load_trusted_authors)

# -----------------------------------------------------------------------
# Per-recipe validation
# -----------------------------------------------------------------------
lint_recipe_file() {
  local file="$1" rel="$2"

  if ! yq -o=json '.' "$file" >/dev/null 2>&1; then
    emit_error "E_INVALID_SCHEMA:$rel:recipe.yaml does not parse as YAML"
    return
  fi

  if [ "$HAVE_JSCHEMA" -eq 1 ]; then
    local tmp_json raw_out filtered rc
    tmp_json=$(mktemp -t recipe.XXXXXX.json)
    yq -o=json '.' "$file" >"$tmp_json"
    raw_out=$(PYTHONWARNINGS=ignore check-jsonschema --schemafile "$STANDARDS_DIR/recipe.json" "$tmp_json" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      filtered=$(printf '%s\n' "$raw_out" | filter_jsonschema_output)
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        emit_error "E_INVALID_SCHEMA:$rel:$line"
      done <<<"$filtered"
    fi
    rm -f "$tmp_json"
  fi

  # License + author checks across every source.
  local count i license upstream author
  count=$(yq -r '.sources | length' "$file" 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$count" ]; do
    license=$(yq -r ".sources[$i].license" "$file" 2>/dev/null)
    upstream=$(yq -r ".sources[$i].upstream" "$file" 2>/dev/null)
    author=""
    case "$upstream" in
      github.com/*/*)
        author=$(printf '%s' "$upstream" | awk -F/ '{print $2}')
        ;;
    esac

    if [ -n "$license" ] && [ "$license" != "null" ]; then
      if ! printf '%s\n' "$ALLOWED_LICENSES" | grep -Fxq "$license"; then
        emit_error "E_LICENSE_NOT_ALLOWED:$rel:sources[$i].license=\"$license\" not in _shared/standards/license-allowlist.yaml — pass --override-license to install-recipe.sh if intentional"
      fi
    fi

    if [ -n "$author" ]; then
      if ! printf '%s\n' "$TRUSTED_AUTHORS" | grep -Fxq "$author"; then
        emit_warn "W_AUTHOR_FIRST_TIME:$rel:upstream author \"$author\" not in recipes/trusted-authors.yaml — install-recipe.sh would prompt for one-time approval"
      fi
    fi

    i=$((i + 1))
  done
}

lint_profile_file() {
  local file="$1" rel="$2"
  if ! yq -o=json '.' "$file" >/dev/null 2>&1; then
    emit_error "E_INVALID_SCHEMA:$rel:profile YAML does not parse"
    return
  fi
  local count i recipe_name
  count=$(yq -r '.recipes | length // 0' "$file" 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "null" ]; then return; fi
  i=0
  while [ "$i" -lt "$count" ]; do
    recipe_name=$(yq -r ".recipes[$i]" "$file" 2>/dev/null)
    if [ -z "$recipe_name" ] || [ "$recipe_name" = "null" ]; then
      i=$((i + 1)); continue
    fi
    # Profile recipes are looked up by exact filename match across recipes/**/.
    if ! find "$RECIPES_DIR" -mindepth 1 -name "${recipe_name}.yaml" -type f 2>/dev/null \
        | grep -vq '/profiles/'; then
      emit_error "E_PROFILE_BAD_REF:$rel:references unknown recipe \"$recipe_name\" — expected a file recipes/**/${recipe_name}.yaml"
    fi
    i=$((i + 1))
  done
}

# -----------------------------------------------------------------------
# File discovery
# -----------------------------------------------------------------------
collect_targets() {
  local mode="$1"; shift
  case "$mode" in
    --staged)
      git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '^recipes/.*\.yaml$' || true
      ;;
    --explicit)
      local arg
      for arg in "$@"; do
        if [ -f "$arg" ]; then
          printf '%s\n' "${arg#"$REPO_ROOT/"}"
        elif [ -d "$arg" ]; then
          find "$arg" -type f -name '*.yaml' 2>/dev/null \
            | while IFS= read -r f; do printf '%s\n' "${f#"$REPO_ROOT/"}"; done
        fi
      done
      ;;
    --all)
      ( cd "$REPO_ROOT" && find recipes -type f -name '*.yaml' 2>/dev/null )
      ;;
  esac
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
mode="--all"
if [ "${1:-}" = "--staged" ]; then mode="--staged"; shift
elif [ $# -gt 0 ]; then mode="--explicit"; fi

targets=$(collect_targets "$mode" "$@")

if [ -z "$targets" ] && [ "$mode" = "--staged" ]; then exit 0; fi

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  abs="$REPO_ROOT/$rel"
  [ -f "$abs" ] || continue
  case "$rel" in
    recipes/profiles/*.yaml|recipes/profiles/*/*.yaml)
      lint_profile_file "$abs" "$rel"
      ;;
    recipes/trusted-authors.yaml)
      : # plain author list; schema-light; nothing more to lint
      ;;
    recipes/*.yaml|recipes/*/*.yaml|recipes/*/*/*.yaml)
      lint_recipe_file "$abs" "$rel"
      ;;
  esac
done <<<"$targets"

printf '%d errors, %d warnings\n' "$ERRORS" "$WARNINGS" >&2
[ "$ERRORS" -eq 0 ]
