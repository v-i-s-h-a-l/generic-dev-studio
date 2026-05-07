#!/usr/bin/env bash
# Regression coverage for the rule-pack metadata contract and seed catalog.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONTRACT="$ROOT/core/v2/rule-packs/pack-contract.md"
CATALOG="$ROOT/core/v2/rule-packs/catalog.yaml"
SCHEMA="$ROOT/core/v2/schemas/rule-pack-catalog.schema.json"
TMPROOT=$(mktemp -d -t rule-pack-metadata-674.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  needle="$1"
  grep -Fq -- "$needle" "$CONTRACT" || fail "contract missing: $needle"
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

[ -f "$CONTRACT" ] || fail "missing contract"
[ -f "$CATALOG" ] || fail "missing catalog"
[ -f "$SCHEMA" ] || fail "missing schema"

yq -o=json '.' "$CATALOG" >"$TMPROOT/catalog.json" || fail "catalog is not valid YAML"
if command -v check-jsonschema >/dev/null 2>&1; then
  check-jsonschema --schemafile "$SCHEMA" "$TMPROOT/catalog.json" >/dev/null || fail "catalog failed schema validation"
fi

jq -e '
  .schema_version == 1
  and .kind == "studio-v2-rule-pack-catalog"
  and .budget_policy.always_loaded_budget_tokens == 700
  and .budget_policy.per_pack_summary_budget_tokens == 180
  and .matching_policy.argus_frontmatter_compatible == true
' "$TMPROOT/catalog.json" >/dev/null || fail "catalog envelope or budget policy invalid"

for anchor in \
  '<!-- rule-pack-contract:argus-compatibility -->' \
  '<!-- rule-pack-contract:required-files -->' \
  '<!-- rule-pack-contract:applicability-predicates -->' \
  '<!-- rule-pack-contract:budgets-and-triggers -->' \
  '<!-- rule-pack-contract:versioning-deprecation -->' \
  '<!-- rule-pack-contract:taxonomy -->'
do
  contains "$anchor"
done

for required in \
  summary_path \
  full_doc_path \
  metadata_path \
  owner \
  applicability \
  enforcement_policy \
  enforcement_hooks \
  fixture_refs
do
  contains "$required"
done

for family in \
  role \
  phase \
  manifest \
  touched_surface \
  language_platform \
  release_job \
  build_test_job \
  review_debug_mode
do
  jq -e --arg family "$family" '.predicate_families | index($family)' "$TMPROOT/catalog.json" >/dev/null \
    || fail "missing predicate family: $family"
done

expected_packs='[
  "git-workflow",
  "source-branch-integration",
  "ios-artifacts",
  "worker-routing",
  "telemetry",
  "cleanup-retention",
  "release-routing",
  "privacy",
  "review"
]'
jq -e --argjson expected "$expected_packs" '
  ([.packs[].id] | sort) == ($expected | sort)
' "$TMPROOT/catalog.json" >/dev/null || fail "initial taxonomy pack set changed"

jq -e '
  ([.packs[].id] | unique | length) == (.packs | length)
  and all(.packs[];
    (.applicability | has("any_of") and has("all_of") and has("none_of"))
    and (.enforcement_policy | has("script_enforced") and has("llm_reviewed") and has("override_env"))
    and (.enforcement_hooks | length > 0)
    and (.fixture_refs | length > 0)
    and (.summary_path | length > 0)
    and (.full_doc_path | length > 0)
    and (.metadata_path | length > 0)
  )
' "$TMPROOT/catalog.json" >/dev/null || fail "pack metadata completeness invalid"

while IFS= read -r path; do
  [ -e "$ROOT/$path" ] || fail "declared path does not exist: $path"
done < <(
  jq -r '
    .packs[]
    | .summary_path,
      .full_doc_path,
      .metadata_path,
      (.enforcement_hooks[]),
      (.fixture_refs[])
  ' "$TMPROOT/catalog.json"
)

summary_budget=$(jq -r '.budget_policy.per_pack_summary_budget_tokens' "$TMPROOT/catalog.json")
while IFS= read -r path; do
  chars=$(wc -c < "$ROOT/$path" | tr -d ' ')
  estimated_tokens=$(( (chars + 3) / 4 ))
  [ "$estimated_tokens" -le "$summary_budget" ] || {
    fail "summary exceeds ${summary_budget}-token budget: $path (~${estimated_tokens})"
  }
done < <(jq -r '.packs[].summary_path' "$TMPROOT/catalog.json")

printf 'PASS: rule-pack metadata contract and catalog\n'
