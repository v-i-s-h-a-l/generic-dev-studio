# Parallel Tracks

Independent work tracks. Each session works on one track only.

## Track label registry

`track:*` labels identify active or historical work lanes. A track label is not a theme; every issue still needs one dominant `theme/*` label from `THEMES.md`.

| Label | Status | Planning surface |
|---|---|---|
| `track:apollo` | Active | Apollo performance-agent research and build arc. Detailed work lives in the Apollo issues and skill docs. |
| `track:build-opt` | Active | Documented below as Track B. |
| `track:forge-safety` | Retained / no open issues | Documented below as Track C and in `FORGE-RELIABILITY.md`; keep for historical filtering until a new forge-safety issue reopens the lane. |
| `track:host-agnostic` | Historical / mostly shipped | Documented below as Track A for context. |
| `track:pm-surface` | Active | GitHub-as-PM-surface arc, including labels, projects, milestones, and issue graph hygiene. |
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

**Label:** `track:forge-safety`
**Branch:** `track/forge-safety`
**Issues:** 7 analysis bugs — safety floor + data integrity + operational fixes
**Merge order:** merges independently (no file overlap with A or B)
**Forge flag system:** 🟢 Green (autonomous) / 🟡 Yellow (deploy-gated) / 🔴 Red (user-gated)

### Execution waves

| Wave | Issues | Deps | Flag | Can parallelize |
|---|---|---|---|---|
| 1 | #299 (Argus infra root causes) | none | 🟢 | yes — independent |
| 1 | #301 (debrief contract + writer) | none | 🟢 | yes — independent |
| 1 | #279 (debrief enforcement) | none | 🟢 | yes — independent |
| 1 | #76 (dual-write audit) | none | 🟢 | yes — independent |
| 2 | #298 (sweep blind spots) | Blocked by: #301 | 🟢 | after #301 |
| 2 | #300 (cascade circuit breaker) | Blocked by: #299, #279 | 🟡 | after #299 + #279 |
| 3 | #97 (App Store version) | Blocked by: #300 | 🔴 | after #300; needs user API key |

### Flag definitions

- 🟢 **Green** — fully autonomous. Implement, verify against acceptance criteria, commit, close. No user touchpoint.
- 🟡 **Yellow** — can be built autonomously, but deployment is gated on upstream issues. Build in parallel, hold merge until deps are verified.
- 🔴 **Red** — hard user dependency. Cannot complete acceptance criteria without user action (API keys, live API calls, device verification). Implement all automatable parts, then pause with a clear "user action needed" summary.

### Files owned

| File | Notes |
|---|---|
| `scripts/task-merge.sh` | #279 (debrief precondition), #300 (composite gate) |
| `scripts/task-emit-debrief.sh` | #279 (--stage / --finalize split) |
| `scripts/sweep-enumerate-debriefs.sh` | #298 (blind spot fixes) |
| `scripts/dispatch-review.sh` | #299 (Argus preflight checks) |
| `scripts/check-merge-precondition.sh` | #279 (new — reusable git hook) |
| `_shared/contracts/debrief-format.md` | #301 (rewrite to YAML schema) |
| `_shared/contracts/.legacy/` | #301 (archive old MD template) |
| `_shared/patterns/dual-write-transition.md` | #76 (new primitive) |
| `achilles/modes/task.md` | #279 (Steps 8.6–8.7 + Step 9 rewrite) |
| `chanakya/modes/*.md` | #76 (audit: dual-write prose fixes) |
| `argus/SKILL.md` | #76 (audit), #299 (preflight) |
| `pushTFBuild.md` | #97 (Step 1c endpoint fix) |
| Mode packs touched by #76 audit | read-only audit; write only if OR→AND fix needed |

### Acceptance gate

Track is complete when:
1. All 7 issues closed
2. Every AC (acceptance criterion) on every issue verified by synthetic test or runtime check
3. Zero `argus_gate_skipped` events in the first full day post-deploy (#299 AC6)
4. Zero non-archived `.md` debriefs in the canonical debriefs directory (#301 AC5)
5. Zero false-positive merge blocks on next 10 real Achilles runs (#300 AC9)

### Shared file conflicts

| File | This track | Other track | Conflict? |
|---|---|---|---|
| `achilles/modes/task.md` | Steps 8.6–9 | Track A: Step 8.5, Track B: Step 6 | No — different sections |
| `scripts/dispatch-review.sh` | Argus preflight | Track A: Argus dispatch | Possible — review at merge time |

## Adding a new track

1. Add a section to this file.
2. Create a `track/<name>` branch.
3. Create a `track:<name>` GH label.
4. Add owned files to the table (verify no overlap with existing tracks).
