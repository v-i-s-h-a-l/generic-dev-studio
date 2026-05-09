#!/usr/bin/env bash
# Fixture for scripts/lint-gh-wrapper.sh (#815).
#
# Cases:
#   1. Clean script (only wrapped/helper gh calls)        → lint passes
#   2. Polluted script with raw `gh` invocations          → lint blocks each
#   3. Approved-context lines (with_login_home_for_github,
#      studio-gh.sh, gh_api_json, command -v gh)          → lint passes
#   4. Allow-annotated line                               → lint passes
#   5. STUDIO_BYPASS_GH_WRAPPER_LINT=1                    → lint exits 0 + audits
#   6. Staged-diff mode flags only newly-added raw lines
#      (pre-existing raw lines on disk are invisible)
#   7. Wrapper-internal file (scripts/studio-gh.sh) exempt
#
# Runs in-place (no clones). Synthetic files live in a tmpdir; staged-diff
# tests use a throwaway repo so they cannot affect the real index.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LINT="$ROOT/scripts/lint-gh-wrapper.sh"

[ -x "$LINT" ] || { printf 'FAIL: %s missing or not executable\n' "$LINT" >&2; exit 1; }

TMP=$(mktemp -d -t gh-wrapper-lint.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------
# Case 1 — clean script (wrapped calls only) passes whole-file scan.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case1/scripts"
cat > "$TMP/case1/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib-studio-context.sh"
with_login_home_for_github gh issue view "$ISSUE" --json number
"$SCRIPTS/studio-gh.sh" pr list --repo foo/bar
SH

if ! "$LINT" "$TMP/case1/scripts/clean.sh" >"$TMP/case1.out" 2>"$TMP/case1.err"; then
  printf 'FAIL case 1 (clean): lint rejected wrapped calls\n' >&2
  cat "$TMP/case1.out" "$TMP/case1.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 2 — polluted script: each raw gh invocation is flagged.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case2/scripts"
cat > "$TMP/case2/scripts/polluted.sh" <<'SH'
#!/usr/bin/env bash
gh issue list --state open
result=$(gh pr view 42 --json number)
gh api graphql -f query="$Q"
SH

if "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case2.out" 2>"$TMP/case2.err"; then
  printf 'FAIL case 2 (polluted): lint accepted raw gh invocations\n' >&2
  exit 1
fi

grep -q 'E_RAW_GH_CALL:.*:2:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag bare `gh issue list` (line 2)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
grep -q 'E_RAW_GH_CALL:.*:3:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `$(gh pr view ...)` (line 3)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
grep -q 'E_RAW_GH_CALL:.*:4:' "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag `gh api graphql` (line 4)\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 3 — approved-context lines pass (helpers, wrapper path, command -v).
# -----------------------------------------------------------------------
mkdir -p "$TMP/case3/scripts"
cat > "$TMP/case3/scripts/approved.sh" <<'SH'
#!/usr/bin/env bash
command -v gh >/dev/null 2>&1 || exit 2
with_login_home_for_github gh issue list --label bug
"$SCRIPTS/studio-gh.sh" pr view 99
gh_api_json /repos/foo/bar/issues
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
# lint-gh-wrapper:allow next-line — documenting the banned shape in error text
echo "do not call \`gh pr create\` directly; use the wrapper"
SH

if ! "$LINT" "$TMP/case4/scripts/annotated.sh" >"$TMP/case4.out" 2>"$TMP/case4.err"; then
  printf 'FAIL case 4 (annotated): lint rejected an annotated line\n' >&2
  cat "$TMP/case4.out" "$TMP/case4.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 5 — bypass env var honored, audit line on stderr.
# -----------------------------------------------------------------------
if ! STUDIO_BYPASS_GH_WRAPPER_LINT=1 "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case5.out" 2>"$TMP/case5.err"; then
  printf 'FAIL case 5 (bypass): lint did not exit 0 with bypass set\n' >&2
  cat "$TMP/case5.out" "$TMP/case5.err" >&2
  exit 1
fi
grep -q 'STUDIO_BYPASS_GH_WRAPPER_LINT=1' "$TMP/case5.err" \
  || { printf 'FAIL case 5: bypass did not emit audit line on stderr\n' >&2; cat "$TMP/case5.err" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 6 — staged-diff mode flags only newly-added raw lines.
# -----------------------------------------------------------------------
REPO="$TMP/case6"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email "fixture@local"
  git config user.name  "fixture"
  mkdir -p scripts
  # Pre-existing raw call — must NOT be flagged once committed (only added
  # lines in subsequent diffs are scanned).
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
gh issue list --state open
SH
  git add scripts/preexisting.sh
  git commit -q -m "seed"

  # Stage 1: edit unrelated line — staged diff should be clean.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
gh issue list --state open
echo "unrelated edit"
SH
  git add scripts/preexisting.sh
  export LINT_GH_WRAPPER_REPO_ROOT="$REPO"
  if ! "$LINT" --staged >"$TMP/case6a.out" 2>"$TMP/case6a.err"; then
    printf 'FAIL case 6a: staged-diff flagged a pre-existing raw call on an unrelated edit\n' >&2
    cat "$TMP/case6a.out" "$TMP/case6a.err" >&2
    exit 1
  fi

  # Stage 2: add a new raw gh call — staged diff must flag exactly that line.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
gh issue list --state open
echo "unrelated edit"
gh pr create --title "x"
SH
  git add scripts/preexisting.sh
  if "$LINT" --staged >"$TMP/case6b.out" 2>"$TMP/case6b.err"; then
    printf 'FAIL case 6b: staged-diff did not flag a newly-added raw gh call\n' >&2
    cat "$TMP/case6b.out" "$TMP/case6b.err" >&2
    exit 1
  fi
  grep -q 'E_RAW_GH_CALL:scripts/preexisting.sh:' "$TMP/case6b.out" \
    || { printf 'FAIL case 6b: did not surface the added line\n' >&2; cat "$TMP/case6b.out" >&2; exit 1; }
  # The pre-existing line (line 2) must NOT appear in the output.
  if grep -q 'preexisting.sh:2:' "$TMP/case6b.out"; then
    printf 'FAIL case 6b: pre-existing line 2 was flagged retroactively\n' >&2
    cat "$TMP/case6b.out" >&2
    exit 1
  fi

  # Stage 3: add a wrapped gh call — staged diff must NOT flag it.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
gh issue list --state open
echo "unrelated edit"
with_login_home_for_github gh pr create --title "x"
SH
  git add scripts/preexisting.sh
  if ! "$LINT" --staged >"$TMP/case6c.out" 2>"$TMP/case6c.err"; then
    printf 'FAIL case 6c: staged-diff flagged a newly-added wrapped call\n' >&2
    cat "$TMP/case6c.out" "$TMP/case6c.err" >&2
    exit 1
  fi
)

# -----------------------------------------------------------------------
# Case 7 — wrapper-internal file (scripts/studio-gh.sh) exempt by name.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case7/scripts"
cat > "$TMP/case7/scripts/studio-gh.sh" <<'SH'
#!/usr/bin/env bash
# Wrapper source-of-truth — exempt by name.
HOME="$github_home" gh "$@"
SH
if ! ( cd "$TMP/case7" && "$LINT" scripts/studio-gh.sh ) >"$TMP/case7.out" 2>"$TMP/case7.err"; then
  printf 'FAIL case 7: wrapper-internal file was flagged\n' >&2
  cat "$TMP/case7.out" "$TMP/case7.err" >&2
  exit 1
fi

printf 'PASS: lint-gh-wrapper fixture (clean, polluted, approved-context, annotated, bypass, staged-diff, wrapper-exempt)\n'
