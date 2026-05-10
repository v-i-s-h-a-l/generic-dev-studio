#!/usr/bin/env bash
# lint-jsonl-merge.sh — flag the dangerous `jq -s 'sort_by(...) | unique'`
# merge pattern in shell scripts (#820 item 7.2).
#
# The pattern looks like
#
#   cat $a $b | jq -c -s 'sort_by(.ts) | unique | .[]' > $out
#
# whose failure mode is silent and catastrophic: control characters in any
# input record break `jq -s`, the merged file is written empty, and the
# typical follow-up `mv merged → canonical; rm bak` overwrites the canonical
# file before anyone checks. This is how T368 cleanup lost a day's events.
#
# Use `scripts/jsonl-merge.sh` instead — it parses with python (control-char
# safe), validates the temp file, refuses to lose records, and refuses to
# write under any project's events/ directory.
#
# Modes:
#   scripts/lint-jsonl-merge.sh --staged
#   scripts/lint-jsonl-merge.sh --strict
#   scripts/lint-jsonl-merge.sh <file> ...
#
# Allow annotation (per-line carve-out):
#   # lint-jsonl-merge:allow next-line — <reason>
#
# Bypass (emergency/debug-only):
#   STUDIO_BYPASS_JSONL_MERGE_LINT=1
#
# Scope: scripts/*.sh, core/**/*.sh, hooks/* (text shell scripts).
# Always-exempt: scripts/jsonl-merge.sh, scripts/lint-jsonl-merge.sh,
# scripts/test-fixtures/**.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT="${LINT_JSONL_MERGE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ "${STUDIO_BYPASS_JSONL_MERGE_LINT:-0}" = "1" ]; then
  printf 'lint-jsonl-merge: STUDIO_BYPASS_JSONL_MERGE_LINT=1 — skipping (audit)\n' >&2
  exit 0
fi

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

in_scope() {
  case "$1" in
    scripts/*.sh) return 0 ;;
    hooks/*)
      case "$1" in
        */*.json) return 1 ;;
      esac
      return 0 ;;
    core/*)
      case "$1" in
        *.sh) return 0 ;;
      esac ;;
  esac
  return 1
}

exempt_by_rule() {
  case "$1" in
    scripts/jsonl-merge.sh) return 0 ;;
    scripts/lint-jsonl-merge.sh) return 0 ;;
    scripts/test-fixtures/*) return 0 ;;
  esac
  return 1
}

# Match `jq` invocations with `-s` (or `-cs`, `-sc`, `-c -s`, etc.) where
# the program string mentions sort_by, unique, group_by, or add — the
# merge-suggesting jq builtins. This catches the dangerous shape without
# flagging benign array constructions like `jq -s '.'` or `jq -s 'length'`.
match_dangerous() {
  local line="$1"
  # Quick reject: require a jq invocation with an -s short-flag DIRECTLY on
  # the jq command (so `paste -sd ... | jq -r ...` doesn't false-positive).
  # Allow these shapes: `jq -s`, `jq -cs`, `jq -sc`, `jq -c -s`, `jq -s -c`.
  case "$line" in
    *'jq -s '*|*'jq -s'$'\t'*|*'jq -s'*"'"*|*'jq -cs '*|*'jq -cs'$'\t'*|*'jq -cs'*"'"*|*'jq -sc '*|*'jq -sc'$'\t'*|*'jq -sc'*"'"*|*'jq -c -s '*|*'jq -s -c '*) ;;
    *) return 1 ;;
  esac
  # Confirm one of the merge-suggesting builtins appears anywhere on the
  # same line (heuristic; multi-line jq programs are rare in our corpus).
  case "$line" in
    *sort_by*|*unique*|*group_by*) return 0 ;;
  esac
  return 1
}

has_allow_annotation() {
  case "$1$2" in
    *'lint-jsonl-merge:allow'*) return 0 ;;
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
    if match_dangerous "$line"; then
      if has_allow_annotation "$line" "$prev"; then
        prev="$line"; continue
      fi
      emit_error "E_JSONL_MERGE_JQ_S:$rel:$lineno:dangerous \`jq -s 'sort_by|unique|group_by|add'\` over ndjson | use scripts/jsonl-merge.sh — \`jq -s\` parse-fails silently on control chars and the typical merge-then-mv shape destroys the canonical file"
    fi
    prev="$line"
  done < "$abs"
}

scan_staged() {
  while IFS= read -r line; do
    case "$line" in
      diff' '--git' '*)
        cur_file="${line##* b/}"
        in_scope_flag=0
        if in_scope "$cur_file" && ! exempt_by_rule "$cur_file"; then
          in_scope_flag=1
        fi
        ;;
      @@*)
        line_num=$(printf '%s\n' "$line" | sed -E 's/^@@.*\+([0-9]+)(,[0-9]+)? @@.*/\1/')
        line_num=$((line_num - 1)) ;;
      \+\+*|---*) ;;
      ' '*) line_num=$((line_num + 1)) ;;
      \-*) ;;
      \+*)
        line_num=$((line_num + 1))
        [ "$in_scope_flag" = "1" ] || continue
        added="${line:1}"
        if match_dangerous "$added"; then
          if has_allow_annotation "$added" ""; then continue; fi
          emit_error "E_JSONL_MERGE_JQ_S:$cur_file:$line_num:dangerous \`jq -s 'sort_by|unique|group_by|add'\` over ndjson | use scripts/jsonl-merge.sh"
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" diff --cached --no-color --unified=0 -- 'scripts/*.sh' 'core/**/*.sh' 'hooks/*' 2>/dev/null)
}

MODE=""
case "${1:-}" in
  --staged) MODE=staged ;;
  --strict) MODE=strict ;;
  "")
    if git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
      MODE=strict
    else
      MODE=staged
    fi
    ;;
  *)
    MODE=adhoc
    ;;
esac

case "$MODE" in
  staged) scan_staged ;;
  strict)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      in_scope "$f" || continue
      exempt_by_rule "$f" && continue
      scan_whole_file "$f"
    done < <(cd "$REPO_ROOT" && find scripts core hooks -type f \( -name '*.sh' -o -path 'hooks/*' \) 2>/dev/null | grep -v '\.json$')
    ;;
  adhoc)
    for f in "$@"; do scan_whole_file "$f"; done
    ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-jsonl-merge: %d error(s) — fix or annotate with `# lint-jsonl-merge:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_JSONL_MERGE_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
