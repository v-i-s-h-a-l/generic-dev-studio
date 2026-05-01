---
name: Chanakya Blocked-By
description: Reverse predecessors lookup. Given a task id, list every task whose predecessors[] contains it — i.e. every task whose dispatch is blocked on this one shipping.
type: mode-pack
schema_version: 1
budget_tokens: 400
snapshots: []
reads:
  - plans/tasks/*.yaml                             # predecessors[] lives per-task; inverse computed at read time
writes: []
---

# Mode: Blocked-By (`/chanakya blocked-by <task-id>`)

Inverse of the `predecessors` edge: lists every task that names `<task-id>` in its `predecessors[]`. Answers "if I ship T347, what unblocks?" Same data source as `query-relations.sh --task <id> | inverse.blocks`, surfaced as a first-class command.

## Steps

The id can be either a UUIDv7 or a legacy `T<nnn>`. Resolve via `query-relations.sh` when the user passes a legacy id; otherwise pass through.

```bash
scripts/query-plans.sh --blocked-by="$TASK_ID"
```

## Render

Group by `state` (lifecycle order). For each blocked task, render: `<id>  <state>  <train|->  <title>`.

Headline line: "<N> tasks blocked on <task-id>" (substituting counts and id).

## Empty result

When nothing is blocked-by the input task, print exactly: "No tasks list <task-id> as a predecessor." Then suggest: "If this task ships, no downstream dispatch is unblocked."

## Cross-links

- `/chanakya status --task <id>` — full forward + inverse relation graph.
- `scripts/query-relations.sh` — same inverse computation, broader output (children, duplicates, causes).
- Task schema: `_shared/schemas/task.md` § Relation edges — `predecessors` + computed `blocks`.
