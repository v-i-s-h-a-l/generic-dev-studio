#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/prd-task-graph-synthesize.sh"
TMPROOT=$(mktemp -d -t task-graph.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/prd-task-graph-synthesize.sh is not executable"
command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq required\n'; exit 0; }

PACKET="$TMPROOT/packet.md"
GRAPH="$TMPROOT/graph.json"

cat >"$PACKET" <<'EOF'
# Fixture Requirement Packet

## Intake Metadata

- Source: `fixture-650`
- Method: deterministic lexical normalization; exact source language is quoted below.

## Explicit Requirements

- `R001` line 1 - stated requirement: "Create the shared schema in `_shared/contracts/generated.md`."
- `R002` line 2 - stated requirement: "Write implementation to `scripts/generated.sh` after R001."
- `R003` line 3 - stated requirement: "Write tests to `scripts/test-fixtures/generated/run.sh` after R001."

## Inferred Behavior To Confirm

- None detected deterministically.

## Stated Non-Goals

- None detected deterministically.

## Ambiguities And Missing Details

- None detected deterministically.

## Conflicts

- None detected deterministically.
EOF

"$RUN" "$PACKET" >"$GRAPH"
jq -e '
  .kind == "task-graph" and
  .validation.status == "valid" and
  (.nodes | length) == 3 and
  (.edges | length) == 2 and
  (.ready_node_ids == ["T-R001"]) and
  (.nodes[] | select(.id == "T-R002") | .write_resources == ["scripts/generated.sh"]) and
  (.nodes[] | select(.id == "T-R003") | .status == "blocked")
' "$GRAPH" >/dev/null || fail "valid graph did not preserve deterministic dependencies and readiness"

"$RUN" "$PACKET" >"$TMPROOT/graph-again.json"
cmp "$GRAPH" "$TMPROOT/graph-again.json" >/dev/null || fail "graph output should be deterministic"

MISSING="$TMPROOT/missing.md"
cat >"$MISSING" <<'EOF'
# Missing Dependency Packet

## Intake Metadata

- Source: `missing`

## Explicit Requirements

- `R001` line 1 - stated requirement: "Implement worker after R999."

## Ambiguities And Missing Details

- `M001`: Output format or schema is not stated explicitly.

## Conflicts

- None detected deterministically.
EOF

if "$RUN" "$MISSING" >"$TMPROOT/missing.json" 2>"$TMPROOT/missing.err"; then
  fail "missing prerequisite graph unexpectedly passed"
fi
jq -e '
  .validation.status == "invalid" and
  (.validation.missing_dependencies[0].missing_source_id == "R999") and
  (.validation.unresolved_missing_details[0].source_id == "M001") and
  (.nodes[] | select(.id == "T-R001") | .dependencies | index("T-M001"))
' "$TMPROOT/missing.json" >/dev/null || fail "missing dependency and shared prerequisite should be serialized"
grep -q 'missing_dependencies' "$TMPROOT/missing.err" || fail "missing dependency failure should be explained"

RACE="$TMPROOT/race.md"
cat >"$RACE" <<'EOF'
# Race Packet

## Intake Metadata

- Source: `race`

## Explicit Requirements

- `R001` line 1 - stated requirement: "Write adapter to `scripts/shared.sh`."
- `R002` line 2 - stated requirement: "Modify fallback to `scripts/shared.sh`."

## Conflicts

- None detected deterministically.
EOF

if "$RUN" "$RACE" >"$TMPROOT/race.json" 2>"$TMPROOT/race.err"; then
  fail "parallel write race graph unexpectedly passed"
fi
jq -e '
  .validation.status == "invalid" and
  (.validation.parallel_write_races[0].resource == "scripts/shared.sh") and
  (.validation.parallel_write_races[0].node_ids == ["T-R001","T-R002"])
' "$TMPROOT/race.json" >/dev/null || fail "parallel write race should be serialized"

HEADINGS="$TMPROOT/headings.md"
cat >"$HEADINGS" <<'EOF'
# Four Heading Source

### 1. Create parser

- Write `scripts/parser.sh`.

### 2. Create schema

- Write `_shared/contracts/parser.md` after R001.

### 3. Add tests

- Write `scripts/test-fixtures/parser/run.sh` after R002.

### 4. Update docs

- Write `README.md` after R003.
EOF

"$RUN" "$HEADINGS" >"$TMPROOT/headings.json"
jq -e '
  .validation.status == "valid" and
  ([.nodes[] | select(.kind == "task")] | length) == 4 and
  (.nodes[] | select(.id == "T-R004") | .dependencies == ["T-R003"])
' "$TMPROOT/headings.json" >/dev/null || fail "component headings should produce exactly four task nodes"

EMPTY_ALLOWED="$TMPROOT/empty-allowed.md"
cat >"$EMPTY_ALLOWED" <<'EOF'
# Empty Allowed Paths Source

### 1. Decide policy

- No concrete write surface is specified.

### 2. Apply policy

- allowed_paths_unscoped: true
- allowed_paths_unscoped_justification: This is an explicit fixture escape hatch.
EOF

if "$RUN" "$EMPTY_ALLOWED" >"$TMPROOT/empty-allowed.json" 2>"$TMPROOT/empty-allowed.err"; then
  fail "empty allowed paths graph unexpectedly passed"
fi
jq -e '
  .validation.status == "invalid" and
  (.validation.empty_allowed_paths[0].node_id == "T-R001") and
  ([.validation.empty_allowed_paths[].node_id] | index("T-R002") | not) and
  (.nodes[] | select(.id == "T-R002") | .allowed_paths_unscoped == true)
' "$TMPROOT/empty-allowed.json" >/dev/null || fail "empty allowed paths should fail unless explicitly unscoped"
grep -q 'empty_allowed_paths' "$TMPROOT/empty-allowed.err" || fail "empty allowed paths failure should be explained"

OPEN_QUESTIONS="$TMPROOT/open-questions.md"
cat >"$OPEN_QUESTIONS" <<'EOF'
# Open Questions Source

### 1. Create thing

- Write `scripts/thing.sh`.

### 2. Test thing

- Write `scripts/test-fixtures/thing/run.sh` after R001.

## Open questions for the planner

- Should this use a global policy?
- What threshold should be configured?
EOF

if "$RUN" "$OPEN_QUESTIONS" >"$TMPROOT/open-questions.json" 2>"$TMPROOT/open-questions.err"; then
  fail "open questions graph unexpectedly passed without --allow-missing-details"
fi
jq -e '
  .validation.status == "invalid" and
  ([.nodes[] | select(.kind == "task")] | length) == 2 and
  (.validation.unresolved_missing_details | length) == 2 and
  ([.nodes[].label] | all(contains("threshold") | not))
' "$TMPROOT/open-questions.json" >/dev/null || fail "open questions should be missing details, not tasks"

FRAGMENT="$TMPROOT/fragment.md"
cat >"$FRAGMENT" <<'EOF'
# Fragment Packet

## Intake Metadata

- Source: `fragment`

## Explicit Requirements

- `R001` line 1 - stated requirement: "`T-R001: after the planner, where"

## Ambiguities And Missing Details

- None detected deterministically.

## Conflicts

- None detected deterministically.
EOF

if "$RUN" "$FRAGMENT" >"$TMPROOT/fragment.json" 2>"$TMPROOT/fragment.err"; then
  fail "fragment-shaped task graph unexpectedly passed"
fi
jq -e '
  .validation.status == "invalid" and
  (.validation.fragment_labels[0].node_id == "T-R001")
' "$TMPROOT/fragment.json" >/dev/null || fail "fragment-shaped labels should fail validation"
grep -q 'fragment_labels' "$TMPROOT/fragment.err" || fail "fragment label failure should be explained"

BRANCH_INLINE="$TMPROOT/branch-inline.md"
cat >"$BRANCH_INLINE" <<'EOF'
# Branch Discipline Fixture

### 1. Per-project branch policy in `feature-config`

- Extend `scripts/manager-feature-config.sh`.

### 2. Source-branch lock-in at plan-chain, work-chain, and resume

- Write `_shared/contracts/chain-task-envelope.md`.
- Update `scripts/manager-plan-chain.sh`.

### 3. Ingest pre-flight prompt + always-on context header

- Update `scripts/dev-studio-ingest-resolve.sh`.

### 4. PR-finalize gate + pre-commit hook

- Update `scripts/pr-merge-finalize.sh`.
- Update `hooks/pre-commit`.

### 5. Worktree-isolated interactive sessions + 3-layer cleanup

- Create `scripts/studio-worktree-gc.sh`.

### 6. Stacked-parent lifecycle + policy doctor

- Update `scripts/manager-release-branch.sh`.
EOF

"$RUN" "$BRANCH_INLINE" >"$TMPROOT/branch-inline.json"
jq -e '
  .validation.status == "valid" and
  ([.nodes[] | select(.kind == "task")] | length) == 6 and
  ([
    .edges[] | select(.from == "T-R001") | .to
  ] | sort == ["T-R002","T-R003","T-R004","T-R005","T-R006"]) and
  ([
    .edges[] | select(.from == "T-R002") | .to
  ] | sort == ["T-R003","T-R006"])
' "$TMPROOT/branch-inline.json" >/dev/null || fail "inline branch-shaped source should preserve dependency sequencing"

BRANCH_SOURCE="/Users/vishalsingh/.dev-studio/generic-dev-studio/plan-chains/branch-discipline-source.md"
if [ -r "$BRANCH_SOURCE" ]; then
  "$RUN" "$BRANCH_SOURCE" >"$TMPROOT/branch-discipline.json"
  jq -e '
    .validation.status == "valid" and
    ([.nodes[] | select(.kind == "task")] | length) == 6 and
    ([.nodes[] | select(.kind == "task" and ((.write_resources // []) | length == 0))] | length) == 0 and
    ([
      .edges[] | select(.from == "T-R001") | .to
    ] | sort == ["T-R002","T-R003","T-R004","T-R005","T-R006"]) and
    ([
      .edges[] | select(.from == "T-R002") | .to
    ] | sort == ["T-R003","T-R006"])
  ' "$TMPROOT/branch-discipline.json" >/dev/null || fail "branch discipline source should produce six bounded component tasks"
fi

printf 'PASS: task graph synthesis\n'
