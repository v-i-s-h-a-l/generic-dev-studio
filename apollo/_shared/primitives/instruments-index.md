---
name: Instruments routing index
description: Diagnostic-question → Instruments template routing table covering P0 modes (memory, thermal, battery) and Phase-2 modes (launch, scroll, network, hangs), plus xctrace capture recipes.
type: reference
schema_version: 1
---

# Instruments routing index

Instruments is the single richest evidence source Apollo has on a single device — every `.trace` is a multi-track time series with full call-stack provenance. The cost is selection: pick the wrong template and the trace is large, slow, and silent on the question being asked. This file is the routing table Apollo consults to map a diagnostic question to the right template before recording.

A trace is hard evidence only when (a) it was recorded under a named scenario, (b) the scenario start/end is bracketed by signposts, and (c) the device cohort is recorded alongside. The strict-9 gate rejects "I opened Instruments and it looked bad."

## Routing table (mode → template)

| Mode | Question | Primary template | Secondary | Why |
|---|---|---|---|---|
| memory | "what's holding this memory?" | Allocations | VM Tracker | Allocations gives per-call-stack retention; VM Tracker shows dirty/resident split |
| memory | "are we leaking?" | Leaks | Allocations | Leaks runs `leaks(1)` at intervals; Allocations confirms growth pattern |
| memory | "are we evicting purgeable memory under pressure?" | VM Tracker | Allocations | dirty / clean / swapped breakdown over time |
| memory | "is footprint large because of caches or app data?" | VM Tracker | File Activity | dirty regions vs mapped files |
| thermal | "what's running hot in this scenario?" | Time Profiler | CPU Counters | Time Profiler ranks by sampled time; CPU Counters resolves frequency / cycle stalls |
| thermal | "which exact instructions stall?" | Processor Trace | CPU Counters | Processor Trace reconstructs every retired instruction; the only template that resolves micro-arch stalls |
| thermal | "is the GPU the heat source?" | Metal System Trace | GPU | Metal System Trace shows command-buffer execution + thermal correlation |
| battery | "where is foreground energy going?" | Power Profiler | Energy Log | Power Profiler partitions by subsystem (CPU, GPU, display, network, location) |
| battery | "are we waking up the radios needlessly?" | Network | Power Profiler | Network shows TCP / cellular activations; correlate with Power Profiler subsystem rows |
| battery | "is location pinning the energy line?" | Location | Power Profiler | Location shows authorization + activation cadence |
| battery | "is the screen the bottleneck?" | Display | Power Profiler | Display Brightness trace + `MXDisplayMetric` cross-check |
| launch (P2) | "where is launch time going?" | App Launch | Time Profiler | App Launch decomposes pre-main / main / first-render |
| launch (P2) | "why is dyld slow?" | App Launch | System Trace | dyld events appear in App Launch with timing |
| scroll (P2) | "which frames are dropping?" | Animation Hitches | Time Profiler | Hitches surfaces missed-deadline frames; Time Profiler attributes the cause |
| scroll (P2) | "is it main thread or GPU?" | Animation Hitches | Metal System Trace | Hitches splits CPU-bound vs GPU-bound |
| hangs (P2) | "why did the main thread block?" | Hangs | Time Profiler | Hangs surfaces ≥250ms blocks; Time Profiler attributes the offending stack |
| hangs (P2) | "is it a lock or sync I/O?" | System Trace | File Activity | System Trace shows kdebug events incl. lock contention and syscalls |
| network (P2) | "what's on the wire?" | Network | System Trace | per-connection timing; correlate with `MXNetworkTransferMetric` |
| any | "what just happened, broadly?" | System Trace | — | Catch-all when the question isn't yet sharpened |

The table is exhaustive for the P0 modes and the named Phase-2 modes; expansion is additive (new row, no schema change).

## Templates Apollo uses

| Template | What it records | Min OS | Notes |
|---|---|---|---|
| **Allocations** | every `malloc` / `vm_allocate` with call stack; class breakdown (objc / Swift) | iOS 13+ | Mark generations with the **i** button to diff before/after a scenario |
| **Leaks** | `leaks(1)` snapshots at configurable interval; cycle detection | iOS 13+ | False positives on Swift COW types under Allocations recorded together |
| **VM Tracker** | resident / dirty / swapped / compressed bytes per region; regions over time | iOS 14+ | Only template surfacing the `footprint` distinction the kernel uses for OOM |
| **Time Profiler** | sampled call stacks at 1ms (configurable) | iOS 13+ | Heavy weight = self-time + descendants; toggle "Hide System Libraries" early |
| **CPU Counters** | PMU counters: cycles, instructions, branch misses, cache misses | iOS 16+ (A15+) | Enables IPC analysis; pick the right counter set per microarch |
| **Processor Trace** | every retired instruction reconstructed | iOS 17+ (A17+, M3+) | Lossless; capture window seconds, file size GB |
| **Power Profiler** | watts attributed by subsystem | iOS 16+ | Replaces Energy Log on modern Xcode; needs a real device |
| **Energy Log** | legacy energy + state transitions | iOS 13+ | Use only if Power Profiler unavailable; lower fidelity |
| **Metal System Trace** | command-buffer scheduling, GPU work, display sync | iOS 13+ | Pair with Animation Hitches for end-to-end render diagnosis |
| **Animation Hitches** | each frame's deadline-vs-actual + classification | iOS 13+ | Cite hitch ratio + per-hitch stack; matches `XCTOSSignpostMetric.scrollDecelerationHitchTimeRatio` |
| **Hangs** | runs sampling on main-thread blocks ≥ threshold (default 250ms) | iOS 16+ | Pair with `MXHangDiagnostic` from MetricKit |
| **Network** | per-connection bytes, RTT, retransmits | iOS 13+ | Correlate by timestamp with Power Profiler `network` row |
| **System Trace** | kdebug events: VM, scheduling, syscalls, locks | iOS 13+ | Highest coverage, highest noise; drop into when nothing else fits |
| **File Activity** | open / read / write / close with stacks and bytes | iOS 13+ | The only template that resolves which file is being written |
| **Core Animation** | render-server FPS, commit / draw timing | iOS 13+ | Out-of-process render-server data; not visible in app-only profiling |
| **App Launch** | pre-main, main, first-frame breakdown | iOS 15+ | Authoritative for cold-launch diagnosis |
| **Points of Interest** | `OSSignposter` intervals + events | iOS 13+ | Always include; the anchor track for every Apollo trace |

## Capture commands

Apollo records traces non-interactively via `xctrace`; the GUI is for human review only. Standard invocation:

```
xctrace record \
  --device "<udid>" \
  --template "<template-name>" \
  --launch -- <bundle-id> \
  --time-limit 30s \
  --output <path>.trace
```

Mode-specific recipes (selected templates Apollo invokes most):

| Mode | Recipe |
|---|---|
| memory peak | `xctrace record --template "Allocations" --launch -- <bundle> --time-limit 60s` |
| memory dirty | `xctrace record --template "VM Tracker" --launch -- <bundle> --time-limit 60s` |
| thermal hot | `xctrace record --template "Time Profiler" --launch -- <bundle> --time-limit 30s --append-run` |
| battery foreground | `xctrace record --template "Power Profiler" --device <ios-device> --time-limit 5m` |
| scroll hitches | `xctrace record --template "Animation Hitches" --launch -- <bundle> --time-limit 20s` |
| hangs | `xctrace record --template "Hangs" --launch -- <bundle> --time-limit 60s` |

Always pair the capture with a scripted scenario via AXe or XcodeBuildMCP (`apollo/_shared/primitives/execution-surface.md`) — `--time-limit` plus an unscripted device produces noise, not evidence.

## Trace export and parsing

Traces are bundles. For automated analysis Apollo exports via:

```
xctrace export --input <run>.trace --xpath '//trace-toc/run[1]/data/table[@schema="<schema>"]' --output <run>.xml
```

Schemas Apollo reads:

| Schema | Source template | Apollo use |
|---|---|---|
| `time-sample` | Time Profiler | call-stack hot-spot ranking |
| `os-signpost` | Points of Interest | interval p50/p95 per name |
| `narrative-run-info` | any | run metadata, device class, OS, app build |
| `vm-op` | VM Tracker | dirty / resident time series |
| `core-animation-fps-estimate` | Core Animation | frame-pacing series |
| `power-history` | Power Profiler | wattage per subsystem time series |
| `cpu-profile` | Time Profiler | weighted call tree |
| `hitch` | Animation Hitches | per-hitch stack + classification |

`xctrace export --toc` lists every available schema for a given trace — Apollo runs it once per template to discover schemas without hard-coding.

## How Apollo references traces

Mode packs cite traces in this shape:

| Citation form |
|---|
| `<template>` `.trace` at `<path>`, scenario `<scenario-name>`, signpost `<name>` p95 `<x>ms`, cohort `<modelCode>/<osMajor>` |

Vague citations ("Time Profiler showed a hot stack") fail the gate. The scenario name + signpost is what makes the trace re-runnable.

## Why

Instruments has more diagnostic depth than any other source Apollo touches, but the cost of a wrong template is silent — the trace records the wrong layer and the question stays unanswered. The routing table eliminates the lookup tax inside a mode pack; the capture-command recipes ensure traces are non-interactive and reproducible. Both are prerequisites for the "auto-capture-before-refuse" corollary in `evidence-gate.md`.

## See also

- `apollo/_shared/primitives/source-map.md` — Apple / WWDC source rows for Instruments templates and planned CPU mode
- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/primitives/signposts.md`
- `apollo/_shared/primitives/xctest-baselines.md`
- `apollo/_shared/primitives/execution-surface.md` — `xctrace` invocation, XCResultKit `.trace` bridging
- `apollo/_shared/primitives/regression-detection.md` — comparing traces across runs
- WWDC19 411 — Getting Started with Instruments
- WWDC18 410 — Creating Custom Instruments
- WWDC22 10082 — Track down hangs with Xcode and on-device detection
