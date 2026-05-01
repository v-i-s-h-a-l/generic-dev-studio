#!/usr/bin/env bash
# Verifies analyze-collect reports brief-write to task-dispatch latency and
# distinguishes dispatched briefs from still-pending authored briefs.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t analyze-collect.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
# shellcheck source=../../../lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"

project_root=$(resolve_project_root_for demo)
events_dir="$project_root/events"
memory_dir="$HOME/.claude/projects/-tmp-demo/memory"
mkdir -p "$events_dir" "$memory_dir"

cat > "$events_dir/2026-04-29.jsonl" <<'JSONL'
{"ts":"2026-04-29T10:00:00Z","agent":"chanakya","event":"brief_written","task":"T001","data":{"task_id":"task-001"}}
{"ts":"2026-04-29T10:15:00Z","agent":"chanakya","event":"task_dispatched","task":"task-001","data":{"worker":"worker-1"}}
{"ts":"2026-04-29T11:00:00Z","agent":"chanakya","event":"brief_state_changed","task":"brief-002","data":{"task_id":"task-002","to":"ready"}}
{"ts":"2026-04-29T11:30:00Z","agent":"chanakya","event":"task_dispatched","task":"task-002","data":{"worker":"worker-2"}}
{"ts":"2026-04-29T12:00:00Z","agent":"chanakya","event":"brief_written","task":"T003","data":{"task_id":"task-003"}}
{"ts":"2026-04-29T12:30:00Z","agent":"chanakya","event":"task_dispatched","task":"task-999","data":{"worker":"worker-3"}}
JSONL

out="$TMPROOT/out"
"$ROOT/scripts/analyze-collect.sh" --project demo --since 2026-04-29 > "$out"

grep -q 'Brief → dispatch latency' "$out" || {
  printf 'missing brief dispatch latency section\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'source: brief_written/brief_state_changed → task_dispatched (joined by task_id)' "$out" || {
  printf 'missing source line\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^written: 3$' "$out" || {
  printf 'written count mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^dispatched: 2$' "$out" || {
  printf 'dispatched count mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^pending: 1$' "$out" || {
  printf 'pending count mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^latency_s: samples=2 avg=1350 p50=900 p90=1800 max=1800$' "$out" || {
  printf 'latency distribution mismatch\n' >&2
  cat "$out" >&2
  exit 1
}

printf 'PASS: analyze-collect brief dispatch latency\n'
