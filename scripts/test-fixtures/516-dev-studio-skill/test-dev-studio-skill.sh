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
grep -Fq '<!-- v2-dev-studio:landing -->' "$SKILL_DIR/SKILL.md" || fail "missing bare-role landing anchor"
grep -Fq '<!-- v2-dev-studio:forwarders -->' "$SKILL_DIR/SKILL.md" || fail "missing forwarders anchor"

[ "$(yq -r '.invocation.slash_command' "$SKILL_DIR/routing.yaml")" = "/dev-studio" ] || fail "routing slash command mismatch"
[ "$(yq -r '.scope' "$SKILL_DIR/portability.yaml")" = "global" ] || fail "dev-studio portability scope must be global"
yq -e '.hosts[] | select(. == "all")' "$SKILL_DIR/portability.yaml" >/dev/null || fail "dev-studio must declare global host fan-out"
yq -e '.exclude_hosts[] | select(. == "claude-code")' "$SKILL_DIR/portability.yaml" >/dev/null || fail "dev-studio must avoid duplicate Claude Code command discovery"

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

assert_alias() {
  alias="$1"
  expected_role="$2"

  [ "$("$RESOLVE" "$alias")" = "$expected_role" ] || fail "$alias alias does not resolve to $expected_role"
  yq -e ".dispatch[] | select(.canonical_role == \"$expected_role\") | .compatibility_aliases[] | select(. == \"$alias\")" "$FORWARDERS" >/dev/null || fail "$alias missing from dispatch aliases"
}

assert_alias chanakya manager
assert_alias achilles worker
assert_alias argus reviewer
assert_alias apollo perf

[ "$(yq -r '.transition.cutover_status' "$FORWARDERS")" = "v1-deleted" ] || fail "A10 deletion should be recorded"
[ "$(yq -r '.forwarders | length' "$FORWARDERS")" = "0" ] || fail "A10 should not preserve v1 forwarder rows"
grep -Fq 'primary traffic surface' "$SKILL_DIR/SKILL.md" || fail "traffic boundary not documented"
grep -Fq 'Bare Role Landing' "$SKILL_DIR/SKILL.md" || fail "bare role landing not documented"
grep -Fq 'Lifecycle Actions' "$SKILL_DIR/SKILL.md" || fail "lifecycle actions not documented"
grep -Fq '/dev-studio <role> checkpoint' "$SKILL_DIR/SKILL.md" || fail "explicit role checkpoint route not documented"
grep -Fq '/dev-studio checkpoint' "$SKILL_DIR/SKILL.md" || fail "bare checkpoint manager route not documented"
grep -Fq 'direct one-line invocation' "$SKILL_DIR/SKILL.md" || fail "direct command suggestion not documented"
yq -e '.invocation.triggers[] | select(. == "/dev-studio checkpoint")' "$SKILL_DIR/routing.yaml" >/dev/null || fail "checkpoint trigger metadata missing"
yq -e '.invocation.triggers[] | select(. == "/dev-studio resume-checkpoint")' "$SKILL_DIR/routing.yaml" >/dev/null || fail "resume-checkpoint trigger metadata missing"

printf 'PASS: dev-studio umbrella skill and forwarders\n'
