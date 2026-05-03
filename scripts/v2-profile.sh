#!/usr/bin/env bash
# v2-profile.sh - resolve and run Studio v2 project-profile operations.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

PROFILE=""
OPERATION=""
PROJECT_ROOT="${STUDIO_PROJECT_ROOT:-}"
DRY_RUN=0
VALIDATE=0
LIST=0
JSON=0

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/v2-profile.sh --profile <name|profile.yaml> --validate
  scripts/v2-profile.sh --profile <name|profile.yaml> --list [--json]
  scripts/v2-profile.sh --profile <name|profile.yaml> --operation <op> [--project-root <dir>] [--dry-run] [--] [args...]

Maps generic Studio v2 operations such as build, test:unit, lint, format,
release:beta, and release:prod to project-profile owned commands.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
    --profile=*) PROFILE="${1#--profile=}"; shift ;;
    --operation) OPERATION="${2:?--operation requires a value}"; shift 2 ;;
    --operation=*) OPERATION="${1#--operation=}"; shift ;;
    --project-root) PROJECT_ROOT="${2:?--project-root requires a dir}"; shift 2 ;;
    --project-root=*) PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --validate) VALIDATE=1; shift ;;
    --list) LIST=1; shift ;;
    --json) JSON=1; shift ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
EXTRA_ARGS=("$@")

[ -n "$PROFILE" ] || usage
command -v yq >/dev/null 2>&1 || { printf 'v2-profile: yq required\n' >&2; exit 2; }

profile_file_for() {
  case "$1" in
    */*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/profiles/$1/profile.yaml" ;;
  esac
}

PROFILE_FILE=$(profile_file_for "$PROFILE")
[ -f "$PROFILE_FILE" ] || {
  printf 'v2-profile: profile not found: %s\n' "$PROFILE_FILE" >&2
  exit 2
}
PROFILE_DIR=$(cd "$(dirname "$PROFILE_FILE")" && pwd)

yaml_has_key() {
  yq -e "has(\"$2\")" "$1" >/dev/null 2>&1
}

validate_authority() {
  local rel="$1" authority key
  authority="$PROFILE_DIR/$rel"
  [ -f "$authority" ] || {
    printf 'v2-profile: missing authority sidecar: %s\n' "$authority" >&2
    return 1
  }
  for key in action role filesystem commands secret_scopes mutation_scopes interactive headless_safe failure_classes override; do
    yaml_has_key "$authority" "$key" || {
      printf 'v2-profile: authority %s missing %s\n' "$authority" "$key" >&2
      return 1
    }
  done
}

validate_profile() {
  local op command authority hatch_count
  for key in schema_version kind profile operations rules; do
    yaml_has_key "$PROFILE_FILE" "$key" || {
      printf 'v2-profile: profile %s missing %s\n' "$PROFILE_FILE" "$key" >&2
      return 1
    }
  done
  [ "$(yq -r '.kind' "$PROFILE_FILE")" = "studio-v2-project-profile" ] || {
    printf 'v2-profile: unsupported profile kind in %s\n' "$PROFILE_FILE" >&2
    return 1
  }
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    command=$(OPERATION_KEY="$op" yq -r '.operations[env(OPERATION_KEY)].command // ""' "$PROFILE_FILE")
    authority=$(OPERATION_KEY="$op" yq -r '.operations[env(OPERATION_KEY)].authority // ""' "$PROFILE_FILE")
    [ -n "$command" ] && [ -x "$PROFILE_DIR/$command" ] || {
      printf 'v2-profile: operation %s command missing or not executable: %s\n' "$op" "$PROFILE_DIR/$command" >&2
      return 1
    }
    validate_authority "$authority" || return 1
  done < <(yq -r '.operations | keys | .[]' "$PROFILE_FILE")

  hatch_count=$(yq -r '(.plugin_escape_hatches // []) | length' "$PROFILE_FILE")
  [ "$hatch_count" -eq 0 ] || yq -e '
    (.plugin_escape_hatches // [])[] |
    has("authority") and has("commands") and has("generated_artifacts") and has("failure_behavior")
  ' "$PROFILE_FILE" >/dev/null
}

list_operations() {
  if [ "$JSON" -eq 1 ]; then
    yq -o=json '.operations' "$PROFILE_FILE"
  else
    yq -r '.operations | keys | .[]' "$PROFILE_FILE"
  fi
}

operation_field() {
  OPERATION="$OPERATION" yq -r ".operations[env(OPERATION)].$1 // \"\"" "$PROFILE_FILE"
}

operation_args() {
  OPERATION="$OPERATION" yq -r '.operations[env(OPERATION)].args[]? // ""' "$PROFILE_FILE"
}

run_operation() {
  local command authority
  [ -n "$OPERATION" ] || usage
  OPERATION="$OPERATION" yq -e '.operations[env(OPERATION)]' "$PROFILE_FILE" >/dev/null 2>&1 || {
    printf 'v2-profile: operation not defined in %s: %s\n' "$PROFILE_FILE" "$OPERATION" >&2
    exit 2
  }
  command=$(operation_field command)
  authority=$(operation_field authority)
  validate_authority "$authority"
  PROFILE_ARGS=()
  while IFS= read -r arg; do
    PROFILE_ARGS+=("$arg")
  done < <(operation_args)

  if [ "$DRY_RUN" -eq 1 ]; then
    jq -n \
      --arg profile "$(yq -r '.profile' "$PROFILE_FILE")" \
      --arg operation "$OPERATION" \
      --arg command "$PROFILE_DIR/$command" \
      --arg authority "$PROFILE_DIR/$authority" \
      --arg project_root "${PROJECT_ROOT:-}" \
      --argjson args "$(printf '%s\n' "${PROFILE_ARGS[@]}" | jq -R . | jq -s .)" \
      '{profile:$profile, operation:$operation, command:$command, authority:$authority, project_root:(if $project_root == "" then null else $project_root end), args:$args}'
    return 0
  fi

  [ -n "$PROJECT_ROOT" ] || {
    printf 'v2-profile: --project-root or STUDIO_PROJECT_ROOT is required for operation %s\n' "$OPERATION" >&2
    exit 2
  }
  STUDIO_PROJECT_ROOT="$PROJECT_ROOT" "$PROFILE_DIR/$command" "${PROFILE_ARGS[@]}" "${EXTRA_ARGS[@]}"
}

if [ "$VALIDATE" -eq 1 ]; then
  validate_profile
fi
if [ "$LIST" -eq 1 ]; then
  list_operations
fi
if [ -n "$OPERATION" ]; then
  run_operation
fi
if [ "$VALIDATE" -eq 0 ] && [ "$LIST" -eq 0 ] && [ -z "$OPERATION" ]; then
  usage
fi
