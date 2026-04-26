---
name: Chanakya Update
description: Cross-reference git state with the master plan and auto-close tasks whose branches have merged.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 2000
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
writes:
  - plans/tasks/*.yaml                             # state transitions via lib-ledger
---

# Mode: Update (`/chanakya update`)

## Step 1 — Scan git state

```
git worktree list
git branch -a --sort=-committerdate
```

## Step 2 — Cross-reference with task index


## Step 3 — Write state transitions

