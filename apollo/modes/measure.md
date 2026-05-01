---
name: Apollo measure mode
description: Capture-only mode for hard-evidence artifacts without recommending a fix. Pre-flight tool for Apollo perf briefs with empty evidence artifacts.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 3000
session_budget: 600s
locks:
  - simulator-{udid}
  - xctrace-{device}
emits:
  - apollo_capture_started
  - apollo_capture_completed
  - apollo_capture_deferred
reads:
  - ~/.dev-studio/<project>/apollo/baselines/*.json
  - ~/.dev-studio/.runtime/host-capabilities.yaml
writes:
  - ~/.dev-studio/<project>/apollo/captures/<id>/**
  - ~/.dev-studio/<project>/events/<today>.jsonl
  - ~/.dev-studio/.runtime/locks/apollo/*
---

# Mode: Measure (`/apollo measure <metric>` / `--capture-only`)

Apollo's capture-only path. Produces a single hard-evidence artifact for a named metric (`memory` | `thermal` | `battery` | `cpu`) on a named cohort, then exits — **no fix recommendation, no patch dispatch, no re-measure loop**. Companion to the diagnostic mode packs.

## When to use

1. **Pre-flight for a perf brief.** Chanakya is about to author a brief with `dispatch_agent: apollo` but `evidence.artifacts` is empty. Run measure-mode against the regression scenario; the captured artifact path becomes the brief's `evidence.artifacts[0]`.
2. **Baseline capture.** A new release branch needs a fresh baseline before perf work begins. Measure-mode captures the baseline and writes it under `apollo/baselines/` keyed by `baseline_ref`.
3. **Cohort re-capture.** A perf-merge loop refused with `cohort-mismatch` (see `apollo/_shared/primitives/perf-merge-loop.md`). Measure-mode re-captures on the requested cohort so the next loop iteration runs cleanly.

Not for: open-ended "what's slow?" investigation. Use the diagnostic mode packs (`memory.md`, `thermal.md`, `battery.md`) for that — they capture and recommend.

## Invocation

```
/apollo measure memory                       # default cohort, default workload
/apollo measure thermal --cohort iPhone-16-Pro-iOS-19 --workload export-1080p
/apollo measure battery --capture-only       # explicit capture-only flag (alias)
/apollo measure cpu --workload scroll-feed
/apollo memory --capture-only                # equivalent: enter memory mode, exit after capture
```

`--capture-only` is the explicit alias for callers that prefer to enter the diagnostic mode pack but stop before the recommendation step. Both spellings produce the same artifact and emit the same events.

## Pre-conditions

- Host capability — `host-capabilities.yaml` must declare the capture surface required for the metric (XcodeBuildMCP + Instruments for memory/thermal; xctrace + Energy Log for battery; MXMetricPayload requires a TestFlight build registered with the device). Refuse with `host-incapable` if the surface is not available.
- Cohort declared — explicit `--cohort` flag OR an active baseline whose cohort is reused. Never silently pick a cohort; cohort drift is the #1 cause of strict-9 refusals downstream.
- Workload declared — explicit `--workload` flag OR a default declared by the metric's mode pack (memory: 60-second app-foreground idle; thermal: 5-minute export loop; battery: 30-minute Energy Log session). Document the workload on the artifact's sidecar so re-capture is reproducible.

## Steps

### Step 1 — Resolve metric + cohort + workload

Parse the invocation. Resolve metric to one of `memory | thermal | battery | cpu`. Resolve cohort either from `--cohort` or from `<project>/apollo/baselines/<baseline_ref>.json`. Resolve workload either from `--workload` or from the metric's mode-pack default.

If any of the three are unresolved, refuse with `missing-input` and list which fields are unset. Do not guess.

### Step 2 — Acquire lock

Take `~/.dev-studio/.runtime/locks/apollo/<metric>-{udid}.lock` (and `xctrace-{device}.lock` for trace-emitting captures). If contended, refuse with `lock-contended` and report which other Apollo session is holding. Capture sessions never queue — the user re-runs after the other session releases.

### Step 3 — Drive the capture surface

Per the metric's `apollo/_shared/primitives/execution-surface.md` recipe:

- **memory** — XcodeBuildMCP boot → AXe automate workload → `xctrace record --template Allocations` → stop on workload exit. Output: `.trace`.
- **thermal** — XcodeBuildMCP boot on a real device (simulator thermal data is not strict-9) → AXe automate workload loop → `xctrace record --template "Thermal State"` → stop on time budget. Output: `.trace` + ASC Performance Metrics polling URL.
- **battery** — Real device, unplugged, full charge → automate workload via TestFlight build → `xcrun simctl spawn` is not valid here → Energy Log download via Settings → Developer → Logs. Output: Energy Log `.logarchive` + Battery Usage screenshot.
- **cpu** — XcodeBuildMCP build → AXe or XCTest drives the declared workload → `xctrace record --template "CPU Profiler"` or Time Profiler fallback, with CPU Counters / Processor Trace / System Trace selected by `apollo/modes/cpu.md`. Output: `.trace` or `.xcresult`.

Emit `apollo_capture_started` at step entry; `apollo_capture_completed` at clean exit; `apollo_capture_deferred` when the capture cannot complete in the session budget (long battery captures often defer).

### Step 4 — Write artifact + sidecar

Write the captured artifact to `~/.dev-studio/<project>/apollo/captures/<capture-id>/` (UUIDv7 capture-id). Sibling sidecar `metadata.yaml`:

```yaml
schema_version: 1
capture_id: 0190f600-1234-7abc-89de-fedcba012345
metric: memory
cohort:
  device: "iPhone 16 Pro"
  os: "iOS 19.0"
  build: "Release"
workload:
  name: "export-1080p"
  duration_s: 300
  description: "Open photo, apply LUT, export at 1080p H.264, dismiss share sheet"
artifact:
  kind: trace                                 # trace | mxmetric | xcresult | signpost | energy-log | asc-perf
  path: "trace/Allocations.trace"             # relative to capture-id dir
  measure: "peak_resident_mb"                 # extracted summary measure
  value: 412.3
  unit: "MB"
captured_at: 2026-04-27T12:14:00Z
captured_with:
  host: claude-code
  session_id: "session-42"
baseline_ref: null                            # populated when --baseline-for <ref> is set
```

The `measure` / `value` / `unit` triple is the canonical summary the brief's `evidence.artifacts` references. Apollo's diagnostic mode packs read these fields directly when computing baseline-vs-observed deltas.

### Step 5 — Report

Single-block report to the user:

```
Captured: <capture-id>
Metric: <memory|thermal|battery|cpu>
Cohort: <device> <os> <build>
Workload: <name> (<duration>s)
Artifact: ~/.dev-studio/<project>/apollo/captures/<capture-id>/<artifact-path>
Summary: <measure> = <value> <unit>

Use as evidence in a perf brief:
  evidence.artifacts:
    - "~/.dev-studio/<project>/apollo/captures/<capture-id>/<artifact-path>"
  baseline_ref: "<git-ref>"
```

Exit. Do not propose fixes. Do not enter the diagnostic-mode loop. The user (or Chanakya brief authoring) is the next step.

## Refusals

| Reason | When | Required action |
|---|---|---|
| `host-incapable` | Capture surface not declared in host-capabilities.yaml | Switch hosts (Mac with Instruments + real device for thermal/battery) or remote-dispatch to a capable host |
| `missing-input` | metric / cohort / workload unresolved | Re-invoke with explicit flags |
| `lock-contended` | Another Apollo session holds the metric lock | Wait for the other session; re-run |
| `capture-failed` | xctrace / AXe / MXMetric subsystem errored | Surface the underlying error; user diagnoses |
| `cohort-unavailable` | Requested cohort device not paired / not booted | Pair the device or pick a different cohort |

All refusals emit `apollo_refused` with the reason code. Capture-mode refusals never auto-retry; the user decides whether to adjust and re-invoke.

## Cross-refs

- `apollo/_shared/primitives/evidence-gate.md` — the strict-9 contract this mode produces evidence for.
- `apollo/_shared/primitives/execution-surface.md` — per-metric capture recipes.
- `apollo/_shared/primitives/perf-merge-loop.md` — what consumes the captured artifact downstream.
- `_shared/schemas/brief.md` — `evidence.artifacts[]` field this mode populates.
- `apollo/modes/{memory,thermal,battery,cpu}.md` — diagnostic mode packs that capture-then-recommend.
