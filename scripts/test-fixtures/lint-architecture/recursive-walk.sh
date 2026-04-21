#!/usr/bin/env bash
# recursive-walk.sh — verifies `collect_candidates` recurses into _shared/
# subdirs. Phase 2.5 Commit A guard: widens -maxdepth 1 to full recursion so
# the Commit C reorg into contracts/ schemas/ primitives/ etc. is lintable.
#
# Builds a throwaway repo skeleton in a temp dir, points the linter at it via
# REPO_ROOT (respected by the script's SCRIPT_DIR detection indirectly — we
# run the linter directly from the fixture by copying the script in), and
# asserts that a frontmatter-bearing file in a nested subdir is discovered
# and passes the frontmatter check.
#
# Exit 0 on pass. Exit 1 on any assertion failure.

set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REAL_LINTER="$SCRIPT_DIR/../../lint-architecture.sh"

if [ ! -f "$REAL_LINTER" ]; then
  echo "FAIL: cannot locate lint-architecture.sh at $REAL_LINTER" >&2
  exit 1
fi

TMPROOT=$(mktemp -d -t lint-arch-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Minimal repo skeleton the linter walks. Only _shared/ is exercised here
# (modes/SKILL.md walks are unchanged by Commit A).
mkdir -p "$TMPROOT/_shared/contracts" "$TMPROOT/scripts"

# Flat file — exists in the current tree; must still be found.
cat >"$TMPROOT/_shared/flat-doc.md" <<'EOF'
---
name: flat-doc
description: Top-level _shared doc
type: reference
---

# Flat
EOF

# Nested file — simulates post-Commit-C layout. Pre-widening this would have
# been invisible to the linter.
cat >"$TMPROOT/_shared/contracts/nested-doc.md" <<'EOF'
---
name: nested-doc
description: Nested _shared/contracts/ doc
type: contract
---

# Nested
EOF

# Deeper nesting — brief-formats style. Must be discovered but skipped by the
# frontmatter check per the narrow carve-out. Intentionally missing frontmatter
# to mirror the current brief-formats/ state.
mkdir -p "$TMPROOT/_shared/contracts/brief-formats"
cat >"$TMPROOT/_shared/contracts/brief-formats/legacy.md" <<'EOF'
# Legacy brief format — no frontmatter (matches current tree).
EOF

# Copy the linter in so SCRIPT_DIR/REPO_ROOT resolution lands inside TMPROOT.
cp "$REAL_LINTER" "$TMPROOT/scripts/lint-architecture.sh"
# lib-paths.sh is sourced best-effort; stub it so the source call succeeds.
: >"$TMPROOT/scripts/lib-paths.sh"

# Run the linter against the fixture tree.
OUT=$(bash "$TMPROOT/scripts/lint-architecture.sh" 2>&1 || true)

fail() {
  echo "FAIL: $1" >&2
  echo "--- linter output ---" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
}

# Assertion 1: nested-doc.md was discovered (absence would mean the walk
# skipped the contracts/ subdir — the exact regression we guard against).
# We prove discovery by stripping its frontmatter and re-running; a missing
# frontmatter violation must surface on the nested file.
rm "$TMPROOT/_shared/contracts/nested-doc.md"
cat >"$TMPROOT/_shared/contracts/nested-doc.md" <<'EOF'
# Nested — no frontmatter
EOF
OUT2=$(bash "$TMPROOT/scripts/lint-architecture.sh" 2>&1 || true)
if ! printf '%s\n' "$OUT2" | grep -q "E_FRONTMATTER.*nested-doc.md"; then
  fail "recursive walk did not reach _shared/contracts/nested-doc.md"
fi

# Assertion 2: brief-formats/legacy.md is discovered but exempt from the
# frontmatter check — no violation should surface for it.
if printf '%s\n' "$OUT2" | grep -q "E_FRONTMATTER.*brief-formats/legacy.md"; then
  fail "brief-formats/ carve-out did not exempt legacy.md from frontmatter check"
fi

# Assertion 3: with valid frontmatter restored on the nested file, the linter
# exits clean on the fixture tree (modulo the intentionally exempted legacy).
cat >"$TMPROOT/_shared/contracts/nested-doc.md" <<'EOF'
---
name: nested-doc
description: Nested _shared/contracts/ doc
type: contract
---

# Nested
EOF
if ! bash "$TMPROOT/scripts/lint-architecture.sh" >/dev/null 2>&1; then
  fail "linter should exit 0 when all discoverable files have valid frontmatter"
fi

echo "PASS: recursive walk discovers nested _shared/ subdirs"
