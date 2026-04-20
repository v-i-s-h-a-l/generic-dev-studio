---
name: Chanakya Update
description: Cross-reference git state with the master plan and auto-close tasks whose branches have merged.
type: mode-pack
snapshots: []
budget_tokens: 2000
---

# Mode: Update (`/chanakya update`)

## Step 1 — Scan git state

```
git worktree list
git branch -a --sort=-committerdate
```

## Step 2 — Cross-reference with master plan

For each in-progress task, check if its branch has been merged. If merged, auto-mark as `done`.

## Step 3 — Write updated master plan

Report changes. Suggest next action.
