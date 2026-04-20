---
name: DerivedData Conventions
description: Per-task DerivedData paths and staleness rules; Argus reuses Achilles's DerivedData for test runs.
type: reference
---

# Shared: DerivedData Conventions

Per-task DerivedData paths and staleness rules. Argus reuses Achilles's DerivedData — no recompile needed for test runs.

## Path Convention

All agents use the same path pattern:

```
/tmp/derived-data/<task-id>/
```

Examples:
- Achilles building T001 → `/tmp/derived-data/T001/`
- Argus testing T001 → `/tmp/derived-data/T001/` (same directory, reuse)
- Build-mode run → `/tmp/derived-data/build-20260418-143000/`

**Why `/tmp/` (not `~/.dev-studio/`)?** DerivedData can be 2–8 GB per task. Keeping it in `/tmp/` puts it on the fastest available volume on macOS and avoids polluting the persistent dev-studio directory with multi-GB build caches. Cleanup is also simpler (OS sweeps `/tmp/` on reboot).

Note: Achilles's SKILL.md Step 6 previously showed `~/.dev-studio/$PROJECT/derived-data/<task-id>`. The canonical path is now `/tmp/derived-data/<task-id>`. Both agents must use this form.

## Staleness Guard

Argus must not run tests against stale build products. Before invoking `xcodebuild test`:

```bash
DERIVED="/tmp/derived-data/<task-id>"
WORKTREE_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
HEAD_TS=$(git -C "$WORKTREE" log -1 --format=%ct "$WORKTREE_HEAD")   # Unix epoch of HEAD commit

# Find the newest build product in DerivedData (Products/ dir)
PRODUCTS_DIR="$DERIVED/Build/Products"
if [ -d "$PRODUCTS_DIR" ]; then
  NEWEST_MTIME=$(find "$PRODUCTS_DIR" -maxdepth 3 -name "*.app" -o -name "*.xctest" 2>/dev/null \
    | xargs stat -f %m 2>/dev/null | sort -n | tail -1)
else
  NEWEST_MTIME=0
fi

if [ -z "$NEWEST_MTIME" ] || [ "$NEWEST_MTIME" -lt "$HEAD_TS" ]; then
  echo "DerivedData is stale (build products older than HEAD commit) — forcing rebuild" >&2
  FORCE_REBUILD=yes
fi
```

If `FORCE_REBUILD=yes`, Argus must run `xcodebuild build` first (acquiring the Achilles build lock is NOT required — Argus uses its own test-slot semaphore and `/tmp/derived-data` is per-task) before running tests.

## Simulator Convention

Argus uses dedicated simulators named `Argus-<slot-N>` (N = 1, 2, 3 matching the test slot):

```bash
# Boot simulator if not already booted
xcrun simctl boot "Argus-${SLOT_N}" 2>/dev/null || true
DEST="platform=iOS Simulator,name=Argus-${SLOT_N}"
```

These simulators are:
- Created once by the user during initial setup (or auto-created by Argus on first run)
- Booted at test-phase start and left running — no shutdown, no cleanup
- Named distinctly from Achilles's simulators to avoid resource conflicts

**Auto-create if missing:**
```bash
SLOT_N=1  # or whichever slot was acquired
SIM_NAME="Argus-${SLOT_N}"
if ! xcrun simctl list devices | grep -q "$SIM_NAME"; then
  # Find latest iOS runtime
  RUNTIME=$(xcrun simctl list runtimes | grep "iOS" | tail -1 | awk '{print $NF}')
  xcrun simctl create "$SIM_NAME" "iPhone 16" "$RUNTIME"
fi
```

## Result Bundle Path

Per-run result bundles use a deterministic path:

```
/tmp/argus-<task-id>.xcresult
```

Argus passes `-resultBundlePath /tmp/argus-<task-id>.xcresult` to every `xcodebuild test` invocation.

**Retention:**
- Approve verdict → delete immediately after review completes.
- Flag verdict → delete after `review_approved` event from Chanakya (i.e., after the review file is archived).
- Block verdict → retain for 48 hours (Chanakya compact sweeps after that).

See `_shared/cleanup-policy.md` for the full retention table.

## Parallel Testing

Within a single Argus test run:
- Unit tests: `-parallel-testing-enabled YES` with automatic worker count (Xcode decides)
- UI tests: `-parallel-testing-enabled YES -parallel-testing-worker-count 2` (capped to avoid simulator thrash)

```bash
# Unit test invocation
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "/tmp/argus-${TASK_ID}.xcresult" \
  -parallel-testing-enabled YES \
  -only-testing:"$UNIT_TARGET"

# UI test invocation
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "/tmp/argus-${TASK_ID}.xcresult" \
  -parallel-testing-enabled YES \
  -parallel-testing-worker-count 2 \
  -only-testing:"$UI_TARGET"
```
