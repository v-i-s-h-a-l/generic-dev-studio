#!/usr/bin/env bash
# Regression fixture for #336: task-load-spec.sh resolves briefs only through
# task.links.brief and behaves identically from Claude and Codex skill roots.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t brief-resolution.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq required"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

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

PROJECT=brief-resolution-project
HOME_ROOT="$TMPROOT/home"
PROJECT_ROOT="$HOME_ROOT/.dev-studio/$PROJECT"
TASK_UUID=019de9f1-0000-7000-8000-000000000336
BRIEF_UUID=019de9f1-0000-7000-8000-000000000337
STALE_BRIEF_UUID=019de9f1-0000-7000-8000-000000000338

mkdir -p "$PROJECT_ROOT/plans/tasks" "$PROJECT_ROOT/plans/briefs" "$PROJECT_ROOT/plans/chanakya-tasks" "$PROJECT_ROOT/events"

cat > "$PROJECT_ROOT/plans/tasks/$TASK_UUID.yaml" <<YAML
schema_version: {name: task, version: 1.1.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_UUID
legacy_task_id: "T336"
title: Brief resolution parity
state: briefed
type: feature
size: s
links: {brief: $BRIEF_UUID}
created_at: 2026-05-02T00:00:00Z
updated_at: 2026-05-02T00:00:00Z
YAML

cat > "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml" <<YAML
schema_version: {name: brief, version: 3.8.0, min_reader: 3.0.0, deprecated_at: null}
id: $BRIEF_UUID
task_id: $TASK_UUID
legacy_task_id: "T336"
type: impl
size: s
state: ready
acceptance: ["Resolve through task.links.brief only."]
created_at: 2026-05-02T00:00:00Z
updated_at: 2026-05-02T00:00:00Z
body: |
  ## Objective
  Keep brief resolution canonical.
YAML

cat > "$PROJECT_ROOT/plans/briefs/$STALE_BRIEF_UUID.yaml" <<YAML
id: $STALE_BRIEF_UUID
task_id: 019de9f1-ffff-7000-8000-000000000336
legacy_task_id: "T336"
type: bugfix
size: l
state: ready
acceptance: ["This stale brief must never win."]
YAML

cat > "$PROJECT_ROOT/plans/chanakya-tasks/T336-impl.md" <<'MD'
# Legacy T336 brief

Size: L
Type: bugfix

This markdown must never be returned as BRIEF_PATH.
MD

CLAUDE_ROOT="$TMPROOT/claude-skills"
CODEX_ROOT="$TMPROOT/codex-skills"
mkdir -p "$CLAUDE_ROOT/scripts" "$CODEX_ROOT/scripts"
ln -s "$ROOT/scripts/task-load-spec.sh" "$CLAUDE_ROOT/scripts/task-load-spec.sh"
ln -s "$ROOT/scripts/lib-paths.sh" "$CLAUDE_ROOT/scripts/lib-paths.sh"
ln -s "$ROOT/scripts/lib-ledger.sh" "$CLAUDE_ROOT/scripts/lib-ledger.sh"
ln -s "$ROOT/scripts/task-load-spec.sh" "$CODEX_ROOT/scripts/task-load-spec.sh"
ln -s "$ROOT/scripts/lib-paths.sh" "$CODEX_ROOT/scripts/lib-paths.sh"
ln -s "$ROOT/scripts/lib-ledger.sh" "$CODEX_ROOT/scripts/lib-ledger.sh"

claude_out="$TMPROOT/claude.out"
codex_out="$TMPROOT/codex.out"
HOME="$HOME_ROOT" ACHILLES_PROJECT="$PROJECT" bash "$CLAUDE_ROOT/scripts/task-load-spec.sh" T336 >"$claude_out" 2>"$claude_out.err"
claude_rc=$?
HOME="$HOME_ROOT" ACHILLES_PROJECT="$PROJECT" bash "$CODEX_ROOT/scripts/task-load-spec.sh" T336 >"$codex_out" 2>"$codex_out.err"
codex_rc=$?

assert "claude layout resolves canonical brief" "[ $claude_rc -eq 0 ]"
assert "codex layout resolves canonical brief" "[ $codex_rc -eq 0 ]"
assert "layouts produce identical spec" "cmp -s '$claude_out' '$codex_out'"
assert "canonical brief wins over stale legacy-id brief" "grep -q '^BRIEF_UUID=$BRIEF_UUID$' '$claude_out'"
assert "legacy markdown is not returned" "! grep -q 'chanakya-tasks' '$claude_out'"

mv "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml" "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml.missing"
missing_out="$TMPROOT/missing.out"
HOME="$HOME_ROOT" ACHILLES_PROJECT="$PROJECT" bash "$CLAUDE_ROOT/scripts/task-load-spec.sh" T336 >"$missing_out" 2>"$missing_out.err"
missing_rc=$?
assert "missing linked YAML fails before dispatch" "[ $missing_rc -eq 2 ]"
assert "missing linked YAML names canonical link failure" "grep -q 'links brief' '$missing_out.err'"
assert "legacy markdown is diagnostic-only" "grep -q 'diagnostic-only' '$missing_out.err'"
assert "diagnostic event is measurable" "grep -q 'legacy_artifact_read' '$PROJECT_ROOT/events/'*.jsonl"
mv "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml.missing" "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml"

yq -i ".task_id = \"$STALE_BRIEF_UUID\"" "$PROJECT_ROOT/plans/briefs/$BRIEF_UUID.yaml"
parity_out="$TMPROOT/parity.out"
HOME="$HOME_ROOT" ACHILLES_PROJECT="$PROJECT" bash "$CODEX_ROOT/scripts/task-load-spec.sh" T336 >"$parity_out" 2>"$parity_out.err"
parity_rc=$?
assert "task/brief mismatch fails before dispatch" "[ $parity_rc -eq 2 ]"
assert "task/brief mismatch reports parity" "grep -q 'task/brief parity failed' '$parity_out.err'"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
