#!/usr/bin/env bash
# task-load-spec parity fixture — proves canonical YAML dispatch, task/brief
# parity enforcement, and opt-in diagnostic legacy fallback.
#
# Run: bash scripts/test-fixtures/task-load-spec/parity.sh

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t task-load-spec.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for task-load-spec parity fixture\n'
  exit 0
fi

HOME_DIR="$TMPROOT/home"
export HOME="$HOME_DIR"
export ACHILLES_PROJECT="task-load-spec-fixture"

PROJECT_ROOT="$HOME_DIR/.dev-studio/$ACHILLES_PROJECT"
mkdir -p "$PROJECT_ROOT/plans/tasks" "$PROJECT_ROOT/plans/briefs" "$PROJECT_ROOT/plans/chanakya-tasks"

DEPLOY_ROOT="$TMPROOT/deployed"
CLAUDE_ROOT="$DEPLOY_ROOT/claude/generic-dev-studio"
CODEX_ROOT="$DEPLOY_ROOT/codex/generic-dev-studio"
mkdir -p "$(dirname "$CLAUDE_ROOT")" "$(dirname "$CODEX_ROOT")"
ln -s "$ROOT" "$CLAUDE_ROOT"
ln -s "$ROOT" "$CODEX_ROOT"

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

TASK_UUID="11111111-1111-7111-8111-111111111111"
BRIEF_UUID="22222222-2222-7222-8222-222222222222"
BAD_TASK_UUID="33333333-3333-7333-8333-333333333333"
BAD_BRIEF_UUID="44444444-4444-7444-8444-444444444444"

cat > "$PROJECT_ROOT/plans/tasks/$TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_UUID
legacy_task_id: "T336"
title: Canonical brief dispatch
state: briefed
type: feature
size: m
links:
  brief: $BRIEF_UUID
  debrief: null
  reviews: []
  release: null
  feedback: []
YAML

cat > "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml" <<YAML
schema_version: {name: brief, version: 3.5.0, min_reader: 3.0.0, deprecated_at: null}
id: $BRIEF_UUID
task_id: $TASK_UUID
legacy_task_id: "T336"
type: impl
size: m
state: ready
created_at: 2026-04-30T00:00:00Z
updated_at: 2026-04-30T00:00:00Z
reads: []
writes: []
acceptance:
  - canonical
testability: []
rework_of: null
reproducer: null
dispatch_agent: achilles
perf_mode: null
evidence: null
summary: canonical dispatch fixture
body: |
  Canonical dispatch fixture.
YAML

cat > "$PROJECT_ROOT/plans/tasks/$BAD_TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $BAD_TASK_UUID
legacy_task_id: "T337"
title: Broken parity
state: briefed
type: feature
size: m
links:
  brief: $BAD_BRIEF_UUID
  debrief: null
  reviews: []
  release: null
  feedback: []
YAML

cat > "$PROJECT_ROOT/plans/briefs/$BAD_BRIEF_UUID.yaml" <<YAML
schema_version: {name: brief, version: 3.5.0, min_reader: 3.0.0, deprecated_at: null}
id: $BAD_BRIEF_UUID
task_id: $TASK_UUID
legacy_task_id: "T337"
type: impl
size: m
state: ready
created_at: 2026-04-30T00:00:00Z
updated_at: 2026-04-30T00:00:00Z
reads: []
writes: []
acceptance:
  - broken parity
testability: []
rework_of: null
reproducer: null
dispatch_agent: achilles
perf_mode: null
evidence: null
summary: broken parity fixture
body: |
  Broken parity fixture.
YAML

cat > "$PROJECT_ROOT/plans/chanakya-tasks/T338-impl.md" <<'MD'
# Task Brief: T338 — Legacy diagnostic brief

Size: S
Type: feature

Diagnostic legacy fixture.
MD

CLAUDE_GOOD="$TMPROOT/claude-good.out"
CODEX_GOOD="$TMPROOT/codex-good.out"
CLAUDE_GOOD_ERR="$TMPROOT/claude-good.err"
CODEX_GOOD_ERR="$TMPROOT/codex-good.err"

if ! "$CLAUDE_ROOT/scripts/task-load-spec.sh" T336 >"$CLAUDE_GOOD" 2>"$CLAUDE_GOOD_ERR"; then
  printf 'not ok - canonical YAML dispatch under Claude root failed\n' >&2
  cat "$CLAUDE_GOOD_ERR" >&2
  exit 1
fi
if ! "$CODEX_ROOT/scripts/task-load-spec.sh" T336 >"$CODEX_GOOD" 2>"$CODEX_GOOD_ERR"; then
  printf 'not ok - canonical YAML dispatch under Codex root failed\n' >&2
  cat "$CODEX_GOOD_ERR" >&2
  exit 1
fi

assert "canonical outputs are identical across deployed roots" "cmp -s '$CLAUDE_GOOD' '$CODEX_GOOD'"
assert "canonical output names the YAML brief" "grep -q 'BRIEF_PATH=.*/plans/briefs/$BRIEF_UUID.yaml' '$CLAUDE_GOOD'"
assert "canonical output has brief UUID" "grep -q '^BRIEF_UUID=$BRIEF_UUID$' '$CLAUDE_GOOD'"
assert "canonical output is a brief task" "grep -q '^TASK_MODE=brief$' '$CLAUDE_GOOD'"

BAD_OUT="$TMPROOT/bad.out"
BAD_ERR="$TMPROOT/bad.err"
if "$ROOT/scripts/task-load-spec.sh" T337 >"$BAD_OUT" 2>"$BAD_ERR"; then
  printf 'not ok - parity-mismatched brief unexpectedly dispatched\n' >&2
  exit 1
fi
assert "parity mismatch fails loudly" "grep -q 'task/brief parity mismatch' '$BAD_ERR'"
if TASK_LOAD_SPEC_DIAGNOSTIC=1 "$ROOT/scripts/task-load-spec.sh" T337 >"$BAD_OUT" 2>"$BAD_ERR"; then
  printf 'not ok - diagnostic mode masked parity mismatch\n' >&2
  exit 1
fi
assert "diagnostic mode still blocks parity mismatch" "grep -q 'task/brief parity mismatch' '$BAD_ERR'"

LEGACY_OUT="$TMPROOT/legacy.out"
LEGACY_ERR="$TMPROOT/legacy.err"
if "$ROOT/scripts/task-load-spec.sh" T338 >"$LEGACY_OUT" 2>"$LEGACY_ERR"; then
  printf 'not ok - legacy-only task should fail without diagnostic opt-in\n' >&2
  exit 1
fi
assert "legacy-only task fails by default" "grep -q 'no brief found for task-id' '$LEGACY_ERR'"
if ! TASK_LOAD_SPEC_DIAGNOSTIC=1 "$ROOT/scripts/task-load-spec.sh" T338 >"$LEGACY_OUT" 2>"$LEGACY_ERR"; then
  printf 'not ok - diagnostic legacy dispatch failed\n' >&2
  cat "$LEGACY_ERR" >&2
  exit 1
fi
assert "diagnostic legacy path resolves the markdown brief" "grep -q '^BRIEF_PATH=.*/plans/chanakya-tasks/T338-impl.md$' '$LEGACY_OUT'"
assert "diagnostic legacy path keeps BRIEF_UUID empty" "grep -q '^BRIEF_UUID=$' '$LEGACY_OUT'"
assert "diagnostic legacy path parses legacy size" "grep -q '^SIZE=s$' '$LEGACY_OUT'"
assert "diagnostic legacy path parses legacy type" "grep -q '^TYPE=feature$' '$LEGACY_OUT'"
EVENT_LOG="$HOME_DIR/.dev-studio/$ACHILLES_PROJECT/events/$(date -u +%F).jsonl"
assert "diagnostic legacy path emits observability" "grep -q 'legacy_artifact_read' '$EVENT_LOG'"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
