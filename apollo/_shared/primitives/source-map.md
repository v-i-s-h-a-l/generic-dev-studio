---
name: Apollo source map
description: Curated Apple documentation, WWDC, and local primitive map for Apollo mode packs and planned CPU mode work.
type: reference
schema_version: 1
---

# Apollo source map

This map is the citation index for Apollo. Mode packs cite source-map row IDs when they need Apple or local authority, then cite the local primitive for the operational contract. The rows classify each source by the Apollo behavior it supports:

- `capture recipe` — which artifact to collect and with which template / workflow
- `evidence gate` — which artifact fields must be present before Apollo recommends
- `diagnosis taxonomy` — how Apollo classifies the signal
- `fix archetype` — which family of remediation the source justifies
- `verification` — how Apollo proves the fix after patching
- `human-guided collection` — collection that Apollo can request but not fully automate

## Mode row index

| Mode | Source-map rows |
|---|---|
| memory | `SRC-MEM-HEAP-WWDC24-10173`, `SRC-MEM-DIAG-WWDC21-10180`, `SRC-MEM-FOOTPRINT-WWDC18-416`, `SRC-MEM-SWIFT-WWDC25-312`, `SRC-INST-BASE-WWDC19-411`, `SRC-INST-CUSTOM-WWDC18-410`, `SRC-METRICKIT-WWDC20-10081`, `SRC-ORG-WWDC21-10087`, `SRC-XCT-PERF` |
| thermal | `SRC-THERM-API`, `SRC-CPU-WWDC25-308`, `SRC-CPU-PTRACE-DOC`, `SRC-CPU-BOTTLENECKS-DOC`, `SRC-CPU-TUNING-DOC`, `SRC-CPU-GUIDE-V4`, `SRC-HANGS-WWDC22-10082`, `SRC-ORG-WWDC21-10087`, `SRC-METRICKIT-WWDC20-10081`, `SRC-INST-BASE-WWDC19-411`, `SRC-INST-CUSTOM-WWDC18-410` |
| battery | `SRC-BATT-WWDC25-226`, `SRC-BATT-POWER-PROFILER-DOC`, `SRC-ORG-WWDC21-10087`, `SRC-BATT-WWDC22-10083`, `SRC-BATT-BG-WWDC22-10142`, `SRC-NET-WWDC21-10212`, `SRC-METRICKIT-WWDC20-10081`, `SRC-XCT-PERF` |
| cpu (planned) | `SRC-CPU-WWDC25-308`, `SRC-CPU-PTRACE-DOC`, `SRC-CPU-BOTTLENECKS-DOC`, `SRC-CPU-TUNING-DOC`, `SRC-CPU-GUIDE-V4`, `SRC-XCT-CPU-DOC`, `SRC-HANGS-WWDC22-10082`, `SRC-METRICKIT-WWDC20-10081`, `SRC-ORG-WWDC21-10087`, `SRC-INST-BASE-WWDC19-411` |
| network | `SRC-NET-HTTP-INST-DOC`, `SRC-NET-WWDC21-10212`, `SRC-NET-MXNETWORK-DOC`, `SRC-NET-MXCELLULAR-DOC`, `SRC-NET-URLSESSIONTASKMETRICS-DOC`, `SRC-NET-ASC-POWER-DOC`, `SRC-SYSTEM-TRACE`, `SRC-INST-BASE-WWDC19-411`, `SRC-METRICKIT-WWDC20-10081` |

## Apple and WWDC rows

| Row ID | Source | Link | Supports | Local primitive / mode pack | Notes |
|---|---|---|---|---|---|
| `SRC-MEM-HEAP-WWDC24-10173` | WWDC24 10173, "Analyze heap memory" | https://developer.apple.com/videos/play/wwdc2024/10173/ | capture recipe; diagnosis taxonomy; fix archetype; verification | `apollo/modes/memory.md`; `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/regression-detection.md` | Verified 2026-05-02. Authoritative for heap vs footprint framing, transient growth, persistent growth, leaks, Allocations, VM Tracker, Memory Graph Debugger, MallocStackLogging, and autorelease pool growth. |
| `SRC-MEM-DIAG-WWDC21-10180` | WWDC21 10180, "Detect and diagnose memory issues" | https://developer.apple.com/videos/play/wwdc2021/10180/ | capture recipe; evidence gate; verification | `apollo/modes/memory.md`; `apollo/_shared/primitives/metrickit.md`; `apollo/_shared/primitives/xctest-baselines.md` | Verified 2026-05-02. Supports MetricKit memory payloads, XCTest memory regression checks, and `.memgraph` / memory graph investigation. |
| `SRC-MEM-FOOTPRINT-WWDC18-416` | WWDC18 416, "iOS Memory Deep Dive" | https://developer.apple.com/videos/play/wwdc2018/416/ | diagnosis taxonomy; evidence gate; fix archetype | `apollo/modes/memory.md`; `apollo/_shared/primitives/regression-detection.md`; `apollo/_shared/primitives/instruments-index.md` | Verified 2026-05-02. Supports footprint vs dirty / compressed / clean memory, image memory cost, VM Tracker, `vmmap`, `heap`, `leaks`, and `malloc_history`. |
| `SRC-MEM-SWIFT-WWDC25-312` | WWDC25 312, "Improve memory usage and performance with Swift" | https://developer.apple.com/videos/play/wwdc2025/312/ | fix archetype; verification | `apollo/modes/memory.md`; `apollo/_shared/primitives/canonical-antipatterns.md` | Verified 2026-05-02. Preserved as the Swift memory-performance source for ARC / refcount overhead and Swift-specific memory remediation planning. |
| `SRC-THERM-API` | Apple Developer Documentation, `ProcessInfo.thermalState` and `thermalStateDidChangeNotification` | https://developer.apple.com/documentation/foundation/processinfo/thermalstate | evidence gate; diagnosis taxonomy; fix archetype; verification | `apollo/modes/thermal.md`; `apollo/_shared/primitives/signposts.md` | Canonical observer contract. Apollo citations must pair the state transition with a public signpost and cohort. |
| `SRC-BATT-WWDC25-226` | WWDC25 226, "Profile and optimize power usage in your app" | https://developer.apple.com/videos/play/wwdc2025/226/ | capture recipe; evidence gate; diagnosis taxonomy; fix archetype; verification; human-guided collection | `apollo/modes/battery.md`; `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/organizer-asc.md` | Verified 2026-05-02. Canonical for Power Profiler, reproducible vs field-only power issues, on-device Performance Trace collection, Xcode Energy Gauges, XCTest, Organizer, MetricKit, and App Store Connect API coverage. |
| `SRC-BATT-POWER-PROFILER-DOC` | Apple Developer Documentation, "Measuring your app's power use with Power Profiler" | https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler | capture recipe; verification; human-guided collection | `apollo/modes/battery.md`; `apollo/_shared/primitives/instruments-index.md` | Verified 2026-05-02. Supports pairing Power Profiler with CPU Profiler, Processor Trace, CPU Counters, Metal debugging, Network / HTTP Traffic instruments, and repeated before / after captures. |
| `SRC-BATT-WWDC22-10083` | WWDC22 10083, "Power down: Improve battery consumption" | https://developer.apple.com/videos/play/wwdc2022/10083/ | diagnosis taxonomy; fix archetype | `apollo/modes/battery.md`; `apollo/_shared/primitives/canonical-antipatterns.md` | Preserved as the battery-efficiency source for system-subsystem drain patterns. Verify page title before adding new row details. |
| `SRC-BATT-BG-WWDC22-10142` | WWDC22 10142, "Efficiency awaits: Background tasks in SwiftUI" | https://developer.apple.com/videos/play/wwdc2022/10142/ | fix archetype; verification; human-guided collection | `apollo/modes/battery.md`; `apollo/_shared/primitives/canonical-antipatterns.md` | Preserved for `BGTaskScheduler`, background refresh / processing task cadence, and background overrun checks. Verify API names before adding new background-task mode fields. |
| `SRC-NET-WWDC21-10212` | WWDC21 10212, "Analyze HTTP traffic in Instruments" | https://developer.apple.com/videos/play/wwdc2021/10212/ | capture recipe; diagnosis taxonomy; fix archetype; verification | `apollo/modes/network.md`; `apollo/modes/battery.md`; `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Canonical WWDC source for the Instruments Network template, HTTP Traffic instrument, URLSession / task / transaction visualization, request fan-out, blocked transaction diagnosis, cache behavior, HTTP protocol comparison, and trace privacy warning. |
| `SRC-NET-HTTP-INST-DOC` | Apple Developer Documentation, "Analyzing HTTP traffic with Instruments" | https://developer.apple.com/documentation/foundation/analyzing-http-traffic-with-instruments | capture recipe; evidence gate; diagnosis taxonomy; human-guided collection | `apollo/modes/network.md`; `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Primary documentation for selecting the Network template, recording HTTP Traffic, and treating traces as sensitive because HTTP contents may be stored in trace artifacts and logs. |
| `SRC-NET-MXNETWORK-DOC` | Apple Developer Documentation, `MXNetworkTransferMetric` | https://developer.apple.com/documentation/metrickit/mxnetworktransfermetric | evidence gate; verification | `apollo/modes/network.md`; `apollo/modes/battery.md`; `apollo/_shared/primitives/metrickit.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Exact MetricKit class for cumulative Wi-Fi and cellular upload / download transfer evidence, including `cumulativeWifiUpload`, `cumulativeWifiDownload`, `cumulativeCellularUpload`, and `cumulativeCellularDownload`. |
| `SRC-NET-MXCELLULAR-DOC` | Apple Developer Documentation, `MXCellularConditionMetric` | https://developer.apple.com/documentation/metrickit/mxcellularconditionmetric | evidence gate; verification | `apollo/modes/network.md`; `apollo/modes/battery.md`; `apollo/_shared/primitives/metrickit.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Exact MetricKit class for cellular-condition context via `histogrammedCellularConditionTime`; required when a cellular network or radio-drain claim depends on carrier / signal quality. |
| `SRC-NET-URLSESSIONTASKMETRICS-DOC` | Apple Developer Documentation, `URLSessionTaskMetrics` and `URLSessionTaskTransactionMetrics` | https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics | evidence gate; verification; diagnosis taxonomy | `apollo/modes/network.md`; `apollo/_shared/primitives/signposts.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Primary API source for task intervals, redirect counts, and per-request / response transaction timing collected by the URL Loading System during a session task; valid only when Apollo captures it under a named signposted scenario. |
| `SRC-NET-ASC-POWER-DOC` | Apple Developer Documentation, App Store Connect API "Power and Performance Metrics and Logs" | https://developer.apple.com/documentation/appstoreconnectapi/power-and-performance-metrics-and-logs | evidence gate; verification; human-guided collection | `apollo/modes/network.md`; `apollo/_shared/primitives/organizer-asc.md`; `apollo/_shared/primitives/evidence-gate.md` | Verified 2026-05-03. Primary ASC API source for power and performance metrics / diagnostics by app or build. Network mode may cite ASC rows only when the response artifact names the metric category, cohort, build, window, aggregate / percentile, and baseline. |
| `SRC-ORG-WWDC21-10087` | WWDC21 10087, "Diagnose Power and Performance regressions in your app" | https://developer.apple.com/videos/play/wwdc2021/10087/ | evidence gate; diagnosis taxonomy; verification; human-guided collection | `apollo/_shared/primitives/organizer-asc.md`; `apollo/_shared/primitives/regression-detection.md` | Verified 2026-05-02. Canonical for Xcode Organizer reports, device / percentile regressions, App Store Connect `perfPowerMetrics`, and diagnostic-signature workflows. |
| `SRC-METRICKIT-WWDC20-10081` | WWDC20 10081, "What's new in MetricKit" | https://developer.apple.com/videos/play/wwdc2020/10081/ | evidence gate; verification; human-guided collection | `apollo/_shared/primitives/metrickit.md`; `apollo/_shared/primitives/evidence-gate.md` | Preserved for MetricKit payload and diagnostic delivery cadence. Verify newly cited MetricKit symbols against Apple docs before adding them. |
| `SRC-XCT-PERF` | Apple Developer Documentation, XCTest performance measurement APIs | https://developer.apple.com/documentation/xctest | evidence gate; verification | `apollo/_shared/primitives/xctest-baselines.md`; all P0 modes | Preserved for `measure(metrics:options:block:)`, baseline bundles, `.xcresult` extraction, and `XCTMetric` catalogue routing. |
| `SRC-INST-BASE-WWDC19-411` | WWDC19 411, "Getting Started with Instruments" | https://developer.apple.com/videos/play/wwdc2019/411/ | capture recipe; diagnosis taxonomy | `apollo/_shared/primitives/instruments-index.md`; all P0 modes | Verified 2026-05-02. Supports template selection, Time Profiler, Points of Interest, and Instruments workflow basics. |
| `SRC-INST-CUSTOM-WWDC18-410` | WWDC18 410, "Creating Custom Instruments" | https://developer.apple.com/videos/play/wwdc2018/410/ | capture recipe; diagnosis taxonomy; human-guided collection | `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/signposts.md` | Verified 2026-05-02. Preserved for custom instrument and model guidance. |
| `SRC-HANGS-WWDC22-10082` | WWDC22 10082, "Track down hangs with Xcode and on-device detection" | https://developer.apple.com/videos/play/wwdc2022/10082/ | evidence gate; diagnosis taxonomy; verification; human-guided collection | `apollo/modes/thermal.md`; planned CPU mode; `apollo/_shared/primitives/metrickit.md` | Verified 2026-05-02. Correct row for Hangs, Xcode Organizer hang reports, MetricKit hang diagnostics, Thread Performance Checker, and on-device hang detection. |
| `SRC-STALE-WWDC22-110340` | Stale alias: previously used as "Track down hangs with Xcode and on-device detection" | https://developer.apple.com/videos/play/wwdc2022/110340/ | stale-reference check | n/a | Verified 2026-05-02 as "Design an effective chart." Do not cite this row for Apollo hangs / thermal / CPU work; use `SRC-HANGS-WWDC22-10082`. This row preserves the old ID so stale references are searchable. |

## CPU planning rows

| Row ID | Source | Link | Supports | Planned CPU-mode use | Local primitive |
|---|---|---|---|---|---|
| `SRC-CPU-WWDC25-308` | WWDC25 308, "Optimize CPU performance with Instruments" | https://developer.apple.com/videos/play/wwdc2025/308/ | capture recipe; evidence gate; diagnosis taxonomy; fix archetype; verification | CPU Profiler before Time Profiler for CPU optimization; Processor Trace for exact function-call / retired-instruction flow; CPU Counters bottleneck analysis for instruction delivery, instruction processing, discarded work, cache, branch, and IPC findings; signposted test harness as the repeatable workload. | `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/signposts.md`; `apollo/_shared/primitives/xctest-baselines.md` |
| `SRC-CPU-PTRACE-DOC` | Apple Developer Documentation, "Analyzing CPU usage with the Processor Trace instrument" | https://developer.apple.com/documentation/xcode/analyzing-cpu-usage-with-processor-trace | capture recipe; evidence gate; diagnosis taxonomy; verification | Processor Trace `.trace` hard-evidence row, hardware support gate, dSYM requirement, function-call views, IPC / cycles / instructions, and short-window capture constraints. | `apollo/_shared/primitives/instruments-index.md`; planned CPU mode |
| `SRC-CPU-BOTTLENECKS-DOC` | Apple Developer Documentation, "Addressing CPU bottlenecks" | https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks | diagnosis taxonomy; fix archetype; verification | CPU Counters `CPU Bottlenecks` mode, Useful / Instruction Delivery / Instruction Processing / Discarded categories, Suggested Next workflow, `OSSignposter` anchors, and post-fix CPU Counters validation. | `apollo/_shared/primitives/instruments-index.md`; `apollo/_shared/primitives/regression-detection.md`; planned CPU mode |
| `SRC-CPU-TUNING-DOC` | Apple Developer Documentation, "Tuning your code's performance for Apple silicon" | https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon | fix archetype; verification | QoS-to-P/E-core scheduling, dynamic work allocation, GCD / Swift concurrency preference, avoiding spin waits, work granularity, and hardware-cohort verification. | `apollo/modes/thermal.md`; planned CPU mode |
| `SRC-CPU-GUIDE-V4` | Apple Developer Documentation, "Apple Silicon CPU Optimization Guide Version 4" | https://developer.apple.com/documentation/apple-silicon/cpu-optimization-guide | diagnosis taxonomy; fix archetype; verification | Microarchitecture, CPU / cache topology, performance-monitoring events, latency / bandwidth tables, instruction sequences, and architecture-specific fix validation. | planned CPU mode |
| `SRC-XCT-CPU-DOC` | Apple Developer Documentation, `XCTCPUMetric` | https://developer.apple.com/documentation/xctest/xctcpumetric | evidence gate; verification | XCTest CPU metric baseline: CPU time, cycles, and instructions retired for deterministic pre-merge checks. | `apollo/_shared/primitives/xctest-baselines.md`; planned CPU mode |
| `SRC-SYSTEM-TRACE` | Apple Instruments System Trace template | n/a | capture recipe; diagnosis taxonomy | Scheduling, lock contention, blocking syscalls, and off-CPU time. CPU mode must route here when Time / CPU Profiler shows wait time rather than on-CPU inefficiency. | `apollo/_shared/primitives/instruments-index.md`; planned CPU mode |
| `SRC-TIME-PROFILER` | Apple Instruments Time Profiler template | n/a | capture recipe; diagnosis taxonomy; verification | Broad sampled call-stack attribution, hang correlation, and sibling context. CPU mode treats this as a starting point or supporting artifact, while `SRC-CPU-WWDC25-308` prefers CPU Profiler for CPU-specific optimization. | `apollo/_shared/primitives/instruments-index.md`; planned CPU mode |

## CPU mode source requirements

CPU mode is not implemented yet. When it is added, its mode pack MUST cite these source-map rows rather than embedding a fresh long reference list:

| Required artifact / workflow | Required rows | Gate note |
|---|---|---|
| CPU Profiler | `SRC-CPU-WWDC25-308` | Prefer for CPU optimization because it samples CPUs independently by clock frequency; Time Profiler remains supporting context. |
| Time Profiler | `SRC-TIME-PROFILER`, `SRC-INST-BASE-WWDC19-411` | Good broad entry point; insufficient alone for microarchitecture claims. |
| Processor Trace | `SRC-CPU-WWDC25-308`, `SRC-CPU-PTRACE-DOC` | Requires supported hardware and dSYMs. Cite function-call / cycles / instructions within a signposted range. |
| CPU Counters | `SRC-CPU-WWDC25-308`, `SRC-CPU-BOTTLENECKS-DOC`, `SRC-CPU-GUIDE-V4` | Cite mode, bottleneck category, counter-derived metric, stack / instruction range, cohort, and signpost. |
| System Trace | `SRC-SYSTEM-TRACE`, `SRC-CPU-TUNING-DOC` | Required when the CPU symptom is blocked / off-CPU work, scheduling, locks, or syscalls rather than inefficient retired instructions. |
| Hangs | `SRC-HANGS-WWDC22-10082`, `SRC-METRICKIT-WWDC20-10081` | Required when CPU work causes user-visible unresponsiveness or main-thread blocks; cite `MXHangDiagnostic` or Hangs `.trace`. |
| MetricKit CPU diagnostics | `SRC-METRICKIT-WWDC20-10081`, `SRC-ORG-WWDC21-10087` | Cite `MXCPUMetric` / `MXCPUExceptionDiagnostic` with cohort, build, payload window, and dSYM status. |
| XCTest CPU metrics | `SRC-XCT-CPU-DOC`, `SRC-XCT-PERF` | Pre-merge gate only; cite `.xcresult`, baseline bundle, metric identifier, and cohort. |

## API-name validity gate

Before adding an Apple API, MetricKit symbol, XCTest metric, Instruments template, or WWDC ID to an Apollo mode pack:

1. **CHECK** the Apple Developer Documentation or Apple Developer video page URL resolves and the title matches the intended citation.
   Before: new source row or mode-pack citation is proposed.
   After: row `Notes` records `Verified <date>` or the citation is held in a stale-alias row.

2. **CHECK** the exact symbol name against Apple documentation when the citation is an API.
   Before: mode text names a symbol such as `MXAppRunTimeMetric.cumulativeForegroundEnergy`, `MXCPUExceptionDiagnostic`, `XCTCPUMetric`, or `ProcessInfo.thermalStateDidChangeNotification`.
   After: citation uses the documented symbol name and deletes hallucinated aliases such as `MXEnergyMetric`.

3. **CHECK** the exact Instruments template name against the current Xcode / Instruments surface or Apple docs before promoting it to a capture recipe.
   Before: mode text names a template such as `Power Profiler`, `CPU Counters`, `Processor Trace`, `Hangs`, `System Trace`, `Time Profiler`, or `CPU Profiler`.
   After: template name and minimum host / hardware constraints are recorded in `apollo/_shared/primitives/instruments-index.md` or a mode-pack gate.

4. **RECORD** any known-bad historical citation as a stale row instead of deleting it silently.
   Before: a stale ID is found in a mode pack, primitive, or issue.
   After: row ID starts with `SRC-STALE-`, names the observed mismatch, and points to the corrected row when known.

## Local primitive coverage

| Primitive | Source rows it operationalizes |
|---|---|
| `apollo/_shared/primitives/evidence-gate.md` | `SRC-MEM-DIAG-WWDC21-10180`, `SRC-BATT-WWDC25-226`, `SRC-ORG-WWDC21-10087`, `SRC-METRICKIT-WWDC20-10081`, `SRC-CPU-WWDC25-308`, `SRC-XCT-CPU-DOC`, `SRC-NET-WWDC21-10212`, `SRC-NET-HTTP-INST-DOC`, `SRC-NET-MXNETWORK-DOC`, `SRC-NET-MXCELLULAR-DOC`, `SRC-NET-URLSESSIONTASKMETRICS-DOC`, `SRC-NET-ASC-POWER-DOC` |
| `apollo/_shared/primitives/instruments-index.md` | `SRC-INST-BASE-WWDC19-411`, `SRC-INST-CUSTOM-WWDC18-410`, `SRC-MEM-HEAP-WWDC24-10173`, `SRC-MEM-FOOTPRINT-WWDC18-416`, `SRC-BATT-WWDC25-226`, `SRC-CPU-WWDC25-308`, `SRC-CPU-PTRACE-DOC`, `SRC-CPU-BOTTLENECKS-DOC`, `SRC-HANGS-WWDC22-10082`, `SRC-NET-HTTP-INST-DOC`, `SRC-NET-WWDC21-10212` |
| `apollo/_shared/primitives/metrickit.md` | `SRC-METRICKIT-WWDC20-10081`, `SRC-ORG-WWDC21-10087`, `SRC-BATT-WWDC25-226`, `SRC-HANGS-WWDC22-10082`, `SRC-NET-MXNETWORK-DOC`, `SRC-NET-MXCELLULAR-DOC` |
| `apollo/_shared/primitives/organizer-asc.md` | `SRC-ORG-WWDC21-10087`, `SRC-BATT-WWDC25-226`, `SRC-NET-ASC-POWER-DOC` |
| `apollo/_shared/primitives/regression-detection.md` | `SRC-ORG-WWDC21-10087`, `SRC-XCT-PERF`, `SRC-MEM-FOOTPRINT-WWDC18-416`, `SRC-CPU-BOTTLENECKS-DOC` |
| `apollo/_shared/primitives/signposts.md` | `SRC-INST-BASE-WWDC19-411`, `SRC-INST-CUSTOM-WWDC18-410`, `SRC-CPU-WWDC25-308`, `SRC-BATT-WWDC25-226` |
| `apollo/_shared/primitives/xctest-baselines.md` | `SRC-XCT-PERF`, `SRC-XCT-CPU-DOC`, `SRC-BATT-WWDC25-226` |

## See also

- `apollo/modes/memory.md`
- `apollo/modes/thermal.md`
- `apollo/modes/battery.md`
- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/instruments-index.md`
- `apollo/_shared/primitives/metrickit.md`
- `apollo/_shared/primitives/organizer-asc.md`
- `apollo/_shared/primitives/regression-detection.md`
- `apollo/_shared/primitives/signposts.md`
- `apollo/_shared/primitives/xctest-baselines.md`
