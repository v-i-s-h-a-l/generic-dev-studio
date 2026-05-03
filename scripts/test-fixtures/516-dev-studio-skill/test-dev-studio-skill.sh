#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SKILL_DIR="$ROOT/core/v2/skills/dev-studio"
FORWARDERS="$SKILL_DIR/forwarders.yaml"
SCHEMA="$ROOT/core/v2/schemas/dev-studio-forwarders.schema.json"
RESOLVE="$ROOT/scripts/v2-role-resolve.sh"
TMPROOT=$(mktemp -d -t dev-studio-skill-516.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require jq
require yq

[ -f "$SKILL_DIR/SKILL.md" ] || fail "missing dev-studio SKILL.md"
[ -f "$SKILL_DIR/routing.yaml" ] || fail "missing dev-studio routing.yaml"
[ -f "$SKILL_DIR/portability.yaml" ] || fail "missing dev-studio portability.yaml"
[ -f "$FORWARDERS" ] || fail "missing dev-studio forwarders.yaml"
[ -f "$SCHEMA" ] || fail "missing dev-studio forwarders schema"

grep -Fq 'name: dev-studio' "$SKILL_DIR/SKILL.md" || fail "SKILL.md frontmatter name mismatch"
grep -Fq 'type: agent-router' "$SKILL_DIR/SKILL.md" || fail "dev-studio is not an agent-router"
grep -Fq '<!-- v2-dev-studio:dispatch -->' "$SKILL_DIR/SKILL.md" || fail "missing dispatch anchor"
grep -Fq '<!-- v2-dev-studio:forwarders -->' "$SKILL_DIR/SKILL.md" || fail "missing forwarders anchor"

[ "$(yq -r '.invocation.slash_command' "$SKILL_DIR/routing.yaml")" = "/dev-studio" ] || fail "routing slash command mismatch"
[ "$(yq -r '.scope' "$SKILL_DIR/portability.yaml")" = "project" ] || fail "dev-studio portability scope must be project"

yq -o=json "$FORWARDERS" > "$TMPROOT/forwarders.json"
jq -e '.schema_version == 1 and .kind == "studio-v2-dev-studio-forwarders" and .leaf_issue == 516' "$TMPROOT/forwarders.json" >/dev/null || fail "forwarder envelope invalid"

if command -v check-jsonschema >/dev/null 2>&1; then
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" "$TMPROOT/forwarders.json" >/dev/null || fail "forwarders schema validation failed"
else
  printf 'WARN: check-jsonschema unavailable; skipped schema validation\n' >&2
fi

for role in manager planner worker reviewer qa-engineer flow-tester perf release-manager host-adapter operator; do
  yq -e ".dispatch[] | select(.canonical_role == \"$role\")" "$FORWARDERS" >/dev/null || fail "missing dispatch row: $role"
done

assert_forwarder() {
  legacy="$1"
  expected_role="$2"
  expected_skill="$3"
  alias="${legacy#/}"

  actual_role=$(yq -r ".forwarders[] | select(.legacy_invocation == \"$legacy\") | .canonical_role" "$FORWARDERS")
  [ "$actual_role" = "$expected_role" ] || fail "$legacy maps to $actual_role, expected $expected_role"

  actual_skill=$(yq -r ".forwarders[] | select(.legacy_invocation == \"$legacy\") | .v1_skill" "$FORWARDERS")
  [ "$actual_skill" = "$expected_skill" ] || fail "$legacy preserves $actual_skill, expected $expected_skill"
  [ -f "$ROOT/$actual_skill" ] || fail "missing preserved v1 skill: $actual_skill"

  [ "$("$RESOLVE" "$alias")" = "$expected_role" ] || fail "$alias alias does not resolve to $expected_role"
  yq -e ".dispatch[] | select(.canonical_role == \"$expected_role\") | .compatibility_aliases[] | select(. == \"$alias\")" "$FORWARDERS" >/dev/null || fail "$alias missing from dispatch aliases"
}

assert_forwarder /chanakya manager chanakya/SKILL.md
assert_forwarder /achilles worker achilles/SKILL.md
assert_forwarder /argus reviewer argus/SKILL.md
assert_forwarder /apollo perf apollo/SKILL.md

[ "$(yq -r '.transition.cutover_status' "$FORWARDERS")" = "cut-over" ] || fail "runtime cutover should be recorded after A9"
grep -Fq 'primary traffic surface' "$SKILL_DIR/SKILL.md" || fail "A9 traffic boundary not documented"

printf 'PASS: dev-studio umbrella skill and forwarders\n'
