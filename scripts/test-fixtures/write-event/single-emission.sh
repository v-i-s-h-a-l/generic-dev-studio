#!/usr/bin/env bash
# single-emission.sh — regression test for the event-log double-emission bug.
#
# Regression guarded:
#   Between 2026-04-17 and 2026-04-21, ~/.dev-studio/<project>/events/*.jsonl
#   exhibited a ~50% duplicate-emission rate: every event landing twice with
#   identical ts + payload. Day counts for turnip-ios:
#     04-17 24/12 (50%), 04-18 187/99 (47%), 04-19 24/12 (50%),
#     04-20 156/78 (50%), 04-21 120/60 (50%), 04-22 48/46 (4%), 04-23 25/25 (0%).
#
#   Root cause (commit 1528e0a, "Phase 2.6 followup (#69): canonical event-log
#   root for writer + readers"): resolve_event_log() returned the legacy
#   ~/.claude/projects/<slug>/memory/events/ path, diverging from the post-2.6
#   canonical ~/.dev-studio/<project>/events/ used by readers + migrate-ledger.
#   The cutover period had both sinks in play, so a single logical emission
#   landed in two places and downstream aggregators double-counted.
#
#   The fix routes resolve_event_log at ~/.dev-studio/<project>/events/
#   exclusively. This test pins that invariant: one CLI invocation of
#   write-event.sh must produce exactly one line in exactly one canonical log.
#
# Assertions:
#   1. write-event.sh writes to $HOME/.dev-studio/<slug>/events/<date>.jsonl
#      (canonical path; NOT $HOME/.claude/projects/<slug>/memory/events/).
#   2. One invocation produces exactly one line in the canonical log.
#   3. The legacy path ~/.claude/projects/<slug>/memory/events/ is NOT written.
#   4. Ten invocations with distinct payloads produce exactly ten distinct lines
#      (no silent dup amplification).
#   5. Ten invocations with the SAME idem-key still physically append ten times
#      (writer is append-only; dedupe is a reader concern — dedupe responsibility
#      belongs to read-events.sh). This pins the separation of concerns that
#      kept the bug latent: if the writer ever starts deduping, the reader's
#      dedupe layer masks future writer double-emissions. Keep the writer dumb.
#
# Exit 0 on pass, 1 on any assertion failure.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

TMPROOT=$(mktemp -d -t write-event-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Sandbox: override HOME so the script writes into the tempdir, and pin the
# project slug so resolve_project() doesn't consult git-toplevel.
export HOME="$TMPROOT"
export ACHILLES_PROJECT="test-project"

CANONICAL_DIR="$HOME/.dev-studio/$ACHILLES_PROJECT/events"
LEGACY_DIR="$HOME/.claude/projects/-synthetic-slug/memory/events"
TODAY=$(date -u +%Y-%m-%d)
CANONICAL_LOG="$CANONICAL_DIR/$TODAY.jsonl"

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

# ---- 1. Single invocation lands in canonical path ----

"$REPO_SCRIPTS/write-event.sh" \
  --agent achilles \
  --event test_emission \
  --task T-REGRESSION-001 \
  --data '{"note":"single-emission"}' \
  --mode task \
  >/dev/null

assert "canonical log exists after one emission" \
  "[ -f '$CANONICAL_LOG' ]"

# ---- 2. Exactly one line in canonical log ----

line_count=$(wc -l < "$CANONICAL_LOG" | tr -d ' ')
assert "one emission => exactly one line (got $line_count)" \
  "[ '$line_count' -eq 1 ]"

# ---- 3. Legacy path MUST NOT be written ----

assert "legacy ~/.claude/projects/*/memory/events/ is NOT written" \
  "[ ! -d '$LEGACY_DIR' ]"

# Broader check: no .jsonl anywhere under ~/.claude/ (defensive; any future
# regression that re-introduces a dual-sink would put files there).
stray=$(find "$HOME/.claude" -type f -name '*.jsonl' 2>/dev/null | head -1 || true)
assert "no stray .jsonl under ~/.claude (writer must not dual-sink)" \
  "[ -z '$stray' ]"

# ---- 4. Distinct-payload emissions: no dup amplification ----

rm -f "$CANONICAL_LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
  "$REPO_SCRIPTS/write-event.sh" \
    --agent achilles \
    --event test_distinct \
    --task "T-REG-$i" \
    --data "{\"seq\":$i}" \
    --mode task \
    >/dev/null
done

line_count=$(wc -l < "$CANONICAL_LOG" | tr -d ' ')
assert "10 distinct emissions => 10 lines (got $line_count)" \
  "[ '$line_count' -eq 10 ]"

distinct_tasks=$(grep -o '"task":"T-REG-[0-9]*"' "$CANONICAL_LOG" | sort -u | wc -l | tr -d ' ')
assert "10 distinct task ids recorded (got $distinct_tasks)" \
  "[ '$distinct_tasks' -eq 10 ]"

# ---- 5. Same idem-key: writer still appends; dedupe is a reader concern ----

rm -f "$CANONICAL_LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
  "$REPO_SCRIPTS/write-event.sh" \
    --agent achilles \
    --event test_idem \
    --task T-REG-IDEM \
    --data '{"note":"same"}' \
    --mode task \
    --idem-key "stable-key" \
    >/dev/null
done

line_count=$(wc -l < "$CANONICAL_LOG" | tr -d ' ')
assert "10 same-idem emissions => 10 physical lines (writer is append-only; got $line_count)" \
  "[ '$line_count' -eq 10 ]"

# Verify reader-side dedupe collapses these to 1.
if [ -x "$REPO_SCRIPTS/read-events.sh" ]; then
  deduped=$("$REPO_SCRIPTS/read-events.sh" --project "$ACHILLES_PROJECT" --event test_idem 2>/dev/null | wc -l | tr -d ' ')
  assert "reader-side dedupe collapses 10 same-idem lines to 1 (got $deduped)" \
    "[ '$deduped' -eq 1 ]"
fi

printf 'PASS: %d assertions\n' "$assertions"
exit 0
