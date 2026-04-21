---
name: Chanakya Update
description: Cross-reference git state with the master plan and auto-close tasks whose branches have merged.
type: mode-pack
snapshots: []
budget_tokens: 2000
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/chanakya-master.md                       # legacy fallback until Commit H
writes:
  - plans/tasks/*.yaml                             # post-migration state transitions (emission switches to YAML in Commit G)
  - plans/chanakya-master.md                       # legacy write target during Phase 2.6 transition
---

# Mode: Update (`/chanakya update`)

## Step 1 — Scan git state

```
git worktree list
git branch -a --sort=-committerdate
```

## Step 2 — Cross-reference with task index

Post-migration: for each in-progress task (via `scripts/query-plans.sh --kind=task --state=in-progress`), check if its branch has been merged. If merged, auto-mark as `done`. Legacy fallback: iterate in-progress tasks from `plans/chanakya-master.md`.

## Step 3 — Write state transitions

Post-migration: update `plans/tasks/<task-id>.yaml` `state` + append `history` entry (schema: `_shared/schemas/task.md`); `scripts/rebuild-index.sh` regenerates `plans/index.yaml`. Legacy write target during Phase 2.6 transition: `plans/chanakya-master.md`. YAML emission lands in Commit G. Report changes. Suggest next action.
