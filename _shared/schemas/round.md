---
name: Round Schema
description: YAML shape for user-testing round aggregates under plans/rounds/<round-id>.yaml. One artifact per user-testing sitting (round 1, round 2, …). Replaces the markdown user-testing-round<N>.md files.
type: reference
---

# Round Schema (`round@1.0.0`)

Per-round artifact written to `~/.dev-studio/<project>/plans/rounds/<round-id>.yaml`. One file per user-testing sitting — round 1, round 2, etc. Authored by `/chanakya test-flow`; updated by `/chanakya review-feedback` as user feedback lands.

Schema carries the machine-readable aggregate; the per-case narrative stays in a `body` string so the round is still legible as a checklist for the human tester (see `schemas/test-flow.md` for the legacy shape this replaces).

## Shape

```yaml
schema_version:
  name: round
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-8001-7e04-8ddd-55ef6fa88b88        # UUIDv7
round_number: 4                                  # 1, 2, 3, … monotonic per project
state: open                                      # planned | open | closed | archived
scope: new                                       # new | full | module:<name>
generated_at: 2026-04-22T11:00:00Z
closed_at: null
previous_round: 0190f52a-6c00-7e03-8ccc-44de6ea77a77  # round-id | null
tested_on:
  device: "iPhone 15 Pro simulator"
  os_version: "iOS 17.4"
tasks:
  - 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11       # task-id covered by this round
  - 0190f52a-6f15-7b4c-9b2e-1e5faa80f622
reviews:
  - 0190f52a-7b22-7e03-8cff-66ef7ec99c99       # review-ids emitted against this round
cases:
  - id: "1.1"
    title: "Filter preset row renders"
    task_refs: [0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11]
    severity: important                          # critical | important | normal
    retest_of: null                              # case-id from previous round being retested
    result: pass                                 # pending | pass | fail
    timing_ms: null                              # for perf cases
    notes: null
  - id: "2.3"
    title: "Export large file under 2s"
    task_refs: [0190f52a-6f15-7b4c-9b2e-1e5faa80f622]
    severity: critical
    retest_of: "2.3"                             # retested from round 3
    result: fail
    timing_ms: 3200
    notes: "Regressed from 1.8s in round 3. Likely related to T042."
summary:
  cases_total: 14
  pass: 11
  fail: 2
  pending: 1
body: |
  # Full round prose rendered from the legacy test-flow template.
  #
  # Includes Setup, Sections, Performance Checkpoints, Task Crosswalk, and
  # Instructions. Renderer emits this for the user's manual-test sitting;
  # once results are entered, Chanakya's review-feedback mode parses the
  # results back into the structured `cases` array above.
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `round_number` | integer ≥ 1 | yes | Human-friendly sequence; monotonic per project. |
| `state` | enum | yes | `planned` \| `open` \| `closed` \| `archived`. |
| `scope` | string | yes | `new` \| `full` \| `module:<name>`. Drives case selection. |
| `generated_at` | RFC3339 UTC | yes | When Chanakya's test-flow mode authored the round. |
| `closed_at` | RFC3339 UTC \| null | yes | Set when `state → closed`. |
| `previous_round` | UUIDv7 \| null | yes | For retest linkage. |
| `tested_on` | object \| null | yes | `{device, os_version}`. Null pre-session, filled when user starts. |
| `tasks` | array of UUIDv7 | yes | Task-ids covered by this round. Empty array allowed (rare — scope=`module` with no verified tasks yet). |
| `reviews` | array of UUIDv7 | yes | Reviews emitted against this round (typically one per session). |
| `cases` | array | yes | Per-case records. See §Cases. |
| `summary` | object | yes | `{cases_total, pass, fail, pending}`. Redundant with `cases` for dashboarding. |
| `body` | string (multiline markdown) | yes | Human-readable round checklist — the surface the user interacts with during the session. |

## Cases

Each case is one check the user performs:

```yaml
cases:
  - id: "1.1"                                     # section.case, stable within the round
    title: "<short label>"
    task_refs: [<task-id>, …]                    # tasks covered by this case
    severity: critical                            # critical | important | normal
    retest_of: "1.1"                             # case-id from previous_round, null if new
    result: pass                                  # pending | pass | fail
    timing_ms: null                               # perf cases only
    notes: null                                   # freeform commentary, ≤ 500 chars
```

## Lifecycle

| State | Meaning |
|---|---|
| `planned` | Round exists but not yet rendered to the user. |
| `open` | Rendered and in active testing. |
| `closed` | Session complete; results captured. |
| `archived` | Post-compact cold storage. |

Transitions:

```
planned → open     : test-flow mode renders and hands to user.
open    → closed   : review-feedback mode ingests results.
closed  → archived : compact sweep.
```

Events: `round_state_changed` (additive — catalog entry lands with this schema).

## Links

- `tasks` enumerates task-ids this round verifies. Each task's `links.reviews` gains the round-level review-id. Bidirectional.
- `reviews` back-refs reviews whose `subject.kind = round, subject.id = round.id`.

## Migration note (2.6)

Legacy markdown rounds at `plans/user-testing-rounds/user-testing-round<N>.md` migrate to `plans/rounds/<round-id>.yaml`. Transform:

1. Parses the header for `Generated`, `Scope`, `Previous round`, `Tested on`.
2. Extracts cases by section (`### <section>.<case>`), task-refs from `[Txxx]` tags.
3. Preserves `result`, `Timing`, `Notes`, `Evidence` into typed fields.
4. Maps severity from `[critical]` / `[important]` / unmarked tags.
5. Renders the original markdown into `body` for human readability.

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing. Replaces `schemas/test-flow.md` (legacy). |

## Related

- `schemas/test-flow.md` — legacy format; kept for archive readability.
- `schemas/task.md` — tasks referenced by `tasks[]`.
- `schemas/review.md` — per-round review artifact.
- `contracts/events.md` — `round_state_changed`.
