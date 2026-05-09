#!/usr/bin/env bash
# Verifies the host-profile resolver library reads declarative profiles without
# running host binaries.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMPROOT=$(mktemp -d -t lib-host-profiles.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

LIB="$ROOT/scripts/lib-host-profiles.sh"
DEFAULT_PROFILE="$ROOT/_shared/host-profiles/default.yaml"
CUSTOM_PROFILE="$ROOT/tests/lib-host-profiles/fixtures/custom.yaml"
MALFORMED_PROFILE="$ROOT/tests/lib-host-profiles/fixtures/malformed.yaml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_json_field() {
  local label="$1" file="$2" jq_expr="$3"
  jq -e "$jq_expr" "$file" >/dev/null || fail "$label"
}

command -v yq >/dev/null 2>&1 || {
  printf 'SKIP: yq required for lib-host-profiles tests\n' >&2
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  printf 'SKIP: jq required for lib-host-profiles tests\n' >&2
  exit 0
}

import_out="$TMPROOT/import.out"
import_err="$TMPROOT/import.err"
bash -c ". '$LIB'" >"$import_out" 2>"$import_err" || fail "library import failed"
[ ! -s "$import_out" ] || fail "library import wrote to stdout"
[ ! -s "$import_err" ] || fail "library import wrote to stderr"

# shellcheck source=../../scripts/lib-host-profiles.sh disable=SC1091
. "$LIB"

load_out="$TMPROOT/load.out"
host_profile_load_file "$DEFAULT_PROFILE" >"$load_out" || fail "default profile did not load"
[ ! -s "$load_out" ] || fail "host_profile_load_file wrote to stdout"
assert_eq "loaded file" "$DEFAULT_PROFILE" "$HOST_PROFILE_LOADED_FILE"

for host_id in claude codex; do
  profile_json="$TMPROOT/$host_id.json"
  host_profile_get "$host_id" >"$profile_json" || fail "host_profile_get failed for $host_id"
  assert_eq "$host_id field count" "7" "$(jq 'keys | length' "$profile_json")"
  assert_json_field "$host_id has exact required keys" "$profile_json" '
    (keys | sort) == ([
      "auth_home",
      "binary_path",
      "capabilities",
      "eligibility_smoke_command",
      "github_home",
      "host_id",
      "synthetic_home_behavior"
    ] | sort)
  '
  assert_eq "$host_id host_id round trip" "$host_id" "$(jq -r '.host_id' "$profile_json")"
  assert_json_field "$host_id capabilities round trip" "$profile_json" '.capabilities | length == 4'
  assert_json_field "$host_id auth_home round trip" "$profile_json" '.auth_home | length > 0'
  assert_json_field "$host_id github_home round trip" "$profile_json" '.github_home | length > 0'
  assert_json_field "$host_id smoke command round trip" "$profile_json" '.eligibility_smoke_command | length > 0'
done

worker_order=$(host_profile_list_for_capability worker | paste -sd, -)
assert_eq "default worker order" "claude,codex" "$worker_order"

HOST_PROFILE_LOADED_FILE=
STUDIO_HOST_PROFILE_FILE="$CUSTOM_PROFILE" host_profile_load_file || fail "STUDIO_HOST_PROFILE_FILE override did not load"
assert_eq "env override loaded file" "$CUSTOM_PROFILE" "$HOST_PROFILE_LOADED_FILE"

reviewer_order=$(host_profile_list_for_capability reviewer | paste -sd, -)
assert_eq "custom reviewer order" "alpha" "$reviewer_order"

export STUDIO_AUTO_HOST_ORDER="beta,alpha"
worker_override_order=$(host_profile_list_for_capability worker | paste -sd, -)
unset STUDIO_AUTO_HOST_ORDER
assert_eq "env worker order override" "beta,alpha" "$worker_override_order"

missing_host_err="$TMPROOT/missing-host.err"
if host_profile_get gamma >"$TMPROOT/missing-host.out" 2>"$missing_host_err"; then
  fail "missing host_id unexpectedly passed"
fi
grep -q 'unknown host profile: gamma' "$missing_host_err" \
  || fail "missing host_id failure was not loud"

missing_capability_err="$TMPROOT/missing-capability.err"
if host_profile_list_for_capability perf >"$TMPROOT/missing-capability.out" 2>"$missing_capability_err"; then
  fail "missing capability unexpectedly passed"
fi
grep -q 'no host profiles provide capability: perf' "$missing_capability_err" \
  || fail "missing capability failure was not loud"

HOST_PROFILE_LOADED_FILE=
malformed_err="$TMPROOT/malformed.err"
if host_profile_load_file "$MALFORMED_PROFILE" >"$TMPROOT/malformed.out" 2>"$malformed_err"; then
  fail "malformed profile unexpectedly loaded"
fi
grep -q 'profile file violates host profile contract' "$malformed_err" \
  || fail "malformed profile failure was not loud"

printf 'PASS: lib-host-profiles\n'
