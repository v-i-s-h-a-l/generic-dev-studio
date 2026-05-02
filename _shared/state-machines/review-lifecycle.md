---
name: Review Lifecycle State Machine
description: Argus review sub-states from pending through in-progress to verdict to acknowledged. Owned by Argus; read by Achilles and Chanakya.
type: reference
---

# Review Lifecycle

Argus reviews have their own short-cycle state machine, separate from task and brief. This lets consumers (Achilles waits for a verdict; Chanakya files follow-ups on `flagged`) watch a review without conflating it with the task's status.

## States

| State | Meaning |
|---|---|
| `pending` | Argus has been invoked; review not yet started. |
| `in-progress` | Argus is actively reading diff + running checks. `.argus-running` marker exists. |
| `approved` | All checks passed. Safe to merge. |
| `flagged` | Non-blocking findings. Safe to merge; Chanakya files follow-ups. |
| `blocked` | Hard block (secrets, base staleness Achilles can't fix, dispatch timeout, etc.). Do not merge. |
| `acknowledged` | Terminal. Achilles or Chanakya consumed the verdict and acted. |

## Transitions

```
pending      → in-progress  : Argus writes `.argus-running` marker.
in-progress  → approved     : all checks green.
in-progress  → flagged      : findings but not blocking.
in-progress  → blocked      : hard block, including dispatch timeout (`review_timeout`).
approved     → acknowledged : Achilles proceeds to merge.
flagged      → acknowledged : Achilles proceeds; Chanakya files follow-up.
blocked      → acknowledged : Achilles fixes and re-invokes, or surfaces to user.
```

## Events

Existing `review_requested` / `review_approved` / `review_flagged` / `review_blocked` (per `events.md`) already cover the terminal transitions. Additive under this lifecycle:

```json
{
  "ts": "…",
  "agent": "argus",
  "event": "review_state_changed",
  "task": "T001",
  "data": {
    "from_state": "pending",
    "to_state": "in-progress"
  }
}
```

Emission policy: emit `review_state_changed` on `pending → in-progress` only (the other transitions are already covered by verdict events). Avoids duplication.

## Pairing with task lifecycle

- `task: self-reviewed` precedes `review: pending`.
- `review: approved | flagged` permits `task: argus-reviewed → merged`.
- `review: blocked` forces `task: argus-reviewed → blocked` unless Achilles can fix.

## Related

- `task-lifecycle.md` — task state machine.
- `events.md` — `review_requested` / `review_*` / `review_state_changed` catalog.
- `review-rules.md` — the checks Argus runs that drive verdicts.
