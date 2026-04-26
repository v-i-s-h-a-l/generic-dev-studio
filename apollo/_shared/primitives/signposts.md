---
name: Signposts primitive
description: OSSignposter (Swift, iOS 15+) and legacy os_signpost API surfaces, interval vs event semantics, MetricKit signpost integration, XCTest measure() bridging, and Release-build overhead model.
type: reference
schema_version: 1
---

# Signposts (in-process workload markers)

Signposts mark named regions and events inside running code. Apollo treats them as **hard evidence (9/10)** when:

1. Captured into a `.trace` via Instruments under a controlled scenario, OR
2. Aggregated into `MXSignpostMetric` via MetricKit on the production fleet.

Signposts that exist only in source — never emitted into a trace or payload — are not evidence. They are instrumentation seeds.

## API surfaces

| API | Availability | Use |
|---|---|---|
| `OSSignposter` (Swift) | iOS 15+ / macOS 12+ | Preferred. Type-safe, supports `withIntervalSignpost`, automatic ID/name management. |
| `os_signpost` C macros | iOS 12+ | Legacy. Used in mixed Obj-C / older deployment targets only. |

`OSSignposter` is the default for any new code where the deployment target allows; `os_signpost` is grandfathered, never the default.

```swift
import OSLog

let signposter = OSSignposter(subsystem: "com.example.app", category: .pointsOfInterest)

// Interval — has begin and end
let state = signposter.beginInterval("FrameRender", id: signposter.makeSignpostID(), "frame=\(idx)")
// ... work ...
signposter.endInterval("FrameRender", state, "draws=\(drawCount)")

// Or scoped:
signposter.withIntervalSignpost("FrameRender", "frame=\(idx)") { … }

// Event — instantaneous
signposter.emitEvent("UserTap", "view=\(viewName, privacy: .public)")
```

## Interval vs event

| Shape | Has duration | Carries metadata at | Apollo use |
|---|---|---|---|
| Interval | yes (begin/end pair) | both endpoints | latency / time-cost workloads |
| Event | no | single point | counters, lifecycle markers, error sites |

Intervals are matched by `OSSignpostID` (auto from `makeSignpostID()` or stable from a hashable). Re-using a single ID for concurrent intervals is the most common bug — they overlap in the trace and skew aggregations. Use `makeSignpostID()` per interval, not per workload type.

## Custom metadata

Both APIs accept formatted strings as metadata. The `OSLogMessage` interpolation is type-safe and supports privacy qualifiers per interpolation:

```swift
signposter.endInterval("Decode", state,
                       "bytes=\(byteCount, privacy: .public), format=\(format, privacy: .public)")
```

**Default privacy is `.private`** — values render as `<private>` in traces and MetricKit aggregations unless explicitly tagged `.public`. Apollo's measurement-grade signposts MUST tag numeric payloads `.public` or they aggregate as opaque. This is the most common silent bug — instrumentation ships, gets aggregated, and the resulting MetricKit data is unreadable.

## XCTest measure() integration

`XCTOSSignpostMetric` bridges signposts into XCTest baselines (iOS 14+, macOS 11+):

```swift
measure(metrics: [XCTOSSignpostMetric(subsystem: "com.example.app",
                                      category: "PointsOfInterest",
                                      name: "FrameRender")]) {
  runScenario()
}
```

Per-interval duration is captured; XCTest persists a baseline (`xcbaseline` bundle in the test target) and surfaces regressions. Pre-canned variants:

| Variant | Captures |
|---|---|
| `XCTOSSignpostMetric.applicationLaunch` | system-emitted launch interval |
| `XCTOSSignpostMetric.scrollDecelerationHitchTimeRatio` | scroll hitch ratio for visible scroll views |

See `apollo/_shared/primitives/xctest-baselines.md` (Stage 1b) for baseline storage and diff math.

## MetricKit aggregation

`MXSignpostMetric` (iOS 14+) reports the production-fleet aggregate of named intervals:

| Property | Shape |
|---|---|
| `signpostName` | matches the `name:` argument at emit |
| `signpostCategory` | matches the category |
| `totalCount` | aggregated count over the payload window |
| `signpostIntervalData` | optional `MXSignpostIntervalData` — `histogrammedSignpostDuration`, `cumulativeCPUTime`, `cumulativeHitchTimeRatio`, `averageMemory`, `cumulativeLogicalWrites` |

Two requirements for inclusion in a payload:

1. The `OSLog` log handle MUST use the `.pointsOfInterest` category — other categories are filtered out of MetricKit aggregation.
2. The signpost name MUST be a string literal at the call site — runtime-formatted names are dropped.

Apollo's mode packs cite `MXSignpostMetric.signpostIntervalData.histogrammedSignpostDuration` as the canonical fleet-side latency evidence.

## Release-build overhead

`OSSignposter` and `os_signpost` are designed to compile to near-zero overhead when no trace consumer is attached:

- Each emit is a single guarded check against the log handle's enabled state.
- String interpolation arguments are evaluated lazily — passing `\(expensiveFunc())` only pays the cost when a consumer is attached.
- Hot-path entry is `@inline(__always)` on `OSSignposter`.

Empirical overhead on a Release build with no trace recording is sub-100 ns per emit and zero allocations. Apollo's recommendation: leave signposts in Release. Removing them is the regression — once the build ships without them, MetricKit's fleet aggregation (`MXSignpostMetric`) goes blind and the next investigation has no production-side evidence.

The one footgun: enabling the `OSLog` `signpost` stream via configuration profile on a real device *does* materialize emits and can perturb timing. Apollo's strict-9 captures from ASC / MetricKit are unaffected; only deliberate `xctrace` recording on a configured device is.

## How Apollo references signposts

Mode packs cite signposts in two evidence shapes:

| Shape | Citation form | Source |
|---|---|---|
| Local trace | `<name>` interval p50/p95 in `<trace.xcresult>` over `<scenario>` | `xctrace record` via execution-surface |
| Fleet aggregate | `MXSignpostMetric.<name>.histogrammedSignpostDuration` over `<window>`, cohort `<device-class>/<os>` | MetricKit `signpostMetrics` |

Apollo refuses citations that name a signpost without naming the trace file or payload window — see the "vague citation" failure mode in `apollo/_shared/primitives/evidence-gate.md`.

## Why

Signposts are the only mechanism that produces evidence equally usable in development (Instruments traces) and production (MetricKit aggregates). XCTest baselines cover the dev-loop regression bar; MetricKit covers fleet drift; signposts are the named-workload anchor that links them. Without them, dev-loop and fleet measure different things at different layers and Apollo's regression-detection math (`apollo/_shared/primitives/regression-detection.md`, Stage 1b) cannot compare across sources.

The privacy default (`.private`) is what makes the "tag measurement-grade numerics `.public`" rule load-bearing — a team that misses it ships instrumentation that aggregates as opaque and silently fails to be evidence.

## See also

- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/metrickit.md` — `MXSignpostMetric` consumer side
- `apollo/_shared/primitives/xctest-baselines.md` (Stage 1b) — `XCTOSSignpostMetric`
- WWDC18 405 — Measuring Performance Using Logging
- WWDC25 308 — `OSSignposter` usage in context
