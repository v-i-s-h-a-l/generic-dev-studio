#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SCHEMA="$ROOT/_shared/schemas/release.md"
LIFECYCLE="$ROOT/_shared/state-machines/release-lifecycle.md"
CONTRACT="$ROOT/_shared/contracts/release-tf-push.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'release@1.3.0' "$SCHEMA" || fail "release schema version was not bumped"
grep -Fq 'withdrawn' "$SCHEMA" || fail "schema does not document withdrawn state"
grep -Fq 'superseded' "$SCHEMA" || fail "schema does not document superseded state"
grep -Fq 'replaces' "$SCHEMA" || fail "schema does not document replacement forward pointer"
grep -Fq 'superseded_by' "$SCHEMA" || fail "schema does not document replacement back pointer"

grep -Fq 'submitted             → withdrawn' "$LIFECYCLE" || fail "missing submitted to withdrawn transition"
grep -Fq 'released              → superseded' "$LIFECYCLE" || fail "missing released to superseded transition"
grep -Fq '[WITHDRAWN] <tag>' "$LIFECYCLE" || fail "missing GitHub release withdrawal title convention"
grep -Fq 'Do not start a new top-level announcement' "$LIFECYCLE" || fail "missing announcement-thread continuity rule"

grep -Fq 'Rename the GitHub Release title to `[WITHDRAWN] <tag>`' "$CONTRACT" || fail "TF contract missing withdrawn GitHub release convention"
grep -Fq 'Do not start a new top-level' "$CONTRACT" || fail "TF contract missing replacement announcement continuity"
grep -Fq 'Hotfix replacement workflow' "$CONTRACT" || fail "TF contract missing dedicated hotfix replacement workflow"

printf 'PASS: release replacement lifecycle contract\n'
