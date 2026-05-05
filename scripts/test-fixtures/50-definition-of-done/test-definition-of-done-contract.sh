#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONTRACT="$ROOT/_shared/contracts/definition-of-done.md"

[ -f "$CONTRACT" ] || {
  printf 'missing definition-of-done contract\n' >&2
  exit 1
}

for required in \
  'Tests or equivalent verification.' \
  'Accessibility impact.' \
  'Localization impact.' \
  'Performance impact.' \
  'Analytics or telemetry impact.' \
  'Feature flag or rollout impact.' \
  'Changelog trailer.' \
  'Changelog: <release-note bullet>' \
  'Changelog: none (internal-only)'; do
  grep -F "$required" "$CONTRACT" >/dev/null || {
    printf 'definition-of-done contract missing required phrase: %s\n' "$required" >&2
    exit 1
  }
done

grep -F '_shared/contracts/definition-of-done.md' "$ROOT/core/v2/roles/worker.yaml" >/dev/null || {
  printf 'worker role does not reference definition-of-done contract\n' >&2
  exit 1
}

grep -F '_shared/contracts/definition-of-done.md' "$ROOT/core/v2/roles/release-manager.yaml" >/dev/null || {
  printf 'release-manager role does not reference definition-of-done contract\n' >&2
  exit 1
}

grep -F 'Changelog:' "$ROOT/RELEASES.md" >/dev/null || {
  printf 'RELEASES.md does not mention Changelog trailers\n' >&2
  exit 1
}

printf 'PASS: definition-of-done contract\n'
