---
name: Apollo battery mode
description: Diagnose → measure → propose → patch → re-measure protocol for battery / energy regressions under strict-9 evidence gating. Covers foreground compute, background overrun, always-on subsystems, and radio drain.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 6000
session_budget: 1800s
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
  - ~/.dev-studio/<project>/apollo/captures/**
  - ~/.dev-studio/<project>/apollo/baselines/*.json
  - ~/.dev-studio/<project>/apollo/deferred/*.yaml
  - ~/.dev-studio/.runtime/host-capabilities.yaml
  - ~/.dev-studio/<project>/events/**.jsonl
writes:
  - ~/.dev-studio/<project>/apollo/captures/<id>/**
  - ~/.dev-studio/<project>/apollo/recommendations/<id>.md
  - ~/.dev-studio/<project>/apollo/deferred/<id>.yaml
  - ~/.dev-studio/<project>/events/<today>.jsonl
  - ~/.dev-studio/.runtime/locks/apollo/*
---

# Mode: Battery (`/apollo battery`)

Battery is the third P0 mode under the strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`). The procedure is ordered: every transition requires hard evidence cited in the catalogue, otherwise the gate refuses and auto-capture-before-refuse runs the next step in the execution-surface decision tree.

The mode treats four energy signal classes as distinct — diagnostic question, capture template, regression math, and verification artifact differ per class. Mode packs cite the class on every recommendation; cross-class citations fail the gate. Battery evidence also splits along an orthogonal axis Apollo enforces explicitly: **reproducible** (debugger-attached, Power Profiler / Energy Gauges drive the capture) versus **non-reproducible** (field-only, `MXAppRunTimeMetric` / ASC Power Metrics carry the signal). The split is load-bearing — different artifact catalogues, different cohort models, different refusal recipes — and follows WWDC25 226 *Profile and optimize power usage in your app*.

## Reproducible vs non-reproducible (WWDC25 226 split)

| Track | When the signal lives there | Authoritative artifacts | What auto-capture can do |
|---|---|---|---|
| Reproducible | Drain reproduces with a paired device under a scripted scenario; debugger / Instruments / `xctrace` is reachable | Power Profiler `.trace` (Xcode 16+, replaces Energy Log on modern hosts), Energy Gauges live readout (Xcode debug navigator), `xctrace` Network / Location / Display sub-templates correlated against the Power Profiler timeline, XCTest `XCTOSSignpostMetric` baselines | Run `xctrace record --template "Power Profiler" --device <udid>` against a scripted scenario; collect Energy Gauges deltas; diff against the saved baseline |
| Non-reproducible | Drain only shows in production; no scenario reproduces it locally | `MXAppRunTimeMetric.cumulativeForegroundEnergy` (mWh, iOS 14+), `MXAppRunTimeMetric.cumulativeForegroundTime` (normalizer), `MXCPUMetric.cumulativeCPUTime` per foreground hour, `MXGPUMetric.cumulativeGPUTime`, `MXDisplayMetric.averagePixelLuminance`, `MXNetworkTransferMetric` upload/download by carrier, `MXDiskIOMetric.cumulativeLogicalWrites`, `MXAnimationMetric.scrollHitchTimeRatio` (over-rendering proxy), `MXCPUExceptionDiagnostic`, `MXDiskWriteExceptionDiagnostic`, ASC Power / Battery / Disk Writes rows | Defer — schedule a deferred-capture row for ≥ 24 h MetricKit cadence, refuse for now with `--deferred <id>`. Apollo never simulates field drain |

The track determines which gate fires. Reproducible recommendations cite the on-device capture; non-reproducible recommendations cite the field aggregate plus the cohort window. Mixing the two — citing a Power Profiler trace for a regression detected only in `MXAppRunTimeMetric.cumulativeForegroundEnergy` — fails the gate. Apollo cites both when both are present, with the Power Profiler trace as the explanatory artifact and the field aggregate as the cohort-anchor.

`MXAppRunTimeMetric.cumulativeForegroundEnergy` is the canonical iOS field-energy signal. The brief sometimes asks for "`MXEnergyMetric`" — that class does not exist in MetricKit; the correct API is `MXAppRunTimeMetric.cumulativeForegroundEnergy` normalized by `cumulativeForegroundTime`. Apollo uses the canonical name in every recommendation; a citation to a non-existent symbol fails the gate.

## Signal classes (battery taxonomy)

| Class | What it looks like | Authoritative source | Apollo template |
|---|---|---|---|
| Foreground compute drain | App is open; sustained CPU or GPU activity drives `cumulativeForegroundEnergy` per foreground hour above the cohort baseline; user sees fast battery percentage drop while interacting | Power Profiler `.trace` (CPU + GPU subsystem rows), `MXCPUMetric.cumulativeCPUTime` ÷ `cumulativeForegroundTime`, `MXGPUMetric.cumulativeGPUTime` per fg hour | Power Profiler + Time Profiler |
| Background-task overrun | App is backgrounded but `cumulativeBackgroundTime` energy proxy elevates; `BGProcessingTask` / `BGAppRefreshTask` runs longer or more often than budgeted; silent push (`content-available: 1`) wakes the app and then runs sustained work | Power Profiler trace launched against a `simctl push` scripted wake or `BGTaskScheduler` debug-trigger sequence; `MXCPUExceptionDiagnostic` payloads attributed to background callstacks; ASC Power Metrics row segmented by foreground / background | Power Profiler driven by background-wake script |
| Always-on subsystem drain | An OS subsystem the app activated stays on past the user-facing need: `CLLocationManager` running at high accuracy when not needed, `AVAudioSession` active outside playback, `CBCentralManager` scanning continuously, `UIApplication.shared.isIdleTimerDisabled = true` left set, `CADisplayLink` running while backgrounded | Power Profiler subsystem rows (Location, Audio, Bluetooth, Display) cross-correlated with the lifecycle row; `MXDisplayMetric.averagePixelLuminance` for screen-brightness drain | Power Profiler + Location / Display sub-templates |
| Networking radio drain | Chatty / un-coalesced traffic prevents radio sleep; cellular radio cost dominates because tail-energy fires on every wake; persistent connections poke the radio without batching | Power Profiler `network` row + Network instrument trace (per-connection bytes, RTT, retransmits, TCP / cellular activations), `MXNetworkTransferMetric.cumulativeCellularUpload` / `cumulativeCellularDownload`, ASC Power Metrics network attribution | Power Profiler + Network instrument |

There is **a first-party Instruments template named "Power Profiler"** (Xcode 16+, replaces Energy Log on modern hosts; falls back to Energy Log on older Xcode). Apollo cites Power Profiler as the canonical battery artifact and treats Energy Log as a lower-fidelity fallback. Power Profiler attributes wattage by subsystem (CPU, GPU, display, network, location); recommendations cite the offending subsystem row with the timestamp range that brackets the scenario.

Power Profiler is **real-device only** — the simulator does not measure power and any "battery" capture against a simulator is structurally invalid. The simulator's `Features → Trigger …` toggles are development conveniences, never citable evidence.

`cumulativeForegroundEnergy` resolution: MetricKit emits a daily summary payload with energy normalized to mWh per foreground hour, broken out per build per cohort. The field is **coarse** (one row per app session per device per day) and only stabilizes after ≥ 7 days of post-fix payloads from the same cohort. Apollo's minimum dwell-time and field-window bars per signal class:

| Class | Minimum sustained-capture dwell (reproducible) | Minimum field-window (non-reproducible) |
|---|---|---|
| Foreground compute drain | ≥ 5 minutes Power Profiler under continuous workload (real device only — Energy Gauges live preview is a development convenience, never citable evidence) | ≥ 7 days of `cumulativeForegroundEnergy` payloads from the same cohort post-fix vs pre-fix |
| Background-task overrun | ≥ 10 minutes Power Profiler with at least 3 background-wake events captured in the trace timeline | ≥ 14 days post-fix — background cadence is per-day at most, sample density requires longer windows |
| Always-on subsystem drain | ≥ 5 minutes Power Profiler under the subsystem-active scenario; `MXDisplayMetric.averagePixelLuminance` distribution requires a per-cohort week minimum | ≥ 7 days post-fix MetricKit cadence |
| Networking radio drain | ≥ 5 minutes Power Profiler paired with Network instrument running concurrently; ≥ 10 connection wakes captured in the timeline | ≥ 7 days `MXNetworkTransferMetric` payload window from the same carrier-class cohort |

Any cited capture below the dwell or field-window bar is downgraded to soft evidence and fails the gate. The bars are the load-bearing line that prevents "I ran Power Profiler for 30 seconds and saw the network row spike" from passing as battery evidence — radio tail-energy alone runs longer than that.

## Phase 1 — Diagnose

Goal: classify the signal into one of {foreground compute drain, background-task overrun, always-on subsystem drain, networking radio drain} and pick the matching template + signpost shape. No fix proposed at this phase. Track the reproducible-vs-non-reproducible axis as a second classification — it determines the artifact catalogue Apollo searches in Phase 2.

Inputs Apollo accepts: `MXMetricPayload` JSON, `MXDiagnosticPayload` JSON, ASC Performance / Power Metrics row, `.xcresult` bundle, `.trace` file (Power Profiler / Energy Log / Network / Location / Display sub-template), Energy Gauges screenshot ANNOTATED with a paired scenario name (Energy Gauges alone is soft evidence — see §Failure modes), or a free-text report citing one of those. Free text without a cited artifact triggers auto-capture-before-refuse.

| Diagnostic question | Template | Signpost shape | Citation (passes gate) |
|---|---|---|---|
| Is foreground energy per hour above the cohort baseline? | Power Profiler + Time Profiler | `OSSignposter` interval `<Scenario>` brackets the workload; per-state event payload at lifecycle transitions (`active`, `inactive`, `background`) | Power Profiler `.trace` showing CPU + GPU + display rows at the scenario interval; or `MXAppRunTimeMetric.cumulativeForegroundEnergy` ÷ `cumulativeForegroundTime` p50 / p95 elevated > §Regression detection threshold for ≥ 7 days on cohort `<modelCode>/<osMajor>` |
| Did a backgrounded-app wake exceed its budget? | Power Profiler driven by a background-wake script | `OSSignposter` interval bracketing the `BGTask` body or the silent-push handler; lifecycle event at `applicationDidEnterBackground` / `application(_:didReceiveRemoteNotification:)` | Power Profiler `.trace` capturing ≥ 3 wakes with the bracket signposts visible; or `MXCPUExceptionDiagnostic` callStack attributed to the background entry-point and `MXAppRunTimeMetric.cumulativeBackgroundTime` elevated |
| Is an OS subsystem held active when the user is not engaging it? | Power Profiler + Location / Display / Network sub-template | `OSSignposter` interval brackets the subsystem-active phase (`location-tracking`, `audio-session`, `ble-scan`, `idle-timer-disabled`); event payload at activation / deactivation | Power Profiler `.trace` showing the subsystem row elevated past the active-use signpost; `MXDisplayMetric.averagePixelLuminance` cohort distribution shifted high; ASC Power Metrics row attributing energy to the subsystem |
| Is the radio waking too often or staying awake too long? | Power Profiler + Network instrument | `OSSignposter` interval `<Network-batch>` brackets the request burst; event payload at each `URLSessionTask` `didCompleteWithError` / WS frame boundary | Power Profiler `network` row + Network instrument `.trace` showing RTT-aware connection wake distribution; `MXNetworkTransferMetric.cumulativeCellularUpload` / `cumulativeCellularDownload` carrier-class cohort delta |

The signposts table is enforced — Apollo refuses a battery recommendation whose source lacks an `OSSignposter` anchor for the cited interval. The privacy default (`.private`) silently aggregates `MXSignpostMetric` payloads as opaque, which is the most common silent-bug shape (`apollo/_shared/primitives/signposts.md §Custom metadata`); recommendations that cite an opaque MetricKit aggregation fail the gate.

## Phase 2 — Measure

Goal: produce the cited artifact under the strict-9 catalogue entry the diagnosis demands. Either the user supplied it, an existing capture matches, or auto-capture runs.

Hard-evidence catalogue rows for battery (from `apollo/_shared/primitives/evidence-gate.md §Hard-evidence catalogue`):

| Source | Property / artifact | When to cite |
|---|---|---|
| Power Profiler `.trace` | per-subsystem wattage time series (CPU, GPU, display, network, location, audio, bluetooth) | every signal class — primary reproducible artifact |
| Energy Log `.trace` | legacy energy + state transitions (lower fidelity) | foreground compute drain when Power Profiler unavailable on the host (Xcode < 16) |
| Network instrument `.trace` | per-connection bytes, RTT, retransmits, TCP / cellular activation cadence | networking radio drain (paired with Power Profiler) |
| Location instrument `.trace` | authorization state + activation cadence | always-on subsystem drain (location class) |
| Display instrument `.trace` | brightness time series + screen-on fraction | always-on subsystem drain (display class) |
| Energy Gauges live readout | foreground / background energy gauge per subsystem | preview only — Apollo treats as soft evidence unless paired with a Power Profiler `.trace` of the same scenario |
| `MXAppRunTimeMetric.cumulativeForegroundEnergy` | mWh per session foreground; normalize by `cumulativeForegroundTime` | foreground compute drain — non-reproducible track |
| `MXAppRunTimeMetric.cumulativeBackgroundTime` | seconds in background per day per cohort | background-task overrun — non-reproducible track |
| `MXCPUMetric.cumulativeCPUTime` per foreground hour | normalized CPU-time per hour | foreground compute drain, networking-attributed CPU |
| `MXGPUMetric.cumulativeGPUTime` per foreground hour | normalized GPU-time per hour | foreground compute drain (GPU-shaped) |
| `MXDisplayMetric.averagePixelLuminance` distribution | luminance histogram per cohort week | always-on subsystem drain (display / brightness) |
| `MXNetworkTransferMetric` | `cumulativeWifiUpload` / `cumulativeWifiDownload` / `cumulativeCellularUpload` / `cumulativeCellularDownload` per cohort | networking radio drain |
| `MXDiskIOMetric.cumulativeLogicalWrites` | bytes per foreground hour | always-on subsystem drain (storage); paired with foreground compute when high CPU correlates |
| `MXAnimationMetric.scrollHitchTimeRatio` | hitch ratio per cohort | foreground compute drain (over-rendering proxy) |
| `MXCPUExceptionDiagnostic` payload | callStackTree, `totalCPUTime`, `totalSampledTime` | foreground compute drain, background-task overrun |
| `MXDiskWriteExceptionDiagnostic` payload | callStackTree, `totalWritesCaused` | always-on subsystem drain (storage) |
| ASC Performance / Power Metrics row | per-build aggregate watts per active hour, normalized | every signal class — production fleet read |
| ASC Battery row | drain rate per foreground hour | foreground compute drain — production fleet read |
| ASC Disk Writes row | bytes written per foreground hour | always-on subsystem drain (storage) |

Capture recipes Apollo runs unattended (full table in `apollo/_shared/primitives/instruments-index.md §Capture commands`):

| Class | Recipe |
|---|---|
| Foreground compute drain | `xctrace record --template "Power Profiler" --device "<udid>" --launch -- "<bundle>" --time-limit 300s --output power-foreground.trace` paired with an XcodeBuildMCP-driven scenario that holds the workload at peak for ≥ 5 min; observer-side `OSSignposter` intervals bracket the scenario |
| Background-task overrun | `xctrace record --template "Power Profiler" --device "<udid>" --time-limit 600s --output power-background.trace` paired with `xcrun simctl push <udid> <bundle-id> <silent-payload.json>` for silent-push wakes and `(lldb) e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"<id>"]` for `BGAppRefreshTask` / `BGProcessingTask` wakes (real-device only; `_simulateExpirationForTaskWithIdentifier:` for the expiration path) |
| Always-on subsystem (location) | `xctrace record --template "Power Profiler" --device "<udid>" --launch -- "<bundle>" --time-limit 300s --output power-location.trace` plus a paired Location instrument run (`xctrace record --template "Location"`); scenario script must enter and exit the location-active state with explicit `OSSignposter` events at each boundary |
| Always-on subsystem (audio / BLE / display / idle-timer) | Power Profiler with the matching sub-template (`Display`, or no sub-template for audio / BLE — they appear as Power Profiler subsystem rows directly); `MTL_HUD_ENABLED=1` is **not** a battery probe — it is thermal / GPU surface only |
| Networking radio drain | `xctrace record --template "Power Profiler" --device "<udid>" --launch -- "<bundle>" --time-limit 300s --output power-network.trace` paired concurrently with `xctrace record --template "Network" --device "<udid>" --output network.trace`; both traces cohort-tagged with the carrier class (`MXMetaData.cellularConditionTime` for context); scenario must capture ≥ 10 connection wakes |

Counter routing for Power Profiler subsystem attribution (per `apollo/_shared/primitives/instruments-index.md §Power Profiler`):

| Question | Subsystem row | Citation form |
|---|---|---|
| Is CPU the dominant drain row? | CPU | CPU watts > 50% of total wattage at the scenario interval; cross-cite Time Profiler weighted-self-time at the same interval to attribute to a stack |
| Is GPU / display the dominant drain row? | GPU + Display | GPU + Display watts > 40% of total at the scenario interval; cross-cite Metal HUD log if available; for over-rendering, cite `MXAnimationMetric.scrollHitchTimeRatio` p95 |
| Is the radio the dominant drain row? | Network | Network watts > 25% of total at the scenario interval; cross-cite Network instrument per-connection cadence; tail-energy patterns visible as power-on intervals lasting beyond the last byte transferred |
| Is location / audio / BLE pinning the line? | Location / Audio / Bluetooth | Subsystem watts non-zero across the scenario interval despite the user not engaging the feature; cross-cite the lifecycle signpost showing the subsystem activated and not deactivated |

Companion CLI tools Apollo invokes through the execution surface for ad-hoc analysis on a captured `.trace` or against a paused process:

| Tool | Use | Notes |
|---|---|---|
| `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="power-history"]'` | Extract per-subsystem watts time series from a Power Profiler `.trace` | Apollo cites the exported XML, never the binary `.trace`, when artifact-size budget is tight |
| `xcrun simctl push <udid> <bundle-id> <payload.json>` | Trigger silent-push wake (`{"aps":{"content-available":1}}`) | Real-device version requires APNs path; route through `apollo/_shared/primitives/execution-surface.md §Tool installation contract` when a paired sandbox cert is needed |
| `(lldb) e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"<id>"]` | Trigger a `BGAppRefreshTask` / `BGProcessingTask` wake from a debugger session | Real-device only; pair with a Power Profiler trace already running. The `_simulate*` SPI is documented in WWDC22 10142 and is debugger-only — it does not ship in production builds |
| `powermetrics --samplers thermal,cpu_power,gpu_power -i 1000` | macOS-host power sample stream | **Host-only** — captures the host SoC, not the connected iOS device. Use only when reproducing on Apple Silicon Mac dev hardware; never citable as iOS evidence |
| Energy Gauges (Xcode debug navigator → Energy) | Live foreground / background energy preview | Soft evidence on its own. Apollo cites Energy Gauges only as a triage probe pointing at the next Power Profiler capture — never as the primary artifact for a recommendation |

Failures that classify cleanly:

| Failure | Classification | Apollo action |
|---|---|---|
| Capture path not installed (`xctrace` missing, real device not paired, APNs sandbox cert absent) | permanent | Refuse with explicit unblock recipe; route to human via `apollo/_shared/primitives/execution-surface.md §Tool installation contract` |
| Capture dwell below the §Reproducible vs non-reproducible field-window minimum | ambiguous | Single retry with extended `--time-limit` or deferred-capture row; on second miss, refuse |
| Captured artifact lacks the signpost the diagnosis named | ambiguous | Single retry with corrected scenario script; on second miss, refuse |
| Capture exceeds session budget (Power Profiler runs are minutes-long; background-overrun captures are tens of minutes) | transient | Schedule deferred capture row at `apollo/deferred/<id>.yaml`; refuse for now with `--deferred <id>` resumption recipe |
| Capture against simulator only | permanent | Refuse — simulator does not measure power. The auto-capture decision tree must reach a paired real device or escalate to non-reproducible track |

Phase 2 emits `apollo_capture_started` at scenario start and `apollo_capture_completed` (or `apollo_capture_deferred`) at end. Both events carry `mode: battery`, `class`, `track` (`reproducible` / `non-reproducible`), `artifact_shape`, `cohort`, `scenario`, `dwell_seconds`. The full event set lands in `_shared/contracts/events.md` alongside this mode pack.

## Phase 3 — Propose

Goal: emit a recommendation rooted in the captured artifact, or refuse explicitly. The phase has only two terminal states.

Decision rule:

| Captured evidence | Propose action |
|---|---|
| Hard evidence (9/10) — cited artifact + scenario + cohort + signpost + dwell ≥ §Signal classes minimum (or field window ≥ minimum on the non-reproducible track) — present | Emit `apollo_recommendation` |
| Soft / no evidence after auto-capture-before-refuse exhausts the tree | Emit `apollo_refused` with verbatim refusal block from `evidence-gate.md §Refusal protocol`. The unblock recipes section must list **at minimum**: `Power Profiler trace` (RUN `xctrace record --template "Power Profiler" …`) AND `MXAppRunTimeMetric.cumulativeForegroundEnergy` payload (RUN MetricKit subscription / ASC export). One of those two artifacts is required for any battery fix recommendation |
| Curated canonical anti-pattern matches the diff AND measurement is structurally impossible | Emit `apollo_advisory` with the literal `advisory:1` prefix and zero impact claim — see `apollo/_shared/primitives/canonical-antipatterns.md` |

Recommendation shape — every battery recommendation Apollo writes carries these fields, in this order:

```
RECOMMEND (battery:<class>): <one-line summary>
  evidence: <artifact-path> <citation-form from primitives>
  track: <reproducible | non-reproducible | both>
  scenario: <name>, signpost <name>, cohort <modelCode>/<osMajor>, build <version>, dwell <seconds>s | field-window <days>d
  diff_target: <file:line | symbol> (from Power Profiler / Time Profiler / Network instrument)
  expected_delta: <metric> p<percentile> -<X>% on cohort <modelCode>/<osMajor>
  verification_recipe: <xctrace command> | <XCTest target.method> | <MetricKit field-window resumption>
  patch_owner: achilles  # always — Apollo never patches in-process
```

The `expected_delta` field is load-bearing: it is the criterion the re-measure phase verifies. Battery `expected_delta` cites one of `MXAppRunTimeMetric.cumulativeForegroundEnergy` ÷ `cumulativeForegroundTime` p95 drop, Power Profiler subsystem-watts delta at the cited interval, `MXNetworkTransferMetric.cumulativeCellularUpload` / `cumulativeCellularDownload` per-fg-hour delta, `MXDisplayMetric.averagePixelLuminance` distribution shift, or ASC Power Metrics watts-per-hour drop — never an unattributed "the battery lasts longer" claim.

Mapped fix archetypes per signal class. Apollo cites the archetype, not the intuition; the cited artifact is what supports the choice.

| Class | Archetype | Signal in artifact | Archetype-specific cohort risk |
|---|---|---|---|
| Foreground compute drain | Reduce per-frame work / cap FPS for non-essential animations; pause `CADisplayLink` and reduce timer cadence under `.serious` thermal state (cross-mode coupling with `apollo/modes/thermal.md` §thermalState reaction protocol) | Power Profiler CPU + GPU rows elevated across the scenario interval; `MXAnimationMetric.scrollHitchTimeRatio` p95 high indicating over-rendering | FPS reductions are user-visible; archetype scoped to non-essential / offscreen work |
| Foreground compute drain | Vectorize via Accelerate (vDSP / vForce / BNNS) when the math is SIMD-friendly; replace polling-shaped main loops with notification / observer-driven wakes | Power Profiler CPU row dominates total wattage; Time Profiler weighted-self-time concentrated in scalar floating-point or polling-loop callstacks | Accelerate APIs platform-specific; archetype scoped to iOS / macOS targets that link Accelerate |
| Foreground compute drain | Honor `ProcessInfo.thermalState` observer — drop FPS / pause prefetch on `.serious` (the observer contract is documented in `apollo/modes/thermal.md`; battery and thermal modes share this archetype because thermal-shed reduces both heat and energy) | Power Profiler CPU + GPU rows do not drop after the `.serious` transition signpost in the trace timeline | Throttling user-visible features below `.serious` is too aggressive; archetype scoped to `.serious` / `.critical` shed paths only |
| Background-task overrun | Coalesce work into a single `BGProcessingTask` with `requiresExternalPower = true` (and `requiresNetworkConnectivity` set to actual need); rate-limit silent-push handlers; reduce `BGAppRefreshTask` `earliestBeginDate` cadence | Power Profiler trace shows ≥ 3 background-wake intervals per session; `MXCPUExceptionDiagnostic` callstack rooted in a background entry point; `MXAppRunTimeMetric.cumulativeBackgroundTime` elevated | `requiresExternalPower = true` defers the task indefinitely on always-on-cellular devices; archetype valid only when the work tolerates deferral |
| Background-task overrun | Honor the `BGTask.expirationHandler` cleanly; stop in-flight work on expiration and persist resume state. Bounded background work is a precondition for a battery-correct background contract | Power Profiler trace shows wake intervals that hit the 30-second / 4-minute walltime ceiling; OS terminates with `MXCrashDiagnostic.terminationReason` `0xdead10cc` (background-watchdog) on the cohort | Premature exits drop work; archetype paired with checkpoint / resume on the next launch |
| Always-on subsystem drain | Switch `CLLocationManager` from foreground `.bestForNavigation` / `.best` to `startMonitoringSignificantLocationChanges` or region monitoring when continuous tracking is not required; pause `startUpdatingLocation()` on `applicationDidEnterBackground` unless the app is a documented location-essential app | Power Profiler Location row non-zero across the scenario interval despite the user not engaging the feature; ASC Power Metrics location attribution | Significant-change service has lower fidelity; archetype scoped to use cases where the lower fidelity is acceptable |
| Always-on subsystem drain | Tear down `AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)` when not playing; use `.ambient` category outside playback windows | Power Profiler Audio row non-zero across the scenario interval; lifecycle signpost shows session activated and not deactivated | Tear-down can interrupt other audio apps; archetype paired with category-correct re-activation on the next playback |
| Always-on subsystem drain | Duty-cycle `CBCentralManager.scanForPeripherals(withServices:options:)` — stop scanning between discovery windows; set `CBCentralManagerScanOptionAllowDuplicatesKey: false` (the BLE-spec default) | Power Profiler Bluetooth row non-zero across the scenario interval; trace shows `scanForPeripherals` invoked once and never balanced with `stopScan()` | Discovery latency increases; archetype scoped to scenarios where stable / paired devices are the expectation |
| Always-on subsystem drain | Scope `UIApplication.shared.isIdleTimerDisabled = true` to the active scenario only (set on enter, reset on exit); reset on `applicationDidEnterBackground` | Power Profiler Display row stays elevated past the active-use signpost; `MXDisplayMetric.averagePixelLuminance` p95 high | Scoping must follow the lifecycle deterministically; archetype paired with `applicationWillResignActive` / `applicationDidEnterBackground` reset |
| Networking radio drain | Coalesce HTTP requests; replace polling with push (APNs / `URLSession` with prefer-cached); batch acknowledgements on long-polling endpoints | Power Profiler Network row + Network instrument show ≥ 10 connection wakes per minute with sub-second active windows; `MXNetworkTransferMetric` per-fg-hour elevated relative to bytes transferred | Coalescing increases worst-case latency; archetype scoped to non-realtime traffic |
| Networking radio drain | Use `URLSessionConfiguration.background` with `discretionary = true` for non-urgent uploads; `isDiscretionary` lets the OS schedule transfers when the device is on Wi-Fi and charging | Power Profiler trace shows large transfers on cellular at full radio activation; `MXNetworkTransferMetric.cumulativeCellularUpload` / `cumulativeCellularDownload` dominate vs WiFi counterparts | Discretionary scheduling defers transfers; archetype valid only when the upload is non-urgent |
| Networking radio drain | Replace persistent WebSocket / TCP connections with APNs push or batched poll windows; if the connection is required, set `URLSessionConfiguration.timeoutIntervalForResource` and coalesce keepalive pings | Power Profiler Network row stays elevated across the scenario interval with low byte-rate; tail-energy patterns visible as power-on intervals lasting beyond the last byte transferred | Push-based architectures require server-side cooperation; archetype scoped to client-controlled endpoints |

The Imgly carve-out is firm: Apollo never proposes a specific Metal change for energy. Apollo names "render-pipeline energy regression at <signpost>", attaches the cited evidence, and the Metal/Imgly knowledge lives in the dedicated `imgly-engine-expert` skill via the Stage 3 delegation contract (#233). This keeps Apollo Imgly-agnostic.

## Phase 4 — Patch

Goal: hand the battery recommendation off to Achilles for the in-tree change. Apollo's authority ends at the recommendation artifact; Apollo never edits source.

Handoff record — Apollo persists a recommendation artifact at `~/.dev-studio/<project>/apollo/recommendations/<id>.md` and emits the brief seed on the studio path Chanakya consumes (note the `track`, `dwell_seconds`, and `field_window_days` fields are mandatory for battery handoffs — Achilles needs the track to know which artifact to re-capture and the field-window to know how long to wait before declaring verification):

```yaml
mode: battery
class: <signal-class>
track: <reproducible | non-reproducible | both>
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
  - dwell_seconds: <N>          # reproducible track
  - field_window_days: <N>      # non-reproducible track
```

Achilles owns the patch on a worktree under its standard flow, dispatches Argus under its standard flow, and merges. Apollo never invokes Achilles directly — Chanakya routes the brief seed into a task, and the task threads through the same gates every other Achilles work does.

R17 ownership stays intact: Apollo writes solely under `~/.dev-studio/<project>/apollo/`. The mode pack never reaches `briefs/`, `debriefs/`, the worktree, or task YAML.

## Phase 5 — Re-measure

Goal: confirm the battery regression resolved by re-capturing the matched artifact (same template, scenario, cohort, signpost, **track**, and dwell or field-window) on the patched build, then running the regression-detection math against the pre-fix anchor.

The phase has three terminal states, each emitted as a follow-up event paired with the original `apollo_recommendation` id so the dashboard correlates pre-fix and post-fix outcomes per cohort.

| Outcome | Criterion | Action |
|---|---|---|
| Verified | Post-fix capture's metric crosses the `expected_delta` threshold AND `apollo/_shared/primitives/regression-detection.md §Decision rule` returns `confirmed regression resolved` (significance test passes, sample sizes met, cohort exact, dwell-matched on reproducible track or ≥ field-window minimum on non-reproducible track) | Emit `apollo_recommendation` follow-up with `status: verified`; persist post-fix artifact alongside pre-fix |
| Partial | Post-fix capture moves the metric in the right direction but below the threshold or fails significance | Emit follow-up with `status: partial`; recommendation remains open, Apollo names what additional evidence would close it |
| Regressed | Post-fix capture moves the metric the wrong direction, or a sibling metric (e.g. user-visible latency on a "discretionary upload" archetype, scroll hitch on a "FPS cap" archetype, thermal state on a "spin loop yield" archetype) regressed | Emit follow-up with `status: regressed`; recommendation rolled back; new diagnose phase opens with the post-fix artifact as input |

Verification artifact requirements (R10 sister-rule for Apollo):

| Claim | Required artifact |
|---|---|
| "foreground energy regression resolved" | post-fix Power Profiler `.trace` of the same template + scenario + cohort + dwell as the pre-fix capture, both retained at `apollo/captures/<id>/`; `MXAppRunTimeMetric.cumulativeForegroundEnergy` ÷ `cumulativeForegroundTime` distribution shift attested across ≥ 7 days of post-fix MetricKit payloads from the same cohort |
| "background overrun resolved" | post-fix Power Profiler under matched background-wake script; `MXAppRunTimeMetric.cumulativeBackgroundTime` per-cohort drop ≥ 14 days post-fix; rate of `MXCPUExceptionDiagnostic` payloads attributed to background callstacks dropped |
| "always-on subsystem drain resolved" | post-fix Power Profiler with the matched subsystem sub-template; lifecycle signpost showing the subsystem deactivated on the resign-active boundary; for display class, `MXDisplayMetric.averagePixelLuminance` distribution shift over ≥ 7 days post-fix |
| "networking radio drain resolved" | post-fix Power Profiler + Network instrument paired captures showing reduced connection wake density; `MXNetworkTransferMetric.cumulativeCellularUpload` / `cumulativeCellularDownload` per-fg-hour drop on the same carrier-class cohort over ≥ 7 days |

Apollo refuses any "resolved" claim that lacks a paired post-fix artifact. The pre-fix artifact stays retained — it is the audit trail.

## Background-activity drain checklist

Cross-cutting checklist Apollo applies during diagnose for any signal class where the app is non-foreground or driving an OS subsystem. Each item names the canonical anti-pattern row (when one exists) and the artifact that resolves the magnitude.

| Subsystem | Diagnose probe | Anti-pattern row | Resolving artifact |
|---|---|---|---|
| Location | Is `CLLocationManager` configured at `.bestForNavigation` / `.best` and running while not user-engaged? | `batt:01` | Power Profiler Location row + ASC Power Metrics location attribution |
| Network | Is HTTP polling cadence sub-minute or are persistent connections un-coalesced? | `batt:02`, `batt:03` | Power Profiler Network row + Network instrument |
| Timer | Is `Timer.scheduledTimer` / `CADisplayLink` active during `applicationDidEnterBackground`? | `batt:04` | Power Profiler CPU row across the background interval; lifecycle signpost showing no pause |
| BLE | Is `CBCentralManager.scanForPeripherals` running continuously without duty cycling? | `batt:05` | Power Profiler Bluetooth row + paired BLE event log |
| Push | Is silent push (`content-available: 1`) used to schedule in-app work without rate limiting or coalescing? | `batt:09` (when curated) | Power Profiler driven by `simctl push` script; `MXAppRunTimeMetric.cumulativeBackgroundTime` per-cohort delta |

The checklist is not the gate — every item still requires the resolving artifact before a recommendation ships. Pure-pattern matches without the artifact emit `advisory:1` only.

## Cohort and noise control

Battery measurements perturb under charging state, ambient temperature, OS minor differences, SoC variant, carrier class, and screen brightness. Apollo discards a captured run from regression math when:

| Condition | Source | Why |
|---|---|---|
| `MXMetaData.batteryChargingState != .unplugged` for the capture window | `MXMetaData` | Charging masks drain entirely — power flows in, not out |
| `MXMetaData.thermalState` already `.serious` at scenario start | `MXMetaData` | Pre-warmed device throttles the workload, biasing CPU / GPU subsystem rows downward |
| First minute after launch | XCTest options | Code-signing + first-launch warmup is not the regression — Apollo trims the leading 60 s |
| Cohort tag mismatch between pre-fix and post-fix capture (`MXMetaData.deviceType` / `LocalComputer.modelCode`) | `MXMetaData` / LocalComputer | Apple Silicon variants drain differently per chip — A15 vs A17 Pro vs A18 cannot be cross-compared |
| Carrier-class mismatch on networking-class captures (`MXMetaData.cellularConditionTime` distribution differs) | `MXMetaData` | Cellular drain depends on radio condition; pre-fix on full-bars vs post-fix on edge-coverage hides the regression |
| Screen brightness mismatch on display-class captures (manual annotation only — Apple does not expose brightness in `MXMetaData`) | manual annotation | Display energy scales with brightness; cross-brightness comparisons are noise |
| Dwell-time or field-window mismatch between pre-fix and post-fix capture | trace metadata / MetricKit window | Drain curves are non-linear with dwell; comparing 60 s vs 300 s captures hides the regression in the dwell delta. Field windows shorter than the §Reproducible vs non-reproducible minimum are downgraded to soft evidence |

Apollo emits `apollo_capture_completed` with `discarded: true` and the reason; the run is not used in the gate but is retained for forensic review.

## Failure modes

| Failure | Classification | Apollo action |
|---|---|---|
| Free-text "the battery drains fast" with no artifact, no reachable capture path | permanent | Refuse with verbatim refusal block; name the human-required action (real-device pairing, TestFlight install, dSYM upload, MetricKit subscription enable). The unblock recipes list `Power Profiler trace` and `MXAppRunTimeMetric.cumulativeForegroundEnergy` payload as the two acceptance forms |
| Soft evidence — Energy Gauges screenshot only, no paired Power Profiler trace | permanent | Refuse; Energy Gauges live readout is preview-only. Auto-capture Power Profiler via xctrace if a real device is paired |
| Capture produced but `OSSignposter` anchor missing | ambiguous | One retry with corrected scenario script; on second miss, escalate via `apollo_refused` with `reason: signpost_missing` |
| Capture produced on simulator only (no real-device pairing) | permanent | Refuse for every signal class — simulator does not measure power. Auto-capture decision tree must reach a paired real device or escalate to non-reproducible track via MetricKit |
| Capture dwell below the §Reproducible vs non-reproducible minimum | ambiguous | One retry with extended `--time-limit`; on second miss, refuse with `reason: dwell_below_threshold` |
| Field window < 7 days on non-reproducible track | permanent | Refuse cohort comparison; defer with a deferred-capture row keyed to the next MetricKit cadence boundary |
| `MXAppRunTimeMetric.cumulativeForegroundEnergy` field is null (iOS < 14) | permanent | Refuse on the non-reproducible track; cite the iOS-version cohort gap and downgrade to ASC Power Metrics row only |
| MetricKit `pastPayloads` empty (fresh install, no prior daily delivery) | transient | Defer — schedule capture for ≥ 24 h, refuse for now with `--deferred <id>`. MetricKit's daily cadence is documented in `apollo/_shared/primitives/metrickit.md §Subscription lifecycle` |
| Capture path autonomy is `human-required` (real-device pairing, sandbox APNs cert install, ASC dSYM upload) | permanent | Refuse with the explicit human-action block; never silently fall through |
| dSYM mismatch on symbolication of an `MXCPUExceptionDiagnostic` payload | ambiguous | Single retry against ASC dSYM fetch; on miss, refuse with `reason: dsym_uuid_mismatch` and the offending UUID |
| Charging state masking the capture window | permanent | Refuse cross-charging comparison; cite §Cohort and noise control. Re-run on an unplugged device |
| Argus-flagged finding on the patch references a battery regression Apollo did not capture pre-fix | permanent | Refuse the verification claim; open a new Phase-1 diagnose against the post-fix capture as the pre-fix anchor for the next iteration |
| Citation names `MXEnergyMetric` (a non-existent MetricKit symbol) | permanent | Refuse with `reason: api_does_not_exist`; correct citation is `MXAppRunTimeMetric.cumulativeForegroundEnergy`. The gate exists to prevent hallucinated symbol citations |

The `## Failure modes` table is the procedure-level enforcement: classifications drive whether Apollo retries (`transient`), refuses (`permanent`), or escalates per the auto-capture decision tree (`ambiguous`).

## Procedure

The five-phase pipeline rendered as enforceable steps. Each step gates the transition into the next phase; gate failure routes through the auto-capture decision tree before any refusal.

1. **READ** the input artifact and classify the signal into one of {foreground compute drain, background-task overrun, always-on subsystem drain, networking radio drain}; classify the track as reproducible or non-reproducible.
   Before: caller invocation specifies one of `/apollo battery`, a cited `.trace` / `MXMetricPayload` / `MXDiagnosticPayload`, or free text mentioning battery / drain / energy.
   After: signal class and track recorded; matching diagnostic-question row from §Phase 1 selected; mode-pack progress event emitted with `mode: battery`, `class`, `track`.

2. **CHECK** the strict-9 hard-evidence catalogue for the captured artifact named by the diagnosis, including the §Reproducible vs non-reproducible dwell or field-window minimum.
   Before: signal class and track set in step 1; capture-set inventory at `apollo/captures/` enumerated.
   After: either the cited artifact is on disk and meets the dwell / field-window bar (proceed to step 4) or the auto-capture decision tree from `apollo/_shared/primitives/execution-surface.md §Auto-capture-before-refuse decision tree` runs in step 3.

3. **RUN** the matching capture recipe from §Phase 2 unattended through the execution surface, holding the workload at peak for the dwell minimum (reproducible track) or scheduling a deferred-capture row (non-reproducible track).
   Before: capability matrix entry for the recipe is `installed: true` per `~/.dev-studio/.runtime/host-capabilities.yaml`; a real device is paired (battery is real-device-only across every class — simulator captures are permanent failure); the scenario script brackets the workload with `OSSignposter` intervals and emits per-lifecycle-transition signposts; for background-overrun captures, `simctl push` payload or `(lldb) BGTaskScheduler` invocation is staged.
   After: artifact persisted at `apollo/captures/<id>/`; `apollo_capture_completed` event emitted with `cohort`, `scenario`, `signpost`, `artifact_shape`, `track`, `dwell_seconds`; cohort/noise gates from §Cohort and noise control evaluated; runs marked `discarded: true` are not consumed downstream.

4. **CHECK** that the captured evidence satisfies the strict-9 fields {artifact, scenario, signpost, cohort, build, dwell or field-window}; if any missing, RETRY step 3 once with corrected scenario script or extended `--time-limit`.
   Before: artifact persisted from step 3 (or pre-existing).
   After: gate state ∈ {hard, soft, none, advisory}. Hard advances to step 5; soft and none route through `apollo/_shared/primitives/evidence-gate.md §Refusal protocol` with the battery-specific unblock recipes (Power Profiler trace, `MXAppRunTimeMetric.cumulativeForegroundEnergy` payload); advisory:1 emits `apollo_advisory` and STOPs without a recommendation.

5. **WRITE** the recommendation artifact at `apollo/recommendations/<id>.md` with the field set from §Phase 3 (evidence, track, scenario, diff_target, expected_delta, verification_recipe, patch_owner).
   Before: gate=hard from step 4; archetype selected from §Phase 3 archetype table; Metal-archetype recommendations delegated to the `imgly-engine-expert` skill instead of in-line.
   After: `apollo_recommendation` event emitted; brief seed YAML written for Chanakya consumption.

6. **RECORD** the handoff to Achilles per §Phase 4; Apollo does NOT mutate the worktree, briefs, or task YAML.
   Before: recommendation artifact written from step 5.
   After: brief seed available on the studio path; R17 ownership preserved (no writes outside `apollo/`); event log carries the recommendation id for cross-agent correlation.

7. **RUN** the post-fix capture using the same template, scenario, cohort, signpost, track, and dwell or field-window as the pre-fix capture from step 3.
   Before: Achilles task closed, Argus verdict approved, merge SHA recorded on the recommendation; the verification recipe from step 5 is reproducible.
   After: post-fix artifact persisted at `apollo/captures/<id>/post-fix/`; cohort + dwell or field-window tags verified to match pre-fix exactly per `apollo/_shared/primitives/regression-detection.md §Cohort normalization`.

8. **EMIT** the verification verdict per §Phase 5 outcome table (`verified` / `partial` / `regressed`) using `apollo/_shared/primitives/regression-detection.md §Decision rule`.
   Before: pre-fix and post-fix artifacts cohort-, track-, and dwell-matched; sample-size minimums met for the cited percentile; ≥ 7 days of post-fix MetricKit `MXAppRunTimeMetric.cumulativeForegroundEnergy` payloads available when the claim cites field energy (≥ 14 days for background-overrun claims).
   After: follow-up `apollo_recommendation` event with `status: <outcome>` emitted; pre-fix and post-fix artifacts both retained; on `regressed` outcome a fresh Phase-1 diagnose opens with the post-fix capture as input.

## Handoffs

| Direction | Surface | Contract |
|---|---|---|
| → Achilles (patch) | `~/.dev-studio/<project>/apollo/recommendations/<id>.md` + brief seed | Recommendation contains `track`, `diff_target`, `expected_delta`, `verification_recipe`, `dwell_seconds` (reproducible) or `field_window_days` (non-reproducible). Achilles applies the patch on a worktree, runs Argus per its normal flow, and merges. Apollo never invokes Achilles directly — Chanakya routes the brief. |
| → Argus (review) | None directly. | Apollo's recommendation artifact is read-only context for Argus during code review. Argus does not write Apollo state. |
| → imgly-engine-expert (Metal/Imgly archetypes) | `delegate: imgly-engine-expert` line on the recommendation when the diff target is in Imgly / Metal pipeline code | Stage 3 deliverable (#233). Until #233 ships, Apollo refuses Metal-internal recommendations and emits `advisory:1` with the canonical-antipattern citation only. |
| → thermal mode (cross-mode coupling) | Apollo annotates the recommendation with `cross_mode: thermal` when the archetype is shared (FPS cap, observer contract, spin-loop yield) | Both modes' verification recipes run; a battery-only verification that ignores a thermal regression is a soft-evidence finding under §Phase 5 outcome table |

## Singleton

Battery mode acquires `simulator-{udid}` (only for non-power adjacent traces — battery captures themselves never use simulator), `xctrace-{device}`, and `real-device-{udid}` locks at step 3 entry; releases on step 3 completion. Foreground compute and background-overrun captures hold the real-device lock for the full dwell minimum (≥ 5 min foreground, ≥ 10 min background) — concurrent battery investigations on the same device collide on the lock, not silently corrupt each other's traces. Cross-mode (memory + thermal + battery on different devices) does not collide. Lock surface lives at `~/.dev-studio/.runtime/locks/apollo/`.

## Why this shape

The five-phase pipeline maps directly onto battery's four signal classes and the strict-9 evidence catalogue. Each phase has exactly one gate — the captured artifact, the cohort + dwell or field-window match, the expected delta, the post-fix verification — and each gate has a documented refusal path. Without that explicit gating, battery recommendations regress to "the device drains fast, optimize something", which is the failure mode the strict-9 contract exists to prevent (see `evidence-gate.md §Why`).

The reproducible-vs-non-reproducible split is the second load-bearing invariant. Battery is the only P0 mode where field-only signal is common — most drain regressions surface in `MXAppRunTimeMetric.cumulativeForegroundEnergy` distributions long before any developer can reproduce them on-bench. Conflating the two tracks (citing a Power Profiler trace for a regression that only shows in field aggregates, or vice versa) yields recommendations that don't survive verification. The split forces Apollo to name which artifact catalogue applies and to wait for the field-window when the track demands it.

The Power Profiler dependency is the third invariant. Energy Log is a fallback, Energy Gauges is preview-only, and `powermetrics` is host-side. Power Profiler (Xcode 16+, real-device-only) is the canonical iOS battery template — recommendations cite the offending subsystem row with the timestamp range that brackets the scenario. The simulator carve-out is firm: simulator does not measure power, and any "battery" capture against a simulator is structurally invalid.

The Imgly carve-out matches thermal mode. Imgly knowledge lives in the dedicated `imgly-engine-expert` skill; Apollo retains measurement and verification authority. The Stage 3 delegation contract (#233) formalizes the boundary; until it ships, Apollo refuses to bake Metal internals into this mode pack.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract + refusal protocol the phase gates feed into
- `apollo/_shared/primitives/metrickit.md` — `MXAppRunTimeMetric`, `MXCPUMetric`, `MXGPUMetric`, `MXDisplayMetric`, `MXNetworkTransferMetric`, `MXDiskIOMetric`, `MXAnimationMetric`, `MXCPUExceptionDiagnostic`, `MXDiskWriteExceptionDiagnostic` schemas
- `apollo/_shared/primitives/signposts.md` — `OSSignposter` shape + privacy default the signal table enforces
- `apollo/_shared/primitives/instruments-index.md` — Power Profiler / Energy Log / Network / Location / Display details + capture commands
- `apollo/_shared/primitives/xctest-baselines.md` — `XCTOSSignpostMetric` + `XCTCPUMetric` baselines for the dev-loop signal
- `apollo/_shared/primitives/regression-detection.md` — battery-specific cohort + carrier + dwell rules; energy curve handling
- `apollo/_shared/primitives/organizer-asc.md` — Performance / Power / Battery / Disk Writes Metrics rows on the production fleet
- `apollo/_shared/primitives/execution-surface.md` — capability matrix + auto-capture decision tree (real-device pairing, APNs sandbox cert as `human-required`)
- `apollo/_shared/primitives/canonical-antipatterns.md` — battery antipatterns curated for the `advisory:1` channel (`batt:NN` rows)
- `apollo/modes/thermal.md` — cross-mode coupling for shared archetypes (thermalState observer, FPS cap, spin-loop yield)
- `_shared/contracts/events.md` — `apollo_capture_*` and `apollo_recommendation` event schemas
- `REVIEW.md` R10 — sister rule for completion claims; Apollo's verification phase is the battery-mode counterpart
- `MXAppRunTimeMetric.cumulativeForegroundEnergy` — Apple Developer reference for the canonical field energy signal
- `BGTaskScheduler` + `BGAppRefreshTaskRequest` + `BGProcessingTaskRequest` — Apple Developer reference for the background contract
- WWDC25 226 — Profile and optimize power usage in your app (canonical for the reproducible-vs-non-reproducible split + Power Profiler workflow)
- WWDC22 10083 — Power down: Improve battery consumption
- WWDC22 10142 — Efficiency awaits: Background tasks in SwiftUI (BGTaskScheduler debug-trigger SPI)
- WWDC21 10087 — Diagnose Power and Performance regressions
- WWDC21 10212 — Analyze HTTP traffic in Instruments (radio tail-energy + connection wake costs)
- WWDC19 417 — Improving Battery Life and Performance
- Apple "Measuring your app's power use with Power Profiler" — Apple Developer guide
- Apple Energy Efficiency Guide for iOS Apps — high-QoS / busy-wait / location accuracy / radio coalescing guidance
