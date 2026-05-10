#!/usr/bin/env bash
# lint-artifact-cleanup.sh — block new artifact-producing call sites that
# don't route through the shared cleanup primitive (#710 / T-R004, #849).
#
# scripts/lib-artifact-cleanup.sh centralizes deterministic cleanup of
# disposable runtime artifacts (tmp dirs, xcresult bundles, xcarchives,
# derived-data trees, ephemeral git worktrees). Hand-rolled mktemp/xcodebuild/
# worktree-add call sites without an EXIT trap drift in subtle ways across
# callers and silently leak filesystem state — `studio-tf-push.sh` leaking
# multi-GB xcarchives per push, simulator-booted DerivedData accumulating
# under long-lived workers, untrapped tmpdirs in slack-list / chain-runner
# loops. The T-R001 audit (`_shared/audits/2026-05-10-artifact-cleanup-audit.md`)
# inventoried the corpus; this lint blocks new offenders from accreting on
# top of the baseline.
#
# Modes:
#   scripts/lint-artifact-cleanup.sh --staged    # pre-commit: scan added
#                                                # lines in the staged diff
#   scripts/lint-artifact-cleanup.sh --strict    # CI: scan whole tree, but
#                                                # honor the baseline
#                                                # allowlist for files that
#                                                # pre-date the lint
#   scripts/lint-artifact-cleanup.sh <file> ...  # ad-hoc whole-file scan
#
# Scope (per #849 acceptance):
#   scripts/*.sh, core/**/*.sh, hooks/* (text shell scripts)
#
# Always-exempt (approved wrappers / resolver layer / this lint):
#   - scripts/lib-artifact-cleanup.sh         (the cleanup primitive itself;
#                                              owns its registry scratch
#                                              under mktemp -d)
#   - scripts/studio-ios-artifact-janitor.sh  (approved janitor)
#   - scripts/node-janitor.sh                 (approved janitor)
#   - scripts/fleet-cleanup.sh                (approved janitor)
#   - scripts/sweep-janitor.sh                (approved janitor)
#   - scripts/lint-artifact-cleanup.sh        (this lint)
#   - scripts/test-fixtures/**                (synthetic data, polluted
#                                              samples; behavioral fixtures
#                                              clean up their own sandbox)
#
# Allowlist (baseline of pre-existing files):
#   scripts/lint-artifact-cleanup-allowlist.txt
#   - --strict mode skips listed files entirely (don't break the world).
#   - --staged mode still flags newly-added lines in those files; existing
#     content is invisible to a staged-diff scan, so the baseline is
#     irrelevant there.
#
# Allow annotation (per-line carve-out for documentation/tests):
#   # lint-artifact-cleanup:allow next-line — <reason>
#
# Approved-context substrings (single-line carve-outs — recognized as
# canonical cleanup-primitive use rather than ad-hoc artifact creation):
#   - register_artifact                  (the cleanup primitive helper)
#   - lint-artifact-cleanup:allow        (per-line annotation)
#
# Detected patterns (E_ARTIFACT_CLEANUP_UNREGISTERED):
#   1. `xcodebuild` invocation (as a command word, not a string literal in
#      a comment or echo) — produces DerivedData / archives / result bundles
#   2. Literal `-derivedDataPath` flag — explicitly relocates DerivedData
#      to a path that must be cleaned
#   3. Literal `git worktree add` — produces a worktree the caller owns
#   4. Literal `mktemp -d` — produces a disposable tmp dir
#
# Bypass (user-controlled, emergency/debug-only):
#   STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1 git commit ...
#   The lint emits a stderr audit line when the bypass fires; assistants
#   must not set the bypass silently.
#
# Error format: <CODE>:<file>:<line>:<detail>
# Exit 0: clean. Exit 1: at least one BLOCK violation.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# Repo root: env override (used by the test fixture against synthetic
# throwaway repos), else the script's own repo. Mirrors the C1/C2/C3 siblings.
if [ -n "${LINT_ARTIFACT_CLEANUP_REPO_ROOT:-}" ]; then
  REPO_ROOT=$(cd "$LINT_ARTIFACT_CLEANUP_REPO_ROOT" && pwd)
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
ALLOWLIST_FILE="$SCRIPT_DIR/lint-artifact-cleanup-allowlist.txt"

if [ "${STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT:-0}" = "1" ]; then
  printf 'lint-artifact-cleanup: STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1 — skipping (audit)\n' >&2
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
    scripts/lib-artifact-cleanup.sh)         return 0 ;;
    scripts/studio-ios-artifact-janitor.sh)  return 0 ;;
    scripts/node-janitor.sh)                 return 0 ;;
    scripts/fleet-cleanup.sh)                return 0 ;;
    scripts/sweep-janitor.sh)                return 0 ;;
    scripts/lint-artifact-cleanup.sh)        return 0 ;;
    scripts/test-fixtures/*)                 return 0 ;;
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
  # Only same-line context counts. The previous-line allowance the lint
  # used to accept (`register_artifact` on the line above) was a false
  # negative — it accepted any earlier register call regardless of which
  # artifact it referenced, which let unrelated `mktemp -d` / `xcodebuild`
  # / etc. slip through. If a register_artifact appears on a different
  # line than the offender, the author should either combine onto one
  # line with `;` or use the explicit per-line annotation
  # `# lint-artifact-cleanup:allow next-line — <reason>` placed on the
  # line immediately above.
  case "$1" in
    *register_artifact*)              return 0 ;;
    *'lint-artifact-cleanup:allow'*)  return 0 ;;
  esac
  return 1
}

# Recognize the explicit per-line annotation only when it is on the
# physically-previous line. This is intentionally narrower than
# has_approved_context: an arbitrary register_artifact above an offender
# is NOT a carve-out, but `# lint-artifact-cleanup:allow next-line` IS.
has_prev_line_annotation() {
  case "$1" in
    *'lint-artifact-cleanup:allow'*) return 0 ;;
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

# Detect the four pattern classes on a single line. Returns 0 + sets
# MATCH_DETAIL when the line contains a banned pattern outside an approved
# wrapper / annotation context.
MATCH_DETAIL=""
match_offender() {
  local line="$1"
  MATCH_DETAIL=""

  # Class 3: `git worktree add` (check before plain xcodebuild to keep
  # detail accurate when a single line contains multiple tokens).
  case "$line" in
    *'git worktree add'*)
      MATCH_DETAIL='`git worktree add` without register_artifact / approved wrapper'
      return 0
      ;;
  esac

  # Class 2: `-derivedDataPath` literal flag.
  case "$line" in
    *-derivedDataPath*)
      MATCH_DETAIL='`-derivedDataPath` without register_artifact / approved wrapper'
      return 0
      ;;
  esac

  # Class 4: `mktemp -d` literal.
  case "$line" in
    *'mktemp -d'*)
      MATCH_DETAIL='`mktemp -d` without register_artifact / approved wrapper'
      return 0
      ;;
  esac

  # Class 1: `xcodebuild` as a command word. Match when preceded by start
  # of line, whitespace, `;`, `&`, `|`, `(`, or backtick — i.e. the token
  # is being executed rather than appearing inside a longer identifier or
  # string literal containing the word.
  if [[ "$line" =~ (^|[[:space:]\;\&\|\(\`\$])xcodebuild([[:space:]]|\"|$) ]]; then
    MATCH_DETAIL='`xcodebuild` invocation without register_artifact / approved wrapper'
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
    if match_offender "$line"; then
      # Same-line register_artifact / annotation always allowed.
      # Previous-line annotation (the explicit `# lint-artifact-cleanup:allow`
      # form) is also allowed — but a bare register_artifact on the previous
      # line is NOT, since it may register a different artifact.
      if has_approved_context "$line" || has_prev_line_annotation "$prev"; then
        prev="$line"
        continue
      fi
      emit_error "E_ARTIFACT_CLEANUP_UNREGISTERED:$rel:$lineno:$MATCH_DETAIL | route through scripts/lib-artifact-cleanup.sh \`register_artifact\` or an approved janitor (studio-ios-artifact-janitor / node-janitor / fleet-cleanup / sweep-janitor); per CLAUDE.md §Where workflow rules live"
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
          if ! is_comment_line "$content" && match_offender "$content"; then
            # Same as scan_whole_file: same-line register_artifact OR
            # previous-line `# lint-artifact-cleanup:allow next-line`
            # annotation are the only carve-outs. A bare register_artifact
            # on the previous added line is no longer a carve-out (false
            # negative for unrelated artifacts).
            if ! has_approved_context "$content" && ! has_prev_line_annotation "$prev_added"; then
              emit_error "E_ARTIFACT_CLEANUP_UNREGISTERED:$f:$new_line:$MATCH_DETAIL | route through scripts/lib-artifact-cleanup.sh \`register_artifact\` or an approved janitor (studio-ios-artifact-janitor / node-janitor / fleet-cleanup / sweep-janitor); per CLAUDE.md §Where workflow rules live"
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
      if exempt_by_rule "$rel"; then
        continue
      fi
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
    sed -n '2,80p' "$0" >&2
    exit 0
    ;;
  *)          run_files "$@" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-artifact-cleanup: %s error(s) — route disposable artifacts through scripts/lib-artifact-cleanup.sh `register_artifact` (or an approved janitor); per-line carve-out: `# lint-artifact-cleanup:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
exit 0
