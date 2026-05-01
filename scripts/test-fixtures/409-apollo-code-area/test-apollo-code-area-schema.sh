#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/tests/fixtures/apollo/code-area"

for fixture in symbolicated unsymbolicated framework-owned swiftui imgly-metal; do
  "$ROOT/scripts/validate-contract.sh" apollo-code-area "$DIR/$fixture.yaml"
done

if "$ROOT/scripts/validate-contract.sh" apollo-code-area "$DIR/invalid-unsymbolicated-guess.yaml" >/dev/null 2>&1; then
  printf 'expected unsymbolicated source guess to fail validation\n' >&2
  exit 1
fi

if "$ROOT/scripts/validate-contract.sh" apollo-code-area "$DIR/invalid-unsymbolicated-candidate.yaml" >/dev/null 2>&1; then
  printf 'expected unsymbolicated source guess to fail validation\n' >&2
  exit 1
fi

printf 'PASS: Apollo code-area schema validation\n'
