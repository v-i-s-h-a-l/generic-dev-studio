---
name: Apollo thermal mode
description: Diagnose → measure → propose → patch → re-measure protocol for thermal regressions under strict-9 evidence gating. Covers sustained-load throttle, hang-under-thermal, CPU hot loops, and GPU-rooted heat.
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

# Mode: Thermal (`/apollo thermal`)

Thermal is the second P0 mode under the strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`). The procedure is ordered: every transition requires hard evidence cited in the catalogue, otherwise the gate refuses and auto-capture-before-refuse runs the next step in the execution-surface decision tree.

The mode treats four thermal signal classes as distinct — diagnostic question, capture template, regression math, and verification artifact differ per class. Mode packs cite the class on every recommendation; cross-class citations fail the gate. Thermal evidence is also the most noise-sensitive in Apollo's catalogue: ambient temperature, charging state, and sustained-dwell time perturb every measurement, and the §Cohort and noise control gates apply with no carve-out.

## Signal classes (thermal taxonomy)

| Class | What it looks like | Authoritative source | Apollo template |
|---|---|---|---|
| Sustained-load throttle | Foreground scenario runs long enough for `ProcessInfo.thermalState` to climb `.nominal → .fair → .serious → .critical`; CPU/GPU clocks reduced; user-visible jank or completion delay past the transition | `ProcessInfo.thermalStateDidChangeNotification` stream + `MXMetaData.thermalState` distribution | Time Profiler + CPU Counters |
| Hang-under-thermal | Main-thread blocked > 250 ms under sustained CPU pressure; `MXHangDiagnostic` payload; if exceeds the watchdog gate, `MXCrashDiagnostic` with `terminationReason: 0x8badf00d` | `MXHangDiagnostic`, `MXCrashDiagnostic` watchdog payload | Hangs (Instruments) + Time Profiler |
| CPU hot loop (E/P-core mismatch) | Workload pinned on P-cores when E-core scheduling would suffice; or QoS misplacement keeps P-cores hot for `.utility`-shaped work | `MXCPUExceptionDiagnostic` (`totalCPUTime`, `totalSampledTime`); CPU Counters per-core breakdown | CPU Counters + Processor Trace |
| GPU-rooted thermal | Heat from sustained Metal compute / fragment shading; Metal Performance HUD shows GPU 100% bound across the scenario; CPU rows flat | `MXGPUMetric.cumulativeGPUTime`, Metal Performance HUD log, Metal System Trace | Metal System Trace + Metal Performance HUD |

There is **no first-party Instruments template named "thermal"**. Apollo cites the proxy chain explicitly: `ProcessInfo.thermalState` transitions are the ground-truth signal; Time Profiler / CPU Counters / Metal System Trace / Energy Log are the proxy artifacts that resolve the cause. Recommendations citing "the device feels hot" without a proxy artifact fail the gate (`evidence-gate.md §Hard-evidence catalogue`). Energy Log is power-attribution, not thermal — Apollo uses it as a battery-mode artifact and only as supporting context here.

`ProcessInfo.thermalState` resolution is **coarse and per-device**: Apple does not publish per-state temperature thresholds, the transition cadence is on the order of tens of seconds to minutes, and serious/critical only arrive under sustained load. Apollo's minimum dwell-time bar per signal class:

| Class | Minimum sustained-capture dwell |
|---|---|
| Sustained-load throttle | ≥ 5 minutes under continuous workload (real device only — simulator's `Features → Trigger Thermal State` is a development convenience, never citable evidence) |
| Hang-under-thermal | ≥ 1 minute under sustained CPU; the hang itself is the artifact, but the thermal correlation requires the dwell |
| CPU hot loop | ≥ 1 minute under the workload; CPU Counters needs sample density to resolve IPC / mispredicts |
| GPU-rooted thermal | ≥ 30 seconds under sustained GPU work — Metal HUD frame data is denser, but cross-frame thermal correlation still needs the dwell |

Any cited capture below the dwell bar is downgraded to soft evidence and fails the gate. The bar is the load-bearing line that prevents "I ran Time Profiler for 20 seconds and saw a hot stack" from passing as thermal evidence.

## thermalState reaction protocol

Apollo enforces an app-side observer contract: `ProcessInfo.thermalStateDidChangeNotification` must drive a per-state load-shedding response. The contract is what makes a thermal recommendation falsifiable — without it, "the app got hotter" is unattributable to the workload.

| State | Apple-published behavior | Required app response | Evidence form |
|---|---|---|---|
| `.nominal` | normal operation | none | n/a |
| `.fair` | slight performance impact possible; OS may throttle silently | drop non-essential background work; reduce analytics cadence; avoid kicking off new prefetch | observer present; `OSSignposter` event at the transition with `state: .public` payload |
| `.serious` | OS throttling actively; user noticing heat | drop frame rate (60 → 30), pause non-visible animations, downsample image / capture pipelines, defer prefetch, reduce capture FPS, throttle camera frame delivery | observer reacting in code; signposted shed-event |
| `.critical` | OS shedding load to prevent emergency shutdown | suspend all non-essential work; minimum interactive frame rate; stop background capture / encode; drop to lowest-fidelity render path | observer reacting in code; ideally a documented "low-thermal mode" path |

Recommendations that target a `.serious` / `.critical` regression but cannot cite the observer's shed-event signpost in the trace fail the gate. The observer is the contract — its absence is the bug.

## Phase 1 — Diagnose

Goal: classify the signal into one of {sustained-load throttle, hang-under-thermal, CPU hot loop, GPU-rooted thermal} and pick the matching template + signpost shape. No fix proposed at this phase.

Inputs Apollo accepts: `MXMetricPayload` JSON, `MXDiagnosticPayload` JSON, ASC Performance / Power Metrics row, `.xcresult` bundle, `.trace` file (Time Profiler / CPU Counters / Processor Trace / Metal System Trace), Metal Performance HUD log, or a free-text report citing one of those. Free text without a cited artifact triggers auto-capture-before-refuse.

| Diagnostic question | Template | Signpost shape | Citation (passes gate) |
|---|---|---|---|
| Did `ProcessInfo.thermalState` cross to `.serious`/`.critical` during the scenario? | Time Profiler + thermalState observer | `OSSignposter` event `<thermalState>` `.public` payload at transition; interval `<Scenario>` brackets the workload | Time Profiler `.trace` weighted-call-tree at the transition timestamp; `MXMetaData.thermalState` distribution > 0% serious for cohort |
| Did the main thread hang while CPU climbed? | Hangs (Instruments) + Time Profiler | `OSSignposter` interval `<Scenario>`; main-thread block surfaces in the Hangs track | `MXHangDiagnostic` payload with `hangDuration ≥ 250 ms`, callStackTree captured, cohort + build pinned; or watchdog `MXCrashDiagnostic` (`0x8badf00d`) when the hang exceeded the gate |
| Is the hot loop on a P-core when an E-core would do? | CPU Counters + Processor Trace | `OSSignposter` interval `<Scenario>` chained with `qos: .public` event payload at task entry | CPU Counters per-core breakdown showing P-core saturation while E-cores idle for the cited interval; Processor Trace resolves the retired-instruction stream when Counters alone are ambiguous |
| Is the GPU the heat source? | Metal System Trace + Metal Performance HUD | `OSSignposter` interval `<Scenario>` paired with `MTLCommandBuffer` boundary signposts (Metal already emits these via the framework) | Metal System Trace `.trace` showing fragment / compute shader > 80% of frame time under load; or Metal HUD log with `gpuTimeMs` > frame-budget for the scenario |

The signposts table is enforced — Apollo refuses a thermal recommendation whose source lacks an `OSSignposter` anchor for the cited interval. The privacy default (`.private`) silently aggregates `MXSignpostMetric` payloads as opaque, which is the most common silent-bug shape (`apollo/_shared/primitives/signposts.md §Custom metadata`); recommendations that cite an opaque MetricKit aggregation fail the gate.

## Phase 2 — Measure

Goal: produce the cited artifact under the strict-9 catalogue entry the diagnosis demands. Either the user supplied it, an existing capture matches, or auto-capture runs.

Hard-evidence catalogue rows for thermal (from `apollo/_shared/primitives/evidence-gate.md §Hard-evidence catalogue`):

| Source | Property / artifact | When to cite |
|---|---|---|
| Time Profiler `.trace` | weighted call tree at thermalState transition; sustained-dwell sample density | sustained-load throttle, hang-under-thermal |
| CPU Counters `.trace` | cycles, instructions, branch mispredicts, L1D/LLC misses; derived IPC | CPU hot loop, sustained-load proxy |
| Processor Trace `.trace` | retired-instruction stream (A15+ / iOS 16+) | CPU hot loop when Counters are ambiguous; the only template that resolves micro-arch stalls |
| Metal System Trace `.trace` | command-buffer execution + thermal correlation row | GPU-rooted thermal |
| Metal Performance HUD log | per-frame GPU utilization, thermal flags, on-screen overlay export | GPU-rooted thermal, real-device only |
| `MXMetaData.thermalState` per-payload distribution | % time in `.fair` / `.serious` / `.critical` over `<window>`, per cohort | every signal class — cohort proxy |
| `MXCPUMetric.cumulativeCPUTime` per foreground hour | normalized CPU-time per hour, per cohort | sustained-load throttle, CPU hot loop |
| `MXCPUExceptionDiagnostic` payload | callStackTree, `totalCPUTime`, `totalSampledTime` | sustained-load throttle, CPU hot loop |
| `MXHangDiagnostic` payload | callStackTree, `hangDuration` | hang-under-thermal |
| `MXCrashDiagnostic` payload, `terminationReason: 0x8badf00d` | watchdog crash (hang exceeded gate) | hang-under-thermal escalated |
| `MXGPUMetric.cumulativeGPUTime` per foreground hour | normalized GPU-time per hour, per cohort | GPU-rooted thermal |
| ASC Performance / Power Metrics row | per-build aggregate thermal + power correlate | every signal class — production fleet read |

Capture recipes Apollo runs unattended (full table in `apollo/_shared/primitives/instruments-index.md §Capture commands`):

| Class | Recipe |
|---|---|
| Sustained-load throttle | `xctrace record --template "Time Profiler" --device "<udid>" --launch -- "<bundle>" --time-limit 360s --output sustained.trace` paired with an AXe-driven scenario that holds the workload at peak for ≥ 5 min; observer-side `OSSignposter` event fires on every thermalState transition |
| Sustained-load throttle (GPU-shaped) | `xctrace record --template "Metal System Trace" --device "<udid>" --launch -- "<bundle>" --time-limit 360s --output sustained-gpu.trace`; same scenario script |
| Hang-under-thermal | `xctrace record --template "Hangs" --device "<udid>" --launch -- "<bundle>" --time-limit 120s --output hang.trace` driving the suspected scenario; pair with Time Profiler on a second run for stack attribution; cross-cite `MXHangDiagnostic` from the same build's `pastPayloads` |
| CPU hot loop | `xctrace record --template "CPU Counters" --device "<udid>" --launch -- "<bundle>" --time-limit 90s --output cpu.trace`; pick counter set per §Counter routing below; on ambiguity escalate to Processor Trace (`xctrace record --template "Processor Trace" --device "<udid>" --launch -- "<bundle>" --time-limit 60s --output ptrace.trace`) — only on iOS 16+ / A15+ |
| GPU-rooted thermal | `xctrace record --template "Metal System Trace" --device "<udid>" --launch -- "<bundle>" --time-limit 60s --output gpu.trace` plus Metal Performance HUD log captured via XcodeBuildMCP environment (`MTL_HUD_ENABLED=1`); sustained scenario ≥ 30 s |

Counter routing for CPU Counters (per `apollo/_shared/primitives/instruments-index.md §CPU Counters`):

| Question | Counter set | Citation form |
|---|---|---|
| Are we IPC-starved (memory-bound or stall-bound)? | Cycles + Instructions Retired; derive IPC = retired / cycle | IPC < 1.5 under sustained load → memory-bound; cite the per-stack IPC at the hot frame |
| Are branch mispredicts dominating? | Cycles + Branch Mispredicts | Mispredict rate > 5% of branches at the hot stack — wasted speculative work as pure heat |
| Are we waiting on the cache hierarchy? | Cycles + L1D-cache-miss + LLC-cache-miss | LLC miss > 5% of accesses at the hot stack → main-memory traffic → heat |
| Is one core scheduled flat-out while siblings idle? | Per-core cycles | Single-core saturation visible in the per-core lane; archetype is single-thread bottleneck (no easy E-core shift) |

Companion CLI tools Apollo invokes through the execution surface for ad-hoc analysis on a captured `.trace` or against a paused process:

| Tool | Use | Notes |
|---|---|---|
| `powermetrics --samplers thermal,cpu_power,gpu_power -i 1000` | macOS-host thermal + power sample stream | Host-only — captures the host SoC, not the connected iOS device. Use only when reproducing on Apple Silicon Mac dev hardware; never citable as iOS evidence |
| `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` | Extract weighted call tree from a `.trace` | Apollo cites the exported XML, never the binary `.trace`, when artifact-size budget is tight |
| `xcrun simctl spawn booted notifyutil -p com.apple.system.thermal.serious` | Trigger simulator thermal notification (development only) | Drives the observer code path; the resulting trace is **not** evidence — simulator does not throttle real silicon |
| `MTL_HUD_ENABLED=1` (env var at launch) | Enable Metal Performance HUD on real device | HUD overlay; export the log via XcodeBuildMCP for citation |

Failures that classify cleanly:

| Failure | Classification | Apollo action |
|---|---|---|
| Capture path not installed (`xctrace` missing, real device not paired) | permanent | Refuse with explicit unblock recipe; route to human via `apollo/_shared/primitives/execution-surface.md §Tool installation contract` |
| Capture dwell below the §Signal classes minimum | ambiguous | Single retry with extended `--time-limit`; on second miss, refuse |
| Captured artifact lacks the signpost the diagnosis named | ambiguous | Single retry with corrected scenario script; on second miss, refuse |
| Capture exceeds session budget (sustained-load runs are minutes-long) | transient | Schedule deferred capture row at `apollo/deferred/<id>.yaml`; refuse for now with `--deferred <id>` resumption recipe |

Phase 2 emits `apollo_capture_started` at scenario start and `apollo_capture_completed` (or `apollo_capture_deferred`) at end. Both events carry `mode: thermal`, `class`, `artifact_shape`, `cohort`, `scenario`, `dwell_seconds`. The full event set lands in `_shared/contracts/events.md` alongside this mode pack.

## Phase 3 — Propose

Goal: emit a recommendation rooted in the captured artifact, or refuse explicitly. The phase has only two terminal states.

Decision rule:

| Captured evidence | Propose action |
|---|---|
| Hard evidence (9/10) — cited artifact + scenario + cohort + signpost + dwell ≥ §Signal classes minimum — present | Emit `apollo_recommendation` |
| Soft / no evidence after auto-capture-before-refuse exhausts the tree | Emit `apollo_refused` with verbatim refusal block from `evidence-gate.md §Refusal protocol` |
| Curated canonical anti-pattern matches the diff AND measurement is structurally impossible | Emit `apollo_advisory` with the literal `advisory:1` prefix and zero impact claim — see `apollo/_shared/primitives/canonical-antipatterns.md` |

Recommendation shape — every thermal recommendation Apollo writes carries these fields, in this order:

```
RECOMMEND (thermal:<class>): <one-line summary>
  evidence: <artifact-path> <citation-form from primitives>
  scenario: <name>, signpost <name>, cohort <modelCode>/<osMajor>, build <version>, dwell <seconds>s
  diff_target: <file:line | symbol> (from Time Profiler / CPU Counters / Metal System Trace)
  expected_delta: <metric> p<percentile> -<X>% on cohort <modelCode>/<osMajor>
  verification_recipe: <xctrace command> | <XCTest target.method>
  patch_owner: achilles  # always — Apollo never patches in-process
```

The `expected_delta` field is load-bearing: it is the criterion the re-measure phase verifies. Thermal `expected_delta` cites one of `MXMetaData.thermalState` distribution shift (% time in `.serious` drop), `MXCPUMetric.cumulativeCPUTime` per-hour delta, `MXGPUMetric.cumulativeGPUTime` per-hour delta, or Time Profiler weighted-self-time delta at the hot stack — never an unattributed "the device runs cooler" claim.

Mapped fix archetypes per signal class. Apollo cites the archetype, not the intuition; the cited artifact is what supports the choice.

| Class | Archetype | Signal in artifact | Archetype-specific cohort risk |
|---|---|---|---|
| Sustained-load throttle | Move offscreen / non-interactive work to E-cores via `.utility` or `.background` QoS (`Task(priority:)`, `DispatchQueue.global(qos:)`) | Time Profiler shows steady CPU on P-core during work that has no user-facing deadline; Per-core CPU Counters confirms P-core saturation | Wrong QoS on user-facing work delays response; archetype valid only when the work is offscreen, non-blocking, and lacks a frame deadline |
| Sustained-load throttle | Yield long-running loops via `Task.yield()` / `await` checkpoints; chunk synchronous work into cooperative units | `MXCPUExceptionDiagnostic` callStack shows monotonic CPU; `cumulativeCPUTime` p99 climbs while wall-clock work bounded | Yields cost cooperative-scheduler turns; archetype valid only when work is interruptible — pure compute kernels do not benefit |
| Sustained-load throttle | Honor `ProcessInfo.thermalState` observer — drop FPS, pause prefetch, reduce capture pipeline fidelity on `.serious` | Trace timeline shows scenario continues at full intensity past the `.serious` transition signpost; observer absent or no-op | Throttling user-visible features below `.serious` is too aggressive; archetype scoped to `.serious` / `.critical` shed paths only |
| Hang-under-thermal | Move blocking work off main; replace `dispatch_sync` / `DispatchSemaphore.wait` with structured concurrency | `MXHangDiagnostic` callStack roots in main; Time Profiler on main thread matches; concurrent CPU climb visible in trace | Concurrency rewrites can introduce data races; archetype paired with Sendable-compliance check on changed types |
| CPU hot loop | Vectorize via Accelerate (vDSP / vForce / BNNS) when the math is SIMD-friendly | Time Profiler shows scalar floating-point inner loop; CPU Counters IPC < 1.5 under load | Accelerate APIs are platform-specific; archetype scoped to iOS / macOS targets that link Accelerate |
| CPU hot loop | Cache-friendlier data layout (struct-of-arrays vs array-of-structs; pointer-chase reduction) | LLC-cache-miss rate > 5% at the hot stack; sequential-access path resolves lower miss rate | Refactor surface is wide; archetype valid only when miss rate is the dominant cycle consumer per Counters |
| GPU-rooted thermal | Reduce per-frame fragment work (lower-resolution offscreen targets, scissor non-visible regions, drop redundant passes) | Metal System Trace shows fragment shader > 80% of frame time under sustained load; HUD `gpuTimeMs` exceeds frame budget | Quality regression possible; archetype scoped to scenarios where thermal trumps fidelity. **Metal-specific archetypes delegate to `imgly-engine-expert` via `apollo/_shared/integrations/imgly-and-metal.md`**; Apollo retains measurement authority and refuses to bake Metal internals into this mode pack |
| GPU-rooted thermal | Coalesce command buffers / drop redundant draw calls / batch encoder work | Metal System Trace shows > 100 draw calls per frame; CPU encode time co-rises | Refactor surface is large; delegate to `imgly-engine-expert` per `apollo/_shared/integrations/imgly-and-metal.md` when the pipeline is owned there; if delegation surface is unavailable (skill not vendored), emit `advisory:1` with the canonical-antipattern citation only |

The Metal carve-out is firm: Apollo never proposes a specific Metal change. Apollo names "render-pipeline thermal regression at <signpost>", attaches the cited evidence, and the Metal/Imgly knowledge lives in the dedicated skill. This keeps Apollo Imgly-agnostic.

## Phase 4 — Patch

Patch handoff contract: `apollo/_shared/primitives/mode-pack-scaffold.md §Phase 4 — Patch (handoff contract)`. Thermal's mode-specific brief-seed delta extends the base `evidence:` list with `dwell_seconds: <N>` — Achilles needs the dwell to reproduce the scenario, and Apollo refuses any thermal handoff that omits it.

## Phase 5 — Re-measure

Re-measure outcome state machine (verified / partial / regressed): `apollo/_shared/primitives/mode-pack-scaffold.md §Phase 5 — Re-measure (outcome state machine)`. Thermal's match-axes tuple is the scaffold base set plus `dwell` — pre-fix and post-fix dwell must match exactly; comparing 60 s vs 360 s captures hides regressions in the dwell delta. Sibling-metric regressions worth flagging on thermal archetypes: battery on the "vectorize" archetype, memory on the "lower-res offscreen" archetype.

Verification artifact requirements (R10 sister-rule for Apollo):

| Claim | Required artifact |
|---|---|
| "thermal regression resolved" | post-fix `.trace` of the same template + scenario + cohort + dwell as the pre-fix capture, both retained at `apollo/captures/<id>/`; `MXMetaData.thermalState` distribution shift attested across ≥ 7 days of post-fix MetricKit payloads from the same cohort |
| "hang resolved" | post-fix Hangs `.trace` under the same scenario showing `hangDuration < 250 ms` AND a fresh `MXHangDiagnostic` window for the build with rate drop |
| "GPU thermal resolved" | post-fix Metal System Trace under matched sustained scenario AND `MXGPUMetric.cumulativeGPUTime` per-hour drop over the same cohort window |

## Cohort and noise control

Thermal measurements perturb under ambient temperature, charging state, OS minor differences, and SoC variant. Apollo discards a captured run from regression math when:

| Condition | Source | Why |
|---|---|---|
| `MXMetaData.batteryChargingState != .unplugged` for the capture window | `MXMetaData` | Charging warms the battery, raises ambient device temp, biases every thermal proxy |
| `MXMetaData.thermalState` already `.serious` at scenario start | `MXMetaData` | Pre-warmed device perturbs the climb curve; the regression must start from a cooled baseline |
| First minute after launch | XCTest options | Code-signing + first-launch warmup is not the regression — Apollo trims the leading 60 s |
| Ambient temperature unknown or outside 18–25 °C window | manual annotation only | No API surface; Apollo refuses cross-temperature comparisons unless the user pins the value in the capture metadata |
| Cohort tag mismatch between pre-fix and post-fix capture (`MXMetaData.deviceType` / `LocalComputer.modelCode`) | `MXMetaData` / LocalComputer | Apple Silicon variants throttle differently per chip — A15 vs A17 Pro vs A18 cannot be cross-compared |
| Dwell-time mismatch between pre-fix and post-fix capture | trace metadata | Sustained-load curves are non-linear — comparing 60 s vs 360 s captures hides the regression in the dwell delta |

Apollo emits `apollo_capture_completed` with `discarded: true` and the reason; the run is not used in the gate but is retained for forensic review.

## Failure modes

| Failure | Classification | Apollo action |
|---|---|---|
| Free-text "the phone gets hot" with no artifact, no reachable capture path | permanent | Refuse with verbatim refusal block; name the human-required action (real-device pairing, TestFlight install, dSYM upload) |
| Soft evidence — Xcode debug-navigator energy gauge screenshot | permanent | Refuse; the navigator gauge is not under the strict-9 catalogue. Auto-capture Time Profiler / Metal System Trace via xctrace if a real device is paired |
| Capture produced but `OSSignposter` anchor missing | ambiguous | One retry with corrected scenario script; on second miss, escalate via `apollo_refused` with `reason: signpost_missing` |
| Capture produced on simulator only (no real-device pairing) | permanent | Refuse for sustained-load and CPU hot loop classes — simulator does not throttle real silicon. Hangs may proceed on simulator (the API surface is what's measured); CPU hot loop may proceed only when the workload is platform-portable AND the user accepts advisory:1 |
| Capture dwell below the §Signal classes minimum | ambiguous | One retry with extended `--time-limit`; on second miss, refuse with `reason: dwell_below_threshold` |
| `MXMetaData.thermalState` distribution lacks `.serious`/`.critical` time for the window | permanent | Refuse a sustained-load recommendation; the OS-level signal is absent. Re-bait the workload or downgrade the diagnosis |
| MetricKit `pastPayloads` empty (fresh install, no prior daily delivery) | transient | Defer — schedule capture for ≥ 24 h, refuse for now with `--deferred <id>`. MetricKit's daily cadence is documented in `apollo/_shared/primitives/metrickit.md §Subscription lifecycle` |
| Capture path autonomy is `human-required` (real-device pairing, configuration profile install, ASC dSYM upload) | permanent | Refuse with the explicit human-action block; never silently fall through |
| dSYM mismatch on symbolication of an `MXCrashDiagnostic` watchdog payload | ambiguous | Single retry against ASC dSYM fetch; on miss, refuse with `reason: dsym_uuid_mismatch` and the offending UUID |
| Ambient temperature unpinned and pre-fix vs post-fix devices in different rooms / seasons | permanent | Refuse cross-environment comparison; cite §Cohort and noise control. Re-run on a controlled bench |
| Argus-flagged finding on the patch references a thermal regression Apollo did not capture pre-fix | permanent | Refuse the verification claim; open a new Phase-1 diagnose against the post-fix capture as the pre-fix anchor for the next iteration |

The `## Failure modes` table is the procedure-level enforcement: classifications drive whether Apollo retries (`transient`), refuses (`permanent`), or escalates per the auto-capture decision tree (`ambiguous`).

## Procedure

The five-phase pipeline rendered as enforceable steps. Each step gates the transition into the next phase; gate failure routes through the auto-capture decision tree before any refusal. Steps 5–8 follow `apollo/_shared/primitives/mode-pack-scaffold.md §Procedure boilerplate`; only steps 1–4 (mode-specific signal parsing through gate evaluation) are inlined here. Thermal's match-axes tuple for step 7 extends the scaffold base set with `dwell`, and step 8 requires ≥ 7 days of post-fix MetricKit `MXMetaData.thermalState` distribution when the claim cites field thermal state.

1. **READ** the input artifact and classify the signal into one of {sustained-load throttle, hang-under-thermal, CPU hot loop, GPU-rooted thermal}.
   Before: caller invocation specifies one of `/apollo thermal`, a cited `.trace` / `MXMetricPayload` / `MXDiagnosticPayload`, or free text mentioning thermal / heat / throttling.
   After: signal class recorded; matching diagnostic-question row from §Phase 1 selected; mode-pack progress event emitted with `mode: thermal`, `class`.

2. **CHECK** the strict-9 hard-evidence catalogue for the captured artifact named by the diagnosis, including the §Signal classes dwell minimum.
   Before: signal class set in step 1; capture-set inventory at `apollo/captures/` enumerated.
   After: either the cited artifact is on disk and meets the dwell bar (proceed to step 4) or the auto-capture decision tree from `apollo/_shared/primitives/execution-surface.md §Auto-capture-before-refuse decision tree` runs in step 3.

3. **RUN** the matching capture recipe from §Phase 2 unattended through the execution surface, holding the workload at peak for the dwell minimum.
   Before: capability matrix entry for the recipe is `installed: true` per `~/.dev-studio/.runtime/host-capabilities.yaml`; a real device is paired for sustained-load and CPU hot loop classes (simulator-only is permanent failure for those classes); the scenario script brackets the workload with `OSSignposter` intervals and emits the per-`thermalState` transition signposts.
   After: artifact persisted at `apollo/captures/<id>/`; `apollo_capture_completed` event emitted with `cohort`, `scenario`, `signpost`, `artifact_shape`, `dwell_seconds`; cohort/noise gates from §Cohort and noise control evaluated; runs marked `discarded: true` are not consumed downstream.

4. **CHECK** that the captured evidence satisfies the strict-9 fields {artifact, scenario, signpost, cohort, build, dwell}; if any missing, RETRY step 3 once with corrected scenario script or extended `--time-limit`.
   Before: artifact persisted from step 3 (or pre-existing).
   After: gate state ∈ {hard, soft, none, advisory}. Hard advances to step 5; soft and none route through `apollo/_shared/primitives/evidence-gate.md §Refusal protocol`; advisory:1 emits `apollo_advisory` and STOPs without a recommendation.

5–8. **PROCEED** through the scaffold boilerplate (`apollo/_shared/primitives/mode-pack-scaffold.md §Procedure boilerplate`): WRITE the recommendation, RECORD the handoff to Achilles, RUN the post-fix capture matching the base axes plus `dwell`, EMIT the verification verdict.

## Handoffs

| Direction | Surface | Contract |
|---|---|---|
| → Achilles (patch) | `~/.dev-studio/<project>/apollo/recommendations/<id>.md` + brief seed | Recommendation contains `diff_target`, `expected_delta`, `verification_recipe`, `dwell_seconds`. Achilles applies the patch on a worktree, runs Argus per its normal flow, and merges. Apollo never invokes Achilles directly — Chanakya routes the brief. |
| → Argus (review) | None directly. | Apollo's recommendation artifact is read-only context for Argus during code review. Argus does not write Apollo state. |
| → imgly-engine-expert (Metal/Imgly archetypes) | `delegate: imgly-engine-expert` line on the recommendation when the diff target is in Imgly / Metal pipeline code | Handoff envelope: `apollo/_shared/integrations/imgly-and-metal.md` (`apollo_to_expert` / `expert_to_apollo` blocks). If the receiving skill is not vendored in the project, refuse with the standard refusal block and emit `advisory:1` with the canonical-antipattern citation only. |

## Singleton

Thermal mode acquires `simulator-{udid}`, `xctrace-{device}`, and `real-device-{udid}` locks at step 3 entry; releases on step 3 completion. Sustained-load and CPU hot loop captures hold the real-device lock for the full dwell minimum (≥ 5 min for sustained-load) — concurrent thermal investigations on the same device collide on the lock, not silently corrupt each other's traces. Cross-mode (memory + thermal on different devices) does not collide. Lock surface lives at `~/.dev-studio/.runtime/locks/apollo/`.

## Why this shape

The five-phase pipeline maps directly onto thermal's four signal classes and the strict-9 evidence catalogue. Each phase has exactly one gate — the captured artifact, the cohort + dwell match, the expected delta, the post-fix verification — and each gate has a documented refusal path. Without that explicit gating, thermal recommendations regress to "the device feels hot, throttle something", which is the failure mode the strict-9 contract exists to prevent (see `evidence-gate.md §Why`).

The "no first-party Instruments thermal template" gap is the dominant tooling error in thermal work: authors look for a single trace named "thermal" and don't find one, then either give up or cite Energy Log (which is power, not thermal). Apollo names the proxy chain explicitly: `ProcessInfo.thermalState` transitions are the ground-truth signal; Time Profiler / CPU Counters / Metal System Trace are the proxy artifacts that resolve the cause. The dwell-minimum bar closes the second-most-common error: a 20-second Time Profiler capture that "showed a hot stack" cannot reach `.serious` and is therefore not thermal evidence.

The thermalState observer contract is the third load-bearing invariant: a regression that targets a `.serious` / `.critical` shed path is unfalsifiable without an observer-side signpost. Apollo refuses to propose a fix to a system the app does not yet observe — the first remediation in that case is to add the observer, not to throttle pre-emptively.

The Metal/Imgly carve-out is Apollo's compositional hinge. Imgly knowledge lives in the dedicated `imgly-engine-expert` skill; Apollo retains measurement and verification authority. The delegation contract at `apollo/_shared/integrations/imgly-and-metal.md` formalizes the boundary — Apollo writes the structured `apollo_to_expert` envelope, the receiving skill returns `expert_to_apollo`, and Apollo applies strict-9 to the verification plan before accepting the recommendation.

## See also

- `apollo/_shared/primitives/mode-pack-scaffold.md` — five-phase pipeline framing, Phase 4 handoff contract, Phase 5 outcome state machine, procedure steps 5–8 boilerplate
- `apollo/_shared/primitives/evidence-gate.md` — strict-9 contract + refusal protocol the phase gates feed into
- `apollo/_shared/primitives/metrickit.md` — `MXMetaData.thermalState`, `MXCPUMetric`, `MXCPUExceptionDiagnostic`, `MXHangDiagnostic`, `MXGPUMetric` schemas
- `apollo/_shared/primitives/signposts.md` — `OSSignposter` shape + privacy default the signal table enforces
- `apollo/_shared/primitives/instruments-index.md` — Time Profiler / CPU Counters / Processor Trace / Metal System Trace details + capture commands
- `apollo/_shared/primitives/xctest-baselines.md` — `XCTClockMetric` + `XCTCPUMetric` baselines for the dev-loop signal
- `apollo/_shared/primitives/regression-detection.md` — thermal-specific cohort + dwell rules; sustained-load curve handling
- `apollo/_shared/primitives/organizer-asc.md` — Performance / Power Metrics rows on the production fleet
- `apollo/_shared/primitives/execution-surface.md` — capability matrix + auto-capture decision tree (real-device pairing as `human-required`)
- `apollo/_shared/primitives/canonical-antipatterns.md` — thermal antipatterns curated for the `advisory:1` channel (`therm:NN` rows)
- `apollo/_shared/integrations/imgly-and-metal.md` — Imgly / Metal delegation contract (handoff envelope + retained-vs-delegated authority)
- `_shared/contracts/events.md` — `apollo_capture_*` and `apollo_recommendation` event schemas
- `REVIEW.md` R10 — sister rule for completion claims; Apollo's verification phase is the thermal-mode counterpart
- `ProcessInfo.thermalState` and `thermalStateDidChangeNotification` — Apple Developer reference for the observer contract
- WWDC25 308 — Optimize CPU performance with Instruments (Processor Trace, CPU Counters)
- WWDC23 10248 — Analyze hangs with Instruments
- WWDC22 10082 — Track down hangs with Xcode and on-device detection
- WWDC21 10087 — Diagnose Power and Performance regressions
- Apple Silicon CPU Optimization Guide v4 — E/P-core scheduling, QoS placement, micro-arch counter routing
- "Tuning your code's performance for Apple silicon" — Apple Developer guide
- Tech Talk 110339 — Metal Performance HUD
