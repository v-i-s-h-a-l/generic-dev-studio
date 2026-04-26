#!/usr/bin/env bash
# lint-brief.sh — validate per-brief YAML against the brief schema (#256).
#
# Currently enforces the `summary` field budget introduced in brief@3.2.0:
# token estimate (word_count × 1.3) MUST be ≤ 500 tokens. A missing or
# null `summary` warns (pre-backfill carve-out) unless --strict is set,
# in which case it errors. Other schema fields are validated upstream by
# the writer / plans-index validator; this lint focuses on the slice that
# downstream consumers (status, dispatch-ready, digest, agent-boot under
# BRIEF_SLICE=summary) render directly.
#
# Usage:
#   scripts/lint-brief.sh <brief.yaml> [<brief.yaml> ...]
#       Lint the named brief files.
#
#   scripts/lint-brief.sh --strict <brief.yaml> ...
#       Treat missing/null summary as an error rather than a warning.
#
# Exit 0: pass (warnings allowed). Exit 1: any block-level violation.
# Error format: <CODE>:<file>:<detail>
#
# Dependencies: yq (mikefarah). Falls back to awk extraction when yq is
# unavailable, with a warning.

set -u
umask 022

SUMMARY_TOKEN_BUDGET=500
WORDS_PER_TOKEN_INVERSE="1.3"   # token_estimate = word_count * 1.3

ERRORS=0
WARNINGS=0
STRICT=0

emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# Parse args.
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) emit_error "E_BAD_FLAG::unknown flag: $1"; exit 1 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

[ ${#FILES[@]} -eq 0 ] && usage

# Extract the `summary` field. yq if available; awk block-scalar fallback.
extract_summary() {
  local file="$1" out
  if command -v yq >/dev/null 2>&1; then
    out=$(yq -r '.summary // ""' "$file" 2>/dev/null) || out=""
    printf '%s' "$out"
    return 0
  fi
  awk '
    BEGIN { in_block=0; indent="" }
    /^summary:[[:space:]]*\|/ { in_block=1; next }
    /^summary:[[:space:]]*null[[:space:]]*$/ { exit }
    /^summary:[[:space:]]*"?'"'"'?/ {
      sub(/^summary:[[:space:]]*/, "", $0)
      gsub(/^["'"'"']|["'"'"']$/, "", $0)
      print; exit
    }
    in_block==1 {
      if ($0 ~ /^[^[:space:]]/) { exit }       # next top-level key ends block
      sub(/^[[:space:]]{2}/, "", $0)
      print
    }
  ' "$file"
}

# Token estimate: floor(word_count * 1.3). Pure shell arithmetic — multiply
# by 13, integer-divide by 10, to avoid awk dependency for the estimate.
estimate_tokens() {
  local words="$1"
  printf '%d' "$(( (words * 13) / 10 ))"
}

if ! command -v yq >/dev/null 2>&1; then
  emit_warn "W_NO_YQ::yq not on PATH; using awk fallback for summary extraction (less reliable)"
fi

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    emit_error "E_NO_FILE:$file:not a file"
    continue
  fi

  summary=$(extract_summary "$file")

  if [ -z "$summary" ]; then
    if [ "$STRICT" -eq 1 ]; then
      emit_error "E_MISSING_SUMMARY:$file:summary is empty or null (3.2.0 requires summary on new briefs)"
    else
      emit_warn  "W_MISSING_SUMMARY:$file:summary is empty or null — populate before dispatch (3.2.0)"
    fi
    continue
  fi

  words=$(printf '%s' "$summary" | wc -w | tr -d ' ')
  tokens=$(estimate_tokens "$words")

  if [ "$tokens" -gt "$SUMMARY_TOKEN_BUDGET" ]; then
    emit_error "E_SUMMARY_TOO_LONG:$file:summary ~${tokens} tokens (${words} words × 1.3) exceeds budget of ${SUMMARY_TOKEN_BUDGET}; condense to the three-line discipline (what / why / key constraint)"
  fi
done

if [ "$ERRORS" -gt 0 ]; then
  printf '\n%d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS" >&2
  exit 1
fi
exit 0
