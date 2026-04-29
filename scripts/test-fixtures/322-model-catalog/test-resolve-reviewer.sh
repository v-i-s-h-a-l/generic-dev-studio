#!/usr/bin/env bash
# Verifies scripts/resolve-reviewer.sh against synthetic catalog/policy/registry
# fixtures. Stubs the reviewer-eligibility script so the test does not depend
# on real `claude` / `codex` binaries.
#
# Asserts (issue #322 acceptance criteria):
#   1. Different-family reviewer wins when impl host is a known family.
#   2. Family collision escalates the tier instead of blocking.
#   3. No eligible reviewer host -> exit 3 with STUDIO_REVIEWER_RESOLUTION=blocked.
#   4. Unknown impl host -> any eligible reviewer is accepted (no exclusion).
#   5. --force-host bypasses the independence partition.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t resolve-reviewer.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

CATALOG="$TMPROOT/model-catalog.yaml"
POLICY="$TMPROOT/model-policy.yaml"
REGISTRY="$TMPROOT/registry.yaml"
ELIG="$TMPROOT/elig.sh"

cat > "$CATALOG" <<'YAML'
schema_version: { name: model-catalog, version: 1.0.0, min_reader: 1.0.0 }
last_refreshed_at: "2026-04-30"
intelligence_tiers: [low, medium, high, max]
models:
  - id: claude-opus-test
    provider_family: anthropic
    intelligence_tier: max
    roles: [reviewer.heavyweight]
    reasoning_effort_supported: false
    default_reasoning_effort: null
  - id: claude-sonnet-test
    provider_family: anthropic
    intelligence_tier: high
    roles: [reviewer.heavyweight, reviewer.fallback]
    reasoning_effort_supported: false
    default_reasoning_effort: null
  - id: gpt-test-max
    provider_family: openai
    intelligence_tier: max
    roles: [reviewer.heavyweight]
    reasoning_effort_supported: true
    default_reasoning_effort: high
  - id: gpt-test-high
    provider_family: openai
    intelligence_tier: high
    roles: [reviewer.heavyweight, reviewer.fallback]
    reasoning_effort_supported: true
    default_reasoning_effort: medium
YAML

cat > "$POLICY" <<'YAML'
schema_version: { name: model-policy, version: 1.0.0, min_reader: 1.0.0 }
roles:
  reviewer.heavyweight: { tier: high }
  reviewer.fallback:    { tier: medium }
reviewer_independence:
  default: prefer-different-family
  same_family_collision: escalate
  no_eligible_reviewer: block
  preferred_family_order: [anthropic, openai]
reasoning_effort:
  reviewer.heavyweight: high
  reviewer.fallback: medium
  same_family_collision_floor: high
YAML

cat > "$REGISTRY" <<YAML
claude-code:
  display_name: "Claude Code"
  detect_binary: claude
  global_skill_dir: "~/.claude/skills"
  capabilities_path: ".claude-plugin/capabilities.yaml"
  tool_dialect: claude
  provider_family: anthropic
  status: adapted
claude-reviewer:
  display_name: "Claude Reviewer"
  detect_binary: claude
  global_skill_dir: "~/.claude-reviewer/skills"
  capabilities_path: ".claude-reviewer/capabilities.yaml"
  tool_dialect: claude
  provider_family: anthropic
  status: adapted
codex:
  display_name: "Codex"
  detect_binary: codex
  global_skill_dir: "~/.codex/skills"
  capabilities_path: ".codex/capabilities.yaml"
  tool_dialect: openai
  provider_family: openai
  status: adapted
codex-reviewer:
  display_name: "Codex Reviewer"
  detect_binary: codex
  global_skill_dir: "~/.codex/skills"
  capabilities_path: ".codex-reviewer/capabilities.yaml"
  tool_dialect: openai
  provider_family: openai
  status: adapted
YAML

# Stub eligibility: allow only the hosts whitespace-listed in $ELIG_ALLOW.
cat > "$ELIG" <<'SH'
#!/usr/bin/env bash
host="${1:-}"
case " ${ELIG_ALLOW:-} " in
  *" $host "*) printf 'PR_REVIEWER_ELIGIBLE=1\n'; exit 0 ;;
  *) printf 'PR_REVIEWER_ELIGIBLE=0\nREASON=stub\n'; exit 1 ;;
esac
SH
chmod +x "$ELIG"

run_resolver() {
  STUDIO_MODEL_CATALOG_FILE="$CATALOG" \
  STUDIO_MODEL_POLICY_FILE="$POLICY" \
  STUDIO_HOSTS_REGISTRY_FILE="$REGISTRY" \
  STUDIO_REVIEWER_ELIGIBILITY_SCRIPT="$ELIG" \
  ELIG_ALLOW="$1" \
    "$ROOT/scripts/resolve-reviewer.sh" "${@:2}"
}

assert_kv() {
  local out="$1" key="$2" want="$3"
  local got
  got=$(printf '%s\n' "$out" | sed -n "s/^${key}=//p" | head -1)
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s: want %s=%s, got %s=%s\n' "$4" "$key" "$want" "$key" "$got" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

# 1. Implementer is anthropic, both reviewer hosts eligible -> prefer codex.
out=$(run_resolver "claude-reviewer codex-reviewer" --impl-host claude-code) \
  || { printf 'FAIL: case 1 exit\n%s\n' "$out" >&2; exit 1; }
assert_kv "$out" STUDIO_REVIEWER_HOST           codex-reviewer  "case 1 host"
assert_kv "$out" STUDIO_REVIEWER_MODEL          gpt-test-high   "case 1 model"
assert_kv "$out" STUDIO_REVIEWER_TIER           high            "case 1 tier"
assert_kv "$out" STUDIO_REVIEWER_FAMILY_COLLISION false         "case 1 collision"
assert_kv "$out" STUDIO_REVIEWER_ESCALATED      false           "case 1 escalated"
assert_kv "$out" STUDIO_REVIEWER_REASONING_EFFORT high          "case 1 effort"

# 2. Implementer openai, only codex reviewer eligible -> escalate to max.
out=$(run_resolver "codex-reviewer" --impl-host codex) \
  || { printf 'FAIL: case 2 exit\n%s\n' "$out" >&2; exit 1; }
assert_kv "$out" STUDIO_REVIEWER_HOST            codex-reviewer  "case 2 host"
assert_kv "$out" STUDIO_REVIEWER_MODEL           gpt-test-max    "case 2 model"
assert_kv "$out" STUDIO_REVIEWER_TIER            max             "case 2 tier"
assert_kv "$out" STUDIO_REVIEWER_FAMILY_COLLISION true           "case 2 collision"
assert_kv "$out" STUDIO_REVIEWER_ESCALATED       true            "case 2 escalated"
assert_kv "$out" STUDIO_REVIEWER_REASONING_EFFORT high           "case 2 effort floor"

# 3. No eligible reviewer host at all -> blocked exit 3.
set +e
out=$(run_resolver "" --impl-host claude-code)
rc=$?
set -e
[ "$rc" = "3" ] || { printf 'FAIL: case 3 expected exit 3, got %s\n%s\n' "$rc" "$out" >&2; exit 1; }
assert_kv "$out" STUDIO_REVIEWER_RESOLUTION blocked                    "case 3 resolution"
assert_kv "$out" STUDIO_REVIEWER_REASON     no_eligible_reviewer_host  "case 3 reason"

# 4. Unknown impl host -> picks any eligible host without exclusion.
out=$(run_resolver "claude-reviewer codex-reviewer" --impl-host unknown) \
  || { printf 'FAIL: case 4 exit\n%s\n' "$out" >&2; exit 1; }
assert_kv "$out" STUDIO_REVIEWER_FAMILY_COLLISION false   "case 4 collision"
assert_kv "$out" STUDIO_REVIEWER_IMPL_FAMILY     ""       "case 4 impl family empty"

# 5. --force-host bypasses the partition; collision flag stays false.
out=$(run_resolver "claude-reviewer" --impl-host claude-code --force-host claude-reviewer) \
  || { printf 'FAIL: case 5 exit\n%s\n' "$out" >&2; exit 1; }
assert_kv "$out" STUDIO_REVIEWER_HOST            claude-reviewer    "case 5 host"
assert_kv "$out" STUDIO_REVIEWER_MODEL           claude-sonnet-test "case 5 model"
assert_kv "$out" STUDIO_REVIEWER_FAMILY_COLLISION false             "case 5 collision"

printf 'OK: 322-model-catalog resolve-reviewer fixture passed.\n'
