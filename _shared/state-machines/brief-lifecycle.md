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
null        → draft        : write_brief_artifact awaiting_user=true|false; brief is mid-authoring.
null        → ready        : write_brief_artifact state=ready; brief is final at mint (urgent-ingest, atomic flows).
draft       → ready        : brief passes `brief@>=2` validation; lint clean.
ready       → dispatched   : Chanakya places in inbox / Achilles picks up.
dispatched  → debriefed    : Achilles writes debrief.
debriefed   → archived     : compact sweep moves to archive.
ready       → superseded   : newer brief for the same task lands with `rework_of: <task-id>`.
dispatched  → superseded   : mid-flight replacement (rare; task usually cancelled + re-briefed).
draft       → superseded   : abandoned draft.
```

## Mint-intent contract

`write_brief_artifact` requires the caller to declare exactly one of:

- `state=ready` — brief is final at mint; skip draft. Suitable for urgent-ingest fast-path and atomic flows where authoring + lint happen pre-mint. Fires `brief_state_changed null → ready`.
- `awaiting_user=true` — brief is `draft` AND its body contains an `## Open questions` (or `## Decisions pending` / `## Awaiting decision` / `## Author pass`) section. Fires `brief_state_changed null → draft` + `brief_awaiting_user` so a sweep surfaces the unresolved decisions. Refuses if no decision section.
- `awaiting_user=false` — brief is `draft` for incremental authoring; caller will lint and call `transition_brief_state ready` before any sweep / dispatch. Fires `brief_state_changed null → draft` only.

Calls without one of these arguments are refused with exit 2 to prevent the T352-class procedural miss (draft brief filed with author-questions but no surfacing signal).

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

## Re-claim rules (#221)

A second `dispatched` transition on an already-`dispatched` brief is a duplicate claim. `scripts/task-claim.sh` enforces these rules before applying any state mutation:

| Condition | Outcome |
|---|---|
| Brief state ≠ `dispatched` | Normal claim — proceed. |
| Brief `dispatched` + worktree dir gone | Orphan reclaim — stale sidecar removed; proceed with a warning. |
| Brief `dispatched` + worktree dir alive | **Refuse — exit 4.** Active session holds the claim. |
| Brief `dispatched` + worktree alive + `--steal` | Force-override — warning emitted; claim transferred. |
| Brief `dispatched` + worktree alive + `ACHILLES_RECLAIM_OK=1` | Env override — same as `--steal`. |

**Claim sidecar.** On a successful claim, `task-claim.sh` writes `plans/briefs/<brief-uuid>.claim` alongside the brief YAML. It contains `{worker_id, claimed_at, task_uuid}` and is removed by `task-merge.sh` at Step 10. A missing sidecar on an otherwise-`dispatched` brief is not an error — the file may have been absent from a pre-#221 run.

**Worktree as liveness proxy.** The claim is considered live as long as the worktree directory `~/.dev-studio/<project>/worktrees/<task-uuid>` exists. The worktree is created at Step 3 and removed at Step 10 (`task-merge.sh`). If Achilles crashes between Steps 3 and 10 without cleanup, the worktree persists — use `--steal` or `ACHILLES_RECLAIM_OK=1` to force reclaim after verifying the session is truly dead.

## Related

- `task-lifecycle.md` — task state machine.
- `brief-formats/` — per-task-type brief templates.
- `events.md` — `brief_state_changed` catalog entry.
- `scripts/task-claim.sh` — enforces re-claim rules at Step 2.
- `scripts/task-merge.sh` — removes claim sidecar at Step 10.
