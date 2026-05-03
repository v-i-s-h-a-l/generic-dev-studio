#!/usr/bin/env bash
# Regression test for the A0b durable event-log semantics spec.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SPEC="$ROOT/core/EVENT-LOG-SEMANTICS.md"
ROADMAP="$ROOT/ROADMAP.md"
ARCH="$ROOT/ARCHITECTURE.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$SPEC" ] || fail "missing core/EVENT-LOG-SEMANTICS.md"

for heading in \
  "## Ordering Semantics" \
  "## Dedupe Semantics" \
  "## Replay Semantics" \
  "## Lock Semantics" \
  "## Backpressure Semantics" \
  "## Relationship to Existing Contracts" \
  "## Validation Invariants for A0.6"
do
  grep -Fq "$heading" "$SPEC" || fail "missing heading: $heading"
done

for required in \
  "_shared/contracts/events.md" \
  "_shared/contracts/event-emission.md" \
  "_shared/contracts/idempotency.md" \
  "at-least-once" \
  "(shard_date, byte_offset)" \
  "no central write lock" \
  "subscriber lag"
do
  grep -Fq "$required" "$SPEC" || fail "missing required term: $required"
done

grep -Fq "core/EVENT-LOG-SEMANTICS.md" "$ROADMAP" || fail "ROADMAP missing event-log semantics link"
grep -Fq "core/EVENT-LOG-SEMANTICS.md" "$ARCH" || fail "ARCHITECTURE missing event-log semantics link"

printf 'PASS: event-log semantics spec anchors present\n'
