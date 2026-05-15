#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_contains() {
  file="$1"
  needle="$2"
  reason="$3"
  grep -Fq -- "$needle" "$ROOT/$file" || fail "$file missing $reason: $needle"
}

require_absent() {
  file="$1"
  needle="$2"
  reason="$3"
  if grep -Fq -- "$needle" "$ROOT/$file"; then
    fail "$file must not claim $reason: $needle"
  fi
}

for file in README.md scripts/README.md core/v2/skills/dev-studio/SKILL.md; do
  require_contains "$file" 'manager composite-chain init --manifest' "explicit composite manifest init"
  require_contains "$file" 'status --run-id' "non-mutating composite status"
  require_contains "$file" 'resume --run-id' "composite resume command shape"
  require_contains "$file" 'natural-language extraction' "non-MVP parent text extraction warning"
  require_contains "$file" 'future/non-MVP' "future composite-parent warning"
  require_contains "$file" 'plan review' "existing gate preservation"
  require_contains "$file" 'PR review/merge policy' "PR gate preservation"
done

require_contains README.md "work-chain --composite-manifest <file>" "selected composite-manifest equivalent"
require_contains scripts/README.md "work-chain --composite-manifest <file>" "selected composite-manifest equivalent"
require_contains core/v2/skills/dev-studio/SKILL.md "work-chain --composite-manifest <file>" "router selected composite-manifest equivalent"
require_contains core/v2/skills/dev-studio/routing.yaml '/dev-studio manager composite-chain init --manifest' "routing trigger for composite init"
require_contains core/v2/skills/dev-studio/routing.yaml '/dev-studio manager composite-chain resume' "routing trigger for composite resume"

for file in README.md scripts/README.md core/v2/skills/dev-studio/SKILL.md; do
  require_absent "$file" 'children can run in parallel' "parallel composite execution"
  require_absent "$file" 'children may run in parallel' "parallel composite execution"
done

printf 'PASS: composite chain docs\n'
