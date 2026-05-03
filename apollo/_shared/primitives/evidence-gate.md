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

## Hard-evidence catalogue (per mode)

| Mode | Hard-evidence artifacts |
|---|---|
| memory | Allocations / VM Tracker `.trace`; `MXMemoryMetric.peakMemoryUsage`; `MXMetaData` foreground-bytes; XCTest `XCTMemoryMetric` baseline; `MXCrashDiagnostic` OOM (`0xc00010ff`) payload |
| thermal | `MXMetaData.thermalState` distribution; `ProcessInfo.thermalState` log; CPU Counters / Time Profiler `.trace`; Metal System Trace `.trace`; Energy Log instrument |
| battery | `MXAppRunTimeMetric.cumulativeForegroundEnergy`; ASC Performance Metrics power row; Energy Log `.trace`; `MXCPUMetric.cumulativeCPUTime` per foreground hour |
| cpu | CPU Profiler / Time Profiler `.trace`; CPU Counters `.trace`; Processor Trace `.trace`; System Trace `.trace`; Hangs `.trace`; `MXCPUMetric`; `MXCPUExceptionDiagnostic`; `MXSignpostIntervalData.cumulativeCPUTime`; XCTest `XCTCPUMetric` baseline diff |
| network | Network / HTTP Traffic `.trace`; Power Profiler `.trace` network row paired with Network `.trace`; System Trace `.trace` correlated to the same network signpost/window; `MXNetworkTransferMetric`; `MXCellularConditionMetric`; signposted `URLSessionTaskMetrics`; ASC Performance / Power Metrics row when the response exposes network-attributed power or transfer data |

Mode packs cite this table when stating their entry conditions. A citation MUST name the artifact, the workload (scenario or payload window), and the cohort (device class + OS) — vague citations like "MetricKit shows it's bad" fail the gate.

## Network hard-evidence catalogue

Network evidence is first-class. Battery networking-radio-drain rows, network-efficiency rows, and cross-mode network findings cite this catalogue instead of inventing local acceptance rules.

| Evidence form | Required fields | Accepted use |
|---|---|---|
| Network / HTTP Traffic `.trace` | artifact path; scenario; `OSSignposter` interval or named capture window; URLSession / task / transaction labels when available; cohort `<device-class>/<os-major>`; build; comparison baseline | Request fan-out, blocked transaction time, connection reuse, cache behavior, HTTP version, retry / redirect churn, transfer timing |
| Power Profiler `.trace` network row paired with Network `.trace` | both artifact paths; same scenario and signpost/window; network subsystem wattage row; connection-wake count or density; cohort; network condition / carrier class when cellular; build; baseline | Battery networking-radio-drain recommendations and verification |
| System Trace `.trace` correlated to Network `.trace` or `URLSessionTaskMetrics` | artifact path; scenario and signpost/window; correlated network event timestamps; scheduling / wake / syscall evidence; cohort; build; baseline | Proving that network waits, wakeups, or blocked work are the performance mechanism rather than CPU or UI work |
| `MXNetworkTransferMetric` | payload artifact; payload window; `cumulativeWifiUpload`, `cumulativeWifiDownload`, `cumulativeCellularUpload`, and / or `cumulativeCellularDownload`; cohort; app build; comparison baseline; foreground/background normalizer when used | Field transfer-volume regressions and battery-network attribution |
| `MXCellularConditionMetric` | payload artifact; payload window; `histogrammedCellularConditionTime`; cohort; carrier-class / radio-condition bucket; app build; baseline | Context for cellular comparisons; required when a cellular transfer or radio-drain claim depends on carrier quality |
| `URLSessionTaskMetrics` | artifact/log path; scenario; task interval; transaction metrics; request/response count; protocol / connection reuse fields when captured; signpost/window; cohort; build; baseline | Deterministic scenario-level request timing when collected by code under a signposted workload |
| ASC Performance / Power Metrics row | ASC response artifact; metric category / row name; app or build endpoint; build; distribution; cohort; percentile or aggregate; collection window; baseline build/window; network attribution if present | Production aggregate confirmation when ASC exposes a network-attributed row or a battery/power row tied to the same network scenario |

Network citations MUST use this shape:

```
<artifact> for scenario <name>, signpost/window <name-or-start..end>,
cohort <device-class>/<os-major>, network <wifi|cellular|mixed>/<carrier-class-or-condition>,
build <version>, baseline <artifact-or-build/window>
```

For Wi-Fi-only claims, `network` may name the Wi-Fi class and omit carrier. For any cellular claim, `network` must include carrier class or cellular-condition distribution. For private endpoints, citations name semantic task/session labels, never URLs, account identifiers, payload bodies, headers, tokens, or workspace names.

## Network soft-evidence and refusal cases

Apollo downgrades these to soft evidence and refuses recommendations after auto-capture-before-refuse:

| Input | Why it fails strict-9 | Unblock recipe |
|---|---|---|
| Screenshot of Instruments, Xcode Network Report, proxy UI, or ASC dashboard | Not a replayable artifact; usually lacks scenario, signpost/window, cohort, or baseline | Capture a Network / HTTP Traffic `.trace` or export the ASC API response row |
| One-off complaint such as "requests feel slow" or "cellular drains battery" | No artifact, cohort, or comparison baseline | Run a signposted scenario with Network `.trace`, or collect MetricKit / ASC field rows |
| App logs without cohort and scenario | Logs do not prove transfer timing, connection state, or network condition | Add `OSSignposter` scenario windows and collect `URLSessionTaskMetrics` or Network `.trace` under that scenario |
| Network trace without signposts or named capture window | Cannot attribute traffic to the workload or compare before / after | Re-run with `OSSignposter` intervals or a documented capture window |
| Field payloads without carrier-class / cellular-condition context | Cellular regressions vary with radio quality; cross-condition comparisons hide or invent regressions | Pair `MXNetworkTransferMetric` with `MXCellularConditionMetric.histogrammedCellularConditionTime` or ASC cohort segmentation |
| Proxy logs, HAR files, packet captures, or server logs alone | Useful context but not first-party device evidence and often expose private payloads | Use them as supporting context only; collect Network `.trace`, `URLSessionTaskMetrics`, MetricKit, or ASC evidence for the gate |

Network refusal blocks list at least two concrete recipes:

```
BLOCKED: network recommendation requires hard evidence; none provided.

Tried to auto-capture via:
  - Network trace: <reason it failed or was skipped>
  - MetricKit / ASC: <reason>

To unblock, capture one of:
  - Network / HTTP Traffic trace — RUN xctrace record --template "Network" --device "<udid>" --launch -- "<bundle-id>" --time-limit 300s --output network.trace
  - URLSessionTaskMetrics under a signposted scenario — RUN the scenario test target and persist task metrics with scenario, cohort, build, and baseline
  - MetricKit field payload — RUN MetricKit subscription / pastPayloads export for MXNetworkTransferMetric plus MXCellularConditionMetric over the cohort window
  - ASC Performance / Power Metrics row — RUN ASC metrics export for the build/cohort/window and cite the baseline row

Resume with `apollo network --evidence <path>` or the calling mode's `--evidence <path>`.
```

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
