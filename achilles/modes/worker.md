---
name: Achilles Worker
description: Fleet worker mode (`/achilles worker [N]`). Turns the current Claude session into a fleet pane — claims a slot atomically, starts a background watch loop, and spawns a fresh `claude -p "/achilles <id>"` per dispatched task. The session is the operator-facing wrapper; the bash watch loop is the IPC primitive.
type: mode-pack
snapshots: []
budget_tokens: 1500
reads: []
writes: []
---

# Mode: Worker (`/achilles worker [N]`)

Turns the current Claude Code session into a fleet worker pane. Designed for the iTerm "Broadcast Input" (`Cmd+Opt+I`) workflow: launch Claude in N panes with `--dangerously-skip-permissions`, broadcast `/achilles worker` once, and each pane atomically claims its own slot.

The Claude session itself does not run user tasks in its own context — it shells out to a background watch loop that spawns a **fresh** `claude -p "/achilles <id>"` per dispatched task. The session is the operator-facing wrapper: ask it "status", "stop", "what's running" and it answers from the worker log.

## W1 — Claim slot and start the watch loop

1. Resolve the worker script path: prefer `<repo-root>/scripts/achilles-worker.sh` (current project), fall back to `~/.claude/skills/scripts/achilles-worker.sh` (installed).
2. Set `ACHILLES_UNATTENDED=1` automatically. Rationale: the user explicitly opted in to dangerous permissions by launching Claude with `--dangerously-skip-permissions` — the child `claude -p` subprocesses inherit that intent.
3. Run the worker via `Bash` with `run_in_background=true`:
   ```sh
   ACHILLES_UNATTENDED=1 <path>/achilles-worker.sh [N]
   ```
   With no `N`: the script atomically claims the lowest free slot via `mkdir worker-N/.lock` with PID-token verify (race-safe under concurrent broadcast).
4. Read the first few lines of the bash output to capture the claimed slot number. Report to the user:
   > "Claimed slot 3 (`<project>:worker-3`). Watching inbox at `~/.dev-studio/<project>/.runtime/achilles-inbox/worker-3/`. Tell Chanakya `--dispatch <task-id>` (or use `scripts/achilles-dispatch.sh`) to send work." — substitute the actual project slug from the worker.sh output.
5. Stay foreground. Do **not** pre-emptively poll. The user will ask when they want status.

## W2 — Status / monitor on demand

When the user asks for status, resolve paths via `scripts/lib-paths.sh` (`resolve_inbox_root`), then run `Bash` to:
- `tail -n 20 $(resolve_inbox_root)/worker-<N>/worker.log`
- Check `$(resolve_inbox_root)/worker-<N>/busy` (current task id, if any)
- Report concisely: current task, recent completions, recent errors.

For fleet-wide status, run `<path>/worker-status.sh` and surface the table.

## W3 — Shutdown

When the user asks to stop the worker (or this Claude session is being closed):
1. Find the background bash PID (from the run_in_background return) and `kill` it.
2. The worker's EXIT trap removes its `.lock` and `busy` markers; slot becomes immediately reclaimable by another pane.
3. Confirm: "Worker stopped, slot N released."

## Why the indirection?

The parent Claude session is the human-friendly shell — it lets you launch with one slash command, ask questions, and stop cleanly. The bash watch loop is the proven IPC primitive (atomic mkdir lock, fswatch, fresh `claude -p` per task). Tasks still get fresh context every time; the wrapper does not consume per-task context.

## Communication with Chanakya

No direct IPC between worker panes and the Chanakya pane is needed. Workers emit events to the shared event log via the `claude -p "/achilles <id>"` subprocess (`task_started`, `task_completed`, `review_blocked`, etc.). Chanakya consumes those events on its next sweep — exactly as today. You only ever talk to Chanakya; Chanakya talks to the event log; the event log knows what every worker is doing.
