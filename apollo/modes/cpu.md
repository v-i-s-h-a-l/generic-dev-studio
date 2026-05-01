---
name: Apollo CPU mode
description: Diagnose -> measure -> attribute -> recommend -> verify protocol for CPU regressions under strict-9 evidence gating. Covers hot paths, main-thread saturation, off-CPU waits, and field CPU diagnostics.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 7000
session_budget: 900s
locks:
  - simulator-{udid}
  - xctrace-{device}
  - real-device-{udid}
emits:
  - apollo_capture_started
  - apollo_capture_completed
  - apollo_capture_deferred
  - apollo_recommendation
  - apollo_refused
  - apollo_advisory
reads:
  - apollo/_shared/primitives/source-map.md
  - apollo/_shared/primitives/evidence-gate.md
  - apollo/_shared/primitives/instruments-index.md
  - apollo/_shared/primitives/metrickit.md
  - apollo/_shared/primitives/signposts.md
  - apollo/_shared/primitives/xctest-baselines.md
  - apollo/_shared/integrations/imgly-and-metal.md
  - ~/.dev-studio/.runtime/host-capabilities.yaml
writes:
  - ~/.dev-studio/<project>/apollo/captures/<id>/**
  - ~/.dev-studio/<project>/apollo/recommendations/<id>.md
  - ~/.dev-studio/<project>/apollo/deferred/<id>.yaml
  - ~/.dev-studio/<project>/events/<today>.jsonl
---

# Mode: CPU (`/apollo cpu`)

CPU is a first-class Apollo mode. It is not a thermal subcase: the user may care about foreground compute spikes, main-thread saturation, polling loops, excessive SwiftUI updates, decode / layout work, SDK hot paths, field `MXCPUExceptionDiagnostic` payloads, or XCTest CPU regressions even when thermal state never rises.

Source-map rows: `apollo/_shared/primitives/source-map.md` §Mode row index -> cpu. CPU mode cites source-map row IDs for Apple / WWDC authority, then cites local primitives for operational gates.

## Signal classes

| Class | What it looks like | Authoritative source | Apollo template |
|---|---|---|---|
| On-CPU hot path | Weighted self time, cycles, or instructions concentrate in a function / stack during the scenario | Time Profiler, CPU Profiler, Processor Trace, `XCTCPUMetric` | CPU Profiler + Time Profiler |
| Main-thread saturation | Main thread spends the scenario interval doing CPU work and misses interaction / frame deadlines | Time Profiler main-thread track, Hangs, signpost interval | Time Profiler + Hangs |
| Microarchitecture bottleneck | High cycles with poor useful work: instruction delivery, branch, cache, IPC, or discarded-work bottleneck | CPU Counters, Processor Trace, Apple Silicon CPU guide | CPU Counters + Processor Trace |
| Off-CPU wait | User-visible slowness correlates with locks, scheduling, syscalls, thread hops, or blocked work rather than retired instructions | System Trace, Time Profiler call tree with wait-heavy stacks | System Trace + Time Profiler |
| Field CPU diagnostic | Production payload reports cumulative CPU, CPU exception, or CPU-heavy signpost interval | `MXCPUMetric`, `MXCPUExceptionDiagnostic`, `MXSignpostIntervalData` | MetricKit + dSYM symbolication |

The class is load-bearing. CPU recommendations cite the class on every finding; cross-class citations fail the gate. A Time Profiler hot stack does not justify a cache-layout recommendation unless CPU Counters or Processor Trace names the memory-system bottleneck.

## Phase 1 - Diagnose

Goal: classify the signal, pick the minimum artifact set, and decide whether Apollo can capture autonomously.

| Question | Primary artifact | Required anchor | Pass condition |
|---|---|---|---|
| Which stack burns CPU inside the user flow? | CPU Profiler or Time Profiler `.trace` | `OSSignposter` interval `<Scenario>` brackets the flow | Weighted self / total time, cycles, or instructions cite symbol + thread + timestamp range |
| Is the main thread CPU-bound? | Time Profiler + Hangs | Main-thread track and scenario signpost | Main-thread samples dominate the interval, or Hangs reports a block with matching call stack |
| Is the issue microarchitectural? | CPU Counters + Processor Trace | Scenario signpost and symbolicated dSYMs | Counter category and derived metric identify instruction delivery, processing, discarded work, cache, branch, or IPC bottleneck |
| Is the app waiting rather than computing? | System Trace | Scenario signpost plus thread identifiers | Wait / lock / syscall / scheduling rows explain wall-clock delay better than on-CPU samples |
| Is this only visible in production? | MetricKit payload + Organizer / ASC row | Build, payload window, cohort, dSYM UUID | `MXCPUMetric` or `MXCPUExceptionDiagnostic` exceeds cohort baseline and resolves to a call stack |

Hard-evidence catalogue rows for CPU (from `apollo/_shared/primitives/evidence-gate.md`): CPU Profiler / Time Profiler `.trace`, CPU Counters `.trace`, Processor Trace `.trace`, System Trace `.trace`, Hangs `.trace`, `MXCPUMetric`, `MXCPUExceptionDiagnostic`, `MXSignpostIntervalData.cumulativeCPUTime`, and `XCTCPUMetric` baseline diffs.

## Phase 2 - Measure

Apollo captures the narrowest artifact that can answer the diagnostic question:

| Class | Capture recipe | Minimum evidence |
|---|---|---|
| On-CPU hot path | `xctrace record --template "CPU Profiler" --device "<udid>" --launch -- "<bundle>" --time-limit 60s --output cpu.trace`; fall back to Time Profiler when CPU Profiler is unavailable | `.trace` with scenario signpost, symbolicated frames, thread, self / total metric, cohort |
| Main-thread saturation | `xctrace record --template "Time Profiler" ...` plus Hangs when user-visible stalls are reported | Main-thread call tree within signpost; hang duration / stack when present |
| Microarchitecture bottleneck | `xctrace record --template "CPU Counters" ...`; escalate to Processor Trace for short, supported hardware windows | Counter category, derived metric, symbol / instruction range, dSYM status, hardware support note |
| Off-CPU wait | `xctrace record --template "System Trace" ...` with the same scenario | Waiting thread / lock / syscall / scheduler row and the caller stack that owns it |
| Field CPU diagnostic | Pull stored MetricKit payloads or ASC diagnostics; symbolize with matching dSYMs | Payload window, cohort, build, metric value, diagnostic callStackTree, dSYM UUID |

Capture-only support: `/apollo measure cpu --capture-only` and `/apollo cpu --capture-only` stop after writing the artifact sidecar. They emit `apollo_capture_completed`; they do not recommend a fix.

## Phase 3 - Attribute

CPU attribution maps evidence to likely source areas without pretending certainty beyond the artifact:

| Evidence | Likely code area | Required wording |
|---|---|---|
| App symbol dominates weighted self time | Function / file owning that symbol | "Likely code area: `<symbol>` / `<file>` because it owns `<metric>` in `<artifact>`" |
| Framework / SDK symbol dominates and app callers are visible | App caller stack that feeds the framework | "Likely code area: caller into `<framework>`; domain fix may need handoff" |
| SwiftUI update / diffing stack appears hot | SwiftUI view update path; hand off code interpretation to SwiftUI performance skill | Cite stack and recommend a SwiftUI performance audit only after hard evidence |
| Imgly / Metal stack dominates | Apollo retains measurement; domain fix guidance routes to `imgly-engine-expert` | Use `apollo/_shared/integrations/imgly-and-metal.md` handoff envelope |
| Wait-heavy System Trace | Synchronization / scheduling owner, not CPU algorithm | Recommend lock / scheduling fix only when wait rows cite owner stack |
| CPU Counters points to cache / branch / IPC | Data layout, branch shape, vectorization, or algorithmic work | Name counter category and metric; do not cite Time Profiler alone |

Recommendation shape:

```yaml
RECOMMEND (cpu:<class>): <one-line summary>
confidence: 9/10
evidence:
  - artifact: ~/.dev-studio/<project>/apollo/captures/<id>/<artifact>
    workload: <scenario>
    cohort: <device>/<os>/<build>
    signpost: <interval-or-event>
    metric: <self_time|cycles|instructions|ipc|cpu_time|hang_duration>
likely_code_area:
  symbol: <symbol-or-stack-root>
  file: <path-or-null>
  rationale: <artifact-backed reason>
fix_archetype: <algorithm|main_thread|qos|wait|vectorize|cache_layout|polling|domain_handoff>
expected_delta: <metric + threshold Apollo will verify>
verification: <post-fix capture recipe>
```

## Phase 4 - Recommend / patch handoff

Patch handoff follows `apollo/_shared/primitives/mode-pack-scaffold.md` §Phase 4. CPU's mode-specific brief seed adds `likely_code_area`, `thread`, and `cpu_class`. Apollo does not write source files.

| Fix archetype | Evidence required | Notes |
|---|---|---|
| Replace polling / spin loop with event-driven wait or cooperative yield | Hot loop stack, high CPU time, loop body visible in symbolicated trace | If the loop is intentionally real-time, require a target cadence and verification budget |
| Move non-interactive work off main or lower QoS | Main-thread saturation or P-core-heavy background-shaped work | Pair with `swift-concurrency-pro` when the patch touches actors, tasks, Sendable, or cancellation |
| Reduce algorithmic complexity / cache repeated work | Hot path grows with input size or repeats within signpost interval | Require a workload description that exercises the bad input shape |
| Vectorize or batch compute | Scalar math hot path, CPU Counters / Processor Trace supports instruction bottleneck | Cite `SRC-CPU-GUIDE-V4` or `SRC-CPU-BOTTLENECKS-DOC`; avoid generic "use SIMD" claims |
| Improve data locality | CPU Counters identifies cache / memory-system bottleneck at a symbol | Time Profiler alone is insufficient |
| Resolve lock / scheduling wait | System Trace shows wait owner and caller stack | Do not call this a CPU-utilization fix; it is a wall-clock responsiveness fix |
| Domain handoff | Imgly, Metal, or SwiftUI stack dominates | Apollo writes the evidence envelope; the domain skill interprets code-level fix options |

## Phase 5 - Verify

Re-measure outcome state machine: `apollo/_shared/primitives/mode-pack-scaffold.md` §Phase 5. CPU's match axes are `cohort + scenario + signpost + build + template + thread_scope`. Pre-fix and post-fix captures must match those axes.

| Claim | Required evidence |
|---|---|
| "CPU regression resolved" | Post-fix CPU Profiler / Time Profiler or `XCTCPUMetric` capture under the same axes; expected delta exceeds the CPU noise floor |
| "Main thread CPU fixed" | Post-fix main-thread weighted time or hang duration drops under the named threshold |
| "Counter bottleneck fixed" | Post-fix CPU Counters / Processor Trace shows the named counter category and derived metric improved |
| "Field CPU improved" | Same-cohort MetricKit / ASC window shows sustained drop after release; local trace may verify mechanism but does not replace field proof |

Sibling-metric regressions worth flagging: thermal and battery for CPU reductions that increase wall-clock dwell; memory for caching / precomputation fixes.

## Cohort and noise control

| Noise source | Gate |
|---|---|
| Simulator vs device | Simulator traces may support code-shape attribution, but strict-9 iOS CPU recommendations require the target device class unless the issue is XCTest-only |
| Debug vs Release | Debug traces are advisory only for CPU cost; Release / profiling build required for recommendation |
| dSYM mismatch | Refuse `reason: dsym_uuid_mismatch`; symbolication is part of the evidence |
| Missing signpost | Refuse `reason: signpost_missing` unless the artifact is a MetricKit field diagnostic whose window is the scenario |
| Thermal pressure | Discard CPU comparisons when `MXMetaData.thermalState > .fair` unless the CPU issue is explicitly thermal-coupled |
| Low Power Mode | Record and match; do not compare Low Power Mode captures to normal captures |

Regression thresholds use `apollo/_shared/primitives/regression-detection.md`: CPU time defaults to +15% on mean. For local signposted traces, Apollo also requires the cited stack to exceed the mode's noise floor before recommending.

## Failure modes

| Failure | Classification | Response |
|---|---|---|
| No artifact and no available capture path | permanent | Emit the strict-9 refusal block with CPU artifacts and attempted paths |
| Host lacks xctrace / real-device access | permanent | Refuse with `reason: capability_unavailable`; list `--evidence <path>` resumption |
| CPU Profiler unavailable on host | ambiguous | Fall back to Time Profiler when the diagnostic question is hot-stack attribution; refuse for CPU-profiler-only claims |
| Processor Trace unsupported on hardware | permanent | Use CPU Counters if sufficient; otherwise refuse the microarchitecture claim |
| dSYM mismatch | ambiguous | Retry dSYM lookup once; refuse with the offending UUID on miss |
| User-visible slowness is off-CPU | permanent | Route to System Trace class; do not recommend CPU algorithm fixes |
| SwiftUI / Imgly / Metal stack dominates | permanent | Emit evidence-backed handoff; Apollo does not embed domain internals |

## Procedure

1. **READ** the input artifact or invocation and classify it into one of {on-CPU hot path, main-thread saturation, microarchitecture bottleneck, off-CPU wait, field CPU diagnostic}.
   Before: caller invokes `/apollo cpu`, `/apollo measure cpu`, or supplies a CPU-shaped artifact.
   After: class, source-map row IDs, and required artifact set are recorded.

2. **CHECK** the strict-9 evidence gate.
   Before: class is known.
   After: hard evidence passes, or auto-capture-before-refuse runs via `apollo/_shared/primitives/execution-surface.md`.

3. **RUN** the capture recipe when Apollo has the host capability and budget.
   Before: capability matrix declares required tools installed; cohort and workload are known.
   After: artifact and sidecar are persisted; `apollo_capture_completed` or `apollo_capture_deferred` is emitted.

4. **CHECK** attribution quality.
   Before: artifact exists.
   After: likely code area, thread scope, metric, and confidence are either evidence-backed or the mode refuses with the strict-9 block.

5. **EMIT** a recommendation or handoff.
   Before: recommendation shape is complete and cites artifact + workload + cohort.
   After: `apollo_recommendation` or `apollo_advisory` event is emitted; source-code mutation routes to Achilles or a domain skill.

6. **CHECK** post-fix verification evidence before any resolved claim.
   Before: user or worker reports a patch landed.
   After: post-fix capture is compared on CPU match axes, or Apollo refuses the completion claim per `REVIEW.md` R10.

## See also

- `apollo/_shared/primitives/source-map.md` - Apple / WWDC source rows for CPU (`SRC-CPU-*`, `SRC-XCT-CPU-DOC`, `SRC-HANGS-WWDC22-10082`, `SRC-METRICKIT-WWDC20-10081`)
- `apollo/_shared/primitives/evidence-gate.md` - strict-9 contract + refusal protocol
- `apollo/_shared/primitives/instruments-index.md` - CPU Profiler / Time Profiler / CPU Counters / Processor Trace / System Trace details
- `apollo/_shared/primitives/metrickit.md` - `MXCPUMetric`, `MXCPUExceptionDiagnostic`, `MXSignpostIntervalData` schemas
- `apollo/_shared/primitives/signposts.md` - scenario anchors that make CPU traces re-runnable
- `apollo/_shared/primitives/xctest-baselines.md` - `XCTCPUMetric` baselines
- `apollo/_shared/integrations/imgly-and-metal.md` - domain handoff envelope when render / SDK stacks dominate
- `_shared/contracts/events.md` - `apollo_capture_*`, `apollo_recommendation`, `apollo_refused`, and `apollo_advisory` schemas
