#!/usr/bin/env bash
# Block new unstructured GitHub issue/PR comment posting call sites.
set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
if [ -n "${LINT_STUDIO_COMMENTS_REPO_ROOT:-}" ]; then
  REPO_ROOT=$(cd "$LINT_STUDIO_COMMENTS_REPO_ROOT" && pwd)
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
ALLOWLIST_FILE="$SCRIPT_DIR/lint-studio-comments-allowlist.txt"

if [ "${STUDIO_BYPASS_COMMENT_STRUCTURE_LINT:-0}" = "1" ]; then
  printf 'lint-studio-comments: STUDIO_BYPASS_COMMENT_STRUCTURE_LINT=1 — skipping (audit)\n' >&2
  exit 0
fi

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

in_scope() {
  local p="$1"
  case "$p" in
    scripts/*.sh|.githooks/*|hooks/*) return 0 ;;
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
    scripts/studio-comment.sh)          return 0 ;;
    scripts/lint-studio-comments.sh)    return 0 ;;
    scripts/test-fixtures/*)            return 0 ;;
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

is_comment_line() {
  case "$1" in
    \#*|' '*\#*|$'\t'*\#*)
      local stripped="${1#"${1%%[![:space:]]*}"}"
      case "$stripped" in
        \#*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

has_allow_annotation() {
  case "$1" in
    *'lint-studio-comments:allow'*) return 0 ;;
  esac
  return 1
}

match_unstructured_comment_post() {
  local line="$1"
  case "$line" in
    *'issue comment '*|*'pr comment '*) ;;
    *) return 1 ;;
  esac
  case "$line" in
    *'studio-comment.sh'*) return 1 ;;
  esac
  if [[ "$line" =~ (^|[[:space:]\;\&\|\(\`])((gh|[\"\$A-Za-z0-9_./{}:-]*studio-gh\.sh)[[:space:]]+)?(issue|pr)[[:space:]]+comment([[:space:]]|$|;|\|) ]]; then
    return 0
  fi
  return 1
}

scan_whole_file() {
  local rel="$1" abs lineno line prev
  case "$rel" in
    /*) abs="$rel" ;;
    *) abs="$REPO_ROOT/$rel" ;;
  esac
  [ -f "$abs" ] || return 0

  lineno=0
  prev=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if is_comment_line "$line"; then
      prev="$line"
      continue
    fi
    if match_unstructured_comment_post "$line"; then
      if has_allow_annotation "$line" || has_allow_annotation "$prev"; then
        prev="$line"
        continue
      fi
      emit_error "E_UNSTRUCTURED_STUDIO_COMMENT:$rel:$lineno:unstructured GitHub issue/PR comment writer | route public comments through scripts/studio-comment.sh and the studio-comment:v1 marker contract"
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
    local diff new_line prev_added in_hunk
    diff=$(git -C "$REPO_ROOT" diff --cached --unified=0 -- "$f" 2>/dev/null) || continue
    [ -z "$diff" ] && continue
    new_line=0
    prev_added=""
    in_hunk=0
    while IFS= read -r dline || [ -n "$dline" ]; do
      case "$dline" in
        '+++ '*|'--- '*) continue ;;
        '@@'*)
          local hunk plus
          hunk="$dline"
          plus="${hunk#*+}"
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
          if ! is_comment_line "$content" && match_unstructured_comment_post "$content"; then
            if ! has_allow_annotation "$content" && ! has_allow_annotation "$prev_added"; then
              emit_error "E_UNSTRUCTURED_STUDIO_COMMENT:$f:$new_line:unstructured GitHub issue/PR comment writer | route public comments through scripts/studio-comment.sh and the studio-comment:v1 marker contract"
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
  local target rel
  for target in "$@"; do
    [ -z "$target" ] && continue
    rel="$target"
    case "$target" in
      "$REPO_ROOT"/*) rel="${target#"$REPO_ROOT/"}" ;;
    esac
    if exempt_by_rule "$rel"; then
      continue
    fi
    scan_whole_file "$rel"
  done
}

mode="${1:-}"
case "$mode" in
  --staged) scan_staged_diff ;;
  --strict|"") run_strict ;;
  --help|-h)
    sed -n '2,45p' "$0" >&2
    exit 0
    ;;
  *) run_files "$@" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  # shellcheck disable=SC2016 # The annotation example is intentionally literal.
  printf 'lint-studio-comments: %s error(s) — use scripts/studio-comment.sh for public issue/PR comments; per-line carve-out: `# lint-studio-comments:allow next-line — <reason>`; emergency bypass: STUDIO_BYPASS_COMMENT_STRUCTURE_LINT=1\n' "$ERRORS" >&2
  exit 1
fi
exit 0
