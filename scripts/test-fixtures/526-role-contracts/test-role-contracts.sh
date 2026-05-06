#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CMD="$ROOT/scripts/v2-role-contract.sh"
SCHEMA="$ROOT/core/v2/schemas/role-contract.schema.json"
TMPROOT=$(mktemp -d -t role-contracts-526.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$CMD" ] || fail "role-contract resolver is not executable"
[ -f "$SCHEMA" ] || fail "missing role-contract schema"
jq -e '.["$schema"] and .type == "object"' "$SCHEMA" >/dev/null || fail "schema is not a JSON schema"

"$CMD" --validate >"$TMPROOT/validate.out" 2>"$TMPROOT/validate.err" || {
  cat "$TMPROOT/validate.err" >&2
  fail "repo role contracts failed validation"
}
grep -Fq 'v2-role-contract: ok' "$TMPROOT/validate.err" || fail "validation did not report success"

for role in manager planner worker reviewer qa-engineer flow-tester perf release-manager; do
  "$CMD" --resolve --role "$role" | grep -Fxq "core/v2/roles/$role.yaml" || fail "canonical role did not resolve: $role"
  "$CMD" --resolve --role "$role" --format json | jq -e --arg role "$role" '.role == $role and .contract_file == ("core/v2/roles/" + $role + ".yaml")' >/dev/null || fail "json resolution invalid for $role"
  if command -v check-jsonschema >/dev/null 2>&1; then
    PYTHONWARNINGS=ignore check-jsonschema --force-filetype yaml --schemafile "$SCHEMA" "$ROOT/core/v2/roles/$role.yaml" >/dev/null \
      || fail "schema rejected role contract: $role"
  fi
done

for role in manager worker reviewer qa-engineer flow-tester perf release-manager; do
  grep -Fq 'checkpoint-artifact' "$ROOT/core/v2/roles/$role.yaml" || fail "missing checkpoint output for role: $role"
  grep -Fq 'Checkpoint artifacts do not replace worker summaries, reviewer verdicts, release packets, QA or flow checklists, perf verdicts, or event logs.' "$ROOT/core/v2/roles/$role.yaml" \
    || fail "missing checkpoint non-replacement rule for role: $role"
done

grep -Fq 'For bare checkpoint or resume-checkpoint invocations' "$ROOT/core/v2/roles/manager.yaml" || fail "manager does not own bare checkpoint shaping"
grep -Fq 'kind: product-context' "$ROOT/core/v2/roles/manager.yaml" || fail "manager product-context input missing"
grep -Fq 'material assumptions affect scope, cost, user-visible behavior, verification, or role routing' "$ROOT/core/v2/roles/manager.yaml" || fail "manager clarification materiality rule missing"
grep -Fq 'does not auto-fetch PRD or Figma sources' "$ROOT/core/v2/roles/manager.yaml" || fail "manager PRD/Figma source boundary missing"
grep -Fq 'Return needs_context rather than locking a brief when material assumptions remain unresolved' "$ROOT/core/v2/roles/manager.yaml" || fail "manager unresolved-assumption needs_context rule missing"
grep -Fq 'Small unambiguous requests stay lightweight' "$ROOT/core/v2/roles/manager.yaml" || fail "manager lightweight-task guard missing"
grep -Fq 'Worker checkpoint use is optional' "$ROOT/core/v2/roles/worker.yaml" || fail "worker checkpoint optionality not documented"

[ "$("$CMD" --resolve --role chanakya)" = "core/v2/roles/manager.yaml" ] || fail "chanakya alias did not resolve to manager contract"
[ "$("$CMD" --resolve --role architect)" = "core/v2/roles/planner.yaml" ] || fail "architect alias did not resolve to planner contract"
[ "$("$CMD" --resolve --role achilles)" = "core/v2/roles/worker.yaml" ] || fail "achilles alias did not resolve to worker contract"
[ "$("$CMD" --resolve --role argus)" = "core/v2/roles/reviewer.yaml" ] || fail "argus alias did not resolve to reviewer contract"
[ "$("$CMD" --resolve --role chiron)" = "core/v2/roles/qa-engineer.yaml" ] || fail "chiron alias did not resolve to qa-engineer contract"
[ "$("$CMD" --resolve --role manual-qa)" = "core/v2/roles/flow-tester.yaml" ] || fail "manual-qa alias did not resolve to flow-tester contract"
[ "$("$CMD" --resolve --role apollo)" = "core/v2/roles/perf.yaml" ] || fail "apollo alias did not resolve to perf contract"
[ "$("$CMD" --resolve --role shipper)" = "core/v2/roles/release-manager.yaml" ] || fail "shipper alias did not resolve to release-manager contract"

BAD="$TMPROOT/bad-contracts"
mkdir -p "$BAD"
cp "$ROOT/core/v2/roles/manager.yaml" "$BAD/manager.yaml"
cp "$ROOT/core/v2/roles/planner.yaml" "$BAD/planner.yaml"
cp "$ROOT/core/v2/roles/worker.yaml" "$BAD/worker.yaml"
cp "$ROOT/core/v2/roles/reviewer.yaml" "$BAD/reviewer.yaml"
cp "$ROOT/core/v2/roles/qa-engineer.yaml" "$BAD/qa-engineer.yaml"
cp "$ROOT/core/v2/roles/flow-tester.yaml" "$BAD/flow-tester.yaml"
if "$CMD" --contract-dir "$BAD" --validate >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  fail "missing perf contract passed validation"
fi
grep -Fq 'missing migrated role contract: perf' "$TMPROOT/bad.err" || fail "missing perf error was not explicit"

printf 'PASS: v2 role contracts\n'
