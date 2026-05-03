#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROLE_CMD="$ROOT/scripts/v2-role-contract.sh"
ROLE_CONTRACT="$ROOT/core/v2/roles/qa-engineer.yaml"
ROLE_SCHEMA="$ROOT/core/v2/schemas/role-contract.schema.json"
HANDOFF="$ROOT/core/v2/handoffs/qa-contract.yaml"
HANDOFF_SCHEMA="$ROOT/core/v2/schemas/handoff.schema.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

"$ROLE_CMD" --validate >/tmp/qa-role-contract.out 2>/tmp/qa-role-contract.err || {
  cat /tmp/qa-role-contract.err >&2
  fail "role contracts failed validation"
}

[ "$("$ROLE_CMD" --resolve --role qa-engineer)" = "core/v2/roles/qa-engineer.yaml" ] || fail "qa-engineer did not resolve"
[ "$("$ROLE_CMD" --resolve --role chiron)" = "core/v2/roles/qa-engineer.yaml" ] || fail "chiron alias did not resolve"
[ "$("$ROLE_CMD" --resolve --role synthetic-qa)" = "core/v2/roles/qa-engineer.yaml" ] || fail "synthetic-qa alias did not resolve"

PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$ROLE_SCHEMA" "$ROLE_CONTRACT" >/dev/null \
  || fail "role schema rejected qa-engineer contract"
PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$HANDOFF_SCHEMA" "$HANDOFF" >/dev/null \
  || fail "handoff schema rejected qa-contract fixture"

yq -e '
  .role == "qa-engineer" and
  .leaf_issue == 541 and
  (.outputs[] | select(.kind == "qa-contract")) and
  (.decision_rights[] | test("parallel|blocked|Escalate")) and
  (.failure_semantics[] | test("partial|blocked|idempotency"))
' "$ROLE_CONTRACT" >/dev/null || fail "qa-engineer contract missing expected semantics"

yq -e '
  .artifact_kind == "qa-contract" and
  .producer_role == "qa-engineer" and
  (.payload.qa_targets | length > 0) and
  (.payload.parallel_completion.partial_allowed == true)
' "$HANDOFF" >/dev/null || fail "qa-contract fixture missing expected payload"

printf 'PASS: qa-engineer role contract and handoff\n'
