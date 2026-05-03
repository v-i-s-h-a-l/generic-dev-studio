#!/usr/bin/env bash
# Fixture for #335: test cases come from debrief YAML only.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t yaml-test-cases-335.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="fixture-335"
PROJ="$HOME/.dev-studio/$ACHILLES_PROJECT"
TASK_UUID="01234567-89ab-7cde-8000-000000000335"
DEBRIEF_UUID="01234567-89ab-7cde-8000-000000003350"

mkdir -p "$PROJ/plans/tasks" "$PROJ/plans/debriefs" "$PROJ/plans/chanakya-inbox/processed"

cat > "$PROJ/plans/tasks/$TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_UUID
legacy_task_id: T335
title: "Fixture task"
state: done
created_at: 2026-05-02T00:00:00Z
updated_at: 2026-05-02T00:00:00Z
links:
  brief: null
  debrief: $DEBRIEF_UUID
  reviews: []
  release: null
  feedback: []
history: []
YAML

cat > "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml" <<YAML
schema_version: {name: debrief, version: 2.0.2, min_reader: 2.0.0, deprecated_at: null}
id: $DEBRIEF_UUID
task_id: $TASK_UUID
legacy_task_id: T335
state: ingested
tests:
  added:
    - title: "YAML case: colon"
      preconditions: "fixture ready"
      steps: "run the flow"
      expected: "passes"
  modified: []
YAML

cat > "$PROJ/plans/chanakya-inbox/T335-tests.md" <<'MD'
## Test Cases
- Legacy standalone case
MD

cat > "$PROJ/plans/chanakya-inbox/processed/T335-debrief.md" <<'MD'
## Test Cases
- Legacy processed case
MD

out="$TMPROOT/out.yaml"
bash "$ROOT/scripts/tests-pull-cases.sh" T335 > "$out"

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

assert "YAML case emitted with quoted title" "grep -q 'title: \"YAML case: colon\"' '$out'"
assert "standalone markdown ignored" "! grep -q 'Legacy standalone case' '$out'"
assert "processed markdown ignored" "! grep -q 'Legacy processed case' '$out'"

rm -f "$PROJ/plans/debriefs/$DEBRIEF_UUID.yaml"
bash "$ROOT/scripts/tests-pull-cases.sh" T335 > "$out"
assert "missing YAML produces empty output, not legacy fallback" "[ ! -s '$out' ]"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: #335 YAML-only test cases\n'
