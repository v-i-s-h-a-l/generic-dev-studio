#!/usr/bin/env bash
# lint-artifact-cleanup-fixture.sh — behavioral fixture for
# scripts/lint-artifact-cleanup.sh (#849, T-R004).
#
# Sister to tests/lint/lib-artifact-cleanup-fixture.sh (which exercises the
# library primitive itself); this fixture exercises the lint gate that
# blocks new unregistered artifact-producing call sites from accreting on
# top of the T-R001 baseline.
#
# Scenarios:
#   (a) deliberate offender (mktemp -d, xcodebuild, -derivedDataPath,
#       git worktree add) is blocked on a whole-file scan
#   (b) line that registers the artifact via `register_artifact` passes
#   (c) STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1 exits 0 + emits stderr audit
#   (d) per-line annotation `# lint-artifact-cleanup:allow next-line` passes
#   (e) scripts/lib-artifact-cleanup.sh itself passes (resolver/primitive
#       exempt by rule even when it uses mktemp -d for its registry)
#   (f) staged-diff mode flags only newly-added lines (pre-existing
#       offenders in allowlisted files stay invisible)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
LINT="$REPO_ROOT/scripts/lint-artifact-cleanup.sh"

if [ ! -x "$LINT" ]; then
  printf 'fixture: missing or not executable: %s\n' "$LINT" >&2
  exit 2
fi

TMP=$(mktemp -d -t lint-artifact-cleanup-fixture.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

FAIL=0
fail() { printf 'FAIL[%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'pass[%s]: %s\n' "$1" "$2"; }

# -----------------------------------------------------------------------
# Scenario (a) — deliberate offenders flagged
# -----------------------------------------------------------------------
mkdir -p "$TMP/a/scripts"
cat > "$TMP/a/scripts/offender.sh" <<'SH'
#!/usr/bin/env bash
tmp=$(mktemp -d)
xcodebuild build -scheme Foo
xcodebuild test -derivedDataPath /tmp/dd -scheme Foo
git worktree add /tmp/wt origin/main
SH
if "$LINT" "$TMP/a/scripts/offender.sh" >"$TMP/a.out" 2>"$TMP/a.err"; then
  fail a "lint accepted deliberate offender"
else
  # Each banned pattern should produce at least one error line.
  for needle in '`mktemp -d`' '`xcodebuild`' '`-derivedDataPath`' '`git worktree add`'; do
    if ! grep -Fq "$needle" "$TMP/a.out"; then
      fail a "missing detail for $needle in lint output"
    fi
  done
  [ "$FAIL" -eq 0 ] && pass a "deliberate offender flagged for all four patterns"
fi

# -----------------------------------------------------------------------
# Scenario (b) — same-line register_artifact carve-out passes
# -----------------------------------------------------------------------
mkdir -p "$TMP/b/scripts"
cat > "$TMP/b/scripts/registered.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib-artifact-cleanup.sh"
tmp=$(mktemp -d); register_artifact tmpdir "$tmp"
# lint-artifact-cleanup:allow next-line — explicit annotation form
scratch=$(mktemp -d -t scratch.XXXXXX); rm -rf "$scratch"
SH
if ! "$LINT" "$TMP/b/scripts/registered.sh" >"$TMP/b.out" 2>"$TMP/b.err"; then
  fail b "lint rejected same-line register_artifact and explicit annotation carve-outs"
  cat "$TMP/b.out" "$TMP/b.err" >&2
else
  pass b "same-line register_artifact and explicit prev-line annotation accepted"
fi

# -----------------------------------------------------------------------
# Scenario (b2) — bare register_artifact on previous line is NOT a carve-out
# (the false-negative the PR #860 review caught). $scratch is unregistered;
# lint must reject it even though the line above contains register_artifact
# for a different artifact.
# -----------------------------------------------------------------------
mkdir -p "$TMP/b2/scripts"
cat > "$TMP/b2/scripts/false-negative.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib-artifact-cleanup.sh"
tmp=$(mktemp -d); register_artifact tmpdir "$tmp"
scratch=$(mktemp -d -t scratch.XXXXXX)
SH
if "$LINT" "$TMP/b2/scripts/false-negative.sh" >"$TMP/b2.out" 2>"$TMP/b2.err"; then
  fail b2 "lint allowed unregistered \$scratch when previous line had register_artifact for a different artifact"
  cat "$TMP/b2.out" "$TMP/b2.err" >&2
else
  pass b2 "previous-line bare register_artifact is no longer a carve-out (false-negative fixed)"
fi

# -----------------------------------------------------------------------
# Scenario (c) — bypass env var exits 0 + emits stderr audit
# -----------------------------------------------------------------------
if ! STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1 "$LINT" "$TMP/a/scripts/offender.sh" >"$TMP/c.out" 2>"$TMP/c.err"; then
  fail c "bypass did not exit 0"
  cat "$TMP/c.out" "$TMP/c.err" >&2
elif ! grep -q 'STUDIO_BYPASS_ARTIFACT_CLEANUP_LINT=1' "$TMP/c.err"; then
  fail c "bypass did not emit audit line on stderr"
  cat "$TMP/c.err" >&2
else
  pass c "bypass honored with stderr audit line"
fi

# -----------------------------------------------------------------------
# Scenario (d) — per-line allow annotation accepted
# -----------------------------------------------------------------------
mkdir -p "$TMP/d/scripts"
cat > "$TMP/d/scripts/annotated.sh" <<'SH'
#!/usr/bin/env bash
# lint-artifact-cleanup:allow next-line — one-shot bootstrap scratch dir, removed inline below
tmp=$(mktemp -d)
rm -rf "$tmp"
SH
if ! "$LINT" "$TMP/d/scripts/annotated.sh" >"$TMP/d.out" 2>"$TMP/d.err"; then
  fail d "annotated line was flagged"
  cat "$TMP/d.out" "$TMP/d.err" >&2
else
  pass d "per-line annotation accepted"
fi

# -----------------------------------------------------------------------
# Scenario (e) — scripts/lib-artifact-cleanup.sh exempt by rule
# -----------------------------------------------------------------------
# The real primitive lives at scripts/lib-artifact-cleanup.sh inside the
# real repo. Sanity check whole-tree scan: --strict against the real repo
# must not flag the primitive (it may legitimately use mktemp -d for its
# own registry scratch space).
if ! "$LINT" --strict >"$TMP/e.out" 2>"$TMP/e.err"; then
  if grep -q 'scripts/lib-artifact-cleanup\.sh' "$TMP/e.out"; then
    fail e "primitive scripts/lib-artifact-cleanup.sh was flagged by --strict"
    grep 'scripts/lib-artifact-cleanup\.sh' "$TMP/e.out" >&2
  else
    fail e "--strict failed on the seeded tree (unexpected offender)"
    cat "$TMP/e.out" "$TMP/e.err" >&2
  fi
else
  pass e "--strict clean on seeded tree; primitive exempt by rule"
fi

# -----------------------------------------------------------------------
# Scenario (f) — staged-diff mode flags only newly-added lines
# -----------------------------------------------------------------------
REPO="$TMP/f"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email "fixture@local"
  git config user.name  "fixture"
  mkdir -p scripts
  # Pre-existing offender — must NOT be flagged once committed.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
tmp=$(mktemp -d)
SH
  git add scripts/preexisting.sh
  git commit -q -m "seed"

  # Stage 1: edit unrelated line — staged diff should be clean.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
tmp=$(mktemp -d)
echo "unrelated edit"
SH
  git add scripts/preexisting.sh
  export LINT_ARTIFACT_CLEANUP_REPO_ROOT="$REPO"
  if ! "$LINT" --staged >"$TMP/f1.out" 2>"$TMP/f1.err"; then
    printf 'FAIL[f1]: staged-diff flagged pre-existing mktemp on unrelated edit\n' >&2
    cat "$TMP/f1.out" "$TMP/f1.err" >&2
    exit 1
  fi

  # Stage 2: add a new offender line — staged diff must flag exactly it.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
tmp=$(mktemp -d)
echo "unrelated edit"
xcodebuild build -scheme New
SH
  git add scripts/preexisting.sh
  if "$LINT" --staged >"$TMP/f2.out" 2>"$TMP/f2.err"; then
    printf 'FAIL[f2]: staged-diff did not flag newly-added xcodebuild\n' >&2
    cat "$TMP/f2.out" "$TMP/f2.err" >&2
    exit 1
  fi
  grep -q 'E_ARTIFACT_CLEANUP_UNREGISTERED:scripts/preexisting.sh:' "$TMP/f2.out" \
    || { printf 'FAIL[f2]: did not surface the added line\n' >&2; cat "$TMP/f2.out" >&2; exit 1; }
  # Pre-existing mktemp on line 2 must NOT be flagged retroactively.
  if grep -qE 'preexisting.sh:2:' "$TMP/f2.out"; then
    printf 'FAIL[f2]: pre-existing mktemp was flagged retroactively\n' >&2
    cat "$TMP/f2.out" >&2
    exit 1
  fi

  # Stage 3: add a registered call — staged diff must NOT flag it.
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
tmp=$(mktemp -d)
echo "unrelated edit"
scratch=$(mktemp -d); register_artifact tmpdir "$scratch"
SH
  git add scripts/preexisting.sh
  if ! "$LINT" --staged >"$TMP/f3.out" 2>"$TMP/f3.err"; then
    printf 'FAIL[f3]: staged-diff flagged a newly-added register_artifact carve-out\n' >&2
    cat "$TMP/f3.out" "$TMP/f3.err" >&2
    exit 1
  fi
) || FAIL=$((FAIL + 1))
[ "$FAIL" -eq 0 ] && pass f "staged-diff mode honors prior-commit baseline and flags new offenders"

if [ "$FAIL" -gt 0 ]; then
  printf 'lint-artifact-cleanup-fixture: %d failure(s)\n' "$FAIL" >&2
  exit 1
fi
printf 'lint-artifact-cleanup-fixture: all 6 scenarios passed\n'
exit 0
