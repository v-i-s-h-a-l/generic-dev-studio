# Studio Consolidation — Session D: Target Architecture

**Session D exit artifact.** Synthesizes audit (`01-audit.md`), parking-lot entries A+B, arc plan (`00-plan.md`), ARCHITECTURE §Design Vision, ROADMAP §Phase sequence, issue #88, and relevant memory into a single target architecture. Input to Session E (user review).

**What this doc is.** A set of ratified decisions with rationale. Not new code; not a migration plan. Session F derives the implementation scope from §6; G+ executes.

**What this doc is not.** A second pass at already-shipped Phase 2.5/2.6/2.6.5/2.6.6 work (those are authoritative), nor a rewrite of issue #88's changeset (adopted by reference), nor backlog grooming for the integration-surface cluster (out of arc).

---

## 0. Decisions at a glance

| # | Topic | Decision | Lands in |
|---|---|---|---|
| 1 | Parking-lot A — host-agnosticism principle | **Adopt with reshaping** — land in `ARCHITECTURE.md` as a principle; v1 implementation mechanics stay in issue #88 | Session F (principle) → #88 release (implementation) |
| 2 | Parking-lot B — mandatory skill invocation | **Adopt with reshaping** — extract Swift-specific table to a stack-scoped file; cross-cutting mechanic lives in a new `_shared/primitives/design-time-skill-routing.md` | Session F |
| 3 | Host-agnostic workers v1 | **Align with #88 as-is** — audit D2 confirms the bounded surface #88 already targets | Post-F release |
| 4 | Test-strategy primitive | **Adopt as drafted in `00-plan.md` §Test strategy** — new `_shared/rules/test-strategy.md`, brief-template consumers updated | Session F |
| 5 | Dispatch-routing unification (#65 × parking-lot B) | **Don't unify yet** — two routing tables (skills, models) ship as sibling primitives; flagged for extraction on second use | Session F (skills); #65 ships separately (models) |
| 6 | Session F scope | See §6 below | Session F |
| 7 | Non-goals for D | Integration-surface cluster (D9); `turnip-project-config.md` relocation (D8) | Out of arc |

---

## 1. Parking-lot A — host-agnosticism principle

**Decision: adopt with reshaping. Lands in `ARCHITECTURE.md` as `§Host-agnosticism`, separate from issue #88's v1 implementation.**

### Reshape notes

1. **Principle vs. implementation separation.** The stashed 18-line block mixes principle (portable substrate, contract-first handoffs, zero third-party runtime deps) with specific enforcement mechanism (`scripts/test-host.sh`). Session F lands the principle; the enforcement script is delivered by issue #88's release. ARCHITECTURE.md should cite the script as the invariant's verification method without depending on it existing.
2. **Off-by-one fix.** Stashed diff says "Chanakya… 15 modes vs. 10"; audit counts 16 Chanakya modes. Fix in the landed version.
3. **Worker-first staging rationale kept verbatim.** The stashed prose captures "wider surface, higher model-quality sensitivity, harder conformance, prompt-cache economics" — matches memory `project_host_agnostic_workers.md` and audit D2 findings. No change needed.
4. **Adapter shape (`skills/agents/commands/` canonical + `.<host>/` dotdirs + per-host root-instruction filenames) stays.** Superpowers-validated across seven hosts; no reason to re-derive.

### Why this doesn't short-circuit the arc

Parking-lot concern was that committing the principle pre-synthesis would preempt design decisions. Session D has the full audit in hand (D2 confirms the surface is bounded; D3 confirms the principle aligns with ARCHITECTURE's existing direction). Committing now is synthesis-scoped, not cascade.

### Open item for Session F

ARCHITECTURE.md §Host-agnosticism cites `scripts/test-host.sh` as the verification primitive. Session F commits the principle; #88 delivers the script. The prose should read "verified by `scripts/test-host.sh` (delivered in host-agnostic-workers-v1 release)" — forward reference, not dead link.

---

## 2. Parking-lot B — mandatory design-time skill invocation

**Decision: adopt with reshaping. The mechanic (structural skill invocation at Achilles Step 4.0/5.0 + Argus Step 3.5) is cross-cutting; the Swift-specific skill table is stack-scoped.**

### Reshape

1. **Extract the mechanic to a shared primitive.** New file `_shared/primitives/design-time-skill-routing.md` defines:
   - What "design-time skill routing" means (pre-edit skill dispatch + post-diff skill re-invocation + self-review verdict schema).
   - Contract between the primitive and its consumers (what Achilles Step 4.0 reads; what Step 5.0 writes to the debrief `## Self-Review` block; what Argus Step 3.5 reads).
   - Required verdict states: `clean | minor | material` (matches parking-lot B).
   - Failure rule: `material` ⇒ fix-then-rerun; no rationalizing.
   - Commit-message "Design choices" 2–4 line note invariant.
2. **Stack-scoped skill tables live outside the primitive.** For now, since Turnip iOS is the only project, ship the Swift table at `_shared/rules/swift-skill-routing.md` (or a cleaner name chosen at implementation). When the second project arrives, this becomes the `projects/<slug>/skills.yaml` stack-module pattern. Don't pre-build the module layer; land the file, keep its location abstractable.
3. **Argus integration: extend `code-quality.md`, don't add a third stage.** Two-stage Argus (spec-compliance → code-quality) just landed in 2.6.6. Adding a third stage is a sequencing churn cost. Step 3.5 sits inside `code-quality.md` as a mandatory sub-step on Swift diffs, flagged `rule: design/<category>` per parking-lot B. `FLAGS` only, never `BLOCKS` in week-1 posture.
4. **Token cost mitigation.** Step 4.0 in every Achilles session would inline the Swift skill table = R8 weight concern per proxy-user engineering discipline. Primitive extraction (point 1) solves this: Achilles mode pack references the primitive file; the primitive is read on-demand.

### Scope: Turnip-only for now, but architected to generalize

Per proxy-user §architectural preferences ("host-agnostic substrate thinking: decisions in one portability release should generalize to future ones"), the primitive + stack-rule split is the generalization hook. Turnip is the pilot; a second stack inherits by adding its own `<stack>-skill-routing.md` + declaring it in the project config. No code changes to the primitive.

### Session F must ship fixtures

Per 2.6.6 gate + D6: any mode pack touched by this adoption (Achilles task.md, Argus code-quality.md) carries a test-mode-pack fixture. If the primitive itself has testable dispatch behavior, fixture it too.

---

## 3. Host-agnostic workers v1 (issue #88)

**Decision: adopt issue #88's v1 changeset by reference. Audit D2 confirms the bounded surface matches #88's keystones.**

### What Session D ratifies

- Scope: Achilles + Argus ship portability together. Chanakya deferred as a follow-up release (per memory `project_host_agnostic_workers.md`; no change).
- Two Codex-blocking items match audit: SessionStart hook (prose-preamble fallback) + `dispatch-review.sh` keystone (replaces Agent-tool prose at Achilles Step 8.5).
- JSON Schema contracts (`worker-report`, `debrief`, `review-verdict`) at worker-handoff boundaries align with Phase 2.5's `schema-version.md` primitive — this is where the primitive gets operational.
- Graceful-degradation principle (fail loud, never silent skip) lands in `REVIEW.md` as a new rule. Audit confirms the Argus-via-Agent-tool silent no-op is the exact bug class this principle prevents.
- Conformance matrix (`scripts/test-host.sh`) runs 3 canned tasks (XS / M / TDD). Single-task harness rejected.
- Per-host event telemetry (`host:` tag on every event) — feeds Phase 3 cache economics. No change from #88.

### What Session D adds / clarifies over #88

1. **Principle-vs-implementation cleanly split per §1 above.** ARCHITECTURE.md §Host-agnosticism lands in Session F (principle). #88's release delivers the implementation. Session F must not block on #88's implementation; #88's release can proceed without re-editing the principle.
2. **Open questions in #88 remain open at Session D's exit** — they're implementation-time decisions (JSON Schema validator choice, `dispatch-review.sh` blocking strategy, host detection mechanism, `host:` placement in event payload, conformance-task source). Not synthesis-gated.
3. **Zero-third-party-runtime-deps rule lands in two places at once.** `REVIEW.md` (enforcement) and `ARCHITECTURE.md §Host-agnosticism` (principle). Already redundant-on-purpose; keep.

---

## 4. Test-strategy primitive

**Decision: adopt as drafted in `00-plan.md` §Test strategy. New primitive at `_shared/rules/test-strategy.md`.**

### Shape

The primitive declares four churn layers and their test-strategy mappings, per `00-plan.md`:

| Layer | Churn | Test strategy |
|---|---|---|
| Core domain invariants | Low | Unit tests |
| SDK adapters / wrappers | Medium | Contract tests (shape, not impl) |
| UI / glue / view code | High | Snapshot + XCUITest + real-device smoke |
| Exploratory / prototype | Very high | Manual verification; no auto-tests |

### Consumers Session F updates

1. **Chanakya brief templates** — `impl-brief.md`, `unit-test-brief.md`, `task-tdd.md` (any brief format that concerns tests) add a `churn_layer` field. Brief-generation logic asks "what churn layer?" and recommends test type.
2. **Achilles mode packs** — `task-tdd.md`, unit-test / UI-test / integration-test modes choose test type from the primitive, not by defaulting to unit.
3. **Argus `code-quality.md`** — the "no unit test for new code" finding is conditional on churn layer. High-churn code routes to contract/snapshot/XCUITest findings instead; `code-quality` does not block on missing unit tests where the primitive says unit tests aren't the right layer.

### Turnip-specific application (captured, not in primitive)

Per `00-plan.md`: characterization test (20 reference photos) before imgly→native swap; snapshot tests on editor screens; delete imgly-coupled unit tests; keep unit tests on stable core (color math, export encoders). This is an *application* of the primitive — goes in a Turnip-scoped note, not in `_shared/rules/test-strategy.md`.

### Fixture requirement

Per 2.6.6 gate: if the primitive is referenced from a mode pack, the mode pack ships with a test-mode-pack fixture demonstrating churn-aware routing. Session F retrofit.

---

## 5. Dispatch-routing unification (D4 × #65)

**Decision: don't unify yet. Ship as sibling primitives with an explicit cross-ref so future unification is a refactor, not a discovery.**

### Rationale

Parking-lot B (skills routing) and #65 (model routing) share shape ("task signals → what fires"), but:

- **Skills routing** is *diff-shape-driven* (architecture change? concurrency code? SwiftUI view?). Signals computed from diff + brief intent.
- **Model routing** is *task-envelope-driven* (XS/M/L size, kind, novelty). Signals computed from brief metadata.

They share the *router-pattern mechanic*, not the *input space*. A unified primitive today would either leak both input spaces into one table (ugly) or force premature indirection (YAGNI fail).

### Concrete decision

- `_shared/primitives/design-time-skill-routing.md` (delivered per §2) lands first.
- `_shared/rules/model-recommendation.md` (per #65) ships when #65 is picked up — separately.
- **Both files carry a `See also:` cross-ref** to each other. If a third routing concern arrives (e.g., test-strategy-by-churn from §4 also routes deterministically from task shape), the second-use rule fires and Session H+ extracts a shared primitive.

### Proxy-user persona check

"YAGNI with teeth" + "extract on second use, not first" + "inherit existing contracts". The router-pattern mechanic is inherited (existing `_shared/router-pattern.md`); we don't need to extract a meta-router for two instances of it.

---

## 6. Session F scope

Ordered list. Session F is "pre-implementation setup" per `00-plan.md` — it prepares substrate + CLAUDE.md triggers + the `studio` skill router, retrofits per 2.6.6, and lands cheap auto-apply housekeeping. Does *not* execute #88 (that's G+ or a standalone release after F).

### F tasks (all auto-apply tier)

1. **Land ARCHITECTURE.md §Host-agnosticism.** Pop `park-A-arch-host-agnosticism` stash, apply reshape from §1 (principle-only; forward-ref `scripts/test-host.sh`; fix 15→16 mode count), commit. Parking-lot A removed.
2. **Extract `_shared/primitives/design-time-skill-routing.md`.** Author the cross-cutting mechanic per §2. Stack-scoped Swift table at `_shared/rules/swift-skill-routing.md` (name subject to change at implementation if a cleaner fits). Update Achilles `task.md` + Argus `code-quality.md` to read from the primitive. Ship test-mode-pack fixtures for both. Parking-lot B removed.
3. **Author `_shared/rules/test-strategy.md`.** Per §4. Update `impl-brief.md`, `unit-test-brief.md`, `task-tdd.md` consumers. Ship fixture.
4. **Build the `studio` skill router.** Cross-agent router with Tier 1 modes: `resume-plan`, `review`, `release`, `ingest`. Tier 2 modes spawn per usage. Router pattern per `_shared/router-pattern.md`. Every Tier 1 mode ships with a 2.6.6 fixture from day 1.
5. **CLAUDE.md triggers updated.** Skill Conventions section extended with `studio` router invocation rules — which mode to fire when the user says "where were we," "review," etc. (mostly already there via `/resume-plan`; make it systematic).
6. **ROADMAP truth-up (D1).** Move Phase 2.5 + 2.6 + 2.6.5 + 2.6.6 from "Planned" to "Completed." Add `host-agnostic-workers-v1` release to the sequence as a named release, not a phase.
7. **Stale-memory cleanup (D5).** Remove `project_planning_sweep_pending.md` (superseded by consolidation arc; post-arc it's fully obsolete).
8. **Fixture retrofit plan (D6).** Not the retrofit itself — the *plan*: batch 21 missing fixtures into groups of 3–5, schedule as background work during low-intensity sessions. Author the plan as a short doc + open a GH issue tracking progress.

### F exit artifact

`04-approved.md` is Session E's artifact (user sign-off on this doc). Session F's exit is the commit history on `main` — no separate doc. Brief the user retrospectively per `00-plan.md` §Briefing (2–4 lines, cumulative).

---

## 7. Non-goals for Session D (reaffirmed)

Explicitly not decided by this doc:

1. **Integration-surface hardening cluster (D9)** — #93, #94, #90, #75, #74, #73. Backlog under `theme/integrations`. Revisit post-arc.
2. **`_shared/primitives/turnip-project-config.md` relocation (D8)** — issue #57. Follows the future `projects/<slug>/` substrate, which is a host-agnostic-v1+ concern, not Session F.
3. **Chanakya portability** — follow-up release, not Session F and not #88 v1.
4. **`#65` model-routing** — ships when picked up; Session F does not draft it.
5. **Confucius as separate agent** — deferred per ARCHITECTURE §Design Vision; Chanakya `modes/knowledge.md` covers for now.
6. **Phase 6 dashboard position** — stays at end per `project_phase_6_deferred.md`.

---

## 8. Parking-lot status at Session D exit

Both entries processed. File is empty of unresolved items.

- **A — host-agnosticism principle**: decision §1; Session F implements; parking-lot entry removed on F commit.
- **B — mandatory skill invocation**: decision §2; Session F implements; parking-lot entry removed on F commit.

If new dimensions surface during Session F, they follow `00-plan.md` no-cascade rule: out-of-arc → GitHub issue, not a re-opened arc.

---

## 9. Inputs honored

For the record — Session D read:

1. `00-plan.md` (arc ground truth, proxy-user persona, test-strategy framework).
2. `studio-consolidation/parking-lot.md` (A + B).
3. `01-audit.md` (synthesis lens + §3 Session C completion).
4. `ARCHITECTURE.md` §Design Vision (2026-04-20 synthesis) + three-tier extraction model.
5. `ROADMAP.md` §Phase sequence (2.5/2.6/2.6.5/2.6.6 completed; 2.7/3/4/5/7/8/9/6 planned).
6. Issue #88 body + 2026-04-24 scalability/standardization comment.
7. Issue #65 body.
8. Memory: `project_host_agnostic_workers.md`, `project_phase_6_deferred.md`, `project_consolidation_arc.md`.

Raw audit partials not re-read — `01-audit.md`'s synthesis lens covered every cross-domain signal needed.

---

## 10. Session E — user review prompt

When user runs Session E (the next arc touchpoint):

1. Read this file cold.
2. Verify each decision in §0 matches intent. Amend where not.
3. Sign off by producing `04-approved.md` with any deltas captured.
4. Then Session F auto-runs.

User amendments at E re-open only the specific decisions challenged. Unmodified decisions carry through to F without re-synthesis — no-cascade preserved.
