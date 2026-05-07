#!/usr/bin/env bash
# Verifies Codex worker capabilities are materialized by the effective spawn.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t codex-worker-spawn.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

WORKER_CAPS="$ROOT/.codex/capabilities.yaml"
REVIEWER_CAPS="$ROOT/.codex-reviewer/capabilities.yaml"
WORKER_WRAPPER="$ROOT/scripts/codex-worker-exec.sh"

grep -q 'spawn_command: "scripts/codex-worker-exec.sh"' "$WORKER_CAPS" \
  || fail "Codex worker manifest does not use the wrapper"
grep -q -- '--sandbox workspace-write' "$WORKER_WRAPPER" \
  || fail "Codex worker wrapper does not materialize workspace-write"
grep -q -- '--ephemeral' "$WORKER_WRAPPER" \
  || fail "Codex worker wrapper does not disable session persistence"
grep -q -- 'approval_policy=never' "$WORKER_WRAPPER" \
  || fail "Codex worker wrapper does not force noninteractive approval"
grep -q -- '--add-dir "$dev_studio_root"' "$WORKER_WRAPPER" \
  || fail "Codex worker wrapper does not add the resolved runtime writable root"
grep -q -- 'CODEX_HOME="$codex_home"' "$WORKER_WRAPPER" \
  || fail "Codex worker wrapper does not export an explicit Codex auth home"
if grep -Eq -- 'dangerously-bypass-approvals-and-sandbox|dangerously-skip-permissions' "$WORKER_WRAPPER"; then
  fail "Codex worker wrapper uses a dangerous sandbox bypass"
fi

grep -q -- '--sandbox read-only' "$REVIEWER_CAPS" \
  || fail "Codex reviewer profile is not read-only"
grep -q -- '--ephemeral' "$REVIEWER_CAPS" \
  || fail "Codex reviewer profile does not disable session persistence"
grep -q -- 'approval_policy=never' "$REVIEWER_CAPS" \
  || fail "Codex reviewer profile does not force noninteractive approval"
grep -q '^secret_scope: none$' "$REVIEWER_CAPS" \
  || fail "Codex reviewer profile is not no-secret"

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR/.codex"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Codex worker spawn fixture $issue",
  "body": "Exercise effective Codex worker spawn.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
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
  - name: codex-worker-spawn-fixture
    base: main
    branch: feature/codex-worker-spawn-fixture
    host: codex
    issues: [576]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

grep -q 'Git metadata strategy: `local-clone`' "$TMPROOT/out" \
  || fail "dry-run plan did not keep Codex on local-clone git metadata"
grep -q 'scripts/codex-worker-exec.sh' "$TMPROOT/out" \
  || fail "dry-run did not use the effective Codex worker wrapper"
grep -q "CODEX_HOME=$HOME_DIR/.codex" "$TMPROOT/out" \
  || fail "dry-run did not pass the caller Codex auth home to the worker"
if grep -q 'codex exec .*Implement this studio issue' "$TMPROOT/out"; then
  fail "dry-run still used plain codex exec for Codex worker"
fi

FAKE_CODEX_LOG="$TMPROOT/fake-codex.log"
cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}" > "$FAKE_CODEX_LOG"
printf 'ARGS=%s\n' "$*" >> "$FAKE_CODEX_LOG"
SH
chmod +x "$BIN/codex"

AUTH_HOME="$TMPROOT/synthetic-codex-home"
mkdir -p "$AUTH_HOME"
PATH="$BIN:$PATH" \
  HOME="$TMPROOT/login-home" \
  CODEX_WORKER_HOME="$AUTH_HOME" \
  FAKE_CODEX_LOG="$FAKE_CODEX_LOG" \
  "$WORKER_WRAPPER" "fixture prompt"

grep -qx "CODEX_HOME=$AUTH_HOME" "$FAKE_CODEX_LOG" \
  || fail "worker wrapper did not preserve explicit Codex auth home"
grep -q -- '--sandbox workspace-write' "$FAKE_CODEX_LOG" \
  || fail "worker wrapper did not invoke codex exec with workspace-write"

SYNTH_HOME="$TMPROOT/synthetic-home"
mkdir -p "$SYNTH_HOME/.codex"
PATH="$BIN:$PATH" \
  HOME="$SYNTH_HOME" \
  FAKE_CODEX_LOG="$FAKE_CODEX_LOG" \
  env -u CODEX_WORKER_HOME -u CODEX_HOME \
  "$WORKER_WRAPPER" "fixture prompt"

grep -qx "CODEX_HOME=$SYNTH_HOME/.codex" "$FAKE_CODEX_LOG" \
  || fail "worker wrapper did not infer Codex auth from synthetic HOME"

bash "$ROOT/scripts/lint-host-agnostic.sh" >/tmp/codex-worker-spawn-lint.out 2>/tmp/codex-worker-spawn-lint.err \
  || {
    cat /tmp/codex-worker-spawn-lint.out >&2
    cat /tmp/codex-worker-spawn-lint.err >&2
    fail "host-agnostic lint rejected effective Codex worker capability"
  }

printf 'PASS: codex worker effective spawn\n'
