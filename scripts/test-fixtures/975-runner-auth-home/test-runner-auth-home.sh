#!/usr/bin/env bash
# Verifies chain runner home selection separates GitHub and Codex auth homes.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t runner-auth-home-975.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

BIN="$TMPROOT/bin"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/personal"
CODEX_AUTH="$SYNTH_HOME/.codex"
RUN_ID="019e334f-9750-7000-8000-000000000001"
mkdir -p "$BIN" "$LOGIN_HOME" "$SYNTH_HOME" "$CODEX_AUTH"

cat > "$BIN/dscl" <<SH
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$LOGIN_HOME"
SH
chmod +x "$BIN/dscl"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$HOME" >> "${GH_HOME_LOG:?}"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "number": 975,
  "title": "runner auth home fixture",
  "body": "Fixture issue body.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/975",
  "state": "OPEN"
}
JSON
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

GH_HOME_LOG="$TMPROOT/gh-home.log"
export GH_HOME_LOG

CHAIN_ROOT="$LOGIN_HOME/.dev-studio/generic-dev-studio/chain-runs/$RUN_ID"
mkdir -p "$CHAIN_ROOT"
cat > "$CHAIN_ROOT/state.json" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "manifest": "fixture-composite.yaml",
  "status": "halted",
  "started_at": "2026-05-17T00:00:00Z",
  "updated_at": "2026-05-17T00:01:00Z",
  "report": "$CHAIN_ROOT/report.md",
  "chains": [
    {
      "name": "fixture-composite",
      "kind": "composite",
      "chain_run_id": "chain-975",
      "status": "halted",
      "issues": []
    }
  ]
}
JSON

PATH="$BIN:$PATH" HOME="$LOGIN_HOME" "$ROOT/scripts/studio-chain-runner.sh" --list > "$TMPROOT/list-login.out"
grep -q "$RUN_ID" "$TMPROOT/list-login.out" || fail "login HOME could not discover durable chain state"

PATH="$BIN:$PATH" HOME="$SYNTH_HOME" "$ROOT/scripts/studio-chain-runner.sh" --list > "$TMPROOT/list-synth.out"
grep -q "$RUN_ID" "$TMPROOT/list-synth.out" || fail "synthetic Codex HOME could not discover durable chain state"

manifest="$TMPROOT/chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: runner-auth-home
    source_branch: main
    branch: feature/runner-auth-home
    host: codex
    issues: [975]
YAML

: > "$GH_HOME_LOG"
env -u CODEX_HOME -u CODEX_WORKER_HOME \
  PATH="$BIN:$PATH" HOME="$SYNTH_HOME" \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/dry-run.out" 2>&1

grep -qx "$LOGIN_HOME" "$GH_HOME_LOG" || {
  printf 'gh HOME log:\n' >&2
  cat "$GH_HOME_LOG" >&2
  fail "GitHub issue lookup did not use normalized login HOME"
}
grep -q "HOME=$CODEX_AUTH" "$TMPROOT/dry-run.out" || {
  cat "$TMPROOT/dry-run.out" >&2
  fail "dry-run worker launch did not use Codex auth home as HOME"
}
grep -q "CODEX_HOME=$CODEX_AUTH" "$TMPROOT/dry-run.out" || {
  cat "$TMPROOT/dry-run.out" >&2
  fail "dry-run worker launch did not export CODEX_HOME"
}
grep -q "STUDIO_CONTEXT_GITHUB_HOME=$LOGIN_HOME" "$TMPROOT/dry-run.out" || {
  cat "$TMPROOT/dry-run.out" >&2
  fail "dry-run worker launch did not export normalized github_home"
}

rm -rf "$CODEX_AUTH"
missing_json="$TMPROOT/missing-context.json"
missing_err="$TMPROOT/missing-context.err"
if env -u CODEX_HOME -u CODEX_WORKER_HOME \
    PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
    bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
    >"$missing_json" 2>"$missing_err"; then
  fail "missing Codex auth home unexpectedly resolved"
fi
grep -q 'auth_home is not a directory for delegated-host-spawn' "$missing_err" \
  || fail "missing Codex auth home did not produce typed auth_home failure"
if grep -q -E 'gho_|ghp_|Authorization:|Bearer ' "$missing_err"; then
  fail "auth-home diagnostic exposed secret-looking output"
fi

grep -q 'write_prelaunch_auth_failure_summary' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner does not write a typed prelaunch auth failure summary"
grep -q 'codex_auth_home unavailable before child execution' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner prelaunch auth failure is not actionable for codex_auth_home"
grep -q 'return 70' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner does not stop before child execution on auth-home failure"

printf 'PASS: runner auth home selection\n'
