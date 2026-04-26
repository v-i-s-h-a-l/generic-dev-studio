---
name: Apollo memory mode
description: Diagnose → measure → propose → patch → re-measure protocol for memory regressions under strict-9 evidence gating. Covers transient peaks, persistent growth, leaks, and OOM kills.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 6000
session_budget: 1800s
locks:
  - simulator-{udid}
  - xctrace-{device}
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

# Mode: Memory (`/apollo memory`)

Memory is the first P0 mode under the strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`). The procedure is ordered: every transition requires hard evidence cited in the catalogue, otherwise the gate refuses and auto-capture-before-refuse runs the next step in the execution-surface decision tree.

The mode treats four memory signal classes as distinct — diagnostic question, capture template, regression math, and verification artifact differ per class. Mode packs cite the class on every recommendation; cross-class citations fail the gate.

## Signal classes (heap taxonomy)

| Class | What it looks like | Authoritative source | Apollo template |
|---|---|---|---|
| Transient peak | Spike during a single scenario; drops back after | XCTest `XCTMemoryMetric`, Allocations generations | Allocations |
| Persistent growth | Working set climbs across scenarios; never drops | VM Tracker dirty + footprint over time, Allocations "Persistent" filter | VM Tracker |
| Leak | Object graph unreachable but retained (refcycle, dangling closure context, CF retain bug) | Leaks template + Memory Graph Debugger; `leaks(1)` CLI on macOS host | Leaks + Memory Graph |
| OOM kill | Process terminated with `0xc00010ff` (jetsam) | `MXCrashDiagnostic.crashDiagnostics[].terminationReason`, `MXAppExitMetric.foregroundExitData.cumulativeMemoryResourceLimitExitCount` | MetricKit + VM Tracker reproduction |

The OS's OOM gate is keyed on **footprint** (kernel-tracked dirty + compressed bytes + IOKit graphics allocations), not RSS. Apollo cites footprint as the OOM-proximity number; RSS is context-only. `MXMemoryMetric.peakMemoryUsage` is footprint; `XCTMemoryMetric` reports RSS — see `apollo/_shared/primitives/regression-detection.md §Memory-specific rules` for the bridge.

Jetsam thresholds vary by device class and foreground state; the published worst-case ceilings Apollo treats as load-bearing:

| Device class | Foreground footprint ceiling (approx) |
|---|---|
| iPhone with ≤ 2 GB RAM (e.g. iPhone 8 family) | ~ 1.0 GB |
| iPhone with 3–4 GB RAM | ~ 1.4 GB |
| iPhone with 6+ GB RAM (e.g. 14 Pro / 15 Pro / 16 Pro) | ~ 2.5–3.0 GB |
| iPad Pro (8+ GB RAM) | ~ 5.0 GB |

Apple does not publish exact values, and they shift per OS minor; Apollo cites the per-cohort `MXMemoryMetric.peakMemoryUsage` p99 distribution as the ground truth and refuses recommendations that hand-wave a ceiling without cohort evidence.

## Phase 1 — Diagnose

Goal: classify the signal into one of {transient peak, persistent growth, leak, OOM kill} and pick the matching template + signpost shape. No fix proposed at this phase.

Inputs Apollo accepts: `MXMetricPayload` JSON, `MXDiagnosticPayload` JSON, ASC Performance Metrics row, `.xcresult` bundle, `.trace` file, or a free-text report citing one of those. Free text without a cited artifact triggers auto-capture-before-refuse.

| Diagnostic question | Template | Signpost shape | Citation (passes gate) |
|---|---|---|---|
| Did peak rise on a single scenario? | Allocations | `OSSignposter` interval `<Scenario>` `.public` byte payload at end | Allocations `.trace` peak delta inside the signposted interval; cohort `<modelCode>/<osMajor>` |
| Did working set rise across scenarios? | VM Tracker | `OSSignposter` interval `<Scenario>` chained per scenario; emit `dirty=\(footprint, privacy: .public)` at end | VM Tracker dirty + compressed series; pre-scenario vs post-scenario delta after one minute settle |
| Is an object graph retained beyond expected scope? | Leaks (Instruments) + Memory Graph (Xcode) | Event signpost `<Type>.deinit` MUST fire when Apollo expects deallocation; absence is the signal | Leaks template cycle list + Memory Graph "Cycle" filter screenshot exported via `xcresult`; matched against the missing `deinit` event |
| Did the OS jetsam the process? | MetricKit + VM Tracker reproduction | `MXAppExitMetric.foregroundExitData.cumulativeMemoryResourceLimitExitCount` | `MXCrashDiagnostic` payload with `terminationReason: 0xc00010ff`, cohort + build pinned; reproduction trace captured under same scenario |

The signposts table is enforced — Apollo refuses a memory recommendation whose source lacks a `OSSignposter` anchor for the cited interval. The privacy default (`.private`) silently aggregates `MXSignpostMetric` payloads as opaque, which is the most common silent-bug shape (`apollo/_shared/primitives/signposts.md §Custom metadata`); recommendations that cite an opaque MetricKit aggregation fail the gate.

## Phase 2 — Measure

Goal: produce the cited artifact under the strict-9 catalogue entry the diagnosis demands. Either the user supplied it, an existing capture matches, or auto-capture runs.

Hard-evidence catalogue rows for memory (from `apollo/_shared/primitives/evidence-gate.md §Hard-evidence catalogue`):

| Source | Property / artifact | When to cite |
|---|---|---|
| Allocations `.trace` | per-call-stack peak, generation-diff bytes | transient peak, persistent growth |
| VM Tracker `.trace` | dirty / resident / compressed / swapped time series | persistent growth, OOM proximity |
| Leaks `.trace` | cycle list with offending classes | leak |
| Memory Graph (`.memgraph` exported from Xcode) | retained graph image + filter view | leak |
| `MXMemoryMetric.peakMemoryUsage` p95 / p99 over `<window>` | footprint distribution by cohort | transient peak, persistent growth, OOM proximity |
| `MXMetaData.foregroundBytes` (iOS 18+) | per-payload foreground footprint snapshot | persistent growth, OOM proximity |
| `MXCrashDiagnostic` payload, `terminationReason: 0xc00010ff` | the jetsam crash itself | OOM kill |
| `MXAppExitMetric.foregroundExitData.cumulativeMemoryResourceLimitExitCount` | rate of OOM kills per cohort per build | OOM kill |
| XCTest `XCTMemoryMetric` baseline diff | RSS-side regression bar pre-merge | transient peak, dev-loop signal only |

Capture recipes Apollo runs unattended (full table in `apollo/_shared/primitives/instruments-index.md §Capture commands`):

| Class | Recipe |
|---|---|
| Transient peak | `xctrace record --template "Allocations" --device "<udid>" --launch -- "<bundle>" --time-limit 60s --output peak.trace` paired with an AXe-driven scenario script that brackets the workload with `OSSignposter` intervals |
| Persistent growth | `xctrace record --template "VM Tracker" --device "<udid>" --launch -- "<bundle>" --time-limit 180s --output growth.trace` driving a 5-scenario loop; export `vm-op` schema and diff post-vs-pre footprint |
| Leak | `xctrace record --template "Leaks" --device "<udid>" --launch -- "<bundle>" --time-limit 90s --output leaks.trace` plus Xcode Memory Graph snapshot captured via XcodeBuildMCP after scenario settles 30 s |
| OOM reproduction | XcodeBuildMCP build → AXe loop the suspected scenario until `MXAppExitMetric.foregroundExitData.cumulativeMemoryResourceLimitExitCount` increments in a fresh `pastPayloads` read, then capture VM Tracker on the prior run |

Companion CLI tools Apollo invokes through the execution surface for ad-hoc analysis on a captured `.trace` or against a paused simulator process:

| Tool | Use | Notes |
|---|---|---|
| `vmmap <pid>` | Region-by-region resident / dirty / swapped breakdown | Sample at scenario boundaries; diff two `vmmap` outputs to localize growth to a region (`MALLOC_LARGE`, `IOKit`, `Foundation`-tagged regions) |
| `heap <pid>` | Class histogram of objc + Swift class instances | Quick sanity check before opening Allocations; counts only, no stacks |
| `leaks <pid>` | Reachability scan; reports cycles | Same engine as the Leaks instrument; CLI is faster for scripted runs |
| `malloc_history <pid> <addr>` | Backtrace history for a specific allocation | Requires `MallocStackLogging=1` or `MallocStackLoggingNoCompact=1` env at process launch — Apollo sets these for capture-only runs |

Failures that classify cleanly:

| Failure | Classification | Apollo action |
|---|---|---|
| Capture path not installed (e.g. `xctrace` missing, simulator not paired) | permanent | Refuse with explicit unblock recipe; route to human via `apollo/_shared/primitives/execution-surface.md §Tool installation contract` |
| Captured artifact lacks the signpost the diagnosis named | ambiguous | Single retry with corrected scenario script; on second miss, refuse |
| Capture exceeds session budget | transient | Schedule deferred capture row at `apollo/deferred/<id>.yaml`; refuse for now with `--deferred <id>` resumption recipe |

Phase 2 emits `apollo_capture_started` at scenario start and `apollo_capture_completed` (or `apollo_capture_deferred`) at end. Both events carry `mode: memory`, `class`, `artifact_shape`, `cohort`, `scenario`. The full event set lands in `_shared/contracts/events.md` alongside this mode pack.

## Phase 3 — Propose

Goal: emit a recommendation rooted in the captured artifact, or refuse explicitly. The phase has only two terminal states.

Decision rule:

| Captured evidence | Propose action |
|---|---|
| Hard evidence (9/10) — cited artifact + scenario + cohort + signpost — present | Emit `apollo_recommendation` |
| Soft / no evidence after auto-capture-before-refuse exhausts the tree | Emit `apollo_refused` with verbatim refusal block from `evidence-gate.md §Refusal protocol` |
| Curated canonical anti-pattern matches the diff AND measurement is structurally impossible | Emit `apollo_advisory` with the literal `advisory:1` prefix and zero impact claim — see `apollo/_shared/primitives/canonical-antipatterns.md` |

Recommendation shape — every memory recommendation Apollo writes carries these fields, in this order:

```
RECOMMEND (memory:<class>): <one-line summary>
  evidence: <artifact-path> <citation-form from primitives>
  scenario: <name>, signpost <name>, cohort <modelCode>/<osMajor>, build <version>
  diff_target: <file:line | symbol> (from Allocations / Memory Graph / vmmap)
  expected_delta: <metric> p<percentile> -<X>% on cohort <modelCode>/<osMajor>
  verification_recipe: <xctrace command> | <XCTest target.method>
  patch_owner: achilles  # always — Apollo never patches in-process
```

The `expected_delta` field is load-bearing: it is the criterion the re-measure phase verifies. A recommendation without an expected delta is rejected by the gate — there is nothing for re-measure to falsify.

Mapped fix archetypes per signal class. Apollo cites the archetype, not the intuition; the cited artifact is what supports the choice.

| Class | Archetype | Signal in artifact | Archetype-specific cohort risk |
|---|---|---|---|
| Transient peak | Stream the workload (chunked decode, paged read, async iterator) instead of materializing | Allocations top-stack at scenario apex shows a single allocation > 50% of total | Streaming may cost CPU; pair with Time Profiler to avoid trading memory for thermal regression |
| Transient peak | Drain `@autoreleasepool` around the hot loop (Obj-C / bridged Swift) | Allocations "Autoreleased" filter shows growth bounded only by main-loop tick | Pure Swift code does not benefit; refuse archetype if the stack is Swift-only |
| Persistent growth | Bound the cache (LRU with explicit limit; weak-keyed `NSCache`) | VM Tracker dirty climbs monotonically across scenarios; Allocations "Persistent" filter shows class with unbounded count | Tightening the bound may raise miss rate; only valid when miss-cost is bounded by signposted re-fetch interval |
| Persistent growth | Release retained `Image` / `CIImage` / `MTLTexture` after presentation | VM Tracker `IOKit` region grows without GPU work; `MXMemoryMetric.peakMemoryUsage` p99 climbs while CPU flat | Critical on iOS — Metal textures live outside the heap and don't show in Allocations |
| Leak | Break ARC retain cycle (closure capture list, delegate weak-ref) | Leaks template cycle list; Memory Graph cycle highlight; missing `<Type>.deinit` event | Capturing `[weak self]` changes lifetime semantics; the recommendation MUST include the call sites that remain meaningful |
| Leak | Bridge a CF retain (`Unmanaged.takeRetainedValue` vs `takeUnretainedValue`) correctly | `malloc_history` shows long-lived `CF*` allocation with no app-side `release` site | Wrong direction silently overreleases — recommend always paired with a unit test on the bridge |
| OOM kill | Lower the per-frame footprint of the Metal command stream (page texture uploads, drop ROI for non-visible layers) | VM Tracker IOKit + `cumulativeForegroundEnergy` co-rise; `MXCrashDiagnostic` callstack roots in render thread | Metal-specific archetypes route to the `imgly-engine-expert` skill via the Stage 3 delegation contract (#233); Apollo retains measurement authority and refuses to bake Metal internals into this mode pack |

The Metal carve-out is firm: Apollo never proposes a specific Metal change. Apollo names "render-pipeline footprint regression at <signpost>", attaches the cited evidence, and the Metal/Imgly knowledge lives in the dedicated skill. This keeps Apollo Imgly-agnostic.

## Phase 4 — Patch

Goal: hand the recommendation to Achilles for the in-tree change. Apollo does not edit code.

Handoff record — Apollo writes a recommendation artifact at `~/.dev-studio/<project>/apollo/recommendations/<id>.md` and emits the brief on the studio path Chanakya consumes:

```yaml
mode: memory
class: <signal-class>
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
```

Achilles applies the patch on a worktree per its normal flow; Argus reviews per its normal flow. Apollo does not bypass either. The recommendation artifact is the brief seed Chanakya turns into a task — Apollo's role ends at handoff.

R17 ownership stays intact — Apollo writes only under `~/.dev-studio/<project>/apollo/`. No writes reach `briefs/`, `debriefs/`, the worktree, or task YAML.

## Phase 5 — Re-measure

Goal: confirm the regression resolved by capturing the same artifact shape under the same scenario on the patched build, then running the regression-detection math.

The phase has three terminal states, each emitted as an event with `apollo_recommendation` follow-up data so the dashboard can pair pre-fix and post-fix.

| Outcome | Criterion | Action |
|---|---|---|
| Verified | Post-fix capture's metric crosses the `expected_delta` threshold AND `apollo/_shared/primitives/regression-detection.md §Decision rule` returns `confirmed regression resolved` (significance test passes, sample sizes met, cohort exact) | Emit `apollo_recommendation` follow-up with `status: verified`; persist post-fix artifact alongside pre-fix |
| Partial | Post-fix capture moves the metric in the right direction but below the threshold or fails significance | Emit follow-up with `status: partial`; recommendation remains open, Apollo names what additional evidence would close it |
| Regressed | Post-fix capture moves the metric the wrong direction, or a sibling metric (e.g. CPU on a streaming archetype) regressed | Emit follow-up with `status: regressed`; recommendation rolled back; new diagnose phase opens with the post-fix artifact as input |

Verification artifact requirements (R10 sister-rule for Apollo):

| Claim | Required artifact |
|---|---|
| "memory regression resolved" | post-fix `.trace` of the same template + scenario + cohort as the pre-fix capture, both retained at `apollo/captures/<id>/` |
| "OOM rate dropped" | post-fix `MXAppExitMetric` payload from the same cohort, ≥ 48 h post-build availability per `apollo/_shared/primitives/organizer-asc.md §Build availability` |
| "leak fixed" | post-fix Leaks `.trace` showing zero cycles for the named class AND a `<Type>.deinit` event in the trace timeline |

Apollo refuses any "resolved" claim that lacks a paired post-fix artifact. The pre-fix artifact stays retained — it is the audit trail.

## Cohort and noise control

Memory measurements perturb under thermal pressure, charging state, and OS minor differences. Apollo discards a captured run from regression math when:

| Condition | Source | Why |
|---|---|---|
| `MXMetaData.thermalState > .fair` during the capture window | `MXMetaData` | Thermal throttling perturbs allocator paths and IOKit |
| `MXMetaData.batteryChargingState != .unplugged` for the capture window | `MXMetaData` | Charging state biases footprint via background indexing daemons |
| First iteration of `XCTApplicationLaunchMetric`-paired memory test | XCTest options | Code-signing + first-launch costs are not the regression |
| Cohort tag mismatch between pre-fix and post-fix capture | `MXMetaData.deviceType` / `LocalComputer.modelCode` | Cross-cohort diff is a category error per `apollo/_shared/primitives/regression-detection.md §Cohort normalization` |

Apollo emits `apollo_capture_completed` with `discarded: true` and the reason; the run is not used in the gate but is retained for forensic review.

## Failure modes

| Failure | Classification | Apollo action |
|---|---|---|
| Free-text "we have a memory issue" with no artifact, no reachable capture path | permanent | Refuse with verbatim refusal block; name the human-required action (TestFlight install, dSYM upload) |
| Soft evidence — screenshot of Xcode debug navigator memory graph | permanent | Refuse; the navigator graph is not under the strict-9 catalogue. Auto-capture VM Tracker via xctrace if the simulator is paired |
| Capture produced but `OSSignposter` anchor missing | ambiguous | One retry with corrected scenario script; on second miss, escalate via `apollo_refused` with `reason: signpost_missing` |
| Allocations trace shows a peak but the cohort tag is `iPhone Simulator` | permanent | Refuse cross-cohort; cite `apollo/_shared/primitives/regression-detection.md §Cohort normalization`. Re-run on a real device cohort or accept advisory:1 only if archetype matches a curated antipattern |
| MetricKit `pastPayloads` empty (fresh install, no prior daily delivery) | transient | Defer — schedule capture for ≥ 24h, refuse for now with `--deferred <id>`. MetricKit's daily cadence is documented in `apollo/_shared/primitives/metrickit.md §Subscription lifecycle` |
| Capture path autonomy is `human-required` (configuration profile install, ASC dSYM upload) | permanent | Refuse with the explicit human-action block; never silently fall through |
| dSYM mismatch on symbolication of an `MXCrashDiagnostic` OOM payload | ambiguous | Single retry against ASC dSYM fetch; on miss, refuse with `reason: dsym_uuid_mismatch` and the offending UUID |
| Captured `.trace` exceeds the artifact-size budget for in-context analysis | transient | Export the relevant schemas via `xctrace export --xpath`; archive the raw `.trace` and cite the exported XML |
| Argus-flagged finding on the patch references a memory regression Apollo did not capture pre-fix | permanent | Refuse the verification claim; open a new Phase-1 diagnose against the post-fix capture as the pre-fix anchor for the next iteration |

The `## Failure modes` table is the procedure-level enforcement: classifications drive whether Apollo retries (`transient`), refuses (`permanent`), or escalates per the auto-capture decision tree (`ambiguous`).

## Procedure

The five-phase pipeline rendered as enforceable steps. Each step gates the transition into the next phase; gate failure routes through the auto-capture decision tree before any refusal.

1. **READ** the input artifact and classify the signal into one of {transient peak, persistent growth, leak, OOM kill}.
   Before: caller invocation specifies one of `/apollo memory`, a cited `.trace` / `MXMetricPayload` / `MXDiagnosticPayload`, or free text mentioning memory.
   After: signal class recorded; matching diagnostic-question row from §Phase 1 selected; mode-pack progress event emitted with `mode: memory`, `class`.

2. **CHECK** the strict-9 hard-evidence catalogue for the captured artifact named by the diagnosis.
   Before: signal class set in step 1; capture-set inventory at `apollo/captures/` enumerated.
   After: either the cited artifact is on disk (proceed to step 4) or the auto-capture decision tree from `apollo/_shared/primitives/execution-surface.md §Auto-capture-before-refuse decision tree` runs in step 3.

3. **RUN** the matching capture recipe from §Phase 2 unattended through the execution surface.
   Before: capability matrix entry for the recipe is `installed: true` per `~/.dev-studio/.runtime/host-capabilities.yaml`; the scenario script brackets the workload with `OSSignposter` intervals.
   After: artifact persisted at `apollo/captures/<id>/`; `apollo_capture_completed` event emitted with `cohort`, `scenario`, `signpost`, `artifact_shape`; cohort/noise gates from §Cohort and noise control evaluated; runs marked `discarded: true` are not consumed downstream.

4. **CHECK** that the captured evidence satisfies the strict-9 fields {artifact, scenario, signpost, cohort, build}; if any missing, RETRY step 3 once with corrected scenario script.
   Before: artifact persisted from step 3 (or pre-existing).
   After: gate state ∈ {hard, soft, none, advisory}. Hard advances to step 5; soft and none route through `apollo/_shared/primitives/evidence-gate.md §Refusal protocol`; advisory:1 emits `apollo_advisory` and STOPs without a recommendation.

5. **WRITE** the recommendation artifact at `apollo/recommendations/<id>.md` with the field set from §Phase 3 (evidence, scenario, diff_target, expected_delta, verification_recipe, patch_owner).
   Before: gate=hard from step 4; archetype selected from §Phase 3 archetype table; Metal-archetype recommendations delegated to the `imgly-engine-expert` skill instead of in-line.
   After: `apollo_recommendation` event emitted; brief seed YAML written for Chanakya consumption.

6. **RECORD** the handoff to Achilles per §Phase 4; Apollo does NOT mutate the worktree, briefs, or task YAML.
   Before: recommendation artifact written from step 5.
   After: brief seed available on the studio path; R17 ownership preserved (no writes outside `apollo/`); event log carries the recommendation id for cross-agent correlation.

7. **RUN** the post-fix capture using the same template, scenario, cohort, and signpost as the pre-fix capture from step 3.
   Before: Achilles task closed, Argus verdict approved, merge SHA recorded on the recommendation; the verification recipe from step 5 is reproducible.
   After: post-fix artifact persisted at `apollo/captures/<id>/post-fix/`; cohort tag verified to match pre-fix exactly per `apollo/_shared/primitives/regression-detection.md §Cohort normalization`.

8. **EMIT** the verification verdict per §Phase 5 outcome table (`verified` / `partial` / `regressed`) using `apollo/_shared/primitives/regression-detection.md §Decision rule`.
   Before: pre-fix and post-fix artifacts cohort-matched; sample-size minimums met for the cited percentile.
   After: follow-up `apollo_recommendation` event with `status: <outcome>` emitted; pre-fix and post-fix artifacts both retained; on `regressed` outcome a fresh Phase-1 diagnose opens with the post-fix capture as input.

## Handoffs

| Direction | Surface | Contract |
|---|---|---|
| → Achilles (patch) | `~/.dev-studio/<project>/apollo/recommendations/<id>.md` + brief seed | Recommendation contains `diff_target`, `expected_delta`, `verification_recipe`. Achilles applies the patch on a worktree, runs Argus per its normal flow, and merges. Apollo never invokes Achilles directly — Chanakya routes the brief. |
| → Argus (review) | None directly. | Apollo's recommendation artifact is read-only context for Argus during code review. Argus does not write Apollo state. |
| → imgly-engine-expert (Metal/Imgly archetypes) | `delegate: imgly-engine-expert` line on the recommendation when the diff target is in Imgly / Metal pipeline code | Stage 3 deliverable (#233). Until #233 ships, Apollo refuses Metal-internal recommendations and emits `advisory:1` with the canonical-antipattern citation only. |

## Singleton

Memory mode acquires `simulator-{udid}` and `xctrace-{device}` locks at step 3 entry; releases on step 3 completion. Two memory-mode investigations on the same simulator collide; cross-mode (memory + thermal on different devices) does not. Lock surface lives at `~/.dev-studio/.runtime/locks/apollo/`.

## Why this shape

The five-phase pipeline maps directly onto memory's four signal classes (per heap taxonomy) and the strict-9 evidence catalogue. Each phase has exactly one gate — the captured artifact, the cohort match, the expected delta, the post-fix verification — and each gate has a documented refusal path. Without that explicit gating, memory recommendations regress to "looks expensive, refactor it", which is the failure mode the strict-9 contract exists to prevent (see `evidence-gate.md §Why`).

The footprint-vs-RSS distinction is the dominant authorship error in memory work: a Debug-build Allocations trace looks bad on RSS while the Release-build OOM kill is keyed on footprint. Apollo cites footprint by default, RSS only as context, and refuses the bridge without explicit conversion. The cohort pin closes the second-most-common error: a regression flagged on simulator that doesn't reproduce on a 2 GB device cohort (or the inverse).

The Metal/Imgly carve-out is Apollo's compositional hinge. Imgly knowledge lives in the dedicated `imgly-engine-expert` skill; Apollo retains measurement and verification authority. The Stage 3 delegation contract (#233) formalizes the boundary; until it ships, Apollo refuses to bake Metal internals into this mode pack.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract + refusal protocol the phase gates feed into
- `apollo/_shared/primitives/metrickit.md` — `MXMemoryMetric`, `MXAppExitMetric`, `MXCrashDiagnostic` schemas
- `apollo/_shared/primitives/signposts.md` — `OSSignposter` shape + privacy default the signal table enforces
- `apollo/_shared/primitives/instruments-index.md` — Allocations / VM Tracker / Leaks template details + capture commands
- `apollo/_shared/primitives/xctest-baselines.md` — `XCTMemoryMetric` baseline diff for the dev-loop signal
- `apollo/_shared/primitives/regression-detection.md` — memory-specific footprint-vs-RSS bridge + cohort rules
- `apollo/_shared/primitives/organizer-asc.md` — peak memory + OOM rate in ASC Performance Metrics
- `apollo/_shared/primitives/execution-surface.md` — capability matrix + auto-capture decision tree
- `apollo/_shared/primitives/canonical-antipatterns.md` — memory antipatterns curated for the `advisory:1` channel
- `_shared/contracts/events.md` — `apollo_capture_*` and `apollo_recommendation` event schemas
- `REVIEW.md` R10 — sister rule for completion claims; Apollo's verification phase is the memory-mode counterpart
- WWDC24 10173 — Analyze heap memory (canonical for the heap taxonomy)
- WWDC21 10180 — Detect and diagnose memory issues
- WWDC18 416 — iOS Memory Deep Dive (canonical for VM page accounting and footprint)
- WWDC25 312 — Improve memory usage and performance with Swift
- WWDC22 10106 — Profile and optimize your game's memory
