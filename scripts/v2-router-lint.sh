#!/usr/bin/env bash
# Validate Studio v2 router contracts and shell router boundaries.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MODE="full"
ERRORS=0
WARNINGS=0
ERROR_LINES=""
WARNING_LINES=""
CONTRACT_SCHEMA="$REPO_ROOT/core/v2/schemas/router-contract.schema.json"

case "${1:-}" in
  --staged) MODE="staged" ;;
  --full|"") MODE="full" ;;
  *) printf 'usage: v2-router-lint.sh [--staged|--full]\n' >&2; exit 2 ;;
esac

emit_error() {
  ERROR_LINES="${ERROR_LINES}${1}"$'\n'
  ERRORS=$((ERRORS + 1))
}

emit_warn() {
  WARNING_LINES="${WARNING_LINES}${1}"$'\n'
  WARNINGS=$((WARNINGS + 1))
}

rel_for() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

staged_paths() {
  git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
}

full_paths() {
  (
    cd "$REPO_ROOT" || exit 1
    find core/v2/routers -type f 2>/dev/null || true
  )
}

paths_to_check() {
  if [ "$MODE" = "staged" ]; then
    staged_paths | grep -E '^core/v2/routers/.*(\.sh|\.ya?ml)$' 2>/dev/null || true
  else
    full_paths | grep -E '^core/v2/routers/.*(\.sh|\.ya?ml)$' 2>/dev/null || true
  fi
}

require_tools() {
  command -v yq >/dev/null 2>&1 || emit_error "E_V2_TOOLING:yq | v2 router lint requires yq"
  command -v check-jsonschema >/dev/null 2>&1 || emit_error "E_V2_TOOLING:check-jsonschema | v2 router contract validation requires check-jsonschema"
}

yaml_value() {
  yq -r "$1" "$2" 2>/dev/null
}

check_contract() {
  local f="$1" rel soft hard
  rel=$(rel_for "$f")

  if ! yq -e '.' "$f" >/dev/null 2>&1; then
    emit_error "E_V2_ROUTER_CONTRACT:$rel | router contract must parse as YAML"
    return 0
  fi

  if [ ! -f "$CONTRACT_SCHEMA" ]; then
    emit_error "E_V2_ROUTER_CONTRACT:$rel | missing schema core/v2/schemas/router-contract.schema.json"
    return 0
  fi

  if ! check-jsonschema --schemafile "$CONTRACT_SCHEMA" "$f" >/dev/null 2>&1; then
    emit_error "E_V2_ROUTER_CONTRACT:$rel | router contract does not match router-contract.schema.json"
  fi

  soft=$(yaml_value '.complexity.soft_warn_non_comment_lines // ""' "$f")
  hard=$(yaml_value '.complexity.hard_max_non_comment_lines // ""' "$f")
  if [ "$soft" != "80" ]; then
    emit_error "E_V2_ROUTER_CONTRACT_FIELD:$rel:complexity.soft_warn_non_comment_lines=$soft | preserve A2a soft warning threshold 80"
  fi
  if [ "$hard" != "100" ]; then
    emit_error "E_V2_ROUTER_CONTRACT_FIELD:$rel:complexity.hard_max_non_comment_lines=$hard | preserve shipped A0.6 hard router limit 100"
  fi
}

check_router_shell() {
  local f="$1" rel count
  rel=$(rel_for "$f")
  count=$(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$f" | wc -l | tr -d ' ')

  if [ "$count" -gt 100 ]; then
    emit_error "E_V2_ROUTER_SIZE:$rel:${count}>100 | v2 routers stay dispatch-only; move logic to helpers"
  elif [ "$count" -ge 80 ]; then
    emit_warn "W_V2_ROUTER_SIZE:$rel:${count}>=80 | router is near the hard 100-line ceiling"
  fi

  if grep -nE '(xcodebuild|swift[[:space:]]+test|gh[[:space:]]+(issue|pr|release)|git[[:space:]]+push)' "$f" >/dev/null 2>&1; then
    emit_error "E_V2_ROUTER_LOGIC:$rel | routers must not embed build, test, GitHub, release, or push logic"
  fi
}

require_tools

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in
    core/v2/routers/*.sh) check_router_shell "$f" ;;
    core/v2/routers/*.yaml|core/v2/routers/*.yml) check_contract "$f" ;;
  esac
done < <(paths_to_check)

if [ "$WARNINGS" -gt 0 ]; then
  printf '%s' "$WARNING_LINES" >&2
fi

if [ "$ERRORS" -gt 0 ]; then
  printf 'v2-router-lint: %d errors (%s)\n' "$ERRORS" "$MODE" >&2
  printf '%s' "$ERROR_LINES" >&2
  exit 1
fi

printf 'v2-router-lint: ok (%s, warnings=%s)\n' "$MODE" "$WARNINGS" >&2
exit 0
