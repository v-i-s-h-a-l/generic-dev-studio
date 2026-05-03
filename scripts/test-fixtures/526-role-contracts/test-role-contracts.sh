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

for role in worker reviewer perf; do
  "$CMD" --resolve --role "$role" | grep -Fxq "core/v2/roles/$role.yaml" || fail "canonical role did not resolve: $role"
  "$CMD" --resolve --role "$role" --format json | jq -e --arg role "$role" '.role == $role and .leaf_issue == 526 and .contract_file == ("core/v2/roles/" + $role + ".yaml")' >/dev/null || fail "json resolution invalid for $role"
done

[ "$("$CMD" --resolve --role achilles)" = "core/v2/roles/worker.yaml" ] || fail "achilles alias did not resolve to worker contract"
[ "$("$CMD" --resolve --role argus)" = "core/v2/roles/reviewer.yaml" ] || fail "argus alias did not resolve to reviewer contract"
[ "$("$CMD" --resolve --role apollo)" = "core/v2/roles/perf.yaml" ] || fail "apollo alias did not resolve to perf contract"

if "$CMD" --resolve --role manager >"$TMPROOT/manager.out" 2>"$TMPROOT/manager.err"; then
  fail "manager unexpectedly resolved to an A8 contract"
fi
grep -Fq 'role has no A8 migrated contract: manager' "$TMPROOT/manager.err" || fail "manager error was not explicit"

BAD="$TMPROOT/bad-contracts"
mkdir -p "$BAD"
cp "$ROOT/core/v2/roles/worker.yaml" "$BAD/worker.yaml"
cp "$ROOT/core/v2/roles/reviewer.yaml" "$BAD/reviewer.yaml"
if "$CMD" --contract-dir "$BAD" --validate >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  fail "missing perf contract passed validation"
fi
grep -Fq 'missing A8 role contract: perf' "$TMPROOT/bad.err" || fail "missing perf error was not explicit"

printf 'PASS: v2 role contracts\n'
