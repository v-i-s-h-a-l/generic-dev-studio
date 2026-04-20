# Phase 2.5 Execution Plan (draft for review)

Drafted 2026-04-20 for the `refactor/intent-router` branch. See `ROADMAP.md` §Phase sequence for phase context.

## 1. Directory reorg proposal

Target top-level layout under `_shared/`:

- `contracts/` — machine/agent interface definitions (inputs & outputs, versions)
- `state-machines/` — lifecycles (states + transitions)
- `schemas/` — structured-data schemas (JSON shapes, ledger rows)
- `primitives/` — small reusable building blocks (git, slack, jwt, paths)
- `patterns/` — architectural conventions (router, singleton, dry-run, manifest, telemetry)
- `rules/` — enforcement, review, localization, cleanup, debt-counter policy

### Mapping table

| Current file | Destination | Rationale |
|---|---|---|
| `_shared/router-pattern.md` | `patterns/router-pattern.md` | Architectural convention. |
| `_shared/singleton-invariants.md` | `patterns/singleton-invariants.md` | Architectural convention. |
| `_shared/enforcement-contract.md` | `rules/enforcement-contract.md` | Operational rule table. |
| `_shared/review-rules.md` | `rules/review-rules.md` | Rule set. |
| `_shared/localization-rules.md` | `rules/localization-rules.md` | Rule set. |
| `_shared/cleanup-policy.md` | `rules/cleanup-policy.md` | Policy = rule. |
| `_shared/debt-tracking.md` | `rules/debt-tracking.md` | Counter + threshold rules. |
| `_shared/build-debt-schema.md` | `schemas/build-debt.md` | Structured-data schema. |
| `_shared/master-plan-format.md` | `schemas/master-plan.md` | Structured-data schema. |
| `_shared/debrief-format.md` | `contracts/debrief-format.md` | Agent→Chanakya output contract. |
| `_shared/events.md` | `contracts/events.md` | Cross-agent event log contract. |
| `_shared/build-message-format.md` | `contracts/build-message-format.md` | Producer→Slack contract. |
| `_shared/test-flow-format.md` | `schemas/test-flow.md` | Document schema. |
| `_shared/brief-formats/*.md` | `contracts/brief-formats/*.md` | Chanakya→Achilles contracts. |
| `_shared/chanakya-principles.md` | `patterns/chanakya-principles.md` | Cross-cutting convention. |
| `_shared/safe-git.md` | `primitives/safe-git.md` | Small reusable helper recipe. |
| `_shared/slack-post.md` | `primitives/slack-post.md` | Reusable helper. |
| `_shared/appstore-connect-jwt.md` | `primitives/appstore-connect-jwt.md` | Reusable helper. |
| `_shared/derived-data.md` | `primitives/derived-data.md` | Operational helper. |
| `_shared/test-slot.md` | `primitives/test-slot.md` | Acquire-protocol helper. |
| `_shared/push-notifications.md` | `primitives/push-notifications.md` | Helper recipe for queue writes. |
| `_shared/file-locations.md` | `primitives/file-locations.md` | Path scheme reference. |
| `_shared/turnip-project-config.md` | `primitives/turnip-project-config.md` | Project-specific config blob. |
| `_shared/token-budgets.json` | `schemas/token-budgets.json` | Structured data. |

### Ambiguous / flagged

- **`turnip-project-config.md`** — project-specific, not really "shared". Candidate to move to a `projects/turnip/` dir in a later phase. Keep under `primitives/` for 2.5 to minimize churn.
- **`chanakya-principles.md`** — 80% principle (pattern), 20% event-emission boilerplate (contract). Staying in `patterns/` is the lesser of two evils; revisit when Phase 2.6 rewrites mode packs.
- **`events.md`** — could go to `schemas/` (it defines a JSONL shape) or `contracts/` (it is the bus). Placed in `contracts/` because the contract semantics (offset protocol, cross-agent consumption) dominate the schema content.
- **`debt-tracking.md` vs `build-debt-schema.md`** — the rules file references the schema file. Splitting across `rules/` vs `schemas/` is correct but requires both refs updated.

### Compatibility strategy

**No symlinks.** Git-tracked symlinks behave poorly on Windows, and `~/.claude/skills/_shared/<file>` is itself a symlink target — double-indirection is a support tax.

1. `git mv` each file to its new subdir.
2. Update **every** reference in one sweep (mode packs, scripts, top-level docs, commands, brief-formats cross-refs). Per-file sed mapping, mechanical and reviewable.
3. The linter's `collect_candidates` function (line 42) must be widened to walk subdirs: replace the `-maxdepth 1` walk with `find "$REPO_ROOT/_shared" -type f -name '*.md'`.
4. `scripts/scaffold-agent.sh` hardcodes `_shared/router-pattern.md` (lines 48, 65–67) — must be updated in the same commit.

Runner-up: one-commit symlink shim at old paths, delete after Phase 2.6. Rejected — leaves an audit smell for weeks and REVIEW R6 (SKILL in sync with reality) gets harder with two valid paths per doc.

## 2. New primitives — content sketches

### `contracts/message-contract.md`

Canonical envelope for every inter-agent message (brief, debrief, review verdict, event, snapshot handoff). Required fields:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | `"<name>@<int>"` | e.g. `"brief@2"`. |
| `message_id` | UUIDv7 | Monotonic; timestamped. |
| `correlation_id` | UUIDv7 | Inherited from triggering message. Survives across the whole task lifecycle. |
| `idempotency_key` | string | Producer-owned, deterministic for a logical action. |
| `sender` | `{agent, version}` | `agent`∈`{chanakya,achilles,argus,luban,chiron,worker-N}`. |
| `recipient` | `{agent, version_range?}` or `"broadcast"` | |
| `intent` | enum | `request` / `response` / `event` / `handoff` / `cancel`. |
| `payload_schema` | string | Points at file in `schemas/`. |
| `payload` | object | Validated against `payload_schema`. |
| `reply_to` | `message_id`? | For responses. |
| `occurred_at` | RFC3339 UTC | |
| `reads[]` | `[path]` | Declared read surface. |
| `writes[]` | `[path]` | Declared write surface. |

Non-goals: no transport spec (today filesystem; tomorrow maybe iMessage). Envelope is transport-agnostic.

### `contracts/idempotency.md`

1. Every writable action (brief write, debrief append, event emit, snapshot regen, merge, TF push) must be idempotent on `idempotency_key`.
2. Key construction: `<agent>:<mode>:<stable-subject>:<content-hash>`. Example: `chanakya:brief:T042:sha1(brief-body)`.
3. Duplicate detection: producer checks the sink's tail (event log, briefs dir) for matching key before writing. If found, emit `action_deduped` event and no-op.
4. Retries MUST reuse the original key. New key = new action.
5. Exception: append-only event log dedupes post-hoc — Chanakya compact pass drops duplicate keys with a `deduped_event_log` counter.
6. Partial-failure contract: if a write is observed by readers but the producer never confirmed, the next retry with the same key is a no-op ack, not a double-write.

### `contracts/schema-version.md`

- Every YAML / JSON / message carries `schema_version: "<name>@<int>"`.
- `<name>` namespaces the schema (e.g. `brief`, `debrief`, `event`, `master-plan`).
- Version bumps: additive-only fields → no bump. Renamed / removed / semantics-changed → bump major integer.
- Readers MUST reject `@<int>` > their max. Producers MUST emit the exact version they wrote.
- Schemas live in `schemas/<name>.md`; each schema file opens with a history table.
- Phase 2.6 migrations land as `schema_version` bumps atomically with migration scripts.

### `contracts/read-write-decls.md`

Mode-pack frontmatter extension:

```yaml
reads:
  - ~/.dev-studio/<project>/plans/master-plan.md
  - ~/.dev-studio/<project>/events/**.jsonl
writes:
  - ~/.dev-studio/<project>/plans/briefs/*.md
  - ~/.dev-studio/<project>/events/<today>.jsonl
```

- Paths may include `<project>` and globs; resolver expands via `lib-paths.sh`.
- `reads` / `writes` declared upfront so the router can audit: (a) which modes contend on the same write path (singleton check), (b) build capability manifest, (c) give Argus a static "touchable surface" for review scoping.
- Linter emits `E_MISSING_RW_DECL` if absent on any mode pack.

### `state-machines/task-lifecycle.md`

States: `proposed → briefed → dispatched → in-progress → self-reviewed → argus-reviewed → merged → user-verifying → verified | rejected → archived`. Side states: `blocked`, `cancelled`, `requeued`.

Transitions (subset):

- `briefed → dispatched` requires `brief@>=2` present + worker idle marker.
- `in-progress → self-reviewed` requires debrief written.
- `self-reviewed → argus-reviewed` requires Argus verdict event; bypass only with `xs-diff` exemption.
- `argus-reviewed → merged` requires `verdict ∈ {approved, flagged}` (not `blocked`).
- `merged → user-verifying` fires push-notification.
- `verified` terminal; `rejected` → `briefed` with `rework_of: <task-id>`.

Each transition emits an event with `from_state`, `to_state`, `actor`.

### `state-machines/brief-lifecycle.md`

States: `draft → ready → dispatched → debriefed → superseded | archived`. Superseded when a follow-up brief (rework / split) references it.

### Additional state machines

- `state-machines/review-lifecycle.md` — `pending → in-progress → approved|flagged|blocked → acknowledged`. Ships with 2.5.
- `state-machines/release-lifecycle.md` — defer to 2.6 (release flow is scripts-heavy; mode-pack rewrite lives there).
- `state-machines/feedback-lifecycle.md` — defer to 2.7 (knowledge layer owns feedback synthesis).

### `patterns/capability-manifest.md`

Machine-readable roster at `_shared/schemas/capability-manifest.json` (generated, not hand-edited):

```json
{
  "schema_version": "capability-manifest@1",
  "generated_at": "...",
  "agents": {
    "chanakya": {
      "version": "2.5.0",
      "modes": [
        {"name":"brief","reads":[...],"writes":[...],"emits":["brief_written"],"consumes":["feedback_*"]}
      ]
    }
  }
}
```

Producer: `scripts/capability-manifest.sh` walks mode-pack frontmatter. Runs in pre-commit alongside `docs-surface.json`. Readers (future dashboard, `/chanakya status --capabilities`) consume it without parsing 30 mode-pack files.

### `patterns/dry-run.md`

1. On `--dry-run`, mode performs all reads and computations normally.
2. Every write is replaced by a log line: `DRY-RUN write path=<path> bytes=<n> idempotency_key=<key>`.
3. Events are buffered and printed, not appended to the real log.
4. Exit code: 0 = would succeed; 2 = dry-run surfaced a problem.
5. `--dry-run` is additive; never inverts default behavior.
6. Router prose enumerates modes that are non-write (no dry-run needed, documented inline).

### `patterns/budget-telemetry.md`

- Every `agent_session_completed` event carries `tokens`. Extend with `cost_usd` (from `tokens` + model-rate table at `_shared/schemas/model-rates.json`).
- New event `mode_budget_exceeded` when session `tokens.total > 1.1 * budget` from `token-budgets.json`. Non-fatal; surfaced in status.
- `scripts/budget-report.sh` aggregates events daily / weekly; hook into compact mode.

## 3. Linter extensions — 5 new codes

| Code | Tier | When | Fix recipe |
|---|---|---|---|
| `E_MISSING_RW_DECL` | block | A `modes/*.md` lacks both `reads:` and `writes:` keys in frontmatter | Add `reads: []` and `writes: []` (empty lists acceptable for pure-read or pure-emit modes). Non-empty lists must use resolver placeholders (`<project>` etc). |
| `E_UNKNOWN_CONTRACT_REF` | block | A mode pack or script references a `_shared/<subdir>/<file>.md` that does not exist | Move/rename the referenced file or update the reference. Linter holds an index of `_shared/**/*.md` and rejects broken links. |
| `E_SCHEMA_VERSION_MISSING` | block | A file under `_shared/schemas/*.md` lacks a `schema_version:` frontmatter key, OR a `modes/*.md` frontmatter declares a `payload_schema:` but omits `payload_schema_version:` | Add `schema_version: "<name>@<int>"` per `contracts/schema-version.md`. |
| `W_IDEMPOTENCY_UNSPECIFIED` | warn | A mode pack declares non-empty `writes:` but its prose contains no mention of `idempotency` or `idempotency_key` | Add an Idempotency section keyed to `contracts/idempotency.md`, OR explicitly state why the mode is safe to retry blindly. |
| `W_CAPABILITY_STALE` | warn | `_shared/schemas/capability-manifest.json` is older than any `modes/*.md` in the staged set | Run `scripts/capability-manifest.sh --regen`. |

## 4. Execution order

Small commits, each independently revertible. Sequential unless marked `‖`.

1. **Commit A — linter widening (no-op semantic change):** change `collect_candidates` to walk `_shared/**/*.md` recursively. Add fixture run. No file moves yet.
2. **Commit B — add new primitives (in old flat `_shared/`):** add the new docs from §2 at flat paths. Land them referenced only from ROADMAP and a new `_shared/README.md` index section. No mode-pack touches.
3. **Commit C — reorg (large, mechanical):** `git mv` every `_shared/*.md` + `_shared/brief-formats/*.md` into its subdir per the mapping table. Sed sweep updates every reference in repo. Regenerate `docs-surface.json` (unchanged). One commit — interim states break linter / pre-commit.
4. **Commit D — linter extensions:** add the 5 new codes to `lint-architecture.sh` and `_shared/rules/enforcement-contract.md`. Start each `E_*` rule as *warn-only* initially behind `ARCH_LINT_LEVEL=strict`. After a 48h soak, promote to block in a tiny follow-up commit.
5. **Commit E — capability manifest:** add `scripts/capability-manifest.sh`, generate initial `_shared/schemas/capability-manifest.json`. Wire into pre-commit hook.
6. **Commit F — dry-run + budget-telemetry docs-only:** pattern files land; actual mode-pack support is Phase 2.6.
7. **Commit G — promotion:** flip `E_*` new codes from warn-only to block. Fix any violations that surface.

Parallelizable:

- **A** and drafting for **B** can be authored concurrently.
- **E** can proceed in parallel with **D** once **C** is merged.
- Everything else sequential because each step depends on the previous file layout.

## 5. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Reference sweep in Commit C misses a file → broken link | Medium | Medium (pre-commit catches via `E_UNKNOWN_CONTRACT_REF` once live — but that code lands in D) | One-off script step in C: grep all `_shared/` refs pre- and post-move, diff the resolution map. |
| Linter walk widening surfaces latent `E_FRONTMATTER` violations in subdirs | Medium | Low | Pre-flight linter run before commit A; fix frontmatter in a preceding commit. |
| Symlinks from `~/.claude/skills/_shared/` break | Low | High (every agent session) | Enumerate symlinks pointing into `_shared/` before the move; update targets or convert to top-level (`~/.claude/skills/_shared` → repo `_shared/`, intact). |
| `ARCH_LINT=0` bypass masks a broken reorg commit | Low | High | Never bypass in Commits A–G. If pre-commit fails, fix, don't skip. |
| Phase 2.6 starts before `_shared/` stabilizes | High | High (churn tax) | Freeze `_shared/` layout at end of 2.5. Any new primitive in 2.6 lands in the new subdirs from day one. |
| Read/write decls reveal we're writing outside declared scope today | Medium | Low (informational) | Treat first pass as discovery; fix discrepancies in 2.6 mode-pack rewrites, not 2.5. |
| Capability manifest generator crashes pre-commit on malformed frontmatter | Low | Medium (commits blocked) | Start as warn-only; promote to block after one green week. |

## 6. Open questions

- **Should `brief-formats/` move under `contracts/` or stay top-level?** Recommended: **move under `contracts/brief-formats/`.** Briefs are inter-agent contracts; grouping signposts intent.
- **Do we introduce `_shared/schemas/` as a new home for `token-budgets.json` and future JSON, or leave JSON at `_shared/` root?** Recommended: **`_shared/schemas/` for all machine-readable data.** Uniform rule for linter + humans.
- **`schema_version` format: `"name@N"` string vs `{name, version}` object?** Recommended: **string `"name@N"`.** Grep-friendly, one-line diffs; objects add ceremony without utility until we have ranges.
- **Should `E_MISSING_RW_DECL` apply to `SKILL.md` routers too?** Recommended: **no, modes only.** Routers dispatch; they don't perform the writes.
- **Idempotency key for `events.md` appends — enforce uniqueness, or accept best-effort-append?** Recommended: **best-effort-append with post-hoc dedupe in compact.** Enforcing at write-time means every producer locks the day's log file.
- **Dry-run: ship actual `--dry-run` implementations in any mode this phase, or docs-only?** Recommended: **docs-only in 2.5; implementations land per-mode in 2.6 alongside rewrites.**
- **Capability manifest — generated artifact committed to git, or regenerated on each session-start?** Recommended: **committed, regenerated by pre-commit hook (like `docs-surface.json`).** Reviewable drift in PRs; no session-start latency.
- **Do we split `chanakya-principles.md` now (pattern + event-contract), or defer?** Recommended: **defer to 2.6.** Referenced everywhere; splitting mid-phase doubles the reference-sweep risk.

## Notes from drafting

Files that surprised during exploration:

- `_shared/turnip-project-config.md` — project-specific config under `_shared/`. Orphaned from the "shared across projects" premise; flagged for a future `projects/` layout.
- `_shared/token-budgets.json` is almost empty (`mode_budgets: {}`) — the existing `W_BUDGET_DRIFT` check is effectively dormant. Populate in 2.5 or acknowledge aspirational.
- `scripts/lint-architecture.sh`'s `collect_candidates` hardcodes `-maxdepth 1` at line 42 — reorg silently breaks linter coverage unless Commit A lands first.
- `scripts/scaffold-agent.sh` hardcodes `_shared/router-pattern.md` in generated scaffolds (lines 48, 65–67). Must update in Commit C or new scaffolds leak broken paths.
- Many references use two forms — repo-relative `_shared/foo.md` AND absolute `~/.claude/skills/_shared/foo.md`. Sed sweep needs both patterns per file.
