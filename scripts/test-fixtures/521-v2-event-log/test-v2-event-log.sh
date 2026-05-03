#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/v2-event-log.sh"
TMPROOT=$(mktemp -d -t v2-event-log-521.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "v2-event-log.sh is not executable"

RUNTIME="$TMPROOT/runtime"
mkdir -p "$RUNTIME"

"$RUN" append --runtime-root "$RUNTIME" --quiet --event-json '{"schema_version":1,"event":"task_state_changed","occurred_at":"2026-05-03T00:00:00Z","producer":{"agent":"worker"},"idempotency_key":"task-1","writable_action":true,"data":{"state":"done"}}'
"$RUN" append --runtime-root "$RUNTIME" --quiet --event-json '{"schema_version":1,"event":"task_state_changed","occurred_at":"2026-05-03T00:00:01Z","producer":{"agent":"worker"},"idempotency_key":"task-1","writable_action":true,"data":{"state":"done-duplicate"}}'
"$RUN" append --runtime-root "$RUNTIME" --quiet --event-json '{"schema_version":1,"event":"observation","occurred_at":"2026-05-03T00:00:02Z","producer":{"agent":"manager"},"data":{"note":"no key passes through"}}'

OUT="$TMPROOT/replay.out"
"$RUN" replay --runtime-root "$RUNTIME" --subscriber indexer > "$OUT"

[ "$(wc -l < "$OUT" | tr -d ' ')" = 2 ] || fail "replay should emit first keyed event plus unkeyed observation"
jq -e 'select(.event == "task_state_changed" and .data.state == "done" and .replay.byte_offset == 0)' "$OUT" >/dev/null || fail "first keyed event was not replayed with byte offset"
if jq -e 'select(.data.state == "done-duplicate")' "$OUT" >/dev/null; then
  fail "duplicate idempotency key was replayed"
fi
jq -e '.subscriber == "indexer" and .shard == "2026-05-03.jsonl" and .next_byte_offset > 0' "$RUNTIME/.runtime/v2/subscribers/indexer.checkpoint.json" >/dev/null || fail "checkpoint was not written"

SECOND="$TMPROOT/replay-second.out"
"$RUN" replay --runtime-root "$RUNTIME" --subscriber indexer > "$SECOND"
[ ! -s "$SECOND" ] || fail "second replay should be empty from checkpoint"

printf '{not-json}\n' >> "$RUNTIME/events/2026-05-03.jsonl"
"$RUN" replay --runtime-root "$RUNTIME" --subscriber dlq --malformed dead-letter --quiet
find "$RUNTIME/.runtime/v2/dead-letter/dlq" -type f -name '*.json' | grep -q . || fail "malformed line did not create dead letter"

LAG="$TMPROOT/lag.json"
"$RUN" lag --runtime-root "$RUNTIME" --subscriber fresh --warning-bytes 1 --critical-bytes 999999 --write-status > "$LAG"
jq -e '.subscriber == "fresh" and .pending_bytes > 0 and .severity == "warning" and .oldest_unprocessed_shard == "2026-05-03.jsonl"' "$LAG" >/dev/null || fail "lag status did not classify warning"
[ -f "$RUNTIME/.runtime/v2/subscribers/fresh.lag.json" ] || fail "lag status artifact was not written"

EMPTY_LAG="$TMPROOT/empty-lag"
mkdir -p "$EMPTY_LAG"
"$RUN" lag --runtime-root "$EMPTY_LAG" --subscriber empty --write-status > "$TMPROOT/empty-lag.json"
jq -e '.subscriber == "empty" and .pending_bytes == 0 and .severity == "ok"' "$TMPROOT/empty-lag.json" >/dev/null || fail "empty lag status was not ok"
[ -f "$EMPTY_LAG/.runtime/v2/subscribers/empty.lag.json" ] || fail "empty lag status artifact was not written"

MISSING="$TMPROOT/missing-shard"
mkdir -p "$MISSING/events" "$MISSING/.runtime/v2/subscribers"
printf '%s\n' '{"event":"later","occurred_at":"2026-05-03T00:00:00Z","data":{}}' > "$MISSING/events/2026-05-03.jsonl"
jq -n '{schema_version:1,subscriber:"broken",shard:"2026-05-02.jsonl",next_byte_offset:0,updated_at:"2026-05-03T00:00:00Z"}' > "$MISSING/.runtime/v2/subscribers/broken.checkpoint.json"
if "$RUN" replay --runtime-root "$MISSING" --subscriber broken > "$TMPROOT/missing.out" 2>"$TMPROOT/missing.err"; then
  fail "missing checkpoint shard replay succeeded"
fi
[ ! -s "$TMPROOT/missing.out" ] || fail "missing checkpoint shard emitted events before failing"
grep -q 'checkpoint shard missing: 2026-05-02.jsonl' "$TMPROOT/missing.err" || fail "missing checkpoint shard error was not explicit"

PARTIAL="$TMPROOT/partial-final-line"
mkdir -p "$PARTIAL/events"
printf '%s' '{"event":"partial_but_valid","occurred_at":"2026-05-03T00:00:00Z","data":{}}' > "$PARTIAL/events/2026-05-03.jsonl"
if "$RUN" replay --runtime-root "$PARTIAL" --subscriber partial > "$TMPROOT/partial.out" 2>"$TMPROOT/partial.err"; then
  fail "partial final line replay succeeded"
fi
[ ! -s "$TMPROOT/partial.out" ] || fail "partial final line emitted before failing"
[ ! -f "$PARTIAL/.runtime/v2/subscribers/partial.checkpoint.json" ] || fail "partial final line advanced checkpoint"
find "$PARTIAL/.runtime/v2/dead-letter/partial" -type f -name '*.json' | grep -q . || fail "partial final line did not create dead letter"
grep -q 'partial final line in 2026-05-03.jsonl' "$TMPROOT/partial.err" || fail "partial final line error was not explicit"

STATE="$TMPROOT/state-unwritable"
mkdir -p "$STATE"
"$RUN" append --runtime-root "$STATE" --quiet --event-json '{"event":"must_not_emit","occurred_at":"2026-05-03T00:00:00Z","data":{}}'
mkdir -p "$STATE/.runtime/v2"
printf 'not a directory\n' > "$STATE/.runtime/v2/subscribers"
if "$RUN" replay --runtime-root "$STATE" --subscriber blocked > "$TMPROOT/state.out" 2>"$TMPROOT/state.err"; then
  fail "subscriber state write failure replay succeeded"
fi
[ ! -s "$TMPROOT/state.out" ] || fail "subscriber state write failure emitted before failing"
grep -q 'subscriber state is not writable for blocked' "$TMPROOT/state.err" || fail "subscriber state write failure error was not explicit"

CHECKPOINT_DIR="$TMPROOT/checkpoint-path-directory"
mkdir -p "$CHECKPOINT_DIR"
"$RUN" append --runtime-root "$CHECKPOINT_DIR" --quiet --event-json '{"event":"must_not_emit","occurred_at":"2026-05-03T00:00:00Z","data":{}}'
mkdir -p "$CHECKPOINT_DIR/.runtime/v2/subscribers/bad.checkpoint.json"
if "$RUN" replay --runtime-root "$CHECKPOINT_DIR" --subscriber bad > "$TMPROOT/checkpoint-dir.out" 2>"$TMPROOT/checkpoint-dir.err"; then
  fail "checkpoint path directory replay succeeded"
fi
[ ! -s "$TMPROOT/checkpoint-dir.out" ] || fail "checkpoint path directory emitted before failing"
grep -q 'checkpoint path is not a file' "$TMPROOT/checkpoint-dir.err" || fail "checkpoint path directory error was not explicit"

DEDUPE_DIR="$TMPROOT/dedupe-path-directory"
mkdir -p "$DEDUPE_DIR"
"$RUN" append --runtime-root "$DEDUPE_DIR" --quiet --event-json '{"event":"must_not_emit","occurred_at":"2026-05-03T00:00:00Z","producer":{"agent":"worker"},"idempotency_key":"bad-dedupe","data":{}}'
if command -v shasum >/dev/null 2>&1; then
  DEDUPE_KEY=$(printf '%s' 'worker|bad-dedupe' | shasum -a 256 | awk '{print $1}')
else
  DEDUPE_KEY=$(printf '%s' 'worker|bad-dedupe' | sha256sum | awk '{print $1}')
fi
mkdir -p "$DEDUPE_DIR/.runtime/v2/subscribers/corrupt.dedupe/$DEDUPE_KEY"
if "$RUN" replay --runtime-root "$DEDUPE_DIR" --subscriber corrupt > "$TMPROOT/dedupe-dir.out" 2>"$TMPROOT/dedupe-dir.err"; then
  fail "dedupe path directory replay succeeded"
fi
[ ! -s "$TMPROOT/dedupe-dir.out" ] || fail "dedupe path directory emitted before failing"
grep -q 'dedupe marker path is not a file for corrupt' "$TMPROOT/dedupe-dir.err" || fail "dedupe path directory error was not explicit"

HANDLER_FAIL="$TMPROOT/handler-failure"
mkdir -p "$HANDLER_FAIL"
"$RUN" append --runtime-root "$HANDLER_FAIL" --quiet --event-json '{"event":"handler_retry","occurred_at":"2026-05-03T00:00:00Z","producer":{"agent":"worker"},"idempotency_key":"handler-retry","data":{}}'
if "$RUN" replay --runtime-root "$HANDLER_FAIL" --subscriber handler --handler 'cat >/dev/null; exit 7' > "$TMPROOT/handler.out" 2>"$TMPROOT/handler.err"; then
  fail "failing handler replay succeeded"
fi
[ ! -f "$HANDLER_FAIL/.runtime/v2/subscribers/handler.checkpoint.json" ] || fail "failing handler advanced checkpoint"
if command -v shasum >/dev/null 2>&1; then
  HANDLER_KEY=$(printf '%s' 'worker|handler-retry' | shasum -a 256 | awk '{print $1}')
else
  HANDLER_KEY=$(printf '%s' 'worker|handler-retry' | sha256sum | awk '{print $1}')
fi
[ ! -e "$HANDLER_FAIL/.runtime/v2/subscribers/handler.dedupe/$HANDLER_KEY" ] || fail "failing handler wrote dedupe marker"
"$RUN" replay --runtime-root "$HANDLER_FAIL" --subscriber handler > "$TMPROOT/handler-retry.out"
jq -e 'select(.event == "handler_retry")' "$TMPROOT/handler-retry.out" >/dev/null || fail "handler failure event was not replayable"

BAD_CHECKPOINT="$TMPROOT/bad-checkpoint"
mkdir -p "$BAD_CHECKPOINT/events" "$BAD_CHECKPOINT/.runtime/v2/subscribers"
printf '%s\n' '{"event":"later","occurred_at":"2026-05-03T00:00:00Z","data":{}}' > "$BAD_CHECKPOINT/events/2026-05-03.jsonl"
jq -n '{schema_version:1,subscriber:"badtype",shard:"2026-05-03.jsonl",next_byte_offset:"abc",updated_at:"2026-05-03T00:00:00Z"}' > "$BAD_CHECKPOINT/.runtime/v2/subscribers/badtype.checkpoint.json"
if "$RUN" replay --runtime-root "$BAD_CHECKPOINT" --subscriber badtype > "$TMPROOT/bad-checkpoint.out" 2>"$TMPROOT/bad-checkpoint.err"; then
  fail "invalid checkpoint type replay succeeded"
fi
[ ! -s "$TMPROOT/bad-checkpoint.out" ] || fail "invalid checkpoint emitted before failing"
grep -q 'invalid checkpoint' "$TMPROOT/bad-checkpoint.err" || fail "invalid checkpoint error was not explicit"

BAD_LAG="$TMPROOT/bad-lag-checkpoint"
mkdir -p "$BAD_LAG/events" "$BAD_LAG/.runtime/v2/subscribers"
printf '%s\n' '{"event":"later","occurred_at":"2026-05-03T00:00:00Z","data":{}}' > "$BAD_LAG/events/2026-05-03.jsonl"
jq -n '{schema_version:1,subscriber:"badlag",shard:"2026-05-03.jsonl",next_byte_offset:"abc",updated_at:"2026-05-03T00:00:00Z"}' > "$BAD_LAG/.runtime/v2/subscribers/badlag.checkpoint.json"
if "$RUN" lag --runtime-root "$BAD_LAG" --subscriber badlag > "$TMPROOT/bad-lag.out" 2>"$TMPROOT/bad-lag.err"; then
  fail "invalid lag checkpoint succeeded"
fi
[ ! -s "$TMPROOT/bad-lag.out" ] || fail "invalid lag checkpoint emitted status"
grep -q 'invalid checkpoint' "$TMPROOT/bad-lag.err" || fail "invalid lag checkpoint error was not explicit"

TOO_BIG=$(printf '%4100s' x | tr ' ' x)
if "$RUN" append --runtime-root "$RUNTIME" --quiet --event-json "$(jq -n --arg payload "$TOO_BIG" '{event:"too_big",occurred_at:"2026-05-03T00:00:03Z",data:{payload:$payload}}')" >/dev/null 2>"$TMPROOT/big.err"; then
  fail "oversized event append succeeded"
fi
grep -q 'exceeds 4096-byte' "$TMPROOT/big.err" || fail "oversized event error was not explicit"

printf 'PASS: v2 durable event log and subscribers\n'
