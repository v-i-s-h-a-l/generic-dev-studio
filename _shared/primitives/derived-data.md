---
name: DerivedData Conventions
description: Per-task DerivedData paths and staleness rules; Argus reuses Achilles's DerivedData for test runs.
type: reference
---

# Shared: DerivedData Conventions

Per-task DerivedData paths and staleness rules. Argus reuses Achilles's DerivedData — no recompile needed for test runs.

For Studio v2 iOS chain execution, the higher-level isolation contract lives in
`_shared/contracts/ios-isolated-execution.md`. That contract defines the target
chain/lane/executor cache scope. The iOS project profile command layer now uses
that contract for profile-owned `build`, `test:unit`, and `test:ui`
operations; the older gates listed below keep their legacy paths until their
own migration issues land.

## Path Convention

### Studio v2 profile operations

`profiles/ios-turnip/commands/xcode-operation` scopes build/test outputs under
`STUDIO_IOS_ARTIFACT_ROOT`, `STUDIO_CHAIN_ARTIFACT_ROOT`, or a run-scoped temp
root derived from `.studio/chain-task-start.json`:

```
<chain-artifact-root>/
  DerivedData/lanes/<executor-or-lane-id>/<cache-key>/
  result-bundles/<issue-run-id>/<attempt-operation>.xcresult
  logs/<issue-run-id>/<attempt-operation>.log
  summaries/<issue-run-id>/<attempt-operation>.summary.txt
  tmp/<issue-run-id>/<attempt-operation>/
```

Each DerivedData root has a sibling `.metadata.json` file. Reuse fails closed
to a fresh cold root when cache-key inputs are missing or metadata does not
match.

### Existing legacy consumers

Current non-profile consumers of older artifact locations are:

| Consumer | Current artifact location |
|---|---|
| `scripts/task-build-gate.sh` | `resolve_derived_data_for "$TASK_ID"` (`~/.dev-studio/.runtime/derived-data/<worktree-slug>/`) |
| `scripts/task-test-gate.sh` | same `resolve_derived_data_for "$TASK_ID"` DerivedData root |
| `scripts/argus-run-tests.sh` | same DerivedData root, plus `/tmp/argus-<task-id>.xcresult` and `/tmp/argus-<task-id>-test-output.txt` |
| `scripts/argus-emit-verdict.sh` | deletes `/tmp/argus-<task-id>.xcresult` on approved/flagged outcomes |
| `scripts/sweep-janitor.sh` | prunes orphaned `~/.dev-studio/.runtime/derived-data/*` roots |
| `_shared/rules/cleanup-policy.md` | still documents compact cleanup for legacy `/tmp/argus-*.xcresult` and older `/tmp/derived-data/*` paths |

No existing consumer reads result bundles, logs, summaries, or temp outputs from
the new v2 profile artifact root; those paths are produced by the profile
command layer for chain-runner review and later telemetry ingestion.

**Why scoped temp roots?** DerivedData can be 2-8 GB per task. Keeping v2
profile artifacts under a chain/run root preserves incremental build value
inside a chain while keeping concurrent lanes from sharing one writable Xcode
cache. The root may still live on a fast temp volume by default; it is no
longer a shared unqualified `/tmp/derived-data` or `/tmp/argus-*` location.

## Staleness Guard

Argus must not run tests against stale build products. Before invoking `xcodebuild test`:

```bash
DERIVED="$(resolve_derived_data_for "<task-id>")"
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

If `FORCE_REBUILD=yes`, Argus must run `xcodebuild build` first (acquiring the Achilles build lock is NOT required — Argus uses its own test-slot semaphore and its current DerivedData root is per task/worktree) before running tests.

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

## Legacy Argus Result Bundle Path

Per-run result bundles use a deterministic path:

```
/tmp/argus-<task-id>.xcresult
```

Argus passes `-resultBundlePath /tmp/argus-<task-id>.xcresult` to every `xcodebuild test` invocation.

**Retention:**
- Approve verdict → delete immediately after review completes.
- Flag verdict → delete after `review_approved` event from Chanakya (i.e., after the review file is archived).
- Block verdict → retain for 48 hours (Chanakya compact sweeps after that).

See `_shared/rules/cleanup-policy.md` for the full retention table.

## Parallel Testing

Within a single Argus test run:
- Unit tests: `-parallel-testing-enabled YES` with automatic worker count (Xcode decides)
- UI tests: `-parallel-testing-enabled YES -parallel-testing-worker-count 2` (capped to avoid simulator thrash)

```bash
# Unit test invocation (executed by argus-run-tests.sh — sample only)
# lint-build:allow next-line — documentation of argus-run-tests.sh's call shape
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "/tmp/argus-${TASK_ID}.xcresult" \
  -parallel-testing-enabled YES \
  -only-testing:"$UNIT_TARGET"

# UI test invocation (executed by argus-run-tests.sh — sample only)
# lint-build:allow next-line — documentation of argus-run-tests.sh's call shape
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "/tmp/argus-${TASK_ID}.xcresult" \
  -parallel-testing-enabled YES \
  -parallel-testing-worker-count 2 \
  -only-testing:"$UI_TARGET"
```
