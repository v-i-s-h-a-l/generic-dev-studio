#!/usr/bin/env bash
# Fixture for scripts/lint-synthetic-home.sh (#816).
#
# Cases:
#   1. Clean script (resolver helpers only)             → lint passes
#   2. Polluted script with inline synthetic-home
#      special casing                                   → lint blocks each
#   3. Resolver-internal pattern (allowed via approved
#      context: studio_home_is_synthetic call)          → lint passes
#   4. Allow-annotated line                             → lint passes
#   5. STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1              → lint exits 0 + audits
#   6. Staged-diff mode flags only newly-added lines
#      (pre-existing inline checks are invisible)
#   7. Resolver source files (lib-studio-context.sh,
#      lib-paths.sh) exempt by name
#
# Runs in-place (no clones). Synthetic files live in a tmpdir; staged-diff
# tests use a throwaway repo so they cannot affect the real index.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LINT="$ROOT/scripts/lint-synthetic-home.sh"

[ -x "$LINT" ] || { printf 'FAIL: %s missing or not executable\n' "$LINT" >&2; exit 1; }

TMP=$(mktemp -d -t synthetic-home-lint.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------
# Case 1 — clean script (resolver helpers only) passes whole-file scan.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case1/scripts"
cat > "$TMP/case1/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib-paths.sh"
if studio_home_is_synthetic "$HOME"; then
  STUDIO_HOME=$(_studio_context_login_home)
fi
SH

if ! "$LINT" "$TMP/case1/scripts/clean.sh" >"$TMP/case1.out" 2>"$TMP/case1.err"; then
  printf 'FAIL case 1 (clean): lint rejected resolver-helper calls\n' >&2
  cat "$TMP/case1.out" "$TMP/case1.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 2 — polluted script: each inline special-case is flagged.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case2/scripts"
cat > "$TMP/case2/scripts/polluted.sh" <<'SH'
#!/usr/bin/env bash
case "$HOME" in
  */.codex-homes/*) is_synthetic=1 ;;
  *) is_synthetic=0 ;;
esac
if [ "$HOME" = "/Users/login" ]; then echo same; fi
[[ "$HOME" =~ \.claude-turnip ]] && echo turnip
SH

if "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case2.out" 2>"$TMP/case2.err"; then
  printf 'FAIL case 2 (polluted): lint accepted inline synthetic-home special cases\n' >&2
  exit 1
fi

# Line 2: case "$HOME" in
grep -q 'E_SYNTHETIC_HOME_SPECIAL_CASE:.*:2:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `case "$HOME"` (line 2)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
# Line 3: */.codex-homes/* — the marker substring inside a case arm
grep -q 'E_SYNTHETIC_HOME_SPECIAL_CASE:.*:3:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `.codex-homes` reference (line 3)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
# Line 6: [ "$HOME" = ... ]
grep -q 'E_SYNTHETIC_HOME_SPECIAL_CASE:.*:6:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `[ "$HOME" = ... ]` (line 6)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
# Line 7: [[ "$HOME" =~ ... ]]
grep -q 'E_SYNTHETIC_HOME_SPECIAL_CASE:.*:7:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `[[ "$HOME" =~ ... ]]` (line 7)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 3 — approved-context lines (resolver helper calls) pass.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case3/scripts"
cat > "$TMP/case3/scripts/approved.sh" <<'SH'
#!/usr/bin/env bash
# Calling the resolver helper is the canonical, approved usage.
if studio_home_is_synthetic "$HOME"; then
  echo "synthetic via resolver"
fi
LOGIN=$(_studio_context_login_home)
SH

if ! "$LINT" "$TMP/case3/scripts/approved.sh" >"$TMP/case3.out" 2>"$TMP/case3.err"; then
  printf 'FAIL case 3 (approved): lint rejected approved-context lines\n' >&2
  cat "$TMP/case3.out" "$TMP/case3.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 4 — allow-annotated line is permitted.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case4/scripts"
cat > "$TMP/case4/scripts/annotated.sh" <<'SH'
#!/usr/bin/env bash
# lint-synthetic-home:allow next-line — documenting the banned shape in error text
echo "do not match \`*/.codex-homes/*\` directly; call studio_home_is_synthetic"
SH

if ! "$LINT" "$TMP/case4/scripts/annotated.sh" >"$TMP/case4.out" 2>"$TMP/case4.err"; then
  printf 'FAIL case 4 (annotated): lint rejected an annotated line\n' >&2
  cat "$TMP/case4.out" "$TMP/case4.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 5 — bypass env var honored, audit line on stderr.
# -----------------------------------------------------------------------
if ! STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1 "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case5.out" 2>"$TMP/case5.err"; then
  printf 'FAIL case 5 (bypass): lint did not exit 0 with bypass set\n' >&2
  cat "$TMP/case5.out" "$TMP/case5.err" >&2
  exit 1
fi
grep -q 'STUDIO_BYPASS_SYNTHETIC_HOME_LINT=1' "$TMP/case5.err" \
  || { printf 'FAIL case 5: bypass did not emit audit line on stderr\n' >&2; cat "$TMP/case5.err" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 6 — staged-diff mode flags only newly-added lines.
# -----------------------------------------------------------------------
REPO="$TMP/case6"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email "fixture@local"
  git config user.name  "fixture"
  mkdir -p scripts
  # Pre-existing special case — must NOT be flagged once committed.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
case "$HOME" in
  */.codex-homes/*) echo synthetic ;;
esac
SH
  git add scripts/preexisting.sh
  git commit -q -m "seed"

  # Stage 1: edit unrelated line — staged diff should be clean.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
case "$HOME" in
  */.codex-homes/*) echo synthetic ;;
esac
echo "unrelated edit"
SH
  git add scripts/preexisting.sh
  export LINT_SYNTHETIC_HOME_REPO_ROOT="$REPO"
  if ! "$LINT" --staged >"$TMP/case6a.out" 2>"$TMP/case6a.err"; then
    printf 'FAIL case 6a: staged-diff flagged a pre-existing case on an unrelated edit\n' >&2
    cat "$TMP/case6a.out" "$TMP/case6a.err" >&2
    exit 1
  fi

  # Stage 2: add a new inline check — staged diff must flag exactly that line.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
case "$HOME" in
  */.codex-homes/*) echo synthetic ;;
esac
echo "unrelated edit"
if [ "$HOME" = "/Users/login" ]; then echo same; fi
SH
  git add scripts/preexisting.sh
  if "$LINT" --staged >"$TMP/case6b.out" 2>"$TMP/case6b.err"; then
    printf 'FAIL case 6b: staged-diff did not flag a newly-added inline check\n' >&2
    cat "$TMP/case6b.out" "$TMP/case6b.err" >&2
    exit 1
  fi
  grep -q 'E_SYNTHETIC_HOME_SPECIAL_CASE:scripts/preexisting.sh:' "$TMP/case6b.out" \
    || { printf 'FAIL case 6b: did not surface the added line\n' >&2; cat "$TMP/case6b.out" >&2; exit 1; }
  # Pre-existing line 2 (`case "$HOME"`) and line 3 (`.codex-homes`) must NOT
  # appear retroactively.
  if grep -qE 'preexisting.sh:(2|3):' "$TMP/case6b.out"; then
    printf 'FAIL case 6b: pre-existing inline case was flagged retroactively\n' >&2
    cat "$TMP/case6b.out" >&2
    exit 1
  fi

  # Stage 3: add a resolver-helper call — staged diff must NOT flag it.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
case "$HOME" in
  */.codex-homes/*) echo synthetic ;;
esac
echo "unrelated edit"
if studio_home_is_synthetic "$HOME"; then echo same; fi
SH
  git add scripts/preexisting.sh
  if ! "$LINT" --staged >"$TMP/case6c.out" 2>"$TMP/case6c.err"; then
    printf 'FAIL case 6c: staged-diff flagged a newly-added resolver-helper call\n' >&2
    cat "$TMP/case6c.out" "$TMP/case6c.err" >&2
    exit 1
  fi
)

# -----------------------------------------------------------------------
# Case 7 — resolver source files (lib-studio-context.sh, lib-paths.sh)
# exempt by name.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case7/scripts"
cat > "$TMP/case7/scripts/lib-studio-context.sh" <<'SH'
#!/usr/bin/env bash
# Resolver layer — exempt by name. Inline `case "$HOME"` is the canonical
# location for synthetic-home detection.
case "$HOME" in
  */.codex-homes/*) is_synthetic=1 ;;
esac
SH
cat > "$TMP/case7/scripts/lib-paths.sh" <<'SH'
#!/usr/bin/env bash
# Defines studio_home_is_synthetic — exempt by name.
studio_home_is_synthetic() {
  case "${1:-${HOME:-}}" in
    */.codex-homes/*) return 0 ;;
    *) return 1 ;;
  esac
}
SH
if ! ( cd "$TMP/case7" && "$LINT" scripts/lib-studio-context.sh scripts/lib-paths.sh ) >"$TMP/case7.out" 2>"$TMP/case7.err"; then
  printf 'FAIL case 7: resolver source files were flagged\n' >&2
  cat "$TMP/case7.out" "$TMP/case7.err" >&2
  exit 1
fi

printf 'PASS: lint-synthetic-home fixture (clean, polluted, approved-context, annotated, bypass, staged-diff, resolver-exempt)\n'
