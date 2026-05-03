#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ROLE_CMD="$ROOT/scripts/v2-role-contract.sh"
ROLE_CONTRACT="$ROOT/core/v2/roles/release-manager.yaml"
ROLE_SCHEMA="$ROOT/core/v2/schemas/role-contract.schema.json"
HANDOFF="$ROOT/core/v2/handoffs/release-packet.yaml"
HANDOFF_SCHEMA="$ROOT/core/v2/schemas/handoff.schema.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

"$ROLE_CMD" --validate >/tmp/release-role-contract.out 2>/tmp/release-role-contract.err || {
  cat /tmp/release-role-contract.err >&2
  fail "role contracts failed validation"
}

[ "$("$ROLE_CMD" --resolve --role release-manager)" = "core/v2/roles/release-manager.yaml" ] || fail "release-manager did not resolve"
[ "$("$ROLE_CMD" --resolve --role release)" = "core/v2/roles/release-manager.yaml" ] || fail "release alias did not resolve"
[ "$("$ROLE_CMD" --resolve --role shipper)" = "core/v2/roles/release-manager.yaml" ] || fail "shipper alias did not resolve"

PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$ROLE_SCHEMA" "$ROLE_CONTRACT" >/dev/null \
  || fail "role schema rejected release-manager contract"
PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$HANDOFF_SCHEMA" "$HANDOFF" >/dev/null \
  || fail "handoff schema rejected release-packet fixture"

yq -e '
  .role == "release-manager" and
  .leaf_issue == 543 and
  ((.outputs | map(.kind)) | contains(["release-packet"]))
' "$ROLE_CONTRACT" >/dev/null || fail "release-manager contract missing expected semantics"
grep -Fq '#214' "$ROLE_CONTRACT" || fail "release-manager contract does not reference #214"
grep -Fq 'Do not tag' "$ROLE_CONTRACT" || fail "release-manager contract does not prevent tagging"

yq -e '
  .artifact_kind == "release-packet" and
  .producer_role == "release-manager" and
  (.payload.tags == "pending") and
  (.payload.blockers | length > 0)
' "$HANDOFF" >/dev/null || fail "release-packet fixture missing expected payload"
grep -Fq '#214' "$HANDOFF" || fail "release-packet fixture does not reference #214"

printf 'PASS: release-manager role contract and handoff\n'
