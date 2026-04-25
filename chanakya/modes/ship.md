---
name: Chanakya Ship
description: Brief + dispatch composite. Resolves targets, checks debt gates, briefs pending tasks, phases dispatch (fleet mode via work-stealing queue; single-session prints commands).
type: mode-pack
schema_version: 1
snapshots: [briefs.json, debt.json]
budget_tokens: 2500
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/briefs/*.yaml                            # post-migration brief artifacts
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-tasks/*.md                      # legacy fallback until Commit H
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
  - .runtime/achilles-inbox/worker-*/alive         # worker heartbeats (fleet-mode detect)
writes:
  - .runtime/achilles-inbox/queue/*.json           # queue enqueues in fleet mode
---

# Composite: Ship (`/chanakya ship <target>`)

Brief and dispatch tasks to Achilles in a single command. This is the "hands-off" mode — Chanakya briefs, then tells the user exactly which `/achilles` commands to run in parallel.

Snapshots: `snapshots/briefs.json` (5-min freshness; post-migration fallback is `scripts/query-plans.sh --kind=task,brief`, with a `chanakya-master.md` direct read still honored during Phase 2.6 transition). `snapshots/debt.json` for the debt-gate filter (fallback: master-plan debt block).

## Target parsing

- `ship T001` → ship a specific task (and its test sub-tasks)
- `ship T001,T002,T003` → ship multiple specific tasks
- `ship next` → ship the highest-priority `pending` or `briefed` task
- `ship next 3` → ship the top 3 ready tasks
- `ship all` → ship every `pending` or `briefed` task that isn't blocked

## Steps

1. **Resolve targets.** Based on the argument, collect the task list. Include test sub-tasks that are unblocked (parent is `done`).
2. **Check debt gates.** Same filtering as brief-all.
3. **Brief any `pending` tasks** in the target list. Run Brief Generation mode for each. Skip already-briefed tasks.
4. **Generate dispatch plan.** Analyze dependencies and produce a phased execution plan:

   ```
   Phase 1 (parallel — no dependencies):
     Tab 1: /achilles T001
     Tab 2: /achilles T003
   
   Phase 2 (after Phase 1 merges):
     Tab 1: /achilles T002          ← depends on T001
     Tab 2: /achilles T001a         ← unit tests for T001
     Tab 3: /achilles T001c         ← UI tests for T001
   
   Phase 3 (after Phase 2 merges):
     Tab 1: /achilles T002a         ← unit tests for T002
   ```

5. **Dispatch Phase 1.** In **fleet mode** (any alive worker dir present): enqueue every Phase 1 task via `--queue-enqueue`, then call `--queue-drain` once. Workers pick tasks up via `fswatch`; further drains fire automatically on each `task_completed` (Step 0E of review mode). Phase 2+ tasks wait in the queue until their dependency resolves and can be enqueued by the auto-advance step below. In **single-session mode** (no alive workers): fall back to printing `/achilles` commands for the user to run in parallel tabs.
6. Report: "Ship plan generated. Phase 1: N tasks enqueued (queue depth=N, free workers=W). Further phases will auto-dispatch as tasks complete — no need to re-run `ship`."

**Auto-advance:** After each `/chanakya status` or inbox sweep, if all Phase 1 tasks are `done`, automatically print the Phase 2 commands. The user doesn't need to re-run `ship`.
