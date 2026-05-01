---
name: Chanakya Dispatch-Ready
description: Briefed tasks where every predecessor has reached merged/verified/archived. The fleet-wide "what can I dispatch right now?" query, grouped by train.
type: mode-pack
schema_version: 1
budget_tokens: 800
snapshots: []
reads:
  - plans/tasks/*.yaml                             # state + predecessors + train + effort_minutes + recommended_model live per-task
writes: []
---

# Mode: Dispatch-Ready (`/chanakya dispatch-ready`)

The "what's safe to dispatch right now?" query. A task is dispatch-ready when:

1. `state == briefed`
2. Every id in `predecessors[]` resolves to a task whose `state ∈ {merged, verified, archived}`

Empty `predecessors[]` is vacuously ready.

## Steps

```bash
scripts/query-tasks.sh --dispatch-ready --format=json
```

Render the result grouped by `train` (tasks without a train fall under `ad-hoc`). Within each train group, sort by `priority` ascending (`p0` first), then `updated_at` ascending so the longest-briefed task surfaces first.

For each row, surface six columns: `<id>  <priority>  <effort_minutes|->  <recommended_model|->  <title>  <summary|->`. `query-tasks.sh --format=json` includes `priority`, `effort_minutes`, `recommended_model`, and `brief_summary` from the linked brief, so this mode uses the compact slice without loading the full brief body:

```bash
scripts/query-tasks.sh --dispatch-ready --format=json \
  | jq -r 'group_by(.train // "ad-hoc")[]
           | "## " + (.[0].train // "ad-hoc"),
             (sort_by(.priority, .updated_at)[]
              | [.id, .priority, (.effort_minutes // "-" | tostring),
                 (.recommended_model // "-"), .title, (.brief_summary // "-")] | @tsv)'
```

## Empty result

If nothing is dispatch-ready, print exactly: "No briefed tasks have all predecessors resolved." Then suggest: "Run `/chanakya status` to see what's in flight, or `/chanakya brief-all` to brief any pending proposals."

## Suggest next action

When dispatch-ready tasks exist, surface a one-line dispatch hint per train, e.g.:

> "train/comms-revamp: 3 ready (T350 p0 sonnet 75m). Dispatch with `/achilles next`."

## Cross-links

- `/chanakya train dispatch-ready <name>` — train-scoped variant.
- `/chanakya status` — fleet view; this mode is a focused projection.
- Dispatch gating contract: `_shared/schemas/task.md` § Dispatch gating — predecessor resolution rule.
