---
name: Chanakya Review (PRD delta)
description: Explicit `/chanakya review` sub-command — user pastes updated PRD and Chanakya diffs it against the current master plan / task index, marking affected tasks as `needs-rework`, regenerating stale briefs, and adding new task entries for new requirements. The pre-dispatch inbox sweep (Steps 0A–0G) has moved to `modes/inbox-sweep.md` — this mode pack only loads when the user explicitly runs `/chanakya review`.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json]
budget_tokens: 800
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/*.yaml                            # brief lookup for re-generation of stale briefs
  - plans/chanakya-master.md                       # legacy fallback until Commit H
writes:
  - plans/tasks/<task-id>.yaml                     # state transitions (→ needs-rework) and delta notes
  - plans/tasks/<new-task-id>.yaml                 # newly-minted tasks for requirements not present before
  - plans/briefs/<brief-id>.yaml                   # regenerated briefs for stale ones
  - plans/chanakya-master.md                       # legacy master-plan row mutation during Phase 2.6 transition (dual-write)
  - plans/chanakya-tasks/<task-id>-<slug>.md       # legacy regenerated brief markdown during Phase 2.6 transition (dual-write, via delegated brief-mode regeneration)
  - plans/index.yaml                               # via scripts/rebuild-index.sh
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Review (`/chanakya review` — PRD delta)

Diff an updated PRD against the current master plan. The pre-dispatch inbox sweep (Steps 0A–0G) already ran before this mode was invoked — its procedure lives in `modes/inbox-sweep.md`.

## Step 1 — Get the updated requirements

Ask: "Paste the updated PRD, describe the changes, or give me the file path."

## Step 2 — Diff against master plan

For each change, classify:

- **No impact** — doesn't touch any existing task
- **Pending/briefed task affected** — update description, mark brief as stale
- **Done/verified task needs rework** — set task state to `needs-rework`, explain delta
- **New work** — create new task entries

## Step 3 — Present change report

```
PRD Delta:
- T001 (export flow) — VERIFIED, affected: new HEIF format requirement
  Rework scope: add HEIF encoder option, ~S complexity
- T003 (texture browse) — BRIEFED, affected: grid changed from 2-col to 3-col
  Brief is stale, needs regeneration
- NEW: T006 — Watermark toggle (not in previous PRD)
```

## Step 4 — Apply and report

Update the task artifacts (post-migration: `plans/tasks/<task-id>.yaml` state + `history`; legacy: `chanakya-master.md` row). Auto-regenerate any stale briefs (invoke Brief Generation mode for each). Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`. Emit `task_state_changed` events for each mutated task.

For **NEW** tasks from Step 2, allocate each `legacy_task_id` via `scripts/next-task-id.sh` (one call per new task; each returns the next sequential T-number). Never pick a T-number from context — the script is the authoritative source across YAML + master plan + legacy dir + event log.

Report which briefs were updated and which tasks were marked `needs-rework`.

## Cross-cutting

Debt counter rules: `_shared/rules/debt-tracking.md`. Principles: `_shared/patterns/chanakya-principles.md`. Inbox sweep procedure: `modes/inbox-sweep.md`.
