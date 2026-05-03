#!/usr/bin/env bash
# Resolve Studio v2 canonical roles from canonical names or compatibility aliases.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/core/v2/registry/roles.json"
FORMAT="text"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-role-resolve.sh [--registry <path>] [--format text|json] <role-or-alias>
       scripts/v2-role-resolve.sh [--registry <path>] --list
USAGE
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-role-resolve: jq is required\n' >&2
    exit 3
  }
}

validate_registry() {
  [ -r "$REGISTRY" ] || {
    printf 'v2-role-resolve: registry not readable: %s\n' "$REGISTRY" >&2
    exit 3
  }

  jq -e '
    .schema_version == 1 and
    .kind == "studio-v2-role-registry" and
    (.roles | type == "array") and
    (.roles | length > 0) and
    ([.roles[].name] | unique | length) == (.roles | length)
  ' "$REGISTRY" >/dev/null 2>&1 || {
    printf 'v2-role-resolve: invalid role registry: %s\n' "$REGISTRY" >&2
    exit 3
  }

  jq -e '
    def norm: ascii_downcase | gsub("[ _]"; "-");
    ([.roles[] | .name, (.aliases // [])[] | norm] | length) ==
    ([.roles[] | .name, (.aliases // [])[] | norm] | unique | length)
  ' "$REGISTRY" >/dev/null 2>&1 || {
    printf 'v2-role-resolve: alias conflict in registry: %s\n' "$REGISTRY" >&2
    exit 3
  }
}

list_roles() {
  jq -r '.roles[].name' "$REGISTRY"
}

resolve_role() {
  local input="$1"
  local query
  query='
    def norm: ascii_downcase | gsub("[ _]"; "-");
    ($input | norm) as $needle |
    [
      .roles[]
      | select((.name | norm) == $needle or ((.aliases // []) | map(norm) | index($needle)))
    ] as $matches |
    if ($matches | length) == 1 then
      $matches[0] as $role |
      {
        schema_version: 1,
        input: $input,
        canonical_role: $role.name,
        matched_as: (if (($role.name | norm) == $needle) then "canonical" else "alias" end),
        role: $role
      }
    elif ($matches | length) == 0 then
      empty
    else
      error("ambiguous role alias: " + $input)
    end
  '

  if [ "$FORMAT" = "json" ]; then
    jq -e --arg input "$input" "$query" "$REGISTRY"
  else
    jq -er --arg input "$input" "$query | .canonical_role" "$REGISTRY"
  fi
}

require_jq

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REGISTRY="$2"
      shift 2
      ;;
    --format)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      FORMAT="$2"
      case "$FORMAT" in
        text|json) ;;
        *) usage; exit 2 ;;
      esac
      shift 2
      ;;
    --list)
      validate_registry
      list_roles
      exit 0
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
      validate_registry
      if ! resolve_role "$INPUT"; then
        printf 'v2-role-resolve: unknown role or alias: %s\n' "$INPUT" >&2
        exit 1
      fi
      exit 0
      ;;
  esac
done

usage
exit 2
