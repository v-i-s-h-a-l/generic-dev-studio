#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-status"
MANIFEST="$FIXTURE_DIR/composite-manifest.yaml"
MANAGER="$ROOT/scripts/manager-composite-chain.sh"
RUN_ID="019e2c8a-9550-7000-8000-000000000001"
TMPROOT="${TMPDIR:-/tmp}/composite-chain-status.$$"

trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

mkdir -p "$TMPROOT"

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema required"

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-manifest --manifest "$MANIFEST" >/dev/null

if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" init --manifest "$MANIFEST" --run-id "../../bad" >"$TMPROOT/bad-run-id.out" 2>"$TMPROOT/bad-run-id.err"; then
  fail "bad run id unexpectedly initialized state"
fi
grep -Fq "run id must be a lowercase UUIDv7" "$TMPROOT/bad-run-id.err" \
  || fail "bad run id failure did not name UUIDv7 validation"

init_json=$(HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
  "$MANAGER" init --manifest "$MANIFEST" --run-id "$RUN_ID" --json)
state_path=$(printf '%s\n' "$init_json" | jq -r '.state_path')
[ -f "$state_path" ] || fail "init did not write state"

HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
  "$ROOT/scripts/validate-contract.sh" composite-chain-state "$state_path"
HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" validate-state --state "$state_path" >/dev/null

before_hash=$(hash_file "$state_path")
status_output=$(HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio "$MANAGER" status --run-id "$RUN_ID")
after_hash=$(hash_file "$state_path")
[ "$before_hash" = "$after_hash" ] || fail "status mutated state"

printf '%s\n' "$status_output" | grep -Fq "Current child: ui-ia-redesign (pending)" \
  || fail "status missing current child"
printf '%s\n' "$status_output" | grep -Fq "Completed children:" \
  || fail "status missing completed children"
printf '%s\n' "$status_output" | grep -Fq "Remaining children:" \
  || fail "status missing remaining children"
printf '%s\n' "$status_output" | grep -Fq "Active child run id: none" \
  || fail "status missing active child run id"
printf '%s\n' "$status_output" | grep -Fq "Blocked/halt reason: none" \
  || fail "status missing halt reason"
printf '%s\n' "$status_output" | grep -Fq "Next resume command: /dev-studio manager composite-chain status --run-id $RUN_ID" \
  || fail "status missing next resume command"

if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" status --parent-issue 953 >"$TMPROOT/parent.out" 2>"$TMPROOT/parent.err"; then
  fail "parent issue parsing unexpectedly succeeded"
fi
grep -Fq "parent issue parsing is unsupported" "$TMPROOT/parent.err" \
  || fail "unsupported parent issue parsing did not explain the MVP limit"

duplicate_manifest="$TMPROOT/duplicate-manifest.yaml"
yq '.children[1].id = .children[0].id' "$MANIFEST" > "$duplicate_manifest"
if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" validate-manifest --manifest "$duplicate_manifest" >"$TMPROOT/duplicate.out" 2>"$TMPROOT/duplicate.err"; then
  fail "duplicate child ids unexpectedly passed"
fi
grep -Fq "child ids must be unique" "$TMPROOT/duplicate.err" \
  || fail "duplicate child id failure did not name the invariant"

later_running="$TMPROOT/later-running.json"
jq '.state = "running_child" | .children[1].status = "running" | .current_child_index = 1 | .current_child_id = .children[1].id' \
  "$state_path" > "$later_running"
if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" validate-state --state "$later_running" >"$TMPROOT/later.out" 2>"$TMPROOT/later.err"; then
  fail "later-child ordering violation unexpectedly passed"
fi
grep -Fq "state invariant validation failed" "$TMPROOT/later.err" \
  || fail "later-child failure did not name invariant validation"

two_active="$TMPROOT/two-active.json"
jq '.state = "running_child" | .children[0].status = "running" | .children[1].status = "planning" | .current_child_index = 0 | .current_child_id = .children[0].id' \
  "$state_path" > "$two_active"
if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" validate-state --state "$two_active" >"$TMPROOT/two-active.out" 2>"$TMPROOT/two-active.err"; then
  fail "two active children unexpectedly passed"
fi
grep -Eq "INVALID|state invariant validation failed" "$TMPROOT/two-active.err" \
  || fail "two-active failure did not surface validation"

mismatch="$TMPROOT/current-child-mismatch.json"
jq '.state = "running_child" | .children[0].status = "running" | .current_child_index = 1 | .current_child_id = .children[0].id' \
  "$state_path" > "$mismatch"
if HOME="$TMPROOT/home" ACHILLES_PROJECT=generic-dev-studio \
    "$MANAGER" validate-state --state "$mismatch" >"$TMPROOT/mismatch.out" 2>"$TMPROOT/mismatch.err"; then
  fail "current child index/id mismatch unexpectedly passed"
fi
grep -Fq "state invariant validation failed" "$TMPROOT/mismatch.err" \
  || fail "current-child mismatch failure did not name invariant validation"

printf 'PASS: composite chain status\n'
