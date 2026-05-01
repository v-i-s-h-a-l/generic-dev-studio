#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/brief-summary.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export ACHILLES_PROJECT="brief-summary-project"

PROJECT_ROOT="$HOME/.dev-studio/$ACHILLES_PROJECT"
TASK_ID="0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11"
BRIEF_ID="0190f52a-6e11-7c01-8a77-11a05a9e2b4c"
SUMMARY="Adopt OS_LOG categories for the photo-editor pipeline. Replaces ad-hoc print(). Don't change log formatting at call sites -- only routing."

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq required"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

mkdir -p "$PROJECT_ROOT/plans/tasks" "$PROJECT_ROOT/plans/briefs" "$PROJECT_ROOT/events"

cat > "$PROJECT_ROOT/plans/tasks/$TASK_ID.yaml" <<YAML
schema_version: {name: task, version: 1.1.0, min_reader: 1.0.0, deprecated_at: null}
id: $TASK_ID
legacy_task_id: "T256"
title: Brief summary cheap-read slice
state: briefed
type: feature
size: s
priority: p1
effort_minutes: 30
recommended_model: sonnet
train: brief-shape
predecessors: []
links: {brief: $BRIEF_ID}
created_at: 2026-05-01T00:00:00Z
updated_at: 2026-05-01T00:00:00Z
YAML

cat > "$PROJECT_ROOT/plans/briefs/$BRIEF_ID.yaml" <<YAML
schema_version: {name: brief, version: 3.8.0, min_reader: 3.0.0, deprecated_at: null}
id: $BRIEF_ID
task_id: $TASK_ID
legacy_task_id: "T256"
type: impl
size: s
state: ready
created_at: 2026-05-01T00:00:00Z
updated_at: 2026-05-01T00:00:00Z
figma: null
reads: []
writes: []
acceptance: ["Routes existing print calls through OS_LOG categories."]
testability: []
rework_of: null
summary: "$SUMMARY"
body: |
  ## Objective
  Route photo-editor logging through OS_LOG categories.
YAML

"$ROOT/scripts/lint-brief.sh" "$PROJECT_ROOT/plans/briefs/$BRIEF_ID.yaml" >/dev/null

long_brief="$TMP/long.yaml"
{
  sed '/^summary:/,$d' "$PROJECT_ROOT/plans/briefs/$BRIEF_ID.yaml"
  printf 'summary: "'
  awk 'BEGIN { for (i=0; i<390; i++) printf "word " }'
  printf '"\nbody: |\n  ## Objective\n  Too long.\n'
} > "$long_brief"
if "$ROOT/scripts/lint-brief.sh" "$long_brief" >"$TMP/long.out" 2>&1; then
  echo "FAIL: long summary lint passed unexpectedly" >&2
  exit 1
fi
grep -q 'E_SUMMARY_TOO_LONG' "$TMP/long.out"

"$ROOT/scripts/chanakya-snap.sh" briefs >/dev/null
"$ROOT/scripts/status-render-tasks.sh" < "$PROJECT_ROOT/.runtime/state/chanakya-snapshots/briefs.json" > "$TMP/status.md"
grep -q 'Brief summary cheap-read slice' "$TMP/status.md"
grep -q 'Adopt OS_LOG categories for the photo-editor pipeline' "$TMP/status.md"

"$ROOT/scripts/query-tasks.sh" --dispatch-ready --format=json > "$TMP/dispatch.json"
jq -e --arg summary "$SUMMARY" '.[0].brief_summary == $summary' "$TMP/dispatch.json" >/dev/null

BRIEF_SLICE=summary "$ROOT/scripts/task-load-spec.sh" T256 > "$TMP/spec.env"
grep -q '^BRIEF_SUMMARY=' "$TMP/spec.env"
grep -q '^BRIEF_SUMMARY_TOKENS=' "$TMP/spec.env"
grep -q 'brief_summary_used' "$PROJECT_ROOT/events/"*.jsonl

echo "PASS: brief summary slice"
