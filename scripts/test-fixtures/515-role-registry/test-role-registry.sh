#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RESOLVE="$ROOT/scripts/v2-role-resolve.sh"
REGISTRY="$ROOT/core/v2/registry/roles.json"
SCHEMA="$ROOT/core/v2/schemas/role-registry.schema.json"
TMPROOT=$(mktemp -d -t role-registry-515.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RESOLVE" ] || fail "resolver is not executable"
[ -f "$REGISTRY" ] || fail "missing role registry"
[ -f "$SCHEMA" ] || fail "missing role registry schema"

jq -e '.["$schema"] and .type == "object"' "$SCHEMA" >/dev/null || fail "schema is not a JSON schema"
jq -e '.schema_version == 1 and .kind == "studio-v2-role-registry" and .leaf_issue == 515' "$REGISTRY" >/dev/null || fail "registry envelope invalid"

for role in manager planner worker reviewer qa-engineer flow-tester perf release-manager host-adapter operator; do
  "$RESOLVE" "$role" | grep -Fxq "$role" || fail "canonical role does not resolve: $role"
done

[ "$("$RESOLVE" chanakya)" = manager ] || fail "chanakya alias did not resolve to manager"
[ "$("$RESOLVE" Achilles)" = worker ] || fail "case-insensitive alias did not resolve"
[ "$("$RESOLVE" qa_engineer)" = qa-engineer ] || fail "underscore alias did not normalize"
[ "$("$RESOLVE" "manual qa" 2>/dev/null || true)" = flow-tester ] || fail "space alias did not normalize"
[ "$("$RESOLVE" --format json apollo | jq -r '.canonical_role + ":" + .matched_as')" = perf:alias ] || fail "json output did not include alias resolution"

if "$RESOLVE" unknown-role >"$TMPROOT/unknown.out" 2>"$TMPROOT/unknown.err"; then
  fail "unknown alias resolved successfully"
fi
grep -Fq 'unknown role or alias' "$TMPROOT/unknown.err" || fail "unknown alias error was not explicit"

cat > "$TMPROOT/conflict.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "studio-v2-role-registry",
  "roles": [
    {"name": "manager", "aliases": ["same"]},
    {"name": "worker", "aliases": ["same"]}
  ]
}
JSON

if "$RESOLVE" --registry "$TMPROOT/conflict.json" same >"$TMPROOT/conflict.out" 2>"$TMPROOT/conflict.err"; then
  fail "conflicting aliases resolved successfully"
fi
grep -Fq 'alias conflict' "$TMPROOT/conflict.err" || fail "conflicting alias error was not explicit"

printf 'PASS: role registry and alias resolver\n'
