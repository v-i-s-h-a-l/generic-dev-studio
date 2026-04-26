---
name: Organizer and App Store Connect primitive
description: Xcode Organizer reports + App Store Connect performance / power metrics API. Apollo's server-side read of the production fleet — same data MetricKit reports, server-aggregated and queryable.
type: reference
schema_version: 1
---

# Xcode Organizer + App Store Connect (production fleet, server-side)

Apple aggregates the same on-device performance data MetricKit reports into two server-side surfaces: the Xcode Organizer (GUI) and the App Store Connect API (programmatic). Apollo treats both as **hard evidence (9/10)** when a citation names the metric, the build, the cohort, and the time window — vague references ("Organizer shows it's worse") fail the gate identically to vague MetricKit citations.

The data is the same data MetricKit delivers on-device, re-aggregated. The opt-in cohort is identical: roughly 20–30% of users who enabled `Share With App Developers`. Treat all coverage estimates with that ceiling in mind.

## Xcode Organizer reports

`Window → Organizer` in Xcode lists per-build reports for every distributed build (TestFlight + App Store). Reports of interest:

| Report | Metric | Apollo mode |
|---|---|---|
| Crashes | crash count, top crashing thread, attached call stack tree | memory, thermal |
| Hangs | hang rate, p95 hang duration | responsiveness (Phase 2) |
| Disk Writes | bytes written / hour foreground | battery |
| Battery | battery drain rate per foreground hour | battery |
| Power | watts per active hour, normalized | battery |
| Launch Time | cold-launch p50 / p95 / p99 | launch (Phase 2) |
| Hang Rate | percentage of foreground time spent in hangs | responsiveness (Phase 2) |
| Scroll Hitches | hitch ratio for the app's scroll views | scroll-perf (Phase 2) |
| Memory | peak memory usage distribution; OOM rate | memory |
| Disk | persistent disk usage distribution | battery |

Each report exposes a per-build trend line, a cohort filter (device class, OS, country), and a rank-ordered call-stack list for diagnostic surfaces. Reports update on the same ~24h cadence MetricKit delivers; a brand-new build shows partial data for ~48h.

The Organizer GUI is for human review. Apollo cites Organizer screenshots only as a fallback when ASC API access is unavailable; the API path is always preferred.

## App Store Connect API (programmatic)

The ASC API exposes the same telemetry the Organizer renders. Two flows Apollo uses:

| Flow | Surface | What it returns |
|---|---|---|
| Performance / Power Metrics | per-build aggregate metrics | rolled-up statistics (p50 / p95) per metric category, broken down by device class + OS |
| Analytics Reports | raw per-day TSV | row-level data the developer post-aggregates; opt-in per Apple Developer program |

Authentication: App Store Connect API key (issuer ID + key ID + `.p8`), JWT signed ES256, `Bearer` header. Tokens expire ≤ 20 minutes; Apollo's execution surface (`apollo/_shared/primitives/execution-surface.md`) refreshes on each invocation.

### Metric categories

The Performance / Power Metrics flow returns categories that align with MetricKit:

| Category | Maps to | Apollo cites |
|---|---|---|
| Disk Writes | `MXDiskIOMetric.cumulativeLogicalWrites` | bytes / foreground hour, p95 |
| Hang Rate | `MXAppResponsivenessMetric.histogrammedApplicationHangTime` | p95 hang seconds / foreground hour |
| Launch Time | `MXAppLaunchMetric.histogrammedTimeToFirstDraw` | cold p95, warm p95 |
| Memory | `MXMemoryMetric.peakMemoryUsage` | peak p95 by device class |
| Battery | derived from `MXAppRunTimeMetric.cumulativeForegroundEnergy` ÷ `cumulativeForegroundTime` | mWh / hour |
| Scroll Hitches | `MXAnimationMetric.scrollHitchTimeRatio` | ratio p50 / p95 |
| Peak Memory | `MXMemoryMetric.peakMemoryUsage` p99 | OOM proximity |

Each row carries: `metric`, `goal` (Apple's recommended target), `value`, `unit`, `device`, `osVersion`, `percentile`, `buildVersion`. Apollo persists the full row, not just the value, so cohort drift later doesn't invalidate the citation.

### Build cohorting

Apollo always cites a single build version, never an aggregate across builds. Trends across builds are reported as a sequence of single-build citations — pre-aggregated multi-build numbers obscure regression direction.

Per-cohort breakdown is mandatory:

| Cohort axis | Why |
|---|---|
| Device class | `iPhone14,2` p95 ≠ `iPhone11,8` p95; collapsing them hides device-specific regressions |
| OS major | iOS 18 vs iOS 19 perf characteristics differ (scheduler, Metal driver) |
| Distribution | TestFlight builds are a smaller, biased cohort; App Store builds reflect production |

Apollo refuses any citation that doesn't pin device class + OS major. The cohort tag is the same one used in MetricKit (`MXMetaData`) and XCTest baselines (`LocalComputer.modelCode`); the three sources are diff-comparable only when the cohort tag matches.

### Build availability

A build appears in the API ~24h after the first opted-in install reports payloads. Apollo's dispatch logic queries the API at investigation time and refuses citations against builds with `coverage_status != reporting` — under-reporting builds produce noisy aggregates.

## TestFlight vs App Store

| Surface | Cohort size | Bias | Apollo use |
|---|---|---|---|
| TestFlight | 100s–1000s testers | younger devices, opted-in heavily, often beta OS | early-warning regression detection |
| App Store | full opted-in fleet | broader device + OS spread; the production reality | shipped-build regression confirmation |

Apollo treats TestFlight evidence as **provisional**: it can prompt investigation but cannot confirm a regression. App Store evidence is the confirmation gate. A regression flagged on TestFlight that does not reproduce on the next App Store build's first 48h of data is downgraded, not retracted.

## How Apollo references Organizer / ASC data

Mode packs cite production-fleet evidence in this shape:

| Citation form |
|---|
| ASC `<metric>` p95 `<x><unit>` for build `<version>`, cohort `<modelCode>/<osMajor>`, distribution `<TestFlight|App Store>`, window `<start..end>` |
| Organizer `<report>` build `<version>` cohort `<modelCode>/<osMajor>` — top-1 stack `<symbol>` `<percent>%` |

Either form satisfies the strict-9 gate. The mandatory tags are: metric, build, cohort, distribution, window.

## Privacy and data handling

ASC payloads contain no user identifiers. Aggregate counts and percentiles only. Diagnostic call stacks (Organizer Crashes / Hangs reports) contain symbol names from app code — same code-confidentiality treatment as MetricKit diagnostic payloads. Apollo's persistence pattern matches `apollo/_shared/primitives/metrickit.md §Persistence` — local-first, cached, never proxied through third-party services.

## Why

MetricKit gives Apollo per-device payloads from the local install. The Organizer + ASC API give Apollo the same data aggregated *server-side* across the fleet, queryable by build and cohort. The two are complementary: MetricKit is push (the device sends what it has), ASC is pull (Apollo asks for a specific cohort's stats). Apollo's regression-detection layer (`apollo/_shared/primitives/regression-detection.md`) operates on whichever source has the better cohort match at investigation time — usually ASC for cross-build comparisons, MetricKit for the local install's own history.

The TestFlight-as-provisional rule is what stops Apollo from chasing beta-cohort artifacts. Without it, every TestFlight regression flag becomes a fire drill that disappears at App Store release with no learning.

## See also

- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/metrickit.md` — on-device side of the same data
- `apollo/_shared/primitives/regression-detection.md` — diff math across builds
- `apollo/_shared/primitives/execution-surface.md` — ASC API auth + fetch
- WWDC20 10076 — Diagnose performance issues with the Xcode Organizer
- WWDC21 10087 — Diagnose Power and Performance regressions
- App Store Connect API — Performance / Power Metrics reference
