#!/usr/bin/env bash
# Verifies the planner role contract and planner-output handoff fixture.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROLE_CMD="$ROOT/scripts/v2-role-contract.sh"
ROLE_CONTRACT="$ROOT/core/v2/roles/planner.yaml"
ROLE_SCHEMA="$ROOT/core/v2/schemas/role-contract.schema.json"
HANDOFF="$ROOT/core/v2/handoffs/planner-output.yaml"
HANDOFF_SCHEMA="$ROOT/core/v2/schemas/handoff.schema.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

[ -x "$ROLE_CMD" ] || fail "role-contract resolver is not executable"
[ -f "$ROLE_CONTRACT" ] || fail "missing planner role contract"
[ -f "$ROLE_SCHEMA" ] || fail "missing role contract schema"
[ -f "$HANDOFF" ] || fail "missing planner-output handoff fixture"
[ -f "$HANDOFF_SCHEMA" ] || fail "missing handoff schema"

"$ROLE_CMD" --validate >/tmp/planner-role-contract.out 2>/tmp/planner-role-contract.err || {
  cat /tmp/planner-role-contract.err >&2
  fail "role contracts failed validation"
}

[ "$("$ROLE_CMD" --resolve --role planner)" = "core/v2/roles/planner.yaml" ] \
  || fail "planner did not resolve to planner contract"
[ "$("$ROLE_CMD" --resolve --role architect)" = "core/v2/roles/planner.yaml" ] \
  || fail "architect alias did not resolve to planner contract"
[ "$("$ROLE_CMD" --resolve --role luban)" = "core/v2/roles/planner.yaml" ] \
  || fail "luban alias did not resolve to planner contract"

yq -e '
  .role == "planner" and
  .leaf_issue == 540 and
  (.outputs[] | select(.kind == "planner-output")) and
  (.outputs[] | select(.kind == "worker-contract")) and
  (.decision_rights[] | test("reuse|Decompose|blocked")) and
  (.escalation_triggers[] | test("manager|Acceptance|Scope|priorities")) and
  (.failure_semantics[] | test("escalate to manager"))
' "$ROLE_CONTRACT" >/dev/null || fail "planner contract is missing expected authority or escalation text"

PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$ROLE_SCHEMA" "$ROLE_CONTRACT" >/dev/null \
  || fail "role schema rejected planner contract"
PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$HANDOFF_SCHEMA" "$HANDOFF" >/dev/null \
  || fail "handoff schema rejected planner-output fixture"

yq -e '
  .artifact_kind == "planner-output" and
  .producer_role == "planner" and
  .consumer_role == "reviewer" and
  (.payload.reusable_api_findings | length > 0) and
  (.payload.acceptance_criteria | length > 0) and
  (.payload.refactoring_follow_ups[0].reason | length > 0) and
  (.payload.refactoring_follow_ups[0].affected_area | length > 0) and
  (.payload.refactoring_follow_ups[0].risk == "medium") and
  (.payload.refactoring_follow_ups[0].suggested_timing | length > 0) and
  (.payload.decomposition[0].owner_role == "worker") and
  (.payload.escalation.required == false)
' "$HANDOFF" >/dev/null || fail "planner-output fixture is missing expected planner payload"

printf 'PASS: planner role contract and handoff\n'
