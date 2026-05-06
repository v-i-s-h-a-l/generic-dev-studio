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

- `R001` line 1 - stated requirement: "Create the shared schema."
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

printf 'PASS: task graph synthesis\n'
