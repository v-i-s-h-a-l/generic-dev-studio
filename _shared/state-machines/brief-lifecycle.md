---
name: Brief Lifecycle State Machine
description: States the brief artifact transits — draft, ready, dispatched, debriefed, superseded or archived. Runs parallel to the task lifecycle but lives in the brief file, not the task record.
type: reference
---

# Brief Lifecycle

The brief is a separate artifact from the task, with its own lifecycle. Task state is about "what the work is doing"; brief state is about "what this particular specification is doing". A task may have multiple briefs across rework cycles — each carries its own lifecycle trace.

## States

| State | Meaning |
|---|---|
| `draft` | Chanakya is authoring. Not yet ready for dispatch. |
| `ready` | Brief complete, meets minimum-viable format (`brief@>=2`), dispatchable. |
| `dispatched` | Placed in worker inbox or picked up by interactive Achilles. |
| `debriefed` | Achilles merged its debrief back. Brief is consumed. |
| `superseded` | Replaced by a newer brief for the same task (rework). Terminal. |
| `archived` | Debriefed brief moved to cold storage. Terminal. |

## Transitions

```
draft       → ready        : brief passes `brief@>=2` validation.
ready       → dispatched   : Chanakya places in inbox / Achilles picks up.
dispatched  → debriefed    : Achilles writes debrief.
debriefed   → archived     : compact sweep moves to archive.
ready       → superseded   : newer brief for the same task lands with `rework_of: <task-id>`.
dispatched  → superseded   : mid-flight replacement (rare; task usually cancelled + re-briefed).
draft       → superseded   : abandoned draft.
```

## Events

Emit `brief_state_changed` on every transition (except internal `draft` sub-steps):

```json
{
  "ts": "…",
  "agent": "chanakya",
  "event": "brief_state_changed",
  "task": "T001",
  "data": {
    "from_state": "ready",
    "to_state": "dispatched",
    "brief_version": "2.1.0",
    "brief_path": "~/.dev-studio/<project>/plans/chanakya-tasks/T001-impl.md"
  }
}
```

## Pairing with task lifecycle

The brief lifecycle aligns with the task lifecycle at two points:

- `brief: ready` is a precondition for `task: briefed → dispatched`.
- `brief: debriefed` is coincident with `task: self-reviewed` (Achilles writes both in the same step).

Otherwise the two machines run independently. A task in `rejected` returns to `briefed`; the old brief enters `superseded`; a new brief starts in `draft`.

## Related

- `task-lifecycle.md` — task state machine.
- `brief-formats/` — per-task-type brief templates.
- `events.md` — `brief_state_changed` catalog entry.
