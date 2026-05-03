---
name: Apollo network mode
description: Diagnose -> measure -> recommend -> verify protocol for network-efficiency regressions under strict-9 evidence gating.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 7000
session_budget: 900s
locks:
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
  - apollo/_shared/primitives/organizer-asc.md
  - apollo/_shared/primitives/canonical-antipatterns.md
  - ~/.dev-studio/.runtime/host-capabilities.yaml
writes:
  - ~/.dev-studio/<project>/apollo/captures/<id>/**
  - ~/.dev-studio/<project>/apollo/recommendations/<id>.md
  - ~/.dev-studio/<project>/apollo/deferred/<id>.yaml
  - ~/.dev-studio/<project>/events/<today>.jsonl
  - ~/.dev-studio/.runtime/locks/apollo/*
---

# Mode: Network (`/apollo network`, `/apollo network-efficiency`)

Network is a first-class Apollo mode for request and connection behavior: latency, fan-out, retry churn, over-fetch, cache misses, transfer volume, connection reuse, and network-condition skew. Battery owns energy impact. Network mode may cross-cite battery only when the claim is paired with Power Profiler or field power evidence from `apollo/_shared/primitives/evidence-gate.md §Network hard-evidence catalogue`.

Source-map rows: `apollo/_shared/primitives/source-map.md` §Mode row index -> network. Operational gates live in `apollo/_shared/primitives/evidence-gate.md §Network hard-evidence catalogue`.

## Signal classes

| Class | What it looks like | Authoritative evidence | Apollo template |
|---|---|---|---|
| Request latency | A signposted user flow waits on tasks / transactions, blocked states, redirects, or slow response phases | Network / HTTP Traffic `.trace`, signposted `URLSessionTaskMetrics` | Network + Points of Interest |
| Fan-out / over-fetch | One user action creates too many tasks, duplicate requests, or oversized payloads | Network trace task count, transaction bytes, task labels, payload baseline | Network |
| Cache miss / reuse failure | Repeated network transactions where cache hits or connection reuse were expected | Network trace cache/transaction states, task metrics, HTTP headers when safely summarized | Network |
| Retry / redirect churn | Retries, redirects, auth challenges, or backoff failures dominate the scenario | Network trace transaction chain, `URLSessionTaskMetrics.redirectCount`, logs with cohort + signpost | Network |
| Persistent connection cadence | WebSocket / long-poll / stream cadence keeps traffic active beyond the scenario need | Network trace connection intervals, task metrics, paired Power Profiler when energy is claimed | Network + Power Profiler when needed |
| Field transfer regression | Wi-Fi or cellular bytes regress in production for a cohort/window | `MXNetworkTransferMetric` plus `MXCellularConditionMetric` for cellular claims, ASC rows when present | MetricKit / ASC |

## Evidence gate

Hard evidence is exactly the network row in `apollo/_shared/primitives/evidence-gate.md §Hard-evidence catalogue`. The citation must name artifact, scenario or payload window, cohort, network condition, build, and baseline.

| Evidence | Minimum bar |
|---|---|
| Network / HTTP Traffic `.trace` | Scenario or named capture window, `OSSignposter` interval when the app can provide one, task/session labels when available, cohort, build, baseline |
| `URLSessionTaskMetrics` | Captured under a signposted workload; task interval, transaction metrics, request/response count, redirect count, cohort, build, baseline |
| `MXNetworkTransferMetric` | Seven-day minimum cohort window; Wi-Fi/cellular upload/download fields; build; baseline; foreground/background normalizer when used |
| `MXCellularConditionMetric` | Required with cellular transfer or radio-drain claims; cite `histogrammedCellularConditionTime` for the same window/cohort |
| Power Profiler paired with Network | Required for battery/radio energy claims; both traces share scenario, signpost/window, cohort, build, and baseline |
| ASC row | Exported response artifact with app/build endpoint, metric category/row name, distribution, cohort, percentile or aggregate, window, baseline |

Simulator Network traces can support request-shape diagnosis when the issue is simulator-reproducible and no power / radio claim is made. Cellular, MetricKit, ASC, Power Profiler, and any radio-energy claim require real device or production-field evidence.

## Capture paths

| Path | Recipe | Output |
|---|---|---|
| Network trace | `xctrace record --template "Network" --device "<udid>" --launch -- "<bundle>" --time-limit 300s --output network.trace` | Network / HTTP Traffic `.trace` plus metadata sidecar |
| System Trace correlation | Record System Trace over the same scenario when Network shows waits but not the scheduling cause | paired `.trace` with matching signpost/window |
| Paired power | Record Power Profiler and Network for the same scenario when the claim mentions radio wake density or battery | `power-network.trace` + `network.trace` |
| Task metrics | Run the scenario test target and persist `URLSessionTaskMetrics` with semantic task/session labels | JSON/log artifact |
| MetricKit / ASC | Query stored payloads or ASC Power / Performance response for matching cohort/window | JSON response artifact |

Capture-only support: `/apollo measure network --capture-only` and `/apollo network --capture-only` stop after writing the artifact sidecar. `measure network` has no default workload; the caller must provide `--workload` or `--scenario` because generic network capture leaks assumptions and records unrelated traffic.

Codex degraded mode inherits `apollo/SKILL.md §Degraded mode` verbatim: when capture tools are unavailable, skip auto-capture, refuse with `attempted-paths: [capture unavailable on Codex]`, and resume only with `--evidence <path>`.

## Recommendation archetypes

Network recommendations are allowed only when the measured artifact matches an archetype below. Each recommendation includes expected delta and the post-fix artifact that will verify it.

| Archetype | Evidence required | Expected delta | Tradeoff / non-goal | Verification |
|---|---|---|---|---|
| Request coalescing | Network trace shows duplicate/fan-out tasks for one signpost interval | fewer tasks or lower blocked transaction time | May increase first-byte wait; do not batch user-visible urgent work blindly | matched Network trace |
| Cache policy correction | Trace/task metrics show repeated transfers where safe cache reuse is expected | lower transfer bytes or fewer transactions | Freshness rules win; do not cache personalized/private responses without policy proof | Network trace or `URLSessionTaskMetrics` |
| Payload trimming | Transfer bytes regress against baseline for same scenario/cohort | lower bytes per scenario or per field window | Do not remove required content or private validation fields | Network trace plus MetricKit/ASC for field claims |
| Retry/backoff tuning | Trace shows retry, redirect, or auth-challenge churn dominating scenario | fewer retry/redirect transactions and lower wall time | Slower retry may delay recovery; cite product tolerance | Network trace/task metrics |
| WebSocket / long-poll cadence | Connection intervals or pings continue beyond need | fewer connection wakes or lower transfer cadence | Do not break realtime contract; background delivery may need APNs | Network trace; paired Power Profiler for energy |
| Background / discretionary transfer | Large non-urgent transfer blocks foreground scenario or cellular window | lower foreground bytes or blocked time | User-immediate actions stay foreground | MetricKit/ASC or Network trace |
| Pagination / prefetch bounds | One scenario fetches pages/items outside user-visible need | fewer requests/bytes within signpost | Avoid under-prefetch jank; verify UX-critical latency | Network trace |
| Compression / protocol negotiation | Trace names payload size or HTTP version as bottleneck | lower bytes or blocked time | Server capability may be out of app scope; no server-only requirement | Network trace before/after |
| Obsolete request cancellation | Trace shows tasks completing after scenario cancellation/nav change | fewer completed obsolete tasks | Cancellation must not drop required writes | Network trace/task metrics |

## Advisory rows

Network `advisory:1` rows live in `apollo/_shared/primitives/canonical-antipatterns.md §Network anti-patterns`. They cite request shape, fan-out, cache headers, HTTP version, redirect/retry churn, transfer pattern, connection reuse, and cancellation. They never claim wattage, radio-tail energy, or measured impact. Battery `batt:*` rows continue to own energy-shaped advisories.

## Failure modes

| Failure | Classification | Response |
|---|---|---|
| No artifact and capture unavailable | permanent | Emit the strict-9 refusal block from `evidence-gate.md §Network soft-evidence and refusal cases` |
| Missing workload / scenario for measure mode | permanent | Refuse with `missing-input`; require `--workload` or `--scenario` |
| Trace lacks signpost or named window | ambiguous | Retry once with corrected scenario; then refuse `reason: signpost_missing` |
| Cellular transfer claim lacks cellular-condition context | permanent | Refuse until `MXCellularConditionMetric.histogrammedCellularConditionTime` or ASC cohort segmentation is supplied |
| Carrier/network-condition mismatch | permanent | Refuse the comparison; recapture matching network condition or narrow the cohort |
| Private URL/payload details appear in proposed citation | permanent | Redact to semantic task/session labels; never commit trace contents |
| Energy claim without Power Profiler / field power evidence | permanent | Route to battery or require paired power evidence |
| Host lacks xctrace / real-device access | permanent | Refuse with `reason: capability_unavailable`; allow `--evidence <path>` resume |

## Procedure

1. **READ** the invocation or artifact and classify it into one network signal class.
   Before: caller invokes `/apollo network`, `/apollo network-efficiency`, `/apollo measure network`, or supplies a network-shaped artifact.
   After: class, source-map rows, required evidence, and capture/degraded-host path are recorded.

2. **CHECK** the strict-9 network evidence catalogue.
   Before: class is known.
   After: hard evidence passes, or auto-capture-before-refuse runs when host capabilities allow it.

3. **RUN** or defer the capture recipe when workload, cohort, host capability, and budget are present.
   Before: workload/scenario and cohort are known; capture tools are available.
   After: artifact sidecar is persisted and `apollo_capture_completed` or `apollo_capture_deferred` is emitted.

4. **CHECK** privacy, cohort, network-condition, signpost/window, and baseline fields.
   Before: artifact exists.
   After: recommendation fields are evidence-backed, or Apollo refuses with the exact missing fields.

5. **WRITE** the recommendation artifact per `apollo/_shared/primitives/mode-pack-scaffold.md` §Phase 4.
   Before: archetype selected and evidence passes.
   After: `apollo_recommendation` event and brief seed are emitted; Apollo does not mutate source files.

6. **RUN** post-fix verification on the same match axes: cohort + scenario + signpost/window + build + network condition + artifact shape.
   Before: patch lands.
   After: post-fix capture verifies, partially verifies, regresses, or refuses the completion claim.

## See also

- `apollo/_shared/primitives/evidence-gate.md` - strict-9 network catalogue and refusal cases
- `apollo/_shared/primitives/source-map.md` - `SRC-NET-*` source rows
- `apollo/_shared/primitives/instruments-index.md` - Network template and `xctrace` recipe
- `apollo/_shared/primitives/metrickit.md` - `MXNetworkTransferMetric`, `MXCellularConditionMetric`
- `apollo/_shared/primitives/organizer-asc.md` - ASC network-attributed citation shape
- `apollo/_shared/primitives/mode-pack-scaffold.md` - shared patch handoff and re-measure protocol
- `apollo/modes/battery.md` - energy/radio-drain ownership boundary
