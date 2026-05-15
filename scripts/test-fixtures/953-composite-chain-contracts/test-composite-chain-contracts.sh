#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE_DIR="$ROOT/scripts/test-fixtures/953-composite-chain-contracts"
SCHEMA="$ROOT/_shared/contracts/composite-chain-state.schema.json"
STATE="$FIXTURE_DIR/valid-state.json"
MANIFEST="$FIXTURE_DIR/composite-manifest.yaml"
TMPROOT=$(mktemp -d -t composite-chain-contracts.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema required"

[ -f "$SCHEMA" ] || fail "missing schema: $SCHEMA"
[ -f "$STATE" ] || fail "missing fixture state: $STATE"
[ -f "$MANIFEST" ] || fail "missing fixture manifest: $MANIFEST"

jq empty "$SCHEMA"
jq empty "$STATE"
jq -e '(.children | map(.id) | unique | length) == (.children | length)' "$STATE" >/dev/null \
  || fail "state fixture child ids are not unique"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" \
  --base-uri "file://$ROOT/_shared/contracts/" "$STATE" >/dev/null \
  || fail "valid state did not pass schema validation"

jq '.children[1].status = "running"' "$STATE" > "$TMPROOT/two-active.json"
if PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" \
    --base-uri "file://$ROOT/_shared/contracts/" "$TMPROOT/two-active.json" >/dev/null 2>&1; then
  fail "schema accepted two active children"
fi

jq '.children[0].status = "blocked"' "$STATE" > "$TMPROOT/bad-status.json"
if PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" \
    --base-uri "file://$ROOT/_shared/contracts/" "$TMPROOT/bad-status.json" >/dev/null 2>&1; then
  fail "schema accepted an unknown child status"
fi

yq -e '
  .kind == "composite-chain" and
  .schema_version == 1 and
  .mode == "sequential" and
  (.children | length) == 2 and
  .children[0].id == "ui-ia-redesign" and
  .children[0].source_type == "issue" and
  .children[0].issue == 123
' "$MANIFEST" >/dev/null || fail "manifest fixture does not match MVP shape"

grep -Fq 'composite_chain_started' "$ROOT/_shared/contracts/events.md" \
  || fail "events contract missing composite_chain_started"
grep -Fq 'composite_child_run_completed' "$ROOT/_shared/contracts/events.md" \
  || fail "events contract missing composite child completion event"
grep -Fq 'Natural-language extraction from parent issue text is a non-goal' \
  "$ROOT/_shared/contracts/composite-chain-state.md" \
  || fail "contract doc missing MVP non-goal"

printf 'PASS: composite chain contracts\n'
