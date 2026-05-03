#!/usr/bin/env bash
# Resolve repo-vendored Studio v2 skill artifacts without mutating host registries.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FORMAT="json"
LIST=0

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-skill-load.sh [--root <repo>] [--format json|path|prompt] <skill-name>
       scripts/v2-skill-load.sh [--root <repo>] --list [--format text|json]

Resolves skills from skills/vendored/** only. The loader is read-only: it does
not create symlinks and does not mutate any host global skill registry.
USAGE
}

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-skill-load: jq is required\n' >&2
    exit 3
  }
  command -v yq >/dev/null 2>&1 || {
    printf 'v2-skill-load: yq is required\n' >&2
    exit 3
  }
}

rel_for() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

skill_frontmatter_json() {
  local skill_md="$1"
  awk '
    NR == 1 && $0 == "---" { in_frontmatter=1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter { print }
  ' "$skill_md" | yq -o=json '.'
}

skill_name_for_dir() {
  local dir="$1" name
  name=$(skill_frontmatter_json "$dir/SKILL.md" | jq -r '.name // empty') || return 1
  [ -n "$name" ] || name=$(basename "$dir")
  printf '%s\n' "$name"
}

validate_skill_dir() {
  local dir="$1" rel pinned path_declared
  rel=$(rel_for "$dir")
  for file in SKILL.md vendor.yaml portability.yaml; do
    [ -f "$dir/$file" ] || {
      printf 'v2-skill-load: invalid vendored skill %s: missing %s\n' "$rel" "$file" >&2
      return 1
    }
  done

  pinned=$(yq -r '.pinned_sha // ""' "$dir/vendor.yaml")
  if ! printf '%s\n' "$pinned" | grep -Eq '^[0-9a-f]{40}$'; then
    printf 'v2-skill-load: invalid vendored skill %s: pinned_sha must be a 40-character lowercase git SHA\n' "$rel" >&2
    return 1
  fi

  path_declared=$(yq -r '.path // ""' "$dir/vendor.yaml")
  if [ -n "$path_declared" ] && [ "$path_declared" != "$(basename "$dir")/" ]; then
    printf 'v2-skill-load: invalid vendored skill %s: vendor.yaml path must match directory basename\n' "$rel" >&2
    return 1
  fi

  yq -e '(.hosts | type == "!!seq" and length > 0) and (.scope == "global" or .scope == "project")' "$dir/portability.yaml" >/dev/null 2>&1 || {
    printf 'v2-skill-load: invalid vendored skill %s: portability.yaml must declare hosts and scope\n' "$rel" >&2
    return 1
  }
}

find_skill_dir() {
  local wanted="$1" dir found="" name
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    name=$(skill_name_for_dir "$dir") || continue
    if [ "$name" = "$wanted" ] || [ "$(basename "$dir")" = "$wanted" ]; then
      if [ -n "$found" ]; then
        printf 'v2-skill-load: ambiguous skill name: %s\n' "$wanted" >&2
        exit 1
      fi
      found="$dir"
    fi
  done < <(find "$REPO_ROOT/skills/vendored" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)

  [ -n "$found" ] || {
    printf 'v2-skill-load: unknown vendored skill: %s\n' "$wanted" >&2
    exit 1
  }
  printf '%s\n' "$found"
}

artifact_json_for_dir() {
  local dir="$1" frontmatter vendor portability references
  validate_skill_dir "$dir" || exit 1
  frontmatter=$(skill_frontmatter_json "$dir/SKILL.md") || {
    printf 'v2-skill-load: invalid SKILL.md frontmatter: %s\n' "$(rel_for "$dir/SKILL.md")" >&2
    exit 1
  }
  vendor=$(yq -o=json '.' "$dir/vendor.yaml")
  portability=$(yq -o=json '.' "$dir/portability.yaml")
  references=$(find "$dir/references" -type f 2>/dev/null | sort | while IFS= read -r ref; do rel_for "$ref"; done | jq -R . | jq -s .)

  jq -n \
    --argjson frontmatter "$frontmatter" \
    --argjson vendor "$vendor" \
    --argjson portability "$portability" \
    --arg root "$(rel_for "$dir")" \
    --arg skill_md "$(rel_for "$dir/SKILL.md")" \
    --arg vendor_yaml "$(rel_for "$dir/vendor.yaml")" \
    --arg portability_yaml "$(rel_for "$dir/portability.yaml")" \
    --argjson references "$references" \
    '{
      schema_version: 1,
      kind: "studio-v2-vendored-skill-artifact",
      parent_issue: 444,
      leaf_issue: 518,
      skill: {
        name: ($frontmatter.name // ""),
        description: ($frontmatter.description // ""),
        license: ($frontmatter.license // $vendor.license // ""),
        metadata_version: (($frontmatter.metadata.version // "") | tostring)
      },
      source: {
        upstream: ($vendor.upstream // ""),
        pinned_sha: ($vendor.pinned_sha // ""),
        recipe: ($vendor.recipe // ""),
        strategy: ($vendor.strategy // ""),
        vendored_at: (($vendor.vendored_at // "") | tostring)
      },
      paths: {
        root: $root,
        skill_md: $skill_md,
        vendor_yaml: $vendor_yaml,
        portability_yaml: $portability_yaml,
        references: $references
      },
      portability: {
        hosts: ($portability.hosts // []),
        scope: ($portability.scope // "")
      }
    }'
}

list_skills() {
  local dir artifact
  if [ "$FORMAT" = "text" ]; then
    find "$REPO_ROOT/skills/vendored" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while IFS= read -r dir; do
      validate_skill_dir "$dir" >/dev/null || exit 1
      skill_name_for_dir "$dir"
    done
    return 0
  fi

  [ "$FORMAT" = "json" ] || { usage; exit 2; }
  {
    printf '['
    first=1
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      artifact=$(artifact_json_for_dir "$dir")
      if [ "$first" -eq 0 ]; then
        printf ','
      fi
      first=0
      printf '%s' "$artifact"
    done < <(find "$REPO_ROOT/skills/vendored" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
    printf ']\n'
  } | jq '.'
}

require_tools

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --format)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      FORMAT="$2"
      case "$FORMAT" in
        json|path|prompt|text) ;;
        *) usage; exit 2 ;;
      esac
      shift 2
      ;;
    --list)
      LIST=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      INPUT="$1"
      shift
      [ "$#" -eq 0 ] || { usage; exit 2; }
      ;;
  esac
done

REPO_ROOT=$(cd "$REPO_ROOT" && pwd)

if [ "$LIST" -eq 1 ]; then
  [ "${INPUT:-}" = "" ] || { usage; exit 2; }
  list_skills
  exit 0
fi

[ -n "${INPUT:-}" ] || { usage; exit 2; }

SKILL_DIR=$(find_skill_dir "$INPUT")
case "$FORMAT" in
  json)
    artifact_json_for_dir "$SKILL_DIR"
    ;;
  path)
    validate_skill_dir "$SKILL_DIR" || exit 1
    rel_for "$SKILL_DIR/SKILL.md"
    ;;
  prompt)
    validate_skill_dir "$SKILL_DIR" || exit 1
    sed '1{/^---$/!q;d;}; /^---$/,$!d; /^---$/d' "$SKILL_DIR/SKILL.md"
    ;;
  text)
    usage
    exit 2
    ;;
esac
