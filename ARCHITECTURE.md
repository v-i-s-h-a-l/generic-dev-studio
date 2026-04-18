# Architecture

How responsibilities split across the studio. Living doc.

## Three-tier extraction model

When something feels too big to keep inline in an agent's SKILL.md, it can be extracted to one of three tiers. Pick the lightest tier that actually solves the problem.

| Tier | What goes here | Cost | Examples |
|---|---|---|---|
| **1. Reference (`_shared/X.md`)** | Schemas, file locations, format specs, lookup tables, conventions. Read on demand by an agent that needs them. | Cheap — just a file read. No new context. | `events.md`, `build-debt-schema.md`, `file-locations.md`, `cleanup-policy.md` |
| **2. Module (separate skill)** | Stack-specific or domain-specific bulk that only some projects need. Installed opt-in via symlink. | Medium — own SKILL.md, separate skill registration. | (planned) `ios-toolkit/`, `web-toolkit/`, `appstore-release/` |
| **3. Subagent** | A coherent multi-step *job* with clear input/output and its own context. The main agent invokes via `Agent` tool, gets a result back, processes it. | Heavy — separate context, briefing prompt, return-value parsing. | Achilles → Argus is already this pattern. Future: `compactor`, `brief-writer`, `feedback-ingester`, `session-closer`, `analysis-runner`. |

## Decision rules

**Reach for Tier 1 (`_shared/`) when:**
- It's data, schema, or lookup material
- Multiple agents need the same content
- Inline duplication would drift

**Reach for Tier 2 (module) when:**
- It's stack-specific (iOS, web, etc.) or audience-specific
- Not every project needs it
- It's substantial (>200 lines of agent-facing prose)

**Reach for Tier 3 (subagent) when:**
- It's a coherent *job*, not a *step* (think: "could a person be hired to just do this thing?")
- It needs its own context to reason properly (lots of file reads, isolated decision-making)
- Multiple agents would invoke it (avoids duplication across SKILL.md files)
- The main agent only cares about the result, not the intermediate work

## When NOT to use a subagent

- Quick lookups → use `_shared/` reference instead
- Inline single-step decisions → keep in SKILL.md
- Tightly-coupled work that needs frequent feedback with the main agent
- Something that only one agent ever does and it's <100 lines

Subagents have invocation overhead (spawn, brief, return). For small things, inline wins.

## Skills load on demand

Each agent's SKILL.md only loads when *that agent* is invoked. Chanakya's content doesn't burden Achilles sessions, and vice versa. So:

- **Duplication between agents** → not a context bloat issue, but is a maintenance issue. Promote to `_shared/`.
- **Bulk within one agent** → real context bloat. This is what subagents and modules are for.

## End-of-session handling

**Achilles** — natural end signal (task done → idle). Cleanup happens in Step 11 (sit idle).

**Chanakya** — fuzzy end. Trigger is the user's "anything else? safe to exit?" intent. When detected, Chanakya should:
1. Drain pending debriefs (final inbox sweep)
2. Confirm any unpushed commits
3. Surface unread push-queue items
4. Emit `agent_session_completed`
5. Return a one-line "safe to exit" or "wait — these N items are pending"

**Argus** — runs as a subagent of Achilles; ends when verdict returned.

## Recovery on resume

Each agent's wake routine should detect skipped end-of-session cleanup:

> Read the last `agent_session_completed` event. If it's older than 24h AND there's been activity since (events emitted, debriefs landed), assume the prior session ended without cleanup. Run end-of-session logic for the prior period, emit a backdated `agent_session_completed`, then proceed.

Self-healing. No user prompt needed.

## Phase 2 extraction targets

Capture the candidates here so future planning has them visible. Not commitments — just possibilities:

- `compactor` (subagent) — Chanakya's compact mode. **Pilot extraction** when SKILL.md bloat justifies it.
- `brief-writer` (subagent) — brief generation from master plan tasks.
- `feedback-ingester` (subagent) — Slack/DM/channel ingestion pipeline.
- `session-closer` (subagent) — end-of-session cleanup for Chanakya.
- `analysis-runner` (subagent) — daily analysis pass over event log + debriefs.
- `ios-toolkit` (module) — Swift/SwiftUI/UIKit/xcodebuild content extracted from current chanakya/achilles SKILL.md.
- `appstore-release` (module) — push-tf, full-send-to-app-store, JWT, dSYM upload.
- `slack-publish` (module) — sync-slack, postSlackTesting, slack-post boilerplate.

Tracked as issues — see `theme/internal` filter on GitHub Issues.

## Don't pre-extract

Each extraction has cost (briefing the new artifact, drift risk, debugging). Extract only when:
- A SKILL.md has grown to where adding more makes it harder to maintain
- A pattern of duplication is established (≥2 places copy the same content)
- A subagent candidate has been validated as a real job, not a step

Iterating on extraction is harder than adding inline; default to inline until pain is concrete.
