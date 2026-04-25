#!/usr/bin/env bash
# repair-vendored-portability.sh — backfill portability.yaml for vendored skills
# installed before #179 landed.
#
# Walks skills/vendored/*/<name>/ directories. For each that has a vendor.yaml
# but no portability.yaml, resolves portability via:
#   1. Recipe-explicit portability block (if the recipe file still exists)
#   2. Upstream content probes (.claude-plugin → claude-code, agents/openai.yaml → codex)
#   3. Default (claude-code only)
#
# Then runs sync-host-skills.sh --all to propagate the new portability.yaml
# files into each host's discovery dir.
#
# Usage:
#   scripts/repair-vendored-portability.sh [--dry-run]
#
# Exit:
#   0  all vendored skills now have portability.yaml
#   1  at least one skill could not be repaired

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VENDORED_ROOT="$REPO_ROOT/skills/vendored"
RECIPES_DIR="$REPO_ROOT/recipes"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if ! command -v yq >/dev/null 2>&1; then
  printf 'repair-vendored-portability: yq is required\n' >&2; exit 2
fi

repaired=0
skipped=0
failed=0

for vendor_yaml in "$VENDORED_ROOT"/*/*/vendor.yaml; do
  [ -f "$vendor_yaml" ] || continue
  vendor_dir=$(dirname "$vendor_yaml")
  skill_name=$(basename "$vendor_dir")

  if [ -f "$vendor_dir/portability.yaml" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  recipe_name=$(yq -r '.recipe // ""' "$vendor_yaml" 2>/dev/null)
  [ "$recipe_name" = "null" ] && recipe_name=""

  # 1. Recipe-explicit portability?
  port_source="default"
  port_hosts_list="claude-code"
  port_scope="global"

  if [ -n "$recipe_name" ]; then
    recipe_file=$(find "$RECIPES_DIR" -type f -name "${recipe_name}.yaml" -not -path "*/profiles/*" 2>/dev/null | head -1)
    if [ -n "$recipe_file" ]; then
      rp_hosts=$(yq -r '.portability.hosts // [] | .[]' "$recipe_file" 2>/dev/null)
      rp_scope=$(yq -r '.portability.scope // ""' "$recipe_file" 2>/dev/null)
      [ "$rp_scope" = "null" ] && rp_scope=""
      if [ -n "$rp_hosts" ]; then
        port_source="recipe"
        port_hosts_list="$rp_hosts"
        [ -n "$rp_scope" ] && port_scope="$rp_scope"
      fi
    fi
  fi

  # 2. Probe vendored content if no recipe-explicit portability.
  if [ "$port_source" = "default" ]; then
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

  hosts_csv=$(printf '%s\n' "$port_hosts_list" | paste -sd ',' -)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s → portability.yaml (source=%s, hosts=%s, scope=%s)\n' \
      "${vendor_dir#"$REPO_ROOT/"}" "$port_source" "$hosts_csv" "$port_scope"
    repaired=$((repaired + 1))
    continue
  fi

  {
    printf 'schema_version: 1\nhosts:\n'
    printf '%s\n' "$port_hosts_list" | while IFS= read -r h; do
      [ -z "$h" ] && continue
      printf '  - %s\n' "$h"
    done
    printf 'scope: %s\n' "$port_scope"
  } > "$vendor_dir/portability.yaml" || { failed=$((failed + 1)); continue; }

  printf 'repaired: %s (source=%s, hosts=%s)\n' \
    "${vendor_dir#"$REPO_ROOT/"}" "$port_source" "$hosts_csv" >&2

  if [ "$port_source" != "recipe" ] && [ -x "$SCRIPT_DIR/emit-event.sh" ]; then
    "$SCRIPT_DIR/emit-event.sh" recipe_portability_inferred \
      recipe="$skill_name" hosts="$hosts_csv" scope="$port_scope" source="$port_source" \
      >/dev/null 2>&1 || true
  fi

  repaired=$((repaired + 1))
done

printf '\nrepair-vendored-portability: repaired=%d skipped=%d failed=%d\n' \
  "$repaired" "$skipped" "$failed" >&2

if [ "$DRY_RUN" -eq 0 ] && [ "$repaired" -gt 0 ] && [ -x "$SCRIPT_DIR/sync-host-skills.sh" ]; then
  printf 'repair-vendored-portability: running sync-host-skills.sh --all\n' >&2
  "$SCRIPT_DIR/sync-host-skills.sh" --all 2>&1
fi

[ "$failed" -eq 0 ] || exit 1
exit 0
