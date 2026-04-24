---
name: Swift Skill Routing
description: Diff-signal to skill-invocation table for Swift / SwiftUI / IMGLY work. Read by Achilles Step 4.0 (pre-edit) and Step 5.0 (post-diff), and by Argus Step 3.5 (review). Mechanic lives in `_shared/primitives/design-time-skill-routing.md`.
type: rule
---

# Swift Skill Routing

Stack-scoped routing table for Swift projects. Paired with `_shared/primitives/design-time-skill-routing.md` — this file supplies the *what* (which skill for which diff signal); the primitive supplies the *how* (when to invoke, verdict schema, commit-note invariant, fix-then-rerun rule).

Stack: Swift (any iOS / macOS / package work using Swift, SwiftUI, IMGLY SDK, or the Claude API).

## Diff-signal table

Read top-to-bottom against the anticipated diff (Step 4.0) or actual diff (Step 5.0 / Step 3.5). Every matching row fires its skill. A diff matching five rows invokes five skills.

| Diff signal | Skill | Finding category |
|---|---|---|
| New type, protocol, actor, or module boundary | `swift-architecture-skill` | `architecture` |
| New or renamed `public` / package-internal symbol | `swift-api-design-guidelines-skill` | `api-design` |
| `async` / `await` / `Task` / `actor` / `@MainActor` / `nonisolated` / `Sendable` changes | `swift-concurrency-pro` | `concurrency` |
| SwiftUI view body, `@State`, `@Observable`, `@Binding`, `@Environment` | `swiftui-pro` | `swiftui` |
| New SwiftUI view file or large body split | `swiftui-view-refactor` | `swiftui-structure` |
| iOS 26+ surfaces (Liquid Glass, native blur, scrollable containers) | `swiftui-liquid-glass` | `swiftui-ios26` |
| SwiftUI redraw / allocation / profiling concerns | `swiftui-performance-audit` | `swiftui-perf` |
| IMGLY engine APIs: block, scene, event, export, history | `imgly-engine-expert` | `imgly` |
| New tests using `@Test` / `#expect` / test plans | `swift-testing-pro` + `swift-testing-expert` | `tests` |
| Figma reference in the brief | `figma-to-swiftui` | `figma-fidelity` |
| Claude API / Anthropic SDK code | `claude-api` | `claude-api` |

## How consumers use this table

- **Achilles Step 4.0** — match the anticipated diff shape against the signal column. Load every matching skill **before** the first edit. Apply guidance while writing. Write the "Design choices" commit note (see primitive) on the first commit.
- **Achilles Step 5.0** — match the actual diff against the signal column. Re-invoke every matching skill. Record each skill's verdict (`clean` / `minor` / `material`) in the debrief's `## Self-Review`. A `material` finding triggers the primitive's fix-then-rerun rule.
- **Argus Step 3.5** — match the actual diff against the signal column. Invoke every matching skill. Findings become `FLAGS` (never `BLOCKS` in week-1 posture) tagged `rule: design/<category>` from the third column. Also read the "Design choices" note for `design-drift` / `design-accountability-missing`.

## Rules for editing this table

- **Additive by default.** New signals add rows; existing rows rarely change.
- **Signal specificity.** A signal row must be narrow enough that a reader can unambiguously decide "does my diff hit this?" Vague signals produce noise.
- **One skill per row, unless the skills are genuinely paired.** `swiftui-pro` + `swiftui-view-refactor` ship together because refactoring a view without SwiftUI idioms is nonsense; `swift-testing-pro` + `swift-testing-expert` same pairing logic. Bundling beyond that is a smell.
- **Don't add guidance inline.** If a skill's guidance needs amplifying, amplify it in the skill, not here. This file stays routing-only.

## When to split

This table becomes `turnip-skill-routing.md` (or another project-scoped slug) when a second Swift project joins the studio and the two projects need different skill sets. Until then, one Swift stack = one table.

## Fixture coverage

The primitive's fixture (`tests/primitives/design-time-skill-routing.yaml`) exercises the cross-cutting mechanic. This table's correctness is exercised by the Achilles + Argus mode-pack fixtures whenever they walk through a Swift diff scenario.
