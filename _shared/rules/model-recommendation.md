---
name: Model recommendation rule
description: Deterministic task-level model tier recommendation for brief authors and dispatchers. Uses task size, kind, cross-file count, and novelty score.
type: reference
schema_version: 1
---

# Model Recommendation Rule

Use this rule when authoring or reviewing a brief. The output is a pair:

```yaml
recommended_models:
  best_result:
    tier: opus | sonnet | haiku
    model_id: <resolved from _shared/schemas/model-catalog.yaml>
    reasoning_effort: low | medium | high
  fast_turnaround:
    tier: opus | sonnet | haiku
    model_id: <resolved from _shared/schemas/model-catalog.yaml>
    reasoning_effort: low | medium | high
  rationale: "<one line tied to this task>"
```

## Inputs

| Input | Values |
|---|---|
| `task.size` | `xs` / `s` / `m` / `l` |
| `task.kind` | `impl` / `test` / `docs` / `refactor` / `debug` |
| `task.cross_file_count` | non-negative integer |
| `task.novelty_score` | `0` to `3` where `0` is mechanical and `3` is novel or ambiguous |

## Rule

1. Start with `sonnet / medium`.
2. Use `opus / high` for `debug` tasks, novelty `3`, size `l`, or `cross_file_count >= 8`.
3. Use `haiku / low` for mechanical work: size `xs`, novelty `0`, `cross_file_count <= 2`, and kind `docs`, `test`, or `refactor`.
4. Use `sonnet / low` for size `s`, novelty `0`, and `cross_file_count <= 4`.
5. Fast-turnaround may downgrade at most one tier when the task is not high-risk:
   - `opus / high` becomes `sonnet / medium` only when novelty is below `3`, kind is not `debug`, and `cross_file_count < 8`.
   - `sonnet / medium` becomes `haiku / low` only for size `xs` and novelty `0`.
   - `haiku / low` stays `haiku / low`.

## Policy

`_shared/rules/model-policy.yaml` selects which recommendation consumers prefer by default. Inline override is allowed, but the brief or debrief must record why the override beat the rule.

## Catalog

`_shared/schemas/model-catalog.yaml` maps tiers to concrete model IDs. Keep recommendation logic tier-based so model refreshes update the catalog without rewriting every mode pack.

## Related

- `_shared/rules/brief-model-effort.md`
- `_shared/schemas/brief.md`
- `_shared/contracts/events.md`
