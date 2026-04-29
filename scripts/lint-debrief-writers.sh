#!/usr/bin/env bash
# lint-debrief-writers.sh — block active legacy debrief write targets.
#
# Active debrief producers must write YAML through scripts/lib-ledger.sh
# `write_debrief_artifact`, landing under plans/debriefs/<debrief-id>.yaml.
# Legacy markdown and chanakya-inbox debrief paths are read/diagnostic-only.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

STAGED=0
if [ "${1:-}" = "--staged" ]; then
  STAGED=1
fi

ERRORS=0

emit_error() {
  printf '%s\n' "$1"
  ERRORS=$((ERRORS + 1))
}

is_allowed_legacy_reader() {
  case "$1" in
    scripts/analyze-collect.sh|\
    scripts/archive-legacy-surfaces.sh|\
    scripts/backfill-legacy-yaml.sh|\
    scripts/detect-edits.sh|\
    scripts/lib-ledger.sh|\
    scripts/lint-debrief-writers.sh|\
    scripts/migrate-ledger.sh|\
    scripts/sweep-enumerate-debriefs.sh|\
    scripts/tests-pull-cases.sh|\
    scripts/verify-ledger.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

script_targets() {
  if [ "$STAGED" -eq 1 ]; then
    git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
      | grep -E '^scripts/.*\.sh$' \
      | grep -vE '^scripts/test-fixtures/' || true
  else
    (cd "$REPO_ROOT" && find scripts -path scripts/test-fixtures -prune -o -type f -name '*.sh' -print)
  fi
}

mode_targets() {
  if [ "$STAGED" -eq 1 ]; then
    git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
      | grep -E '(^|/)SKILL\.md$|/modes/[^/]+\.md$' || true
  else
    (cd "$REPO_ROOT" && find . -path ./.git -prune -o \( -name SKILL.md -o -path '*/modes/*.md' \) -type f -print | sed 's|^\./||')
  fi
}

scan_script() {
  local rel="$1" file="$REPO_ROOT/$rel"
  [ -f "$file" ] || return 0
  is_allowed_legacy_reader "$rel" && return 0

  local hit line_no line
  hit=$(awk '
    /^[[:space:]]*#/ { next }
    /legacy_inbox_write_debrief/ { print NR ":" $0; exit }
    /plans\/chanakya-inbox\/[^[:space:]]*debrief[^[:space:]]*\.(md|yaml)/ { print NR ":" $0; exit }
    /chanakya-inbox.*-debrief\.(md|yaml)/ { print NR ":" $0; exit }
    /plans\/debriefs\/[^[:space:]]*\.md/ { print NR ":" $0; exit }
    /-debrief\.md/ && /(cat[[:space:]]*>|printf|tee|touch|cp[[:space:]]|mv[[:space:]]|>|OUT=|DEST=|TARGET=|DEBRIEF=|FILE=|path=)/ { print NR ":" $0; exit }
  ' "$file" 2>/dev/null || true)

  [ -z "$hit" ] && return 0
  line_no="${hit%%:*}"
  line="${hit#*:}"
  emit_error "E_DEBRIEF_LEGACY_WRITE:$rel:$line_no:active script references legacy debrief write target: $line | use write_debrief_artifact -> plans/debriefs/<debrief-id>.yaml"
}

scan_mode_pack() {
  local rel="$1" file="$REPO_ROOT/$rel"
  [ -f "$file" ] || return 0

  local hit line_no line
  hit=$(awk '
    /^```/ { in_code = 1 - in_code; next }
    in_code { next }
    /write .*chanakya-inbox.*debrief/ { print NR ":" $0; exit }
    /write .*debrief markdown/ { print NR ":" $0; exit }
    /debrief markdown.*chanakya-inbox/ { print NR ":" $0; exit }
    /chanakya-inbox.*-debrief\.(md|yaml)/ { print NR ":" $0; exit }
    /write .*plans\/debriefs\/[^[:space:]]*\.md/ { print NR ":" $0; exit }
  ' "$file" 2>/dev/null || true)

  [ -z "$hit" ] && return 0
  line_no="${hit%%:*}"
  line="${hit#*:}"
  emit_error "E_DEBRIEF_LEGACY_WRITE:$rel:$line_no:mode prose points at retired debrief write target: $line | reference _shared/contracts/debrief-format.md and write YAML only"
}

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  scan_script "$rel"
done < <(script_targets)

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  scan_mode_pack "$rel"
done < <(mode_targets)

printf 'lint-debrief-writers: %d errors\n' "$ERRORS" >&2
[ "$ERRORS" -eq 0 ]
