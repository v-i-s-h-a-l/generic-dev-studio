#!/usr/bin/env bash
# lint-field-review-surfaces.sh — block raw cross-host review command setup.
#
# Field-agent review setup must go through scripts/phase-review.sh or a
# successor wrapper that preserves reviewer auth roots, env scrubbing, MCP
# isolation, readable payload handoff, and startup-failure diagnostics.
#
# Usage:
#   scripts/lint-field-review-surfaces.sh [<file_or_dir> ...]
#   scripts/lint-field-review-surfaces.sh --staged
#
# Allow annotation:
#   # lint-field-review:allow next-line — documenting/testing the banned pattern
#
# Emergency/debug override documentation is allowed only when it says the
# STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1 bypass is user-controlled and
# emergency/debug-only. Assistants must not use the bypass silently.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

ERRORS=0

collect_targets() {
  case "${1:-}" in
    --staged)
      git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | while IFS= read -r f; do
            case "$f" in
              core/v2/*|chains/*|scripts/*|_shared/*|hosts/*|REVIEW.md|CLAUDE.md|AGENTS.md)
                case "$f" in
                  *.md|*.sh|*.yaml|*.yml|*.json) printf '%s\n' "$f" ;;
                esac
                ;;
            esac
          done
      ;;
    "")
      (
        cd "$REPO_ROOT" || exit 1
        find core/v2 chains scripts _shared hosts \
          -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) 2>/dev/null
        [ -f REVIEW.md ] && printf '%s\n' REVIEW.md
        [ -f CLAUDE.md ] && printf '%s\n' CLAUDE.md
        [ -f AGENTS.md ] && printf '%s\n' AGENTS.md
      )
      ;;
    *)
      local arg f
      for arg in "$@"; do
        if [ -f "$arg" ]; then
          case "$arg" in
            "$REPO_ROOT"/*) printf '%s\n' "${arg#"$REPO_ROOT/"}" ;;
            *) printf '%s\n' "$arg" ;;
          esac
        elif [ -d "$arg" ]; then
          find "$arg" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) 2>/dev/null \
            | while IFS= read -r f; do
                case "$f" in
                  "$REPO_ROOT"/*) printf '%s\n' "${f#"$REPO_ROOT/"}" ;;
                  *) printf '%s\n' "$f" ;;
                esac
              done
        fi
      done
      ;;
  esac
}

abs_for() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
  esac
}

label_for() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

scan_file() {
  local target="$1"
  local abs rel found rc
  abs=$(abs_for "$target")
  [ -f "$abs" ] || return 0
  rel=$(label_for "$abs")

  case "$rel" in
    tests/*|scripts/test-fixtures/*|scripts/lint-field-review-surfaces.sh)
      return 0
      ;;
  esac

  found=$(awk -v file="$rel" '
    function has_raw_command(line) {
      return line ~ /(^|[^[:alnum:]_-])(claude[[:space:]]+-p|codex[[:space:]]+exec)([[:space:]]|["`'\'';|&)]|$)/
    }
    function has_review_context(text) {
      return text ~ /(reviewer|review host|review setup|review this|cross-host|sibling-host|phase[ -]?gate|phase plan|plan[ -]?review|outcome[ -]?review|verdict|qa|flow|release-manager|perf|planner|architect|field-agent)/
    }
    function is_host_eligibility_smoke(line) {
      return line ~ /^[[:space:]]*eligibility_smoke_command:[[:space:]]*["'\''"]?(claude[[:space:]]+-p|codex[[:space:]]+exec)([[:space:]]|["'\''"]|$)/
    }
    function documents_banned_pattern(text) {
      return text ~ /(must not|do not|forbid|forbidden|banned|retired|instead of raw|bypass|wrapper|document|testing|test fixture)/
    }
    function bypass_is_documented(text) {
      return text ~ /STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1/ && text ~ /(emergency|debug|user-controlled|user approved|user-approved|explicit)/
    }
    function allowed_annotation(text) {
      return text ~ /lint-field-review:allow[[:space:]]+(next-line|line)/
    }
    {
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        prev2 = (i > 2 ? lines[i - 2] : "")
        prev1 = (i > 1 ? lines[i - 1] : "")
        next1 = (i < NR ? lines[i + 1] : "")
        next2 = (i + 1 < NR ? lines[i + 2] : "")
        window = prev2 "\n" prev1 "\n" lines[i] "\n" next1 "\n" next2

        if (lines[i] ~ /STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1/) {
          if (!(allowed_annotation(lines[i]) || allowed_annotation(prev1) || bypass_is_documented(window))) {
            printf "E_FIELD_REVIEW_BYPASS:%s:%d:%s | bypass must be documented as user-controlled emergency/debug-only; assistants must not use it silently\n", file, i, lines[i]
            had = 1
          }
        } else if (has_raw_command(lines[i]) &&
            !is_host_eligibility_smoke(lines[i]) &&
            !(allowed_annotation(lines[i]) || allowed_annotation(prev1)) &&
            has_review_context(window) &&
            !documents_banned_pattern(window)) {
          printf "E_FIELD_REVIEW_RAW_HOST:%s:%d:%s | route cross-host review through scripts/phase-review.sh or a wrapper successor; annotate only for tests/docs of the banned pattern\n", file, i, lines[i]
          had = 1
        }
      }
      exit had
    }
  ' "$abs")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$found"
    ERRORS=$((ERRORS + $(printf '%s\n' "$found" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')))
  fi
}

TARGETS=$(collect_targets "$@" 2>/dev/null)
[ -z "$TARGETS" ] && exit 0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  scan_file "$f"
done <<EOF
$TARGETS
EOF

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-field-review-surfaces: %s error(s)\n' "$ERRORS" >&2
  exit 1
fi

exit 0
