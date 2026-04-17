# Roadmap

## Remote orchestration via iMessage / Telegram (planned)

**Goal:** user interacts with Chanakya via iMessage/Telegram from anywhere; Chanakya dispatches work to manually-spawned Achilles worker terminals in real time. User never needs to be at the laptop to direct the work — only to have the worker terminals already running.

### Architecture

**Worker terminals (manually spawned by user):**
- User opens N terminals (typical: 6); each runs `scripts/achilles-worker.sh <N>`
- Script watches `~/.claude/achilles-inbox/worker-N/` via `fswatch`
- On new task file: invokes `claude -p "/achilles <task-id>"` → **fresh process, clean context per task**
- On completion: moves task file to `done/`, writes event to shared event log, sets idle marker
- Heartbeat file `alive` refreshed every 60s

**Chanakya (orchestrator):**
- Runs interactively in primary session OR headless triggered by iMessage/Telegram input
- Dispatch: writes task file to selected worker's inbox
- Capacity-aware: reads busy/idle markers across all worker inboxes, picks idle ones
- Responds to user via iMessage/Telegram after events land in log

**Shared state:**
- Event log: existing `<project-memory>/events/<date>.jsonl`
- Worker inbox root: `~/.claude/achilles-inbox/worker-<N>/`
  - `*.task` — pending tasks
  - `*.task.done` — completed
  - `busy`, `alive` — status markers
  - `rescue/` — requeued tasks from crashed workers

### Commands to build
- `scripts/achilles-worker.sh` — shell loop with fswatch + claude -p
- `scripts/worker-status.sh` — one-shot report of all workers
- Chanakya modes: `--dispatch <task-id> <worker-N|any>`, `--dispatch-many <task-ids>`, `--cancel <task-id>`, `--worker-status`
- iMessage/Telegram command parser in Chanakya: "work on T001 T002", "status", "cancel T004", "what's worker 2 doing"

### Nice-to-haves (later)
- Two-way iMessage: user interrupts mid-flow
- Task priority lanes (`urgent/` inbox)
- Worker routing hints ("worker with DerivedData for X")
- Session replay from event log

### Why this architecture
- File-based IPC is simple, debuggable, survives Claude Code restarts
- `claude -p` per task = guaranteed fresh context without harness changes
- Existing event log already handles the return path; no new infra needed for Chanakya → user comms
- Chanakya's `--watch`/`--ship-mode` flags already establish the "event-driven orchestrator" pattern; this extends them
