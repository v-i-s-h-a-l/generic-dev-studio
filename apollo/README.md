# Apollo — Performance Agent

A dedicated iOS performance agent that **diagnoses, fixes, and verifies one performance metric at a time** under a strict-9 evidence gate. Apollo composes with the existing topology — Chanakya dispatches, Achilles applies, Argus reviews — and never replaces them.

Greek god of medicine + the Apollo program: healing + measurement + precision.

> **Status.** Memory, thermal, battery, CPU, network, profile, and measure mode packs are tracked in the router. Apollo refuses recommendations without strict-9 evidence and runs in degraded analysis-only mode on hosts without capture tooling.

---

## What makes Apollo different

| Concern | Existing agent | Apollo |
|---|---|---|
| Evidence shape | code review intuition, test failures, lints | `.trace`, `MXMetricPayload`, XCTest baseline, signpost data, Energy Log, ASC Performance Metrics |
| Refusal posture | block on hard rule violation | refuse on missing evidence; auto-capture before refusing |
| Cadence | per-task (synchronous with brief lifecycle) | retroactive on shipped code; subscription to MetricKit payloads; baseline diffs across releases |
| Ownership of fixes | Achilles applies | Achilles applies; Apollo measures + verifies |

Performance work is orthogonal to feature work. Bolting it onto Argus would bloat the reviewer; folding into Achilles would dilute the worker. A dedicated agent with per-metric mode packs matches the lean architecture cleanly.

## P0 modes

| Mode | Owns | Hard-evidence catalogue |
|---|---|---|
| `memory` | leak detection, OOM diagnosis, peak / sustained footprint | Allocations / VM Tracker `.trace`, `MXMemoryMetric`, `XCTMemoryMetric` baseline, `MXCrashDiagnostic` OOM payload |
| `thermal` | thermal throttling, sustained CPU, GPU heat | `MXMetaData.thermalState` distribution, CPU Counters / Time Profiler `.trace`, Metal System Trace, Energy Log |
| `battery` | foreground energy, cumulative CPU per hour, drain regressions | `MXAppRunTimeMetric`, ASC Performance Metrics power row, Energy Log, `MXCPUMetric` |
| `cpu` | foreground CPU spikes, hot paths, main-thread saturation, CPU diagnostics | CPU Profiler / Time Profiler `.trace`, CPU Counters, Processor Trace, System Trace, `MXCPUMetric`, `MXCPUExceptionDiagnostic`, `XCTCPUMetric` |
| `network` | request latency, retry churn, over-fetch, cache miss, connection reuse, transfer regressions | Network / HTTP Traffic `.trace`, `URLSessionTaskMetrics`, `MXNetworkTransferMetric`, `MXCellularConditionMetric`, ASC rows |
| `profile` | guided real-device profiling session; orchestrates scenario, signposts, capture, attribution, and verification | Delegates evidence to memory / CPU / thermal / battery / network modes |

Phase 2 modes (launch-time, scroll-perf, binary-size) are deferred. Each mode is a single mode pack at `apollo/modes/<name>.md`; the dispatch table in `apollo/SKILL.md` is the single source of truth for triggers.

## The strict-9 evidence gate

Apollo's core refusal contract: **no fix recommendation without hard evidence**. The full contract lives at `apollo/_shared/primitives/evidence-gate.md`. The short version:

| Tier | Confidence | Evidence shape | Outcome |
|---|---|---|---|
| Hard | 9/10 | named artifact + workload + cohort | RECOMMEND |
| Soft | 5–7/10 | "looks slow", screenshot, single user report | REFUSE; auto-capture-before-refuse |
| None | 0 | claim with no artifact | REFUSE; auto-capture-before-refuse |
| Advisory | 1/10 | curated canonical anti-pattern | FLAG `advisory:1` only — no impact claim |

Auto-capture-before-refuse: when a capture path exists in the execution surface (`apollo/_shared/primitives/execution-surface.md`) and fits the session budget, Apollo captures the missing artifact itself rather than refusing. Refusal is reserved for the cases where no capture path exists or the budget is exceeded.

## Execution surface

The bounded set of tools Apollo can invoke autonomously, declared in `apollo/_shared/primitives/execution-surface.md`:

- **XcodeBuildMCP** — build / test / archive on simulator + device, XCTest with `.xcresult` capture
- **AXe** (cameroncooke MCP) — UI scenario automation on simulator + paired device
- **XCResultKit** (AvdLee) — `.xcresult` parsing
- **xctrace** — Instruments trace recording + export
- **ChimeHQ/Meter** — MetricKit payload parsing + symbolication
- **ASC API client** — Performance / Power Metrics, Analytics Reports

Tools not listed are not in Apollo's autonomous set. Adding one requires a primitive update, not an inline opt-in. Host capabilities are declared in `~/.dev-studio/.runtime/host-capabilities.yaml`; Apollo refuses fast at boot when a depended-on tool is `installed: false`.

## How a mode runs (preview)

```
You:      /apollo memory
You:      The 3.4.0 build is OOMing on iPhone 12 / iOS 18 during photo export.

Apollo:   [walks evidence-gate decision tree]
          [checks for cited artifacts — none provided]
          [evaluates auto-capture paths]
          [picks Allocations + VM Tracker via xctrace under a scripted export scenario]

Apollo:   captured 3.4.0-baseline.trace via xctrace under scenario `export-30s`,
          cohort iPhone 12 / iOS 18.6 (15-min budget; finished in 8m 22s).
          peak resident memory 1.42 GB; OOM threshold ~1.4 GB on this class.
          regression vs. 3.3.2 baseline: +312 MB peak (cited:
          baselines/memory.json#3.3.2-export-30s).

          Recommendation: <fix> — cited
          captures/2026-04-26-export-30s.trace + baselines/memory.json#3.3.2-...

You:      Apply it.
[Achilles takes over — Apollo doesn't write source code]
```

That second-to-last step is the whole point. Apollo never says "looks slow, refactor it." Every recommendation cites an artifact + workload + cohort, and every refusal names the path that would have unblocked it.

## Apollo and the existing agents

| Boundary | Rule |
|---|---|
| Apollo ↔ Achilles | Apollo measures + recommends; Achilles applies. Apollo never writes source files in the worktree. |
| Apollo ↔ Argus | Argus reviews diffs; Apollo verifies the post-fix metric. A recommendation that lands as a PR loops through Argus normally; Apollo's verification is a follow-on capture. |
| Apollo ↔ Chanakya | Chanakya dispatches Apollo on a perf brief or a user-triggered investigation. Apollo's findings flow back through the event log; Chanakya files follow-up tasks for the recommended fix. |
| Apollo ↔ imgly-engine-expert | Apollo retains measurement + verification authority. Imgly/Metal-specific knowledge routes to the existing `imgly-engine-expert` skill via the delegation contract at [`_shared/integrations/imgly-and-metal.md`](_shared/integrations/imgly-and-metal.md). |

Stage 5 (#235) wires Chanakya dispatch + Argus interaction policy. Until then, Apollo is invoked directly by the user.

## Roadmap

The full stage map lives on issue [#236 (epic)](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/236).

| Stage | Issue | Deliverable | Status |
|---|---|---|---|
| 1a | [#228](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/228) | Foundational primitives (evidence-gate, MetricKit, signposts) | shipped |
| 1b | [#229](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/229) | Tooling primitives (XCTest, Instruments, ASC, regression, execution-surface) | shipped |
| 2a | [#230](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/230) | `memory` mode pack | next |
| 2b | [#231](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/231) | `thermal` mode pack | unblocked |
| 2c | [#232](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/232) | `battery` mode pack | unblocked |
| 3 | [#233](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/233) | Imgly/Metal touchpoint + delegation contract | shipped |
| 4 | [#234](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/234) | SKILL.md + routing.yaml + scaffold | **this PR** |
| 5 | [#235](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/235) | Chanakya dispatch + Argus interaction policy | blocked on 4 + ≥1 mode |

## When to use Apollo (preview)

| Situation | Use |
|---|---|
| A specific metric regressed between releases | `/apollo <metric>` with the regression cited |
| TestFlight build is shipping `MXCrashDiagnostic` payloads | `/apollo memory` (OOM) or `/apollo thermal` (heat) |
| Reviewer suspects a perf hit but has no artifact | `/apollo <metric>` — auto-capture pathway runs |
| Generic "the app feels slow" complaint | Apollo refuses without a metric chosen; pick `memory`, `thermal`, `battery`, `cpu`, or `network` first |

Apollo refuses cross-metric guesses on purpose. The evidence catalogue diverges per mode; "the app feels slow" without a metric chosen has no decidable artifact target.

## File system (preview)

```
apollo/
  SKILL.md                   # router (this stage)
  routing.yaml               # slash-command surface
  portability.yaml           # host portability declaration
  agents/openai.yaml         # Codex adapter interface
  README.md                  # this file
  docs.html                  # quick-reference page
  modes/                     # mode packs (Stage 2 deliverables)
    memory.md                # #230
    thermal.md               # #231
    battery.md               # #232
    cpu.md                   # #406
    network.md               # #424
    profile.md               # #410
  _shared/primitives/        # cross-cutting primitives
    evidence-gate.md         # strict-9 contract
    execution-surface.md     # capability matrix
    metrickit.md
    signposts.md
    xctest-baselines.md
    instruments-index.md
    organizer-asc.md
    regression-detection.md

~/.dev-studio/<project>/apollo/
  captures/<id>/             # captured artifacts (.trace, .xcresult, MetricKit JSON)
  baselines/<metric>.json    # XCTest performance baselines per metric
  deferred/<id>.yaml         # deferred-capture rows; drained by scheduled sweep
  recommendations/<id>.md    # recommendation artifact (cited evidence + proposed fix)
```

## See also

- `apollo/SKILL.md` — router + dispatch table.
- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract.
- `apollo/_shared/primitives/execution-surface.md` — autonomous tool inventory.
- `apollo/docs.html` — quick-reference card.
- `chanakya/README.md` / `achilles/README.md` / `argus/README.md` — sister agents.
- `REVIEW.md` R10 — sister rule for completion claims.
