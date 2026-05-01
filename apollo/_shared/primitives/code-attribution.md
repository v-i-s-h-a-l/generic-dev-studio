---
name: Apollo code attribution
description: Structured code_area contract for mapping performance evidence to likely source areas, confidence, owner, and verification without guessing from unresolved symbols.
type: reference
schema_version: 1
---

# Apollo code attribution

Apollo recommendations include a `code_area` block when evidence can be mapped to code or ownership. The schema is `_shared/contracts/apollo-code-area.schema.json`; validate with:

```bash
scripts/validate-contract.sh apollo-code-area <code-area.yaml>
```

## Confidence tiers

| Confidence | Required evidence | Owner |
|---|---|---|
| `confirmed` | Symbolicated app frame resolves to a source file/module, or MetricKit callStackTree resolves via matching dSYM | `achilles` unless a domain route below applies |
| `likely` | Symbolicated framework / SDK stack has visible app caller, or XCTest signpost maps to one source area | `achilles`, `swiftui-performance-audit`, or `imgly-engine-expert` |
| `advisory` | Curated anti-pattern row plus structurally blocked measurement | Owner from the advisory row; no impact claim |
| `blocked` | Unsymbolicated trace, missing dSYM, unresolved source search, or ambiguous ownership | `apollo-refusal` |

Unresolved symbols are never guessed. Apollo reports `symbolication_status: unsymbolicated`, `confidence: blocked`, `suggested_owner: apollo-refusal`, and an empty `responsible_frames` list.

## Candidate routing

| Candidate kind | Signal | Suggested owner |
|---|---|---|
| `app-source` | App symbol resolves to file/module in checkout | `achilles` |
| `apple-framework` | Apple framework dominates and no app caller is visible | `human-investigation` |
| `third-party-framework` | SDK dominates with app caller visible | `achilles` for caller; otherwise `human-investigation` |
| `swiftui` | SwiftUI update/diff/layout stack dominates | `swiftui-performance-audit` |
| `imgly-metal` | `IMGLY*`, CE.SDK engine, `MTL*`, or command-buffer stack dominates | `imgly-engine-expert` |
| `unresolved` | Missing dSYM, hex addresses only, or source search misses | `apollo-refusal` |

## Recommendation block

Mode packs include this block in recommendation artifacts:

```yaml
code_area:
  schema_version:
    name: apollo-code-area
    version: 1.0.0
    min_reader: 1.0.0
    deprecated_at: null
  attribution_id: code-area-feed-scroll
  mode: cpu
  evidence:
    artifact_path: ~/.dev-studio/<project>/apollo/captures/<id>/cpu.trace
    interval: FeedScroll
    cohort: iPhone16,2/iOS19
    scenario_id: feed-scroll-cpu
  symbolication_status: symbolicated
  responsible_frames:
    - symbol: FeedCell.body.getter
      module: Turnip
      weight: 42.7
      thread: main
  candidates:
    - kind: swiftui
      target: FeedCell.body
      file: Turnip/Feed/FeedCell.swift
      rationale: Time Profiler samples concentrate in SwiftUI body recomputation during FeedScroll.
  confidence: likely
  suggested_owner: swiftui-performance-audit
  verification_recipe: Re-run CPU Profiler on the same scenario and compare main-thread self time.
```

## See also

- `_shared/contracts/apollo-code-area.schema.json`
- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/_shared/integrations/imgly-and-metal.md`
- `apollo/modes/cpu.md`
