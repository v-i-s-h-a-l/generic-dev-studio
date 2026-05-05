#!/usr/bin/env bash
# Verifies the shared completion-summary convention is wired into role contracts.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONTRACT="$ROOT/_shared/contracts/completion-summary.md"

[ -f "$CONTRACT" ] || {
  printf 'missing completion summary contract\n' >&2
  exit 1
}

for required in \
  'We fixed/implemented' \
  'Impact on user:' \
  'Behavior before:' \
  'Behavior after:' \
  'New behavior:' \
  'PR/merge state:' \
  'Local sync state:' \
  'Worktree cleanup:' \
  'Derived data and stale artifacts:' \
  'Safe to end the session.' \
  'Not safe to end the session yet:'; do
  grep -F "$required" "$CONTRACT" >/dev/null || {
    printf 'completion summary contract missing required phrase: %s\n' "$required" >&2
    exit 1
  }
done

for role in manager worker reviewer; do
  grep -F '_shared/contracts/completion-summary.md' "$ROOT/core/v2/roles/$role.yaml" >/dev/null || {
    printf '%s role does not reference completion-summary contract\n' "$role" >&2
    exit 1
  }
done

grep -F '_shared/contracts/completion-summary.md' "$ROOT/_shared/contracts/debrief-format.md" >/dev/null || {
  printf 'debrief format does not reference completion-summary contract\n' >&2
  exit 1
}

printf 'PASS: completion summary contract\n'
