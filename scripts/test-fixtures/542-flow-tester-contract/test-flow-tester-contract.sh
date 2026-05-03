#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROLE_CMD="$ROOT/scripts/v2-role-contract.sh"
ROLE_CONTRACT="$ROOT/core/v2/roles/flow-tester.yaml"
ROLE_SCHEMA="$ROOT/core/v2/schemas/role-contract.schema.json"
HANDOFF="$ROOT/core/v2/handoffs/flow-test-checklist.yaml"
HANDOFF_SCHEMA="$ROOT/core/v2/schemas/handoff.schema.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

"$ROLE_CMD" --validate >/tmp/flow-role-contract.out 2>/tmp/flow-role-contract.err || {
  cat /tmp/flow-role-contract.err >&2
  fail "role contracts failed validation"
}

[ "$("$ROLE_CMD" --resolve --role flow-tester)" = "core/v2/roles/flow-tester.yaml" ] || fail "flow-tester did not resolve"
[ "$("$ROLE_CMD" --resolve --role manual-qa)" = "core/v2/roles/flow-tester.yaml" ] || fail "manual-qa alias did not resolve"
[ "$("$ROLE_CMD" --resolve --role exploratory-tester)" = "core/v2/roles/flow-tester.yaml" ] || fail "exploratory-tester alias did not resolve"

PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$ROLE_SCHEMA" "$ROLE_CONTRACT" >/dev/null \
  || fail "role schema rejected flow-tester contract"
PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$HANDOFF_SCHEMA" "$HANDOFF" >/dev/null \
  || fail "handoff schema rejected flow-test checklist fixture"

yq -e '
  .role == "flow-tester" and
  .leaf_issue == 542 and
  (.outputs[] | select(.kind == "flow-test-checklist")) and
  (.decision_rights[] | test("scenario|severity|Block")) and
  (.verification_floor[] | test("differs from qa-engineer and reviewer"))
' "$ROLE_CONTRACT" >/dev/null || fail "flow-tester contract missing expected semantics"

yq -e '
  .artifact_kind == "flow-test-checklist" and
  .producer_role == "flow-tester" and
  (.payload.scenarios | length > 0) and
  (.payload.merge_block_rule | test("block"))
' "$HANDOFF" >/dev/null || fail "flow-test checklist fixture missing expected payload"

printf 'PASS: flow-tester role contract and handoff\n'
