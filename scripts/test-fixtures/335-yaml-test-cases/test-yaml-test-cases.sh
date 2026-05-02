#!/usr/bin/env bash
# Regression fixture for #335: debrief YAML is the test-case authority.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t yaml-test-cases.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

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

PROJECT=fixture-project
PLANS="$TMPROOT/.dev-studio/$PROJECT/plans"
TASK_UUID=019dde9b-0000-7000-8000-000000000335
DEBRIEF_UUID=019dde9b-0000-7000-8000-000000000336
mkdir -p "$PLANS/tasks" "$PLANS/debriefs"

CASES='[
  {
    "title": "Open export sheet",
    "preconditions": "A project is open.",
    "steps": ["Tap Export", "Choose JPEG"],
    "expected": "The export sheet stays visible."
  }
]'

writer_out="$TMPROOT/writer.out"
writer_err="$TMPROOT/writer.err"
HOME="$TMPROOT" ACHILLES_PROJECT="$PROJECT" \
  bash "$ROOT/scripts/task-write-test-cases.sh" T335 "$CASES" >"$writer_out" 2>"$writer_err"
writer_rc=$?

assert "writer succeeds" "[ $writer_rc -eq 0 ]"
assert "writer preserves full case title" "jq -e '.[0].title == \"Open export sheet\"' '$writer_out' >/dev/null"
assert "writer preserves steps array" "jq -e '.[0].steps == [\"Tap Export\", \"Choose JPEG\"]' '$writer_out' >/dev/null"
assert "writer does not create legacy sidecar" "[ ! -e '$PLANS/chanakya-inbox/T335-tests.md' ]"

cat > "$PLANS/tasks/$TASK_UUID.yaml" <<YAML
legacy_task_id: T335
links:
  debrief: $DEBRIEF_UUID
YAML

cat > "$PLANS/debriefs/$DEBRIEF_UUID.yaml" <<YAML
tests:
  added:
    - title: Open export sheet
      preconditions: A project is open.
      steps:
        - Tap Export
        - Choose JPEG
      expected: The export sheet stays visible.
  modified:
    - Legacy title-only case
  skipped_because: null
YAML

pull_out="$TMPROOT/pull.out"
HOME="$TMPROOT" ACHILLES_PROJECT="$PROJECT" \
  bash "$ROOT/scripts/tests-pull-cases.sh" T335 >"$pull_out"
pull_rc=$?

assert "pull succeeds from YAML" "[ $pull_rc -eq 0 ]"
assert "pull emits canonical cases block" "grep -q '^cases:$' '$pull_out'"
assert "pull keeps YAML object title" "grep -q 'title: \"Open export sheet\"' '$pull_out'"
assert "pull keeps YAML object expected result" "grep -q 'expected: \"The export sheet stays visible.\"' '$pull_out'"
assert "pull tolerates legacy title-only YAML case" "grep -q 'title: \"Legacy title-only case\"' '$pull_out'"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
