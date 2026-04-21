#!/usr/bin/env bash
# partition-merge.sh — fixture-based unit test for
# scripts/write-shared.sh + scripts/read-shared.sh + scripts/machine-id.sh.
#
# Exercises the contract in _shared/patterns/multi-machine-sync.md §Rules:
#   1. Partitioned by writer — write never crosses partition boundary.
#   2. Append-only / atomic rename within a partition.
#   3. Union at read-time (disjoint partitions merge cleanly).
#   4. Stable total order by (occurred_at, machine-id).
#   5. Conflict-free — even with matching timestamps across partitions.
#
# Runs against temp dirs; never touches ~/.dev-studio/. Exit 0 on pass, 1 on
# any assertion failure.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)
export PATH="$REPO_SCRIPTS:$PATH"

TMPROOT=$(mktemp -d -t sync-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export DEV_STUDIO_SHARED_ROOT="$TMPROOT/shared"

assertions=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then
    fail "$1 — failed: $2"
  fi
}

# Simulate two machines via two DEV_STUDIO_MACHINE_ID_FILE overrides. Pre-seed
# each with a distinct UUID so tests are hermetic.
M_A="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
M_B="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ID_FILE_A="$TMPROOT/machine-id-A"
ID_FILE_B="$TMPROOT/machine-id-B"
printf '%s\n' "$M_A" > "$ID_FILE_A"
printf '%s\n' "$M_B" > "$ID_FILE_B"

# --- Rule 1 + 2: write lands only in self-partition; atomic rename. ---
DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" feedback/F-0001.json '{"occurred_at":"2026-04-22T10:00:00Z","id":"F-0001","from":"A"}' >/dev/null

assert "rule 1/2: file lands in A's partition" \
  "[ -f '$TMPROOT/shared/$M_A/feedback/F-0001.json' ]"
assert "rule 1/2: file does NOT leak into B's partition" \
  "[ ! -e '$TMPROOT/shared/$M_B/feedback/F-0001.json' ]"

DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_B" \
  "$REPO_SCRIPTS/write-shared.sh" feedback/F-0002.json '{"occurred_at":"2026-04-22T11:00:00Z","id":"F-0002","from":"B"}' >/dev/null

assert "rule 1: B's write does NOT leak into A's partition" \
  "[ ! -e '$TMPROOT/shared/$M_A/feedback/F-0002.json' ]"

# --- Rule 3: read-time union across partitions with disjoint keys. ---
list_out=$(DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/read-shared.sh" --list feedback | sort)
assert "rule 3: --list shows F-0001 file (from A)" \
  "printf '%s' '$list_out' | grep -q '/$M_A/feedback/F-0001.json'"
assert "rule 3: --list shows F-0002 file (from B)" \
  "printf '%s' '$list_out' | grep -q '/$M_B/feedback/F-0002.json'"

# --- Rule 4: stable order by occurred_at for jsonl streams. ---
DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" --append events.jsonl \
  '{"ts":"2026-04-22T10:00:00Z","agent":"achilles","event":"task_started","task":"T001","data":{},"producer":{"agent":"achilles","mode":"task","instance_id":"A-1"}}' >/dev/null

DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_B" \
  "$REPO_SCRIPTS/write-shared.sh" --append events.jsonl \
  '{"ts":"2026-04-22T11:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T002","data":{},"producer":{"agent":"chanakya","mode":"brief","instance_id":"B-1"}}' >/dev/null

DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" --append events.jsonl \
  '{"ts":"2026-04-22T12:00:00Z","agent":"achilles","event":"task_completed","task":"T001","data":{},"producer":{"agent":"achilles","mode":"task","instance_id":"A-1"}}' >/dev/null

read_out=$(DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/read-shared.sh" events.jsonl)

line_count=$(printf '%s\n' "$read_out" | sed '/^$/d' | wc -l | tr -d ' ')
assert "rule 3: read returns all 3 events (A's 2 + B's 1)" \
  "[ '$line_count' -eq 3 ]"

ts_list=$(printf '%s\n' "$read_out" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
sorted_ts=$(printf '%s\n' "$ts_list" | sort)
assert "rule 4: stream is sorted by ts ascending" \
  "[ '$ts_list' = '$sorted_ts' ]"
first_ts=$(printf '%s\n' "$ts_list" | head -n 1)
assert "rule 4: first ts is A's 10:00" \
  "[ '$first_ts' = '2026-04-22T10:00:00Z' ]"

# --- Rule 4: tiebreaker on matching ts. ---
DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_B" \
  "$REPO_SCRIPTS/write-shared.sh" --append events.jsonl \
  '{"ts":"2026-04-22T10:00:00Z","agent":"chanakya","event":"tie","task":"T003","data":{},"producer":{"agent":"chanakya","mode":"brief","instance_id":"B-tie"}}' >/dev/null

read_out2=$(DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/read-shared.sh" events.jsonl)
first_two=$(printf '%s\n' "$read_out2" | sed -n '1,2p' | sed -n 's/.*"instance_id":"\([^"]*\)".*/\1/p')
first=$(printf '%s\n' "$first_two" | sed -n '1p')
second=$(printf '%s\n' "$first_two" | sed -n '2p')
assert "rule 4 tiebreaker: A's event precedes B's on matching ts" \
  "[ '$first' = 'A-1' ] && [ '$second' = 'B-tie' ]"

# --- Rule 5: conflict-free. Two writers with the same logical path in
# different partitions do NOT overwrite each other. ---
DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" notes/shared.txt 'A version' >/dev/null
DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_B" \
  "$REPO_SCRIPTS/write-shared.sh" notes/shared.txt 'B version' >/dev/null

a_content=$(cat "$TMPROOT/shared/$M_A/notes/shared.txt")
b_content=$(cat "$TMPROOT/shared/$M_B/notes/shared.txt")
assert "rule 5: A's notes/shared.txt retained A's content" \
  "[ '$a_content' = 'A version' ]"
assert "rule 5: B's notes/shared.txt retained B's content" \
  "[ '$b_content' = 'B version' ]"

# --- Security / path guard: traversal is rejected. ---
if DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" ../escape 'bad' >/dev/null 2>&1; then
  fail "path-guard: traversal should be rejected"
fi
if DEV_STUDIO_MACHINE_ID_FILE="$ID_FILE_A" \
  "$REPO_SCRIPTS/write-shared.sh" /absolute 'bad' >/dev/null 2>&1; then
  fail "path-guard: absolute path should be rejected"
fi
assertions=$((assertions + 2))

printf 'PASS: %d assertions\n' "$assertions"
