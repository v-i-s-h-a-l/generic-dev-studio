#!/usr/bin/env bash
# install-recipe.sh — vendor an upstream skill into the studio per its recipe.
#
# Reads recipes/**/<name>.yaml, fetches upstream at pinned_sha, validates
# license + author against allowlists, vendors into skills/vendored/<author>/
# <skill>/ with vendor.yaml recording source + SHA + license + attribution,
# and triggers a host fan-out so the new skill is reachable from every
# adapted host's discovery dir.
#
# Usage:
#   scripts/install-recipe.sh <recipe-name>
#                                            # interactive: prompts on first-
#                                              time author
#   scripts/install-recipe.sh <recipe-name> --auto-approve-author
#                                            # add author to trusted list
#                                              without prompting (CI / batch)
#   scripts/install-recipe.sh <recipe-name> --override-license=<spdx>
#                                            # accept a non-allowlist license
#                                              for this install only
#   scripts/install-recipe.sh <recipe-name> --dry-run
#                                            # plan only; no filesystem changes
#
# Exit:
#   0  vendor + fan-out succeeded
#   1  validation, fetch, or lint failure
#   2  bad invocation
#
# Idempotent: re-running with the same pinned_sha is a no-op (vendor.yaml
# already records the SHA). Bumping the pinned_sha and re-running re-vendors.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RECIPES_DIR="$REPO_ROOT/recipes"
TRUSTED_AUTHORS_FILE="$RECIPES_DIR/trusted-authors.yaml"

# shellcheck source=lib-github-transport.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-github-transport.sh"

if ! command -v yq >/dev/null 2>&1; then
  printf 'install-recipe: yq is required\n' >&2; exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'install-recipe: git is required\n' >&2; exit 2
fi

NAME=""
AUTO_APPROVE=0
OVERRIDE_LICENSE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --auto-approve-author) AUTO_APPROVE=1 ;;
    --override-license=*) OVERRIDE_LICENSE="${1#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) printf 'install-recipe: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      else printf 'install-recipe: extra argument "%s"\n' "$1" >&2; exit 2
      fi ;;
  esac
  shift
done

if [ -z "$NAME" ]; then
  printf 'usage: install-recipe.sh <recipe-name> [--auto-approve-author] [--override-license=SPDX] [--dry-run]\n' >&2
  exit 2
fi

# -----------------------------------------------------------------------
# Helpers (defined early so the install loop can call them)
# -----------------------------------------------------------------------
fetch_verbatim() {
  # $1 = author, $2 = repo, $3 = sha, $4 = subpath, $5 = dst dir
  local author="$1" repo="$2" sha="$3" path="$4" dst="$5"
  local tmpdir
  tmpdir=$(mktemp -d -t recipe-fetch.XXXXXX) || return 1

  # Anonymous mode: upstream is a third-party repo. The shared helper still
  # provides GIT_TERMINAL_PROMPT=0 + the stale-helper diagnostic seam without
  # using the studio's gh credentials against an unrelated remote.
  ( cd "$tmpdir" \
    && git init -q . \
    && git remote add origin "https://github.com/$author/$repo.git" \
    && STUDIO_GIT_TRANSPORT_ANONYMOUS=1 studio_git_transport_fetch -q --depth 1 origin "$sha" \
    && git checkout -q FETCH_HEAD ) || { rm -rf "$tmpdir"; return 1; }

  local src="$tmpdir/${path%/}"
  if [ ! -d "$src" ]; then
    printf 'install-recipe: upstream path "%s" missing in %s/%s @ %s\n' "$path" "$author" "$repo" "$sha" >&2
    rm -rf "$tmpdir"; return 1
  fi

  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' --exclude 'vendor.yaml' "$src/" "$dst/"
  else
    # Fallback: cp -R; less precise on `--delete`, but functional.
    rm -rf "$dst"
    mkdir -p "$dst"
    ( cd "$src" && tar -cf - . ) | ( cd "$dst" && tar -xf - )
  fi
  rm -rf "$tmpdir"
  return 0
}

# Resolve recipe file by name (any depth under recipes/, excluding profiles/).
RECIPE_FILE=$(find "$RECIPES_DIR" -type f -name "${NAME}.yaml" -not -path "*/profiles/*" 2>/dev/null | head -1)
if [ -z "$RECIPE_FILE" ]; then
  printf 'install-recipe: recipe "%s" not found under recipes/\n' "$NAME" >&2
  exit 1
fi

# Validate via lint-recipe.sh first.
if [ -x "$SCRIPT_DIR/lint-recipe.sh" ]; then
  if ! "$SCRIPT_DIR/lint-recipe.sh" "$RECIPE_FILE" >/dev/null 2>&1; then
    printf 'install-recipe: %s fails lint-recipe.sh — fix recipe first\n' "${RECIPE_FILE#"$REPO_ROOT/"}" >&2
    "$SCRIPT_DIR/lint-recipe.sh" "$RECIPE_FILE" >&2
    exit 1
  fi
fi

# Recipe fields.
strategy=$(yq -r '.strategy' "$RECIPE_FILE")
authoring_standard=$(yq -r '.authoring_standard' "$RECIPE_FILE")
attribution=$(yq -r '.attribution // ""' "$RECIPE_FILE")

# Recipe-level portability override (optional).
recipe_port_hosts=$(yq -r '.portability.hosts // [] | .[]' "$RECIPE_FILE" 2>/dev/null)
recipe_port_scope=$(yq -r '.portability.scope // ""' "$RECIPE_FILE" 2>/dev/null)
[ "$recipe_port_scope" = "null" ] && recipe_port_scope=""

# Iterate sources. Most recipes have one; verbatim composite is rare.
src_count=$(yq -r '.sources | length' "$RECIPE_FILE")
src_idx=0
overall_rc=0

while [ "$src_idx" -lt "$src_count" ]; do
  upstream=$(yq -r ".sources[$src_idx].upstream" "$RECIPE_FILE")
  upath=$(yq -r ".sources[$src_idx].path" "$RECIPE_FILE")
  pinned_sha=$(yq -r ".sources[$src_idx].pinned_sha" "$RECIPE_FILE")
  license=$(yq -r ".sources[$src_idx].license" "$RECIPE_FILE")

  # github.com/<author>/<repo>
  author=$(printf '%s' "$upstream" | awk -F/ '{print $2}')
  repo=$(printf '%s' "$upstream" | awk -F/ '{print $3}')

  # License gate.
  effective_license="$license"
  if [ -n "$OVERRIDE_LICENSE" ]; then
    effective_license="$OVERRIDE_LICENSE"
    printf 'install-recipe: override-license="%s" applied for sources[%d]\n' "$OVERRIDE_LICENSE" "$src_idx" >&2
  fi
  if ! yq -r '.allowed[]' "$REPO_ROOT/_shared/standards/license-allowlist.yaml" 2>/dev/null \
      | grep -Fxq "$effective_license"; then
    printf 'install-recipe: license "%s" not in allowlist; pass --override-license=%s if intentional\n' "$effective_license" "$effective_license" >&2
    overall_rc=1
    src_idx=$((src_idx + 1)); continue
  fi

  # Author gate.
  if ! yq -r '.trusted[]' "$TRUSTED_AUTHORS_FILE" 2>/dev/null | grep -Fxq "$author"; then
    if [ "$AUTO_APPROVE" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        # Append to trusted list (idempotent).
        printf '\n  # auto-approved by install-recipe.sh on %s\n  - %s\n' "$(date -u +%Y-%m-%d)" "$author" \
          | sed -i.bak "/^trusted:/a\\
"$'\\\n''#  added by --auto-approve-author '"$(date -u +%Y-%m-%d)"$'\\\n''  - '"$author" "$TRUSTED_AUTHORS_FILE" 2>/dev/null || \
            printf '  - %s\n' "$author" >> "$TRUSTED_AUTHORS_FILE"
        rm -f "${TRUSTED_AUTHORS_FILE}.bak"
      fi
      printf 'install-recipe: author "%s" auto-approved (--auto-approve-author)\n' "$author" >&2
    else
      if [ ! -t 0 ]; then
        printf 'install-recipe: author "%s" not trusted; run with --auto-approve-author or add to recipes/trusted-authors.yaml manually\n' "$author" >&2
        overall_rc=1
        src_idx=$((src_idx + 1)); continue
      fi
      printf 'install-recipe: author "%s" is not in recipes/trusted-authors.yaml.\n' "$author" >&2
      printf '  Vendoring %s/%s requires explicit approval (one-time supply-chain check).\n' "$author" "$repo" >&2
      printf '  Approve and add "%s" to the trusted list? [y/N] ' "$author" >&2
      read -r answer
      case "$answer" in
        y|Y|yes|YES)
          if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n  # added via interactive approval %s\n  - %s\n' "$(date -u +%Y-%m-%d)" "$author" >> "$TRUSTED_AUTHORS_FILE"
          fi
          printf 'install-recipe: author "%s" approved\n' "$author" >&2
          ;;
        *)
          printf 'install-recipe: author "%s" rejected; aborting source[%d]\n' "$author" "$src_idx" >&2
          overall_rc=1
          src_idx=$((src_idx + 1)); continue
          ;;
      esac
    fi
  fi

  # Vendoring location.
  case "$strategy" in
    verbatim)
      vendor_dir="$REPO_ROOT/skills/vendored/$author/$NAME"
      ;;
    inspired|owned)
      # `inspired` and `owned` recipes are for content that's already in the
      # repo at skills/owned/<name>/ — install verifies + records vendor.yaml
      # but doesn't fetch.
      vendor_dir="$REPO_ROOT/skills/owned/$NAME"
      ;;
    *)
      printf 'install-recipe: unknown strategy "%s"\n' "$strategy" >&2
      overall_rc=1
      src_idx=$((src_idx + 1)); continue
      ;;
  esac

  # Idempotency: read existing vendor.yaml if present, compare pinned_sha.
  vendor_yaml="$vendor_dir/vendor.yaml"
  if [ -f "$vendor_yaml" ]; then
    existing_sha=$(yq -r '.pinned_sha // ""' "$vendor_yaml" 2>/dev/null)
    if [ "$existing_sha" = "$pinned_sha" ] && [ "$strategy" != "owned" ] && [ "$strategy" != "inspired" ] \
       && [ -f "$vendor_dir/portability.yaml" ]; then
      printf 'install-recipe: %s already vendored at %s (no-op)\n' "$NAME" "$pinned_sha" >&2
      src_idx=$((src_idx + 1)); continue
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] would vendor %s/%s @ %s into %s\n' "$author" "$repo" "$pinned_sha" "${vendor_dir#"$REPO_ROOT/"}"
    src_idx=$((src_idx + 1)); continue
  fi

  if [ "$strategy" = "verbatim" ]; then
    fetch_verbatim "$author" "$repo" "$pinned_sha" "$upath" "$vendor_dir" || { overall_rc=1; src_idx=$((src_idx + 1)); continue; }
  fi

  # Write vendor.yaml (records source + SHA + license + attribution).
  mkdir -p "$vendor_dir"
  cat > "$vendor_yaml" <<EOF
schema_version: 1
recipe: $NAME
strategy: $strategy
upstream: $upstream
path: $upath
pinned_sha: $pinned_sha
license: $effective_license
authoring_standard: $authoring_standard
vendored_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  if [ -n "$attribution" ] && [ "$attribution" != "null" ]; then
    printf 'attribution: |\n' >> "$vendor_yaml"
    printf '%s\n' "$attribution" | sed 's/^/  /' >> "$vendor_yaml"
  fi

  # ---- Portability resolution: recipe-explicit → upstream probe → default ----
  # For owned/inspired strategies, respect hand-managed portability.yaml.
  if [ -f "$vendor_dir/portability.yaml" ] && { [ "$strategy" = "owned" ] || [ "$strategy" = "inspired" ]; }; then
    printf 'install-recipe: vendored %s @ %s -> %s\n' "$NAME" "$pinned_sha" "${vendor_dir#"$REPO_ROOT/"}" >&2
    printf 'install-recipe: portability.yaml preserved (owned/inspired — hand-managed)\n' >&2
    src_idx=$((src_idx + 1)); continue
  fi

  port_source="default"
  port_hosts_list="claude-code"
  port_scope="${recipe_port_scope:-global}"

  if [ -n "$recipe_port_hosts" ]; then
    port_source="recipe"
    port_hosts_list="$recipe_port_hosts"
  else
    inferred=""
    [ -d "$vendor_dir/.claude-plugin" ] && inferred="${inferred:+$inferred
}claude-code"
    [ -f "$vendor_dir/agents/openai.yaml" ] && inferred="${inferred:+$inferred
}codex"
    if [ -n "$inferred" ]; then
      port_source="inferred"
      port_hosts_list="$inferred"
      case "$port_hosts_list" in
        *claude-code*) : ;;
        *) port_hosts_list="claude-code
$port_hosts_list" ;;
      esac
    fi
  fi

  {
    printf 'schema_version: 1\nhosts:\n'
    printf '%s\n' "$port_hosts_list" | while IFS= read -r h; do
      [ -z "$h" ] && continue
      printf '  - %s\n' "$h"
    done
    printf 'scope: %s\n' "$port_scope"
  } > "$vendor_dir/portability.yaml"

  if [ "$port_source" != "recipe" ] && [ -x "$SCRIPT_DIR/emit-event.sh" ]; then
    hosts_csv=$(printf '%s\n' "$port_hosts_list" | paste -sd ',' -)
    "$SCRIPT_DIR/emit-event.sh" recipe_portability_inferred \
      recipe="$NAME" hosts="$hosts_csv" scope="$port_scope" source="$port_source" \
      >/dev/null 2>&1 || true
  fi

  printf 'install-recipe: vendored %s @ %s -> %s\n' "$NAME" "$pinned_sha" "${vendor_dir#"$REPO_ROOT/"}" >&2
  printf 'install-recipe: portability.yaml written (source=%s, hosts=%s)\n' \
    "$port_source" "$(printf '%s\n' "$port_hosts_list" | paste -sd ',' -)" >&2

  src_idx=$((src_idx + 1))
done

# Fan-out (skip on dry-run).
if [ "$DRY_RUN" -eq 0 ] && [ "$overall_rc" -eq 0 ]; then
  if [ -x "$SCRIPT_DIR/sync-host-skills.sh" ]; then
    "$SCRIPT_DIR/sync-host-skills.sh" --all >/dev/null 2>&1 || \
      printf 'install-recipe: post-install sync-host-skills.sh --all reported drift; run manually to inspect\n' >&2
  fi
fi

exit "$overall_rc"
