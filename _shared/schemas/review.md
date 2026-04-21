---
name: Review Schema
description: YAML shape for Argus and user verdicts under plans/reviews/<review-id>.yaml. Covers pre-merge code reviews, user-testing rounds results, and release-gate reviews.
type: reference
---

# Review Schema (`review@1.0.0`)

Per-review artifact written to `~/.dev-studio/<project>/plans/reviews/<review-id>.yaml`. Each review targets a subject (a task, a round, a release) and carries a verdict + findings list. Argus emits reviews on task merges; Chanakya emits them on round aggregates; the user emits them via `/chanakya review-feedback`.

## Shape

```yaml
schema_version:
  name: review
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-7a11-7e03-8c99-44df6fd77a77        # UUIDv7
subject:
  kind: task                                     # task | round | release
  id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11       # UUIDv7 of the subject
reviewer: argus                                  # argus | user | chanakya
state: approved                                  # pending | in-progress | approved | flagged | blocked | acknowledged
requested_at: 2026-04-22T12:41:10Z
completed_at: 2026-04-22T12:45:30Z
verdict: approved                                # approved | flagged | blocked | null (while pending/in-progress)
findings: []
checks_run:
  - name: regression_risk
    result: pass
  - name: secrets_in_diff
    result: pass
  - name: base_staleness
    result: pass
  - name: edge_case_coverage
    result: pass
scope:
  diff_size: 187
  file_count: 4
  caps_triggered: []                             # array of {cap, value, limit}
notes: null
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `subject` | object | yes | `{kind, id}`. `kind ∈ {task, round, release}`. `id` must resolve to an artifact of that kind. |
| `reviewer` | enum | yes | `argus` \| `user` \| `chanakya`. User-emitted reviews come from `/chanakya review-feedback`. |
| `state` | enum | yes | Per `state-machines/review-lifecycle.md`: `pending` \| `in-progress` \| `approved` \| `flagged` \| `blocked` \| `acknowledged`. |
| `requested_at` | RFC3339 UTC | yes | When the review was invoked. |
| `completed_at` | RFC3339 UTC \| null | yes | Null while `pending` / `in-progress`. |
| `verdict` | enum \| null | yes | `approved` \| `flagged` \| `blocked` \| null (while pre-terminal). Redundant with `state` for terminal verdicts; separates intent (state) from ruling (verdict). |
| `findings` | array | yes | Per-finding `{rule, tier, message, path?}`. See §Findings. |
| `checks_run` | array | yes | Per-check `{name, result}`. `result ∈ {pass, fail, skip, warn}`. |
| `scope` | object | yes | `{diff_size, file_count, caps_triggered}`. Records what Argus saw — useful for dashboards and rule-effectiveness analysis. |
| `notes` | string \| null | yes | Optional reviewer commentary. |

## Findings

Each finding records one review-rule hit:

```yaml
findings:
  - rule: R1_new_permission_surface
    tier: ask
    message: "Diff writes to /tmp/foo — outside ~/.dev-studio/**. Confirm or relocate."
    path: "scripts/new-thing.sh"
  - rule: R5_bash_portability
    tier: block
    message: "Uses `shopt -s nullglob` in a file that may be sourced from zsh."
    path: "scripts/lib-paths.sh"
```

- `rule` — stable identifier from `rules/review-rules.md` (e.g. `R1_new_permission_surface`, `R3_path_resolution`).
- `tier` — `block` \| `auto-fix` \| `ask` \| `warn`. Drives the verdict: any `block` → `blocked`; any `ask` unresolved → `flagged`; otherwise `approved`.
- `message` — human-readable context, ≤ 300 chars.
- `path` — optional file-relative reference; may include `:line` suffix.

## Verdict derivation

Argus computes verdict from findings:

| Condition | Verdict |
|---|---|
| Any finding with `tier: block` | `blocked` |
| No `block`, at least one `ask` or `warn` | `flagged` |
| Empty findings, all checks pass | `approved` |

User-emitted reviews (from `/chanakya review-feedback`) set verdict directly — no derivation.

## Lifecycle

Per `state-machines/review-lifecycle.md`:

```
pending → in-progress → {approved | flagged | blocked} → acknowledged
```

Transitions emit `review_state_changed` + the existing `review_approved` / `review_flagged` / `review_blocked` events per `contracts/events.md`.

## Links

- `subject` back-references the task / round / release. Bidirectional:
  - `subject.kind = task` ⇒ `task.links.reviews` contains `review.id`.
  - `subject.kind = round` ⇒ `round.reviews` contains `review.id`.
  - `subject.kind = release` ⇒ `release.reviews` contains `review.id`.
- Validator enforces both directions.

## Migration note (2.6)

Pre-2.6 Argus review output lived in free-form markdown under the worktree (`.argus/review.md`). Those files are archived as-is to `archive/2026-pre-2.6/` per Q18 — the verdict was the authoritative signal (captured in events), and the prose is historical context only. New reviews emit directly to YAML.

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing. |

## Related

- `state-machines/review-lifecycle.md` — authoritative transitions.
- `rules/review-rules.md` — source of finding `rule` identifiers.
- `schemas/task.md` / `schemas/round.md` / `schemas/release.md` — subjects a review can target.
- `contracts/events.md` — `review_*` events.
