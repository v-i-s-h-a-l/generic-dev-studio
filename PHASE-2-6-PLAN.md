# Phase 2.6 Execution Plan (draft)

Drafted 2026-04-20 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Design decisions below are each marked locked or deferred; deferred rows have a recommended default in **bold**.

Phase 2.6 overhauls the ledger: every artifact becomes structured YAML, event logs consolidate from nine locations to one, `plans/index.yaml` joins the artifacts relationally, every Chanakya and Achilles mode pack is rewritten against the new contracts, agent-versioning hooks land, and a new Achilles `/achilles debrief` mode ships. Built on the Phase 2.5 contracts (message envelope, schema versioning, state machines, capability manifest, event-log reader primitive). Gated by 2.5; gates 2.7.

See `ROADMAP.md` §Phase sequence, `PHASE-2-5-PLAN.md` for upstream contracts, and `ARCHITECTURE.md` §Design Vision for agent-roster rationale.

## 0. Standards and non-negotiables

These govern every decision here; unchanged from 2.5 §0, restated for self-containment:

- **World-class or it doesn't ship.** Scalable, reliable, fast, observable, versioned, testable. No fragile migrations — dual-write + shadow-read + halt-on-divergence is table stakes. Vertical slices, never wide fragile layers. See memory: `feedback_world_class_standard.md`.
- **Agent-first design.** Structured, machine-readable, zero prompts. Agent drift (model versions, prompt wording, agent boundaries) is the error model — design against it, not against human typos. See memory: `feedback_no_manual_input.md`.
- **Three-tier artifact paths.** Tier 1 = repo; tier 2 = `~/.dev-studio/<project>/`; tier 3 = `~/.dev-studio/<project>/shared/<machine-id>/`. All writes resolve via `scripts/lib-paths.sh` — never hardcode. See memory: `feedback_artifact_paths.md`.
- **Minimal permission footprint.** No new allowlist asks. All ledger writes stay under the existing two roots.

## 1. Decisions table — locked vs deferred

| # | Decision | Status | Resolution |
|---|---|---|---|
| Q1 | Ledger migration strategy | Locked | Dual-write (old paths + new YAML) + parallel read + shadow-read verifier. Verifier emits `ledger_divergence` events; migration auto-halts when divergence > 0.1%. No fail-over complexity — user confirmed no in-flight work during migration, so freeze-on-divergence is the correct default. |
| Q2 | Schema versioning scope | Locked | Per-type SemVer. Each artifact type (task, brief, debrief, review, round, release, feedback, crash) independently versioned using the `{name, version, min_reader, deprecated_at}` object form from 2.5 Q10. |
| Q3 | Agent-boot payload shape | Locked | Rich: `{agent, git_sha, skill_version, schema_versions, loaded_mode_packs, active_snapshots, token_budget}`. Trim after debugging stabilizes (post-2.6 review). |
| Q4 | Achilles `/achilles debrief` invocation | Locked | Conversational. Scans transcript + staged/working-tree diff, asks inline whether tests are needed, emits YAML debrief. Ships in 2.6 against the new schema. No flag-heavy form. |
| Q15 | `plans/index.yaml` structure | Locked | Hybrid (option c): normalized relational index *and* back-references embedded in individual artifact files. Both shapes. Index is authoritative for queries; back-refs let a single file stand alone. |
| Q16 | In-flight work during migration | Locked | None. User assures migration runs on a quiesced project. This makes freeze-on-divergence safe; no dual-code-path fallback needed. |
| Q17 | Ledger inventory | Locked | Audit complete (2026-04-20). Nine event-log files + four directories enumerated in §3. Consolidation map concrete. |
| Q18 | Processed-brief archive treatment | **Deferred — recommend: archive as-is, no re-migration.** | 141 processed briefs in `chanakya-inbox/processed/` are historical. Copy to `archive/2026-pre-2.6/` untouched; new consumers read only post-cutover YAML. Cheaper than forward-porting dead state. |
| Q19 | Feedback-dir pruning scope | **Deferred — recommend: prune `.gitkeep`-only dirs at cutover.** | `archive/`, `reporters/`, `root-causes/` are placeholder-only. Delete at cutover; recreate lazily on first real write. |
| Q20 | Debrief/inbox taxonomy cleanup timing | **Deferred — recommend: cleanup in-flight during transform step.** | Migration script detects misfiled debriefs (e.g. `*-debrief.md` in inbox root) and routes to `debriefs/` during transform. Logged in migration report. |
| Q21 | Release-lifecycle state machine home | Locked | Ships in 2.6 per 2.5 §3.9 deferral. Lands as `state-machines/release-lifecycle.md` in Commit B. |

## 2. Target ledger layout

Post-migration structure under `~/.dev-studio/<project>/` (tier-2):

```
plans/
  index.yaml                      # relational index (§4)
  tasks/<task-id>.yaml            # one file per task artifact
  briefs/<brief-id>.yaml          # Chanakya → Achilles contract instances
  debriefs/<debrief-id>.yaml      # Achilles → Chanakya outputs
  reviews/<review-id>.yaml        # Argus verdicts + user-testing rounds
  rounds/<round-id>.yaml          # user-testing round aggregates
  releases/<release-id>.yaml      # TestFlight / App Store submissions
  feedback/<feedback-id>.yaml     # user + Slack + crash-sourced feedback
  crashes/<crash-id>.yaml         # Crashlytics-derived records
events/
  YYYY-MM-DD.jsonl                # single canonical event log, partitioned by day
  index.yaml                      # manifest: day → first/last ts, event count, schema versions seen
archive/
  2026-pre-2.6/                   # pre-migration snapshot (frozen, read-only)
shared/<machine-id>/              # tier-3 (unchanged from 2.5)
.runtime/                         # derived/regenerated (unchanged)
```

### 2.1 Artifact YAML schemas

Each artifact carries the standard `schema_version` object (2.5 Q10) plus type-specific fields. All timestamps RFC3339 UTC. All IDs UUIDv7.

**Task** (`schemas/task.md`, `task@1.0.0`):

```yaml
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
title: "…"
state: proposed|briefed|dispatched|in-progress|self-reviewed|argus-reviewed|merged|verified|rejected|archived
size: xs|s|m|l
created_at: …
updated_at: …
links:
  brief: <brief-id>?
  debrief: <debrief-id>?
  reviews: [<review-id>…]
  release: <release-id>?
  feedback: [<feedback-id>…]
history: [{from, to, actor, at, event_id}…]   # state-transition log
```

**Brief** (`schemas/brief.md`, `brief@3.1.0` — bumped from 2.5's 3.x object form):

```yaml
schema_version: {name: brief, version: 3.1.0, min_reader: 3.0.0, deprecated_at: null}
id: <uuidv7>
task_id: <uuidv7>
size: xs|s|m|l
figma: {…} | null
reads: [<path>…]
writes: [<path>…]
acceptance: […]
testability: […]
# body markdown in `body:` multi-line string
```

**Debrief** (`schemas/debrief.md`, `debrief@2.0.0` — breaking from current `debrief-format.md` markdown):

```yaml
schema_version: {name: debrief, version: 2.0.0, min_reader: 2.0.0, deprecated_at: null}
id: <uuidv7>
task_id: <uuidv7>?            # null for /achilles debrief direct-mode fixes
mode: task|direct-debrief
diff_summary: {files, +lines, -lines}
decisions: [{what, why}…]
tests: {added: [], modified: [], skipped_because: "…"?}
debt: {build: bool, test: bool, notes: "…"?}
open_questions: [...]
```

**Review** (`schemas/review.md`, `review@1.0.0`):

```yaml
schema_version: {name: review, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
subject: {kind: task|round|release, id: <uuidv7>}
reviewer: argus|user|chanakya
verdict: approved|flagged|blocked
findings: [{rule, tier, message, path?}…]
```

**Round / Release / Feedback / Crash** follow the same envelope pattern — one file per artifact, typed schema, links table, state history. Full field lists in `_shared/schemas/<name>.md` shipped by Commit B.

### 2.2 Back-reference convention (Q15)

Every artifact YAML includes a `links:` block naming related artifacts by ID. `plans/index.yaml` is the authoritative relational join; individual files carry enough back-refs to be understandable in isolation (agent opens one file, sees what it connects to, can resolve via index). Back-refs are maintained by the writer that creates the link; validator (§4) checks bidirectional consistency.

## 3. Event-log consolidation

### 3.1 Source inventory (from Q17 audit, 2026-04-20)

Nine files across four directories:

| Source path | Role (inferred) | Action |
|---|---|---|
| `~/.dev-studio/<project>/event-log.jsonl` | Legacy flat log | Merge → canonical, archive original |
| `~/.dev-studio/<project>/events.jsonl` | Duplicate legacy | Merge → canonical, archive |
| `~/.dev-studio/<project>/events.log` | Text-format variant | Parse best-effort, merge, archive |
| `~/.dev-studio/<project>/events/<yyyy-mm-dd>.jsonl` | Partial day-partition (new shape) | Move → canonical `events/<yyyy-mm-dd>.jsonl` |
| `~/.dev-studio/<project>/events/agents.jsonl` | Agent-boot only | Merge → canonical (type tag preserved), archive |
| `~/.dev-studio/<project>/events/events.jsonl` | Undifferentiated stream | Merge → canonical by `occurred_at` → per-day, archive |
| `~/.dev-studio/<project>/.runtime/events.jsonl` | Runtime-dir duplicate | Merge → canonical, archive |
| `~/.dev-studio/<project>/.runtime/events.ndjson` | NDJSON variant | Parse, merge, archive |
| `~/.dev-studio/<project>/plans/chanakya-events.jsonl` | Chanakya-only stream | Merge → canonical (producer tag preserved), archive |

### 3.2 Canonical target

Single path: `~/.dev-studio/<project>/events/YYYY-MM-DD.jsonl`. Day-partitioned by `occurred_at` UTC date. Append-only. `events/index.yaml` manifests each day (first/last ts, event count, schema versions seen).

### 3.3 Merge algorithm

1. Stream all nine sources; parse each line with tolerant JSON (NDJSON variant normalizes).
2. Dedupe on `(producer.agent, idempotency_key)` per 2.5 Q12. If key missing (legacy events), synthesize `legacy:<source>:<line-hash>`.
3. Sort globally by `occurred_at`; bucket into day files.
4. Validate each event against `contracts/events.md` schema; unparseable events land in `archive/2026-pre-2.6/unparseable-events.jsonl` with source + line number.
5. Emit `ledger_migration_merged` summary event.

### 3.4 Reader migration

The 2.5-shipped `scripts/read-events.sh` primitive becomes the only event-log entry point. Every consumer (Chanakya modes, Achilles modes, Argus, future dashboard) switches to it in Commit E. Legacy paths trigger a `legacy_event_read` warning event for one cycle, then become read-errors.

## 4. `plans/index.yaml` structure

Relational index joining all artifact types (Q15 locked: hybrid):

```yaml
schema_version: {name: plans-index, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
generated_at: <rfc3339>
generator: scripts/rebuild-index.sh
tasks:
  - id: <uuidv7>
    state: …
    brief: <brief-id>?
    debrief: <debrief-id>?
    reviews: [<review-id>…]
    release: <release-id>?
briefs: [{id, task_id, state}…]
debriefs: [{id, task_id?, mode}…]
reviews: [{id, subject, verdict}…]
rounds: [{id, tasks: [<task-id>…]}…]
releases: [{id, tasks: [<task-id>…], channel, state}…]
feedback: [{id, linked_tasks: [<task-id>…], source}…]
crashes: [{id, linked_tasks: [<task-id>…]}…]
```

### 4.1 Lifecycle

- **Regenerated**, never hand-edited. `scripts/rebuild-index.sh` globs `plans/*/` YAML, produces canonical output with stable ordering.
- Pre-commit hook reruns if any artifact file staged.
- Validator contract (`contracts/plans-index-validator.md`):
  1. Every `links:` back-ref in an artifact has a matching entry in the index.
  2. Every index entry points at a real file.
  3. Bidirectional consistency: `task.links.brief = X` ⇔ `brief.task_id = task.id`.
  4. No orphans (artifact present, no reference) — warn.
  5. No dangling (reference present, no artifact) — block.

### 4.2 Query pattern

Agents reading the ledger call `scripts/query-plans.sh --kind=task --state=verified` (thin wrapper over `yq`) instead of globbing. Consistent shape across consumers.

## 5. Achilles `/achilles debrief` mode

New mode-pack `achilles/modes/debrief.md`. Ships in 2.6 against the new YAML schema.

### 5.1 Invocation

Conversational. User types `/achilles debrief` with no args inside an active Claude session. Mode reads session state directly — it is designed for the *direct-to-Claude* bug-fix path that bypasses brief → worktree → Argus.

### 5.2 Behavior

1. **Scan transcript** — recent turns in the current session for intent signals (what was asked, what was changed).
2. **Scan diff** — working-tree + staged changes (`git diff HEAD`). Summarize files, +/- lines, touched areas.
3. **Infer decisions** — why-level notes extracted from transcript + code commentary.
4. **Ask inline about tests** — single conversational question naming the touched files: *"Changes in `<files>` — do these need tests? y / n / describe."* Default captured even if user skips.
5. **Emit debrief YAML** to `plans/debriefs/<uuidv7>.yaml` with `mode: direct-debrief`, `task_id: null`.
6. **Event** `debrief_emitted` per 2.5 contract.

### 5.3 Integration with existing debrief pipeline

Schema matches task-mode debrief (§2.1) with `task_id: null` sentinel + `mode: direct-debrief`. Chanakya's debrief-ingest mode reads both shapes uniformly — no branching. Knowledge-layer (2.7) indexes them identically.

### 5.4 Non-goals

- Not a review. No verdict. No Argus invocation.
- Not an autoformatter. Zero code changes.
- Not a git action. Does not stage, commit, or push.

## 6. Migration script architecture

`scripts/migrate-ledger.sh` — project-scoped. Run against the first project with accumulated ledger state; other projects migrate later if/when they accumulate state.

### 6.1 Phases

1. **Backup** — snapshot entire `~/.dev-studio/<project>/` tree to `archive/2026-pre-2.6/` with atomic rename. Idempotent: skip if archive exists.
2. **Transform** — read legacy artifacts, emit new YAML to a **staging path** (`~/.dev-studio/<project>/.migration-staging/`). Does not touch canonical paths yet. Detects misfiled artifacts (Q20) and routes correctly in the process.
3. **Dual-write window** — both old writers and new writers emit simultaneously. Duration: as long as verifier reports 0 divergence.
4. **Verify** — shadow-read verifier (§6.3) runs on a loop.
5. **Cutover** — atomic rename staging → canonical. Legacy paths become read-error on next access. Archive kept.

### 6.2 Dual-write shape

Every Chanakya/Achilles write during the migration window goes through a `write_artifact(kind, payload)` helper that:

- Writes the YAML form to the new canonical path.
- Writes the legacy form (markdown brief, flat event line, etc.) to the old path.
- Tags both with a shared `migration_write_id` so the verifier can pair them.

Helper lives at `scripts/dual-write.sh`. Removed in the commit that flips cutover.

### 6.3 Shadow-read verifier

`scripts/verify-ledger.sh`:

1. Reads a random 5% sample of `migration_write_id` pairs per run.
2. Normalizes each side to a canonical comparison form (strip whitespace, sort keys, resolve IDs).
3. Computes divergence rate = mismatches / sampled.
4. If `> 0.1%` for two consecutive runs → emit `ledger_divergence` event, **freeze migration** (dual-write continues; cutover blocked).
5. If `0` for 24h of sustained writes → emit `ledger_convergence_achieved`, cutover unblocked.

Runs on a loop during the dual-write window (human-triggered or cron; not a daemon).

### 6.4 Halt-on-divergence logic

On freeze: emit `ledger_migration_frozen` with divergence diff. User investigates manually. No automatic rollback — the dual-write means both shapes are intact. Resume by fixing the root cause and re-running verify.

## 7. Mode-pack rewrite checklist

Every Chanakya + Achilles mode pack is rewritten against the new contracts. Grouped by risk.

### 7.1 Low-risk (docs-only contract updates)

Path renames, schema-ref bumps, `reads:`/`writes:` pointer updates. Mechanical.

- Chanakya: `status`, `report-design`, `report-product`, `feedback-history`, `feedback-archive`, `sync-slack`, `ingest-thread`, `ingest-dm`, `ingest-slack`, `test-manifest`, `test-flow`.
- Achilles: `build` (docs-only — no behavior change).

### 7.2 Medium-risk (emit new YAML shape)

Writers whose output format changes from markdown/free-form to typed YAML.

- Chanakya: `brief`, `brief-all`, `review`, `update`, `compact`, `sweep-debt`, `ingest-*` (debrief emission path).
- Achilles: `task` (debrief emission), `push-tf`, `app-store` (release artifact emission).

### 7.3 High-risk (behavioral change)

State-machine adherence, new contracts enforced, event emission shape.

- Chanakya: `verify` (reads new review/round shape), `review-feedback` (joins feedback + task via index).
- Achilles: `debrief` (**new mode**, §5).
- All modes: adopt `agent_boot` hook (§8) at first-write of session.

### 7.4 Rewrite order

Low → medium → high. Within each tier, leaf modes (no dependents) first. Every rewrite commit keeps dual-write active, so no mode ever writes only the new shape until cutover.

## 8. Agent-versioning hooks

### 8.1 `agent_boot` event

Emitted once per agent session at first write. Payload per Q3:

```yaml
schema_version: {name: agent-boot, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
agent: chanakya|achilles|argus
git_sha: <short-sha>              # repo commit at session start
skill_version: <semver>           # from SKILL.md frontmatter
schema_versions:                  # every schema the agent will read/write this session
  - {name: brief, version: 3.1.0}
  - {name: debrief, version: 2.0.0}
  - …
loaded_mode_packs: [<name>…]
active_snapshots: [<snapshot-id>…]
token_budget: {session_cap, mode_caps: {…}}
```

### 8.2 Reader validation

Any consumer reading an artifact checks:

1. Artifact's `schema_version` is known to this reader.
2. Reader's version `>=` artifact's `min_reader`.
3. Fail loudly on mismatch — emit `schema_read_rejected`, refuse to process. Never silently degrade.

### 8.3 Mismatch handling

Two buckets:

- **Reader too old** (`reader_version < artifact.min_reader`) — block. User upgrades studio.
- **Reader too new** (`reader_version >> artifact.version`) — allowed if `artifact.deprecated_at` is null. Emit `schema_version_gap` warn. If `deprecated_at` is in the past, block.

Keeps drift observable without hair-trigger breakage.

## 9. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: 10 commits.

1. **Commit A — schemas land.** All YAML schemas (§2.1) under `_shared/schemas/` as flat markdown specs. No script/mode changes. Pre-commit validates schemas parse.
2. **Commit B — state-machines land.** `state-machines/release-lifecycle.md` + `state-machines/feedback-lifecycle.md` (deferred from 2.5 §3.9). Plus `contracts/plans-index-validator.md`.
3. **Commit C — migration primitives.** `scripts/dual-write.sh` + `scripts/verify-ledger.sh` + `scripts/migrate-ledger.sh` (backup + transform phases only, not cutover). Unit tests on fixture ledger.
4. **Commit D — `plans/index.yaml` generator.** `scripts/rebuild-index.sh` + `scripts/query-plans.sh`. Wired into pre-commit. Smoke test rebuild-from-scratch.
5. **Commit E — event-log consolidation.** Run one-shot merge of the 9 sources → canonical day-partitioned files. Archive originals under `archive/2026-pre-2.6/events/`. Every consumer flipped to `scripts/read-events.sh`. Legacy-path access → warn.
6. **Commit F — Agent-boot hook.** `contracts/agent-boot.md` + emission helper. All three agent SKILL.md files add the hook. Schema-version validation primitive (`scripts/validate-schema.sh`).
7. **Commit G — low-risk mode-pack rewrites (§7.1).** Pure path/ref updates. Dual-write active.
8. **Commit H — medium-risk mode-pack rewrites (§7.2).** Writers emit new YAML shape; legacy writes continue via dual-write. Verifier runs.
9. **Commit I — high-risk mode-pack rewrites + `/achilles debrief`.** `achilles/modes/debrief.md` (§5). Remaining behavioral changes.
10. **Commit J — cutover.** Verifier green for 24h with sustained writes → flip. `scripts/dual-write.sh` removed; legacy paths removed from `lib-paths.sh`. Archive frozen. Post-cutover validation run.

Parallelizable: A ‖ B. G ‖ H's drafting once F merges. Migration script testing (C) can run against fixture data anytime after A.

## 10. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Divergence verifier too noisy (false positives from whitespace/ordering) | Medium | Medium (false freeze) | Canonical-form normalization in verifier; two-consecutive-runs rule before freeze. |
| Legacy event parse fails on `events.log` text format | High | Low (rows skipped to `unparseable-events.jsonl`) | Expected; reviewed manually post-merge. |
| Mode-pack rewrite Commit H introduces behavior drift | Medium | Medium | Per-mode diff review; Commit G precedes so contract-only changes land first. |
| `agent_boot` hook doubles session overhead | Low | Low | Emitted once; size ~1 KB. Trimmed per Q3 post-stabilization. |
| `plans/index.yaml` regenerator slow at scale (141+ tasks × 8 kinds) | Low | Medium | YAML globbing + `yq` aggregation; if >2s, move to incremental rebuild. |
| Cutover flips before verifier actually green | Low | High | Gate: `verify-ledger.sh` must report `ledger_convergence_achieved` event before Commit J runs; script-enforced, not human-trusted. |
| Dual-write path divergence because helper misses an edge case (e.g. cancel events) | Medium | Medium | Verifier catches it by construction; that is the whole point. |
| Migration script run against a non-quiesced project (Q16 violated) | Low | High | Pre-flight check: `scripts/migrate-ledger.sh` aborts if any event <30s old or any worktree has uncommitted changes. |
| `/achilles debrief` writes into wrong dir during dual-write window | Low | Low | Emits through same `write_artifact` helper — no new paths. |

## 11. Post-2.6 freeze rules

When Commit J merges:

- Ledger layout under `plans/` + `events/` is **frozen**. New artifact kinds land in a new subdir under `plans/`, never at root.
- Markdown artifacts forbidden — any new artifact kind must define a YAML schema first and land in `_shared/schemas/`.
- Event-log writes go **only** through `scripts/write-event.sh` (wraps canonical day-partitioned append). No direct file appends.
- Event-log reads go **only** through `scripts/read-events.sh`.
- Legacy paths (old event files, markdown briefs, inbox-subdir debriefs) removed from `lib-paths.sh`; any reference is a lint block.
- Agent-boot hook is mandatory at first write. Sessions without a recent `agent_boot` event are treated as drift and flagged by Argus.

## 12. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **Q18** — processed-brief archive forward-port. Recommended archive-as-is for 2.6; revisit if knowledge-layer (2.7) wants structured access to pre-cutover briefs.
- **Q19** — feedback-dir pruning scope. Recommended prune-at-cutover; revisit only if a consumer proves it needed the placeholder shape.
- **Q20** — debrief/inbox taxonomy cleanup. Recommended in-flight during transform; manual audit of migration report after Commit E.
- **Other projects** — migration script is project-scoped but run only against the pilot project in 2.6. Other projects migrate opportunistically when they accumulate ledger state.
- **Dashboard reads** (Phase 6) — target schemas land in 2.6; dashboard consumption deferred.
- **`chanakya-snapshots/` regeneration** — derived, not migrated. Flush + rebuild on first post-cutover session.
- **Per-artifact CHANGELOG files** — schema-history tables in `_shared/schemas/<name>.md` are enough for 2.6. Dedicated changelogs only if drift becomes hard to track.
