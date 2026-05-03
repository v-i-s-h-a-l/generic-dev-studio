#!/usr/bin/env bash
# Regression test for the A0c auth and permissions model spec.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SPEC="$ROOT/core/AUTH-PERMISSIONS.md"
ROADMAP="$ROOT/ROADMAP.md"
ARCH="$ROOT/ARCHITECTURE.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$SPEC" ] || fail "missing core/AUTH-PERMISSIONS.md"

for heading in \
  "## GitHub Auth" \
  "## Local Tool Boundaries" \
  "## Sub-Agent Boundaries" \
  "## Release-Action Scopes" \
  "## Failure Semantics" \
  "## Permission Manifest Inputs" \
  "## Validation Invariants for A0.6"
do
  grep -Fq "$heading" "$SPEC" || fail "missing heading: $heading"
done

for required in \
  "scripts/studio-gh.sh" \
  "scripts/phase-review.sh" \
  "hosts/ADAPTER-SPEC.md" \
  "_shared/contracts/release-tf-push.md" \
  "secret scopes" \
  "mutation scopes" \
  "Reviewer roles default to no-secret" \
  "Silent no-ops are forbidden" \
  "unsupported" \
  "unknown" \
  "partial"
do
  grep -Fq "$required" "$SPEC" || fail "missing required term: $required"
done

grep -Fq "core/AUTH-PERMISSIONS.md" "$ROADMAP" || fail "ROADMAP missing auth permissions link"
grep -Fq "core/AUTH-PERMISSIONS.md" "$ARCH" || fail "ARCHITECTURE missing auth permissions link"

printf 'PASS: auth permissions spec anchors present\n'
