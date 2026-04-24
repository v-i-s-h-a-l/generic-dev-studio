---
name: Test Strategy
description: Layered test-type selection by churn rate. Maps the churn layer of code under test (core / adapter / UI-glue / exploratory) to the right test type (unit / contract / snapshot+UI / manual). Read by Chanakya brief generation, Achilles test modes, and Argus code-quality. Prevents unit-test-everywhere calcification under high iteration (SDK swaps, UI reshape, prototypes).
type: rule
---

# Test Strategy — Layered by Churn

Unit tests calcify around implementation details. Under high iteration — SDK swaps like IMGLY→native, UI reshape, prototype exploration — test rewrites dominate cost without catching regressions. The fix is not "fewer tests"; it's **the right test type for the layer's churn rate**.

Adopted 2026-04-24 (studio consolidation arc Session F). Supersedes the implicit "default to unit" convention in brief templates and Achilles test modes.

## The four churn layers

| Layer | Churn | Test strategy |
|---|---|---|
| **Core domain invariants** — pure functions, value types, math, encoding, parsing, state machines with few edges | Low | Unit tests. These stabilize; rewrites are rare. |
| **SDK adapters / wrappers** — the Swift surface wrapping a third-party SDK (IMGLY engine, network client, storage adapter), protocol boundaries with external systems | Medium | Contract tests. Test shape / invariants / error mapping, not the SDK's internals. Survive the SDK swap. |
| **UI / glue / view code** — SwiftUI views, view-models tightly bound to views, navigation glue, the "wire these three things together" layer | High | Snapshot tests for visual regression + XCUITest for flows + real-device smoke. Unit tests on UI glue are a trap — they freeze the implementation, not the behavior. |
| **Exploratory / prototype** — brand-new features being shaped, flow experiments, throw-away code | Very high | Manual verification. No auto-tests until shape settles. A failing auto-test on prototype code is nearly always the test's fault, not the code's. |

## Brief-level question

Every implementation brief answers exactly one question:

> **`churn_layer:`** one of `core` | `adapter` | `ui` | `exploratory`.

Chanakya asks this during brief generation and records it on the brief. The answer drives:

1. Which test tasks (if any) Chanakya spawns for this brief.
2. Which Achilles mode the test tasks route to (`task-tdd`, `test-unit`, `test-integration`, `test-ui`, or none).
3. What Argus Step 3 expects to see (and does *not* flag as missing).

If the layer is genuinely ambiguous, pick the higher-churn layer — the one that produces less test debt. Wrong-down (calling UI "core") produces calcified tests; wrong-up (calling core "UI") just means unit tests weren't written for something that could have had them — recoverable.

## Consumer rules

### Chanakya (brief generation)

Every new brief carries `churn_layer`. Brief templates require the field:

- `impl-brief.md` → add `## Churn Layer` section.
- `unit-test-brief.md` → same field; if `churn_layer ≠ core`, surface a warning: "unit-test brief for non-core layer — confirm this is intentional."
- `integration-test-brief.md` → appropriate for `adapter`.
- `ui-test-brief.md` → appropriate for `ui`.
- `tdd-brief.md` → appropriate when the code being specified is `core` or `adapter`; TDD on `ui` / `exploratory` is nearly always wrong.

Chanakya's brief-recommendation logic (manual for now, automatable later): after the impl brief lands, suggest the test task type from the layer:

| Layer | Spawn |
|---|---|
| `core` | unit-test-brief |
| `adapter` | integration-test-brief (contract-style) |
| `ui` | ui-test-brief + optional snapshot task |
| `exploratory` | none; flag `test_strategy: manual` on the brief |

### Achilles (test modes)

Achilles test modes (`task.md` Step 4B/4C/4D) choose test style from the brief's `churn_layer`, not by defaulting to unit:

- Step 4B (unit / integration) — if the brief is `churn_layer: ui` or `exploratory`, stop: "test type does not match layer; escalate to Chanakya." Don't silently write unit tests on UI-glue code.
- Step 4C (UI tests) — require `churn_layer: ui` or, occasionally, `adapter`.
- Step 4D (TDD) — require `churn_layer: core` or `adapter`.

### Argus (code-quality)

Step 3's "new production code lacks unit tests" finding is **conditional on `churn_layer`**:

- `core` → flag `missing-unit-test` if the diff adds production code without a matching unit test.
- `adapter` → flag `missing-contract-test` (different finding; surface that unit tests of the wrapper's internals are the wrong layer).
- `ui` → **do not flag missing unit tests.** Flag missing snapshot tests or missing XCUITest coverage where the brief specified them.
- `exploratory` → do not flag any missing-test category. Manual verification is the contract.

If the brief has no `churn_layer`, treat as `core` (conservative) but surface `missing-churn-layer` as an `accountability` flag so Chanakya can backfill the field.

## Ambiguous cases

- **Value type with one derived method** → `core`. The method is pure; unit-test the edge cases.
- **View model that owns service calls + UI state** → split if possible; otherwise `ui`. Service-call glue is not `adapter` unless you own the adapter layer below it.
- **A new SDK wrapper being introduced** → `adapter`. Even if it changes a lot this week, the *shape* stabilizes — that's what contract tests pin.
- **A full-screen rewrite in SwiftUI** → `ui`. Snapshot + XCUITest. Unit tests on view-bodies are the canonical waste.
- **A model being prototyped with unknown final shape** → `exploratory`. Revisit the layer once shape stabilizes; re-classify and retroactively add tests at the new layer.

## When the layer changes

Code moves between layers. A prototype stabilizes and becomes `core`. An adapter's internals leak into view code and it becomes `ui`. When a layer changes:

1. The next task touching that code records the new layer in its brief.
2. Existing tests are *not* automatically rewritten. The next review (Argus) flags the new layer vs. existing tests; follow-ups land incrementally.
3. No bulk test-deletion events. Calcified tests are removed one-file-at-a-time as they get in the way of feature work.

## Turnip-specific (not part of the primitive, captured here)

The arc's driving case was the IMGLY→native swap. Application of the primitive to Turnip:

- Characterization test: 20 reference photos, compare output hashes, before the swap begins. This *is* a contract test for the `adapter` layer — it pins IMGLY's behavior so the native implementation can prove shape-equivalence.
- Snapshot tests on editor screens (`ui` layer).
- Delete IMGLY-coupled unit tests that were testing IMGLY's internals masquerading as "our code".
- Keep unit tests on stable core (color math, export encoders, filter LUT parsing) — `core` layer, low churn.

These are applications, not primitive content. They live on the Turnip brief that executes the swap.

## Fixture

`tests/primitives/test-strategy.yaml` — scenario pressures a subagent into deciding test type for code at each layer. Without the rule, subagent defaults to "write unit tests." With it, it correctly routes UI to snapshot+XCUITest and adapter to contract tests.

## Explicitly not in scope

- **Performance tests.** Orthogonal axis (latency / allocation / energy). Routed separately when the brief has a perf budget.
- **Security / penetration tests.** Out of scope for churn-based routing.
- **Mutation testing.** Potentially useful on `core` layer; not triggered by churn classification.
