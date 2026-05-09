#!/usr/bin/env bash
# Fixture for scripts/lint-runtime-paths.sh (#814).
#
# Cases:
#   1. Clean shell script (no banned patterns)        → lint passes
#   2. Polluted script with each of the 3 patterns    → lint blocks each
#   3. Allow-annotated line                           → lint passes
#   4. STUDIO_BYPASS_RUNTIME_PATH_LINT=1              → lint exits 0 + audits
#   5. Staged-diff mode flags only newly-added lines
#      (pre-existing lines on disk are invisible)
#
# Runs in-place (no clones). Synthetic files live in a tmpdir; staged-diff
# tests use a throwaway repo so they cannot affect the real index.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LINT="$ROOT/scripts/lint-runtime-paths.sh"

[ -x "$LINT" ] || { printf 'FAIL: %s missing or not executable\n' "$LINT" >&2; exit 1; }

TMP=$(mktemp -d -t runtime-paths-lint.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------
# Case 1 — clean script passes whole-file scan.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case1/scripts"
cat > "$TMP/case1/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib-paths.sh"
runtime=$(project_runtime_dir)
echo "$runtime"
SH

if ! "$LINT" "$TMP/case1/scripts/clean.sh" >"$TMP/case1.out" 2>"$TMP/case1.err"; then
  printf 'FAIL case 1 (clean): lint rejected a clean script\n' >&2
  cat "$TMP/case1.out" "$TMP/case1.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 2 — polluted script: each of the 3 banned formulas is flagged.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case2/scripts"
cat > "$TMP/case2/scripts/polluted.sh" <<'SH'
#!/usr/bin/env bash
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
STATE="${HOME}/.dev-studio/myproj/state"
echo "see also ~/.dev-studio/myproj/snapshots"
SH

if "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case2.out" 2>"$TMP/case2.err"; then
  printf 'FAIL case 2 (polluted): lint accepted banned formulas\n' >&2
  exit 1
fi

grep -q 'E_RAW_RUNTIME_PATH:.*:2:"\$HOME/\.dev-studio"'    "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag $HOME/.dev-studio\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
grep -q 'E_RAW_RUNTIME_PATH:.*:3:"\${HOME}/\.dev-studio"'  "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag ${HOME}/.dev-studio\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }
grep -q 'E_RAW_RUNTIME_PATH:.*:4:"~/\.dev-studio"'          "$TMP/case2.out" \
  || { printf 'FAIL case 2: did not flag ~/.dev-studio\n' >&2; cat "$TMP/case2.out" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 3 — allow-annotated line is permitted.
# -----------------------------------------------------------------------
mkdir -p "$TMP/case3/scripts"
cat > "$TMP/case3/scripts/annotated.sh" <<'SH'
#!/usr/bin/env bash
# lint-runtime-paths:allow next-line — documenting the banned shape in error text
echo "do not write to \$HOME/.dev-studio/<project> by hand"
SH

if ! "$LINT" "$TMP/case3/scripts/annotated.sh" >"$TMP/case3.out" 2>"$TMP/case3.err"; then
  printf 'FAIL case 3 (annotated): lint rejected an annotated line\n' >&2
  cat "$TMP/case3.out" "$TMP/case3.err" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Case 4 — bypass env var honored, audit line on stderr.
# -----------------------------------------------------------------------
if ! STUDIO_BYPASS_RUNTIME_PATH_LINT=1 "$LINT" "$TMP/case2/scripts/polluted.sh" >"$TMP/case4.out" 2>"$TMP/case4.err"; then
  printf 'FAIL case 4 (bypass): lint did not exit 0 with bypass set\n' >&2
  cat "$TMP/case4.out" "$TMP/case4.err" >&2
  exit 1
fi
grep -q 'STUDIO_BYPASS_RUNTIME_PATH_LINT=1' "$TMP/case4.err" \
  || { printf 'FAIL case 4: bypass did not emit audit line on stderr\n' >&2; cat "$TMP/case4.err" >&2; exit 1; }

# -----------------------------------------------------------------------
# Case 5 — staged-diff mode flags only newly-added lines, not pre-existing.
# -----------------------------------------------------------------------
REPO="$TMP/case5"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email "fixture@local"
  git config user.name  "fixture"
  mkdir -p scripts
  # Pre-existing pollution — must NOT be flagged once committed.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
SH
  git add scripts/preexisting.sh
  git commit -q -m "seed"

  # Stage 1: edit unrelated line — staged diff should be clean.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
echo "unrelated edit"
SH
  git add scripts/preexisting.sh
  export LINT_RUNTIME_PATHS_REPO_ROOT="$REPO"
  if ! "$LINT" --staged >"$TMP/case5a.out" 2>"$TMP/case5a.err"; then
    printf 'FAIL case 5a: staged-diff flagged a pre-existing line on an unrelated edit\n' >&2
    cat "$TMP/case5a.out" "$TMP/case5a.err" >&2
    exit 1
  fi

  # Stage 2: add a new banned line — staged diff must flag exactly that line.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
echo "unrelated edit"
NEW_DIR="$HOME/.dev-studio/added/state"
SH
  git add scripts/preexisting.sh
  if "$LINT" --staged >"$TMP/case5b.out" 2>"$TMP/case5b.err"; then
    printf 'FAIL case 5b: staged-diff did not flag a newly-added banned line\n' >&2
    cat "$TMP/case5b.out" "$TMP/case5b.err" >&2
    exit 1
  fi
  grep -q 'E_RAW_RUNTIME_PATH:scripts/preexisting.sh:.*"\$HOME/\.dev-studio"' "$TMP/case5b.out" \
    || { printf 'FAIL case 5b: did not surface the added line\n' >&2; cat "$TMP/case5b.out" >&2; exit 1; }
  # The pre-existing line (line 2) must NOT appear in the output.
  if grep -q 'preexisting.sh:2:' "$TMP/case5b.out"; then
    printf 'FAIL case 5b: pre-existing line 2 was flagged retroactively\n' >&2
    cat "$TMP/case5b.out" >&2
    exit 1
  fi
)

# -----------------------------------------------------------------------
# Case 6 — resolver-layer paths exempt by name, even when polluted.
# -----------------------------------------------------------------------
# Synthesize a fake repo root with a stand-in lib-paths.sh and verify the
# explicit-file path skips it.
mkdir -p "$TMP/case6/scripts"
cat > "$TMP/case6/scripts/lib-paths.sh" <<'SH'
#!/usr/bin/env bash
# Resolver source-of-truth — exempt by name.
runtime() { printf '%s\n' "$HOME/.dev-studio/.runtime"; }
SH
# When called via repo-relative path, the rule exempts scripts/lib-paths.sh.
if ! ( cd "$TMP/case6" && "$LINT" scripts/lib-paths.sh ) >"$TMP/case6.out" 2>"$TMP/case6.err"; then
  printf 'FAIL case 6: resolver-layer file was flagged\n' >&2
  cat "$TMP/case6.out" "$TMP/case6.err" >&2
  exit 1
fi

printf 'PASS: lint-runtime-paths fixture (clean, polluted, annotated, bypass, staged-diff, resolver-exempt)\n'
