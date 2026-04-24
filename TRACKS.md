# Parallel Tracks

Two independent work tracks running concurrently. Each session works on one track only.

## How to use

1. **Pick a track** — open a session, check out the track branch.
2. **Pick an issue** — `gh issue list --label track:<name>` filtered to unassigned.
3. **Claim it** — `gh issue edit N --assignee @me` before starting. This is the mutex.
4. **Work on the track branch** — commit to `track/<name>`, not `main`.
5. **Done?** — close the issue, pick the next unassigned one.
6. **Track complete** — open a PR from `track/<name>` → `main`.

## Track A — host-agnostic (`track/host-agnostic`)

**Label:** `track:host-agnostic`  
**Issues:** #88 (and any sub-issues it spawns)  
**Merge order:** merges first

### Files owned

| File | Notes |
|---|---|
| `achilles/modes/task.md` | **Step 8.5 only** (Argus dispatch) |
| `argus/modes/*.md` | full ownership |
| `argus/SKILL.md` | full ownership |
| `scripts/dispatch-review.sh` | new |
| `scripts/test-host.sh` | new |
| `_shared/contracts/*.md` | JSON schema additions |
| `REVIEW.md` | graceful-degradation rule |
| `ARCHITECTURE.md` | host-agnostic section |
| `tests/mode-packs/achilles/*.yaml` | host-agnostic fixtures |

## Track B — build-opt (`track/build-opt`)

**Label:** `track:build-opt`  
**Issues:** #110 (B1), #111 (B2), #112 (B3), #113 (B4) — plus prereq runbooks #52, #53, #54  
**Merge order:** merges after Track A (or rebases on it for task.md)

### Issues in order

| Issue | Title | Prereqs |
|---|---|---|
| #110 (B1) | `swift-test-gate.sh` | none — start here |
| #111 (B2) | Node registry + node-dispatch.sh | #52 (mini online) |
| #112 (B3) | Route builds to mini | B1, B2, #53 |
| #113 (B4) | Snapshot canonical env | B2 |

### Files owned

| File | Notes |
|---|---|
| `achilles/modes/task.md` | **Step 6 only** (build routing hook) |
| `scripts/swift-test-gate.sh` | new |
| `scripts/node-dispatch.sh` | new |
| `scripts/node-health.sh` | new |
| `scripts/node-pick.sh` | new |
| `scripts/snapshot-sync.sh` | new |
| `_shared/primitives/file-locations.md` | snapshot path addition only |

## Shared file: `achilles/modes/task.md`

Track A owns **Step 8.5**. Track B owns **Step 6**.  
These are different sections — edits don't conflict.  
**Merge rule:** Track A merges to main first. Track B rebases `track/build-opt` on `main` before opening its PR (one rebase, trivial).

## Adding a third track

1. Add a row to this file.
2. Create a `track/<name>` branch.
3. Create a `track:<name>` GH label.
4. Add owned files to the table (verify no overlap with A or B).
