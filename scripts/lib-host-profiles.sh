#!/usr/bin/env bash
# lib-host-profiles.sh - data access for declarative Studio host profiles.
#
# This library is intentionally sourceable and side-effect-light. It validates
# and reads host profile files, but it does not run host binaries or eligibility
# smoke commands.
#
# Public functions:
#   host_profile_load_file [path]
#   host_profile_get <host_id>
#   host_profile_list_for_capability <capability>
#
# host_profile_get emits a JSON object for the requested host profile.
# host_profile_list_for_capability emits one host id per line in resolver order.

# No `set -e` here - sourced into scripts that choose their own shell policy.

HOST_PROFILES_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
HOST_PROFILES_REPO_ROOT=$(cd "$HOST_PROFILES_LIB_DIR/.." && pwd)
HOST_PROFILES_DEFAULT_FILE="$HOST_PROFILES_REPO_ROOT/_shared/host-profiles/default.yaml"

: "${HOST_PROFILE_LOADED_FILE:=}"
: "${HOST_PROFILE_LAST_ERROR:=}"

HOST_PROFILE_REQUIRED_FIELDS=$(cat <<'EOF'
host_id
binary_path
auth_home
github_home
capabilities
synthetic_home_behavior
eligibility_smoke_command
EOF
)

_host_profile_fail() {
  HOST_PROFILE_LAST_ERROR="$*"
  printf 'lib-host-profiles: %s\n' "$*" >&2
  return 1
}

_host_profile_require_tools() {
  command -v yq >/dev/null 2>&1 || {
    _host_profile_fail "yq is required for host profile YAML parsing"
    return 127
  }
  command -v jq >/dev/null 2>&1 || {
    _host_profile_fail "jq is required for host profile JSON emission"
    return 127
  }
}

_host_profile_resolve_file() {
  if [ -n "${HOST_PROFILE_LOADED_FILE:-}" ]; then
    printf '%s\n' "$HOST_PROFILE_LOADED_FILE"
    return 0
  fi
  if [ -n "${STUDIO_HOST_PROFILE_FILE:-}" ]; then
    printf '%s\n' "$STUDIO_HOST_PROFILE_FILE"
    return 0
  fi
  printf '%s\n' "$HOST_PROFILES_DEFAULT_FILE"
}

_host_profile_allowed_capability() {
  case "${1:-}" in
    worker|reviewer|planner|perf) return 0 ;;
    *) return 1 ;;
  esac
}

_host_profile_env_order_lines() {
  awk -v order="${STUDIO_AUTO_HOST_ORDER:-}" 'BEGIN {
    n = split(order, parts, /[[:space:],]+/)
    for (i = 1; i <= n; i++) {
      if (parts[i] != "") {
        print parts[i]
      }
    }
  }'
}

_host_profile_validate_file() {
  local file="${1:?usage: _host_profile_validate_file <path>}" json

  _host_profile_require_tools || return $?

  [ -f "$file" ] || {
    _host_profile_fail "profile file not found: $file"
    return 1
  }

  json=$(yq -o=json '.' "$file" 2>/dev/null) || {
    _host_profile_fail "profile file does not parse as YAML: $file"
    return 1
  }

  printf '%s\n' "$json" | jq -e --argjson required "$(printf '%s\n' "$HOST_PROFILE_REQUIRED_FIELDS" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
    def allowed_capability:
      . == "worker" or . == "reviewer" or . == "planner" or . == "perf";
    (.schema_version == 1)
    and (.kind == "host-profiles")
    and (.default_order | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.profiles | type == "object" and length > 0)
    and (
      .profiles
      | to_entries
      | all(.[]; . as $entry | (
          ($entry.value | type == "object")
          and (($entry.value | keys | sort) == ($required | sort))
          and ($entry.value.host_id == $entry.key)
          and (["host_id", "binary_path", "auth_home", "github_home", "synthetic_home_behavior", "eligibility_smoke_command"] | all(. as $field | ($entry.value[$field] | type == "string" and length > 0)))
          and ($entry.value.capabilities | type == "array" and length > 0 and all(.[]; type == "string" and allowed_capability))
        ))
    )
    and (
      . as $root
      | .default_order
      | all(.[]; ($root.profiles[.] // null) != null)
    )
  ' >/dev/null 2>&1 || {
    _host_profile_fail "profile file violates host profile contract: $file"
    return 1
  }
}

host_profile_load_file() {
  local file="${1:-}"

  if [ -z "$file" ]; then
    if [ -n "${STUDIO_HOST_PROFILE_FILE:-}" ]; then
      file="$STUDIO_HOST_PROFILE_FILE"
    else
      file="$HOST_PROFILES_DEFAULT_FILE"
    fi
  fi

  _host_profile_validate_file "$file" || return 1
  HOST_PROFILE_LOADED_FILE="$file"
}

host_profile_get() {
  local host_id="${1:-}" file profile_json

  [ -n "$host_id" ] || {
    _host_profile_fail "usage: host_profile_get <host_id>"
    return 2
  }

  file=$(_host_profile_resolve_file)
  _host_profile_validate_file "$file" || return 1

  profile_json=$(yq -o=json '.' "$file" \
    | jq -e --arg host_id "$host_id" '.profiles[$host_id] // empty') || {
      _host_profile_fail "unknown host profile: $host_id"
      return 1
    }

  printf '%s\n' "$profile_json"
}

host_profile_list_for_capability() {
  local capability="${1:-}" file json order_json missing_hosts result

  [ -n "$capability" ] || {
    _host_profile_fail "usage: host_profile_list_for_capability <capability>"
    return 2
  }
  _host_profile_allowed_capability "$capability" || {
    _host_profile_fail "unsupported host capability: $capability"
    return 2
  }

  file=$(_host_profile_resolve_file)
  _host_profile_validate_file "$file" || return 1
  json=$(yq -o=json '.' "$file") || return 1

  if [ -n "${STUDIO_AUTO_HOST_ORDER:-}" ]; then
    order_json=$(_host_profile_env_order_lines | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    order_json=$(printf '%s\n' "$json" | jq -c '.default_order')
  fi

  missing_hosts=$(printf '%s\n' "$json" \
    | jq -r --argjson order "$order_json" '. as $root | [ $order[] | select(. as $id | ($root.profiles[$id] // null) == null) ] | join(",")')
  if [ -n "$missing_hosts" ]; then
    _host_profile_fail "host order references unknown profile(s): $missing_hosts"
    return 1
  fi

  result=$(printf '%s\n' "$json" \
    | jq -r --arg capability "$capability" --argjson order "$order_json" '
        . as $root
        |
        [
          $order[]
          | select(. as $id | ($root.profiles[$id].capabilities | index($capability)) != null)
        ]
        | .[]
      ')

  if [ -z "$result" ]; then
    _host_profile_fail "no host profiles provide capability: $capability"
    return 1
  fi

  printf '%s\n' "$result"
}
