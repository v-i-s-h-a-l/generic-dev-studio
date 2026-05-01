---
name: Apollo signpost assistant
description: Scenario-driven signpost planning for Apollo. Produces OSSignposter interval/event plans, privacy guidance, patch-ready brief seeds, and missing-signpost refusal policy.
type: reference
schema_version: 1
---

# Apollo signpost assistant

The signpost assistant runs before capture when a scenario has weak or missing points of interest. It reads `apollo/_shared/primitives/scenarios.md`, writes a signpost plan, and lets Apollo block before producing an unusable trace.

Validate plans with:

```bash
scripts/validate-contract.sh apollo-signpost-plan <plan.yaml>
```

## Mode patterns

| Mode | Preferred interval | Useful events | Metadata guidance |
|---|---|---|---|
| memory | The allocation-heavy user flow, e.g. `PhotoExport` or `FeedOpen` | Cache flush, image decode start/end, memory warning | Public numeric sizes only: bytes, item counts, dimensions. No filenames or user text. |
| cpu | The hot interaction or compute window, e.g. `FeedScroll`, `ExportEncode` | QoS/task entry, algorithm phase, retry boundary | Public counters: item count, frame index, batch size. No content labels. |
| thermal | Sustained workload dwell, e.g. `CanvasRenderDwell` | `thermalState` transition, shed action | Thermal state and FPS cap are public; user/session identifiers stay private. |
| battery | Foreground or background energy window, e.g. `BackgroundSync` | Lifecycle transition, radio wake, background task start/end | Public counts and durations only; URLs, channels, and account ids stay private. |

## Patch-ready brief seed

When a required signpost is absent, Apollo emits a brief seed instead of recommending a performance fix:

```yaml
dispatch_agent: achilles
kind: impl
title: Add Apollo signposts for <scenario-id>
body:
  goal: Add OSSignposter points of interest required by Apollo scenario <scenario-id>.
  acceptance:
    - Required intervals from the signpost plan are emitted in Release builds.
    - Public metadata keys match the plan and contain no user data.
    - A trace for the scenario shows the expected interval/event names.
evidence:
  artifacts:
    - ~/.dev-studio/<project>/apollo/scenarios/<scenario-id>.yaml
    - ~/.dev-studio/<project>/apollo/signpost-plans/<plan-id>.yaml
```

## Missing-signpost policy

| Situation | Apollo behavior |
|---|---|
| Scenario declares required signposts that are absent before capture | `block-before-capture`; emit the brief seed above |
| Capture finishes but a required signpost is missing | `retry-once` with corrected scenario/instrumentation; second miss emits `apollo_refused` with `reason: signpost_missing` |
| Signpost would expose private data | Replace payload with public count/category, or mark metadata private and do not use it for MetricKit aggregation |
| User cannot add instrumentation | Downgrade to `advisory-only`; no strict-9 recommendation can cite the missing interval |

## Procedure

1. **READ** the Apollo scenario.
   Before: scenario is validated by `_shared/contracts/apollo-scenario.schema.json`.
   After: flow steps, metric targets, and expected artifacts are known.

2. **WRITE** a signpost plan.
   Before: scenario metric targets are known.
   After: each required interval/event has placement, privacy, and acceptance text.

3. **CHECK** captured artifacts for expected signposts.
   Before: trace, MetricKit payload, or `.xcresult` exists.
   After: Apollo proceeds, retries once, or refuses with `reason: signpost_missing`.

## See also

- `_shared/contracts/apollo-signpost-plan.schema.json`
- `apollo/_shared/primitives/signposts.md`
- `apollo/_shared/primitives/scenarios.md`
- `apollo/_shared/primitives/evidence-gate.md`
