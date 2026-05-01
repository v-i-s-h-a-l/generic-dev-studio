---
name: imgly-metal-delegation-contract
description: Apollo to imgly-engine-expert handoff for Metal / Imgly archetypes. Detection protocol, retained Metal evidence, input/output envelope, and the authority matrix.
type: reference
schema_version: 1
---

# Imgly / Metal touchpoint + delegation contract

Apollo is metric-first and project-agnostic. When a thermal / battery / memory recommendation lands inside an Imgly (CE.SDK) or raw Metal pipeline, Apollo does not propose the in-tree change — it hands off to the host-resolved `imgly-engine-expert` skill. This file is the contract that makes that handoff structured rather than free-text.

The boundary is load-bearing: Apollo retains measurement and verification authority; Imgly internals stay in the receiving skill. Without this contract Apollo would either (a) refuse every Metal-rooted regression, or (b) leak Imgly-specific knowledge into mode packs and re-grow into the project. Both are failure modes; this file prevents both.

## Receiving skill

`imgly-engine-expert` is a machine-local or project-local skill resolved from the current host's skill directories; it is not shipped as a studio-owned repo skill. It owns the CE.SDK API surface, block-management patterns, scope system, and the project's Imgly playbook. Apollo never reads its internals — only its name (for the `delegate:` line on a recommendation) and its handoff envelope (defined below).

If the current host cannot resolve the skill from global or project-local skill directories, Apollo cannot delegate; the recommendation refuses with the standard refusal block (`apollo/_shared/primitives/evidence-gate.md` § Refusal protocol) and names "no Imgly delegation surface available" as the unblock.

## Detection — when does Apollo decide a project uses Imgly / Metal?

Apollo's decision is **conservative**: confirm presence, never infer absence. The first match wins; absence of all four signals routes the recommendation through the standard archetype tables, not the Imgly carve-out.

| Signal | Source | Strength |
|---|---|---|
| `imgly-engine-expert` skill present in the host global skill directory or at project-local `.claude/skills/imgly-engine-expert/SKILL.md` | filesystem (host + project roots) | strong — confirms the receiving surface exists |
| Cited stack contains `IMGLYEngine`, `IMGLY*`, `Engine.block.*`, or symbols matching the EngineManipulator file map | `.trace` cpu-profile / call-stack / `MXCallStackTree` | strong — confirms Imgly is on the hot path |
| Cited stack contains `MTKView.draw`, `CADisplayLink`, `MTLCommandBuffer`, `MTLRenderCommandEncoder` frames | `.trace` cpu-profile / Metal System Trace command-buffer rows | medium — confirms raw Metal, may or may not be Imgly-owned |
| Diff target file path matches editor engine wrapper, scene graph, render pipeline, or any path where private project guidance claims IMGLY ownership | git diff path | strong — confirms the change site is in Imgly territory |

Single-signal matches are sufficient — these are independent evidence channels, not a quorum. Apollo does not "guess" Imgly involvement from feel: a Metal System Trace with no Imgly symbols and a non-Imgly diff path is plain Metal, not Imgly, and the delegation envelope still applies (the receiving skill is the right consumer for raw Metal in projects that vendor it).

## Metal evidence Apollo retains

Apollo measures; the receiving skill recommends. Apollo's evidence-gathering surface for GPU / Metal regressions is unchanged by this contract — listed here as a single reference for mode packs that need to point at it:

| Artifact | Captured via | Cited in |
|---|---|---|
| Metal Performance HUD log | `MTL_HUD_ENABLED=1` env var at launch, log exported via XcodeBuildMCP | `apollo/modes/thermal.md` § Phase 1 capture, `apollo/modes/battery.md` § Phase 1 capture |
| Metal System Trace `.trace` | `xctrace record --template "Metal System Trace" --device <udid> --launch -- <bundle> --time-limit <s>` | `apollo/_shared/primitives/instruments-index.md` thermal / scroll rows |
| Command-buffer signpost intervals | framework-emitted `OSSignposter` boundaries on `MTLCommandBuffer`; pair with scenario signposts via the routing in `apollo/_shared/primitives/signposts.md` | `apollo/modes/thermal.md` GPU-rooted row |
| `MXGPUMetric.cumulativeGPUTime` | MetricKit subscription / `pastPayloads` — see `apollo/_shared/primitives/metrickit.md` | `apollo/modes/thermal.md`, `apollo/modes/battery.md` |
| GPU subsystem watts | Power Profiler subsystem row — see `apollo/_shared/primitives/instruments-index.md` battery rows | `apollo/modes/battery.md` § Phase 3 archetypes |

This table is a pointer surface, not a re-statement. The capture commands and citation shapes live in their primary primitives — `instruments-index.md`, `metrickit.md`, `signposts.md`, `execution-surface.md`. Apollo never expands this list into a Metal tutorial; that is the receiving skill's surface.

## Handoff envelope

A delegated recommendation is a structured handoff, not a free-text ask. Apollo writes the envelope into the recommendation artifact (`~/.dev-studio/<project>/apollo/recommendations/<id>.md`) with two named blocks: `apollo_to_expert` (input) and `expert_to_apollo` (output, filled by the receiving skill). The receiving skill is invoked with the input block as its sole context; Apollo does not narrate around it.

### `apollo_to_expert` (Apollo → expert)

```yaml
apollo_to_expert:
  recommendation_id: <ulid>             # links to apollo/recommendations/<id>.md
  metric: <memory | thermal | battery | cpu>  # which mode authored the handoff
  scenario: <scenario-name>             # the scripted workload bracketed by signposts
  signpost_window:
    name: <OSSignposter interval name>
    p50_ms: <number>
    p95_ms: <number>
    sample_n: <number>                  # ≥ regression-detection.md sample-size minimum
  cited_artifacts:
    - shape: <trace | xcresult | mxmetric | hud-log | asc-row>
      path: <abs path under ~/.dev-studio/<project>/apollo/captures/>
      template: <Allocations | "Metal System Trace" | "Power Profiler" | …>   # when shape=trace
  cohort:
    model_code: <e.g. iPhone16,2>
    os_major: <e.g. 19>
  diff_target:
    file: <repo-relative path, optional — empty when authored from MetricKit-only signal>
    symbol: <function or block, optional>
  advisory_id: <e.g. therm:06 | mem:04>  # optional; present when handoff is rooted in canonical-antipatterns.md
  detection_signals:                    # which of the four signals from § Detection fired
    - skill_present: <true | false>
    - imgly_symbols_in_stack: <true | false>
    - metal_symbols_in_stack: <true | false>
    - diff_in_imgly_path: <true | false>
```

Apollo MUST fill every required field. Missing scenario / signpost_window / cohort fails the strict-9 gate — the handoff is the recommendation, and the recommendation inherits the gate.

### `expert_to_apollo` (expert → Apollo)

```yaml
expert_to_apollo:
  recommendation_id: <ulid>             # echoes the input
  archetype_id: <expert-defined>        # e.g. imgly:cmdbuf-reuse, imgly:scope-toggle, metal:scissor
  recommendation: <≤ 3 sentence summary of the proposed change>
  diff_target:                          # may differ from Apollo's input — receiving skill may relocate
    file: <repo-relative path>
    symbol: <function or block>
  scope_estimate: <small | medium | large>   # routes Achilles' brief shape
  verification_plan:
    artifact: <trace | xcresult | mxmetric | hud-log | asc-row>
    template: <Instruments template name when artifact=trace>
    scenario: <scenario-name — reuses Apollo's, or names a new one>
    expected_delta: <metric> p<percentile> -<X>% cohort <model_code>/<os_major>
  rejected_alternatives: <optional, free-text list of considered-and-discarded approaches>
```

Apollo applies strict-9 to `verification_plan` before accepting the recommendation. A `verification_plan` whose artifact isn't in the hard-evidence catalogue (`apollo/_shared/primitives/evidence-gate.md` § Hard-evidence catalogue) is rejected and the handoff round-trips with a refusal note. A plan whose `expected_delta` lacks percentile / cohort fails the same way.

The accepted recommendation flows downstream as a normal Apollo recommendation artifact: Achilles consumes the brief seed, Argus reviews, and the post-fix capture closes the loop per `REVIEW.md` R10. The `delegate: imgly-engine-expert` line on the recommendation is the audit trail — review tooling reads it to know the in-tree change came from the receiving skill.

## Retained vs delegated authority

| Concern | Apollo retains | Delegated to `imgly-engine-expert` |
|---|---|---|
| Evidence capture (`xctrace`, MetricKit, ASC, HUD log) | ✓ | — |
| Strict-9 evidence-gate enforcement | ✓ | — |
| Cohort + scenario + signpost framing | ✓ | — |
| Decision: is there a regression? (`regression-detection.md`) | ✓ | — |
| Decision: which Imgly / Metal change addresses it | — | ✓ |
| CE.SDK API surface, block-management, scope system | — | ✓ |
| Project-specific playbook (private file maps, local architecture notes, project-local overrides, etc.) | — | ✓ |
| Verification-plan acceptance (must hit strict-9) | ✓ | — |
| Post-fix capture under matched scenario / cohort | ✓ | — |
| Final accept / refuse on the recommendation | ✓ | — |

Two invariants make this stable: (1) Apollo is the only authority that touches the strict-9 gate — the receiving skill's `verification_plan` is *proposed*, Apollo accepts or rejects it; (2) the receiving skill is the only authority on Imgly internals — Apollo neither inlines its archetypes nor second-guesses them on Imgly grounds (Apollo can reject on evidence grounds — that is different).

## Project-specific Imgly playbook

A private project-local override may carry a project-specific archetype catalogue. That catalogue is **explicitly out of scope for Apollo**. Apollo does not read it, does not link to it from any mode pack, and does not reproduce any of it here. The whole point of this contract is that Apollo can be transplanted to a project whose Imgly skill has a different catalogue, and the contract still works.

## Why

Performance recommendations that touch a render pipeline have two failure modes Apollo must avoid:

1. **Vague Metal advice** — "reduce fragment work" / "coalesce command buffers" is a non-fix on its own. The pipeline owner needs to know *which* shader, *which* buffers, *which* draw calls. Apollo doesn't know Imgly; the receiving skill does.
2. **Imgly leakage into Apollo** — once Apollo learns one project's CE.SDK pattern, the Stage-2 mode packs grow project-specific archetypes, and Apollo stops being transplantable. The strict-9 gate then ratchets up Imgly-flavored "evidence" that doesn't generalize.

A structured envelope solves both: Apollo measures, the receiving skill recommends, Apollo verifies, and neither agent grows into the other's territory. The contract is small on purpose — every field the envelope adds is a future place to leak.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract; the gate this handoff inherits
- `apollo/_shared/primitives/instruments-index.md` — Metal System Trace + GPU template details + capture commands
- `apollo/_shared/primitives/canonical-antipatterns.md` — `therm:06`, `mem:04`, `mem:05` advisory rows that route here when measurement is impossible
- `apollo/_shared/primitives/regression-detection.md` — sample-size minimums + cohort normalization for the `signpost_window` block
- `apollo/_shared/primitives/execution-surface.md` — XcodeBuildMCP / `xctrace` invocation paths Apollo uses to capture HUD log + Metal System Trace
- `apollo/modes/thermal.md` § Phase 3 archetypes — GPU-rooted rows that delegate via this contract
- `apollo/modes/battery.md` § Phase 3 archetypes — render-pipeline energy rows that delegate via this contract
- `apollo/modes/memory.md` § Phase 3 archetypes — IOKit / `MTLTexture` rows that delegate via this contract
- Tech Talk 110339 — Metal Performance HUD
- WWDC22 10106 — Profile and optimize your game's memory
- Apple — *Metal Performance Best Practices*; *Reducing the memory footprint of Metal apps*
