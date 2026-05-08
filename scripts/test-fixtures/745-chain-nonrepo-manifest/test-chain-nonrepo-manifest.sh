#!/usr/bin/env bash
# Verifies chain-runner accepts manifests stored outside any git checkout.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CANON_ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)
TMPROOT=$(mktemp -d -t chain-nonrepo-manifest.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR" "$TMPROOT/nonrepo"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "number": 745,
  "title": "Non-repo manifest fixture",
  "body": "Keep temp chain manifests working.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/745",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/nonrepo/chain.yaml"
cat > "$manifest" <<YAML
schema_version: 1
target_repo_root: $CANON_ROOT
chains:
  - name: nonrepo-manifest-fixture
    base: main
    branch: feature/nonrepo-manifest-fixture
    host: codex
    issues: [745]
YAML

if git -C "$(dirname "$manifest")" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "fixture manifest directory unexpectedly lives inside a git checkout"
fi

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

grep -q "Target repo root: \`$CANON_ROOT\`" "$TMPROOT/out" || {
  cat "$TMPROOT/out" >&2
  fail "plan did not report the manifest-selected target repo root"
}

grep -q "DRY-RUN HOME=.* scripts/host-preflight.sh codex $CANON_ROOT" "$TMPROOT/out" || {
  cat "$TMPROOT/out" >&2
  fail "host preflight did not use the target repo root"
}

grep -q "DRY-RUN retry\\[network_partition\\].* git -C $CANON_ROOT fetch origin --prune" "$TMPROOT/out" || {
  cat "$TMPROOT/out" >&2
  fail "fetch did not use the target repo root"
}

fallback_manifest="$TMPROOT/nonrepo/fallback-chain.yaml"
cat > "$fallback_manifest" <<'YAML'
schema_version: 1
chains:
  - name: fallback-root-fixture
    base: main
    branch: feature/fallback-root-fixture
    host: codex
    issues: [745]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$fallback_manifest" --dry-run > "$TMPROOT/fallback.out" 2>&1
grep -q "Target repo root: \`$CANON_ROOT\`" "$TMPROOT/fallback.out" || {
  cat "$TMPROOT/fallback.out" >&2
  fail "non-repo manifest without a target did not fall back to the studio repo root"
}

if grep -q 'not a git repository' "$TMPROOT/out"; then
  cat "$TMPROOT/out" >&2
  fail "non-repo manifest directory leaked into git root resolution"
fi

bad_manifest="$TMPROOT/nonrepo/bad-chain.yaml"
cat > "$bad_manifest" <<YAML
schema_version: 1
target_repo_root: $TMPROOT/missing-repo
chains:
  - name: bad-root-fixture
    base: main
    branch: feature/bad-root-fixture
    host: codex
    issues: [745]
YAML

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$bad_manifest" --dry-run > "$TMPROOT/bad.out" 2>&1; then
  cat "$TMPROOT/bad.out" >&2
  fail "missing explicit target repo root unexpectedly passed"
fi

grep -q 'target repo root does not exist' "$TMPROOT/bad.out" || {
  cat "$TMPROOT/bad.out" >&2
  fail "missing explicit target repo root did not produce an actionable error"
}

printf 'PASS: chain-runner non-repo manifest\n'
