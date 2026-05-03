#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LOADER="$ROOT/scripts/v2-skill-load.sh"
SCHEMA="$ROOT/core/v2/schemas/vendored-skill-artifact.schema.json"
TMPROOT=$(mktemp -d -t vendored-skill-loader-518.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$LOADER" ] || fail "loader is not executable"
[ -f "$SCHEMA" ] || fail "missing vendored skill artifact schema"
jq -e '.["$schema"] and .type == "object"' "$SCHEMA" >/dev/null || fail "schema is not a JSON schema"

artifact=$("$LOADER" swift-concurrency-pro)
if command -v check-jsonschema >/dev/null 2>&1; then
  printf '%s\n' "$artifact" > "$TMPROOT/artifact.json"
  check-jsonschema --schemafile "$SCHEMA" "$TMPROOT/artifact.json" >/dev/null || fail "artifact failed JSON Schema validation"
fi
printf '%s\n' "$artifact" | jq -e '
  .schema_version == 1 and
  .kind == "studio-v2-vendored-skill-artifact" and
  .parent_issue == 444 and
  .leaf_issue == 518 and
  .skill.name == "swift-concurrency-pro" and
  (.source.pinned_sha | test("^[0-9a-f]{40}$")) and
  .paths.skill_md == "skills/vendored/twostraws/swift-concurrency-pro/SKILL.md" and
  (.portability.hosts | index("all")) and
  .portability.scope == "global"
' >/dev/null || fail "json artifact did not match expected contract"

[ "$("$LOADER" --format path swift-concurrency-pro)" = "skills/vendored/twostraws/swift-concurrency-pro/SKILL.md" ] || fail "path format did not return SKILL.md"
"$LOADER" --format prompt swift-concurrency-pro | grep -Fq 'Review Swift concurrency code' || fail "prompt format did not strip frontmatter and emit body"
"$LOADER" --list --format text | grep -Fxq 'swift-concurrency-pro' || fail "list output omitted known skill"

mkdir -p "$TMPROOT/skills/vendored/example/bad-skill"
cat > "$TMPROOT/skills/vendored/example/bad-skill/SKILL.md" <<'SKILL'
---
name: bad-skill
description: Bad fixture.
license: MIT
metadata:
  version: "1.0"
---
Bad fixture.
SKILL
cat > "$TMPROOT/skills/vendored/example/bad-skill/vendor.yaml" <<'YAML'
schema_version: 1
recipe: bad-skill
strategy: verbatim
upstream: example.invalid/bad-skill
path: bad-skill/
pinned_sha: not-a-sha
license: MIT
vendored_at: 2026-05-03T00:00:00Z
YAML
cat > "$TMPROOT/skills/vendored/example/bad-skill/portability.yaml" <<'YAML'
schema_version: 1
hosts:
  - all
scope: global
YAML

if "$LOADER" --root "$TMPROOT" bad-skill >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  fail "bad pinned_sha resolved successfully"
fi
grep -Fq 'pinned_sha must be a 40-character lowercase git SHA' "$TMPROOT/bad.err" || fail "bad pinned_sha error was not explicit"

if "$LOADER" definitely-missing-skill >"$TMPROOT/missing.out" 2>"$TMPROOT/missing.err"; then
  fail "missing skill resolved successfully"
fi
grep -Fq 'unknown vendored skill' "$TMPROOT/missing.err" || fail "missing skill error was not explicit"

printf 'PASS: vendored skill loader and version pinning\n'
