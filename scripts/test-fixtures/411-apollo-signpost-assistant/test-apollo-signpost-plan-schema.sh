#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/tests/fixtures/apollo/signpost-plans"

"$ROOT/scripts/validate-contract.sh" apollo-signpost-plan "$DIR/feed-scroll-cpu.yaml"
"$ROOT/scripts/validate-contract.sh" apollo-signpost-plan "$DIR/multi-mode.yaml"

if "$ROOT/scripts/validate-contract.sh" apollo-signpost-plan "$DIR/invalid-private-required.yaml" >/dev/null 2>&1; then
  printf 'expected invalid signpost plan to fail validation\n' >&2
  exit 1
fi

printf 'PASS: Apollo signpost plan schema validation\n'
