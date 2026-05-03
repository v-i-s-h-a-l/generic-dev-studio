#!/usr/bin/env bash
# Validate and resolve Studio v2 executable role contracts.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONTRACT_DIR="$REPO_ROOT/core/v2/roles"
FORMAT="text"
ACTION=""
ROLE=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-role-contract.sh [--contract-dir <dir>] --validate
       scripts/v2-role-contract.sh [--contract-dir <dir>] --list
       scripts/v2-role-contract.sh [--contract-dir <dir>] --resolve --role <role-or-alias> [--format text|json]
USAGE
}

require_tools() {
  command -v yq >/dev/null 2>&1 || {
    printf 'v2-role-contract: yq is required\n' >&2
    exit 3
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-role-contract: jq is required\n' >&2
    exit 3
  }
}

contract_files() {
  find "$CONTRACT_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
}

role_for_file() {
  yq -r '.role // ""' "$1"
}

validate_contract_file() {
  local file="$1" rel key role
  case "$file" in
    "$REPO_ROOT"/*) rel="${file#"$REPO_ROOT/"}" ;;
    *) rel="$file" ;;
  esac

  for key in schema_version kind parent_issue leaf_issue status role purpose inputs outputs reads writes idempotency_key decision_rights escalation_triggers failure_semantics verification_floor; do
    yq -e "has(\"$key\")" "$file" >/dev/null 2>&1 || {
      printf 'v2-role-contract: %s missing %s\n' "$rel" "$key" >&2
      return 1
    }
  done

  yq -e '.schema_version == 1 and .kind == "studio-v2-role-contract" and .parent_issue == 444 and .leaf_issue == 526' "$file" >/dev/null 2>&1 || {
    printf 'v2-role-contract: invalid contract envelope: %s\n' "$rel" >&2
    return 1
  }

  role=$(role_for_file "$file")
  "$REPO_ROOT/scripts/v2-role-resolve.sh" "$role" >/dev/null 2>&1 || {
    printf 'v2-role-contract: unknown role in %s: %s\n' "$rel" "$role" >&2
    return 1
  }

  case "$role" in
    worker|reviewer|perf) ;;
    *)
      printf 'v2-role-contract: A8 contract has out-of-scope role in %s: %s\n' "$rel" "$role" >&2
      return 1
      ;;
  esac

  yq -e '(.inputs | length > 0) and (.outputs | length > 0) and (.reads | length > 0) and (.writes | length > 0) and (.decision_rights | length > 0) and (.escalation_triggers | length > 0) and (.failure_semantics | length > 0) and (.verification_floor | length > 0)' "$file" >/dev/null 2>&1 || {
    printf 'v2-role-contract: empty contract section in %s\n' "$rel" >&2
    return 1
  }
}

validate_contracts() {
  [ -d "$CONTRACT_DIR" ] || {
    printf 'v2-role-contract: contract directory not found: %s\n' "$CONTRACT_DIR" >&2
    exit 3
  }

  local file role roles
  roles=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    validate_contract_file "$file" || exit 3
    role=$(role_for_file "$file")
    roles="${roles}${role}"$'\n'
  done < <(contract_files)

  for role in worker reviewer perf; do
    printf '%s' "$roles" | grep -Fxq "$role" || {
      printf 'v2-role-contract: missing A8 role contract: %s\n' "$role" >&2
      exit 3
    }
  done

  [ "$(printf '%s' "$roles" | sed '/^$/d' | sort | uniq -d | wc -l | tr -d ' ')" = "0" ] || {
    printf 'v2-role-contract: duplicate role contracts\n' >&2
    exit 3
  }
}

list_contracts() {
  validate_contracts
  contract_files | while IFS= read -r file; do
    role_for_file "$file"
  done
}

resolve_contract() {
  [ -n "$ROLE" ] || { usage; exit 2; }
  validate_contracts

  local canonical file
  canonical=$("$REPO_ROOT/scripts/v2-role-resolve.sh" "$ROLE") || {
    printf 'v2-role-contract: unknown role or alias: %s\n' "$ROLE" >&2
    exit 1
  }

  case "$canonical" in
    worker|reviewer|perf) ;;
    *)
      printf 'v2-role-contract: role has no A8 migrated contract: %s\n' "$canonical" >&2
      exit 1
      ;;
  esac

  file="$CONTRACT_DIR/$canonical.yaml"
  [ -f "$file" ] || {
    printf 'v2-role-contract: contract missing for role: %s\n' "$canonical" >&2
    exit 3
  }

  if [ "$FORMAT" = "json" ]; then
    yq -o=json "$file" | jq --arg file "${file#"$REPO_ROOT/"}" '. + {contract_file: $file}'
  else
    printf '%s\n' "${file#"$REPO_ROOT/"}"
  fi
}

require_tools

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --contract-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CONTRACT_DIR="$2"
      shift 2
      ;;
    --validate)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="validate"
      shift
      ;;
    --list)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="list"
      shift
      ;;
    --resolve)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="resolve"
      shift
      ;;
    --role)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ROLE="$2"
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$ACTION" in
  validate)
    validate_contracts
    printf 'v2-role-contract: ok\n' >&2
    ;;
  list)
    list_contracts
    ;;
  resolve)
    resolve_contract
    ;;
  *)
    usage
    exit 2
    ;;
esac
