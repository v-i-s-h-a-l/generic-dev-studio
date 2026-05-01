---
name: Apollo mode-pack scaffold
description: Cross-mode framing for Apollo P0 packs — 5-phase pipeline, Phase 4 handoff, Phase 5 state machine, steps 5–8 boilerplate. Mode packs cite this and inline only mode-specific deltas.
type: reference
schema_version: 1
---

# Apollo P0 mode-pack scaffold

Every Apollo P0 mode pack (memory, thermal, battery, cpu, future P0 / P1 modes) follows the same five-phase pipeline under the strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`):

```
Phase 1 — Diagnose       classify the signal
Phase 2 — Measure        produce the cited artifact
Phase 3 — Propose        emit a recommendation OR refuse
Phase 4 — Patch          hand off to Achilles
Phase 5 — Re-measure     verify on the post-fix capture
```

Phases 1–3 are mode-specific: each pack defines its own signal taxonomy, hard-evidence catalogue, capture recipes, recommendation shape, and archetype table. Phases 4 and 5 share a procedure, a contract, and a state machine; this primitive owns that scaffolding so individual mode packs only carry their deltas.

## Phase 4 — Patch (handoff contract)

Apollo never patches in-process. Phase 4 hands the recommendation to Achilles via a recommendation artifact and a brief seed Chanakya consumes.

Handoff surface:
- recommendation artifact: `~/.dev-studio/<project>/apollo/recommendations/<id>.md`
- brief seed: emitted on the studio path Chanakya turns into a task
- patch owner: `achilles` (always — Apollo never patches in-process)

Brief seed YAML — base shape every P0 mode emits:

```yaml
mode: <memory|thermal|battery|...>
class: <signal-class>
recommendation_id: <ulid>
patch_owner: achilles
brief_kind: impl
diff_target: <file:line | symbol>
expected_delta: <metric> p<percentile> -<X>% cohort <modelCode>/<osMajor>
verification_recipe: <command>
evidence:
  - <artifact-path>
  - <signpost-name>
  - cohort: <modelCode>/<osMajor>
  - build: <version>
```

Modes extend the `evidence:` list with mode-specific axes (e.g. thermal adds `dwell_seconds`; battery adds `track` plus `dwell_seconds` or `field_window_days`). The base fields are mandatory across every mode.

R17 ownership is the load-bearing invariant: Apollo writes only under `~/.dev-studio/<project>/apollo/`. The mode pack never reaches `briefs/`, `debriefs/`, the worktree, or task YAML. Achilles owns the patch on a worktree per its standard flow; Argus reviews per its standard flow; Chanakya routes the brief seed. Apollo never invokes Achilles directly.

## Phase 5 — Re-measure (outcome state machine)

Phase 5 confirms the regression resolved by re-capturing the same artifact shape under the same scenario on the patched build, then running the regression-detection math (`apollo/_shared/primitives/regression-detection.md §Decision rule`).

Three terminal states. Each is emitted as a follow-up event paired with the original `apollo_recommendation` id so the dashboard correlates pre-fix and post-fix outcomes per cohort.

| Outcome | Criterion | Action |
|---|---|---|
| Verified | Post-fix capture's metric crosses the `expected_delta` threshold AND the regression-detection decision returns `confirmed regression resolved` (significance test passes, sample sizes met, mode-specific match axes exact) | Emit `apollo_recommendation` follow-up with `status: verified`; persist post-fix artifact alongside pre-fix |
| Partial | Post-fix capture moves the metric in the right direction but below the threshold or fails significance | Emit follow-up with `status: partial`; recommendation remains open; mode pack names what additional evidence would close it |
| Regressed | Post-fix capture moves the metric the wrong direction, or a sibling metric (cross-mode coupling) regressed | Emit follow-up with `status: regressed`; recommendation rolled back; new Phase-1 diagnose opens with the post-fix capture as input |

**Match axes.** Every mode pins a tuple of axes that must exactly match between pre-fix and post-fix captures. The base tuple — mandatory for every mode — is `cohort + scenario + signpost + build`. Modes extend it: thermal adds `dwell`; battery adds `track` plus `dwell_or_field_window`. Mode packs name their tuple in §Cohort and noise control.

Apollo refuses any "resolved" claim that lacks a paired post-fix artifact. The pre-fix artifact stays retained — it is the audit trail.

## Procedure boilerplate (steps 5–8)

Every P0 mode pack closes its `## Procedure` section with these four steps. Mode packs may inline them verbatim or reference this primitive; the only legitimate deltas are the mode-specific match axes named in step 7 and the field-window minimums named in step 8.

5. **WRITE** the recommendation artifact at `apollo/recommendations/<id>.md` with the field set from the mode pack's §Phase 3.
   Before: gate=hard from step 4; archetype selected from §Phase 3 archetype table; Metal-archetype recommendations delegated to `imgly-engine-expert` per `apollo/_shared/integrations/imgly-and-metal.md`.
   After: `apollo_recommendation` event emitted; brief seed YAML written for Chanakya consumption per §Phase 4.

6. **RECORD** the handoff to Achilles per §Phase 4; Apollo does NOT mutate the worktree, briefs, or task YAML.
   Before: recommendation artifact written from step 5.
   After: brief seed available on the studio path; R17 ownership preserved (no writes outside `apollo/`); event log carries the recommendation id for cross-agent correlation.

7. **RUN** the post-fix capture matching the pre-fix capture on the mode's match-axes tuple (base: cohort + scenario + signpost + build; mode-specific extensions added per the mode pack's §Phase 5).
   Before: Achilles task closed; Argus verdict approved; merge SHA recorded on the recommendation; the verification recipe from step 5 is reproducible.
   After: post-fix artifact persisted at `apollo/captures/<id>/post-fix/`; match axes verified per `apollo/_shared/primitives/regression-detection.md §Cohort normalization`.

8. **EMIT** the verification verdict per §Phase 5 outcome table using `apollo/_shared/primitives/regression-detection.md §Decision rule`.
   Before: pre-fix and post-fix artifacts match-axis matched; sample-size minimums met for the cited percentile; mode-specific field-window minimums met when the claim cites field aggregates.
   After: follow-up `apollo_recommendation` event with `status: <outcome>` emitted; pre-fix and post-fix artifacts both retained; on `regressed` outcome a fresh Phase-1 diagnose opens with the post-fix capture as input.

Steps 1–4 (input parsing, evidence catalogue check, capture recipe execution, gate evaluation) are mode-specific and live inline in each mode pack.

## Ownership split

| Section | Owner |
|---|---|
| Five-phase pipeline framing | this primitive |
| Phase 4 patch handoff contract + base brief-seed YAML + R17 ownership | this primitive |
| Phase 5 outcome state machine (verified / partial / regressed) | this primitive |
| Procedure boilerplate steps 5–8 | this primitive |
| Signal classes (taxonomy table) | mode pack |
| Hard-evidence catalogue rows | mode pack |
| Capture recipes + counter routing | mode pack |
| Recommendation shape (`RECOMMEND (<mode>:<class>)` block + extra YAML fields) | mode pack |
| Archetype table | mode pack |
| Cohort and noise control rules + match-axes tuple | mode pack |
| Verification artifact requirements (per-claim) | mode pack |
| Failure modes table | mode pack |
| Procedure steps 1–4 | mode pack |
| Handoffs and Singleton sections | mode pack |

## Why this shape

The five phases map directly onto strict-9: diagnose names the signal, measure produces the artifact, propose checks the artifact against the gate, patch hands off to Achilles, re-measure verifies. Each phase has exactly one gate and one refusal path.

Graduating the shared scaffolding to this primitive resolves three problems:

1. **Lint fence.** `scripts/lint-architecture.sh §check_dup_prose` fingerprints 10-line prose windows across every mode pack; phases 4 and 5 used to trip it because their content is structurally identical by design. Paraphrasing on every new mode pack was busywork that pushed packs apart for prose-uniqueness rather than for content.
2. **Drift surface.** Three (and counting) places to update the brief seed shape, the R17 reminder, the outcome table. Centralizing keeps them aligned by construction.
3. **Author cost.** New mode packs cite this primitive and supply only their deltas instead of recopying the full 5-phase scaffold.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract these phases gate into
- `apollo/_shared/primitives/regression-detection.md` — Phase 5 decision rule + cohort normalization
- `apollo/_shared/primitives/execution-surface.md` — auto-capture-before-refuse decision tree feeding step 3
- `apollo/_shared/integrations/imgly-and-metal.md` — Metal/Imgly delegation contract referenced in step 5
- `apollo/modes/memory.md` / `apollo/modes/thermal.md` / `apollo/modes/battery.md` / `apollo/modes/cpu.md` — P0 mode packs implementing this scaffold
- `_shared/contracts/events.md` — `apollo_capture_*` and `apollo_recommendation` event schemas
- `REVIEW.md` R10 / R17 — sister rules referenced in the verification and handoff contracts
