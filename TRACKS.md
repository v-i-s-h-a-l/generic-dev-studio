# Parallel Tracks

Independent work tracks. Each session works on one track only.

## Track label registry

`track:*` labels identify active or historical work lanes. A track label is not a theme; every issue still needs one dominant `theme/*` label from `THEMES.md`.

| Label | Status | Planning surface |
|---|---|---|
| `track:apollo` | Active | Apollo performance-agent research and build arc. Detailed work lives in the Apollo issues and skill docs. |
| `track:build-opt` | Active | Documented below as Track B. |
| `track:forge-safety` | Historical / archived | Historical lookup lives in `archive/forge-reliability-2026-05-03.md`; keep for filtering and future safety-floor regressions. |
| `track:host-agnostic` | Historical / mostly shipped | Documented below as Track A for context. |
| `track:pm-surface` | Active | GitHub-as-PM-surface arc, including labels, projects, milestones, and issue graph hygiene. Primary board: [Studio v2 transition](https://github.com/users/v-i-s-h-a-l/projects/1); field contract: [PM-SURFACE.md](PM-SURFACE.md). |
| `track:skill-distribution` | Active backlog | Skill distribution and recipe-system follow-ups from the skill distribution arc. |
| `track:v2` | Active | Studio v2 substrate rebuild and transition issues; sequence context lives in `ROADMAP.md`. |
| `track:workflow` | Active | Chain-runner and workflow-control-plane enhancements. |

Legacy follow-up labels such as `phase-2-5-followup`, `phase-2-6-followup`, and `phase-2.7-epic` are retained for existing issue filtering, but they are not `track:*` labels. Prefer a `track:*` label for new parallel work lanes.

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

## Track C — forge-safety (`track/forge-safety`)

Archived on 2026-05-03 after the safety-floor queue closed and the user explicitly waived the freeze as an active blocker.

Historical detail lives in [`archive/forge-reliability-2026-05-03.md`](archive/forge-reliability-2026-05-03.md). Do not append routine backlog drift to that archive. New safety-floor regressions should get fresh GitHub issues and, if they reopen this lane, a new active planning surface.

## Adding a new track

1. Add a section to this file.
2. Create a `track/<name>` branch.
3. Create a `track:<name>` GH label.
4. Add owned files to the table (verify no overlap with existing tracks).
