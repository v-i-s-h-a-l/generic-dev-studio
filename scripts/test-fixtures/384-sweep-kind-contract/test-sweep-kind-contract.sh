#!/usr/bin/env bash
# test-sweep-kind-contract.sh — regression fixture for sweep kind routing.
#
# The debrief enumerator must emit only canonical sweep-ingest subcommands.
# Historical aliases remain accepted by sweep-ingest during mixed-version
# rollout, but they must not appear in new queue rows.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t sweep-kind-contract.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=fixture
PROJ="$HOME/.dev-studio/fixture"
mkdir -p "$PROJ/plans/debriefs" "$PROJ/plans/tasks" "$PROJ/plans/releases" "$PROJ/events"

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
  printf 'SKIP: yq required for sweep kind contract fixture\n'
  exit 0
fi

cat > "$PROJ/plans/debriefs/001-task.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: task
task_id: task-1
legacy_task_id: T001
YAML

cat > "$PROJ/plans/debriefs/002-direct.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: direct-debrief
task_id: null
YAML

cat > "$PROJ/plans/debriefs/003-build.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: manual-build-check
result: inconclusive
YAML

cat > "$PROJ/plans/debriefs/004-release.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: release
tag: TF-384
channel: testflight
version: 1.0.0
build_number: 384
tasks: []
YAML

OUT="$TMPROOT/stdout.txt"
ERR="$TMPROOT/stderr.txt"
bash "$ROOT/scripts/sweep-enumerate-debriefs.sh" >"$OUT" 2>"$ERR"
rc=$?

assert "enumerator exits zero" "[ $rc -eq 0 ]"
assert "enumerator emits four queue rows" "[ \$(wc -l < '$OUT' | tr -d ' ') -eq 4 ]"
assert "enumerator emits only canonical ingest subcommands" \
  "awk -F '\t' 'NF != 3 { exit 1 } \$1 !~ /^(debrief|build-check|release)\$/ { exit 1 }' '$OUT'"
assert "enumerator does not emit historical aliases" \
  "! awk -F '\t' '\$1 ~ /^(task-debrief|direct-debrief|manual-build-check)\$/ { found=1 } END { exit found ? 0 : 1 }' '$OUT'"
assert "task and direct debriefs both route through debrief" \
  "[ \$(awk -F '\t' '\$1 == \"debrief\" { n++ } END { print n + 0 }' '$OUT') -eq 2 ]"
assert "manual build check routes through build-check" \
  "awk -F '\t' '\$1 == \"build-check\" && \$2 ~ /003-build.yaml\$/ { found=1 } END { exit found ? 0 : 1 }' '$OUT'"
assert "release routes through release" \
  "awk -F '\t' '\$1 == \"release\" && \$2 ~ /004-release.yaml\$/ { found=1 } END { exit found ? 0 : 1 }' '$OUT'"

cat > "$PROJ/plans/debriefs/alias-task.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: task
YAML

cat > "$PROJ/plans/debriefs/alias-direct.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: direct-debrief
YAML

cat > "$PROJ/plans/debriefs/alias-build.yaml" <<'YAML'
schema: debrief@2.0.2
state: emitted
mode: manual-build-check
result: inconclusive
YAML

bash "$ROOT/scripts/sweep-ingest.sh" task-debrief "$PROJ/plans/debriefs/alias-task.yaml" >/dev/null 2>"$TMPROOT/alias-task.err"
alias_task_rc=$?
bash "$ROOT/scripts/sweep-ingest.sh" direct-debrief "$PROJ/plans/debriefs/alias-direct.yaml" >/dev/null 2>"$TMPROOT/alias-direct.err"
alias_direct_rc=$?
bash "$ROOT/scripts/sweep-ingest.sh" manual-build-check "$PROJ/plans/debriefs/alias-build.yaml" >/dev/null 2>"$TMPROOT/alias-build.err"
alias_build_rc=$?

assert "task-debrief alias still normalizes" "[ $alias_task_rc -eq 0 ]"
assert "direct-debrief alias still normalizes" "[ $alias_direct_rc -eq 0 ]"
assert "manual-build-check alias still normalizes" "[ $alias_build_rc -eq 0 ]"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
