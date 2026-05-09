#!/usr/bin/env bash
# lint-synthetic-home.sh — block ad-hoc synthetic-home special casing outside
# the resolver layer (#710 Phase C3, #816).
#
# scripts/lib-studio-context.sh and scripts/lib-paths.sh centralize
# synthetic-home detection (`studio_home_is_synthetic`,
# `_studio_context_login_home`, `_studio_context_default_studio_home`) so
# production scripts don't have to reason about whether the current `$HOME`
# is a Codex synthetic root, a Claude turnip workspace, or the canonical
# login home. Hand-rolled `[ "$HOME" = ... ]`, `case "$HOME" in ...`, or
# inline reimplementations of the `*/.codex-homes/*` marker drift from the
# resolver invariants and re-introduce the bug class the resolver was built
# to prevent.
#
# Modes:
#   scripts/lint-synthetic-home.sh --staged    # pre-commit: scan added lines
#                                              # in the staged diff
#   scripts/lint-synthetic-home.sh --strict    # CI: scan whole tree, but
#                                              # honor the baseline allowlist
#                                              # for files that pre-date the
#                                              # lint
#   scripts/lint-synthetic-home.sh <file> ...  # ad-hoc whole-file scan
#
# Scope (per #816 acceptance #1):
#   scripts/*.sh, core/**/*.sh, hooks/* (text shell scripts)
#
# Always-exempt:
#   - scripts/lib-studio-context.sh   (resolver — adapter contract)
#   - scripts/lib-paths.sh            (defines studio_home_is_synthetic)
#   - scripts/lint-synthetic-home.sh  (this lint)
#   - scripts/test-fixtures/**        (synthetic data, polluted samples)
#
# Allowlist (baseline of pre-existing files):
#   scripts/lint-synthetic-home-allowlist.txt
#   - --strict mode skips listed files entirely (don't break the world).
#   - --staged mode still flags newly-added lines in those files; existing
#     content is invisible to a staged-diff scan, so the baseline is
#     irrelevant there.
#
# Allow annotation (per-line carve-out for documentation/tests):
#   # lint-synthetic-home:allow next-line — <reason>
#
# Approved-context substrings (single-line carve-outs — recognized as
# canonical resolver use rather than ad-hoc special casing):
#   - studio_home_is_synthetic        (the resolver helper)
#   - _studio_context_login_home      (the resolver helper)
#   - lint-synthetic-home:allow       (per-line annotation)
#
# Detected patterns (E_SYNTHETIC_HOME_SPECIAL_CASE):
#   1. `case "$HOME" in ...` / `case $HOME in ...` / `case "${HOME...}" in`
#      — case statements pivoting on $HOME
#   2. `[ "$HOME" = ... ]` / `[[ "$HOME" = ... ]]` / `[[ "$HOME" =~ ... ]]`
#      / `!=` variants / `${HOME...}` brace forms — direct conditional
#      comparisons on $HOME
#   3. Any line referencing the literal `.codex-homes` substring — the
#      resolver's synthetic-home marker. Reimplementing this match outside
#      the resolver layer is the canonical drift bug.
#
# Bypass (user-controlled, emergency/debug-only):
#   STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1 git commit ...
#   The lint emits a stderr audit line when the bypass fires; assistants
#   must not set the bypass silently.
#
# Error format: <CODE>:<file>:<line>:<detail>
# Exit 0: clean. Exit 1: at least one BLOCK violation.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# Repo root: env override (used by the test fixture against synthetic
# throwaway repos), else the script's own repo. Mirrors the C1/C2 siblings.
if [ -n "${LINT_SYNTHETIC_HOME_REPO_ROOT:-}" ]; then
  REPO_ROOT=$(cd "$LINT_SYNTHETIC_HOME_REPO_ROOT" && pwd)
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
ALLOWLIST_FILE="$SCRIPT_DIR/lint-synthetic-home-allowlist.txt"

if [ "${STUDIO_BYPASS_SYNTHETIC_HOME_LINT:-0}" = "1" ]; then
  printf 'lint-synthetic-home: STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1 — skipping (audit)\n' >&2
  exit 0
fi

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

in_scope() {
  local p="$1"
  case "$p" in
    scripts/*.sh) return 0 ;;
    hooks/*)
      case "$p" in
        */*.json) return 1 ;;
      esac
      return 0
      ;;
    core/*)
      case "$p" in
        *.sh) return 0 ;;
      esac
      ;;
  esac
  return 1
}

exempt_by_rule() {
  case "$1" in
    scripts/lib-studio-context.sh|scripts/lib-paths.sh) return 0 ;;
    scripts/lint-synthetic-home.sh)                     return 0 ;;
    scripts/test-fixtures/*)                            return 0 ;;
  esac
  return 1
}

ALLOWLIST=""
if [ -f "$ALLOWLIST_FILE" ]; then
  ALLOWLIST=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }
  ' "$ALLOWLIST_FILE")
fi

allowlisted() {
  [ -z "$ALLOWLIST" ] && return 1
  printf '%s\n' "$ALLOWLIST" | grep -Fxq -- "$1"
}

has_approved_context() {
  case "$1" in
    *studio_home_is_synthetic*)   return 0 ;;
    *_studio_context_login_home*) return 0 ;;
    *'lint-synthetic-home:allow'*) return 0 ;;
  esac
  return 1
}

is_comment_line() {
  local stripped="${1#"${1%%[![:space:]]*}"}"
  case "$stripped" in
    \#*) return 0 ;;
  esac
  return 1
}

# Detect the three pattern classes on a single line. Returns 0 + sets
# MATCH_DETAIL when the line contains a synthetic-home special-casing
# pattern outside the resolver layer.
MATCH_DETAIL=""
match_special_case() {
  local line="$1"
  MATCH_DETAIL=""

  # Class 1: `case "$HOME" in` / `case $HOME in` / `case "${HOME...}" in`
  if [[ "$line" =~ (^|[[:space:]\;\&\|\(])case[[:space:]]+\"?\$\{?HOME(\}|\")?[[:space:]]+in([[:space:]]|$) ]]; then
    MATCH_DETAIL='case statement pivoting on $HOME'
    return 0
  fi

  # Class 2: `[ "$HOME" = ... ]` / `[[ "$HOME" = ... ]]` / `=~` / `!=`,
  # plus `${HOME...}` brace-expansion forms used as the test subject.
  if [[ "$line" =~ \[\[?[[:space:]]+\"?\$\{?HOME[^\"]*\}?\"?[[:space:]]*(=~|==|!=|=)[[:space:]] ]]; then
    MATCH_DETAIL='conditional comparison on $HOME'
    return 0
  fi

  # Class 3: literal `.codex-homes` substring — the resolver's marker.
  case "$line" in
    *.codex-homes*) MATCH_DETAIL='inline reference to `.codex-homes` marker'; return 0 ;;
  esac

  return 1
}

scan_whole_file() {
  local rel="$1"
  local abs
  case "$rel" in
    /*) abs="$rel" ;;
    *)  abs="$REPO_ROOT/$rel" ;;
  esac
  [ -f "$abs" ] || return 0

  local lineno=0 prev=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if is_comment_line "$line"; then
      prev="$line"
      continue
    fi
    if match_special_case "$line"; then
      if has_approved_context "$line" || has_approved_context "$prev"; then
        prev="$line"
        continue
      fi
      emit_error "E_SYNTHETIC_HOME_SPECIAL_CASE:$rel:$lineno:$MATCH_DETAIL | route synthetic-home detection through scripts/lib-paths.sh \`studio_home_is_synthetic\` or scripts/lib-studio-context.sh \`_studio_context_login_home\` per CLAUDE.md §Where workflow rules live"
    fi
    prev="$line"
  done < "$abs"
}

scan_staged_diff() {
  local files
  files=$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
    | while IFS= read -r f; do
        [ -z "$f" ] && continue
        if in_scope "$f" && ! exempt_by_rule "$f"; then
          printf '%s\n' "$f"
        fi
      done)
  [ -z "$files" ] && return 0

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local diff
    diff=$(git -C "$REPO_ROOT" diff --cached --unified=0 -- "$f" 2>/dev/null) || continue
    [ -z "$diff" ] && continue

    local new_line=0 prev_added="" in_hunk=0
    while IFS= read -r dline || [ -n "$dline" ]; do
      case "$dline" in
        '+++ '*|'--- '*) continue ;;
        '@@'*)
          local hunk="$dline"
          local plus="${hunk#*+}"
          plus="${plus%%,*}"
          plus="${plus%% *}"
          new_line="$plus"
          prev_added=""
          in_hunk=1
          continue
          ;;
        '-'*) continue ;;
        '+'*)
          [ "$in_hunk" -eq 1 ] || continue
          local content="${dline#+}"
          if ! is_comment_line "$content" && match_special_case "$content"; then
            if ! has_approved_context "$content" && ! has_approved_context "$prev_added"; then
              emit_error "E_SYNTHETIC_HOME_SPECIAL_CASE:$f:$new_line:$MATCH_DETAIL | route synthetic-home detection through scripts/lib-paths.sh \`studio_home_is_synthetic\` or scripts/lib-studio-context.sh \`_studio_context_login_home\` per CLAUDE.md §Where workflow rules live"
            fi
          fi
          prev_added="$content"
          new_line=$((new_line + 1))
          ;;
        *)
          [ "$in_hunk" -eq 1 ] && new_line=$((new_line + 1))
          ;;
      esac
    done <<<"$diff"
  done <<<"$files"
}

run_strict() {
  local files
  files=$(git -C "$REPO_ROOT" ls-files 2>/dev/null \
    | while IFS= read -r f; do
        [ -z "$f" ] && continue
        if in_scope "$f" && ! exempt_by_rule "$f" && ! allowlisted "$f"; then
          printf '%s\n' "$f"
        fi
      done)
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    scan_whole_file "$f"
  done <<<"$files"
}

run_files() {
  local target
  for target in "$@"; do
    [ -z "$target" ] && continue
    local rel="$target"
    case "$target" in
      "$REPO_ROOT"/*) rel="${target#"$REPO_ROOT/"}" ;;
      /*) rel="$target" ;;
    esac
    if [ -f "$rel" ]; then
      if exempt_by_rule "$rel"; then
        continue
      fi
      scan_whole_file "$rel"
    elif [ -f "$REPO_ROOT/$rel" ]; then
      scan_whole_file "$rel"
    fi
  done
}

mode="${1:-}"
case "$mode" in
  --staged)   scan_staged_diff ;;
  --strict)   run_strict ;;
  "" )        run_strict ;;
  --help|-h)
    sed -n '2,70p' "$0" >&2
    exit 0
    ;;
  *)          run_files "$@" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-synthetic-home: %s error(s) — call scripts/lib-paths.sh `studio_home_is_synthetic` or scripts/lib-studio-context.sh `_studio_context_login_home` instead of inline `case "$HOME"` / `[ "$HOME" = ... ]` / `.codex-homes` checks; per-line carve-out: `# lint-synthetic-home:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
exit 0
