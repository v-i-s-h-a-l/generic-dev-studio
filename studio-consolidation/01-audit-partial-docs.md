# 01-audit, partial — Root docs + ROADMAP drift

**Source:** Session B Explore agent (id `ad34a1cd`), completed 2026-04-24.
**Scope:** ARCHITECTURE.md, REVIEW.md, RELEASES.md, ROADMAP.md, CLAUDE.md, README.md, THEMES.md, IDEAS.md + phase drift verification. Pure inventory.

---

## ARCHITECTURE.md

**Purpose:** Responsibility split across three-tier extraction model (Reference, Module, Subagent) and design decisions for 2026-04 architecture refactor.

**Authoritative sections:**
- ## Three-tier extraction model
- ## Decision rules
- ## When NOT to use a subagent
- ## Skills load on demand
- ## End-of-session handling
- ## Recovery on resume
- ## Phase 2 extraction targets
- ## Don't pre-extract
- ### Host-agnosticism
- ## Design Vision (2026-04-20 synthesis)
  - ### Router pattern (landed)
  - ### Agent roster (v1)
  - ### Ledger / artifact layer (Phase 2.6)
  - ### Router contract extensions (Phase 2.5)
  - ### Knowledge layer (Phase 2.7)
  - ### Prompt-caching strategy (Phase 3)
  - ### Schedule-driven automation (Phase 3)
  - ### Tests as a first-class concern (Phase 3)
  - ### Crashlytics loop with 3-step gate (Phase 5 pilot)
  - ### Executive dashboard (Phase 6)
  - ### Cross-agent routing intelligence (Phase 7)
  - ### Studio as shippable product (mindset)
  - ### Explicitly rejected alternatives

**Rules / invariants declared:**
1. Tier 1 (Reference) for data/schema/lookup material; multiple agents need it; inline duplication risks drift.
2. Tier 2 (Module) for stack-specific, substantial (>200 lines) content not every project needs.
3. Tier 3 (Subagent) for coherent jobs with clear input/output, own context, multiple invokers.
4. Never pre-extract; default to inline until pain is concrete (SKILL.md bloat or ≥2-place duplication).
5. Every agent is host-agnostic; no load-bearing Claude-Code-specific primitives.
6. Portable agent assumes: file I/O, POSIX shell, single session, read/write tools.
7. Inter-agent handoffs validate against JSON Schemas at `_shared/contracts/<kind>.schema.json`.
8. Zero third-party runtime deps in worker code; POSIX + `jq` + `yq` only.
9. `scripts/test-host.sh` enforces conformance across declared hosts; regressions block release.
10. Chanakya: Sonnet for orchestration; Haiku for event-processing modes. Achilles: Opus always. Argus: Opus always.

**References to other docs/files:**
- `_shared/router-pattern.md`
- `_shared/singleton-invariants.md`
- `_shared/contracts/<kind>.schema.json`
- `_shared/state-machines/<entity>.yaml`
- `_shared/project-memory.md` (Phase 2.7)
- `scripts/memory-query.sh` (Phase 2.7)
- `scripts/test-host.sh`
- `REVIEW.md`, `ROADMAP.md`, `CLAUDE.md`

**Claims about current state:**
- Phase 1 ✓ Foundation docs landed.
- Phase 1.5 ✓ Enforcement layer (linter, pre-commit hook, scaffold, graduation scan, surface manifest).
- Phase 2 ✓ Chanakya router refactor (router 55 lines + 14 mode packs + snapshot skeletons).
- Phase 2 (snap) ✓ Real snapshot producers, SessionStart prewarm, status-mode consumption, invalidation.
- Phase 3 (Achilles) ✓ Achilles router refactor (router 51 lines + 9 mode packs).
- Phase 2.6.6 ✓ Skill-testing primitive + four obra/superpowers adaptations.
- v0.4.0 follow-ups ✓ Sweep reliability bundle, Achilles base-refresh, review-waive lifecycle, REVIEW R11.
- Phase 2.5 planned: Router contract extensions (message contracts, state machines, idempotency, schema versioning, read/write declarations).
- Phase 2.6 planned: Ledger overhaul (structured YAML, `plans/index.yaml`, single canonical event log, Achilles `debrief` mode).
- Phase 2.7 planned: Knowledge layer (`_shared/project-memory.md`, `scripts/memory-query.sh`).

---

## REVIEW.md

**Purpose:** Project-specific review rules for generic-dev-studio; memory of corrections and invariants.

**Authoritative sections:**
- ## How to use
- ## Rules (R1–R11)
- ## Deferred / known gaps
- ## Rule evolution

**Rules declared (load-bearing):**
- **R1:** Zero new permission surface outside `~/.dev-studio/**` (ask tier).
- **R2:** Zero new user input in agent workflows (block + auto-fix tier).
- **R3:** Path resolution via `scripts/lib-paths.sh`, never hardcode (block + auto-fix tier).
- **R4:** Per-project default; machine-global only for physical-resource locks (ask tier).
- **R5:** Bash + zsh portability for `scripts/*.sh` (block + auto-fix tier).
- **R6:** SKILL.md kept in sync with script behavior via grep-checks (warn tier).
- **R7:** Comments encode WHY, not WHAT (block + auto-fix tier).
- **R8:** SKILL.md prose >20 lines considered for `_shared/` or stack-module extraction (warn tier).
- **R9:** Dual-write preserved during Phase 2.6 transition: YAML first, legacy second, partial-failure loud via `lib-ledger.sh` helpers (block + auto-fix tier).
- **R10:** Iron Law — no completion claims without fresh verification evidence (build log, test output, Argus verdict) captured in debrief (block + auto-fix tier).
- **R11:** No studio-initiated pushes to base branches; integration via `gh pr create` / `gh pr merge` only (block + auto-fix tier).

**References to other docs/files:**
- `_shared/primitives/file-locations.md` (R1)
- `_shared/patterns/dual-write-transition.md` (R9)
- `scripts/lib-paths.sh` (R3)
- `scripts/verify-ledger.sh` (R9 evidence)
- `scripts/lib-ledger.sh` helpers (R9)

**Claims about current state:**
- Dual-write T218a drift was caught by `scripts/verify-ledger.sh` because a writer mutated legacy brief markdown without paired YAML update (R9).
- One prior regression cost debugging time (R5 bash/zsh portability issue in `lib-paths.sh`).

---

## RELEASES.md

**Purpose:** Tagging and release-notes conventions.

**Authoritative sections:**
- ## When to tag
  - ### Tag-worthy signals
  - ### Not tag-worthy on its own
  - ### Cadence heuristic
  - ### How to suggest
- ## Release notes template
  - ### Style rules for "What's new"
  - ### Subject-flip test
  - ### Minor-bump headline rule
  - ### Major-bump extras
  - #### Cadence rules for MAJORs
- ## Versioning
  - ### Decide the bump by asking three questions
  - ### Mapping to version bumps
  - ### When to cut 1.0
  - #### `v1.0` is special
  - ### Pre-release suffixes
  - ### When in doubt
- ## Mechanics
  - ### Tags vs releases
  - ### Standard release flow
  - ### Hard rules

**Tag-worthy threshold:** "Cut a release when the repo crosses a **user-visible milestone** — someone who uses the studio should be able to upgrade and feel the difference." Heuristic: ≥3 tag-worthy commits OR ≥14 days + ≥1 tag-worthy commit.

**Release-notes tone rules:**
- User's outcome is the subject; software as subject fails.
- Plain language (10-year-old test).
- Lead with outcome in bold + one line of context.
- Workflow-first (if it doesn't change what user does/notices, cut it).
- Examples sparingly; not every bullet needs one.
- One line per bullet.

**Breaking change triggers (MINOR pre-1.0; MAJOR post-1.0):**
- Script flag removed or renamed.
- SKILL.md sub-command removed or renamed.
- On-disk path moved.
- Env var removed or renamed.
- Event log / task file / brief format changes old agents can't parse.

---

## ROADMAP.md

**Purpose:** Vision and themes for long-running directions; vision for remote orchestration via iMessage/Telegram; phase sequence (architecture refactor).

**Completed phases (ROADMAP claims):**
- Phase 1 ✓, Phase 1.5 ✓, Phase 2 ✓, Phase 2 (snap) ✓, Phase 3 (Achilles) ✓, Phase 2.6.6 ✓.

**Planned phases (ROADMAP claims):**
- Phase 2.5, 2.6, 2.7, 3, 4, 5, 6, 7, 8, 9.

---

## CLAUDE.md

**Auto-apply tier (no user ask):**
- Rule wording tweaks (REVIEW.md, RELEASES.md, CLAUDE.md, THEMES.md).
- Threshold adjustments backed by data.
- Brief-template additions.
- Skill-prose trimming (never-used sections).
- Comment improvements, dead-code removal, README clarifications.
- New issue creation (explicitly discussed work).
- Theme label assignment.
- Updating README roadmap timeline + Story so far on releases.

**Ask-first tier (requires user OK):**
- Changing how agents hand off (Chanakya → Achilles flow).
- Removing / renaming rules / sub-commands / event types.
- Breaking changes.
- Permission scope, secrets, auth changes.
- Deleting issues or releases.

---

## README.md

**Release history (story so far):**
- v0.1.0-beta.1 — First beta; three Claude agents coordinated over file-based inbox.
- v0.1.0-beta.2 — Workers as real Claude sessions (`/achilles worker`); collision-safe slot claiming.
- v0.2.0-beta.1 — Per-project fleets; terminal panes self-label; review/release rulebooks.
- v0.3.0 — Mode packs load on demand; Argus two-stage; structured YAML plans/debriefs; `/achilles debrief` mode; REVIEW R10.
- v0.4.0 — Orphan-debrief backfill; Achilles base-refresh pre-Argus; review-waive lifecycle; sweep telemetry restored.

---

## THEMES.md

**Active themes:**
- **theme/internal:** Studio gets faster, leaner, smarter per release.
- **theme/ios-craft:** Best assistant for Swift/SwiftUI/UIKit.
- **theme/release:** Release pipeline disappears.
- **theme/integrations:** Slack, Linear/Jira, Crashlytics, App Store Connect, GitHub, Notion.
- **theme/design:** Figma → code with high fidelity.
- **theme/discovery:** New MCPs, skills, tools evaluated in context.

**Active focus this season:** **theme/internal**.

---

## IDEAS.md

Captured (not yet planned):
- 2026-04-20 — Add `/achilles debrief` mode for direct-to-Claude bug fixes (already shipped in v0.3.0).

---

# Drift Catalog — ROADMAP claims vs. filesystem

| Phase | ROADMAP Status | Filesystem Evidence | Verdict |
|---|---|---|---|
| **Phase 1** | ✓ Completed | `_shared/patterns/router-pattern.md`, `singleton-invariants.md` present | **Shipped** |
| **Phase 1.5** | ✓ Completed | `scripts/lint-architecture.sh`, `.githooks/pre-commit`, `scaffold-agent.sh`, `graduation-scan.sh`, `update-surface-manifest.sh` all present | **Shipped** |
| **Phase 2** | ✓ Completed | Router in `chanakya/SKILL.md`; ~14 modes present | **Shipped** |
| **Phase 2 (snap)** | ✓ Completed | `scripts/chanakya-snap.sh`, `rebuild-index.sh`, SessionStart hook at `hooks/session-start`; status mode at `chanakya/modes/status.md` | **Shipped** |
| **Phase 3 (Achilles)** | ✓ Completed | Router in `achilles/SKILL.md`; 10 modes | **Shipped** |
| **Phase 2.6.6** | ✓ Completed | `scripts/test-mode-pack.sh`, `_shared/primitives/skill-testing.md`, two-stage Argus, 4-state worker-report, REVIEW R10, SessionStart hook | **Shipped** |
| **Phase 2.5** | **Planned** | `_shared/contracts/message-contract.md`, `schema-version.md`, `idempotency.md`, `read-write-decls.md` present; 5 state-machines; `_shared/patterns/capability-manifest.md` + `_shared/schemas/capability-manifest.json` present | **SHIPPED — ROADMAP is stale** |
| **Phase 2.6** | **Planned** | `_shared/schemas/{task,brief,debrief,round,release,review,crash}.md` present; `achilles/modes/debrief.md` exists; `plans/` directory and `plans/index.yaml` **not present at repo root** (correct — they live in `~/.dev-studio/<project>/`, per path invariant) | **SHIPPED — ROADMAP is stale** (plans/ live per-project under `~/.dev-studio/`, not in repo) |
| **Phase 2.7** | Planned | No `project-memory.md`, no `memory-query.sh`, no `chanakya/modes/knowledge.md` | **Not started** |
| **Phase 3** | Planned (partial) | `PHASE-3-PLAN.md` exists documenting cache-hit telemetry shape; no `/schedule` or `/loop` command; no `test-health.md` mode | **Partial — documented, not implemented** |
| **Phase 4** | Planned | No `luban/` directory | **Not started** |
| **Phase 5** | Planned | No Crashlytics integration; no Argus `smoke` mode | **Not started** |
| **Phase 6** | Planned (deferred to end) | No dashboard code | **Not started** |
| **Phase 7** | Planned | No routing-intelligence artifacts | **Not started** |
| **Phase 8** | Planned | `chanakya/docs.html` exists but no Phase 8 redesign markers | **Backlog** |
| **Phase 9** | Planned | Depends on Phase 2.7 | **Blocked** |

Note on Phase 2.6: the filesystem-agent flagged `plans/` missing from repo root — that's correct and by design. Per Iron Law #3 + `feedback_artifact_paths.md`, per-project ledger lives under `~/.dev-studio/<project>/plans/`, not in the studio repo. The schemas (which live in the studio repo at `_shared/schemas/`) are shipped; the runtime ledger instances are project-specific. **Phase 2.6 verdict: SHIPPED.**

---

## Host-agnosticism (ARCHITECTURE.md §Host-agnosticism)

**Principle:** Every agent is host-agnostic. No agent capability depends on Claude-Code-specific primitives in its load-bearing path.

**Quote:**
> Every agent is host-agnostic. No agent capability may depend on Claude-Code-specific primitives — hooks, the Agent subagent tool, tool-name dialects ("use the Read tool"), or SessionStart injection — in its load-bearing path. Host adapters provide ergonomic optimizations; they never provide required functionality. Portability is a tested invariant, not aspiration.

**Substrate claimed:**
- File I/O on the repo and `~/.dev-studio/**`
- POSIX shell
- Single model session with system prompt + turn loop
- Read/write tools in whatever dialect the host exposes

**Enforcement artifact:** `scripts/test-host.sh` present.

---

## REVIEW.md Rules R1–R11

| Rule | Tier | Summary |
|---|---|---|
| R1 | ask | Zero new permission surface outside `~/.dev-studio/**` |
| R2 | block+auto | Zero new user input in agent workflows |
| R3 | block+auto | Path resolution via `scripts/lib-paths.sh` |
| R4 | ask | Per-project default; machine-global only for physical-resource locks |
| R5 | block+auto | Bash + zsh portability |
| R6 | warn | SKILL.md kept in sync with script behavior |
| R7 | block+auto | Comments encode WHY, not WHAT |
| R8 | warn | SKILL.md sections >20 lines → consider extraction |
| R9 | block+auto | Dual-write preserved (YAML + legacy) |
| R10 | block+auto | Iron Law: no completion claims without fresh verification |
| R11 | block+auto | No studio-initiated pushes to base branches |

---

## Summary

All root docs present and authoritative. ARCHITECTURE.md, REVIEW.md, RELEASES.md, ROADMAP.md, CLAUDE.md, README.md, THEMES.md, IDEAS.md all readable and internally consistent.

**Phase completion drift (material for Session D):**
- Phase 2.5: marked Planned, actually SHIPPED. ROADMAP needs truth-up.
- Phase 2.6: marked Planned, actually SHIPPED (runtime ledger per-project by design). ROADMAP needs truth-up.
- Phase 2.7: confirmed Not started.
- Phase 3: partial — PHASE-3-PLAN.md exists, implementation pending.

Host-agnosticism principle exists in ARCHITECTURE.md; `scripts/test-host.sh` enforcement artifact present; implementation details in load-bearing paths remain (SessionStart, Agent tool, `claude -p`) — this is what issue #88 targets.

All 11 REVIEW.md rules present. R10 Iron Law and R11 push-base rule recent additions.
