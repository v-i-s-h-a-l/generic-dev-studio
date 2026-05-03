#!/usr/bin/env bash
# lint-build-invocations.sh — refuse raw xcodebuild / swift build / swift
# test invocations in agent-controlled paths. Toolchain entry must funnel
# through the gate scripts (see _shared/primitives/build-gate.md). Phase 1
# of the release-substrate arc (#216): prevents future regressions of the
# Phase 0 fix (#215).
#
# Usage:
#   scripts/lint-build-invocations.sh [<file_or_dir> ...]
#       Lint specific paths; if none given, walks core/v2/skills/,
#       _shared/, scripts/, .claude/skills/.
#
#   scripts/lint-build-invocations.sh --staged
#       Lint only files staged for commit. Exits 0 if no relevant files
#       staged.
#
# Exit 0: clean. Exit 1: at least one raw invocation found.
#
# Detection patterns:
#   - `\bxcodebuild\s+(build|test|archive|clean|analyze|install|destroy|...)`
#     — xcodebuild followed by an action verb, which is the raw call shape
#   - `\bswift\s+(build|test)\b` — raw swift toolchain
#
# Excluded by construction:
#   - `xcodebuild-shim.sh`, `xcodebuildmcp`, `xcodebuild.lock`,
#     `xcodebuild-lock` (don't match `xcodebuild` + action verb)
#   - `swift-test-gate.sh`, `swift-lsp` (don't match `swift` + space + verb)
#
# Allow-list (files where the raw call is the sanctioned single source):
#   scripts/task-build-gate.sh
#   scripts/task-test-gate.sh
#   scripts/swift-test-gate.sh
#   scripts/argus-run-tests.sh
#   scripts/xcodebuild-shim.sh
#   scripts/snapshot-sync.sh
#
# Opt-out marker (one-off cases, requires rationale comment):
#   # lint-build:allow next-line — <reason>
#   xcodebuild test ...

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

ERRORS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }

# ---- File discovery ---------------------------------------------------
collect_targets() {
  case "${1:-}" in
    --staged)
      git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | while IFS= read -r f; do
            case "$f" in
              core/v2/skills/*|_shared/*|scripts/*|.claude/skills/*)
                printf '%s\n' "$f"
                ;;
            esac
          done
      ;;
    "")
      # `.yaml` is excluded — yaml is configuration metadata, not executable;
      # the strings "swift test"/"xcodebuild" appearing in description fields
      # are documentation, never the actual call site.
      ( cd "$REPO_ROOT" && find core/v2/skills _shared scripts \
          -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null )
      ;;
    *)
      local arg
      for arg in "$@"; do
        if [ -f "$arg" ]; then
          printf '%s\n' "${arg#"$REPO_ROOT/"}"
        elif [ -d "$arg" ]; then
          find "$arg" -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null \
            | while IFS= read -r f; do printf '%s\n' "${f#"$REPO_ROOT/"}"; done
        fi
      done
      ;;
  esac
}

# ---- Allow-list (sanctioned call sites) -------------------------------
# These files contain the only authorized raw xcodebuild / swift invocations.
# Tests for an exact relative-path match — substring would be brittle.
is_allowlisted() {
  case "$1" in
    scripts/task-build-gate.sh|\
    scripts/task-test-gate.sh|\
    scripts/swift-test-gate.sh|\
    scripts/argus-run-tests.sh|\
    scripts/xcodebuild-shim.sh|\
    scripts/snapshot-sync.sh|\
    scripts/studio-tf-push.sh|\
    scripts/lint-build-invocations.sh)
      return 0
      ;;
  esac
  return 1
}

# ---- The grep -----------------------------------------------------------
# `xcodebuild` followed by whitespace + an action verb. The verb list is
# xcodebuild's documented action set; new verbs (rare) are caught at lint
# update time, not silently slipped past. Same shape for `swift build|test`.
#
# Word-boundary asserted via "(start-of-line | non-identifier-char)" rather
# than `\b` — POSIX ERE doesn't define `\b` and BSD awk on macOS interprets
# it as a backspace character inside string literals, so the dynamic regex
# would silently never match. Identifier chars: alnum + `_` + `-` so that
# `xcodebuild-shim`, `xcodebuildmcp`, `swift-test-gate` don't false-positive.
XCB_RE='(^|[^[:alnum:]_-])xcodebuild[[:space:]]+(build|test|archive|clean|analyze|install|destroy|installsrc|build-for-testing|test-without-building|docbuild)([[:space:]]|$)'
SWIFT_RE='(^|[^[:alnum:]_-])swift[[:space:]]+(build|test)([[:space:]]|$)'

# Per-file scan. Walks the file once; awk peeks back one line to honour
# the opt-out marker. Each finding becomes one E_RAW_BUILD_INVOCATION line
# on stdout; ERRORS is bumped by the count awk emits via END.
scan_file() {
  local f="$1"
  is_allowlisted "$f" && return 0

  local found
  # Two heuristic exemptions, applied at line scope:
  #   1. Shell comment — line starts with `#` after optional whitespace.
  #      Comments describing the toolchain are not invocations.
  #   2. Inline code in markdown — the matched substring sits inside a
  #      pair of backticks on the same line. Inline `code` is documentation,
  #      not an executable directive.
  # Fenced code blocks (```...```) are NOT exempt — those are agent-readable
  # commands and the lint should catch a bypass placed there. Use the
  # opt-out marker (`# lint-build:allow next-line — <reason>`) for the rare
  # legitimate fenced sample (e.g. the build-gate primitive's own examples).
  found=$(awk -v re_x="$XCB_RE" -v re_s="$SWIFT_RE" -v file="$f" '
    function inside_inline_code(line, hit_pos,    bt_count, i, c) {
      bt_count = 0
      for (i = 1; i < hit_pos; i++) {
        c = substr(line, i, 1)
        if (c == "`") bt_count++
      }
      return (bt_count % 2 == 1)
    }
    function keyword_pos(matched_substr, abs_start,    off) {
      # The broader regex captures one boundary char before the keyword
      # (^ or non-alnum). Locate the keyword `swift` or `xcodebuild` inside
      # the matched substring so the inline-code check counts backticks up
      # to the keyword, not to the boundary char which may itself be a `.
      off = index(matched_substr, "swift")
      if (off == 0) off = index(matched_substr, "xcodebuild")
      return abs_start + off - 1
    }
    {
      ltrim = $0
      sub(/^[[:space:]]+/, "", ltrim)
      is_comment = (substr(ltrim, 1, 1) == "#")

      hit_x = match($0, re_x); xs = RSTART; xl = RLENGTH
      hit_s = match($0, re_s); ss = RSTART; sl = RLENGTH
      if (hit_x > 0) { kw = keyword_pos(substr($0, xs, xl), xs) }
      else if (hit_s > 0) { kw = keyword_pos(substr($0, ss, sl), ss) }
      else { kw = 0 }
      hit = (kw > 0)

      if (hit && is_comment) hit = 0
      if (hit && inside_inline_code($0, kw)) hit = 0

      if (hit && prev !~ /lint-build:allow[[:space:]]+next-line/) {
        printf "E_RAW_BUILD_INVOCATION:%s:%d:%s | route through scripts/task-build-gate.sh (build) or scripts/task-test-gate.sh (test) — see _shared/primitives/build-gate.md\n", file, NR, $0
        had++
      }
      prev = $0
    }
    END { exit (had ? 1 : 0) }
  ' "$REPO_ROOT/$f")
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$found"
    ERRORS=$((ERRORS + $(printf '%s\n' "$found" | wc -l | tr -d ' ')))
  fi
}

# ---- Main -------------------------------------------------------------
TARGETS=$(collect_targets "$@" 2>/dev/null)
if [ -z "$TARGETS" ]; then
  exit 0
fi

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$REPO_ROOT/$f" ] || continue
  scan_file "$f"
done <<EOF
$TARGETS
EOF

if [ "$ERRORS" -gt 0 ]; then
  printf '%s errors\n' "$ERRORS" >&2
  exit 1
fi

exit 0
