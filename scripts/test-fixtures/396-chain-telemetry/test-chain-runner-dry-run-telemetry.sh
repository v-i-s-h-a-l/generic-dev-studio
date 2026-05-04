#!/usr/bin/env bash
# Verifies chain-runner dry-run includes UUID telemetry and worker-summary instructions
# without writing private chain-run artifacts.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-telemetry.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "number": 396,
  "title": "Studio chain telemetry",
  "body": "Add chain telemetry.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/396",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: telemetry-fixture
    base: main
    branch: feature/telemetry-fixture
    host: codex
    checkpoint: auto
    issues: [396]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

grep -q 'Run UUID:' "$TMPROOT/out" || {
  printf 'missing run UUID in worker prompt\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'Chain-run UUID:' "$TMPROOT/out" || {
  printf 'missing chain-run UUID in worker prompt\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'Issue-run UUID:' "$TMPROOT/out" || {
  printf 'missing issue-run UUID in worker prompt\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q '.studio/chain-worker-summary.json' "$TMPROOT/out" || {
  printf 'missing worker summary artifact path\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'DRY-RUN scripts/pr-headless-review.sh <pr> --method auto' "$TMPROOT/out" || {
  printf 'missing dry-run review gate line\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'Checkpoint automation: `auto`' "$TMPROOT/out" || {
  printf 'missing checkpoint automation plan line\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'DRY-RUN scripts/studio-checkpoint.sh resume --project generic-dev-studio --role manager --branch feature/telemetry-fixture --latest' "$TMPROOT/out" || {
  printf 'missing checkpoint resume dry-run shape\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}
grep -q 'DRY-RUN cd .*scripts/studio-checkpoint.sh create --project generic-dev-studio --role manager --mode chain-auto --branch feature/telemetry-fixture' "$TMPROOT/out" || {
  printf 'missing checkpoint create dry-run shape\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

if [ -e "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs" ]; then
  printf 'dry-run wrote private chain-run artifacts\n' >&2
  find "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs" -maxdepth 3 -type f >&2
  exit 1
fi

printf 'PASS: chain-runner dry-run telemetry\n'
