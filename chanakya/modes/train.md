---
name: Chanakya Train
description: Per-train view of tasks via the lean-schema `train` field. Sub-modes — list (unique trains), show (tasks by state), dispatch-ready (train-scoped), burn-down (state counts).
type: mode-pack
schema_version: 1
budget_tokens: 800
snapshots: []
reads:
  - plans/tasks/*.yaml                             # train + predecessors + history live in per-task files (not index)
writes: []
---

# Mode: Train (`/chanakya train <show|list|burn-down|dispatch-ready> [name]`)

Query layer over the per-task `train` field (lean schema 1.1.0). Index.yaml does not carry `train`, so every sub-command walks `plans/tasks/*.yaml` via `scripts/query-tasks.sh`.

## Sub-commands

### `list` — unique train names

```bash
scripts/query-tasks.sh --format=json | jq -r '.[].train // empty' | sort -u
```

Print one train per line; tasks without a train are omitted.

### `show <name>` — all tasks in train

```bash
scripts/query-tasks.sh --train="$NAME"
```

Render as a table grouped by `state` (in lifecycle order: proposed → briefed → dispatched → in-progress → self-reviewed → argus-reviewed → merged → user-verifying → verified → archived). Within each state group, sort by `updated_at` ascending.

### `dispatch-ready <name>` — ready-to-dispatch in train

```bash
scripts/query-tasks.sh --train="$NAME" --dispatch-ready
```

Same as `/chanakya dispatch-ready` but train-scoped. Sort by `updated_at` ascending so the longest-briefed task surfaces first.

### `burn-down <name>` — state counts

```bash
scripts/query-tasks.sh --train="$NAME" --format=json \
  | jq 'group_by(.state) | map({state: .[0].state, count: length})'
```

One-line summary: `<train>: 3 briefed, 2 in-progress, 5 merged, 4 verified (14 total)`.

## Default sub-command

If no sub-command is supplied, dispatch to `show` when a name is given, else `list`.

## Output discipline

Pipeable. No banners. The default Step 0 inbox sweep does NOT run for this mode — it is a read-only query over plans/, not a triage pass.

## Cross-links

- `/chanakya dispatch-ready` — fleet-wide variant of this mode's `dispatch-ready` sub-command.
- `/chanakya status --task <id>` — per-task drill-down.
- Task schema: `_shared/schemas/task.md` § Lean fields (1.1.0) — `train`.
