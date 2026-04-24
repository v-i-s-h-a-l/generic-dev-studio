# Studio Consolidation — Session B: Internal Audit (stitched)

**Session B exit artifact.** Stitched synthesis of four parallel audit partials (shared substrate / agents / root docs / external state), plus cross-domain drift catalog and Session C gap decision. Supersedes no prior artifact; is input to Session D synthesis.

**Source partials (read these for the raw inventory; this doc is the synthesis lens):**
- `01-audit-partial-shared.md` — 70 files across `_shared/{contracts,patterns,primitives,rules,state-machines,schemas}`
- `01-audit-partial-agents.md` — 28 mode packs, 3,111 lines (Chanakya 16 / Achilles 10 / Argus 2)
- `01-audit-partial-docs.md` — 8 root docs + phase drift catalog
- `01-audit-partial-external.md` — 70 scripts, 19 open issues, 18 memory entries, recent debriefs

---

## 1. Inventory totals

| Domain | Count | Notes |
|---|---|---|
| `_shared/` files | 70 | 16 contracts (5 brief-format templates), 8 patterns, 13 primitives, 5 rules, 5 state-machines, 18 schemas |
| Agent mode packs | 28 / 3,111 lines | Chanakya 16/1,751 · Achilles 10/1,036 · Argus 2/324 |
| Shell scripts | 70 | 31 emit structured events; all path-resolver-compliant (Iron Law #3) |
| Event types in catalog | 30+ | Catalog at `_shared/contracts/events.md` |
| Open GitHub issues | 19 | Clustered: host-agnostic (#88, #56, #57), Phase 2.6 post-cutover (#76, #62, #61, #58, #64), Phase 2.5 follow-ups (#55), studio gaps (#93, #90, #89, #94, #74, #73, #75, #65) |
| Memory entries | 18 | 1 stale (`project_planning_sweep_pending.md` — superseded by consolidation arc) |
| Schemas with SemVer | 10 | task@1.0.0, brief@3.1.0, debrief@2.0.2, review@1.1.0, release@1.0.0, round@1.0.0, feedback@1.0.0, crash@1.0.0, capability-manifest@1.0.0, master-plan (legacy) |

---

## 2. Cross-domain drift catalog

Signals that only surface when crossing domains. Ordered by synthesis-impact.

### D1 — ROADMAP vs. reality: Phases 2.5 + 2.6 are SHIPPED, documented "Planned"

**Domains:** docs + shared + external + agents (all four corroborate).
**Evidence.**
- docs partial: ROADMAP lists Phase 2.5 "Planned" but `_shared/contracts/{message-contract, schema-version, idempotency, read-write-decls}.md` + 5 state-machines + capability-manifest all present; Phase 2.6 "Planned" but all YAML schemas + `debrief` mode + `lib-ledger.sh` primitives present.
- shared partial: all 10 SemVer schemas shipped; dual-write-transition pattern authored; `brief_completed.gate` taxonomy live.
- external partial: git log shows Phase 2.6.5 + 2.6.6 landed 2026-04-17…04-23, 11+7 commits respectively; ledger mutation primitives owned by scripts.
- agents partial: mode packs reference 2.6 schemas (`brief@3.1.0`, `debrief@2.0.2`, `review@1.1.0`) as consumed dependencies.

**Synthesis implication.** ROADMAP §Phase sequence is the source of planning truth but carries stale "Planned" markers on two shipped phases. Auto-apply tier: ROADMAP truth-up lands in Session F or as a standalone commit — **not** synthesis-gated.

**Severity.** Cosmetic for the arc (Session D can read filesystem directly). Load-bearing for external readers (contributors / fresh sessions treating ROADMAP as truth).

### D2 — Host-coupling is surgically bounded; concentration in ≤3 prose locations

**Domains:** agents + external + docs.
**Evidence.**
- agents partial: only 3 prose hotspots — `chanakya/modes/inbox-sweep.md:100` (SessionStart ref), `achilles/modes/{worker,task,studio-feedback}.md` (`claude -p` spawn), `achilles/modes/task.md` Step 8.5 (Argus via Agent-tool).
- external partial: **"No scripts currently hardcode Claude-Code-specific primitives — Agent/Read/Write tool references are in prose files only."** 70 scripts are clean.
- docs partial: ARCHITECTURE.md declared a host-agnosticism principle at §Host-agnosticism at audit time — **see D4 on provenance**.

**Synthesis implication.** #88 (Host-Agnostic Workers) targets a clean, bounded surface: three prose sites + one dispatch-review.sh keystone. The script tier is already portable. Adapter work is surgical, not a rewrite.

**Severity.** This is the most important positive finding of Session B. It raises confidence that #88 can ship without architectural excavation — the portability tax is already paid in the substrate.

### D3 — Parking-lot A (host-agnosticism principle) partly overlaps with ARCHITECTURE.md reality

**Domains:** parking-lot + docs + memory.
**Evidence.**
- parking-lot.md entry A: "18-line §Host-agnosticism section for ARCHITECTURE.md" — stashed as `park-A-arch-host-agnosticism`.
- docs partial (audited 2026-04-24 before triage): lists ARCHITECTURE.md §Host-agnosticism as present, with 9 declared rules including portable-substrate definition, contract-first handoffs, adapter shape, `scripts/test-host.sh` enforcement.
- memory entry `project_host_agnostic_workers.md`: "audit done, OSS research complete, issue #88 filed."

**Synthesis interpretation.** The docs audit sampled the working tree with the uncommitted +18-line addition; Session B partial reflected that state. Post-triage, the addition is in `git stash` and ARCHITECTURE.md no longer has §Host-agnosticism in tree.

**Implication for Session D.** Treat the docs partial's §Host-agnosticism block as **a provisional draft captured in the audit**, not as committed truth. Session D reads `parking-lot.md` entry A + the stashed diff when deciding adopt / reshape / drop. Don't double-count the principle as "already ARCHITECTURE-landed."

**Minor drift.** The stashed principle claims "Chanakya… surface area (15 modes vs. 10)"; agents partial counts 16 modes. Off-by-one; harmless for the argument.

### D4 — Parking-lot B (mandatory skill invocation) and issue #65 point at the same gap

**Domains:** parking-lot + issues + CLAUDE.md + agents.
**Evidence.**
- parking-lot B (stashed): makes skill invocation structural at Achilles Step 4.0 + Step 5.0 + new Argus Step 3.5; Swift-specific skill table covers architecture / API-design / concurrency / SwiftUI / IMGLY / testing.
- external partial: issue #65 = "Task-level model recommendation system" (Opus/Sonnet/Haiku per task).
- CLAUDE.md "Skill Conventions": `/swiftui-pro`, `/swiftui-view-refactor`, `/swift-concurrency-pro`, `/swift-testing-pro`, `/swift-api-design-guidelines-skill`, `/swift-architecture-skill` — five of six already exist ambient to Claude Code.
- agents partial: no mode pack currently declares skill dependencies in frontmatter; skills are invoked opportunistically in prose.

**Synthesis interpretation.** "Which skill fires when" is a first-class routing concern adjacent to #65 ("which model fires when"). Parking-lot B proposes per-diff-shape skill routing; #65 proposes per-task model routing. Session D decides whether to unify these into one **agent-dispatch-routing** primitive (skills × models × mode packs selected by task shape) or keep them separate.

**Severity.** Potential tier-3 architectural extract — don't land either in isolation.

### D5 — `project_planning_sweep_pending.md` is stale and load-bearing only by accident

**Domains:** memory + arc-plan.
**Evidence.**
- external partial: flagged stale. Memory content says "next: Phase 2.7" (superseded by consolidation arc's Session D).
- memory entry `project_consolidation_arc.md`: explicitly supersedes the sweep-pending pointer.

**Implication.** Session F housekeeping. Low priority. Auto-apply during F.

### D6 — Test-mode-pack fixture coverage: 7 of 28 mode packs covered

**Domains:** shared + agents.
**Evidence.**
- shared partial §primitives/skill-testing.md: Phase 2.6.5 retroactive coverage = 5 packs; live-fire dispatch fixtures added 2026-04-24 (3 SKILL.yaml files). Total ≈ 7 with fixtures.
- agents partial: 28 mode packs total. **21 missing fixtures.** Lint emits `W_MISSING_PACK_FIXTURE` (warn, not block).

**Implication.** Retrofit is a silent task-backlog item. New mode packs from Session D + F **must** ship with fixtures per 2.6.6 gate. Session D should not produce new mode packs without matching fixtures.

### D7 — Test-strategy primitive is an unfilled slot referenced by the arc plan

**Domains:** plan + shared + agents + proxy-user-persona.
**Evidence.**
- `00-plan.md` §Test strategy: proposes `_shared/rules/test-strategy.md`, layered by churn rate (unit for low churn, contract for SDK adapters, snapshot + XCUITest for UI, manual for prototypes).
- shared partial: `_shared/rules/` has cleanup, debt-tracking, enforcement, localization, review-rules — **no** test-strategy.md.
- agents partial: Achilles test modes (`task-tdd`, unit-test / ui-test / integration brief formats) default to unit tests without churn-aware routing.

**Implication.** Clean Session D output slot. Drafting `_shared/rules/test-strategy.md` + updating `impl-brief.md` + `unit-test-brief.md` templates to ask "what churn layer?" is synthesis-scoped. Turnip-specific characterization-test recipe (pre-imgly→native) is an application of the primitive, not the primitive itself — keep scope layered.

### D8 — `_shared/primitives/turnip-project-config.md` still lives at studio scope

**Domains:** shared + issues.
**Evidence.**
- shared partial: flagged for move to `projects/turnip/` post-2.5.
- external partial: issue #57 open, labeled `polish / phase-2-5-followup`.

**Implication.** Known cleanup. Belongs in the same refactor as any future `projects/<slug>/` substrate — ties to stack-module concept from parking-lot B §Turnip-only vs generalize.

### D9 — Slack / Playwright / App Store gaps cluster as "integration surface hardening"

**Domains:** issues + themes.
**Evidence.**
- external partial: #93 (parenthesized studio-feedback parse), #94 (queued-prompt-slack), #90 (Playwright MCP OAuth), #75 (App Store char limit), #74 (bug-analysis Slack flow), #73 (App Store PR verify).
- THEMES.md: `theme/integrations` exists (Slack, Linear/Jira, Crashlytics, App Store Connect, GitHub, Notion). Active-focus season = `theme/internal`.

**Implication.** These are off-arc — Session D should not pull them in. Park as `theme/integrations` backlog; revisit post-arc. Already well-tracked via issues.

### D10 — No true contradictions in `_shared/`

**Domains:** shared self-check.
**Evidence.** Shared partial §Cross-contract drift catalog: 12 candidate items, all resolve as intentional layering (legacy vs canonical, full-lifecycle vs user-view projection, strict vs staged rollout, tracked deprecations). Zero dangling cross-refs across 70 files.

**Implication.** The substrate tier is internally coherent. Session D inherits contracts without reconciliation work.

---

## 3. Session C gap decision

**Gate:** `Session C runs only if B surfaces external gaps.` — `00-plan.md`.

**External-research candidates considered:**

| Candidate | Is it an external-research gap? | Rationale |
|---|---|---|
| Host-agnostic portability patterns | **No — done** | Memory `project_host_agnostic_workers.md` confirms OSS research complete; issue #88 carries the 2026-04-24 research comment; CrewAI / AutoGen / Aider / Superpowers patterns already absorbed in parking-lot A draft. |
| Skills infrastructure design (studio router + Tier 1/2 modes) | **No** | Internal design; inherits existing router-pattern.md. Synthesis-scoped, not research-scoped. |
| Test strategy layering by churn rate | **No** | Plan §Test strategy captures the framework; Turnip specifics are application. Synthesis writes `_shared/rules/test-strategy.md`. |
| Task-level model recommendation (#65) | **No** | Needs internal telemetry (Max-plan consumption, not per-token cost), not OSS survey. |
| Integration-surface hardening cluster (#90, #93, #94, #73, #74, #75) | **No — off-arc** | Backlog, not architecture. |
| Parking-lot A + B | **No** | Synthesis decides; research already done for A; B is internal design. |

**Decision: Session C is SKIPPED.** Proxy-user auto-decides. External research would be make-work; all open design questions are synthesis-resolvable from in-tree inputs + existing memory + the two parking-lot entries.

**Next Claude session:** Session D synthesis — reads `00-plan.md`, this file, `parking-lot.md`, the 4 partials, ARCHITECTURE §Design Vision, ROADMAP §Phase sequence, issue #88, memory `project_host_agnostic_workers.md`. Produces `03-target-architecture.md`. **Does not** also execute Session F implementation.

---

## 4. Inputs for Session D synthesis

Consolidated read-list Session D must ingest cold:

1. `00-plan.md` — arc ground truth, proxy-user persona, test-strategy framework, appendix §what prior revisions are being absorbed.
2. `studio-consolidation/parking-lot.md` — A (host-agnosticism principle, stashed as `park-A-arch-host-agnosticism`) + B (skill-invocation upgrade, stashed as `park-B-skill-invocation-upgrade`).
3. This file (`01-audit.md`) — synthesis lens; skip partials unless drilling into specific drift.
4. Partials only if D needs raw numbers: `01-audit-partial-{shared,agents,docs,external}.md`.
5. `ARCHITECTURE.md` — §Design Vision (2026-04-20 synthesis). §Host-agnosticism is **not** there (per D3); use the stashed diff if adopting.
6. `ROADMAP.md` §Phase sequence — source of record despite D1 staleness; Session D may truth it up as a side-effect, or defer to Session F.
7. Issue #88 body + 2026-04-24 research comment — major unblocked item; D2 shows the surface is bounded.
8. Memory `project_host_agnostic_workers.md`, `project_phase_6_deferred.md`, `project_consolidation_arc.md`.

Session D output (`03-target-architecture.md`) must address:
- Adopt / reshape / drop for parking-lot A + B (D3, D4).
- Host-agnostic workers v1 architecture (Achilles + Argus) building on D2's bounded surface.
- Test-strategy primitive `_shared/rules/test-strategy.md` (D7).
- Unified dispatch-routing vs separate (skills vs model) per #65 × parking-lot B intersection (D4).
- Session F scope: `studio` skill router + Tier 1/2 modes + CLAUDE.md triggers + ROADMAP truth-up (D1) + stale-memory cleanup (D5) + fixture retrofit plan (D6).
- **Non-goals for D**: integration-surface cluster (D9), turnip-config relocation (D8 — follows whichever Session F work lands the `projects/<slug>/` substrate).

---

## 5. Parking-lot deltas from Session B

No new items parked during Session B (audit was read-only by design). Existing entries A and B stand as-is; this file's D3 and D4 update their synthesis framing without modifying the entries themselves.

---

## Summary

Studio is internally coherent: 70-file substrate with zero contradictions, 28 mode packs cleanly referencing shipped contracts, 70 scripts host-clean. Two ROADMAP phases (2.5 + 2.6) are shipped but documented planned — cosmetic drift. Host-coupling is surgically bounded to 3 prose sites, making #88 tractable. Parking-lot A and B are the live design questions for Session D; no external research needed. Session C skipped. Next: Session D synthesis in a fresh Claude session.
