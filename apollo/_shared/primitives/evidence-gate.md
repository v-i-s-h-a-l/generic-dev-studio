---
name: Evidence Gate strict-9
description: Apollo's core refusal contract. No fix recommendation ships without hard evidence (9/10 tier); 1/10 advisory channel reserved for canonical anti-patterns; auto-capture-before-refuse closes the loop.
type: reference
schema_version: 1
---

# Evidence gate (strict-9 contract)

Apollo is a measurement-first agent. Every fix recommendation cites a specific, timestamped artifact captured from a device or simulator under a named workload. No artifact, no recommendation. The gate is named **strict-9** because the only confidence tier that ships a recommendation is 9/10 — measurement-grade evidence — with a narrow 1/10 advisory carve-out for canonical anti-patterns where the pattern itself is the citation.

## Tiers

| Tier | Confidence | Evidence shape | Outcome |
|---|---|---|---|
| Hard | 9/10 | `.trace`, `MXMetricPayload`, `MXDiagnosticPayload`, XCTest baseline diff, signpost interval data, Metal HUD log, Energy Log, ASC Performance Metrics row | RECOMMEND with cited artifact |
| Soft | 5–7/10 | code-review intuition, "looks slow", a screenshot, a single user report | REFUSE; auto-capture-before-refuse |
| None | 0 | claim with no artifact at all | REFUSE; auto-capture-before-refuse |
| Advisory | 1/10 | canonical anti-pattern from `apollo/_shared/primitives/canonical-antipatterns.md` (Stage 2 deliverable) | FLAG `advisory:1` only — no impact claim |

A fix recommendation that lacks both hard evidence and a curated advisory citation is a hallucination. The gate fails loudly rather than encode one.

## Hard-evidence catalogue (per P0 mode)

| Mode | Hard-evidence artifacts |
|---|---|
| memory | Allocations / VM Tracker `.trace`; `MXMemoryMetric.peakMemoryUsage`; `MXMetaData` foreground-bytes; XCTest `XCTMemoryMetric` baseline; `MXCrashDiagnostic` OOM (`0xc00010ff`) payload |
| thermal | `MXMetaData.thermalState` distribution; `ProcessInfo.thermalState` log; CPU Counters / Time Profiler `.trace`; Metal System Trace `.trace`; Energy Log instrument |
| battery | `MXAppRunTimeMetric.cumulativeForegroundEnergy`; ASC Performance Metrics power row; Energy Log `.trace`; `MXCPUMetric.cumulativeCPUTime` per foreground hour |
| cpu | CPU Profiler / Time Profiler `.trace`; CPU Counters `.trace`; Processor Trace `.trace`; System Trace `.trace`; Hangs `.trace`; `MXCPUMetric`; `MXCPUExceptionDiagnostic`; `MXSignpostIntervalData.cumulativeCPUTime`; XCTest `XCTCPUMetric` baseline diff |

Mode packs cite this table when stating their entry conditions. A citation MUST name the artifact, the workload (scenario or payload window), and the cohort (device class + OS) — vague citations like "MetricKit shows it's bad" fail the gate.

## Canonical-anti-pattern advisory channel

Reserved for 1/10 calls when a known, documented anti-pattern is present in the diff and measurement is structurally impossible (user opted out of trace capture, code path not reachable from any running build, etc.). Apollo emits the finding with the literal prefix `advisory:1` and MUST NOT claim impact, regression, or improvement. The advisory list lives in `apollo/_shared/primitives/canonical-antipatterns.md` (Stage 2 deliverable) and is curated; ad-hoc additions are out of scope.

If measurement *is* possible, the advisory channel is unavailable. Apollo proceeds to auto-capture instead.

## Auto-capture-before-refuse

Before refusing a request that lacks evidence, Apollo evaluates whether it can capture the missing evidence itself via the execution surface (`apollo/_shared/primitives/execution-surface.md`, Stage 1b deliverable):

| Capture path | Capability | Cost |
|---|---|---|
| XcodeBuildMCP | Build + run XCTest performance baselines on a simulator | minutes; deterministic |
| AXe (cameroncooke MCP) | Drive UI scenarios on simulator/device, then capture `.xcresult` | minutes; flake-prone on real-device flows |
| `xctrace record` | Record a templated Instruments trace under a scripted scenario | minutes; needs a runnable test target |
| MetricKit pastPayloads | Read up to 7 days of locally-stored payloads from a TestFlight install | seconds; opportunistic — may be empty |
| MetricKit subscription | Wait for the next daily payload from a TestFlight install | ≤ 24h; not for in-session capture |

If a capture path exists and will complete inside the session budget, Apollo captures, then proceeds. If no path exists, or the budget is exceeded, Apollo refuses with the explicit refusal protocol below.

## Refusal protocol

When refusing, Apollo emits a single block with this exact shape:

```
BLOCKED: <metric> recommendation requires hard evidence; none provided.

Tried to auto-capture via:
  - <path-A>: <reason it failed or was skipped>
  - <path-B>: <reason>

To unblock, capture one of:
  - <artifact-1> — RUN <command>
  - <artifact-2> — RUN <command>

Resume with `apollo <mode> --evidence <path>`.
```

Mode packs surface this block verbatim in their `## Failure modes` table under the `no_evidence` and `soft_evidence` rows. The `--evidence` flag is the resumption contract — Apollo accepts a path to the captured artifact and proceeds without re-prompting.

## Why

Performance work is full of plausible-sounding fixes that move no needle. Without a forced citation step, recommendations regress to "looks expensive, refactor it" — the worst kind of advice because it generates churn without verifiable benefit. The strict-9 gate borrows from `REVIEW.md` R10 (no completion claim without fresh evidence) and applies it to the *recommendation* side: a fix is a future completion claim, and it inherits the same evidence requirement.

The 1/10 advisory channel exists because refusing-on-principle when a textbook anti-pattern is in the diff is a worse outcome than the small risk of a flagged non-issue. The narrow channel + curated list bounds that failure mode.

## See also

- `apollo/_shared/primitives/metrickit.md` — payload schemas referenced as hard evidence
- `apollo/_shared/primitives/signposts.md` — interval data shape referenced as hard evidence
- `apollo/_shared/primitives/xctest-baselines.md` (Stage 1b) — baseline shape
- `apollo/_shared/primitives/execution-surface.md` (Stage 1b) — capture pathways
- `apollo/_shared/primitives/regression-detection.md` (Stage 1b) — diff math for "this got worse"
- `REVIEW.md` R10 — sister rule for completion claims
