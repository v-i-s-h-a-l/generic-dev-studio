#!/usr/bin/env bash
# lint-mode-pack.sh — enforce mode-pack discipline (MP1–MP4).
#
# Walks every `*/modes/*.md` and every `<agent>/SKILL.md` and checks:
#   MP1  budget_tokens declared and not exceeded (estimate: chars / 4)
#   MP2  no 4+ consecutive lines duplicated from _shared/{contracts,rules,
#        primitives,schemas}/*.md (escape hatch: HTML comment sentinel)
#   MP3  router files <= 80 non-blank, non-comment lines
#   MP4  grandfather list at scripts/lint-mode-pack-grandfather.txt
#        downgrades MP1/MP3 to warn until the listed target date passes
#
# Usage:
#   scripts/lint-mode-pack.sh                  # lint everything
#   scripts/lint-mode-pack.sh --staged          # lint only staged files
#   scripts/lint-mode-pack.sh path/to/file.md   # lint specific file(s)
#
# Exit 0 on pass (warnings allowed); exit 1 on any block-level violation.
# Error format: <CODE>:<file>[:<line>]:<detail>
# Authoritative rule: _shared/rules/mode-pack-discipline.md

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
GRANDFATHER_FILE="$SCRIPT_DIR/lint-mode-pack-grandfather.txt"
ROUTER_LINE_CAP=80
DUP_RUN_MIN=4
DUP_LINE_MIN_CHARS=40

ERRORS=0
WARNINGS=0

emit_block() { printf '%s\n' "$1" >&2; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

today_iso() { date -u +%Y-%m-%d; }

# ----------------------------------------------------------------------
# Grandfather lookup
# Reads the grandfather file once into a flat list of "path|target".
# Returns 0 (active) and prints target if path is grandfathered with a
# future-or-today date; returns 1 otherwise.
# ----------------------------------------------------------------------
GRANDFATHER_INDEX=""
load_grandfather() {
  [ -n "$GRANDFATHER_INDEX" ] && return 0
  [ -f "$GRANDFATHER_FILE" ] || { GRANDFATHER_INDEX=" "; return 0; }
  GRANDFATHER_INDEX=$(awk '
    /^#/ || NF == 0 { next }
    NF < 3 { printf "MALFORMED:%s\n", $0; next }
    { printf "%s|%s|%s\n", $1, $2, $3 }
  ' "$GRANDFATHER_FILE")
  # Reject malformed lines fast — the grandfather file itself must be valid.
  if printf '%s\n' "$GRANDFATHER_INDEX" | grep -q '^MALFORMED:'; then
    printf '%s\n' "$GRANDFATHER_INDEX" | grep '^MALFORMED:' | while IFS= read -r line; do
      emit_block "E_GRANDFATHER_MALFORMED:$GRANDFATHER_FILE::${line#MALFORMED:}"
    done
    return 1
  fi
}

# Echoes target date if grandfathered + active; empty otherwise.
grandfather_active_for() {
  local path="$1"
  load_grandfather || return 1
  local row target today
  today=$(today_iso)
  row=$(printf '%s\n' "$GRANDFATHER_INDEX" | awk -F'|' -v p="$path" '$1 == p { print $0; exit }')
  [ -z "$row" ] && return 1
  target=$(printf '%s' "$row" | awk -F'|' '{print $3}')
  # Compare ISO dates lexicographically.
  if [ "$today" \< "$target" ] || [ "$today" = "$target" ]; then
    printf '%s' "$target"
    return 0
  fi
  return 1
}

# ----------------------------------------------------------------------
# Frontmatter helpers
# ----------------------------------------------------------------------
read_frontmatter_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---$/ { c++; next }
    c == 1 && $1 == k":" { sub(/^[^:]+:[ \t]*/, ""); print; exit }
  ' "$file"
}

# ----------------------------------------------------------------------
# MP1 — token budget
# ----------------------------------------------------------------------
check_mp1() {
  local file="$1"
  local rel="${file#"$REPO_ROOT/"}"
  local budget chars est
  budget=$(read_frontmatter_field "$file" budget_tokens)
  if [ -z "$budget" ]; then
    emit_block "E_MP1_BUDGET_MISSING:$rel::frontmatter must declare 'budget_tokens: <int>' (see _shared/rules/mode-pack-discipline.md MP1)"
    return
  fi
  case "$budget" in
    *[!0-9]*|'') emit_block "E_MP1_BUDGET_INVALID:$rel::budget_tokens must be a positive integer (got: $budget)"; return ;;
  esac
  chars=$(wc -c < "$file" | tr -d ' ')
  est=$((chars / 4))
  if [ "$est" -gt "$budget" ]; then
    local pct=$((est * 100 / budget))
    local target
    if target=$(grandfather_active_for "$rel"); then
      emit_warn "W_MP1_BUDGET_OVER:$rel::~${est} tokens > budget ${budget} (${pct}%) — grandfathered until ${target}"
    else
      emit_block "E_MP1_BUDGET_OVER:$rel::~${est} tokens > budget ${budget} (${pct}%) — trim or raise budget_tokens"
    fi
  fi
}

# ----------------------------------------------------------------------
# MP2 — inline duplication detection
# Build a corpus of "significant" lines from _shared/{contracts,rules,
# primitives,schemas}/*.md once, then scan target files for runs.
# ----------------------------------------------------------------------
DUP_CORPUS_FILE=""
build_dup_corpus() {
  [ -n "$DUP_CORPUS_FILE" ] && return 0
  DUP_CORPUS_FILE=$(mktemp -t lint-mode-pack-corpus.XXXXXX) || {
    emit_warn "W_MP2_CORPUS_INIT:_shared::could not allocate corpus tempfile; MP2 skipped"
    DUP_CORPUS_FILE="/dev/null"
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -f \"$DUP_CORPUS_FILE\"" EXIT
  find "$REPO_ROOT/_shared/contracts" "$REPO_ROOT/_shared/rules" \
       "$REPO_ROOT/_shared/primitives" "$REPO_ROOT/_shared/schemas" \
       -type f -name '*.md' 2>/dev/null \
    | while IFS= read -r f; do
        awk -v min="$DUP_LINE_MIN_CHARS" '
          { gsub(/[ \t]+$/, "") }
          length($0) >= min && $0 !~ /^#/ && $0 !~ /^[ \t]*$/ { print }
        ' "$f"
      done | sort -u > "$DUP_CORPUS_FILE"
}

check_mp2() {
  local file="$1"
  local rel="${file#"$REPO_ROOT/"}"
  build_dup_corpus
  [ "$DUP_CORPUS_FILE" = "/dev/null" ] && return 0
  # Walk the file line-by-line; detect runs of significant lines that all
  # exist in the corpus. Skip when preceded by the escape-hatch sentinel
  # within the previous 2 lines.
  awk -v corpus="$DUP_CORPUS_FILE" -v min="$DUP_LINE_MIN_CHARS" \
      -v run_min="$DUP_RUN_MIN" -v rel="$rel" '
    BEGIN {
      while ((getline line < corpus) > 0) { c[line] = 1 }
      close(corpus)
      run = 0; run_start = 0; allow = 0
    }
    {
      if ($0 ~ /<!-- *shared-dup-allowed:/) { allow = 1; next }
      gsub(/[ \t]+$/, "")
      sig = (length($0) >= min && $0 !~ /^#/ && $0 !~ /^[ \t]*$/)
      # `allow` persists across blank/heading lines until the next run is
      # evaluated — the sentinel sits above the block, often separated by a
      # heading or blank line.
      if (!sig) {
        if (run >= run_min && !allow) {
          printf "E_MP2_INLINE_DUP:%s:%d:%d consecutive lines duplicate _shared/* content — reference instead, or annotate with <!-- shared-dup-allowed: <reason> -->\n", rel, run_start, run
          exit 2
        }
        if (run > 0) { run = 0; allow = 0 }
        next
      }
      if (c[$0]) {
        if (run == 0) run_start = NR
        run++
      } else {
        if (run >= run_min && !allow) {
          printf "E_MP2_INLINE_DUP:%s:%d:%d consecutive lines duplicate _shared/* content — reference instead, or annotate with <!-- shared-dup-allowed: <reason> -->\n", rel, run_start, run
          exit 2
        }
        run = 0; allow = 0
      }
    }
    END {
      if (run >= run_min && !allow) {
        printf "E_MP2_INLINE_DUP:%s:%d:%d consecutive lines duplicate _shared/* content — reference instead, or annotate with <!-- shared-dup-allowed: <reason> -->\n", rel, run_start, run
        exit 2
      }
    }
  ' "$file"
  local rc=$?
  if [ "$rc" -eq 2 ]; then
    # awk already printed the finding; record it as a block.
    ERRORS=$((ERRORS + 1))
  fi
}

# ----------------------------------------------------------------------
# MP3 — router cap
# ----------------------------------------------------------------------
check_mp3() {
  local file="$1"
  local rel="${file#"$REPO_ROOT/"}"
  local lines
  lines=$(awk 'NF > 0 && $0 !~ /^[ \t]*<!--/ { c++ } END { print c+0 }' "$file")
  if [ "$lines" -gt "$ROUTER_LINE_CAP" ]; then
    local target
    if target=$(grandfather_active_for "$rel"); then
      emit_warn "W_MP3_ROUTER_OVER:$rel::${lines} non-blank lines > cap ${ROUTER_LINE_CAP} — grandfathered until ${target}"
    else
      emit_block "E_MP3_ROUTER_OVER:$rel::${lines} non-blank lines > cap ${ROUTER_LINE_CAP} — push detail into a mode pack or _shared/"
    fi
  fi
}

# ----------------------------------------------------------------------
# MP5 — retired-pattern gate (cross-agent)
# Reads _shared/rules/retired-patterns.md and blocks on any ERE match
# in the target file. Applies to both SKILL.md routers and mode packs.
# ----------------------------------------------------------------------
RETIRED_PATTERNS_FILE="$REPO_ROOT/_shared/rules/retired-patterns.md"
RETIRED_PATTERNS=""   # lazy-loaded

load_retired_patterns() {
  [ -n "$RETIRED_PATTERNS" ] && return 0
  [ -f "$RETIRED_PATTERNS_FILE" ] || { RETIRED_PATTERNS=" "; return 0; }
  # Extract lines between <!-- lint:patterns:start --> and <!-- lint:patterns:end -->.
  # Strip full-line comments (# ...) and blank lines.
  RETIRED_PATTERNS=$(awk '
    /<!--[[:space:]]*lint:patterns:start[[:space:]]*-->/ { in_block=1; next }
    /<!--[[:space:]]*lint:patterns:end[[:space:]]*-->/   { in_block=0; next }
    !in_block { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }
  ' "$RETIRED_PATTERNS_FILE")
  [ -z "$RETIRED_PATTERNS" ] && RETIRED_PATTERNS=" "
  return 0
}

check_mp5() {
  local file="$1"
  local rel="${file#"$REPO_ROOT/"}"
  load_retired_patterns
  [ "$RETIRED_PATTERNS" = " " ] && return 0

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    local hit lineno
    hit=$(grep -nE "$pattern" "$file" 2>/dev/null | head -1)
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    emit_block "E_MP5_RETIRED_PATTERN:$rel:$lineno:matches retired pattern [$pattern] — see _shared/rules/retired-patterns.md for replacement"
  done <<EOF
$RETIRED_PATTERNS
EOF
}

# ----------------------------------------------------------------------
# Target collection
# ----------------------------------------------------------------------
collect_targets() {
  local mode="${1:-}"; [ $# -gt 0 ] && shift
  case "$mode" in
    --staged)
      git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '(^|/)SKILL\.md$|/modes/[^/]+\.md$' \
        || true
      ;;
    --all|'')
      ( cd "$REPO_ROOT" && find . -path ./.git -prune -o \
          \( -name SKILL.md -o -path '*/modes/*.md' \) -type f -print 2>/dev/null \
          | sed 's|^\./||' )
      ;;
    *)
      local arg
      for arg in "$mode" "$@"; do
        [ -f "$arg" ] || continue
        printf '%s\n' "${arg#"$REPO_ROOT/"}"
      done
      ;;
  esac
}

# ----------------------------------------------------------------------
# Filter: which files are in scope for which checks
# - SKILL.md routers: MP3 only (no budget_tokens contract)
# - modes/*.md: MP1 + MP2
# Vendored skills (under .claude/skills/, skills/vendored/) skipped — their
# discipline is the upstream author's, not ours.
# ----------------------------------------------------------------------
is_vendored() {
  # Only `skills/vendored/` is upstream-owned. `.claude/skills/` holds
  # studio-owned skills (e.g. studio router) and must be linted.
  case "$1" in
    skills/vendored/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_router() {
  case "$1" in
    */SKILL.md) return 0 ;;
    *) return 1 ;;
  esac
}

is_mode_pack() {
  case "$1" in
    */modes/*.md) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------
main() {
  load_grandfather || return 1
  local targets
  targets=$(collect_targets "$@")
  [ -z "$targets" ] && return 0

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    is_vendored "$rel" && continue
    local abs="$REPO_ROOT/$rel"
    [ -f "$abs" ] || continue
    if is_router "$rel"; then
      check_mp3 "$abs"
      check_mp5 "$abs"
    elif is_mode_pack "$rel"; then
      check_mp1 "$abs"
      check_mp2 "$abs"
      check_mp5 "$abs"
    fi
  done <<EOF
$targets
EOF

  if [ "$ERRORS" -gt 0 ]; then
    printf 'lint-mode-pack: %d block-level violation(s), %d warning(s)\n' "$ERRORS" "$WARNINGS" >&2
    return 1
  fi
  if [ "$WARNINGS" -gt 0 ]; then
    printf 'lint-mode-pack: %d warning(s) (grandfathered)\n' "$WARNINGS" >&2
  fi
  return 0
}

main "$@"
