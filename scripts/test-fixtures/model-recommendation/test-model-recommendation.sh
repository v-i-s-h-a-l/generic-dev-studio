#!/usr/bin/env bash
# Verifies deterministic model tier recommendations.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

out=$("$ROOT/scripts/recommend-model.sh" --size xs --kind docs --cross-file-count 1 --novelty-score 0)
printf '%s' "$out" | grep -q '"best_result":{"tier":"haiku"' || {
  printf 'FAIL: mechanical docs task should recommend haiku\n' >&2
  printf '%s\n' "$out" >&2
  exit 1
}

out=$("$ROOT/scripts/recommend-model.sh" --size m --kind debug --cross-file-count 3 --novelty-score 2)
printf '%s' "$out" | grep -q '"best_result":{"tier":"opus"' || {
  printf 'FAIL: debug task should recommend opus\n' >&2
  printf '%s\n' "$out" >&2
  exit 1
}

out=$("$ROOT/scripts/recommend-model.sh" --size xs --kind impl --cross-file-count 1 --novelty-score 0 --preference fast_turnaround)
printf '%s' "$out" | grep -q '"selected":{"preference":"fast_turnaround","tier":"haiku"' || {
  printf 'FAIL: fast preference should select fast_turnaround recommendation\n' >&2
  printf '%s\n' "$out" >&2
  exit 1
}

printf 'PASS: model recommendation rule\n'
