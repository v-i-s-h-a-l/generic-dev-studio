---
name: Chanakya Train
description: Per-train task queries and the manual single-train runner. Sub-modes — list, show, dispatch-ready, burn-down, run.
type: mode-pack
schema_version: 1
budget_tokens: 1200
snapshots: []
reads:
  - plans/tasks/*.yaml                             # train + predecessors + history live in per-task files (not index)
  - plans/briefs/*.yaml                            # run reviews the selected brief before dispatch
writes:
  - ~/.dev-studio/<project>/.runtime/task-trains/  # run state, private review artifacts, local telemetry
  - events/<date>.jsonl                            # task_train_* telemetry via scripts/chanakya-task-train.sh
---

# Mode: Train (`/chanakya train <show|list|burn-down|dispatch-ready|run> [name]`)

Query layer and single-train execution coordinator over the per-task `train` field (lean schema 1.1.0). Index.yaml does not carry `train`, so read-only sub-commands walk `plans/tasks/*.yaml` via `scripts/query-tasks.sh`.

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

### `run <name>` — reviewed, resumable single-train dispatch

Before:
- Run the normal Step 0 inbox sweep unless the user explicitly requested read-only output.
- Brief or refresh the next unblocked items in the train before dispatch. The shell runner operates only on already-briefed dispatch-ready tasks.

Run:

```bash
scripts/chanakya-task-train.sh --train "$NAME" --dry-run
scripts/chanakya-task-train.sh --train "$NAME" --limit 1 --yes
```

For manual parallel trains, use one shell/session per independent train and distinct train names:

```bash
scripts/chanakya-task-train.sh --train "$TRAIN_A" --name "$TRAIN_A" --yes
scripts/chanakya-task-train.sh --train "$TRAIN_B" --name "$TRAIN_B" --yes
```

The runner:
- creates private state under `~/.dev-studio/<project>/.runtime/task-trains/<name>/`;
- writes one plan artifact and runs `scripts/phase-review.sh --kind plan` before each dispatch;
- emits `task_dispatched` plus `task_train_*` telemetry;
- dispatches only through `scripts/achilles-dispatch.sh`;
- watches canonical events and task YAML for completion;
- writes one outcome artifact and runs `scripts/phase-review.sh --kind outcome` before continuing;
- resumes from `state.json` when re-run with the same `--name`/`--state-dir`.

Stop conditions:
- blocked or ambiguous plan/outcome review;
- no dispatch-ready brief;
- no alive Achilles worker;
- unresolved predecessor;
- worker/user blocker (`task_awaiting_user`, `task_rescued`);
- Argus block, merge conflict, failed build/test signal, or timeout.

After:
- Print the state path and next resume command when the run stops or dispatches with `--no-watch`.
- Surface only real human blockers. Do not spawn another train automatically.

## Default sub-command

If no sub-command is supplied, dispatch to `show` when a name is given, else `list`.

## Output discipline

Read-only sub-commands are pipeable and skip Step 0. `run` is a write mode and uses the normal Chanakya pre-dispatch sweep.

## Cross-links

- `/chanakya dispatch-ready` — fleet-wide variant of this mode's `dispatch-ready` sub-command.
- `/chanakya status --task <id>` — per-task drill-down.
- Task schema: `_shared/schemas/task.md` § Lean fields (1.1.0) — `train`.
