#!/usr/bin/env bash
# Verifies bare chain-runner invocation discovers resumable runs and runnable manifests.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-discover.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

HOME_DIR="$TMPROOT/home"
RUN_ROOT="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"
mkdir -p "$RUN_ROOT/run-discovery-1"

cat > "$RUN_ROOT/run-discovery-1/state.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-discovery-1",
  "manifest": "chains/workflow-measurement-improvements.yaml",
  "status": "paused",
  "started_at": "2026-05-03T00:00:00Z",
  "updated_at": "2026-05-03T00:01:00Z",
  "report": "/tmp/report-discovery.md",
  "halt_records": []
}
JSON

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/out" 2>&1

grep -q '^# Studio Chain Discovery$' "$TMPROOT/out" || {
  printf 'missing discovery heading\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'run-discovery-1' "$TMPROOT/out" || {
  printf 'missing resumable run row\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'scripts/studio-chain-runner.sh --resume run-discovery-1 --yes' "$TMPROOT/out" || {
  printf 'missing resume suggestion\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'chains/workflow-measurement-improvements.yaml' "$TMPROOT/out" || {
  printf 'missing runnable manifest row\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'scripts/studio-chain-runner.sh chains/workflow-measurement-improvements.yaml --only field-telemetry-mvp --dry-run' "$TMPROOT/out" || {
  printf 'missing runnable chain suggestion\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

printf 'PASS: chain-runner discovery mode\n'
