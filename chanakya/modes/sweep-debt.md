---
name: Chanakya Sweep-Debt
description: Identify and dispatch all pending debt-reduction tasks (test sub-tasks + build checks) in one command.
type: mode-pack
schema_version: 1
snapshots: [briefs.json, debt.json]
budget_tokens: 2000
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/briefs/*.yaml                            # post-migration brief artifacts (for briefed check)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes: []
---

# Composite: Sweep-Debt (`/chanakya sweep-debt`)

Identify and dispatch all pending work needed to reduce build and test debt below warn thresholds. One command to get back to green.

Snapshots: `snapshots/debt.json` for counter state (5-min freshness; fallback: read master-plan debt block). `snapshots/briefs.json` for the pending-test-task selection (5-min freshness; fallback post-migration is `scripts/query-plans.sh --kind=task`, with a `plans/chanakya-master.md` scan still honored during Phase 2.6 transition).

## Steps

1. **Read all three debt counters** from the master plan.
2. **Collect actionable tasks:**
   - **Build debt:** If `State: warn` or `block`, include the open `TBUILD-<n>` task (or file one if none exists).
   - **Unit test debt:** Collect all `pending` or `briefed` test-unit sub-tasks whose parent is `done`. These are the tasks that will decrement the counter.
   - **UI test debt:** Same for test-ui sub-tasks.
3. **Brief any un-briefed tasks** from the collected set.
4. **Generate dispatch plan** (same phased format as `ship`). Test sub-tasks are independent of each other and can run in parallel. The build check should run last (after test tasks merge, so the build includes test code).
5. **Estimate impact:** "Running these N tasks will reduce: build debt 8→0, unit test debt 5→2, UI test debt 3→1."
6. Report with the dispatch commands.

If all three counters are in `silent` state: "All debt counters are green. Nothing to sweep."

Full debt-counter schema + thresholds: `_shared/rules/debt-tracking.md`.
