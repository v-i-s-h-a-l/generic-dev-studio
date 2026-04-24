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

### Host-agnosticism

**Principle.** Every agent is host-agnostic. No agent capability may depend on Claude-Code-specific primitives — hooks, the Agent subagent tool, tool-name dialects ("use the Read tool"), or SessionStart injection — in its load-bearing path. Host adapters provide ergonomic optimizations; they never provide required functionality. Portability is a tested invariant, not aspiration.

**Substrate.** A portable agent is allowed to assume: file I/O on the repo and `~/.dev-studio/**`; a POSIX shell; a single model session with system prompt + turn loop; read/write tools in whatever dialect the host exposes. That's it. Everything above is our protocol.

**Contract-first, not prose-first.** Inter-agent handoffs (briefs, debriefs, verdicts) validate against JSON Schemas at `_shared/contracts/<kind>.schema.json`. Validators reject malformed output *before* it reaches the next agent. Borrowed from CrewAI (`output_pydantic`) and AutoGen (typed message bus) — both independently converged on strict schemas as the stable cross-model substrate. Aider's `model-settings.yml` lesson reinforces: codify per-model quirks as data, never as branching code.

**Adapter shape.** Canonical content at top-level `skills/` / `agents/` / `commands/` equivalents; host packaging under `.<host>/` dotdirectories mirroring each host's native config location; root instruction files named by each host's convention (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) with shared content. Hook scripts canonical; per-host hook-schema JSON points at the same script; prose-preamble fallback carries hosts without hook support. Shape validated across seven hosts by Superpowers (`obra/superpowers`). See `hosts/ADAPTER-SPEC.md` for the authoritative guide to authoring a host adapter — required files, capability manifest schema, security floor, and step-by-step conformance checklist.

**Zero third-party runtime deps.** Worker-facing code paths stay on POSIX + `jq` + `yq`. Host adapters may use host-native tooling; core scripts may not introduce package managers, brokers, or libraries. Borrowed verbatim from Superpowers' contributor rule — same substrate bar.

**Enforcement.** Verified by `scripts/test-host.sh` (delivered in the host-agnostic-workers-v1 release per issue #88), which runs a canned conformance matrix (XS / M / TDD tasks) end-to-end against each declared host and asserts: debrief lands, schema validates, review gate fires, merge completes. Host manifests carry a conformance-passed stamp; regressions block release.

**Staging.** Workers ship first (Achilles + Argus together — half-portable review gate is worse than none). Chanakya portability follows in a later release; it's a scope-staging choice, not a technical constraint. Rationale: surface area (16 modes vs. 10), model-quality sensitivity (orchestration judgment leans harder on model capability than mechanical edits), conformance-test design (worker I/O is bounded, orchestrator I/O is open-ended), and prompt-cache economics (Chanakya sessions are longest — defer host-swap until Phase 3 cache strategy lands). New agents (Lu Ban, Chiron) are born portable.

**Explicitly not adopted.** LiteLLM-style universal model routers (hosts own inference). MCP as the worker tool transport (file I/O + shell already works). Framework adoption (AutoGen / LangGraph / CrewAI) — we steal patterns, not dependencies. Marketplace publishing per host (we're not shipping to marketplaces; conformance testing replaces it).

---

## Design Vision (2026-04-20 synthesis)

Long-form design decisions from the April 2026 architecture session. The existing docs (this file, ROADMAP.md, REVIEW.md, CLAUDE.md) cover most; this section captures decisions and rationales that would otherwise live only in conversation context. Goal: a fresh Claude session reads this and picks up without re-litigating.

### Router pattern (landed)

See `_shared/router-pattern.md` and `_shared/singleton-invariants.md`. Chanakya + Achilles now use the pattern; Argus stays inline (single-purpose); Lu Ban (upcoming) is router-first from birth.

### Agent roster (v1)

| Agent | Role | Singleton? | Lineage |
|---|---|---|---|
| Chanakya | Project manager, orchestrator, knowledge synthesizer | Yes (per project) | Indian strategist, Arthashastra |
| Achilles | Implementer, worktree-isolated worker | No (many concurrent) | Greek warrior |
| Argus | Reviewer, diff + regression auditor | No (stateless per task) | Greek many-eyed watchman |
| Lu Ban (planned) | Architect, design dialogue | No (slug-isolated) | Chinese master craftsman 鲁班, 5th c. BCE |
| Chiron (planned) | Synthetic QA — AI tester for TF builds | No (per build) | Greek centaur, trained Achilles |

Deferred: Confucius (knowledge synthesizer as separate agent) — currently a mode on Chanakya.

### Ledger / artifact layer (Phase 2.6)

Current master plan is a ~100KB God-object markdown. Target: per-entity structured YAML + single canonical event log + derived snapshots.

Key commitments:
- One file per task / round / release / design / debrief / review / crash report.
- `plans/index.yaml` is the single entry point with pointers.
- Inline relational links (`related_tasks`, `in_round`, `targets_release`, `from_design`, `fixes_crash`).
- Master plan is a **generated view**, not source of truth. Never written to directly.
- Event log canonical path: `events/YYYY-MM-DD.jsonl`. Six other historical locations consolidated + deleted.
- Snapshots derived from structured sources, not from the master plan.

### Router contract extensions (Phase 2.5)

Five primitives on top of the router pattern:

1. **Message contracts** — `_shared/contracts/<kind>.yaml` schemas for briefs, debriefs, verdicts, designs, crash-reports. Linter enforces.
2. **State machines** — `_shared/state-machines/<entity>.yaml` declarative transitions. Task, review, design, crash lifecycles. Transitions emit `*_transitioned` events.
3. **Idempotency declarations** — mode frontmatter: `idempotent: true|false` + `dedup_key: <field>` when false.
4. **Schema versioning** — every artifact, message, snapshot carries `schema: <int>`; consumers declare `requires_schema:`. Mismatch = hard fail.
5. **Read/write declarations** — mode frontmatter `writes: [tasks, events]` or `writes: []`. Enables static analysis.

Ship alongside (Phase 2.6): capability manifest (`docs-surface.json` extension), dry-run contract (every mutating mode supports `--dry-run`), budget telemetry (`mode_dispatched` carries observed token cost; analyzer tightens periodically).

Deferred until need proves: recovery protocols, pipeline declarations, approval primitive, cost telemetry, provenance tags.

### Knowledge layer (Phase 2.7)

Knowledge is a **shared primitive, not an agent.** `_shared/project-memory.md` (contract) + `scripts/memory-query.sh` (primitive). Every agent queries; each owns queries that match its role:
- Status / synthesis → Chanakya (new `modes/knowledge.md`).
- Design rationale / ADRs → Lu Ban.
- Implementation memory — "seen this before?" → Achilles.
- Review patterns → Argus.

Cross-cutting synthesis ("summarize last 3 months") lives in Chanakya `modes/knowledge.md`. Separate Confucius agent deferred until synthesis mode proves too heavy for Chanakyas singleton role.

### Prompt-caching strategy (Phase 3)

Design every session invocation to maximize Anthropic-API cache hits:
- **Stable prefix:** CLAUDE.md + router + shared patterns. First. Doesnt change per-session.
- **Cacheable middle:** project state snapshot (changes slowly).
- **Variable tail:** current user message + mode-specific context.

Target: 80 ache hit rate across sessions. Token savings cumulative; latency follows.

### Schedule-driven automation (Phase 3)

Routine maintenance reactive → proactive via `/schedule` and `/loop`:
- **Daily:** debt sweep, feedback inbox sweep, Crashlytics pull, snapshot regen.
- **Weekly:** retrospective auto-draft, test-health report, dependency-update scan.
- **Monthly:** architecture review with Lu Ban, simplicity prune, agent-rule-rot check.
- **Quarterly:** budget re-tuning, deprecation sweep, studio self-audit.

### Tests as a first-class concern (Phase 3)

New `modes/test-health.md` on Chanakya: coverage trends, flaky detection, test-to-crash correlation, proactive test suggestions. Auto-surfaced weekly.

### Crashlytics loop with 3-step gate (Phase 5 pilot)

Flow: detect → brief → fix → 3-step verification → release-track → Crashlytics auto-comment.

Three gates before resolving a crash fix:
1. Fix-confidence assessment (LLM compares commit diff vs stack trace; low confidence → `Possible fix for crash` label per existing Slack convention).
2. Edge cases (Argus mandatory for crash-labeled fixes).
3. No behavior regression (Argus diff-review).

Post-merge: `scripts/crash-watch.sh` tracks recurrence; drops trigger auto-comment on the Crashlytics issue naming the release.

### Executive dashboard (Phase 6)

Local web app, read-only + approval buttons, against the structured ledger. Four zoom levels:
- **Now** — in-flight tasks, TF build status, top 3 crashes.
- **Week** — releases shipped, regressions, designer feedback rate, debt delta.
- **Month** — narrative synthesis, velocity, architectural concerns from debriefs.
- **Quarter** — release cadence, crash trajectory.

Purpose: CLI respects the agents; dashboard respects the human.

### Cross-agent routing intelligence (Phase 7)

Chanakya detects novelty signals (new subsystem, rewrite, >N files) at plan time → suggests Lu Ban handoff (user approves). Achilles debriefs carry `architectural_concern` flag; Chanakya re-routes on sweep. **Suggestions, not hard routing.**

### Studio as shippable product (mindset)

Design as if another iOS team could adopt tomorrow. Not literal shipping — a constraint that forces standardization, reliability, and absence of tribal knowledge. Any convention "only one person knows" is a weakness.

### Explicitly rejected alternatives

So future sessions dont re-propose:

- **XcodeGen/Tuist** — 2-person team; automation handles pbxproj.
- **SwiftLint** — tentative skip; Claude writes conformant Swift. Revisit on style drift.
- **MetricKit** — redundant with App Store Connect Analytics at this teams scale.
- **Always-on session replay** — projects opt-in debug tool is the better fit.
- **Phased release** — tried; didnt suit cadence.
- **App Store rejection-risk pre-check** — friction per release, low hit rate.
- **Release retrospective auto-draft** — release-health manifest (structured data) covers the same ground better.
- **Canary TF channel** — team small enough it doesnt need a second channel.
- **Screenshot automation** — design team owns.
- **Bi-directional Figma↔code sync** — operationally brittle.
- **Team routing intelligence** — 2-dev team, both do everything.
- **Competitive intelligence agent** — too ambitious, legal gray area.
- **SQLite state** — premature; YAML + grep scales 10x.
- **Auto-removing stale feature flags** — product decisions dont map to usage data.
- **Separate Historian/Confucius agent** — deferred; starts as Chanakya mode.
