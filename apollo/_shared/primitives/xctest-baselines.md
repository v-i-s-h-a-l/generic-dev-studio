---
name: XCTest baselines primitive
description: XCTMetric types, measure() API, baseline storage and diff, custom metrics, launch / hitch / memory / CPU / storage / clock / signpost variants. Apollo's dev-loop regression bar.
type: reference
schema_version: 1
---

# XCTest baselines (dev-loop regression bar)

XCTest's performance APIs let a test target measure a named workload, persist the result as a baseline in the test bundle, and fail subsequent runs that regress beyond a configured tolerance. Apollo treats a baseline diff as **hard evidence (9/10)** when (a) the test target is checked in, (b) the baseline is checked in (`*.xcbaseline`), and (c) the run cohort matches the baseline cohort (same device class / OS major).

Swift Testing does not yet ship a `measure` equivalent — performance assertions stay on `XCTestCase` even in projects that have otherwise migrated. Apollo cites the XCTest target by name when referencing a baseline.

## API surface

```swift
final class CheckoutPerfTests: XCTestCase {
  func testRenderCart() {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10              // default 5
    opts.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(metrics: [
      XCTClockMetric(),
      XCTMemoryMetric(),
      XCTCPUMetric(),
      XCTStorageMetric(),
      XCTOSSignpostMetric(subsystem: "com.example.app",
                          category: "PointsOfInterest",
                          name: "RenderCart"),
    ], options: opts) {
      startMeasuring()
      runScenario()
      stopMeasuring()
    }
  }
}
```

`measure(metrics:options:block:)` runs the closure `iterationCount` times, collects every metric per iteration, computes per-metric average + std-dev, and compares against the persisted baseline. A run that exceeds `baseline + maxStandardDeviation × baselineStdDev` fails the test.

`XCTMeasureOptions.iterationCount` defaults to 5; Apollo recommends 10 for high-variance workloads (anything touching disk, network, or first-render). `manuallyStart` / `manuallyStop` invocation options exclude setup from the measured window — load-bearing for cold-launch and decode-style workloads.

## XCTMetric catalogue

| Metric | Captures | Apollo mode |
|---|---|---|
| `XCTClockMetric` | wall-clock duration | all P0 |
| `XCTCPUMetric` | CPU time, instructions retired, cycles | thermal, battery |
| `XCTMemoryMetric` | physical memory delta, peak | memory |
| `XCTStorageMetric` | logical writes, persistent allocations | battery |
| `XCTApplicationLaunchMetric` | launch interval (warm or cold via option) | launch (Phase 2) |
| `XCTOSSignpostMetric` | duration of a named `OSSignposter` interval | all P0 — anchor metric |
| `XCTOSSignpostMetric.applicationLaunch` | system-emitted launch interval | launch (Phase 2) |
| `XCTOSSignpostMetric.scrollDecelerationHitchTimeRatio` | hitch ratio for visible `UIScrollView` deceleration | scroll-perf (Phase 2) |
| `XCTOSSignpostMetric.navigationTransitionHitchTimeRatio` | hitch ratio for navigation transitions | scroll-perf (Phase 2) |
| `XCTOSSignpostMetric.customNavigationTransitionHitchTimeRatio` | hitch ratio for app-defined navigation | scroll-perf (Phase 2) |

`XCTApplicationLaunchMetric(waitUntilResponsive: true)` extends the launch interval through first responsiveness — a tighter definition than time-to-first-draw and the one Apollo cites under the `launch` mode.

## Custom metrics

Conform to `XCTMetric` for an app-defined dimension (frame count, allocation count, pixel mismatch). Apollo uses custom metrics sparingly — built-ins cover the P0 surface, and a custom metric is one more thing to validate against the strict-9 gate.

```swift
final class AllocationCountMetric: NSObject, XCTMetric {
  func reportMeasurements(from start: XCTPerformanceMeasurement,
                          to end:   XCTPerformanceMeasurement) throws -> [XCTPerformanceMeasurement] {
    [.init(identifier: "app.allocations.count", displayName: "Allocations",
           doubleValue: Double(end.allocationCount - start.allocationCount),
           unitSymbol: "")]
  }
  func willBeginMeasuring() {} ; func didStopMeasuring() {}
  func copy(with zone: NSZone? = nil) -> Any { AllocationCountMetric() }
}
```

A custom metric MUST emit a stable `identifier` — Apollo's regression-detection (`apollo/_shared/primitives/regression-detection.md`) keys baselines off it, and renaming silently zeroes history.

## Baseline storage and diff

Baselines persist as `<TestTarget>.xctest/Contents/Resources/Baselines/<UUID>.xcbaseline/` bundles in the built test target, with the source-controlled copy at `<project>/<TestTarget>/Baselines/<UUID>.xcbaseline/`. Each `.xcbaseline` bundle holds:

| File | Content |
|---|---|
| `Info.plist` | per-test `WriterID`, `LocalComputer.modelCode`, OS version, baseline timestamp |
| `Results.xcbaseline/Contents/Resources/<Target>/<TestClass>/<testMethod>.plist` | per-metric `baselineAverage` + `baselineIntegrationDisplayName` + `maxPercentRegression` + `maxPercentRelativeStandardDeviation` |

A run produces a `.xcresult` bundle. The relevant subtree:

```
<derived>/Logs/Test/<run>.xcresult/
  Test-<scheme>-...
    payloadRefs → ActionTestSummaryGroup
      tests[].subtests[].performanceMetrics[]
        identifier, displayName, measurements: [Double], baselineAverage, baselineRelativeStandardDeviation, maxPercentRegression
```

Apollo extracts that subtree via XCResultKit (`apollo/_shared/primitives/execution-surface.md`) and computes its own diff (`apollo/_shared/primitives/regression-detection.md`) — the built-in pass/fail is a sanity check, not the canonical signal.

## Baseline cohort and platform pinning

A baseline is only comparable to a run on the same device class + OS major. Xcode tags the baseline with `LocalComputer.modelCode` (e.g. `iPhone14,2`) and Apollo refuses cross-cohort diffs. Multi-cohort coverage requires multiple `.xcbaseline` bundles, one per cohort, selected at run-time by the test plan's destination.

Test-plan layout: one `.xctestplan` per cohort, each pinning `targetDeviceModel` and `targetDeviceOSVersion`. Apollo's `instruments-index.md` references the test plan by name when citing dev-loop evidence.

## How Apollo references XCTest baselines

Mode packs cite baseline diffs in this shape:

| Citation form |
|---|
| `<TestClass>.<testMethod>` `<metric.identifier>` p_avg `<x>` ± `<sd>` vs baseline `<y>` ± `<bsd>` on cohort `<modelCode>/<osMajor>`, `.xcresult` `<path>` |

Vague forms ("the perf test got slower") fail the strict-9 gate. The cohort tag is mandatory — without it, the diff isn't comparable.

## Why

XCTest baselines are the only synthetic-but-deterministic perf signal Apollo gets pre-merge. MetricKit fleet data lags by ~24h and reflects shipped builds; XCTest is the dev-loop counterpart that catches regressions before they ship. The baseline-bundle-in-the-repo pattern keeps the diff anchor under source control, which is what makes "fresh evidence" verifiable — a baseline file's git history is the audit trail.

The cohort pin is what prevents the most common false positive: a baseline recorded on simulator failing on a slower physical device looks like a regression but isn't one. Apollo's regression-detection layer enforces the pin; the primitive documents why.

## See also

- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/signposts.md` — `XCTOSSignpostMetric` source side
- `apollo/_shared/primitives/instruments-index.md` — when a baseline regression demands trace-level diagnosis
- `apollo/_shared/primitives/regression-detection.md` — diff math, cohort rules
- `apollo/_shared/primitives/execution-surface.md` — XCResultKit extraction
- WWDC19 417 — Testing in Xcode (perf metrics intro)
- WWDC20 10077 — Eliminate animation hitches with XCTest
- WWDC25 226 — XCTest performance integration
