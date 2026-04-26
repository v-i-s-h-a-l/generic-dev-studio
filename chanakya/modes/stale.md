---
name: Chanakya Stale
description: Tasks stuck in their current state longer than N days. Default --days=7. Surfaces forgotten briefed tasks, abandoned in-progress branches, and merged tasks awaiting verification.
type: mode-pack
schema_version: 1
budget_tokens: 600
snapshots: []
reads:
  - plans/tasks/*.yaml                             # history[-1].at (latest transition timestamp) lives per-task
writes: []
---

# Mode: Stale (`/chanakya stale [--days=N] [--state=<state>]`)

Surface tasks where the most recent state transition is older than N days. Default window is 7 days. The age signal comes from `history[-1].at` (latest transition); when `history` is empty, falls back to `updated_at`.

## Steps

### Default (all states, last-7-day cutoff)

```bash
scripts/query-tasks.sh --state-age-gt=7
```

### Filter to one state

```bash
scripts/query-tasks.sh --state=briefed --state-age-gt=14
```

### Custom window

```bash
scripts/query-tasks.sh --state-age-gt="$DAYS"
```

## Render

Group by `state` (lifecycle order). Within each group, sort by age descending — oldest first. Each row: `<id>  <state>  <age-days>d  <train|->  <title>`.

When the result set is empty, print exactly: "No stale tasks beyond N days." (substituting the cutoff).

## Suggest next action

For each stale group, surface the canonical follow-up:

| State | Canonical next action |
|---|---|
| `proposed` | "/chanakya brief <id>" |
| `briefed` | "/chanakya dispatch-ready" then dispatch |
| `dispatched` / `in-progress` | check worker status; consider `/chanakya janitor` |
| `merged` | "/chanakya verify --task <id>" |
| `blocked` | review the blocker; consider `/chanakya reopen` if stale |

Suggestions are advisory — print under each group as one line.

## Output discipline

Pipeable. No Step 0 inbox sweep for this mode (read-only query). Surfacing is the contract; mutation is up to the user.
