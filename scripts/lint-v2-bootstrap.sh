#!/usr/bin/env bash
# lint-v2-bootstrap.sh - A0.4 bootstrap-only gate for the Studio v2 substrate.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

MODE="full"
case "${1:-}" in
  --staged) MODE="staged" ;;
  --full|"") MODE="full" ;;
  *) printf 'usage: lint-v2-bootstrap.sh [--staged|--full]\n' >&2; exit 2 ;;
esac

ERRORS=0
ERROR_LINES=""

emit_error() {
  ERROR_LINES="${ERROR_LINES}${1}"$'\n'
  ERRORS=$((ERRORS + 1))
}

require_file() {
  local rel="$1"
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    emit_error "E_V2_BOOTSTRAP_MISSING:$rel | restore the A0.4 bootstrap skeleton"
  fi
}

spec_signed_off() {
  local spec="$REPO_ROOT/core/v2/SPEC.md"
  [ -f "$spec" ] && grep -Fxq '<!-- v2-bootstrap:a0.5-sign-off:complete -->' "$spec"
}

changed_paths() {
  if [ "$MODE" = "staged" ]; then
    git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
  else
    {
      find "$REPO_ROOT/core" -type f 2>/dev/null
      find "$REPO_ROOT/profiles" -type f 2>/dev/null
    } | sed "s#^$REPO_ROOT/##"
  fi
}

is_substrate_path() {
  case "$1" in
    core/*|profiles/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_pre_signoff_allowed_path() {
  case "$1" in
    core/v2/hooks/pre-commit) return 0 ;;
    *.md|*.yaml|*.yml|*.json|*.schema.json) return 0 ;;
    *) return 1 ;;
  esac
}

is_code_like_path() {
  case "$1" in
    *.sh|*.bash|*.zsh|*.py|*.rb|*.js|*.jsx|*.ts|*.tsx|*.swift|*.go|*.rs|*.java|*.kt|*.m|*.mm|*.c|*.cc|*.cpp|*.h|*.hpp) return 0 ;;
  esac
  if [ -f "$REPO_ROOT/$1" ] && head -n 1 "$REPO_ROOT/$1" 2>/dev/null | grep -q '^#!'; then
    return 0
  fi
  return 1
}

check_required_skeleton() {
  require_file "core/v2/bootstrap.yaml"
  require_file "core/v2/schemas/bootstrap.schema.json"
  require_file "core/v2/BOOTSTRAP.md"
  require_file "core/v2/hooks/pre-commit"

  if [ -f "$REPO_ROOT/.githooks/pre-commit" ] && \
     ! grep -q 'lint-v2-bootstrap.sh --staged' "$REPO_ROOT/.githooks/pre-commit"; then
    emit_error "E_V2_BOOTSTRAP_HOOK:.githooks/pre-commit | delegate to scripts/lint-v2-bootstrap.sh --staged"
  fi
}

check_required_anchors() {
  local bootstrap="$REPO_ROOT/core/v2/BOOTSTRAP.md"
  [ -f "$bootstrap" ] || return 0
  local anchor
  for anchor in \
    '<!-- v2-bootstrap:a0.4-scope -->' \
    '<!-- v2-bootstrap:schema-presence -->' \
    '<!-- v2-bootstrap:required-anchors -->' \
    '<!-- v2-bootstrap:pre-a0.5-code-freeze -->' \
    '<!-- v2-bootstrap:a0.6-deferred-rules -->'
  do
    if ! grep -Fxq "$anchor" "$bootstrap"; then
      emit_error "E_V2_BOOTSTRAP_ANCHOR:core/v2/BOOTSTRAP.md:missing=$anchor | restore the required A0.4 anchor"
    fi
  done
}

check_manifest_rule_boundary() {
  local manifest="$REPO_ROOT/core/v2/bootstrap.yaml"
  [ -f "$manifest" ] || return 0
  local allowed
  allowed='schema_presence|required_anchors|pre_a0_5_code_freeze|a0_6_deferred_rules'
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if ! printf '%s\n' "$rule" | grep -Eq "^($allowed)$"; then
      emit_error "E_V2_BOOTSTRAP_RULE:core/v2/bootstrap.yaml:$rule | A0.4 may only enforce bootstrap/meta rules; defer SPEC-derived rules to A0.6"
    fi
  done < <(
    awk '
      /^enforced_rules:[[:space:]]*$/ { in_rules=1; next }
      in_rules && /^[^[:space:]]/ { exit }
      in_rules && /^[[:space:]]*-[[:space:]]*/ {
        v=$0
        sub(/^[[:space:]]*-[[:space:]]*/, "", v)
        print v
      }
    ' "$manifest"
  )
}

check_pre_signoff_freeze() {
  spec_signed_off && return 0
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    is_substrate_path "$path" || continue
    if is_code_like_path "$path" && ! is_pre_signoff_allowed_path "$path"; then
      emit_error "E_V2_PRE_A05_CODE:$path | substrate implementation code requires A0.5 SPEC sign-off"
    fi
  done < <(changed_paths)
}

check_required_skeleton
check_required_anchors
check_manifest_rule_boundary
check_pre_signoff_freeze

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-v2-bootstrap: %d errors (%s)\n' "$ERRORS" "$MODE" >&2
  printf '%s' "$ERROR_LINES" >&2
  exit 1
fi

printf 'lint-v2-bootstrap: ok (%s)\n' "$MODE" >&2
exit 0
