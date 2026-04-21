---
name: Test-Slot Semaphore
description: File-based semaphore limiting concurrent Argus test runs to 3 slots to prevent simulator overcommit.
type: reference
---

# Shared: Test-Slot Semaphore

File-based semaphore for Argus test execution. Limits concurrent test runs to 3 slots to avoid simulator overcommit.

**Only Argus acquires test slots.** Achilles uses the separate `xcodebuild.lock` (see `achilles/modes/task.md` Step 6). XS/S reviews never run tests and never acquire slots.

## Slot Directory

```
~/.dev-studio/.runtime/locks/test-slots/
```

Three slot files: `slot-1`, `slot-2`, `slot-3`. Each is a directory (so `mkdir` is the atomic acquire operation).

## Acquire Protocol

```bash
SLOT_DIR=~/.dev-studio/.runtime/locks/test-slots
mkdir -p "$SLOT_DIR"

SLOT=""
for n in 1 2 3; do
  if mkdir "$SLOT_DIR/slot-$n" 2>/dev/null; then
    echo "$$:argus:<task-id>:$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SLOT_DIR/slot-$n/pid"
    SLOT="$SLOT_DIR/slot-$n"
    break
  fi
done

if [ -z "$SLOT" ]; then
  # All 3 slots busy — wait and retry
  sleep 15
  # (loop back to the acquire block)
fi
```

**PID file format:** `<pid>:<agent>:<task-id>:<acquired-at-ISO8601>` — single line.

## Release Protocol

Always release via trap to handle unexpected exits:

```bash
trap 'rm -rf "$SLOT"' EXIT INT TERM

# ... run xcodebuild test ...

rm -rf "$SLOT"
trap - EXIT INT TERM
```

Release happens **before** writing the test result to the event log. The slot is held only for the duration of the `xcodebuild test` call.

## Stale Slot Detection

A slot is stale if:

1. The PID in the slot file no longer exists: `! kill -0 <pid> 2>/dev/null`
2. OR the slot was acquired > 2 hours ago (read `acquired-at` from the pid file)

Argus checks for stale slots before entering the wait loop:

```bash
for n in 1 2 3; do
  SLOT_PATH="$SLOT_DIR/slot-$n"
  if [ -d "$SLOT_PATH" ] && [ -f "$SLOT_PATH/pid" ]; then
    SLOT_PID=$(cut -d: -f1 "$SLOT_PATH/pid")
    ACQUIRED=$(cut -d: -f4 "$SLOT_PATH/pid")
    AGE_S=$(( $(date -u +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ACQUIRED" +%s 2>/dev/null || echo 0) ))
    if ! kill -0 "$SLOT_PID" 2>/dev/null || [ "$AGE_S" -gt 7200 ]; then
      echo "Stale test slot $n (PID $SLOT_PID, age ${AGE_S}s) — reclaiming" >&2
      rm -rf "$SLOT_PATH"
    fi
  fi
done
```

Run stale detection once before the acquire loop. Do not run it inside the retry loop (avoid race with another live instance doing the same).

## Chanakya Compact Cleanup

Chanakya compact (`--sweep-artifacts`) scans all three slot files:
- If the owning PID is dead and age > 24h → remove.
- Log removed stale markers in the compact report.

See `_shared/rules/cleanup-policy.md` for the full sweep protocol.

## Constraints

- XS/S reviews: **never acquire** — no test run, no slot needed.
- M/L reviews: acquire before `xcodebuild test`, release after.
- TDD reviews: acquire once, hold through the two-run (start-commit + HEAD) sequence.
- Do not acquire the Achilles `xcodebuild.lock` — those are independent semaphores.
- Maximum wait before giving up: 30 minutes. If all slots are still busy after 30 min of retries, fail the test phase with `test_run_failed` event and reason `slot_timeout`.
