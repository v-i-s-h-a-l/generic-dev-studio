#!/usr/bin/env bash
# Verifies chain-runner worker-pool sizing follows healthy xcodebuild offload nodes
# and clamps to the available-RAM heuristic.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-pool.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR/.dev-studio/.runtime"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "number": 134,
  "title": "Achilles worker-pool scaling by offload availability",
  "body": "Scale worker pool from healthy xcodebuild nodes.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/134",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

cat > "$TMPROOT/node-health" <<'SH'
#!/usr/bin/env bash
case "$1" in
  mini-a|mini-b) printf '%s\thealthy\t0.10\t%s.local\n' "$1" "$1" ;;
  mini-stall) sleep 5; printf '%s\thealthy\t0.10\t%s.local\n' "$1" "$1" ;;
  *) printf '%s\tunreachable\t-\t-\n' "$1" ;;
esac
SH
chmod +x "$TMPROOT/node-health"

cat > "$BIN/ssh" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep 5
SH
chmod +x "$BIN/ssh"

cat > "$HOME_DIR/.dev-studio/.runtime/nodes.json" <<'JSON'
{
  "nodes": [
    {"id": "local", "roles": ["xcodebuild"], "enabled": true},
    {"id": "mini-a", "roles": ["xcodebuild"], "enabled": true},
    {"id": "mini-b", "roles": ["xcodebuild"], "enabled": true},
    {"id": "mini-swift", "roles": ["swift-test"], "enabled": true},
    {"id": "mini-disabled", "roles": ["xcodebuild"], "enabled": false}
  ]
}
JSON

manifest="$TMPROOT/chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: pool-fixture
    base: main
    branch: feature/pool-fixture
    host: codex
    issues: [134]
YAML

env -u STUDIO_CHAIN_WORKER_POOL \
  PATH="$BIN:$PATH" \
  HOME="$HOME_DIR" \
  STUDIO_CHAIN_NODE_HEALTH_CMD="$TMPROOT/node-health" \
  STUDIO_CHAIN_AVAILABLE_RAM_GIB=64 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

grep -q 'worker_pool=3' "$TMPROOT/out" || {
  printf 'expected two healthy offload nodes to yield worker_pool=3\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

env -u STUDIO_CHAIN_WORKER_POOL \
  PATH="$BIN:$PATH" \
  HOME="$HOME_DIR" \
  STUDIO_CHAIN_NODE_HEALTH_CMD="$TMPROOT/node-health" \
  STUDIO_CHAIN_AVAILABLE_RAM_GIB=12 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/capped" 2>&1

grep -q 'worker_pool=2' "$TMPROOT/capped" || {
  printf 'expected 12GiB at 6GiB/worker to cap worker_pool at 2\n' >&2
  cat "$TMPROOT/capped" >&2
  exit 1
}

cat > "$HOME_DIR/.dev-studio/.runtime/nodes.json" <<'JSON'
{
  "nodes": [
    {"id": "local", "roles": ["xcodebuild"], "enabled": true},
    {"id": "mini-stall", "host": "mini-stall.local", "user": "tester", "roles": ["xcodebuild"], "enabled": true}
  ]
}
JSON

env -u STUDIO_CHAIN_WORKER_POOL \
  PATH="$BIN:$PATH" \
  HOME="$HOME_DIR" \
  STUDIO_CHAIN_NODE_HEALTH_CMD="$TMPROOT/node-health" \
  STUDIO_CHAIN_NODE_HEALTH_TIMEOUT_S=1 \
  STUDIO_CHAIN_AVAILABLE_RAM_GIB=64 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/stalled" 2>&1

grep -q 'worker_pool=1' "$TMPROOT/stalled" || {
  printf 'expected stalled offload probe to fall back to local-only worker_pool=1\n' >&2
  cat "$TMPROOT/stalled" >&2
  exit 1
}

grep -q 'worker-pool node-health degraded: timed out probing mini-stall after 1s' "$TMPROOT/stalled" || {
  printf 'expected degraded worker-pool timeout context in dry-run output\n' >&2
  cat "$TMPROOT/stalled" >&2
  exit 1
}

started=$(date -u +%s)
set +e
PATH="$BIN:$PATH" \
  HOME="$HOME_DIR" \
  STUDIO_NODE_HEALTH_TIMEOUT_S=1 \
  "$ROOT/scripts/node-health.sh" mini-stall > "$TMPROOT/node-health-stalled" 2>&1
node_health_rc=$?
set -e
elapsed=$(( $(date -u +%s) - started ))

[ "$node_health_rc" -eq 1 ] || {
  printf 'expected node-health stalled SSH probe to exit 1, got %s\n' "$node_health_rc" >&2
  cat "$TMPROOT/node-health-stalled" >&2
  exit 1
}

grep -q $'mini-stall\tunreachable\t-\tmini-stall.local' "$TMPROOT/node-health-stalled" || {
  printf 'expected node-health to report stalled SSH probe as unreachable\n' >&2
  cat "$TMPROOT/node-health-stalled" >&2
  exit 1
}

[ "$elapsed" -lt 4 ] || {
  printf 'expected node-health timeout to finish promptly, elapsed=%ss\n' "$elapsed" >&2
  cat "$TMPROOT/node-health-stalled" >&2
  exit 1
}

printf 'PASS: chain-runner worker pool sizing\n'
