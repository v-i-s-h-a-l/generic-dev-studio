---
name: Chanakya Touchpoint
description: Reverse affinity.touchpoints index. Given a file path or glob, list the last N tasks that declared they would touch it. Code archaeology — "what tasks last touched FilterPreset/**?"
type: mode-pack
schema_version: 1
budget_tokens: 600
snapshots: []
reads:
  - plans/tasks/*.yaml                             # affinity.touchpoints[] lives per-task; inverse computed at read time
writes: []
---

# Mode: Touchpoint (`/chanakya touchpoint <file-or-glob> [--limit=N]`)

Reverse `affinity.touchpoints` index. Given a file path (or glob), lists every task that declared it would touch that path. Answers "what's the history of work on `Project/FilterPreset/**`?" Same data source as `/chanakya blocked-by` and Argus diff-scope sharpening.

Field definition: `_shared/schemas/task.md` § affinity.touchpoints.

## Steps

RUN the query:

```bash
scripts/query-tasks.sh --touchpoints="$FILE_OR_GLOB" --limit="$LIMIT"
```

Default limit: 10. Results are sorted by `updated_at` descending — most recent first.

## Render

Print a headline: `N task(s) touched <file-or-glob>` (substituting the hit count and the user's input verbatim).

Print a terminal table with columns: `TASK-ID  TITLE  STATE  UPDATED  MATCHED-GLOB`.

Use fixed-width alignment. Truncate `TITLE` at 48 chars if needed. `MATCHED-GLOB` is the specific glob from the task's `affinity.touchpoints[]` that matched.

## Empty result

When the script returns no rows, print:

> No tasks declared touchpoints matching `<path>`.

Then suggest:

> Add `affinity.touchpoints` to the brief when authoring the next task that touches this path — run `/chanakya brief` and the brief mode populates the field.

## Limit flag

`/chanakya touchpoint <path> --limit=N` overrides the 10-task default. When a non-default limit is active, surface it in the headline: `Top N task(s) by recency touched <path>`.

## Cross-links

- `/chanakya blocked-by <task-id>` — same reverse-index pattern, different edge (`predecessors`).
- `_shared/schemas/task.md` § affinity — source field definition, upstream writers.
