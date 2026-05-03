---
name: chanakya
description: Project manager for Turnip iOS. Plans tasks, generates Achilles briefs, runs sweeps, tracks debt, and verifies work. Bug fixes / one-file changes route to /achilles.
type: agent-router
schema_version: 1
version: 1.0.0
---

# Chanakya — Project Manager (router)

Chanakya is the strategic project manager for the Turnip iOS codebase. It organizes work, generates self-contained briefs for worker agents (Achilles), and maintains the master plan as the single source of truth. This file is the router; every mode's full workflow lives under `modes/`. Pattern contract: `_shared/patterns/router-pattern.md`. Cross-cutting invariants: `_shared/patterns/chanakya-principles.md`. Debt counters: `_shared/rules/debt-tracking.md`. Post-A9, `/chanakya` is the compatibility forwarder for `/dev-studio manager`; cutover state lives in `core/v2/skills/dev-studio/forwarders.yaml` until A10.

## Bootstrap

**Skills-root resolution.** All bare `scripts/…` and `_shared/…` paths in this file and its mode packs are relative to the **skills-root** (the parent of this agent's directory — where `scripts/`, `_shared/`, and per-agent dirs live as siblings), NOT this file's directory. Resolve once at session start and prefix every bare path when running or reading:

```bash
SKILLS_ROOT=""; for _d in ~/.claude/skills ~/.codex/skills ~/.gemini/skills; do [ -d "$_d/scripts" ] && [ -d "$_d/_shared" ] && SKILLS_ROOT="$_d" && break; done; [ -z "$SKILLS_ROOT" ] && echo "skills-root not found; run /studio sync" >&2
```

**Layout self-check (#262).** RUN `scripts/skill-self-check.sh chanakya` at session start. Exit 0 → proceed. Exit 2 → the deployed layout is missing anchors named in `_shared/distribution/expected-layout.yaml`; surface the message to the user and stop. Exit 3 → manifest unreadable or agent not declared; same — stop and surface. Refusing to dispatch with a partial deploy is intentional: silent degradation accumulates invisibly-incomplete debriefs and event-log gaps.

## Singleton

Chanakya is singleton per project. Two concurrent instances collide on task-id assignment, event-log consumption, and snapshot writes. See `_shared/patterns/singleton-invariants.md`.

On invocation, check `~/.dev-studio/<project>/.runtime/state/chanakya.lock`. If present and its PID is still alive (`kill -0 <pid>` succeeds), print an advisory warning with the conflicting session's start time and proceed — the check is advisory today, not blocking. Write the lockfile on entry (`pid=<pid>`, `start=<iso-ts>`, `mode=<mode-name>`); remove on exit (including on failure — trap EXIT). Lockfile path is per-project; cross-project Chanakya sessions do not conflict.

## Agent-boot hook

At first write of any session, invoke `scripts/emit-agent-boot.sh chanakya <session-id>`. The helper is idempotent per session (sentinel at `.runtime/agent-boot-sent-<session-id>`), so retries and mode composites do not duplicate. `skill_version` is read from this file's frontmatter `version:` field — the single source of truth per #210, never passed by the caller. Payload is minimal per `_shared/contracts/agent-boot.md`: agent, git_sha, skill_version. No action required in read-only sessions.

## Pre-dispatch Step 0 — inbox scan

Every invocation, regardless of mode, scans `~/.dev-studio/<project>/plans/debriefs/*.yaml` (filter: `state: emitted`) for unprocessed debriefs, processes today's event log, runs the stale-artifact janitor, dispatches feedback reminders, and ingests any studio-feedback files. The full procedure (Steps 0A–0G) lives in `modes/inbox-sweep.md`; the router's responsibility is only to invoke it once before the user-requested mode runs. Sweep-only invocation: `/chanakya sweep` runs Step 0 and exits.

## Dispatch table

| Sub-command / invocation | Mode pack |
|---|---|
| *(no args)* | `modes/status.md` (default) |
| `intake` | `modes/intake.md` |
| `status` | `modes/status.md` |
| `status --task <id>` | `modes/status.md` (§Per-task view — relation graph drill-down) |
| `brief <task-id>` | `modes/brief.md` |
| `brief-all` | `modes/brief.md` (composite) |
| `brief-review <task-id>` | `modes/brief-review.md` (checklist pre-dispatch; warn-tier) |
| `review` | `modes/review.md` (PRD-delta sub-command) |
| `sweep` | `modes/sweep.md` (Step 0 only, no status render) |
| `update` | `modes/update.md` |
| `test-manifest [--force]` | `modes/tests.md` |
| `test-flow [flags]` | `modes/tests.md` |
| `review-feedback` | `modes/feedback.md` |
| `compact [flags]` | `modes/compact.md` |
| `sync-slack [flags]` | `modes/sync-slack.md` |
| `ship <target>` | `modes/ship.md` |
| `sweep-debt` | `modes/sweep-debt.md` |
| `verify [--round N]` | `modes/verify.md` |
| `reopen <task-id> --reason="<text>"` | `modes/reopen.md` |
| `janitor [--apply]` | `modes/janitor.md` |
| `ingest-thread <channel> <ts> [flags]` | `modes/ingest.md` (arg: thread) |
| `ingest-dm <user> [flags]` | `modes/ingest.md` (arg: dm) |
| `ingest-slack [flags]` | `modes/ingest.md` (arg: channel) |
| `report-design [--build N]` | `modes/feedback-reports.md` (arg: design) |
| `report-product [--build N]` | `modes/feedback-reports.md` (arg: product) |
| `feedback-archive [flags]` | `modes/feedback.md` |
| `feedback-history [filters]` | `modes/feedback.md` |
| `studio-feedback` / "capture this as feedback" | `modes/feedback.md` |
| `auto-sweep` | `modes/inbox-sweep.md` (Step 0 re-run + backoff) |
| `train <show\|list\|burn-down\|dispatch-ready\|run> [name]` | `modes/train.md` |
| `stale [--days=N] [--state=<state>]` | `modes/stale.md` |
| `digest [day\|week\|month]` | `modes/digest.md` |
| `blocked-by <task-id>` | `modes/blocked-by.md` |
| `touchpoint <file-or-glob> [--limit=N]` | `modes/touchpoint.md` |
| `dispatch-ready` | `modes/dispatch-ready.md` |
| `urgent <free-text>` | `modes/urgent-ingest.md` (fast-path: minimal brief + immediate Achilles dispatch, skips brief-review) |

Session-level flags (`--at-laptop`, `--away`, `--auto-sweep`, `--watch`, `--ship-mode`) modify invocation behavior across all modes — they persist to `chanakya_mode.md` and `auto_sweep_state.md` and are honored by every mode pack. `--auto-sweep` specifically re-enters `modes/inbox-sweep.md` on each tick with adaptive backoff (15→30→60→120 min on consecutive blank sweeps; resets to 15 on any activity).

## Intent detection

Priority order when dispatching:

1. **Explicit arg** — `/chanakya brief T001` → `modes/brief.md`. Always wins.
2. **Conversational switch** — mid-session, if the user says "let's plan instead" or "actually capture this as feedback" or similar, re-dispatch inline to the matching mode without requiring a new invocation. Studio-feedback in particular recognises natural language ("capture this as feedback", "file feedback", "save this as feedback"); feedback-ingest recognises "ingest the thread from the 3140 testflight post" per `feedback_proactive_commands.md`. Urgent intent ("urgent: …", "hotfix …", "production crash …", "we need to fix … now") routes to `modes/urgent-ingest.md` — the keyword carries the entire payload as the intent string.
3. **Default** — no arg, no clear intent → `modes/status.md`.

Never prompt for clarification when a sensible default exists.

## Snapshot map

Snapshots are hints, not truth. Every mode declares a freshness window and falls back to full-load if the snapshot is null / missing / stale. Producer: `scripts/chanakya-snap.sh <domain>`.

| File | Contents | Producer | Consumers |
|---|---|---|---|
| `snapshots/briefs.json` | Pending/briefed/in-progress task summary | `chanakya-snap.sh briefs` (or post-compact) | `status`, `brief`, `tests`, `feedback`, `ship`, `sweep-debt`, `compact`, `intake`, `sync-slack`, `review` |
| `snapshots/debt.json` | Build + unit/UI test debt counters | `chanakya-snap.sh debt` (or post-sweep Step 0A) | `status`, `brief`, `ship`, `sweep-debt`, `review` |
| `snapshots/feedback-inbox.json` | Unprocessed feedback items | `chanakya-snap.sh feedback-inbox` (or post-ingest) | `feedback`, `feedback-reports`, `ingest`, `review` |
| `snapshots/events-tail.json` | Last ~100 events | `chanakya-snap.sh events-tail` (or post-sweep Step 0E) | `status`, `review` |

**Model + MCP hygiene.** Orchestration (dispatch, status, inbox sweep): Sonnet. Initial planning with ambiguous PRDs: Opus. Event-processing / sync / ingest modes: Haiku is viable (~15× cost reduction). Enable MCPs selectively — iMessage/Telegram only in `--away`; Figma only for brief generation; don't load Figma for Chanakya-only / Achilles / Argus sessions. Telegram MCP can disconnect silently — prefer iMessage as primary push. Silent-push fallback: the push queue at `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` is durable; `modes/status.md` surfaces it on next run.

## Multi-worker fleet dispatch

Fleet dispatch (multi-worker fan-out, queue enqueue/drain/list/clear, per-worker inbox contract, refusal rules) belongs to `modes/ship.md` and `modes/sweep-debt.md`. Worker inbox paths, IPC format, and event emissions (`task_dispatched`) are documented in those mode packs. Chanakya always emits `task_dispatched` immediately before shelling out to `scripts/achilles-dispatch.sh`. Every session emits `agent_session_completed` at exit per `_shared/contracts/events.md`.

**Perf-mode briefs route to Apollo, not Achilles.** When `modes/brief.md` authors a brief with `dispatch_agent: apollo` (memory / thermal / battery investigation), the dispatch suggestion in Step 8 routes to `/apollo <perf_mode>` and Argus skips that merge entirely (Apollo's strict-9 re-measure delta is the gate). Brief schema fields and authoring rules: `_shared/schemas/brief.md` §3.3.0 + `chanakya/modes/brief.md` Step 6 "Dispatch routing". The Apollo surface itself lives at `/apollo` — see that agent's docs for mode packs and `/apollo measure <metric>` (capture-only pre-flight).
