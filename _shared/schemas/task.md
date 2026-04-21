---
name: Task Schema
description: YAML shape for per-task artifacts under plans/tasks/<task-id>.yaml. One file per task. Carries state, size, links to related artifacts, and a history log of state transitions. Authoritative: task-lifecycle.md defines legal states and transitions.
type: reference
---

# Task Schema (`task@1.0.0`)

Per-task artifact written to `~/.dev-studio/<project>/plans/tasks/<task-id>.yaml`. Replaces the inline per-task markdown block in the legacy master plan. One file per task — the master plan becomes a rendered view, no longer a source of truth (Phase 2.6).

## Shape

```yaml
schema_version:
  name: task
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11       # UUIDv7
title: "Add filter preset row"
state: proposed                                  # see states table below
size: m                                          # xs | s | m | l
created_at: 2026-04-22T10:15:00Z
updated_at: 2026-04-22T10:15:00Z
links:
  brief: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c   # brief-id | null
  debrief: null                                  # debrief-id | null
  reviews: []                                    # list of review-ids
  release: null                                  # release-id | null
  feedback: []                                   # list of feedback-ids
history:
  - from: null
    to: proposed
    actor: chanakya
    at: 2026-04-22T10:15:00Z
    event_id: 0190f52a-6e0c-7c11-80aa-22bb33cc44dd   # UUIDv7 of the task_state_changed event
```

## Fields

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
| `links.reviews` | array of UUIDv7 | yes | All Argus reviews issued against the task's worktree. Append-only. |
| `links.release` | UUIDv7 \| null | yes | Release artifact the task shipped in. Null until release-flow mode links it. |
| `links.feedback` | array of UUIDv7 | yes | Feedback records that reference this task. |
| `history` | array of transition records | yes | Append-only. See §History below. |

## States

Enum values and transitions governed by `state-machines/task-lifecycle.md`:

```
proposed → briefed → dispatched → in-progress → self-reviewed → argus-reviewed → merged → user-verifying → verified
                                                                                                        → rejected → briefed (rework)
verified → archived
any      → blocked | cancelled | requeued
```

Readers MUST reject unknown state values (no silent degradation).

## Links

Back-reference invariants enforced by `contracts/plans-index-validator.md`:

- `task.links.brief = X` ⇔ `brief.task_id = task.id` and `brief.id = X`.
- Every `review-id` in `links.reviews` resolves to a `review.yaml` whose `subject.kind = task` and `subject.id = task.id`.
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

## Example — full lifecycle

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
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing — per-task YAML replaces master-plan inline blocks. |

## Related

- `state-machines/task-lifecycle.md` — authoritative state + transition list.
- `schemas/brief.md` / `schemas/debrief.md` / `schemas/review.md` — artifacts referenced by `links`.
- `contracts/plans-index-validator.md` — bidirectional reference checks.
- `contracts/schema-version.md` — envelope semantics.
