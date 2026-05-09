#!/usr/bin/env bash
# Verifies host eligibility smoke triage without touching real host auth.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMPROOT=$(mktemp -d -t lib-host-eligibility.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

LIB="$ROOT/scripts/lib-host-eligibility.sh"
PROFILE="$TMPROOT/host-profiles.yaml"
BIN="$TMPROOT/bin"
AUTH_HOME="$TMPROOT/auth-home"
GITHUB_HOME="$TMPROOT/github-home"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_jq() {
  local label="$1" json="$2" jq_expr="$3"
  printf '%s\n' "$json" | jq -e "$jq_expr" >/dev/null || fail "$label"
}

command -v yq >/dev/null 2>&1 || {
  printf 'SKIP: yq required for lib-host-eligibility tests\n' >&2
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  printf 'SKIP: jq required for lib-host-eligibility tests\n' >&2
  exit 0
}

mkdir -p "$BIN" "$AUTH_HOME" "$GITHUB_HOME"

cat > "$BIN/fake-host" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ok)
    [ "${HOME:-}" = "${STUDIO_CONTEXT_AUTH_HOME:-}" ] || {
      printf 'HOME did not use auth home\n' >&2
      exit 31
    }
    [ "${STUDIO_CONTEXT_AUTH_HOME:-}" = "${TEST_AUTH_HOME:-}" ] || {
      printf 'STUDIO_CONTEXT_AUTH_HOME mismatch\n' >&2
      exit 32
    }
    [ "${STUDIO_CONTEXT_GITHUB_HOME:-}" = "${TEST_EXPECTED_GITHUB_HOME:-}" ] || {
      printf 'STUDIO_CONTEXT_GITHUB_HOME mismatch\n' >&2
      exit 33
    }
    printf 'ok\n'
    ;;
  expired)
    printf 'token expired; run login again\n' >&2
    exit 41
    ;;
  fail)
    printf 'SDK handshake failed\n' >&2
    exit 42
    ;;
  *)
    printf 'unknown fake-host mode: %s\n' "${1:-}" >&2
    exit 43
    ;;
esac
SH
chmod +x "$BIN/fake-host"

PATH="$BIN:$PATH"
export PATH
export TEST_AUTH_HOME="$AUTH_HOME"
export TEST_EXPECTED_GITHUB_HOME="$GITHUB_HOME"
unset TEST_GITHUB_HOME || true

cat > "$PROFILE" <<YAML
schema_version: 1
kind: host-profiles
default_order:
  - eligible
  - missing-binary
  - missing-auth
  - expired-auth
  - smoke-failed
profiles:
  eligible:
    host_id: eligible
    binary_path: fake-host
    auth_home: "\${env.TEST_AUTH_HOME_OVERRIDE:-\${env.TEST_AUTH_HOME}}"
    github_home: "\${env.TEST_GITHUB_HOME:-$GITHUB_HOME}"
    capabilities:
      - worker
    synthetic_home_behavior: fixture
    eligibility_smoke_command: "fake-host ok"
  missing-binary:
    host_id: missing-binary
    binary_path: missing-host-binary
    auth_home: "\${env.TEST_AUTH_HOME}"
    github_home: "$GITHUB_HOME"
    capabilities:
      - worker
    synthetic_home_behavior: fixture
    eligibility_smoke_command: "missing-host-binary ok"
  missing-auth:
    host_id: missing-auth
    binary_path: fake-host
    auth_home: "$TMPROOT/missing-auth-home"
    github_home: "$GITHUB_HOME"
    capabilities:
      - worker
    synthetic_home_behavior: fixture
    eligibility_smoke_command: "fake-host ok"
  expired-auth:
    host_id: expired-auth
    binary_path: fake-host
    auth_home: "$AUTH_HOME"
    github_home: "$GITHUB_HOME"
    capabilities:
      - worker
    synthetic_home_behavior: fixture
    eligibility_smoke_command: "fake-host expired"
  smoke-failed:
    host_id: smoke-failed
    binary_path: fake-host
    auth_home: "$AUTH_HOME"
    github_home: "$GITHUB_HOME"
    capabilities:
      - worker
    synthetic_home_behavior: fixture
    eligibility_smoke_command: "fake-host fail"
YAML

import_out="$TMPROOT/import.out"
import_err="$TMPROOT/import.err"
bash -c ". '$LIB'" >"$import_out" 2>"$import_err" || fail "library import failed"
[ ! -s "$import_out" ] || fail "library import wrote to stdout"
[ ! -s "$import_err" ] || fail "library import wrote to stderr"

# shellcheck source=../../scripts/lib-host-eligibility.sh disable=SC1091
. "$LIB"

host_profile_load_file "$PROFILE" >/dev/null || fail "fixture profile did not load"

eligible_json=$(host_eligibility_check eligible)
assert_eq "eligible outcome" "eligible" "$(printf '%s\n' "$eligible_json" | jq -r '.outcome')"
assert_jq "eligible record shape" "$eligible_json" '
  .host_id == "eligible"
  and .detail == "smoke command completed successfully"
  and .smoke_command == "fake-host ok"
  and (.duration_ms | type == "number")
'

binary_json=$(host_eligibility_check missing-binary)
assert_eq "missing binary outcome" "binary-missing" "$(printf '%s\n' "$binary_json" | jq -r '.outcome')"
assert_jq "missing binary detail" "$binary_json" '.detail | test("missing-host-binary")'

missing_auth_json=$(host_eligibility_check missing-auth)
assert_eq "missing auth outcome" "auth-stale" "$(printf '%s\n' "$missing_auth_json" | jq -r '.outcome')"
assert_jq "missing auth detail" "$missing_auth_json" '.detail | test("auth home is missing")'

expired_json=$(host_eligibility_check expired-auth)
assert_eq "expired auth outcome" "auth-stale" "$(printf '%s\n' "$expired_json" | jq -r '.outcome')"
assert_jq "expired auth detail" "$expired_json" '.detail | test("stale authentication") and test("token expired")'

failed_json=$(host_eligibility_check smoke-failed)
assert_eq "fresh auth failure outcome" "auth-fresh-but-failed" "$(printf '%s\n' "$failed_json" | jq -r '.outcome')"
assert_jq "fresh failure detail" "$failed_json" '.detail | test("exited 42") and test("SDK handshake failed")'

check_out="$TMPROOT/check.out"
check_err="$TMPROOT/check.err"
host_eligibility_check smoke-failed >"$check_out" 2>"$check_err" || fail "classified smoke failure returned non-zero"
[ ! -s "$check_err" ] || fail "classified smoke failure leaked human output to stderr"
assert_jq "stdout is a single structured record" "$(cat "$check_out")" '.outcome == "auth-fresh-but-failed"'

printf 'PASS: lib-host-eligibility\n'
