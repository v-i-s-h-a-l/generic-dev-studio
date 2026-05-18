---
name: Task Schema
description: YAML shape for per-task artifacts under plans/tasks/<task-id>.yaml. One file per task. Carries state, size, priority, type, train + release lineage, predecessors, affinity, reopen lineage, verification block, and history of state transitions. Authoritative: task-lifecycle.md defines legal states and transitions.
type: reference
---

# Task Schema (`task@1.3.0`)

Per-task artifact written to `~/.dev-studio/<project>/plans/tasks/<task-id>.yaml`. Replaces the inline per-task markdown block in the legacy master plan. One file per task — the master plan becomes a rendered view, no longer a source of truth (Phase 2.6).

Versions 1.1.0, 1.2.0, and 1.3.0 are non-breaking — every new field is optional with a documented default (per `contracts/EVOLUTION.md` rule 1). Readers on earlier versions transparently ignore the new fields; writers may emit them when value is known. `min_reader: 1.0.0` keeps the entire active fleet compatible.

## Shape

```yaml
schema_version:
  name: task
  version: 1.3.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11       # UUIDv7
title: "Add filter preset row"
type: feature                                    # feature | bug | refactor | test | release | direct  (1.1.0; absent ⇒ feature)
state: proposed                                  # see states table below
size: m                                          # xs | s | m | l
priority: p2                                     # p0 | p1 | p2 | p3  (1.1.0; absent ⇒ p2)
created_at: 2026-04-22T10:15:00Z
updated_at: 2026-04-22T10:15:00Z
labels: []                                       # 1.1.0; flat string array — theme/*, track/*, train/*, auto-followup, parking-lot, urgent
parent: null                                     # 1.1.0; UUIDv7 epic parent | null
train: null                                      # 1.1.0; train name (e.g. "comms-revamp") | null
release_target: null                             # 1.1.0; planned milestone (e.g. "v0.7.0", "tf-247") | null
released_in: null                                # 1.1.0; immutable post-release stamp written by Nabu (#214) | null
predecessors: []                                 # 1.1.0; UUIDv7 array; non-empty gates dispatch (DAG ordering)
similar_to: []                                   # 1.1.0; UUIDv7 array; knowledge-layer hint (Phase 2.7)
affinity:                                        # 1.1.0
  touchpoints: []                                # path/glob array — Argus diff-scope + parallel-safety
  prefers_node: null                             # node-id | null routing hint
origin: human                                    # 1.1.0; human | feedback | auto-followup | crash | review-finding | direct  (absent ⇒ human)
effort_minutes: null                             # 1.1.0; integer estimate; null = unestimated
recommended_model: null                          # 1.1.0; opus | sonnet | haiku | opus-1m | null
reopen_reason: null                              # 1.1.0; string; populated when state == reopened (#252)
reopen_chain: []                                 # 1.1.0; prior debrief-id array (chronological)
duplicate_of: null                               # 1.1.0; UUIDv7 of the canonical task | null
caused_by: []                                    # 1.2.0; UUIDv7 array; regression / fallout provenance — task IDs whose ship caused this task to be filed
verification:                                    # 1.1.0; composite cross-cutting view (denormalized — see §Verification block)
  debrief_id: null
  review_id: null
  merge_sha: null
  build_id: null
links:
  brief: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c   # brief-id | null
  debrief: null                                  # debrief-id | null
  reviews: []                                    # list of review-ids
  release: null                                  # release-id | null
  feedback: []                                   # list of feedback-ids
  crashes: []                                    # 1.3.0; list of crash-ids addressed by this task
history:
  - from: null
    to: proposed
    actor: chanakya
    at: 2026-04-22T10:15:00Z
    event_id: 0190f52a-6e0c-7c11-80aa-22bb33cc44dd   # UUIDv7 of the task_state_changed event
```

## Fields

### Core (1.0.0)

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | `{name, version, min_reader, deprecated_at}` per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | Monotonic. Stable across the task lifetime. |
| `title` | string | yes | Short human-readable label. |
| `state` | enum | yes | One of the values in `state-machines/task-lifecycle.md`. |
| `size` | enum | yes | `xs` \| `s` \| `m` \| `l`. Drives build-gate + review policy. |
| `created_at` | RFC3339 UTC | yes | Set once on file creation. |
| `updated_at` | RFC3339 UTC | yes | Bumped on every state transition / link update. |
| `links.brief` | UUIDv7 \| null | yes | Current brief for this task. See §Links below. |
| `links.debrief` | UUIDv7 \| null | yes | Most recent debrief. One task may have many debriefs across rework cycles; `links.debrief` names the latest. |
| `links.reviews` | array of UUIDv7 | yes | All Argus reviews issued against the task's worktree. Append-only by Argus per `primitives/agent-comms-boundary.md`. |
| `links.release` | UUIDv7 \| null | yes | Release artifact the task shipped in. Null until release-flow mode links it. |
| `links.feedback` | array of UUIDv7 | yes | Feedback records that reference this task. |
| `links.crashes` | array of UUIDv7 | no | Crash records addressed by this task. Default `[]`. Bidirectional with `crash.linked_tasks`; public surfaces must use the crash record's public-safe projection, not private crash fields. (1.3.0) |
| `history` | array of transition records | yes | Append-only. See §History below. |

### Lean fields (1.1.0)

All optional; absence semantics documented per `contracts/EVOLUTION.md` rule 1.

| Field | Type | Required | Default when absent | Notes |
|---|---|---|---|---|
| `type` | enum | no | `feature` | `feature` \| `bug` \| `refactor` \| `test` \| `release` \| `direct`. Drives intake routing + Argus stage policy. Distinct from `brief.type` (which classifies the *change kind*, e.g. `impl` vs `unit-test`). |
| `priority` | enum | no | `p2` | `p0` \| `p1` \| `p2` \| `p3`. Lower is higher priority. Drives dispatch-view ordering. |
| `labels` | array of strings | no | `[]` | Flat label set. Conventional prefixes: `theme/<name>`, `track/<name>`, `train/<name>`, plus standalone tags `auto-followup`, `parking-lot`, `urgent`. Maps 1:1 to GH Issue labels for #239 if/when reopened. |
| `parent` | UUIDv7 \| null | no | `null` | Epic hierarchy. The parent task's `type` is typically `release` or `refactor` for an arc. |
| `train` | string \| null | no | `null` | Single-train convention — a string identifying a coordinated body of work (e.g. `"comms-revamp"`). One value per task; cross-train work uses two tasks. |
| `release_target` | string \| null | no | `null` | Planned shipping milestone (e.g. `"v0.7.0"`, `"tf-247"`). Mutable until the task ships; cleared on cancel. |
| `released_in` | string \| null | no | `null` | Immutable tag stamp written by Nabu (#214) when the release artifact transitions to `released`. Once set, never modified. |
| `predecessors` | array of UUIDv7 | no | `[]` | Tasks that must reach `merged` (or `verified`) before this task may transition to `dispatched`. Non-empty value gates dispatch — see §Dispatch gating. |
| `similar_to` | array of UUIDv7 | no | `[]` | Knowledge-layer hint for Phase 2.7 — references prior tasks the brief author drew on. Not a hard dependency. |
| `affinity.touchpoints` | array of strings | no | `[]` | File path globs the task is expected to touch. Sharpens Argus's diff scope (#254) and lets Chanakya detect parallel-unsafe tasks before dispatch (#224). |
| `affinity.prefers_node` | string \| null | no | `null` | Worker node-id hint (per `~/.dev-studio/.runtime/nodes.json`). Soft routing preference; honored when the node is idle. |
| `origin` | enum | no | `human` | `human` \| `feedback` \| `auto-followup` \| `crash` \| `review-finding` \| `direct`. Drives concern-emission + crash-throughput dashboards. |
| `effort_minutes` | integer \| null | no | `null` | Estimate at brief time. Null = unestimated. Surfaced in dispatch view; rolls up at `train` level for burn-down. |
| `recommended_model` | enum \| null | no | `null` | `opus` \| `sonnet` \| `haiku` \| `opus-1m` \| `null`. Brief author's hint; consumed by dispatch and the future A/B model-routing path (ROADMAP §A/B). |
| `reopen_reason` | string \| null | no | `null` | Free-text reason; populated only when `state == reopened`. ≤ 280 chars. |
| `reopen_chain` | array of UUIDv7 | no | `[]` | Chronological list of prior debrief-ids across reopen cycles. Append-only when state transitions through `reopened`. |
| `duplicate_of` | UUIDv7 \| null | no | `null` | When set, this task is closed-as-duplicate of the named canonical task. Setting `duplicate_of` requires `state` ∈ `{cancelled, archived}`. |
| `caused_by` | array of UUIDv7 | no | `[]` | Regression / fallout provenance — tasks whose ship caused this task to be filed. Forward-only edge; the inverse `causes` is computed at read time by `scripts/query-relations.sh` (no stored field). Typical use: a bug task lists the feature task whose merge introduced the regression. (1.2.0) |
| `verification.debrief_id` | UUIDv7 \| null | no | `null` | Latest verifying debrief. May equal `links.debrief` or differ when verification used a re-run. |
| `verification.review_id` | UUIDv7 \| null | no | `null` | Argus review that approved the verifying run. May equal `links.reviews[-1]` or differ when verification used a separate review. |
| `verification.merge_sha` | string \| null | no | `null` | Full-length SHA of the verified merge commit. Equals `debrief.branch.merge_sha` when both are populated. |
| `verification.build_id` | string \| null | no | `null` | Build identifier from the verifying run (e.g. TestFlight build number). Null until the task ships. |

The `verification` block is **denormalized** — every field can be derived by joining `links.debrief`, `links.reviews`, and `links.release`. Maintained as a cross-cutting projection so a single read of the task answers "is this verified?" without four lookups. Writers (Chanakya `inbox-sweep`, Achilles `task`) keep it in sync with `links.*`; the plans-index validator flags drift.

## Relation edges

The schema carries several relation edges, all forward-only on the storing task. Inverse views are computed at read time by `scripts/query-relations.sh` — no inverse field is persisted, so the SSOT stays on the forward edge.

| Forward edge | Field | Cardinality | Inverse (computed) |
|---|---|---|---|
| blocked-by | `predecessors` | many | `blocks` |
| parent | `parent` | one | `children` |
| confirmed duplicate | `duplicate_of` | one | `duplicates` |
| suspected similar | `similar_to` | many | `similar_to` (symmetric hint; not strictly inverse) |
| caused-by | `caused_by` | many | `causes` |
| crash-fixed-by | `links.crashes` | many | `fixed-by-task` |
| reopen lineage | `reopen_chain` | many (chronological) | (no inverse — chain is per-task history) |

Reverse-index helper: `scripts/query-relations.sh --task <id>` joins these into a `forward:` / `inverse:` block. `/chanakya status --task <id>` renders that block; `/chanakya brief` and `/chanakya intake` consult `similar_to` / `duplicate_of` at author time to surface possible duplicates.

## States

Enum values and transitions governed by `state-machines/task-lifecycle.md`:

```
proposed → briefed → dispatched → in-progress → self-reviewed → argus-reviewed → merged → user-verifying → verified
                                                                                                        → rejected → briefed (rework)
verified → archived
verified | merged | archived | cancelled → reopened → briefed (re-brief) | archived (drop)
any      → blocked | cancelled | requeued
```

The reopen lifecycle (#252) re-enters closed tasks with a recorded `reopen_reason`; prior `links.debrief` appends to `reopen_chain` on transition. See `task-lifecycle.md` for the authoritative transition table and event-payload requirements.

Readers MUST reject unknown state values (no silent degradation), with one carve-out: readers on `task@1.0.0` reject `reopened` (the value did not exist), and writers that need to emit it MUST also write `schema_version.version: 1.1.0` so the reader's min-reader check fails fast rather than silently dropping the state.

## Dispatch gating

When `predecessors` is non-empty, the `briefed → dispatched` transition is gated:

```
∀ pred in predecessors:
  read plans/tasks/<pred>.yaml
  pred.state ∈ {merged, verified, archived}
```

If any predecessor is unmet, dispatch is deferred — Chanakya's brief-mode emits a `dispatch_blocked` event with the unmet set and leaves `state: briefed`. The task surfaces in `/chanakya status` under "blocked-by-DAG" rather than as ready-to-dispatch.

## Links

Back-reference invariants enforced by `contracts/plans-index-validator.md`:

- `task.links.brief = X` ⇔ `brief.task_id = task.id` and `brief.id = X`.
- Every `review-id` in `links.reviews` resolves to a `review.yaml` whose `subject.kind = task` and `subject.id = task.id`.
- Every crash ID in `links.crashes` resolves to a `crash.yaml` whose `linked_tasks` contains this task ID. Chain state, worker prompts, commit bodies, build summaries, release notes, and post-release annotations derived from this edge must project only `crash.public_label`, `crash.public_crash_url`, `crash.fix_confidence`, and build/version context.
- Orphans (no inbound references) produce validator warnings; dangling (reference without artifact) produces validator blocks.

The `plans/index.yaml` relational index is authoritative for joins; `links:` blocks let a single file stand alone without loading the index.

## History

Each entry in `history:` records one state transition:

```yaml
- from: briefed          # null only on the initial proposed entry
  to: dispatched
  actor: chanakya        # chanakya | achilles | argus | user
  at: 2026-04-22T10:32:11Z
  event_id: 0190f52a-7b0c-7c11-80aa-22bb33cc44dd
  reason: "worker-2 idle"   # optional, ≤120 chars
```

`event_id` is the UUIDv7 of the `task_state_changed` event emitted at the same transition. The event log is the authoritative audit stream; `history` is the per-task view.

## Example — full lifecycle (1.0.0 minimal shape)

```yaml
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11
title: "Add filter preset row"
state: merged
size: m
created_at: 2026-04-22T10:15:00Z
updated_at: 2026-04-22T12:48:17Z
links:
  brief: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c
  debrief: 0190f52a-79aa-7d02-8b88-33ce5fe65e66
  reviews:
    - 0190f52a-7a11-7e03-8c99-44df6fd77a77
  release: null
  feedback: []
  crashes:
    - 0190f52b-0000-7100-8ccc-99ff00aa11bb
history:
  - {from: null,            to: proposed,       actor: chanakya, at: 2026-04-22T10:15:00Z, event_id: 0190f52a-6e0c-7c11-80aa-22bb33cc44dd}
  - {from: proposed,        to: briefed,        actor: chanakya, at: 2026-04-22T10:18:02Z, event_id: 0190f52a-6f20-7c12-80aa-22bb33cc44de}
  - {from: briefed,         to: dispatched,     actor: chanakya, at: 2026-04-22T10:20:33Z, event_id: 0190f52a-6f33-7c13-80aa-22bb33cc44df}
  - {from: dispatched,      to: in-progress,    actor: achilles, at: 2026-04-22T10:22:09Z, event_id: 0190f52a-6f55-7c14-80aa-22bb33cc44e0}
  - {from: in-progress,     to: self-reviewed,  actor: achilles, at: 2026-04-22T12:40:51Z, event_id: 0190f52a-7950-7c15-80aa-22bb33cc44e1}
  - {from: self-reviewed,   to: argus-reviewed, actor: argus,    at: 2026-04-22T12:45:30Z, event_id: 0190f52a-7a00-7c16-80aa-22bb33cc44e2}
  - {from: argus-reviewed,  to: merged,         actor: achilles, at: 2026-04-22T12:48:17Z, event_id: 0190f52a-7a80-7c17-80aa-22bb33cc44e3}
```

## Example — 1.1.0 with lean fields populated

```yaml
schema_version: {name: task, version: 1.1.0, min_reader: 1.0.0, deprecated_at: null}
id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11
title: "Add filter preset row"
type: feature
state: merged
size: m
priority: p2
created_at: 2026-04-22T10:15:00Z
updated_at: 2026-04-22T12:48:17Z
labels: ["theme/photo-editor", "train/filter-presets"]
parent: 0190f52a-1000-7000-8000-000000000001    # epic: photo-editor refresh
train: filter-presets
release_target: "tf-247"
released_in: null
predecessors:
  - 0190f52a-6c00-7000-8000-aabbccddeeff        # filter-store landing
similar_to: []
affinity:
  touchpoints:
    - "Project/FilterPreset/**"
  prefers_node: null
origin: human
effort_minutes: 75
recommended_model: sonnet
reopen_reason: null
reopen_chain: []
duplicate_of: null
verification:
  debrief_id: 0190f52a-79aa-7d02-8b88-33ce5fe65e66
  review_id: 0190f52a-7a11-7e03-8c99-44df6fd77a77
  merge_sha: a1b2c3d4e5f60718293a4b5c6d7e8f90
  build_id: null
links:
  brief: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c
  debrief: 0190f52a-79aa-7d02-8b88-33ce5fe65e66
  reviews:
    - 0190f52a-7a11-7e03-8c99-44df6fd77a77
  release: null
  feedback: []
history:
  - {from: null,            to: proposed,       actor: chanakya, at: 2026-04-22T10:15:00Z, event_id: 0190f52a-6e0c-7c11-80aa-22bb33cc44dd}
  - {from: proposed,        to: briefed,        actor: chanakya, at: 2026-04-22T10:18:02Z, event_id: 0190f52a-6f20-7c12-80aa-22bb33cc44de}
  - {from: briefed,         to: dispatched,     actor: chanakya, at: 2026-04-22T10:20:33Z, event_id: 0190f52a-6f33-7c13-80aa-22bb33cc44df}
  - {from: dispatched,      to: in-progress,    actor: achilles, at: 2026-04-22T10:22:09Z, event_id: 0190f52a-6f55-7c14-80aa-22bb33cc44e0}
  - {from: in-progress,     to: self-reviewed,  actor: achilles, at: 2026-04-22T12:40:51Z, event_id: 0190f52a-7950-7c15-80aa-22bb33cc44e1}
  - {from: self-reviewed,   to: argus-reviewed, actor: argus,    at: 2026-04-22T12:45:30Z, event_id: 0190f52a-7a00-7c16-80aa-22bb33cc44e2}
  - {from: argus-reviewed,  to: merged,         actor: achilles, at: 2026-04-22T12:48:17Z, event_id: 0190f52a-7a80-7c17-80aa-22bb33cc44e3}
```

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.3.0 | 2026-05-18 | Added optional `links.crashes` for crash-fix task traceability. Public propagation through worker prompts, commits, build summaries, release notes, and post-release annotations must use the crash schema's public-safe projection. Non-breaking; `min_reader: 1.0.0`. |
| 1.2.0 | 2026-04-27 | Added `caused_by` (regression / fallout provenance — UUIDv7 array; default `[]`). Forward-only; inverse `causes` is computed at read time by `scripts/query-relations.sh`. Non-breaking; `min_reader: 1.0.0`. New "Relation edges" section enumerates the forward/inverse model across all existing edges. (#282) |
| 1.1.0 | 2026-04-27 | Lean fields landed (#247 Stage C deliverable 2): `type`, `priority`, `labels`, `parent`, `train`, `release_target`, `released_in`, `predecessors`, `similar_to`, `affinity`, `origin`, `effort_minutes`, `recommended_model`, `reopen_reason`, `reopen_chain`, `duplicate_of`, `verification`. All optional with documented defaults — non-breaking; `min_reader: 1.0.0`. `reopened` reserved in state enum for #252. |
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing — per-task YAML replaces master-plan inline blocks. |

## Related

- `state-machines/task-lifecycle.md` — authoritative state + transition list.
- `primitives/agent-comms-boundary.md` — writer / lifecycle-co-writer matrix governing who may mutate which field.
- `schemas/brief.md` / `schemas/debrief.md` / `schemas/review.md` / `schemas/release.md` — artifacts referenced by `links` and `verification`.
- `contracts/plans-index-validator.md` — bidirectional reference + `verification`-block drift checks.
- `contracts/schema-version.md` — envelope semantics.
- `contracts/EVOLUTION.md` — additive-only evolution rules followed by 1.0.0 → 1.1.0.
