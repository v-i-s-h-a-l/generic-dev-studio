#!/usr/bin/env bash
# lib-fixtures.sh — sourced library shared between verify-ledger.sh and the
# forthcoming scripts/replay-fixture.sh. Centralizes the "scrub + diff"
# primitives so fixture assertions stay identical regardless of caller.
#
# Exposes:
#   scrub_timestamps                   stdin → stdout: <TS> + <UUID> placeholders
#   fixture_root_for <slug>            repo-relative fixture directory
#   assert_yaml_equivalent <a> <b>     semantic YAML equality (via yq -o=json)
#   assert_events_multiset_equal <a> <b>  JSONL multisets match on tuple keys
#   diff_scrubbed <a> <b>              unified diff after scrubbing both sides
#
# No `set -e` — sourced into scripts that may or may not want strict mode.

FIXTURES_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
FIXTURES_REPO_ROOT=$(cd "$FIXTURES_LIB_DIR/.." && pwd)

# Replace RFC3339-ish timestamps and UUIDv7s with stable placeholders so
# fixture diffs don't churn on wall-clock + randomness. Case-sensitive by
# intent: schema values use lowercase hex for UUIDs, uppercase `T` / `Z` for
# timestamps — anything else is prose.
scrub_timestamps() {
  # First the timestamps (ISO8601 UTC, millis optional), then the UUIDs.
  # Two sed invocations keep each regex readable; single stream, no tmp file.
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
    -e 's/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/<UUID>/g'
}

fixture_root_for() {
  local slug="${1:?usage: fixture_root_for <slug>}"
  printf '%s\n' "$FIXTURES_REPO_ROOT/scripts/test-fixtures/$slug"
}

# Semantic YAML equality — normalize both sides to canonical JSON (sorted
# keys, no whitespace variance) before comparison. Exits 0 on equal, 1 on
# differing content, 2 on missing input. Requires `yq` on PATH.
assert_yaml_equivalent() {
  local a="${1:?assert_yaml_equivalent <a> <b>}"
  local b="${2:?}"
  [ -f "$a" ] || { printf 'assert_yaml_equivalent: missing %s\n' "$a" >&2; return 2; }
  [ -f "$b" ] || { printf 'assert_yaml_equivalent: missing %s\n' "$b" >&2; return 2; }
  if ! command -v yq >/dev/null 2>&1; then
    printf 'assert_yaml_equivalent: yq not on PATH\n' >&2
    return 2
  fi
  local ja jb
  ja=$(yq -o=json 'sort_keys(..)' "$a" 2>/dev/null) || return 2
  jb=$(yq -o=json 'sort_keys(..)' "$b" 2>/dev/null) || return 2
  [ "$ja" = "$jb" ]
}

# Multiset equality on (agent, event, task, idempotency_key) tuples. Two
# JSONL streams are equal iff the sorted tuple extracts match — order-
# independent, but event-count sensitive.
assert_events_multiset_equal() {
  local a="${1:?assert_events_multiset_equal <a> <b>}"
  local b="${2:?}"
  [ -f "$a" ] || { printf 'assert_events_multiset_equal: missing %s\n' "$a" >&2; return 2; }
  [ -f "$b" ] || { printf 'assert_events_multiset_equal: missing %s\n' "$b" >&2; return 2; }
  if ! command -v jq >/dev/null 2>&1; then
    printf 'assert_events_multiset_equal: jq not on PATH\n' >&2
    return 2
  fi
  local ta tb
  ta=$(jq -r '[.agent, .event, .task, (.idempotency_key // "")] | @tsv' "$a" 2>/dev/null | sort) || return 2
  tb=$(jq -r '[.agent, .event, .task, (.idempotency_key // "")] | @tsv' "$b" 2>/dev/null | sort) || return 2
  [ "$ta" = "$tb" ]
}

# Print unified diff of two files after scrubbing both sides. Exit 0 when
# byte-identical post-scrub, 1 otherwise.
diff_scrubbed() {
  local a="${1:?diff_scrubbed <a> <b>}"
  local b="${2:?}"
  [ -f "$a" ] || { printf 'diff_scrubbed: missing %s\n' "$a" >&2; return 2; }
  [ -f "$b" ] || { printf 'diff_scrubbed: missing %s\n' "$b" >&2; return 2; }
  local ta tb
  ta=$(mktemp); tb=$(mktemp)
  scrub_timestamps < "$a" > "$ta"
  scrub_timestamps < "$b" > "$tb"
  local rc=0
  if ! diff -u "$ta" "$tb"; then
    rc=1
  fi
  rm -f "$ta" "$tb"
  return "$rc"
}
