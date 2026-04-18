# Achilles worker fleet

File-based IPC that lets one Chanakya session dispatch tasks to N independent
Achilles worker panes. Each worker is a long-running shell loop that spawns a
fresh `claude -p "/achilles <id>"` per task — clean context every time, no
harness changes required.

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

In your Chanakya session (or any shell):

```sh
scripts/achilles-dispatch.sh T001              # auto-routes to least-loaded alive worker
scripts/achilles-dispatch.sh T002 worker-3     # pin to a specific worker
scripts/achilles-dispatch.sh T004 any -- --wait --force-build
scripts/worker-status.sh                       # see fleet at a glance
scripts/achilles-cancel.sh T002                # remove a pending dispatch
```

## On-disk layout

```
~/.dev-studio/.runtime/achilles-inbox/
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

Override the root with `ACHILLES_INBOX_ROOT=/some/path`.

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
| `ACHILLES_INBOX_ROOT` | `$HOME/.dev-studio/.runtime/achilles-inbox` | Where worker dirs live |
| `ACHILLES_MAX_SLOTS` | `16` | Upper bound for auto-claim slot scan |
| `ACHILLES_TASK_TIMEOUT_SEC` | `2700` (45m) | Max per-task runtime; needs `gtimeout`. 0 disables. |
| `ACHILLES_UNATTENDED` | `0` | Set to `1` to pass `--dangerously-skip-permissions` for fully unattended overnight runs. |

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
