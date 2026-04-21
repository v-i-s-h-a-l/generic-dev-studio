---
name: _shared Index
description: Index of every file under _shared/ grouped by target subdir. Commit C moves files into subdirs and updates every reference; this index stays flat-path today and is rewritten then.
type: reference
---

# `_shared/` index

Cross-agent contracts, state machines, schemas, primitives, patterns, and rules. Every agent references this tree; nothing here is agent-specific.

**Layout note.** Files currently live at the flat `_shared/` path. Phase 2.5 Commit C reorganizes them into subdirectories (`contracts/`, `state-machines/`, `schemas/`, `primitives/`, `patterns/`, `rules/`). Grouping below follows the target layout so reference sweeps can be mechanical. See `PHASE-2-5-PLAN.md` §2.

## Contracts — inter-agent interface definitions

| File | Purpose |
|---|---|
| `message-contract.md` | Canonical envelope for every inter-agent message. |
| `idempotency.md` | Key construction and dedupe rules for writable actions. |
| `schema-version.md` | Object-form SemVer + `min_reader` + `deprecated_at`. |
| `event-emission.md` | Producer-side event rules. Extracted from `chanakya-principles.md`. |
| `read-write-decls.md` | Mode-pack frontmatter for declared reads / writes. |
| `debrief-format.md` | Achilles → Chanakya debrief shape. |
| `events.md` | Event log schema, atomicity, offset, and event catalog. |
| `build-message-format.md` | Producer → Slack build-posting contract. |
| `brief-formats/` | Chanakya → Achilles brief templates per task type. |

## State machines — lifecycles

| File | Purpose |
|---|---|
| `task-lifecycle.md` | Proposed → briefed → dispatched → in-progress → reviewed → merged → verified / rejected → archived. |
| `brief-lifecycle.md` | Draft → ready → dispatched → debriefed → superseded / archived. |
| `review-lifecycle.md` | Pending → in-progress → approved / flagged / blocked → acknowledged. |

Deferred: `release-lifecycle.md` (ships in 2.6), `feedback-lifecycle.md` (ships in 2.7).

## Schemas — structured data shapes

| File | Purpose |
|---|---|
| `build-debt-schema.md` | Build-debt counter + threshold schema. |
| `master-plan-format.md` | Master plan YAML shape. |
| `test-flow-format.md` | Test-flow round document shape. |
| `token-budgets.json` | Per-mode token budget seed values. |

## Primitives — reusable helpers

| File | Purpose |
|---|---|
| `safe-git.md` | `safe_git_commit` wrapper with stale-lock removal. |
| `slack-post.md` | Slack post helper with retry + dedupe. |
| `appstore-connect-jwt.md` | ASC JWT minting helper. |
| `derived-data.md` | Per-task DerivedData path conventions. |
| `test-slot.md` | Simulator slot acquisition protocol. |
| `push-notifications.md` | Push queue writer recipe. |
| `file-locations.md` | Canonical root paths (tier 1 / 2 / 3). |
| `turnip-project-config.md` | Flagged for move to `projects/turnip/` post-2.5. |

## Patterns — architectural conventions

| File | Purpose |
|---|---|
| `router-pattern.md` | Agent router + mode-pack convention. |
| `singleton-invariants.md` | Which agents are singleton and why. |
| `chanakya-principles.md` | Cross-cutting invariants Chanakya modes inherit. |
| `dry-run.md` | `--dry-run` convention every writable mode adopts. |
| `budget-telemetry.md` | `tokens` + `cost_usd` on session-completed; `mode_budget_exceeded` event. |
| `multi-machine-sync.md` | Tier-3 partitioned-by-writer shared state. |
| `capability-manifest.md` | Machine-readable roster regenerated from mode-pack frontmatter. |

## Rules — enforcement, review, cleanup

| File | Purpose |
|---|---|
| `enforcement-contract.md` | Linter error-code table + fix recipes. |
| `review-rules.md` | Checks Argus runs pre-merge. |
| `localization-rules.md` | iOS string-localization mandates. |
| `cleanup-policy.md` | Event-log rotation + compact-sweep rules. |
| `debt-tracking.md` | Build/test debt counter + threshold rules. |

## Why this index exists

Agent sessions and pre-commit linters both rely on file references resolving. A central index surfaces what lives where so references are grounded in actual files — not inferred from memory of prior sessions.

Commit C moves these files into subdirs; references in every agent + script get updated in the same commit.
