#!/usr/bin/env bash
# lint-html-theme.sh - enforce system-adaptive light/dark theme support in generated HTML.
#
# Usage:
#   scripts/lint-html-theme.sh [--staged|--full]
#
# Override:
#   STUDIO_BYPASS_HTML_THEME_GUARD=1 scripts/lint-html-theme.sh --staged

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

MODE="full"
case "${1:-}" in
  --staged) MODE="staged" ;;
  --full|"") MODE="full" ;;
  *) printf 'usage: lint-html-theme.sh [--staged|--full]\n' >&2; exit 2 ;;
esac

if [ "${STUDIO_BYPASS_HTML_THEME_GUARD:-0}" = "1" ]; then
  printf 'lint-html-theme: skipped by STUDIO_BYPASS_HTML_THEME_GUARD=1 (%s)\n' "$MODE" >&2
  exit 0
fi

ERRORS=0

emit_error() {
  printf '%s\n' "$1" >&2
  ERRORS=$((ERRORS + 1))
}

html_paths() {
  if [ "$MODE" = "staged" ]; then
    git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.html$' || true
  else
    find "$REPO_ROOT" -type f -name '*.html' 2>/dev/null | sed "s#^$REPO_ROOT/##"
  fi
}

check_file() {
  local rel="$1" abs="$REPO_ROOT/$1"
  [ -f "$abs" ] || {
    emit_error "E_HTML_THEME_MISSING:$rel | missing file"
    return 0
  }

  if ! grep -Fq '<meta name="color-scheme" content="light dark">' "$abs"; then
    emit_error "E_HTML_THEME_META:$rel | add <meta name=\"color-scheme\" content=\"light dark\">"
  fi
  if ! grep -Fq 'color-scheme: light dark;' "$abs"; then
    emit_error "E_HTML_THEME_CSS:$rel | add :root { color-scheme: light dark; }"
  fi
  if ! grep -Fq '@media (prefers-color-scheme: dark)' "$abs"; then
    emit_error "E_HTML_THEME_DARK_MEDIA:$rel | add a dark-mode media query override"
  fi
  if grep -Fq 'color-scheme: light;' "$abs"; then
    emit_error "E_HTML_THEME_LIGHT_ONLY:$rel | replace hard-coded light-only color-scheme with light dark"
  fi
}

FOUND=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  FOUND=1
  check_file "$path"
done < <(html_paths)

if [ "$FOUND" -eq 0 ]; then
  printf 'lint-html-theme: ok (%s, no HTML surface)\n' "$MODE" >&2
  exit 0
fi

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-html-theme: %d errors (%s)\n' "$ERRORS" "$MODE" >&2
  exit 1
fi

printf 'lint-html-theme: ok (%s)\n' "$MODE" >&2
exit 0
