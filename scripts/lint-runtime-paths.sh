#!/usr/bin/env bash
# lint-runtime-paths.sh — block raw $HOME/.dev-studio path formulas outside
# the resolver layer (#710 Phase C1, #814).
#
# Production scripts must build durable-state paths via the resolver layer —
# `scripts/lib-paths.sh` (path roots, project slug, runtime dirs) or
# `scripts/lib-studio-context.sh` (STUDIO_CONTEXT_* envelope). Hand-rolled
# `$HOME/.dev-studio/<project>/...`, `~/.dev-studio/...`, or
# `${HOME}/.dev-studio/...` formulas drift from the resolver invariants and
# regress under host-flipping (synthetic HOME, codex sandbox, sibling-host
# review). #791 (`pr-reviewer-eligibility.sh` using `mktemp -d -t ...`
# instead of resolving under `STUDIO_CONTEXT_STUDIO_HOME`) was the most
# recent example.
#
# Modes:
#   scripts/lint-runtime-paths.sh --staged        # pre-commit: scan added
#                                                 # lines in the staged diff
#   scripts/lint-runtime-paths.sh --strict        # CI: scan whole tree, but
#                                                 # honor the baseline
#                                                 # allowlist for files that
#                                                 # pre-date the lint
#   scripts/lint-runtime-paths.sh <file> ...      # ad-hoc whole-file scan
#
# Scope (per #814 acceptance #1):
#   scripts/*.sh, core/**/*.sh, hooks/* (text shell scripts)
#
# Always-exempt:
#   - scripts/lib-paths.sh, scripts/lib-studio-context.sh   (resolver layer)
#   - scripts/test-fixtures/**                              (synthetic data)
#   - scripts/lint-runtime-paths.sh                         (this lint)
#
# Allowlist (baseline of pre-existing files):
#   scripts/lint-runtime-paths-allowlist.txt
#   - --strict mode skips listed files entirely (don't break the world).
#   - --staged mode still flags newly-added lines in those files; existing
#     content is invisible to a staged-diff scan, so the baseline is
#     irrelevant there.
#
# Allow annotation (per-line carve-out for documentation/tests):
#   # lint-runtime-paths:allow next-line — <reason>
#
# Bypass (user-controlled, emergency/debug-only):
#   STUDIO_BYPASS_RUNTIME_PATH_LINT=1 git commit ...
#   The lint emits a stderr audit line when the bypass fires; assistants
#   must not set the bypass silently.
#
# Error format: <CODE>:<file>:<line>:<detail>
# Exit 0: clean. Exit 1: at least one BLOCK violation.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# Repo root: env override (used by the test fixture against synthetic
# throwaway repos), else the script's own repo. This keeps `--staged` and
# `--strict` working from any cwd while letting fixtures pin a synthetic root.
if [ -n "${LINT_RUNTIME_PATHS_REPO_ROOT:-}" ]; then
  REPO_ROOT=$(cd "$LINT_RUNTIME_PATHS_REPO_ROOT" && pwd)
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
ALLOWLIST_FILE="$SCRIPT_DIR/lint-runtime-paths-allowlist.txt"

if [ "${STUDIO_BYPASS_RUNTIME_PATH_LINT:-0}" = "1" ]; then
  printf 'lint-runtime-paths: STUDIO_BYPASS_RUNTIME_PATH_LINT=1 — skipping (audit)\n' >&2
  exit 0
fi

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

# In-scope file? Only shell scripts under scripts/, core/, hooks/.
# bash 3.2 lacks `**` globstar in `case`, so we test in two passes.
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

# Exempt by rule (resolver layer, fixtures, the lint itself).
exempt_by_rule() {
  case "$1" in
    scripts/lib-paths.sh|scripts/lib-studio-context.sh) return 0 ;;
    scripts/lint-runtime-paths.sh)                       return 0 ;;
    scripts/test-fixtures/*)                             return 0 ;;
  esac
  return 1
}

# Loaded once into a newline-delimited string for cheap membership testing.
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

# Pattern detector for a single line of text. Returns the matched pattern
# label on stdout when the line contains a banned formula, otherwise nothing.
match_pattern() {
  local line="$1"
  # shellcheck disable=SC2088 # tildes/expansions are literal match patterns here, not paths
  case "$line" in
    *'$HOME/.dev-studio'*)    printf '$HOME/.dev-studio\n' ;;
    *'${HOME}/.dev-studio'*)  printf '${HOME}/.dev-studio\n' ;;
    *'~/.dev-studio'*)        printf '~/.dev-studio\n' ;;
  esac
}

# Allow annotation on the line itself or the previous source line.
has_allow_annotation_line() {
  case "$1" in
    *'lint-runtime-paths:allow'*) return 0 ;;
  esac
  return 1
}

# Whole-file scan for --strict mode.
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
    local pat
    pat=$(match_pattern "$line")
    if [ -n "$pat" ]; then
      if has_allow_annotation_line "$line" || has_allow_annotation_line "$prev"; then
        prev="$line"
        continue
      fi
      emit_error "E_RAW_RUNTIME_PATH:$rel:$lineno:\"$pat\" | route durable-state paths through scripts/lib-paths.sh (project_runtime_dir / project_state_dir / runtime_global_dir) or scripts/lib-studio-context.sh (STUDIO_CONTEXT_STUDIO_HOME)"
    fi
    prev="$line"
  done < "$abs"
}

# Staged-diff scan: only added (`+`) lines in the unified diff are inspected.
# Pre-existing lines are never flagged, satisfying the "don't break the world"
# acceptance criterion.
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
    # Walk the unified diff for this file. `+++ ` is the file header; lines
    # starting with `+` (single char) are added content. Hunk headers
    # (`@@ -a,b +c,d @@`) carry the new-file starting line.
    local diff
    diff=$(git -C "$REPO_ROOT" diff --cached --unified=0 -- "$f" 2>/dev/null) || continue
    [ -z "$diff" ] && continue

    awk -v file="$f" '
      function match_pattern(s) {
        if (index(s, "$HOME/.dev-studio")   > 0) return "$HOME/.dev-studio"
        if (index(s, "${HOME}/.dev-studio") > 0) return "${HOME}/.dev-studio"
        if (index(s, "~/.dev-studio")       > 0) return "~/.dev-studio"
        return ""
      }
      function has_allow(s) {
        return index(s, "lint-runtime-paths:allow") > 0
      }
      /^@@/ {
        # @@ -a,b +c,d @@  — extract c (new-file starting line).
        if (match($0, /\+[0-9]+/)) {
          new_line = substr($0, RSTART + 1, RLENGTH - 1) + 0
        }
        prev_added = ""
        next
      }
      /^\+\+\+ / { next }
      /^--- /    { next }
      /^-/       { next }   # removed lines do not advance new-file counter
      /^\+/ {
        line = substr($0, 2)
        pat = match_pattern(line)
        if (pat != "" && !has_allow(line) && !has_allow(prev_added)) {
          printf "E_RAW_RUNTIME_PATH:%s:%d:\"%s\" | route durable-state paths through scripts/lib-paths.sh (project_runtime_dir / project_state_dir / runtime_global_dir) or scripts/lib-studio-context.sh (STUDIO_CONTEXT_STUDIO_HOME)\n", file, new_line, pat
          had = 1
        }
        prev_added = line
        new_line++
        next
      }
      { new_line++ }
      END { exit had ? 1 : 0 }
    ' <<<"$diff"
    if [ $? -ne 0 ]; then
      ERRORS=$((ERRORS + 1))
    fi
  done <<<"$files"
}

# --strict: walk every tracked file in scope.
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

# Ad-hoc: scan the explicit list of files (whole-file, no allowlist gating —
# callers explicitly chose these targets, e.g. test fixtures asserting on
# polluted synthetic files).
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
      # Honor exempt-by-rule even when called explicitly so test fixtures
      # documenting the banned pattern stay clean.
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
    sed -n '2,50p' "$0" >&2
    exit 0
    ;;
  *)          run_files "$@" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-runtime-paths: %s error(s) — fix or annotate with `# lint-runtime-paths:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_RUNTIME_PATH_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
exit 0
