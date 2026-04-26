---
name: Agent Comms Boundary
description: Single source of truth for cross-agent message flow. Defines the six message classes, the authorial writer for each, the lifecycle co-writers permitted to flip state-machine fields, and the readers. Lints against capability-manifest declarations to prevent boundary drift.
type: reference
---

# Agent Comms Boundary

The contract that defines **who is allowed to write which cross-agent artifact, on which fields, under which conditions**. Every mode pack's `reads:` / `writes:` declaration is checked against this primitive by `scripts/lint-comms-boundary.sh`.

Without this primitive, every new feature re-derives the boundary, gets it slightly wrong, and the comms layer accretes inconsistency. #76 (writers mutating legacy without YAML), #195 (merge without debrief), and #206 (legacy IDs leaking into normal flow) were all symptoms of an undocumented boundary.

## The invariant

> **Every cross-agent artifact has exactly ONE authorial writer.** Other agents may act as lifecycle co-writers — but only on fields named in the artifact's state machine, append-only, never mutating payload. Pass-through agents do not mutate.

Three operational consequences:

1. A new mode pack proposing to **create** an artifact kind already owned by another agent is a boundary violation — the linter blocks.
2. A mode pack proposing to **mutate fields outside the lifecycle co-writer allowlist** is a boundary violation — the linter blocks.
3. A mode pack proposing to **read** an artifact is always allowed — readers are not gated.

## Writer ownership model

Two writer roles per artifact class:

| Role | Cardinality | What it does | What it must not do |
|---|---|---|---|
| **Authorial writer** | exactly 1 agent | Creates the file, owns the payload, sets the initial state | — |
| **Lifecycle co-writer** | 0..N agents | Appends to history, flips state per the artifact's state machine, updates back-ref `links.*` fields | Mutate payload fields, create the artifact, change state outside the lifecycle |

The lifecycle co-writer set is **enumerated** in each row below — it is not open-ended. A mode pack declaring writes against an artifact it is not the authorial writer of must justify the write through one of the listed co-writer surfaces.

## The six message classes

| # | Message | Authorial writer | Lifecycle co-writers (fields they may touch) | Readers | Schema | Transport | State machine | Cardinality |
|---|---|---|---|---|---|---|---|---|
| 1 | **Brief** | Chanakya | Chanakya `review` (regenerates stale briefs — full rewrite under the existing `brief-id`); Achilles `task` (state: `dispatched → debriefed` per brief-lifecycle) | Achilles | [`schemas/brief.md`](../schemas/brief.md) — `brief@3.1.0` | `plans/briefs/<brief-id>.yaml` | [`state-machines/brief-lifecycle.md`](../state-machines/brief-lifecycle.md) | 1 per task |
| 2 | **Debrief** | Achilles | Chanakya `inbox-sweep` (state: `emitted → ingested → superseded`) | Chanakya, knowledge layer (Phase 2.7) | [`schemas/debrief.md`](../schemas/debrief.md) — `debrief@2.0.2` | `plans/debriefs/<debrief-id>.yaml` | (state field embedded in schema, §`state` enum) | 1 per task or direct-debrief |
| 3 | **Review verdict** | Argus | Chanakya `verify` (consumes; no field mutation today); Argus itself appends `events/<date>.jsonl` review events as state changes | Chanakya, Achilles | [`contracts/review-verdict.schema.json`](../contracts/review-verdict.schema.json) — `review@1.1.0` | `plans/reviews/<review-id>.yaml` | [`state-machines/review-lifecycle.md`](../state-machines/review-lifecycle.md) | 1+ per task (re-reviews append) |
| 4 | **Event** | any | — (events are immutable; append-only stream — no co-writers, no state) | Chanakya (primary); Achilles `worker` (status); Argus `code-quality` (prior-review lookup) | [`contracts/events.md`](../contracts/events.md) catalog + [`contracts/event-emission.md`](../contracts/event-emission.md) | `events/<YYYY-MM-DD>.jsonl` | — | streaming |
| 5 | **Master-plan row** | `scripts/render-master-plan.sh` (post Commit H — render-only) | none post-flip; pre-flip transitional dual-write tolerated and lint-warned (not blocked) until #245 lands | user, dashboards | [`schemas/master-plan.md`](../schemas/master-plan.md) — markdown surface | `plans/chanakya-master.md` | — (projection of `plans/tasks/*.yaml`) | 1 row per task — generated |
| 6 | **Follow-up task** | Chanakya | Achilles `task` / `push-tf` / `app-store` (back-refs: `links.debrief`, `links.release`; state transitions per task-lifecycle); Argus `code-quality` (back-ref: `links.reviews` append) | Chanakya, user | [`schemas/task.md`](../schemas/task.md) — `task@1.0.0` (→ `task@1.1.0` per #247) | `plans/tasks/<task-id>.yaml` | [`state-machines/task-lifecycle.md`](../state-machines/task-lifecycle.md) | N per task lineage |

**Single-agent classes** (feedback, round, release) are not on the cross-agent boundary — both authorial writer and all lifecycle writers are the same agent — but they follow the same model. `release` is the borderline case: Achilles is authorial writer (`push-tf`, `app-store`), Chanakya `inbox-sweep` is the lifecycle co-writer (release state transitions on debrief ingest). Treat releases as **class 7** for lint purposes once Nabu (#214) ships.

## Flow diagram

```
                       ┌──────────────────────────────┐
                       │           USER               │
                       └──────────────┬───────────────┘
                                      │  intent / feedback
                                      ▼
                       ┌──────────────────────────────┐
              ┌────────│         CHANAKYA             │────────┐
              │        │  (orchestrator + ingestor)   │        │
              │        └──────┬───────────────┬───────┘        │
              │  writes brief │       writes  │  writes        │
              │     (1)       │       task    │  master-plan   │
              │               │       (6)     │  (5, post-#245)│
              ▼               ▼               ▼                ▼
       ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  ┌──────────────┐
       │ plans/      │ │ plans/      │ │ plans/      │  │ plans/       │
       │ briefs/     │ │ tasks/      │ │ chanakya-   │  │ feedback/    │
       │             │ │             │ │ master.md   │  │ rounds/      │
       └──────┬──────┘ └──────┬──────┘ └─────────────┘  └──────────────┘
              │ reads         │ back-refs (links.*)
              │               │ + state transitions
              ▼               ▲
       ┌─────────────────────────────┐
       │         ACHILLES            │
       │  (worker — implements)      │
       └──────┬──────────────────────┘
              │ writes debrief (2)            ┌──────────────────┐
              ├────────────────────────────► │ plans/debriefs/   │
              │                              │ <id>.yaml         │
              │ (Chanakya inbox-sweep flips  └─────────┬─────────┘
              │  state: emitted→ingested)              │ reads
              │                                        ▼
              │                              ┌──────────────────┐
              │ requests review              │     CHANAKYA     │
              ▼                              │  (debrief ingest)│
       ┌─────────────────┐                   └──────────────────┘
       │     ARGUS       │
       │  (reviewer)     │
       └──────┬──────────┘
              │ writes review verdict (3)    ┌──────────────────┐
              └────────────────────────────► │ plans/reviews/   │
                                             │ <id>.yaml        │
                                             └─────────┬────────┘
                                                       │ reads
                                                       ▼
                                              CHANAKYA + ACHILLES

       ┌──────────────────────────────────────────────────┐
       │  EVENT (4) — broadcast, append-only              │
       │  Any agent ─writes─► events/<YYYY-MM-DD>.jsonl   │
       │  Chanakya tails on wake (primary reader)         │
       └──────────────────────────────────────────────────┘
```

## What "lifecycle co-writer" means concretely

A lifecycle co-writer may touch **only** the fields named in the artifact's state machine for the transition it is performing. Never the payload. Never multiple state transitions in one write. Always append to `history[]`.

Concrete examples:

```yaml
# Achilles, after merge, on plans/tasks/<task-id>.yaml:
state: argus-reviewed → merged          # ✅ allowed: in task-lifecycle
links.debrief: <new-debrief-id>          # ✅ allowed: lifecycle back-ref
history: [..., {from: argus-reviewed, to: merged, actor: achilles, at: ...}]   # ✅ append
title: "Renamed task"                    # ❌ forbidden: payload mutation by non-author

# Chanakya inbox-sweep, on plans/debriefs/<debrief-id>.yaml:
state: emitted → ingested                # ✅ allowed: in debrief lifecycle
decisions: [...]                         # ❌ forbidden: payload mutation by non-author

# Argus, on plans/tasks/<task-id>.yaml:
links.reviews: [..., <new-review-id>]    # ✅ allowed: lifecycle back-ref (append-only)
history: [..., {from: self-reviewed, to: argus-reviewed, actor: argus, at: ...}]   # ✅ append
priority: P0                             # ❌ forbidden: payload mutation by non-author
```

## Pass-through agents

Some agents read an artifact only to forward, route, or display. These agents **never write** to the artifact — reading is the entire interaction.

| Pass-through pattern | Agent | Reads | Reason |
|---|---|---|---|
| Routing display | Chanakya `status` | tasks, releases, rounds | Render-only — never mutates |
| Spec evidence | Argus `spec-compliance` | briefs, tasks | Reads to compare against debrief; verdict goes to events + (eventually) review yaml via `code-quality` |
| Worker status | Achilles `worker` | events | Status reads only — never mutates |

If a future mode pack proposes to "pass through and lightly annotate," the lint rejects unless the field-level annotation is added to the artifact's state machine first.

## Lint specification (for `scripts/lint-comms-boundary.sh`)

The linter (#247 deliverable 3) walks `_shared/schemas/capability-manifest.json` and applies these rules to every mode-pack `writes:` declaration:

**B1 — Authorial writer ownership.** For every `plans/<kind>/*.yaml` write where the writing agent is not the authorial writer named in the matrix, the declaration must include the substring `back-ref` or `state transition` (or be an `events/` write). Otherwise: **block** with `B_AUTHORIAL_WRITER_VIOLATION`.

**B2 — Forbidden creates.** For every `plans/<kind>/<id>.yaml` write (file-creation pattern, no glob), the writing agent must be the authorial writer. Otherwise: **block** with `B_FORBIDDEN_CREATE`.

**B3 — Lifecycle co-writer scope.** For every back-ref or state-transition write declared by a non-authorial writer, the lifecycle field touched must be enumerated in the matrix row's "Lifecycle co-writers" column. Otherwise: **block** with `B_LIFECYCLE_OUT_OF_SCOPE`.

**B4 — Master-plan dual-write.** Any non-render-master-plan writer of `plans/chanakya-master.md` is **warn** (`W_MASTER_PLAN_DUAL_WRITE`) until #245 (Commit H) lands; **block** thereafter.

**B5 — Pass-through purity.** A mode pack listed under "Pass-through agents" with any `writes:` declaration against the artifact it passes through is **block** with `B_PASS_THROUGH_VIOLATION`.

**B6 — Schema reference.** Every `writes:` line targeting a `plans/<kind>/` path must include a `schema:` annotation pointing at the canonical schema doc (e.g. `# schema: _shared/schemas/debrief.md`) — already present in most current declarations. Missing: **warn** with `W_MISSING_SCHEMA_REF`.

The linter loads the matrix from this primitive (parsed at lint time), not from a separate config file. **This file is the contract.**

### Synthetic violation fixture

`tests/lint-comms-boundary/violations/` (created in Session 3) holds canonical bad declarations. Smallest case: a synthetic `achilles/modes/fake.md` with `writes: plans/reviews/<review-id>.yaml` — must produce `B_AUTHORIAL_WRITER_VIOLATION` with a clear message.

## Drift findings — current state (audit 2026-04-27)

Audit of `_shared/schemas/capability-manifest.json` against this primitive surfaced:

1. **No B1/B2 violations.** Every `plans/<kind>/<id>.yaml` create-shaped write is performed by the correct authorial writer.
2. **B4 dual-writes (warn-tier, expected).** Eight Chanakya modes + two Achilles modes write to `plans/chanakya-master.md` for the Phase 2.6 transitional dual-write. All carry `# legacy ... until Commit H` annotations. Resolved by #245.
3. **B6 missing schema-ref (warn-tier, low-frequency).** A handful of `plans/index.yaml` writes lack the schema annotation. Cleanup batch in Session 3.
4. **Pass-through purity holds.** Argus `spec-compliance` writes only `events/`; never the review YAML.

No B3 (out-of-scope co-writer) violations detected — every back-ref / state-transition declaration aligns with the matrix.

## Related

- `contracts/message-contract.md` — the **envelope** every cross-agent message carries (transport-agnostic). The boundary primitive defines who's on each side; the envelope defines how the message travels.
- `contracts/read-write-decls.md` — the per-mode-pack frontmatter that this primitive lints against.
- `schemas/capability-manifest.json` — generated roster of all declarations; the linter's input data.
- `schemas/brief.md`, `schemas/debrief.md`, `schemas/task.md`, `schemas/release.md`, `schemas/feedback.md`, `schemas/round.md` — per-class shapes.
- `state-machines/brief-lifecycle.md`, `state-machines/task-lifecycle.md`, `state-machines/release-lifecycle.md`, `state-machines/review-lifecycle.md`, `state-machines/feedback-lifecycle.md` — transition definitions consumed by the lifecycle co-writer model.
- `contracts/EVOLUTION.md` — additive-only evolution rules; this primitive itself follows them.

## History

| Date | Change |
|---|---|
| 2026-04-27 | Initial landing (#247 Stage C, deliverable 1 of 3). Schema deltas (deliverable 2) and `scripts/lint-comms-boundary.sh` (deliverable 3) follow. |
