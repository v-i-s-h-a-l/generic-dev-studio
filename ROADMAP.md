# Roadmap

This file is the **vision and themes** doc — long-running directions the project is heading. For *actionable backlog* (specific work that's queued or in flight), see [open issues](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues). For *what just shipped*, see the [Releases page](https://github.com/v-i-s-h-a-l/generic-dev-studio/releases) and the timeline at the top of [README.md](README.md).

---

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
- Chanakya modes: `--dispatch <task-id> <worker-N|any>`, `--queue-enqueue <task-id>` + `--queue-drain` (work-stealing; preferred for batch), `--dispatch-many <task-ids>` (legacy upfront fan-out), `--cancel <task-id>`, `--worker-status`
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

---

## Advanced use cases (future)

- **Dependency-aware dispatch** — Chanakya tracks task DAG, only dispatches a task when all predecessors have reached `done` or `verified`
- **Parallel refactor sharding** — split a large refactor into N independent file-level shards, dispatch to N workers simultaneously
- **Handoff chains** — impl worker → tests worker → integration tests worker, each triggered by the previous one's `brief_completed` event; no manual dispatch between phases
- **Overnight queue** — AFK backlog gets chewed through in `--away` mode; morning digest summarizes what merged, what blocked, what needs review
- **Scheduled cadences** — auto-compact at 03:00, morning triage on first Chanakya wake, end-of-day summary; managed via `/schedule`
- **A/B experimentation** — dispatch the same task to 2 workers with different prompt strategies, compare review verdicts and diff quality
- **Regression watchdog** — after any merge to main, auto-dispatch a smoke test suite to any idle worker slot
- **Conversational planning** — Chanakya parses ambiguous intent arriving via iMessage ("the filter thing is broken again") into a structured brief without user being at the laptop

---

## Edge cases to handle

- **Stuck child process** — 45-min timeout for M/L tasks, 20-min for XS/S; kill the process and requeue the task with a `requeued_after_timeout` note in the debrief
- **Cascading blocks** — when a predecessor task is blocked, all successor dispatch is gated; Chanakya surfaces the full blocked subgraph in `/chanakya status`
- **PID recycling** — heartbeat tuple = `(hostname, pid, process-start-time)` to distinguish a reused PID from the original worker
- **Headless permission prompts** — pre-allowlist all expected tool calls in `settings.local.json`, or run child processes with `--dangerously-skip-permissions` for fully unattended overnight runs
- **Git LFS bandwidth** — use `--reference` to a shared bare-clone cache for large assets, or serialize LFS fetches via a dedicated lock to avoid throttling
- **Simulator contention** — allocate dedicated named simulators per worker slot (e.g., `Achilles-1` through `Achilles-6`) to prevent slot collisions in parallel test runs
- **Event log day-boundary** — offset stored as `(filename, byte)` tuple; when the date rolls over, Chanakya resets offset to 0 on the new day's file and re-processes from the start
- **File contention across worktrees** — merge lock serializes writes to the main checkout; Argus base-staleness check catches drift introduced by a sibling merge that completed during review
- **Disk fill** — Chanakya sweep checks available disk (`df -h`); emits `disk_low` event (threshold: <2 GB free) and pauses new worker dispatch until space is recovered
- **Slot reclamation** — worker slots with a dead PID (no process at the recorded PID) are auto-reclaimed on the next worker boot, not requiring manual cleanup
- **User mid-dispatch intervention** — "pause all" is honored at task-step boundaries (end of Step 3/4/5/6), not mid-execution; in-flight builds complete before pausing
- **Log rotation mid-wake** — if `atomic replace` of the event log occurs while Chanakya is mid-read, the offset tuple survives because it references `(filename, byte)` — re-read from the new file's start if byte offset exceeds new file size

---

## Token budget posture

Optimizations landed in this session and the rationale behind them:

- **At-laptop / away split** — auto-sweep and push channels are only active in `--away` mode. When at the laptop, Chanakya runs on-demand only, eliminating scheduled-wake overhead and MCP cold-start costs entirely.
- **Adaptive backoff** — `--auto-sweep` starts at 15-min intervals but backs off exponentially (15→30→60→120 min) on consecutive blank sweeps. Resets to 15 min on any real activity. Push-on-exception events (block, conflict, build-debt-blocked) bypass backoff entirely — critical alerts are never delayed.
- **Model recommendations** — Chanakya: Sonnet for orchestration, Haiku for event-processing modes (~15× cheaper). Achilles: Opus always for code generation (no downgrade). Argus: Opus always (reasoning-heavy edge-case analysis). Worker parent bash-loop sessions can use Haiku since they only dispatch, not implement.
- **Argus scope caps** — cross-file scan capped at 10 neighbor files × 50 lines each; diffs >500 lines load only the 500 most-changed lines; XS single-file diffs under 20 lines skip Argus entirely. Each triggered cap emits a `review_scoped` event for longitudinal tuning.
- **MCP hygiene** — iMessage/Telegram MCPs are enabled only in `--away` mode. Figma MCP loads only for brief generation. Telegram is not the primary push channel (silent disconnect risk); iMessage is preferred.

---

## Phase sequence (architecture refactor)

Ordered plan for the intent-router + ledger + knowledge refactor, as of 2026-04-20. GitHub issues (#35–#50) track actionable items; this section captures *sequence and dependencies*.

### Completed (branch `refactor/intent-router`)

- **Phase 1** ✓ Foundation docs — `_shared/router-pattern.md`, `_shared/singleton-invariants.md`.
- **Phase 1.5** ✓ Enforcement layer — linter, pre-commit hook, scaffold, graduation scan, surface manifest.
- **Phase 2** ✓ Chanakya router refactor — router 55 lines + 14 mode packs + snapshot skeletons.
- **Phase 2 (snap)** ✓ Real snapshot producers + SessionStart prewarm + status-mode consumption + invalidation.
- **Phase 3 (Achilles)** ✓ Achilles router refactor — router 51 lines + 9 mode packs.

### Planned

- **Phase 2.5** — Router contract extensions. Must-haves: message contracts, state machines, idempotency, schema versioning, read/write declarations. Ship-alongside: capability manifest, dry-run, budget telemetry. Reorganize `_shared/` into subdirectories (`patterns/`, `contracts/`, `state-machines/`, `schemas/`, `primitives/`, `rules/`). Linter extends with ~5 new codes. No mode-pack changes yet.
- **Phase 2.6** — Ledger overhaul. All artifacts → structured YAML (tasks, designs, rounds, releases, debriefs, reviews, crashes). `plans/index.yaml` + inline relational links. Single canonical event log at `events/YYYY-MM-DD.jsonl`; six other locations consolidated + archived. Migration script for turnip-ios (backup → transform → cutover). Every Chanakya and Achilles mode pack rewritten against new contracts. Agent-versioning hooks. **Also:** add Achilles `debrief` mode (`/achilles debrief`) for direct-to-Claude bug fixes that bypass the brief → worktree → Argus pipeline — scans conversation + staged diff, emits a debrief in the new YAML schema; user tells it whether tests are needed.
- **Phase 2.7** — Knowledge layer. `_shared/project-memory.md` + `scripts/memory-query.sh`. Chanakya `modes/knowledge.md` for synthesis. Slack-ingest index joins the memory layer. Cross-refs from Lu Ban / Achilles / Argus.
- **Phase 3** — Prompt-caching instrumentation + schedule-driven automation. Stable-prefix caching design. Daily/weekly/monthly/quarterly crons via `/schedule` and `/loop`. `modes/test-health.md`. Weekly narrative auto-post.
- **Phase 4** — Lu Ban greenfield (`/luban`). Multi-file designs from day 1. ADR auto-write on `status: approved`. `_shared/architecture-catalog.md`. Integration with Chanakya Step 0 scan.
- **Phase 5** — Crashlytics auto-brief loop + Argus `smoke` mode (synthetic-QA capability folded into Argus; right-sizing — no fifth agent). 3-step gate for crash fixes. `scripts/crash-watch.sh` modeled on `appstore-watch.sh`.
- **Phase 6** — Executive dashboard. Local web app. Four zoom levels (Now / Week / Month / Quarter) + approval buttons.
- **Phase 7** — Cross-agent routing intelligence. Chanakya suggests Lu Ban handoff on novelty; Achilles debrief surfaces architectural concerns. Always suggestion, never hard routing.
- **Phase 8** — docs.html redesign. Use-case primary groupings + agent badge. Adds Lu Ban card + Argus smoke-mode section.
- **Phase 9** — Memory-aware briefs + crystal-ball analysis + narrative polish.

### Later (prove need first)

Autonomous improvement loop, agent rollback via semver, studio as shippable public product.

### Dependencies

- 2.5 gates 2.6 (contracts before the overhaul conforming to them).
- 2.6 gates 2.7 (structured data before the knowledge layer indexing it).
- 2.7 and 3 are parallelizable.
- Lu Ban (4) lands on 2.5 + 2.6 foundation.
- Argus smoke mode (5) independent of Lu Ban.
- Dashboard (6) reads the 2.6 ledger; gated on 2.6.

### Open questions — revisit at next session start

- Any phase reorder or reject? (memory: `project_phase_reordering_pending.md`)
- Budget defaults after observing real traffic.
- Confucius (dedicated knowledge agent) — extract from Chanakyas mode if it bloats?
