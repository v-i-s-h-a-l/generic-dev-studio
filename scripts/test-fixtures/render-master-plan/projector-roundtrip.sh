#!/usr/bin/env bash
# projector-roundtrip.sh — fixture test for scripts/render-master-plan.sh and
# scripts/extract-master-plan-preamble.sh (Stage A.0 / #273).
#
# Walks four scenarios:
#   1. Bootstrap from existing master-plan: extractor produces preamble.md +
#      build-debt.yaml; projector renders chanakya-master.md byte-stable.
#   2. Build-debt YAML mutation: helpers update YAML; projector reflects it.
#   3. Released-in annotation: task with links.release renders TF-N annotation.
#   4. Safeguard: projector refuses to overwrite a master-plan when no
#      preamble.md exists (would lose editorial content).
#
# Run: bash scripts/test-fixtures/render-master-plan/projector-roundtrip.sh
# Pass: prints "PASS (N assertions)" with exit 0.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

TMPROOT=$(mktemp -d -t render-mp-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Override HOME so resolve_project_root_for lands inside the temp dir. The
# fixture project slug is unique to avoid colliding with any real project.
export HOME="$TMPROOT"
PROJECT="render-mp-fixture"
PROJ_ROOT="$HOME/.dev-studio/$PROJECT"
PLANS_DIR="$PROJ_ROOT/plans"
mkdir -p "$PLANS_DIR/tasks" "$PLANS_DIR/releases"

export ACHILLES_PROJECT="$PROJECT"
export ACHILLES_DISPLAY_NAME="Render MP Fixture"

assertions=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then fail "$1 — failed: $2"; fi
}

# ---------- Scenario 1: bootstrap from existing master-plan -----------------

cat > "$PLANS_DIR/chanakya-master.md" <<'EOF'
# Render MP Fixture — Master Plan
**Updated:** 2026-04-27 (initial seed for fixture)

---

## Dashboard
- Active: 2
- Notes: editorial preamble that must round-trip through extractor

## Build Debt

- Counter: 4 / warn@6 / block@12
- State: silent
- Last green: build-fixture (2026-04-27)
- Last green SHA: deadbee
- Unverified since: [T010, T011]
- Open check task: —
- Blocked by: —
- Next TBUILD n: 2

## Module Index

| Module | Active |
|--------|--------|
| Test   | T010   |

---

## Active Tasks

### T010 — Sample task one
- **Priority:** P1
- **Status:** briefed

### T020 — Sample task two
- **Priority:** P2
- **Status:** merged

## Release Log

| Build | Version | Type | Date | Tag | HEAD | Tasks Included |
|-------|---------|------|------|-----|------|---------------|
EOF

cat > "$PLANS_DIR/tasks/11111111-aaaa-7000-8000-000000000010.yaml" <<'EOF'
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 11111111-aaaa-7000-8000-000000000010
title: "Sample task one"
state: briefed
links:
  brief: null
  debrief: null
  reviews: []
  release: null
  feedback: []
legacy_task_id: "T010"
legacy_row: |
  - **Priority:** P1
  - **Status:** briefed
EOF

cat > "$PLANS_DIR/tasks/22222222-bbbb-7000-8000-000000000020.yaml" <<'EOF'
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 22222222-bbbb-7000-8000-000000000020
title: "Sample task two"
state: merged
links:
  brief: null
  debrief: null
  reviews: []
  release: 33333333-cccc-7000-8000-000000000099
  feedback: []
legacy_task_id: "T020"
legacy_row: |
  - **Priority:** P2
  - **Status:** merged
EOF

cat > "$PLANS_DIR/releases/33333333-cccc-7000-8000-000000000099.yaml" <<'EOF'
schema_version: {name: release, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 33333333-cccc-7000-8000-000000000099
channel: testflight
state: released
build_number: 9999
version: "1.0.0"
tag: "TF-9999"
commit_sha: "abc1234"
released_at: 2026-04-27T10:00:00Z
tasks: ["T020"]
EOF

# Run the extractor.
bash "$REPO_SCRIPTS/extract-master-plan-preamble.sh" 2>&1 | grep -q "wrote.*master-plan-preamble.md" \
  || fail "extractor did not write preamble.md"
bash "$REPO_SCRIPTS/extract-master-plan-preamble.sh" 2>&1 | grep -q "already exists" \
  || fail "extractor not idempotent on second run"

assert "preamble.md exists" "[ -f '$PLANS_DIR/master-plan-preamble.md' ]"
assert "build-debt.yaml exists" "[ -f '$PLANS_DIR/build-debt.yaml' ]"
assert "preamble preserves Dashboard" "grep -q '## Dashboard' '$PLANS_DIR/master-plan-preamble.md'"
assert "preamble preserves Module Index" "grep -q '## Module Index' '$PLANS_DIR/master-plan-preamble.md'"
assert "preamble does NOT contain Build Debt block" \
  "! grep -q '## Build Debt' '$PLANS_DIR/master-plan-preamble.md'"
assert "preamble does NOT contain Active Tasks" \
  "! grep -q '## Active Tasks' '$PLANS_DIR/master-plan-preamble.md'"

# build-debt.yaml carries the right values.
counter=$(yq -r '.counter' "$PLANS_DIR/build-debt.yaml")
state=$(yq -r '.state' "$PLANS_DIR/build-debt.yaml")
warn_at=$(yq -r '.warn_at' "$PLANS_DIR/build-debt.yaml")
block_at=$(yq -r '.block_at' "$PLANS_DIR/build-debt.yaml")
last_sha=$(yq -r '.last_green_sha' "$PLANS_DIR/build-debt.yaml")
next_n=$(yq -r '.next_tbuild_n' "$PLANS_DIR/build-debt.yaml")
unverified_count=$(yq -r '.unverified_since | length' "$PLANS_DIR/build-debt.yaml")
assert "extracted counter=4" "[ '$counter' = '4' ]"
assert "extracted state=silent" "[ '$state' = 'silent' ]"
assert "extracted warn_at=6" "[ '$warn_at' = '6' ]"
assert "extracted block_at=12" "[ '$block_at' = '12' ]"
assert "extracted last_green_sha=deadbee" "[ '$last_sha' = 'deadbee' ]"
assert "extracted next_tbuild_n=2" "[ '$next_n' = '2' ]"
assert "unverified_since has 2 entries" "[ '$unverified_count' = '2' ]"

# Run the projector.
bash "$REPO_SCRIPTS/render-master-plan.sh" 2>&1 || fail "projector failed"

OUT="$PLANS_DIR/chanakya-master.md"
assert "rendered file present" "[ -f '$OUT' ]"
assert "header has display name" "head -1 '$OUT' | grep -q 'Render MP Fixture — Master Plan'"
assert "Dashboard preserved via preamble" "grep -q '## Dashboard' '$OUT'"
assert "Build Debt section rendered" "grep -q '^## Build Debt' '$OUT'"
assert "Build Debt counter=4 in projection" "grep -q '^- Counter: 4 / warn@6 / block@12' '$OUT'"
assert "Active Tasks heading rendered" "grep -q '^## Active Tasks' '$OUT'"
assert "T010 emitted with title" "grep -q '^### T010 — Sample task one' '$OUT'"
assert "T020 emitted with title" "grep -q '^### T020 — Sample task two' '$OUT'"
assert "T010 sorts before T020" \
  "[ \"\$(grep -n '^### T010\\|^### T020' '$OUT' | head -2 | head -1 | grep -o T020)\" = \"\" ]"

# Released-in annotation joins task → release via links.release.
assert "T020 has Released-in annotation" "grep -A1 '^### T020' '$OUT' | grep -q 'Released in:.*TF-9999'"
assert "T010 has no Released-in annotation" \
  "[ \"\$(awk '/^### T010/{p=1; next} /^### /{p=0} p && /Released in:/' '$OUT')\" = \"\" ]"

# Release log table populated.
assert "Release log row for build 9999" "grep -q '| 9999 | 1.0.0 | testflight |' '$OUT'"

# Idempotency: running again produces byte-identical output (modulo timestamp).
sha_a=$(grep -v '^\*\*Updated:\*\*' "$OUT" | shasum | awk '{print $1}')
sleep 1
bash "$REPO_SCRIPTS/render-master-plan.sh" 2>&1 || fail "second projector run failed"
sha_b=$(grep -v '^\*\*Updated:\*\*' "$OUT" | shasum | awk '{print $1}')
assert "projector is idempotent (modulo timestamp)" "[ '$sha_a' = '$sha_b' ]"

# ---------- Scenario 2: build-debt mutation via lib-ledger -----------------

# shellcheck source=../../lib-paths.sh
. "$REPO_SCRIPTS/lib-paths.sh"
# shellcheck source=../../lib-ledger.sh
. "$REPO_SCRIPTS/lib-ledger.sh"

build_debt_increment "T030" 0 || fail "build_debt_increment failed"
new_counter=$(yq -r '.counter' "$PLANS_DIR/build-debt.yaml")
unverified_last=$(yq -r '.unverified_since[-1]' "$PLANS_DIR/build-debt.yaml")
assert "increment counter to 5" "[ '$new_counter' = '5' ]"
assert "appended T030 to unverified" "[ '$unverified_last' = 'T030' ]"

build_debt_increment "T031" 1 || fail "build_debt_increment overridden failed"
new_counter=$(yq -r '.counter' "$PLANS_DIR/build-debt.yaml")
new_state=$(yq -r '.state' "$PLANS_DIR/build-debt.yaml")
unverified_last=$(yq -r '.unverified_since[-1]' "$PLANS_DIR/build-debt.yaml")
assert "increment to 6 crosses warn threshold" "[ '$new_counter' = '6' ]"
assert "state transitioned to warn" "[ '$new_state' = 'warn' ]"
assert "appended T031[overridden]" "[ '$unverified_last' = 'T031[overridden]' ]"

bash "$REPO_SCRIPTS/render-master-plan.sh" 2>&1 || fail "projector failed after mutation"
assert "rendered counter reflects mutation (6)" "grep -q '^- Counter: 6 / warn@6 / block@12' '$OUT'"
assert "rendered state reflects mutation (warn)" "grep -q '^- State: warn' '$OUT'"

build_debt_reset_green "fixture green" "cafef00" || fail "build_debt_reset_green failed"
new_counter=$(yq -r '.counter' "$PLANS_DIR/build-debt.yaml")
new_state=$(yq -r '.state' "$PLANS_DIR/build-debt.yaml")
empty_unverified=$(yq -r '.unverified_since | length' "$PLANS_DIR/build-debt.yaml")
assert "green reset counter=0" "[ '$new_counter' = '0' ]"
assert "green reset state=silent" "[ '$new_state' = 'silent' ]"
assert "green clears unverified" "[ '$empty_unverified' = '0' ]"

build_debt_annotate_red "feedb55" "TBUILD-2" || fail "build_debt_annotate_red failed"
new_state=$(yq -r '.state' "$PLANS_DIR/build-debt.yaml")
broken=$(yq -r '.broken_commit_sha' "$PLANS_DIR/build-debt.yaml")
blocked=$(yq -r '.blocked_by' "$PLANS_DIR/build-debt.yaml")
assert "red forces state=block" "[ '$new_state' = 'block' ]"
assert "red sets broken_commit_sha" "[ '$broken' = 'feedb55' ]"
assert "red sets blocked_by" "[ '$blocked' = 'TBUILD-2' ]"

# ---------- Scenario 3: safeguard against overwrite ------------------------

mv "$PLANS_DIR/master-plan-preamble.md" "$PLANS_DIR/master-plan-preamble.md.bak"
if bash "$REPO_SCRIPTS/render-master-plan.sh" 2>/dev/null; then
  fail "projector should refuse without preamble"
fi
mv "$PLANS_DIR/master-plan-preamble.md.bak" "$PLANS_DIR/master-plan-preamble.md"

# Override env var should let it through.
RENDER_MASTER_PLAN_FORCE=1 bash "$REPO_SCRIPTS/render-master-plan.sh" 2>&1 \
  || fail "force-override failed"

# ---------- Scenario 4: extractor handles missing build-debt block ---------

# Fresh project with master-plan that has no Build Debt section.
PROJECT2="render-mp-fixture-2"
PROJ_ROOT2="$HOME/.dev-studio/$PROJECT2"
mkdir -p "$PROJ_ROOT2/plans"
cat > "$PROJ_ROOT2/plans/chanakya-master.md" <<'EOF'
# Fixture 2 — Master Plan
**Updated:** 2026-04-27

---

## Dashboard
- Active: 0

### T999 — placeholder
- **Status:** proposed
EOF

ACHILLES_PROJECT="$PROJECT2" bash "$REPO_SCRIPTS/extract-master-plan-preamble.sh" 2>&1 \
  | grep -q "seeding defaults" \
  || fail "extractor should warn on missing Build Debt block"
counter2=$(yq -r '.counter' "$PROJ_ROOT2/plans/build-debt.yaml")
assert "missing block extracts counter=0" "[ '$counter2' = '0' ]"

printf 'PASS (%d assertions)\n' "$assertions"
