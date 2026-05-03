#!/usr/bin/env bash
# Verifies the Studio v2 iOS skill catalog names the current vendored iOS profile.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CATALOG="$ROOT/core/v2/skills/ios/catalog.yaml"
SCHEMA="$ROOT/core/v2/schemas/ios-skill-catalog.schema.json"
PROFILE="$ROOT/recipes/profiles/ios.yaml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

[ -f "$CATALOG" ] || fail "missing catalog: $CATALOG"
[ -f "$SCHEMA" ] || fail "missing schema: $SCHEMA"
[ -f "$PROFILE" ] || fail "missing profile: $PROFILE"

jq -e 'has("$schema") and .type == "object"' "$SCHEMA" >/dev/null \
  || fail "schema is not a JSON object schema"

[ "$(yq -r '.schema_version.name' "$CATALOG")" = "ios-skill-catalog" ] \
  || fail "unexpected schema name"
[ "$(yq -r '.parent_issue' "$CATALOG")" = "444" ] \
  || fail "parent issue is not #444"
[ "$(yq -r '.leaf_issue' "$CATALOG")" = "520" ] \
  || fail "leaf issue is not #520"
[ "$(yq -r '.catalog_policy.routing_authority' "$CATALOG")" = "advisory" ] \
  || fail "routing authority must stay advisory"
[ "$(yq -r '.catalog_policy.host_registry_mutation' "$CATALOG")" = "forbidden" ] \
  || fail "catalog must not mutate host registries"

profile_recipes=$(mktemp -t ios-profile-recipes.XXXXXX)
catalog_ids=$(mktemp -t ios-catalog-ids.XXXXXX)
trap 'rm -f "$profile_recipes" "$catalog_ids"' EXIT

yq -r '.recipes[]' "$PROFILE" | sort > "$profile_recipes"
yq -r '.skills[].id' "$CATALOG" | sort > "$catalog_ids"
diff -u "$profile_recipes" "$catalog_ids" >/dev/null \
  || fail "catalog ids differ from recipes/profiles/ios.yaml"

while IFS= read -r skill; do
  skill_path=$(yq -r '.skills[] | select(.id == "'"$skill"'") | .skill_path' "$CATALOG")
  recipe_path=$(yq -r '.skills[] | select(.id == "'"$skill"'") | .recipe_path' "$CATALOG")
  vendor_path=$(yq -r '.skills[] | select(.id == "'"$skill"'") | .vendor_path' "$CATALOG")
  portability_path=$(yq -r '.skills[] | select(.id == "'"$skill"'") | .portability_path' "$CATALOG")
  [ -f "$ROOT/$skill_path" ] || fail "$skill missing skill_path: $skill_path"
  [ -f "$ROOT/$recipe_path" ] || fail "$skill missing recipe_path: $recipe_path"
  [ -f "$ROOT/$vendor_path" ] || fail "$skill missing vendor_path: $vendor_path"
  [ -f "$ROOT/$portability_path" ] || fail "$skill missing portability_path: $portability_path"

  catalog_sha=$(yq -r '.skills[] | select(.id == "'"$skill"'") | .source.pinned_sha' "$CATALOG")
  vendor_sha=$(yq -r '.pinned_sha' "$ROOT/$vendor_path")
  recipe_sha=$(yq -r '.sources[0].pinned_sha' "$ROOT/$recipe_path")
  [ "$catalog_sha" = "$vendor_sha" ] || fail "$skill catalog/vendor SHA mismatch"
  [ "$catalog_sha" = "$recipe_sha" ] || fail "$skill catalog/recipe SHA mismatch"
done < "$catalog_ids"

printf 'PASS: iOS skill catalog\n'
