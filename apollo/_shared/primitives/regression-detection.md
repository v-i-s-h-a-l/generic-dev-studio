---
name: Regression detection primitive
description: The statistical bar for "this got worse." Baseline-diff math, percentile selection, per-cohort normalization, sample-size minimums, cold-vs-warm distinction, and Apollo's regression decision rule.
type: reference
schema_version: 1
---

# Regression detection (the statistical bar)

Performance data is noisy. Apollo's regression-detection layer is the math that turns a per-build measurement into a regression *call* — confirmed, suspected, or none. The rule has to be conservative (over-flagging produces churn) and sensitive (under-flagging is the failure mode the agent exists to prevent). This file defines the rule.

A regression call IS hard evidence (9/10) only when (a) it is paired with the underlying measurements, (b) the cohort match is exact, and (c) the sample sizes pass the minimums below. Calls that miss any of those degrade to advisory-1.

## Sources Apollo compares

| Source | Shape | Comparison axis |
|---|---|---|
| XCTest baseline | per-iteration array (length `iterationCount`) | run vs persisted baseline, same cohort |
| MetricKit `MXMetricPayload` | per-day aggregate, histogram or scalar | day-to-day on same install, or build-to-build cohort |
| ASC Performance Metrics | per-build aggregate, percentile | build-to-build, cohort-pinned |
| Instruments `.trace` (signpost) | per-interval array within one run | run vs run, same scenario, same cohort |

Apollo never compares across sources without a documented bridge. XCTest baseline ↔ ASC is a bridge (signposts named identically); MetricKit ↔ ASC is a bridge (same underlying data, different aggregation); XCTest ↔ MetricKit is *not* a bridge (synthetic vs field; cohorts overlap only by accident).

## Percentile selection

| Percentile | When to cite | Why |
|---|---|---|
| p50 | typical-case latency, throughput | resilient to outliers; stable across small samples |
| p95 | tail latency, hitch ratio, hang exposure | the percentile that maps to user-visible slowness |
| p99 | OOM proximity, peak memory, watchdog risk | rare-event surface; only stable above ~5000 samples |
| max | never as evidence | one outlier wins; Apollo refuses citations of `max` |

Default: cite p95 for time-domain metrics, p99 for memory peak, p50 alongside for context. A p95 regression with p50 unchanged is a tail regression (often a worst-case-input bug); a p50 regression with p95 unchanged is rare and usually a measurement artifact (cohort drift, cache state).

## Cohort normalization

Two metrics are comparable only when their cohort tag matches on both axes:

| Axis | Match rule |
|---|---|
| Device class | exact `modelCode` (e.g. `iPhone14,2`) |
| OS major | exact major (e.g. `19`) — minor versions may be combined within a single major |

Cross-cohort comparison is a category error and the most common silent false positive. A test plan that switches its destination from simulator → real device produces a "regression" that is actually a cohort change. Apollo refuses any diff that crosses either axis without an explicit `--cross-cohort` opt-in (which downgrades the call to advisory-1, never hard).

For build-to-build trend lines, Apollo collapses by cohort first, then reports per-cohort deltas. A "regression on iPhone 13 only" is a useful finding; an aggregated number across a cohort spread is not.

## Cold vs warm

Launch and first-render metrics differentiate cold (process not in memory) from warm (process resumed from suspend). They are different distributions, not points on a continuum. Apollo treats them as distinct metrics:

| Variant | Source axis |
|---|---|
| Cold launch | `XCTApplicationLaunchMetric` first iteration after device reboot, or ASC `Launch Time → Cold` |
| Warm launch | `XCTApplicationLaunchMetric` subsequent iterations, or ASC `Launch Time → Warm` |
| Resume | `MXAppLaunchMetric.histogrammedApplicationResumeTime` |

A regression in warm launch with no change in cold launch is a different bug than a uniform launch regression — usually a state-restoration cost, not a code-load cost. Citing "launch p95 regressed" without naming the variant fails the gate.

## Sample-size minimums

Below a minimum sample size, percentile statistics are unstable enough that a "regression" is more likely noise than signal. Apollo enforces:

| Percentile | Minimum samples |
|---|---|
| p50 | 30 |
| p95 | 200 |
| p99 | 5000 |

Sources at investigation time:

| Source | Typical samples per cohort per build |
|---|---|
| XCTest `measure()` | 5–20 (set by `iterationCount`) |
| MetricKit per-day payload | 1 per device per day |
| ASC per-build aggregate | thousands–millions, cohort-dependent |
| Instruments single trace | tens to hundreds of signpost intervals |

XCTest does not satisfy p95 / p99 minimums on its own — Apollo cites XCTest at p50 and uses ASC for tail percentiles. The sources are designed to be combined, not substituted.

## Decision rule

Apollo emits one of three calls per metric:

| Call | Criteria |
|---|---|
| **Confirmed regression** | (Δ ≥ relative threshold) AND (sample sizes met) AND (cohort exact) AND (significance test passes) |
| **Suspected regression** | (Δ ≥ relative threshold) AND any one criterion above missing |
| **No regression** | otherwise |

### Relative thresholds (default)

| Metric class | Threshold |
|---|---|
| Time domain (latency, launch, hitch ratio) | +10% on p95 |
| Memory peak | +5% on p99 |
| Energy / battery | +10% on mean foreground energy per hour |
| CPU time | +15% on mean (high baseline noise) |
| Disk writes | +20% on mean (very high baseline noise) |

Thresholds are tuned per repo via mode-pack frontmatter; the defaults above are the floor — overrides may tighten, never loosen below `+5%` without an `advisory:` flag.

### Significance test

Apollo runs a non-parametric test rather than assuming a Gaussian distribution (perf data is heavy-tailed):

| Comparison shape | Test |
|---|---|
| Two arrays of per-iteration values (XCTest, signposts) | Mann–Whitney U, two-sided, α = 0.01 |
| Two histograms (MetricKit) | empirical bootstrap of percentile delta, 10,000 resamples, 99% CI excludes 0 |
| Two cohort-rolled percentiles (ASC) | Wilson interval on the percentile, 99%; check overlap |

Parametric tests (t-test) are not used — they over-call regressions on long-tailed distributions. The Mann–Whitney path is robust to the distributions Apollo encounters.

## Memory-specific rules

Memory regressions have one extra dimension: footprint vs RSS. The OOM kill is keyed on `footprint` (the kernel's accounting that excludes clean mapped pages); RSS includes clean pages that won't be evicted under pressure. Apollo cites footprint by default and notes RSS only as context. `MXMemoryMetric.peakMemoryUsage` is footprint; `XCTMemoryMetric` reports RSS — the bridge requires explicit conversion (or a VM Tracker trace) and Apollo refuses footprint claims based on RSS-only sources.

## False-positive sources Apollo bounds

| Source | Mitigation |
|---|---|
| Cohort drift between baseline and run | exact cohort tag enforcement |
| Single-iteration outlier dominating mean | percentile reporting, not mean |
| Build configuration drift (Debug vs Release) | metric requires `optimizationLevel` in cohort tag |
| Background thermal pressure perturbing run | `MXMetaData.thermalState` ≤ `.fair` for the run; otherwise discard |
| Charging state perturbing battery measurement | discard when `MXMetaData.batteryChargingState != .unplugged` for battery mode |
| Code-signing or first-launch costs | first-iteration discard for cold-launch with `manuallyStart` |

Each mitigation lives in the corresponding mode pack's procedure; this file is the reason they exist.

## How Apollo emits a regression call

Mode packs surface a call in this shape:

```
REGRESSION (confirmed): <metric> <p95|p99> +<delta>% on <modelCode>/<osMajor>
  baseline: <x><unit> ± <sd>  (n=<n>, source=<src>, build=<base>)
  run:      <y><unit> ± <sd>  (n=<n>, source=<src>, build=<head>)
  test: Mann–Whitney U, p=<p>, α=0.01
  artifacts: <baseline-path>, <run-path>
```

The call is rejected by the strict-9 gate without all six fields populated.

## Why

Performance data is non-Gaussian, non-stationary, and small-sample on the dev-loop side. A naive "did the number go up" rule misfires constantly — the agent that adopts it generates noise faster than humans can dismiss. The rules in this file are the minimum machinery to get conservative, defensible regression calls. They are deliberately stricter than Xcode's built-in `maxPercentRegression` (which uses a single-mean comparison): Xcode's check is fine for blocking a CI run, but not strict enough to be evidence under the strict-9 gate.

The percentile-discipline (no `max`, p95 default, p99 only with samples) is the rule that prevents the most common authorship error: citing one bad sample as a trend.

## See also

- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/xctest-baselines.md` — sample shape for synthetic source
- `apollo/_shared/primitives/metrickit.md` — sample shape for on-device source
- `apollo/_shared/primitives/organizer-asc.md` — sample shape for fleet-aggregated source
- `apollo/_shared/primitives/instruments-index.md` — sample shape for in-trace source
- `apollo/_shared/primitives/execution-surface.md` — where the math runs
