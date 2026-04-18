# Achilles worker fleet

File-based IPC that lets one Chanakya session dispatch tasks to N independent
Achilles worker panes. Each worker is a long-running shell loop that spawns a
fresh `claude -p "/achilles <id>"` per task — clean context every time, no
harness changes required.

**Multi-project:** each project gets its own independent fleet, resolved
automatically from the git toplevel basename. Run one Chanakya + N workers
per project. Cross-project one-offs: `ACHILLES_PROJECT=<slug>`.

## Setup

```sh
brew install fswatch coreutils   # coreutils gives gtimeout (optional but recommended)
chmod +x scripts/*.sh
```

## Daily flow

Open N terminal panes (typical: 6). Easiest with iTerm **Broadcast Input** (`Cmd+Opt+I`) — type the same command once, every pane runs it, and each pane atomically claims the lowest free slot:

```sh
scripts/achilles-worker.sh        # auto-claims slot 1, 2, 3, … per pane
```

Or pin slots explicitly:

```sh
scripts/achilles-worker.sh 1
scripts/achilles-worker.sh 2
```

Slot ownership is held by `worker-N/.lock` (an atomic `mkdir`). When a pane exits, the lock is released. A stale heartbeat (>180s) lets a new pane reclaim that slot automatically. Cap the auto-claim scan with `ACHILLES_MAX_SLOTS` (default 16).

Worker panes auto-title as `<project>:worker-N` (iTerm/tmux OSC 0) so you can tell at a glance which project each pane belongs to.

After each dispatched task, the pane prints the last 40 lines of `worker.log` so questions or errors from the subagent are visible without tailing the log from a separate pane.

**Stuck-state detection:** if `claude -p` exits `rc=0` but no debrief was written at `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`, the worker treats the task as silently stuck (the subagent almost certainly exited after asking a clarifying question the one-shot process could never answer). The task file goes to `rescue/` and a sidecar `<task-id>-stuck.md` captures the flags, timestamp, and last 200 lines of log. Operator decides whether to re-brief and re-dispatch.

In your Chanakya session (or any shell):

```sh
scripts/achilles-dispatch.sh T001              # current project, least-loaded worker
scripts/achilles-dispatch.sh T002 worker-3     # pin to a specific worker
scripts/achilles-dispatch.sh T004 any -- --wait --force-build
ACHILLES_PROJECT=other-app scripts/achilles-dispatch.sh T001   # cross-project
scripts/worker-status.sh                       # current project's fleet
scripts/worker-status.sh --all-projects        # machine-wide view
scripts/achilles-cancel.sh T002                # remove a pending dispatch

# Work-stealing queue (preferred for batch dispatch):
scripts/achilles-queue.sh enqueue T001         # append to pending queue
scripts/achilles-queue.sh drain                # hand head-of-queue to each free worker
scripts/achilles-queue.sh list                 # inspect queue
scripts/achilles-queue.sh depth                # integer queue depth
scripts/achilles-queue.sh clear                # wipe queue (abort scenarios only)
```

**Why work-stealing over upfront fan-out.** Task durations span 3–5× (XS LSP-only vs. M/L with full `xcodebuild`). Batch-assigning N+1…2N tasks to inboxes upfront leaves fast workers idle while slow ones still have a backlog. The queue hands one task at a time on each `task_completed` event, so every freed worker gets the next pending task.

## On-disk layout

Per-project (the common case):

```
~/.dev-studio/<project>/.runtime/achilles-inbox/
  worker-1/
    alive               # touched every 60s by heartbeat
    busy                # present iff a task is in-flight (contents = task-id)
    inbox/<ts>-<id>.task   # pending dispatches (fswatch target)
    done/<ts>-<id>.task    # completed
    rescue/<ts>-<id>.task  # timed-out or malformed; left alone for operator
    worker.log
  worker-2/
  ...
```

Project slug is resolved by `scripts/lib-paths.sh` in this order:
1. `ACHILLES_PROJECT` env var (explicit override — cross-project dispatch)
2. `$(basename "$(git rev-parse --show-toplevel)")` (normal case)
3. Error with install hint

Full root override: `ACHILLES_INBOX_ROOT=/some/path` bypasses project resolution entirely.

## Task file format

```
task_id=T001
flags=--wait --force-build
dispatched_at=2026-04-18T12:34:56Z
dispatched_from=user@host
```

## Env vars

| Var | Default | Effect |
|---|---|---|
| `ACHILLES_PROJECT` | `$(basename "$(git rev-parse --show-toplevel)")` | Project slug for path resolution — set to dispatch cross-project |
| `ACHILLES_INBOX_ROOT` | `$HOME/.dev-studio/<project>/.runtime/achilles-inbox` | Explicit override — bypasses project resolution entirely |
| `ACHILLES_MAX_SLOTS` | `16` | Upper bound for auto-claim slot scan |
| `ACHILLES_TASK_TIMEOUT_SEC` | `2700` (45m) | Max per-task runtime; needs `gtimeout`. 0 disables. |
| `ACHILLES_UNATTENDED` | `0` | Set to `1` to pass `--dangerously-skip-permissions` for fully unattended overnight runs. |
| `ACHILLES_AUTONOMOUS` | `0` (set to `1` automatically by the worker per task) | Tells the Achilles subagent there is no user to answer clarifying questions; it must pick obvious defaults and document them in the debrief. Exported by `achilles-worker.sh` for every `claude -p` subprocess. Do not set manually unless testing. |
| `ACHILLES_DISPLAY_NAME` | derived (see below) | Friendly name for panes / logs. Override per-shell, or pre-bake per-project via `~/.dev-studio/<project>/.display_name` (first non-comment line wins). |

**Display-name resolution:** `ACHILLES_DISPLAY_NAME` env var → `~/.dev-studio/<project>/.display_name` file → git-remote basename → project slug.

## Caveats

- **`--dangerously-skip-permissions`** disables the harness's permission gate. Only enable
  (`ACHILLES_UNATTENDED=1`) when you trust every brief that lands in the inbox.
- **In-flight cancel** is not supported. `achilles-cancel.sh` removes pending dispatches
  only; to stop a running task, kill the worker pane (`Ctrl-C`) and the next process_task
  iteration will exit cleanly.
- **Rescue files don't auto-retry.** Move them back to `inbox/` yourself once the
  underlying issue is fixed.
- **No PID-recycling guard yet** (see ROADMAP edge cases). Heartbeat staleness is the
  only liveness signal — if a worker pane crashes mid-task, the `busy` file may linger
  until the next worker boots in that slot.
