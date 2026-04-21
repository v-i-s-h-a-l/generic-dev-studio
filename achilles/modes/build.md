---
name: Achilles Build
description: Manual build verification (`/achilles build`). One command: green resets the debt counter on Chanakya's next sweep; red auto-bisects to name the breaking commit and files a P0 fix task. No brief required. Never prompts the user.
type: mode-pack
snapshots: []
budget_tokens: 2500
reads:
  - plans/index.yaml                               # post-migration task index (for Unverified-since set)
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/chanakya-master.md                       # legacy: `## Build Debt` block + Unverified-since (until Commit H)
writes:
  - plans/debriefs/<debrief-id>.yaml               # post-migration build-check debrief (YAML emission lands in Commit G; schema: _shared/schemas/debrief.md)
  - plans/chanakya-inbox/<BUILD_ID>-debrief.md     # legacy write target during Phase 2.6 transition
  - events/<date>.jsonl                            # build-check events (via scripts/write-event.sh)
---

# Mode: Build (`/achilles build`)

On-demand build verification. One command: green resets the debt counter; red auto-bisects to name the breaking commit and files a P0 fix task. No brief required. Never prompts the user.

This mode short-circuits the normal task pipeline — no branch, no merge, no Argus gate. Artifacts live in a detached-HEAD worktree and are cleaned only on green; red preserves them for inspection.

## B1 — Compute `Covers:` range

Read the `## Build Debt` block (legacy: `plans/chanakya-master.md`; post-migration: the `build_debt` section that Commit G's master-plan regenerator emits from `plans/index.yaml`). Take `Last green: <sha>` and the current committed HEAD of `$ORIG_BRANCH`. The range is `<last-green-sha>..HEAD`. Also capture the `Unverified since: [T015, T016, ...]` list — these task IDs are the human-readable Covers set.

If `Last green` is empty or the SHA is unreachable (branch rewritten), treat the base as "unknown" and use `<earliest-commit-on-branch>..HEAD`.

**Fast-path no-op:** if HEAD is the same SHA as `Last green`, print `"Already verified green at <short-sha> — nothing to do."` and exit. No worktree, no build, no debrief.

## B2 — Isolate

```bash
PROJECT=$(basename "$(git -C <repo-root> rev-parse --show-toplevel)")
STAMP=$(date +%Y%m%d-%H%M%S)
BUILD_ID="build-$STAMP"
WORKTREE=~/.dev-studio/$PROJECT/worktrees/$BUILD_ID
DERIVED=/tmp/derived-data/$BUILD_ID
HEAD_SHA=$(git -C <repo-root> rev-parse HEAD)

mkdir -p ~/.dev-studio/$PROJECT/worktrees /tmp/derived-data
git -C <repo-root> worktree add --detach "$WORKTREE" "$HEAD_SHA"
```

Detached HEAD — no branch created. Build mode never commits or merges.

## B3 — Full build at HEAD

Run the full-green build path used by the task mode's Step 6 verbatim, using `$DERIVED` as the DerivedData path and `$BUILD_ID` wherever `<task-id>` appears. Capture `BUILD_STATUS`.

**Full-green build block** (same contract as the task pipeline): acquire the per-project `xcodebuild.lock` via atomic `mkdir`, run `xcodebuild -scheme <scheme> -destination <dest> -derivedDataPath "$DERIVED" build`, release the lock, check status. See the task mode's build-gate documentation for the lock recipe and reclaim rules.

## B4a — Green path

1. Write debrief. Post-migration canonical target: `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` (schema: `_shared/schemas/debrief.md`, `mode: direct-debrief`, `task_id: null`). YAML emission lands in Commit G; during Phase 2.6 transition the legacy write target `~/.dev-studio/<project>/plans/chanakya-inbox/<BUILD_ID>-debrief.md` (format: `_shared/contracts/debrief-format.md`) remains in use:

```markdown
# Debrief: <BUILD_ID> — Manual build verification
Type: manual-build-check
Completed: <timestamp>
HEAD: <sha>
Covers: T015..T022        # from Unverified since, if non-empty; else "none"

## Build Verification
build_gate: full-green
result: pass
```

2. Clean up: `git worktree remove "$WORKTREE"` and `rm -rf "$DERIVED"`.
3. Print: `"✅ Build green at <short-sha>. Debt counter will reset on next Chanakya sweep."`
4. Exit. Chanakya handles counter reset + closing any open TBUILD on its next sweep.

## B4b — Red path — auto-bisect

Do **not** clean up yet — the worktree and DerivedData persist for the whole bisect.

1. **Start bisect inside `$WORKTREE`:**

```bash
cd "$WORKTREE"
git bisect start
git bisect bad "$HEAD_SHA"
git bisect good "$LAST_GREEN_SHA"   # from the Build Debt block
```

2. **Bisect loop** — for each commit `git bisect` checks out, run the same locked `xcodebuild` (reusing `$DERIVED` to keep SPM warm). Mark good/bad based on exit status:

```bash
while git bisect log | grep -q "^# first bad commit:" ; do break; done
# loop:
STATUS=$(run_locked_xcodebuild "$DERIVED")
if [ $STATUS -eq 0 ]; then git bisect good; else git bisect bad; fi
```

Each bisect step acquires the `xcodebuild.lock` for the build and releases it immediately after — siblings are not starved. DerivedData is intentionally **not** cleaned between steps: keeping SPM dependencies resolved is what makes bisect tolerable time-wise.

3. **Bisect verdict** — capture the breaking commit SHA, its subject, the touched files:

```bash
BAD_SHA=$(git bisect log | awk '/^# first bad commit:/ {print $5}')
BAD_SUBJECT=$(git show -s --format=%s "$BAD_SHA")
BAD_FILES=$(git show --name-only --format= "$BAD_SHA")
git bisect reset
```

4. **Debrief:**

```markdown
# Debrief: <BUILD_ID> — Manual build verification
Type: manual-build-check
Completed: <timestamp>
HEAD: <sha>
Covers: T015..T022

## Build Verification
build_gate: full-red
result: fail

## Bisect Result
Last green: <last-green-sha> (T014)
HEAD: <head-sha>
Breaking commit: <BAD_SHA> — <BAD_SUBJECT>
Suspect files:
- <path/to/File.swift>
- <path/to/Other.swift>
Error excerpt:
~~~
<first ~20 lines of xcodebuild failure at the bad commit>
~~~

## Follow-up Tasks
- P0 fix: restore green build. Breaking commit <BAD_SHA>. See suspect files. Block state remains active until this is resolved.
```

5. **Cleanup is conditional.** Keep `$WORKTREE` and `$DERIVED` in place so the user (or Chanakya's fix task) can inspect. Print their paths in the user-facing summary.

6. Print:

> "⛔ Build red. Bisect identified `<BAD_SHA>` — <subject>. Debrief written for Chanakya (will file P0 fix task). Artifacts retained at `~/.dev-studio/<project>/worktrees/<BUILD_ID>/` for inspection."

## B5 — Never modify Build Debt directly

Chanakya owns the counter. Build Mode only produces a debrief — the green/red outcome is reflected in the counter on Chanakya's next inbox sweep.

## Edge cases

- **Dirty main checkout:** irrelevant — Build Mode worktrees always branch from committed HEAD. User's uncommitted changes are untouched.
- **Another Achilles running Step 6:** both use the same `xcodebuild.lock`. Build Mode queues naturally.
- **Bisect range exceeds 64 commits:** cap at 6 bisect steps. If the breaking commit isn't isolated after 6 builds, write `bisect_inconclusive: true` to the debrief and list the remaining suspect range instead of a single commit. Chanakya will file a manual-investigation P0 instead of a single-commit fix task.
- **Orphan `build-*` artifacts older than 48h:** Chanakya's inbox sweep janitor removes them (see Chanakya's Step 0).
