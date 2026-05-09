#!/usr/bin/env bash
# lint-gh-wrapper.sh — block raw `gh` invocations outside the
# scripts/studio-gh.sh wrapper layer (#710 Phase C2, #815).
#
# Production scripts must invoke GitHub CLI through scripts/studio-gh.sh or
# the `with_login_home_for_github` helper from scripts/lib-studio-context.sh
# so the canonical login HOME is used. Raw `gh ...` calls in synthetic-home
# host sessions (Codex sandbox, Claude variants, sibling-host review) resolve
# auth through the wrong account and re-introduce the exact bug the wrapper
# was built to prevent.
#
# Modes:
#   scripts/lint-gh-wrapper.sh --staged      # pre-commit: scan added lines
#                                            # in the staged diff
#   scripts/lint-gh-wrapper.sh --strict      # CI: scan whole tree, but honor
#                                            # the baseline allowlist for
#                                            # files that pre-date the lint
#   scripts/lint-gh-wrapper.sh <file> ...    # ad-hoc whole-file scan
#
# Scope (per #815 acceptance #1):
#   scripts/*.sh, core/**/*.sh, hooks/* (text shell scripts)
#
# Always-exempt:
#   - scripts/studio-gh.sh         (the wrapper itself)
#   - scripts/lib-studio-context.sh (uses gh inside with_login_home_for_github)
#   - scripts/test-fixtures/**     (synthetic data + mock gh shims)
#   - scripts/lint-gh-wrapper.sh   (this lint)
#
# Allowlist (baseline of pre-existing files):
#   scripts/lint-gh-wrapper-allowlist.txt
#   - --strict mode skips listed files entirely (don't break the world).
#   - --staged mode still flags newly-added lines in those files; existing
#     content is invisible to a staged-diff scan, so the baseline is
#     irrelevant there.
#
# Allow annotation (per-line carve-out for documentation/tests):
#   # lint-gh-wrapper:allow next-line — <reason>
#
# Approved patterns recognized on a single line (not flagged):
#   - with_login_home_for_github gh ...      (canonical helper)
#   - "$SCRIPTS/studio-gh.sh" ...            (wrapper invocation)
#   - gh_api_json ...                         (existing helper that internally
#                                              routes through the wrapper)
#   - command -v gh                           (PATH probe, not invocation)
#
# Bypass (user-controlled, emergency/debug-only):
#   STUDIO_BYPASS_GH_WRAPPER_LINT=1 git commit ...
#   The lint emits a stderr audit line when the bypass fires; assistants
#   must not set the bypass silently.
#
# Error format: <CODE>:<file>:<line>:<detail>
# Exit 0: clean. Exit 1: at least one BLOCK violation.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# Repo root: env override (used by the test fixture against synthetic
# throwaway repos), else the script's own repo. Mirrors lint-runtime-paths.sh.
if [ -n "${LINT_GH_WRAPPER_REPO_ROOT:-}" ]; then
  REPO_ROOT=$(cd "$LINT_GH_WRAPPER_REPO_ROOT" && pwd)
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
ALLOWLIST_FILE="$SCRIPT_DIR/lint-gh-wrapper-allowlist.txt"

if [ "${STUDIO_BYPASS_GH_WRAPPER_LINT:-0}" = "1" ]; then
  printf 'lint-gh-wrapper: STUDIO_BYPASS_GH_WRAPPER_LINT=1 — skipping (audit)\n' >&2
  exit 0
fi

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

# In-scope file? Only shell scripts under scripts/, core/, hooks/.
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

# Exempt by rule (wrapper layer, fixtures, the lint itself).
exempt_by_rule() {
  case "$1" in
    scripts/studio-gh.sh|scripts/lib-studio-context.sh) return 0 ;;
    scripts/lint-gh-wrapper.sh)                          return 0 ;;
    scripts/test-fixtures/*)                             return 0 ;;
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

# Approved-context check: any of these substrings on the same line means the
# `gh` token is a sanctioned call, not a raw bypass.
has_approved_context() {
  case "$1" in
    *with_login_home_for_github*) return 0 ;;
    *studio-gh.sh*)               return 0 ;;
    *gh_api_json*)                return 0 ;;
    *'command -v gh'*)            return 0 ;;
    *'lint-gh-wrapper:allow'*)    return 0 ;;
  esac
  return 1
}

# Comment-only line? Skip — comments and docs may legitimately discuss `gh`.
is_comment_line() {
  case "$1" in
    \#*|' '*\#*|$'\t'*\#*)
      # Reject only if the *first* non-whitespace char is `#`.
      local stripped="${1#"${1%%[![:space:]]*}"}"
      case "$stripped" in
        \#*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Detect `gh <subcommand>` at command position. We require:
#   - `gh` preceded by start-of-line, whitespace, or a shell exec separator
#     (`;`, `&`, `|`, `(`, backtick, `$(`)
#   - followed by a single space then a known subcommand keyword
#
# This deliberately ignores quoted strings (preceded by `"` or `'`) and
# variable references, which are documentation rather than invocation.
GH_SUBCMD_RE='gh (api|alias|attestation|auth|browse|cache|codespace|completion|config|copilot|extension|gist|gpg-key|issue|label|org|pr|preview|project|release|repo|ruleset|run|search|secret|ssh-key|status|variable|workflow)([[:space:]]|$|;|\|)'

match_invocation() {
  # Returns 0 if the line looks like a raw `gh <subcmd>` invocation.
  local line="$1"
  # Fast reject: no `gh ` at all.
  case "$line" in
    *'gh '*) ;;
    *) return 1 ;;
  esac
  # Use bash regex with anchors for command-position prefix.
  if [[ "$line" =~ (^|[[:space:]\;\&\|\(\`])${GH_SUBCMD_RE} ]]; then
    return 0
  fi
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
    if match_invocation "$line"; then
      if has_approved_context "$line" || has_approved_context "$prev"; then
        prev="$line"
        continue
      fi
      emit_error "E_RAW_GH_CALL:$rel:$lineno:raw \`gh\` invocation | route GitHub CLI calls through scripts/studio-gh.sh (assistant-initiated) or with_login_home_for_github (in-script) per CLAUDE.md §GitHub CLI home normalization"
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
          # @@ -a,b +c,d @@  — extract c (new-file starting line).
          local hunk="$dline"
          # POSIX-portable extraction of the +N number.
          local plus="${hunk#*+}"
          plus="${plus%%,*}"
          plus="${plus%% *}"
          new_line="$plus"
          prev_added=""
          in_hunk=1
          continue
          ;;
        '-'*) continue ;;  # removed lines do not advance new-file counter
        '+'*)
          [ "$in_hunk" -eq 1 ] || continue
          local content="${dline#+}"
          if ! is_comment_line "$content" && match_invocation "$content"; then
            if ! has_approved_context "$content" && ! has_approved_context "$prev_added"; then
              emit_error "E_RAW_GH_CALL:$f:$new_line:raw \`gh\` invocation | route GitHub CLI calls through scripts/studio-gh.sh (assistant-initiated) or with_login_home_for_github (in-script) per CLAUDE.md §GitHub CLI home normalization"
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
    sed -n '2,55p' "$0" >&2
    exit 0
    ;;
  *)          run_files "$@" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-gh-wrapper: %s error(s) — call scripts/studio-gh.sh or with_login_home_for_github instead of raw `gh`; per-line carve-out: `# lint-gh-wrapper:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_GH_WRAPPER_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
exit 0
