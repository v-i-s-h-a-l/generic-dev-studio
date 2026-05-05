#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONTRACT="$ROOT/_shared/contracts/engineering-principles.md"

[ -f "$CONTRACT" ] || {
  printf 'missing engineering principles contract\n' >&2
  exit 1
}

for required in \
  'Prefer root-cause fixes over local bandages.' \
  'Convert vague work into measurable acceptance criteria' \
  'Split L-sized implementation work into S or M leaf tasks' \
  'Treat verification as part of implementation.' \
  'Challenge/refine notes' \
  'Root-cause notes for bug fixes and non-trivial changes.' \
  'Reviewer verdicts can evaluate against this contract' \
  'Verification Matrix'; do
  grep -F "$required" "$CONTRACT" >/dev/null || {
    printf 'engineering principles contract missing required phrase: %s\n' "$required" >&2
    exit 1
  }
done

for role in manager worker reviewer; do
  grep -F '_shared/contracts/engineering-principles.md' "$ROOT/core/v2/roles/$role.yaml" >/dev/null || {
    printf '%s role does not reference engineering principles contract\n' "$role" >&2
    exit 1
  }
done

printf 'PASS: engineering principles contract\n'
