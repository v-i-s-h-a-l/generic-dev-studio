---
name: Canonical anti-patterns primitive
description: Curated 1/10 advisory channel for Apollo. Documented anti-patterns cited only when measurement is structurally impossible. Memory + thermal + battery rows seeded (Stage 2a + 2b + 2c).
type: reference
schema_version: 1
---

# Canonical anti-patterns (1/10 advisory channel)

The strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`) reserves a narrow 1/10 channel for canonical, documented anti-patterns. The channel exists for one shape only: the anti-pattern is present in the diff AND measurement is structurally impossible (no capture path inside the budget, no MetricKit payload reachable, no ASC build coverage). When measurement *is* possible, the channel is unavailable and Apollo proceeds to auto-capture-before-refuse.

## Hard rules

| Rule | Why |
|---|---|
| Apollo emits the literal prefix `advisory:1` on every advisory finding. | The prefix is the audit signal — dashboards filter advisory traffic out of regression dashboards by string match. |
| Advisory findings carry NO impact claim, NO regression call, NO expected delta. | Advisory is "the diff matches a pattern that is documented to be slow"; it is not "the diff is slow". |
| The advisory list is curated. Ad-hoc additions are out of scope. | An ungated list grows into an opinion engine; the opinion engine breaks the strict-9 gate. |
| An advisory citation MUST point to one row in this file. | A row that doesn't exist isn't an advisory; it's a hallucination. |
| Apollo refuses to chain advisories (advisory + advisory ≠ recommendation). | Advisory traffic compounding into "RECOMMEND" is the failure mode the channel exists to bound. |

## Citation form

Mode packs cite an advisory in this exact shape:

```
advisory:1 (<mode>:<row-id>): <one-line summary>
  source: apollo/_shared/primitives/canonical-antipatterns.md §<mode>:<row-id>
  diff_target: <file:line | symbol>
  measurement_path: blocked — <reason it's structurally impossible>
```

The `measurement_path: blocked` line is mandatory. If the reason names a path that does exist (e.g., "no simulator paired" when one is paired), the gate downgrades the advisory and routes back to auto-capture.

## Memory anti-patterns (Stage 2a — #230)

| Row id | Pattern | Diff signal | Why advisory, not recommendation |
|---|---|---|---|
| `mem:01` | Synchronous full-image decode on the main thread (`UIImage(contentsOfFile:)` of an asset > 4 MP without downsampling) | `UIImage(contentsOf*)` followed by direct UI assignment, no `CGImageSourceCreateThumbnailAtIndex` or `prepareForDisplay()` path | Footprint cost is real but device-class dependent; without an Allocations trace, magnitude is unknown |
| `mem:02` | Unbounded NSCache without `countLimit` or `totalCostLimit` | `NSCache` instantiated, neither limit set, no eviction observer | NSCache evicts under pressure but the watermark is system-dependent; without VM Tracker evidence, "unbounded" doesn't bound the impact |
| `mem:03` | Strong reference cycle through closure capture in a long-lived owner (`Timer.scheduledTimer`, `NotificationCenter.observe(...)`, `Combine.sink`) | Closure body references `self.` without `[weak self]` or `[unowned self]` AND owner outlives a single scope | Most are real cycles; some (e.g., `self` is a singleton) are intentional. Without Leaks evidence the diff doesn't disambiguate |
| `mem:04` | Retained `CIImage` chain accumulated across frames | `CIImage` stored in a property, re-assigned each frame, no `clearCaches()` on the `CIContext` | CIImage is lazy — peak materializes only when rendered. Without a Metal System Trace + VM Tracker pair, the accumulation cost is theoretical |
| `mem:05` | `MTLTexture` retained beyond the frame that presents it | `MTLTexture` stored as a property of the encoder owner, no explicit nil-out post `present()` | IOKit footprint impact is real but only visible in VM Tracker `IOKit` regions; without that capture, advisory only |
| `mem:06` | Bridging Core Foundation with `Unmanaged.takeUnretainedValue()` on a `Create` / `Copy` API | Method name contains `Create` or `Copy`, return passed through `takeUnretainedValue` | One side of this is overrelease (crash); the other is leak. Without `malloc_history` evidence the direction is undetermined |
| `mem:07` | Per-iteration allocation inside a hot loop with no `@autoreleasepool` (Obj-C / bridged Swift only) | Obj-C method body OR Swift `@objc` API with explicit autorelease semantics, hot loop, no drain | Pure Swift code does not benefit; advisory restricted to call-sites Apollo can identify as bridging Obj-C |
| `mem:08` | `Image` (SwiftUI) stored in `@State` rather than recomputed | `@State var image: Image?` assigned from disk read | SwiftUI's `Image` is a value type; the cost is the underlying `CGImage`. Without VM Tracker evidence the persistence cost is speculative |

## Thermal anti-patterns (Stage 2b — #231)

| Row id | Pattern | Diff signal | Why advisory, not recommendation |
|---|---|---|---|
| `therm:01` | App does sustained CPU / GPU / capture / encode work but registers no `ProcessInfo.thermalStateDidChangeNotification` observer | Codebase contains a render loop, encoder pipeline, ML inference loop, or capture session AND no `addObserver`/`NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)` / `NSProcessInfoThermalStateDidChangeNotification` registration anywhere | The app cannot shed load under thermal pressure; the OS will throttle silently and user-visible regression magnitude is workload-dependent. Without a sustained-load trace, magnitude is unknown |
| `therm:02` | High-frequency timer or display-link animation not paused under `.serious` thermal state | `Timer.scheduledTimer`, `CADisplayLink`, or `Combine.Timer.publish` driving UI / capture / DSP at ≥ 1 Hz AND no thermalState observer reducing cadence | Cost depends on what the timer drives; without Time Profiler under sustained dwell, the impact is theoretical |
| `therm:03` | `.userInteractive` / `.userInitiated` QoS on background-shaped work (export, indexing, prefetch, encode) | `Task(priority: .userInitiated)` or `DispatchQueue.global(qos: .userInteractive)` wrapping work that is not user-blocking and has no frame deadline | High-QoS pins work to P-cores per Apple's scheduler; the heat cost is real but only resolved by per-core CPU Counters under load |
| `therm:04` | Busy-wait / CPU spin loop with no yield, no sleep, no `await` | `while !condition { … }` body without `Thread.sleep`, `Task.yield()`, `await`, or `DispatchSemaphore.wait` | Pure heat production with zero useful work; documented in Apple's Energy Efficiency Guide. Without a Time Profiler trace pinning the spin, the duration / wakeup pattern is unmeasured |
| `therm:05` | Foreground `CLLocationManager` at `kCLLocationAccuracyBest` / `BestForNavigation` without thermal-state throttling | CLLocationManager configured at maximum accuracy, `startUpdatingLocation()` invoked, no thermalState observer reducing accuracy or pausing | High-accuracy GPS is documented as a sustained thermal source (Apple Energy Efficiency Guide); magnitude is device- and reception-dependent |
| `therm:06` | Per-frame construction of `CIImage`, `MTLCommandBuffer`, or `MTLCommandQueue` inside a render / display callback | `CIImage(...)` / `device.makeCommandQueue()` / `commandBuffer()` invoked inside a `CADisplayLink` callback or `MTKView.draw(in:)` at frame rate, no caching / reuse | Metal best-practices document buffer reuse as canonical; without Metal System Trace evidence the per-frame allocation cost is speculative. Apollo refuses Metal-internal recommendations until Stage 3 (#233) ships — see `apollo/modes/thermal.md` Metal carve-out |
| `therm:07` | Continuous foreground ML inference on `MLComputeUnits.all` (or repeated `VNCoreMLRequest`) with no thermal gating | `MLModel.prediction(...)` or `VNCoreMLRequest` invoked per frame / per scenario tick, `computeUnits` left at `.all` or `.cpuAndGPU`, no thermalState observer | Neural Engine + GPU + CPU placement is workload-dependent; without per-cohort capture the heat cost cannot be attributed to ML vs the rest of the pipeline |
| `therm:08` | `AVCaptureSession` running at high FPS / resolution with no shed path under `.serious` | `AVCaptureDevice.activeFormat` set to a high-FPS / high-resolution format, session running in foreground, no thermalState observer reducing FPS or resolution | Capture-pipeline thermal cost scales non-linearly with FPS × resolution; without Metal System Trace + Energy Log under sustained dwell the magnitude is unmeasured |

## Battery anti-patterns (Stage 2c — #232)

| Row id | Pattern | Diff signal | Why advisory, not recommendation |
|---|---|---|---|
| `batt:01` | Foreground `CLLocationManager` running at `kCLLocationAccuracyBest` / `BestForNavigation` while not user-engaged; or `startUpdatingLocation()` invoked without a paired pause on `applicationDidEnterBackground` for non-location-essential apps | `CLLocationManager.desiredAccuracy = kCLLocationAccuracyBest{ForNavigation}`, `startUpdatingLocation()` invoked, no balancing `stopUpdatingLocation()` on background entry, no switch to `startMonitoringSignificantLocationChanges` for non-foreground use | High-accuracy GPS is a documented sustained drain source (Apple Energy Efficiency Guide); magnitude is device- and reception-dependent and can only be attributed by a Power Profiler Location row capture |
| `batt:02` | Polling HTTP loop with sub-minute interval instead of push or backoff | `Timer.scheduledTimer(withTimeInterval: <60, …)` or `RunLoop` schedule firing a `URLSessionDataTask`, `URLSession.shared.data(for:)`, or equivalent in a loop with no `URLRequest.cachePolicy = .returnCacheDataElseLoad` and no exponential backoff | Tail-energy on each cellular wake compounds the per-request cost; without a Power Profiler `network` row + Network instrument trace, the tail-energy magnitude is unmeasured |
| `batt:03` | Persistent WebSocket / long-poll without keepalive coalescing or backoff window | `URLSessionWebSocketTask`, `URLSessionStreamTask`, or third-party WS client kept open across foreground / background transitions, no ping coalescing, no `URLSessionConfiguration.timeoutIntervalForResource`, no APNs fallback for backgrounded delivery | Persistent radio sessions prevent radio sleep; cost depends on RTT and ping cadence and only resolves under Power Profiler + Network instrument paired capture |
| `batt:04` | `Timer.scheduledTimer` / `CADisplayLink` / `Combine.Timer.publish` active when app is backgrounded | Timer or display-link instantiated in `viewDidLoad` / `init`, no `applicationDidEnterBackground` / `scenePhase == .background` invalidation path | Background CPU + display wakes; cost depends on cadence and what the timer drives. Without Power Profiler across the background interval, the wake density is unattributed |
| `batt:05` | `CBCentralManager.scanForPeripherals(withServices:options:)` running continuously without duty-cycling | `scanForPeripherals` invoked once, no balancing `stopScan()`, no duty-cycle window (start → discover → stop → wait → repeat); `CBCentralManagerScanOptionAllowDuplicatesKey: true` ratchets the cost further | Continuous BLE scan is a sustained Bluetooth drain; magnitude depends on advertisement density and only resolves under Power Profiler Bluetooth row capture |
| `batt:06` | `AVAudioSession` activated and held active outside playback windows | `AVAudioSession.sharedInstance().setActive(true, …)` invoked, no balancing `setActive(false, options: .notifyOthersOnDeactivation)` on playback stop / `applicationDidEnterBackground`; `.playAndRecord` category retained when only `.ambient` is needed | Active audio session keeps the audio subsystem powered; cost is real but workload-dependent and only attributed under Power Profiler Audio row capture |
| `batt:07` | `UIApplication.shared.isIdleTimerDisabled = true` left enabled outside the scoped use case | `isIdleTimerDisabled = true` set in a view controller's `viewDidAppear` / `init` with no balancing `false` reset on `viewDidDisappear` / `applicationWillResignActive` / `scenePhase` transition; or set globally at app launch | Disabled idle timer keeps the screen on, dominating display energy; magnitude depends on user dwell and only resolves under Power Profiler Display row + `MXDisplayMetric.averagePixelLuminance` capture |
| `batt:08` | Background URLSession / `BGProcessingTask` with un-bounded work; no `expirationHandler`, `BGProcessingTaskRequest.requiresExternalPower = false` for compute-heavy work, or no `BGTask.setTaskCompleted(success:)` in the success path | `URLSessionConfiguration.background(withIdentifier:)` task started without a registered `URLSessionDelegate.urlSession(_:didCompleteWithError:)` cleanup; or `BGTaskScheduler.shared.register(forTaskWithIdentifier:)` handler that does not register `task.expirationHandler` and call `task.setTaskCompleted(success:)` on every exit path | Background overruns hit the OS watchdog (`0xdead10cc`) and thrash the cohort battery aggregate; magnitude depends on cadence × work and only resolves under Power Profiler driven by a `simctl push` / `(lldb) BGTaskScheduler._simulateLaunchForTaskWithIdentifier:` script |

## How rows enter the list

A new row is added under one of two conditions:

1. **WWDC / Apple-doc citation** — the anti-pattern appears in an Apple-published source as a documented pitfall (WWDC video, Apple Developer guide, Xcode template inline doc). The row carries the citation in the mode-pack `See also` block.
2. **Repeat-incidence in shipped post-mortems** — the same pattern is the root cause in ≥ 3 distinct shipped regressions across ≥ 2 projects, post-mortems retained with the captured pre-fix evidence. The row's evidence trail is summarized in the row's "Why advisory" cell.

Single-incidence patterns do not enter. The bar is deliberate; an ad-hoc list grows into an opinion engine and breaks the strict-9 gate.

## Why curated, not algorithmic

A pattern-match-on-diff system that flags "looks expensive" is the regression Apollo's strict-9 contract exists to prevent. The advisory channel exists for the narrow case where (a) the pattern is documented as a problem by Apple or by the project's own incident history, AND (b) measurement is structurally impossible at the moment of the diff. Both gates are required. Either alone — pattern without curation, or impossibility without pattern — is hallucination wearing the gate's uniform.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — the 1/10 advisory channel definition and its narrow scope
- `apollo/_shared/primitives/execution-surface.md` — the auto-capture decision tree the advisory route only fires after exhausting
- `apollo/modes/memory.md` — consumer of the `mem:NN` rows
- `apollo/modes/thermal.md` — consumer of the `therm:NN` rows
- `apollo/modes/battery.md` — consumer of the `batt:NN` rows
- WWDC18 219 — Image and Graphics Best Practices (canonical for `mem:01`)
- WWDC21 10180 — Detect and diagnose memory issues (canonical for `mem:02`–`mem:05`)
- Apple "ARC: Strong Reference Cycles for Closures" — Swift Programming Language guide (canonical for `mem:03`)
- WWDC18 416 — iOS Memory Deep Dive (canonical for `mem:07`)
- Apple "Reacting to thermal state changes" + `ProcessInfo.thermalStateDidChangeNotification` reference (canonical for `therm:01`, `therm:02`, `therm:05`, `therm:08`)
- Apple Energy Efficiency Guide for iOS Apps — high-QoS / busy-wait / location accuracy guidance (canonical for `therm:03`, `therm:04`, `therm:05`)
- WWDC25 308 — Optimize CPU performance with Instruments (canonical for `therm:03`, `therm:04`)
- Apple Metal best-practices — command-buffer / queue reuse (canonical for `therm:06`)
- WWDC22 10027 / Core ML compute-unit selection guidance (canonical for `therm:07`)
- Apple Energy Efficiency Guide for iOS Apps — location accuracy / radio coalescing / always-on subsystem guidance (canonical for `batt:01`, `batt:02`, `batt:03`, `batt:05`, `batt:06`)
- WWDC25 226 — Profile and optimize power usage in your app (canonical for `batt:01`–`batt:08` reproducible-vs-non-reproducible split)
- WWDC22 10142 — Efficiency awaits: Background tasks in SwiftUI (canonical for `batt:08`)
- WWDC21 10212 — Analyze HTTP traffic in Instruments (canonical for `batt:02`, `batt:03` tail-energy)
- Apple `BGTaskScheduler` + `BGProcessingTaskRequest` references (canonical for `batt:08`)
- Apple `UIApplication.isIdleTimerDisabled` reference (canonical for `batt:07`)
- Apple `AVAudioSession` lifecycle reference (canonical for `batt:06`)
- Apple `CBCentralManagerScanOptionAllowDuplicatesKey` reference (canonical for `batt:05`)
