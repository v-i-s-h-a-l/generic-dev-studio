---
name: Task ID Topic Blocks
description: Block-aware allocation rules for human-readable `legacy_task_id` (T-numbers). Consumed by Chanakya's intake, urgent-ingest, and review modes via `scripts/next-task-id.sh`.
type: rule
---

# Task ID topic-block allocation

`legacy_task_id` (T001, T002, …) is the human-readable display token paired with each task's UUIDv7 canonical id. It is allocated by `scripts/next-task-id.sh`, which is the single authoritative source — never pick a T-number from context.

## The convention

- **Sequential** numbering is the legacy mode (T1–T371 historically). Once a project's sequential range is sealed, all further allocations use **100-task topic blocks** at century boundaries (T800–T899, T900–T999, …).
- Each block has a **theme** and **state** (`open`, `sealed`, `sealed-gap`).
- **Sealed-gap** ranges exist when a project jumped its numbering ad-hoc (e.g. T372–T799 in `turnip-ios`). They are permanently unavailable — never reuse, never retro-renumber merged work to fill them.
- New work that fits an existing **open** block uses the next free ID inside that block.
- New work that opens a new theme allocates a new 100-block at the next century boundary AND records it in the registry in the same intake operation.
- UUID-only follow-ups (`TXXXa`, `TXXXb`, …) are still allowed under any parent task and don't consume block IDs.

## Registry

Each project that opts into block allocation maintains `<plans-dir>/task-id-allocation.yaml`:

```yaml
schema_version: 1
prefix: T
default_block: <name>
blocks:
  - {name: <theme>, range: [<start>, <end>], state: <open|sealed|sealed-gap>, description: "..."}
```

The registry is project-local under `~/.dev-studio/<project>/plans/`. It is **host-agnostic** — every host (`~/.claude/skills`, `~/.codex/skills`, `~/.gemini/skills`) reads the same file via the same script.

When a registry is absent, `next-task-id.sh` falls back to legacy `max+1` allocation with a stderr warning. Migrate by running `--allocate-block`.

## Caller contract

| Caller | Default invocation | When to override with `--block` |
|---|---|---|
| `chanakya/modes/intake.md` Step 6 | `scripts/next-task-id.sh` | Pass `--block=<name>` when the new task fits a non-default theme. |
| `chanakya/modes/urgent-ingest.md` Step 3 | `scripts/next-task-id.sh` | Same. |
| `chanakya/modes/review.md` Step 3 (NEW tasks) | `scripts/next-task-id.sh` | Same. |
| Any other minter | always go through `next-task-id.sh` | Never hand-pick a T-number. |

If the user says *"start a new theme"* during intake, the orchestrator MUST allocate a new block first:

```bash
scripts/next-task-id.sh --allocate-block <name> <start>-<end> \
    --description="<one-line theme>" [--default]
LEGACY_ID=$(scripts/next-task-id.sh --block=<name>)
```

`<start>-<end>` should land on a century boundary (e.g. `900-999`) and never overlap an existing block. The script refuses overlaps.

## Refusal behavior

`next-task-id.sh` exits non-zero (3) when:
- Target block is `sealed` or `sealed-gap`.
- Block name is unknown.
- Block range is exhausted (need to allocate a new block).
- Registry has no `default_block` set and no `--block` was passed.

Callers must surface the script's stderr to the user verbatim — never silently fall through to a hand-picked ID.

## Auditing

`scripts/next-task-id.sh --list-blocks` prints the registry with computed next-free per block. Use it during status / sweep to spot near-exhausted blocks.
