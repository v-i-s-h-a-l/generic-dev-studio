# Studio Consolidation — Arc Plan

**Session A exit artifact.** Defines the 7-session consolidation arc, proxy-user persona, no-cascade discipline, and resume protocol. Supersedes all prior incremental revisions of #88 until the arc closes.

---

## Why this arc exists

Prior planning sessions cascaded: each surfaced one new dimension (Superpowers patterns → substrate reframe → Phase 2.5 already shipped → skills infra → router pattern), each prompted a spec revision, the spec never converged. Root cause: iterative discovery without synthesis. Fix: forced multi-session arc with exit artifacts, no-cascade rule, and one terminal synthesis pass.

---

## Session model

**One arc-session = one Claude Code session.** Fresh context per session. Handoff is strictly file-based: each session reads the prior session's exit artifact(s) cold, produces its own exit artifact, commits, ends. No mega-session accumulation.

Within a single arc-session, parallelization is allowed (e.g., Session B runs 4 parallel audit subagents). Synthesis of subagent returns happens in the *next* Claude session, reading persisted partial files — not in the same session that launched the subagents. This preserves the "fresh context per synthesis" discipline.

## The arc (7 sessions)

| # | Session | Scope | Exit artifact | Gate |
|---|---|---|---|---|
| A | Plan the arc | This doc | `00-plan.md` + memory + commit | User approves (this turn) |
| B | Internal audit | Inventory `_shared/**`, agents, docs, issues, memory | `01-audit.md` | Auto (me, on agent returns) |
| C | External research (conditional) | Only if B surfaces external gaps | `02-research.md` or skipped | Auto (me, at end of B) |
| D | Synthesis | Integrate audit + research + prior revisions → one target architecture | `03-target-architecture.md` | Auto (me) |
| E | Verification / review | User reads cold, amends, signs off | `04-approved.md` | **User** |
| F | Pre-implementation setup | Build `studio` skill + Tier 1 modes + CLAUDE.md triggers | Skills committed, dogfood run | Auto (me) |
| G+ | Implementation | Execute approved plan | Commits per step, closes issues | Auto (me), per-step briefs |

**Critical property:** only sessions A and E require the user. B, C, D, F, G run on proxy-user auto-decisions with retrospective briefings.

---

## Proxy-user persona

Used by me to auto-answer non-critical decisions. Consult on every ambiguous choice. Values ordered roughly by precedence.

### Quality bar
- **World-class or nothing.** Never ship mediocre, fragile, or ordinary. Phase work, never quality.
- **One-synthesis-beats-N-iterations.** Overhauling is the failure mode to avoid. Come back for minor fixes only.
- **Fail loud, never silent.** Silent degradation is a correctness bug.

### Cost / resource model
- Individual user, free tool. Runs on user's existing Claude Max subscription.
- No per-token dollar thinking. Budget on quality, rate-limits, CPU/memory, not money.
- No additional paid services introduced.
- Telemetry tracks consumption, not cost.

### Engineering discipline
- **Zero third-party runtime deps in worker paths.** POSIX + `jq` + `yq` only. Chanakya is allowed marginally more.
- **Inherit existing contracts.** `_shared/contracts/`, `_shared/patterns/`, `_shared/schemas/`, `_shared/state-machines/` are authoritative. New work inherits, never contradicts. If a contract already specifies a shape, do not invent a new one.
- **Paths via `scripts/lib-paths.sh`.** Never hardcode. Runtime writes to `~/.dev-studio/**` only.
- **YAGNI with teeth.** Don't design for hypothetical future needs. Extract on second use, not first.
- **Backward compat shims are tax, not value.** Delete unused code completely; don't leave deprecation comments.
- **No TODOs.** Only tracked deferrals (e.g., `TODO(#42):`) in code.

### Operational preferences
- **Minimal human intervention.** Design for unattended / remote operation. Permission prompts are blockers.
- **Auto-apply tier** per CLAUDE.md: rule tweaks, threshold adjustments, doc sync, label assignment, comment improvements — apply silently, brief retroactively.
- **Ask-first tier** per CLAUDE.md: hand-off flow changes, rule removals, user-project runtime behavior, permissions/secrets, breaking changes, issue/release deletion.
- **Single integrated releases** preferred over many small ones unless scope demands split.
- **Briefing:** 2–4 line summary on cumulative non-trivial work. Stay silent on trivial.

### Architectural preferences
- **Router pattern** for dispatch (precedent: Chanakya, Achilles, Argus all use it).
- **Namespaced / extensible manifests** over flat ones when the manifest will grow.
- **Schemas carry `schema_version` object** (name, version SemVer, min_reader, deprecated_at) per existing contract.
- **Host-agnostic substrate thinking:** decisions in one portability release should generalize to future ones.
- **Test strategy layered by churn rate** (see §Test strategy below).

### Scope discipline
- **No scope creep mid-session.** Parking lot only. Review parking lot at synthesis.
- **Separate issues for deferred work.** Per CLAUDE.md backlog rule.
- **No implementation claims without fresh verification evidence** (REVIEW.md R10).

---

## Critical decision threshold

Bubble up to real user. Do NOT auto-decide.

1. Any change to user's project (Turnip) runtime behavior.
2. Destructive operations: data deletion, force-push, branch removal, file mass-delete.
3. Removing or renaming a user-facing sub-command, flag, or event type.
4. Permission / secrets / auth changes.
5. Breaking changes per RELEASES.md MAJOR rules.
6. Scope expansion that meaningfully extends the arc timeline beyond this plan.
7. True ambiguity where proxy-persona cannot determine preference and the choice has long-term architectural consequence.
8. Anything contradicting a stated preference in memory or this plan.

Everything else: auto-decide, commit, brief in next turn (2–4 lines).

---

## No-cascade discipline

Enforced across all non-user sessions (B, C, D, F, G).

1. **Exit artifact is terminal for its session.** No re-opening except at synthesis (D) or review (E).
2. **Parking lot.** New dimensions surfaced mid-session land in `studio-consolidation/parking-lot.md` (append-only). Reviewed once, at start of synthesis.
3. **Out-of-arc items → GitHub issue.** Per CLAUDE.md backlog rule. Don't expand the arc.
4. **Synthesis is the only redesign moment.** Sessions B/C feed D; no mid-flight spec revisions.
5. **If scope has drifted since Session A, stop and re-plan.** Never proceed with ambiguous scope.

---

## Resume protocol

Any session starts with:

1. Read `~/.claude-personal/projects/<hash>/memory/project_consolidation_arc.md` (pointer + current state).
2. Read last committed exit artifact in `studio-consolidation/`.
3. Read `studio-consolidation/parking-lot.md` if it exists.
4. Confirm scope matches this plan.
5. Proceed.

If transcript context is lost, steps 1–3 fully reconstitute state.

---

## Parallelization policy

Agents and research passes should parallelize unless they depend on each other's output.

- Session B (audit): 4 parallel audit agents (non-overlapping domains).
- Session C (research, if needed): independent questions → parallel agents.
- Session D (synthesis): single-threaded; integration cannot parallelize.
- Session G (implementation): sequential per step; but within a step, independent work parallelizes.

---

## Test strategy (to be formalized in Session D synthesis)

Captured here so it informs audit lens, not only later synthesis.

**Problem:** unit tests calcify around implementation details. Under high iteration (SDK swaps like imgly → native), test rewrites dominate cost without catching regressions.

**Layered framework by churn:**

| Layer | Churn | Test strategy |
|---|---|---|
| Core domain invariants | Low | Unit tests |
| SDK adapters / wrappers | Medium | Contract tests (shape, not impl) |
| UI / glue / view code | High | Snapshot + XCUITest + real-device smoke |
| Exploratory / prototype | Very high | Manual verification; no auto-tests |

**Proposed primitive (Session D output):** `_shared/rules/test-strategy.md`. Chanakya brief template asks "what churn layer?" and recommends test type. Achilles test modes chosen by layer, not default-to-unit. Argus does not block on "no unit test" for high-churn work; routes to contract/snapshot instead.

**Turnip photo editor specific (user's case):** characterization test (20 reference photos) before imgly→native swap; snapshot tests on editor screens; delete imgly-coupled unit tests; keep unit tests on stable core (color math, export encoders).

---

## Current state

- **Session:** A — complete at commit of this doc.
- **Next:** B (internal audit) — launching 4 parallel agents immediately after this commit.
- **Memory pointer:** `project_consolidation_arc.md`.
- **Parking lot:** none yet.

---

## Appendix: what prior revisions are being absorbed

Session D synthesis integrates all of:

1. Issue #88 current body (pass-1 Superpowers revision, Codex-has-hooks, AGENTS.md symlink, capability manifest narrowing).
2. Substrate reframe (workers-as-pilot, dispatch-\<agent\>.sh pattern, namespaced manifest, pluggable conformance harness, ADAPTER-SPEC promoted).
3. Pass-2 research findings (schema SemVer already shipped, correlation_id, tool_executed, supervisor tree deferred, RBAC deferred).
4. Skills infrastructure proposal (studio router + Tier 1/2 modes, CLAUDE.md triggers, router pattern option (a)).
5. Phase 2.5 actual-shipped state vs. ROADMAP "Planned" drift.
6. Test strategy layering (this doc §Test strategy).

No design decision from prior revisions is final until Session D synthesizes and Session E approves.
