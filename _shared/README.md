---
name: _shared Index
description: Index of every file under _shared/, grouped by subdir. Points every agent + script + linter at the authoritative location for a given contract, schema, primitive, pattern, or rule.
type: reference
---

# `_shared/` index

Cross-agent contracts, state machines, schemas, primitives, patterns, and rules. Every agent references this tree; nothing here is agent-specific.

Post Phase 2.5 Commit C, layout is frozen: later phases land new files in existing subdirs; new subdirs need explicit justification.

## `contracts/` — inter-agent interface definitions

| File | Purpose |
|---|---|
| `message-contract.md` | Canonical envelope for every inter-agent message. |
| `idempotency.md` | Key construction and dedupe rules for writable actions. |
| `schema-version.md` | Object-form SemVer + `min_reader` + `deprecated_at`. |
| `event-emission.md` | Producer-side event rules. |
| `read-write-decls.md` | Mode-pack frontmatter for declared reads / writes. |
| `debrief-format.md` | Achilles → Chanakya debrief shape (legacy markdown; superseded by `schemas/debrief.md` in 2.6). |
| `events.md` | Event log schema, atomicity, offset, event catalog. |
| `build-message-format.md` | Producer → Slack build-posting contract. |
| `release-tf-push.md` | Studio-owned TestFlight / App Store push procedure — prerequisites, archive, upload, dSYM, Slack draft, human-approval gate, send. Event taxonomy + `requires_secret_scope` declaration. Phase 2 (#217 Stage B). |
| `plans-index-validator.md` | Invariants + finding codes for `plans/index.yaml` and artifact cross-references. Phase 2.6. |
| `agent-boot.md` | Per-session `agent_boot` event emitted at first write. Minimal payload — agent, git_sha, skill_version. Phase 2.6. |
| `brief-formats/` | Chanakya → Achilles brief templates per task type. |

## `state-machines/` — lifecycles

| File | Purpose |
|---|---|
| `task-lifecycle.md` | Proposed → briefed → dispatched → in-progress → reviewed → merged → verified / rejected → archived. |
| `brief-lifecycle.md` | Draft → ready → dispatched → debriefed → superseded / archived. |
| `review-lifecycle.md` | Pending → in-progress → approved / flagged / blocked → acknowledged. |
| `release-lifecycle.md` | Drafted → submitted → in-review → pending-developer-release → released / rejected / cancelled → archived. Phase 2.6. |
| `feedback-lifecycle.md` | Ingested → triaged → linked → resolved / dismissed → archived. Minimal landing in 2.6; knowledge-layer expansion in 2.7. |

## `schemas/` — structured data shapes

| File | Purpose |
|---|---|
| `task.md` | Per-task YAML artifact (`task@1.1.0`). Phase 2.6 + #247 lean fields. |
| `brief.md` | Chanakya → Achilles brief contract instance (`brief@3.1.0`). Phase 2.6. |
| `debrief.md` | Achilles → Chanakya debrief artifact (`debrief@2.1.0`). Phase 2.6 + #247 `executed_with`. |
| `review.md` | Argus / user verdict artifact (`review@1.0.0`). Phase 2.6. |
| `round.md` | User-testing round aggregate (`round@1.0.0`). Phase 2.6. |
| `release.md` | TestFlight / App Store release artifact (`release@1.1.0`). Phase 2.6 + #247 cancel→replace. |
| `feedback.md` | Ingested feedback record (`feedback@1.0.0`). Phase 2.6. |
| `crash.md` | Crashlytics-derived crash record (`crash@1.0.0`, writer lands in Phase 5). |
| `build-debt.md` | Build-debt counter + threshold schema. |
| `master-plan.md` | Master plan YAML shape (legacy; 2.6 supersedes with per-task files). |
| `test-flow.md` | Test-flow round document shape (legacy; superseded by `round.md` in 2.6). |
| `token-budgets.json` | Per-mode token budget seed values. |
| `capability-manifest.json` | Machine-readable agent + mode-pack roster (regenerated). |
| `capability-manifest-CHANGELOG.md` | Human-readable capability-change log. |
| `model-rates.json` | **Deprecated 2026-04-22** (Max-plan reframe — was per-model USD rates; unused post-reframe). Kept one cycle; remove at 2.7 cutover. |
| `reader-versions.json` | Per-schema reader version table — `validate-schema.sh` reads this. Phase 2.6. |

## `primitives/` — reusable helpers

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

## `patterns/` — architectural conventions

| File | Purpose |
|---|---|
| `router-pattern.md` | Agent router + mode-pack convention. |
| `singleton-invariants.md` | Which agents are singleton and why. |
| `chanakya-principles.md` | Cross-cutting invariants Chanakya modes inherit. |
| `dry-run.md` | `--dry-run` convention every writable mode adopts. |
| `budget-telemetry.md` | `tokens` on session-completed plus derived `cache_hit_rate` + `ctx_util_pct`; `mode_budget_exceeded` event. Max-plan reframe 2026-04-22. |
| `multi-machine-sync.md` | Tier-3 partitioned-by-writer shared state. |
| `capability-manifest.md` | Machine-readable roster regenerated from mode-pack frontmatter. |

## `rules/` — enforcement, review, cleanup

| File | Purpose |
|---|---|
| `enforcement-contract.md` | Linter error-code table + fix recipes. |
| `review-rules.md` | Checks Argus runs pre-merge. |
| `localization-rules.md` | iOS string-localization mandates. |
| `cleanup-policy.md` | Event-log rotation + compact-sweep rules. |
| `debt-tracking.md` | Build/test debt counter + threshold rules. |

## Why this index exists

Agent sessions and pre-commit linters both rely on file references resolving. A central index surfaces what lives where so references are grounded in actual files — not inferred from memory of prior sessions.
