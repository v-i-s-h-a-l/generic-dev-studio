---
name: Canonical anti-patterns primitive
description: Curated 1/10 advisory channel for Apollo. Documented anti-patterns where the pattern itself is the citation; only when measurement is structurally impossible. Memory rows seeded by Stage 2a.
type: reference
schema_version: 1
---

# Canonical anti-patterns (1/10 advisory channel)

The strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`) reserves a narrow 1/10 channel for canonical, documented anti-patterns. The channel exists for one shape only: the anti-pattern is present in the diff AND measurement is structurally impossible (no capture path inside the budget, no MetricKit payload reachable, no ASC build coverage). When measurement *is* possible, the channel is unavailable and Apollo proceeds to auto-capture-before-refuse.

## Hard rules

| Rule | Why |
|---|---|
| Apollo emits the literal prefix `advisory:1` on every advisory finding. | The prefix is the audit signal — dashboards filter advisory traffic out of regression dashboards by string match. |
| Advisory findings carry NO impact claim, NO regression call, NO expected delta. | Advisory is "the diff matches a pattern that is documented to be slow"; it is not "the diff is slow". |
| The advisory list is curated. Ad-hoc additions are out of scope. | An ungated list grows into an opinion engine; the opinion engine breaks the strict-9 gate. |
| An advisory citation MUST point to one row in this file. | A row that doesn't exist isn't an advisory; it's a hallucination. |
| Apollo refuses to chain advisories (advisory + advisory ≠ recommendation). | Advisory traffic compounding into "RECOMMEND" is the failure mode the channel exists to bound. |

## Citation form

Mode packs cite an advisory in this exact shape:

```
advisory:1 (<mode>:<row-id>): <one-line summary>
  source: apollo/_shared/primitives/canonical-antipatterns.md §<mode>:<row-id>
  diff_target: <file:line | symbol>
  measurement_path: blocked — <reason it's structurally impossible>
```

The `measurement_path: blocked` line is mandatory. If the reason names a path that does exist (e.g., "no simulator paired" when one is paired), the gate downgrades the advisory and routes back to auto-capture.

## Memory anti-patterns (Stage 2a — #230)

| Row id | Pattern | Diff signal | Why advisory, not recommendation |
|---|---|---|---|
| `mem:01` | Synchronous full-image decode on the main thread (`UIImage(contentsOfFile:)` of an asset > 4 MP without downsampling) | `UIImage(contentsOf*)` followed by direct UI assignment, no `CGImageSourceCreateThumbnailAtIndex` or `prepareForDisplay()` path | Footprint cost is real but device-class dependent; without an Allocations trace, magnitude is unknown |
| `mem:02` | Unbounded NSCache without `countLimit` or `totalCostLimit` | `NSCache` instantiated, neither limit set, no eviction observer | NSCache evicts under pressure but the watermark is system-dependent; without VM Tracker evidence, "unbounded" doesn't bound the impact |
| `mem:03` | Strong reference cycle through closure capture in a long-lived owner (`Timer.scheduledTimer`, `NotificationCenter.observe(...)`, `Combine.sink`) | Closure body references `self.` without `[weak self]` or `[unowned self]` AND owner outlives a single scope | Most are real cycles; some (e.g., `self` is a singleton) are intentional. Without Leaks evidence the diff doesn't disambiguate |
| `mem:04` | Retained `CIImage` chain accumulated across frames | `CIImage` stored in a property, re-assigned each frame, no `clearCaches()` on the `CIContext` | CIImage is lazy — peak materializes only when rendered. Without a Metal System Trace + VM Tracker pair, the accumulation cost is theoretical |
| `mem:05` | `MTLTexture` retained beyond the frame that presents it | `MTLTexture` stored as a property of the encoder owner, no explicit nil-out post `present()` | IOKit footprint impact is real but only visible in VM Tracker `IOKit` regions; without that capture, advisory only |
| `mem:06` | Bridging Core Foundation with `Unmanaged.takeUnretainedValue()` on a `Create` / `Copy` API | Method name contains `Create` or `Copy`, return passed through `takeUnretainedValue` | One side of this is overrelease (crash); the other is leak. Without `malloc_history` evidence the direction is undetermined |
| `mem:07` | Per-iteration allocation inside a hot loop with no `@autoreleasepool` (Obj-C / bridged Swift only) | Obj-C method body OR Swift `@objc` API with explicit autorelease semantics, hot loop, no drain | Pure Swift code does not benefit; advisory restricted to call-sites Apollo can identify as bridging Obj-C |
| `mem:08` | `Image` (SwiftUI) stored in `@State` rather than recomputed | `@State var image: Image?` assigned from disk read | SwiftUI's `Image` is a value type; the cost is the underlying `CGImage`. Without VM Tracker evidence the persistence cost is speculative |

## Thermal anti-patterns (Stage 2b — #231)

To be added by #231. The row-id namespace is `therm:NN`.

## Battery anti-patterns (Stage 2c — #232)

To be added by #232. The row-id namespace is `batt:NN`.

## How rows enter the list

A new row is added under one of two conditions:

1. **WWDC / Apple-doc citation** — the anti-pattern appears in an Apple-published source as a documented pitfall (WWDC video, Apple Developer guide, Xcode template inline doc). The row carries the citation in the mode-pack `See also` block.
2. **Repeat-incidence in shipped post-mortems** — the same pattern is the root cause in ≥ 3 distinct shipped regressions across ≥ 2 projects, post-mortems retained with the captured pre-fix evidence. The row's evidence trail is summarized in the row's "Why advisory" cell.

Single-incidence patterns do not enter. The bar is deliberate; an ad-hoc list grows into an opinion engine and breaks the strict-9 gate.

## Why curated, not algorithmic

A pattern-match-on-diff system that flags "looks expensive" is the regression Apollo's strict-9 contract exists to prevent. The advisory channel exists for the narrow case where (a) the pattern is documented as a problem by Apple or by the project's own incident history, AND (b) measurement is structurally impossible at the moment of the diff. Both gates are required. Either alone — pattern without curation, or impossibility without pattern — is hallucination wearing the gate's uniform.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — the 1/10 advisory channel definition and its narrow scope
- `apollo/_shared/primitives/execution-surface.md` — the auto-capture decision tree the advisory route only fires after exhausting
- `apollo/modes/memory.md` — consumer of the `mem:NN` rows
- WWDC18 219 — Image and Graphics Best Practices (canonical for `mem:01`)
- WWDC21 10180 — Detect and diagnose memory issues (canonical for `mem:02`–`mem:05`)
- Apple "ARC: Strong Reference Cycles for Closures" — Swift Programming Language guide (canonical for `mem:03`)
- WWDC18 416 — iOS Memory Deep Dive (canonical for `mem:07`)
