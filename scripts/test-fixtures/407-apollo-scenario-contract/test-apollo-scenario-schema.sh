#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
VALID="$ROOT/tests/fixtures/apollo/scenarios/feed-scroll-cpu.yaml"
INVALID="$ROOT/tests/fixtures/apollo/scenarios/invalid-missing-signpost.yaml"
ERR="${TMPDIR:-/tmp}/apollo-scenario-invalid.$$"
trap 'rm -f "$ERR"' EXIT

"$ROOT/scripts/validate-contract.sh" apollo-scenario "$VALID"

if "$ROOT/scripts/validate-contract.sh" apollo-scenario "$INVALID" >"$ERR" 2>&1; then
  printf 'expected invalid scenario to fail validation\n' >&2
  exit 1
fi

printf 'PASS: Apollo scenario schema validation\n'
