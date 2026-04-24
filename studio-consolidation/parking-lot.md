---
name: Session D parking lot
description: Pre-arc drafts and mid-arc dimensions surfaced out-of-band. Session D synthesis reviews these once; they are inputs, not commitments.
---

# Parking lot

Per `00-plan.md` §No-cascade rule: dimensions surfaced outside the synthesis moment are parked here and reviewed exactly once at Session D. Entries are proposals — Session D decides adopt / reshape / drop.

## A — Host-agnosticism architectural principle *(drafted pre-arc, 2026-04-23)*

**Shape.** 18-line §Host-agnosticism section for `ARCHITECTURE.md`. Declares portability as a tested invariant (not aspiration), scopes the allowed portable substrate (file I/O + POSIX + single model session + read/write tools), mandates contract-first handoffs via JSON Schemas at `_shared/contracts/<kind>.schema.json`, specifies adapter shape (canonical `skills/agents/commands/`, per-host `.<host>/` dotdirs, per-host root instruction files), bars third-party runtime deps from worker paths, defines enforcement via `scripts/test-host.sh` running a canned simple-edit task against each declared host, and stages workers (Achilles + Argus together) before Chanakya.

**Provenance.** Memory entry `project_host_agnostic_workers.md` recorded "audit done, OSS research pending." The draft is the research output. Borrows from CrewAI (`output_pydantic`), AutoGen (typed message bus), Aider (`model-settings.yml`), Superpowers (POSIX + `jq` + `yq` substrate bar, seven-host adapter shape).

**Why parked, not committed.** Session D is the arc's explicit redesign moment; load-bearing principles short-circuit synthesis if committed pre-emptively. The external audit partial (`01-audit-partial-external.md`) already flagged host-coupling hotspots; Session D should decide whether the principle as drafted matches the audit's findings or wants reshaping.

**Diff location.** Stashed — see the entry named `park-A-arch-host-agnosticism` in `git stash list`.

**Session D decision needed.**
1. Adopt the principle as-is, with reshaping, or drop.
2. If adopt: does the worker-first staging match the audit's host-coupling hotspots (SessionStart hook, Argus-via-Agent-tool)?
3. `scripts/test-host.sh` enforcement — in-scope for this arc or defer to a follow-up?

---

## B — Design-time skill-invocation upgrade *(drafted pre-arc)*

**Shape.** Paired behavior change across Achilles and Argus mode packs:

*Achilles* (`achilles/modes/task.md`):
- Brief `## Required Skills` section becomes MANDATORY — invocation is acceptance criteria, missing skill ⇒ `report_state: needs_context`.
- New **Step 4.0 Design-time skill routing** runs BEFORE the first production edit. Table maps diff signals to mandatory skills (swift-architecture, swift-api-design-guidelines, swift-concurrency-pro, swiftui-pro + swiftui-view-refactor, swiftui-liquid-glass, swiftui-performance-audit, imgly-engine-expert, swift-testing-pro + swift-testing-expert, figma-to-swiftui, claude-api).
- First commit message carries a 2–4-line "Design choices" note (architecture, API-name choices, concurrency model, deviations).
- **Step 5.0 Re-invoke skills against actual diff** in self-review; each skill's verdict (clean / minor / material) recorded in debrief `## Self-Review`. `material` ⇒ fix-then-rerun, no rationalizing.

*Argus* (`argus/modes/code-quality.md`):
- New **Step 3.5 Swift design review** — mandatory on any Swift diff. Invokes swift-api-design-guidelines / swift-architecture / swift-concurrency-pro / swiftui-pro / swiftui-view-refactor / imgly-engine-expert / swift-testing-pro per diff-signal table. Findings are `FLAGS` only, never `BLOCKS` (week-1 posture).
- Reads the "Design choices" commit note; `design-drift` if claim doesn't match diff; `design-accountability-missing` if the note is absent on a diff that should have had one.
- Findings tagged `rule: design/<category>` for Chanakya inbox-sweep grouping.
- Behavior Rule 1 amended: Argus owns API-design, architecture, concurrency, SwiftUI-idiom, and IMGLY-correctness review (those are design-level and self-review has been observed missing them).

**Premise.** Self-review has systematic blind spots on architecture / API naming / concurrency / framework idioms / IMGLY teardown. Skills are the counterweight. Current flow invokes skills opportunistically; this makes invocation structural.

**Why parked, not committed.** Ask-tier change per `CLAUDE.md` §Auto-apply tiers ("Changing how agents hand off" and "what runs in the user's actual project at runtime"). Arc-relevant: agent mode-pack shape is a Session D synthesis topic, and the agents audit partial (`01-audit-partial-agents.md`) catalogs the existing mode packs — synthesis should decide whether this lives inside the mode packs or as a cross-cutting primitive.

**Diff location.** Stashed — see `park-B-skill-invocation-upgrade` in `git stash list`.

**Session D decision needed.**
1. Adopt the mandatory-skill-invocation model, with what modifications.
2. Scope: only Turnip iOS, or generalize as a cross-project Achilles primitive? (If generalized, the Swift-specific table becomes a stack-module concern — ties to the stack-module gap noted in the shared-audit partial.)
3. Token cost of Step 4.0 table in every Achilles session — R8 check; maybe extract to `_shared/primitives/design-time-skill-routing.md` referenced from the mode pack.
4. Review interaction: does Argus Step 3.5 belong in `code-quality.md` or as a new stage (`design-review`)? Two-stage Argus recently landed; adding a third stage is a sequencing decision.

---

## Rules for this file

- One entry per parked dimension. Don't stack revisions — if a parked entry evolves, update in place with a dated note.
- Synthesis (Session D) processes this file top-to-bottom, decides each entry, and removes it on decision. A lingering entry post-synthesis is a process bug.
- Entries unrelated to the arc go to GitHub issues, not here.
