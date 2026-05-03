#!/usr/bin/env bash
# Verifies --list reports persisted chain runs without requiring a manifest.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-list.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

HOME_DIR="$TMPROOT/home"
RUN_ROOT="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"
mkdir -p "$RUN_ROOT/run-a" "$RUN_ROOT/run-b"

cat > "$RUN_ROOT/run-a/state.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-a",
  "manifest": "chains/a.yaml",
  "status": "planned",
  "started_at": "2026-05-03T00:00:00Z",
  "updated_at": "2026-05-03T00:01:00Z",
  "report": "/tmp/report-a.md"
}
JSON

cat > "$RUN_ROOT/run-b/state.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-b",
  "manifest": "chains/b.yaml",
  "status": "failed",
  "started_at": "2026-05-03T00:02:00Z",
  "updated_at": "2026-05-03T00:03:00Z",
  "report": "/tmp/report-b.md"
}
JSON

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --list > "$TMPROOT/out" 2>&1

grep -q '# Studio Chain Runs' "$TMPROOT/out" || {
  printf 'missing list heading\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q '| run-a | chains/a.yaml | planned | 2026-05-03T00:00:00Z | 2026-05-03T00:01:00Z | /tmp/report-a.md |' "$TMPROOT/out" || {
  printf 'missing run-a row\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q '| run-b | chains/b.yaml | failed | 2026-05-03T00:02:00Z | 2026-05-03T00:03:00Z | /tmp/report-b.md |' "$TMPROOT/out" || {
  printf 'missing run-b row\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
if grep -q 'yq required\|gh required\|manifest' "$TMPROOT/out"; then
  printf '--list should not require manifest resolution, yq, or gh\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
fi

printf 'PASS: chain-runner list persisted runs\n'
