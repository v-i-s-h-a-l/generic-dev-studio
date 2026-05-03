---
name: MetricKit primitive
description: MXMetricPayload + MXDiagnosticPayload schemas, subscription lifecycle, symbolication path, persistence pattern, and privacy model. Apollo's primary source of production-fleet evidence.
type: reference
schema_version: 1
---

# MetricKit (production-fleet evidence)

Apple's on-device aggregation framework for performance and reliability data. Apollo treats MetricKit payloads as **hard evidence (9/10)** under the strict-9 gate (`apollo/_shared/primitives/evidence-gate.md`) because they originate from real devices under real workloads, not synthetic benchmarks.

Two manager singletons:

| Manager | Delivers | Available |
|---|---|---|
| `MXMetricManager.shared` | `MXMetricPayload` (aggregate metrics) | iOS 13+ |
| `MXDiagnosticManager.shared` | `MXDiagnosticPayload` (crashes, hangs, disk-write exceptions, CPU exceptions) | iOS 14+ |

Both deliver via `MXMetricManagerSubscriber` / `MXDiagnosticManagerSubscriber` protocols with `didReceive(_ payloads: […])` callbacks. Payloads also accessible retroactively via `pastPayloads` (≤ 7 days) and `pastDiagnosticPayloads`.

## MXMetricPayload categories

All properties optional (nil if not collected for the window):

| Category | Type | Apollo mode |
|---|---|---|
| `cpuMetrics` | `MXCPUMetric` (cumulativeCPUTime, cumulativeCPUInstructions iOS 14+) | thermal, battery, cpu |
| `memoryMetrics` | `MXMemoryMetric` (peakMemoryUsage, averageSuspendedMemory) | memory |
| `gpuMetrics` | `MXGPUMetric` (cumulativeGPUTime) | thermal, battery |
| `displayMetrics` | `MXDisplayMetric` (averagePixelLuminance) | battery |
| `applicationLaunchMetrics` | `MXAppLaunchMetric` (histogrammedTimeToFirstDraw, histogrammedApplicationResumeTime) | launch (Phase 2) |
| `applicationResponsivenessMetrics` | `MXAppResponsivenessMetric` (histogrammedApplicationHangTime) | responsiveness (Phase 2) |
| `diskIOMetrics` | `MXDiskIOMetric` (cumulativeLogicalWrites) | battery |
| `cellularConditionMetrics` | `MXCellularConditionMetric` (histogrammedCellularConditionTime) | network |
| `networkTransferMetrics` | `MXNetworkTransferMetric` (cumulativeWifiUpload, cumulativeCellularUpload, …) | network, battery |
| `applicationTimeMetrics` | `MXAppRunTimeMetric` (cumulativeForegroundTime, cumulativeBackgroundTime, cumulativeForegroundEnergy iOS 14+) | battery |
| `applicationExitMetrics` | `MXAppExitMetric` (foregroundExitData / backgroundExitData — categorized exit reasons incl. OOM) | memory, thermal |
| `animationMetrics` | `MXAnimationMetric` (scrollHitchTimeRatio, iOS 14+) | scroll-perf (Phase 2) |
| `signpostMetrics` | `[MXSignpostMetric]` — see `apollo/_shared/primitives/signposts.md` | all P0 |
| `metaData` | `MXMetaData` — thermalState samples (iOS 14+), lowPowerModeEnabled, OS, app build, region, deviceType, pid | all P0 |

`metaData.thermalState` is the only place the OS reports field thermal pressure aggregated to the app — load-bearing for the `thermal` mode pack.

## MXDiagnosticPayload categories

| Category | Type | Apollo mode |
|---|---|---|
| `crashDiagnostics` | `[MXCrashDiagnostic]` (callStackTree, exceptionType, terminationReason — incl. watchdog `0x8badf00d`, OOM `0xc00010ff`, runtime `0xdead10cc`) | memory, thermal |
| `hangDiagnostics` | `[MXHangDiagnostic]` (callStackTree, hangDuration) | responsiveness (Phase 2); thermal correlation |
| `cpuExceptionDiagnostics` | `[MXCPUExceptionDiagnostic]` (callStackTree, totalCPUTime, totalSampledTime) | thermal, battery, cpu |
| `diskWriteExceptionDiagnostics` | `[MXDiskWriteExceptionDiagnostic]` (callStackTree, totalWritesCaused) | battery |
| `appLaunchDiagnostics` | `[MXAppLaunchDiagnostic]` (callStackTree, launchDuration, iOS 16+) | launch (Phase 2) |

Every diagnostic carries an `MXCallStackTree` rooted at the offending thread; symbolication lives below.

## Subscription lifecycle

Standard adopt-at-launch pattern:

```swift
final class MetricKitSink: NSObject, MXMetricManagerSubscriber, MXDiagnosticManagerSubscriber {
  func didReceive(_ payloads: [MXMetricPayload])     { payloads.forEach(persist) }
  func didReceive(_ payloads: [MXDiagnosticPayload]) { payloads.forEach(persist) } // iOS 14+
}

let sink = MetricKitSink()
MXMetricManager.shared.add(sink)
MXDiagnosticManager.shared.add(sink) // iOS 14+
```

Delivery cadence: Apple delivers a payload roughly once per 24 hours, gated on the device being idle (typically while charging). The first payload after install can take days. `pastPayloads` returns up to 7 days of stored payloads — query at launch to backfill the on-disk cache.

## Symbolication

Payloads ship with **partial** symbolication: system frames are resolved, app frames are not. Apollo's symbolication path:

1. Pull the build's `dSYM` from Xcode Organizer (`Window → Organizer → Crashes → Show in Finder`) or via App Store Connect dSYM download.
2. Match on `MXCallStackTree.callStacks[].callStackRootFrames[].binaryName` + `binaryUUID`.
3. Resolve each frame's `address` against the binary's `binaryLoadAddress` via `atos -arch <arch> -o <dSYM>/Contents/Resources/DWARF/<bin> -l <loadAddr>`.
4. Persist the symbolicated tree alongside the raw payload for diff against future payloads.

dSYM mismatch is the dominant failure mode — UUID drift between archived build and symbolicating host. ChimeHQ/Meter (open-source MetricKit utilities) ships a Swift symbolication helper that handles UUID matching; `apollo/_shared/primitives/execution-surface.md` (Stage 1b) wraps it.

## Persistence pattern

Payloads are ephemeral — they live in process memory until the app stores them. Apollo's reference pattern:

| Step | Action |
|---|---|
| 1 | On `didReceive`, call `payload.jsonRepresentation()` → `Data`. |
| 2 | Write atomically to `Application Support/Apollo/payloads/<timestamp>-<uuid>.json`. |
| 3 | Index in a SQLite catalog (`payloads.db`) keyed by mode, app build, OS, device class. |
| 4 | Upload (or sync to ASC Performance Metrics fetch) on next foreground; never block UI thread. |
| 5 | Garbage-collect at 30 days unless flagged by an open Apollo investigation. |

`jsonRepresentation()` is the canonical serialization — `MXMetricPayload(json:)` (iOS 14+) round-trips so historical analysis can be done without keeping the original `MXMetricPayload` object graph alive.

## Privacy model

- Per-device opt-in via `Settings → Privacy & Security → Analytics & Improvements → Share With App Developers`. Roughly 20–30% of the fleet opts in; reflect this in coverage estimates.
- Payloads contain no user identifiers, no advertising id, no precise location. `MXMetaData` carries OS, device class, app version, region — enough for cohorting, not for re-identification.
- Diagnostic call-stack trees contain symbol names from app code; treat the upload pipeline as code-confidential, not user-confidential.

## How Apollo references MetricKit

Mode packs cite specific properties as evidence in their procedure tables:

| Mode | Citation form |
|---|---|
| memory | `MXMemoryMetric.peakMemoryUsage` p95 over `<window>` payloads, cohort `<device-class>/<os>` |
| thermal | `MXMetaData.thermalState` distribution (% serious / critical) over `<window>` |
| battery | `MXAppRunTimeMetric.cumulativeForegroundEnergy` per session, normalized by `cumulativeForegroundTime` |
| network | `MXNetworkTransferMetric.cumulativeCellularDownload` / `cumulativeCellularUpload` / `cumulativeWifiDownload` / `cumulativeWifiUpload` over `<window>`, paired with `MXCellularConditionMetric.histogrammedCellularConditionTime` for cellular claims, cohort `<device-class>/<os>`, build `<version>`, baseline `<window-or-build>` |

Mode packs MUST cite the exact payload property, the aggregation window, and the cohort. The strict-9 gate rejects citations missing any of those three.

Network-mode and battery networking-radio-drain citations additionally follow `apollo/_shared/primitives/evidence-gate.md §Network hard-evidence catalogue`: cellular claims require carrier-class / cellular-condition context, and field payloads without a comparison baseline remain soft evidence.

## Why

MetricKit is the only first-party channel for *production* performance data. Synthetic benchmarks (XCTest, local Instruments runs) cover the development loop; field reality lives in MetricKit. The dual-source design — aggregate metrics for trend, diagnostics for incident triage — maps cleanly onto Apollo's two evidence flows: regression detection (trend payload) and root-cause investigation (diagnostic payload). Persisting raw `jsonRepresentation()` keeps Apollo's analysis decoupled from the in-memory payload object graph, which is short-lived and not designed to be passed across processes.

## See also

- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/signposts.md` — `MXSignpostMetric` shape
- `apollo/_shared/primitives/organizer-asc.md` (Stage 1b) — App Store Connect Performance Metrics API
- WWDC20 10081 — What's new in MetricKit
- WWDC25 308 — `OSSignposter` integration with MetricKit
- ChimeHQ/Meter — open-source symbolication utilities
