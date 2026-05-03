#!/usr/bin/env bash
# test-sweep-blind-spots.sh — fixture for #298.
#
# Verifies sweep-enumerate-debriefs.sh keeps stdout backward-compatible for
# ingestable YAML while surfacing non-ingestable blind spots on stderr.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t sweep-blind-spots.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=fixture
PROJ="$HOME/.dev-studio/fixture"
mkdir -p "$PROJ/plans/debriefs" "$PROJ/plans/chanakya-inbox" "$PROJ/plans/tasks" "$PROJ/apollo/deferred"

pass=0
fail=0

assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for sweep blind-spot fixture\n'
  exit 0
fi

cat > "$PROJ/plans/debriefs/TEST-1.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: task
task_id: task-1
legacy_task_id: T001
YAML

cat > "$PROJ/plans/debriefs/TEST-2.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: direct-debrief
task_id: null
YAML

cat > "$PROJ/plans/debriefs/TEST-debrief.md" <<'MD'
# Legacy debrief
MD

cat > "$PROJ/plans/chanakya-inbox/TEST-debrief.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: task
legacy_task_id: T002
YAML

cat > "$PROJ/plans/tasks/task-999.yaml" <<'YAML'
id: task-999
legacy_task_id: T999
state: merged
title: Closed blocker
YAML

cat > "$PROJ/apollo/deferred/TEST.yaml" <<'YAML'
id: TEST
mode: memory
artifact: memory-graph
blocker: T999
scheduled_at: 2026-04-28T00:00:00Z
YAML

OUT="$TMPROOT/stdout.txt"
ERR="$TMPROOT/stderr.txt"
bash "$ROOT/scripts/sweep-enumerate-debriefs.sh" >"$OUT" 2>"$ERR"
rc=$?

assert "sweep exits zero" "[ $rc -eq 0 ]"
assert "stdout keeps two ingestable YAML rows" "[ \$(wc -l < '$OUT' | tr -d ' ') -eq 2 ]"
assert "stdout rows remain three-column queue items" "awk -F '\t' 'NF != 3 { exit 1 } \$1 !~ /^(debrief|build-check|release)\$/ { exit 1 }' '$OUT'"
assert "legacy md blind spot is diagnosed with remediation" "grep -q 'TEST-debrief.md.*mode=legacy.*remediation=archive-or-migrate-to-plans-debriefs-yaml' '$ERR'"
assert "misrouted inbox debrief is diagnosed with remediation" "grep -q 'TEST-debrief.yaml.*location=chanakya-inbox.*remediation=move-to-plans-debriefs-yaml' '$ERR'"
assert "stale Apollo deferral is diagnosed" "grep -q 'TEST.yaml.*stale_blocker=true' '$ERR'"
assert "summary counts all classes" "grep -q '5 items (2 yaml, 1 legacy-md, 1 misrouted, 1 stale-deferred)' '$ERR'"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
