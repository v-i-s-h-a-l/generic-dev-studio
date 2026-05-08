#!/usr/bin/env bash
# Verifies bare chain-runner invocation discovers resumable runs and runnable manifests.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-discover.XXXXXX)
SELECTOR_MANIFEST="$ROOT/chains/zz-698-discovery-selector-fixture.yaml"
trap 'rm -rf "$TMPROOT"; rm -f "$SELECTOR_MANIFEST"' EXIT

HOME_DIR="$TMPROOT/home"
RUN_ROOT="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"
mkdir -p "$RUN_ROOT/run-discovery-1"

cat > "$SELECTOR_MANIFEST" <<'YAML'
schema_version: 1
chains:
  - id: live-chain-id
    name: live-selector
    status: queued
    base: main
    branch: feature/live-selector
    issues: [698]
  - id: completed-chain-id
    name: completed-selector
    status: completed
    base: main
    branch: feature/completed-selector
    issues: [699]
  - id: archived-chain-id
    name: archived-selector
    status: archived
    base: main
    branch: feature/archived-selector
    issues: [700]
YAML

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
grep -q '/dev-studio manager work-chain --resume run-discovery-1 --yes' "$TMPROOT/out" || {
  printf 'missing resume suggestion\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'chains/workflow-measurement-improvements.yaml' "$TMPROOT/out" || {
  printf 'missing runnable manifest row\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q '/dev-studio manager work-chain ios-v2-execution --dry-run' "$TMPROOT/out" || {
  printf 'missing runnable chain suggestion\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q '663,664,665,666,667,668,669,670,671' "$TMPROOT/out" || {
  printf 'object-form issue entries did not render numbers\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'live-chain-id' "$TMPROOT/out" || {
  printf 'discovery did not render chain ids\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
if grep -q '/dev-studio manager work-chain completed-chain-id --dry-run' "$TMPROOT/out"; then
  printf 'default discovery included completed chain\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
fi
if grep -q '/dev-studio manager work-chain archived-chain-id --dry-run' "$TMPROOT/out"; then
  printf 'default discovery included archived chain\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
fi
grep -q 'Attended run: `/dev-studio manager work-chain <manifest|chain-name|chain-id> --attended --yes`' "$TMPROOT/out" || {
  printf 'missing attended command contract\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --discover ios-v2-execution > "$TMPROOT/filtered.out" 2>&1
grep -q 'ios-v2-execution' "$TMPROOT/filtered.out" || {
  printf 'filtered discovery omitted named chain\n' >&2
  cat "$TMPROOT/filtered.out" >&2
  exit 1
}
if grep -q '/dev-studio manager work-chain automation-mode-preference --dry-run' "$TMPROOT/filtered.out"; then
  printf 'filtered discovery included unrelated runnable chain\n' >&2
  cat "$TMPROOT/filtered.out" >&2
  exit 1
fi

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --discover live-selector > "$TMPROOT/filtered-chain-name.out" 2>&1
grep -q 'live-selector' "$TMPROOT/filtered-chain-name.out" || {
  printf 'chain-name discovery omitted exact chain\n' >&2
  cat "$TMPROOT/filtered-chain-name.out" >&2
  exit 1
}
if grep -q 'completed-selector' "$TMPROOT/filtered-chain-name.out"; then
  printf 'chain-name discovery included unrelated chain\n' >&2
  cat "$TMPROOT/filtered-chain-name.out" >&2
  exit 1
fi

HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --discover completed-chain-id > "$TMPROOT/filtered-chain-id.out" 2>&1
grep -q 'completed-selector' "$TMPROOT/filtered-chain-id.out" || {
  printf 'chain-id discovery omitted exact completed chain\n' >&2
  cat "$TMPROOT/filtered-chain-id.out" >&2
  exit 1
}
grep -q 'completed-chain-id' "$TMPROOT/filtered-chain-id.out" || {
  printf 'chain-id discovery did not render exact chain id\n' >&2
  cat "$TMPROOT/filtered-chain-id.out" >&2
  exit 1
}

printf 'PASS: chain-runner discovery mode\n'
