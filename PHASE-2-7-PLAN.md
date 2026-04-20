# Phase 2.7 Execution Plan (draft)

Drafted 2026-04-20 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q24–Q31 are each marked locked or deferred; deferred rows have a recommended default in **bold**.

Phase 2.7 builds the **synthesis / analytical layer** on top of the Phase 2.6 structured ledger. The original ROADMAP framing ("project-memory + memory-query + knowledge mode + Slack-ingest join") was shape-correct but intent-narrow: "find similar bugs" retrieval duplicates `git log` + `grep`. The real product is a set of **named, aggregated views** that answer questions the raw ledger can't easily answer — workflow shape, architecture shape, testing health, token-cost shape. Tier A (SQLite FTS5 substrate) indexes every structured artifact + Slack row; Tier B (view generators) produces machine-readable outputs under `views/`; a thin renderer turns those into markdown for skim.

See `ROADMAP.md` §Phase sequence, `PHASE-2-5-PLAN.md` + `PHASE-2-6-PLAN.md` for upstream contracts, and `ARCHITECTURE.md` §Design Vision for agent-roster rationale. Gated by 2.6 (needs the YAML ledger). Parallelizable with Phase 3.

## 0. Standards and non-negotiables

Unchanged from 2.5/2.6 §0, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale, not fit-for-enterprise.** Single-user workflow tool; the real work is the `<project>` that calls this studio. Zero paid services, no resident LLMs, no multi-GB dbs. For 2.7 specifically: synthesis must be **light at idle** (zero RAM, zero polling) and **cheap at query time** (<200 ms for a view regen on this project's scale).
- **Agent-first design.** View outputs are machine-readable primary, human-readable secondary. Shapes are stable, versioned, and agent-safe. The consumer is usually another agent or another view generator — not a human dashboard.
- **Three-tier artifact paths.** Substrate db + view outputs live under tier 2 (`~/.dev-studio/<project>/`). No tier-3 writes — views are per-machine derived state, cheaply regenerated. No new allowlist asks.
- **Minimal permission footprint.** All reads and writes resolve via `scripts/lib-paths.sh`. SQLite is a single-file db — no daemon, no port, no extra permission.

## 1. Decisions table — locked vs deferred

| # | Decision | Status | Resolution |
|---|---|---|---|
| Q24 | Knowledge store substrate | Locked | SQLite FTS5. Single-file db, zero RAM idle, <5 MB at this scale, no paid deps, no local LLM. Ships with macOS; zero install. |
| Q25 | Synthesis trigger | Locked | Hybrid: incremental index update on artifact writes (hook into the `events/YYYY-MM-DD.jsonl` append + `plans/**/*.yaml` write paths) + periodic full rebuild (catches drift, runs after schema bumps / migrations / manual recovery). |
| Q26 | Query shape | Locked | Not "find similar text" (git log + grep covers that). Named **views** that aggregate Tier A substrate into Tier B structured outputs. Each view is a deliberately-designed answer to a recurring question. |
| Q27 | Producers | Locked | Debriefs, reviews (Argus + user rounds), feedback records, release artifacts, crashes (once Phase 5 feeds them), ADRs (once Phase 4 produces them). Agent consumers are **deferred** — primary consumers in 2.7 are the view generators themselves. |
| Q28 | Slack-ingest unification | Locked | Single SQLite db with `source: slack` tag on Slack rows alongside artifact rows. Unified query surface; no separate Slack db. |
| Q29 | Must-ship-in-2.7 views | Locked | **Four priority views:** `workflow-signature`, `architecture-overview`, `testing-health`, `token-cost-budget`. Seven others (listed §10) are opt-in / later. |
| Q30 | View output format | Locked | Machine-readable primary — structured JSON under `~/.dev-studio/<project>/views/<view-name>/<date>.json` (YAML allowed where more ergonomic; one format per view, declared in the contract). Markdown is a thin optional renderer. |
| Q31 | Refresh cadence | Locked | On-demand via `/chanakya knowledge view <name>` + weekly cron (opt-in, hooked into Phase 3's `/schedule` once that lands). No real-time dashboard refresh. |

## 2. Tier A — FTS5 substrate

### 2.1 Location + layout

```
~/.dev-studio/<project>/memory/
  artifacts.db              # SQLite, FTS5 enabled
  artifacts.db-wal          # WAL mode (durability + concurrent reads)
  artifacts.db-shm
  migrations/<n>.sql        # schema migrations, applied in order
  .last-rebuild             # RFC3339 ts of last full rebuild
```

Tier-2 per-project path. Not synced (tier-3) — derived state, regenerate on another machine. Added to `scripts/lib-paths.sh` as `resolve_memory_db`.

### 2.2 Schema

Single canonical `artifacts` table + per-kind FTS5 virtual tables for fast text search, joined by `id`.

```sql
CREATE TABLE artifacts (
  id             TEXT PRIMARY KEY,      -- UUIDv7 from source artifact
  kind           TEXT NOT NULL,         -- task|brief|debrief|review|round|release|feedback|crash|slack|adr
  source         TEXT NOT NULL,         -- ledger|slack|phase-5-crash|phase-4-adr
  source_path    TEXT,                  -- tier-2 path of origin (for ledger), or slack uri
  occurred_at    TEXT NOT NULL,         -- RFC3339 UTC
  schema_version TEXT NOT NULL,         -- serialized {name, version, min_reader, deprecated_at}
  producer       TEXT,                  -- agent name (ledger) or slack user (slack)
  state          TEXT,                  -- artifact-kind-specific state field
  links_json     TEXT,                  -- serialized links[] array
  body_json      TEXT NOT NULL,         -- full artifact payload, canonicalized
  indexed_at     TEXT NOT NULL
);

CREATE INDEX idx_artifacts_kind_time  ON artifacts(kind, occurred_at);
CREATE INDEX idx_artifacts_source     ON artifacts(source);
CREATE INDEX idx_artifacts_state      ON artifacts(kind, state);

CREATE VIRTUAL TABLE artifacts_fts USING fts5(
  id UNINDEXED,
  title,
  body,
  decisions,       -- debrief decisions field, flattened
  findings,        -- review findings, flattened
  tokenize = 'porter unicode61 remove_diacritics 2'
);
```

**Tokenizer choice:** `porter unicode61` — good enough for code-adjacent English, zero-config, built into macOS SQLite. No custom stemmer, no external lib.

**WAL mode:** `PRAGMA journal_mode=WAL`. Readers never block writers; view regens can run concurrent with an ingest.

### 2.3 Per-kind indexed fields

Each artifact kind defines which fields land in `artifacts_fts` vs structured columns. Declared in `_shared/contracts/memory-ingest.md`.

| Kind | FTS fields | Structured columns | Notes |
|---|---|---|---|
| `task` | title, body | kind, state, occurred_at, links_json | From `plans/tasks/<id>.yaml`. |
| `brief` | title, body (acceptance + testability) | kind, state, occurred_at, links_json | `body` concatenates acceptance + testability bullets. |
| `debrief` | title, body, decisions | kind, state, occurred_at, links_json | `decisions` = flattened `[what, why]` pairs. |
| `review` | title, findings | kind, state, occurred_at, links_json | `findings` = flattened rule + message. |
| `round` | title, body | kind, state, occurred_at, links_json | |
| `release` | title, body (release-notes) | kind, state, occurred_at | |
| `feedback` | title, body | kind, occurred_at, source (user/slack/crash) | |
| `crash` | title (stack-top) | kind, occurred_at | Deferred producer — Phase 5 feed. Row schema fixed now. |
| `slack` | body | source="slack", producer=user, occurred_at | `links_json` carries any referenced task/feedback IDs. |
| `adr` | title, body (decision + rationale) | kind, state, occurred_at | Deferred producer — Phase 4 feed. Row schema fixed now. |

**Zero-row tolerance:** kinds with no producers yet (crash, adr) register their row schema during 2.7 — view generators handle absence gracefully (empty input → view still emits a valid JSON with `row_count: 0`).

### 2.4 Migration-aware ingest

`scripts/memory-ingest.sh` — the single entry point. Two modes:

1. **Incremental** (default) — given one artifact path or event-log line, parse, canonicalize body to JSON, upsert into `artifacts` + refresh the FTS row. Idempotent on `id` (per 2.5 Q12).
2. **Full rebuild** (`--rebuild`) — drops `artifacts_fts`, truncates `artifacts`, walks every YAML under `plans/**/*.yaml`, every line of `events/**/*.jsonl`, every indexed Slack artifact, re-ingests. Writes `.last-rebuild`. Idempotent.

Schema migrations live in `memory/migrations/<n>.sql`, applied in order on any ingest. The ingest script records `schema_version` per-row so old views can still read older artifacts.

Post-Phase-2.6 bootstrap ingest runs once after the 2.6 cutover commit — indexes the full converted YAML ledger + Slack artifacts. After that, incremental carries the load.

## 3. Tier B — view generators (the four priority views)

Every view generator is a script under `scripts/views/<view-name>.sh` that:

1. Reads Tier A (SQLite queries, no direct file reads).
2. Produces exactly one output file: `views/<view-name>/<date>.json`.
3. Is idempotent on input — same substrate → same output.
4. Emits an `view_generated` event with `{view_name, schema_version, row_count, input_cursor}`.

Every view's JSON output carries a `schema_version` object (per 2.5 Q10 + 2.6 Q2) so consumers can evolve without breakage. Output schemas declared in `_shared/schemas/view-<name>.md`.

### 3.1 View: `workflow-signature`

**Question answered:** "What's unique about how we work?" — cycle-time percentiles per task size, rework rate, Argus-flag rate, blocked-task time distribution. The signature that distinguishes this project's workflow from a generic one.

**Inputs:**
- Event types: `task_state_transition`, `review_emitted`, `task_blocked`, `task_unblocked`.
- Artifact kinds: `task` (for size + current state), `review` (for verdict).
- Sample query: `SELECT state, occurred_at FROM task_transitions WHERE task_id=?` to reconstruct cycle time per task.

**Output schema** (`schemas/view-workflow-signature.md`, `view-workflow-signature@1.0.0`):

```json
{
  "schema_version": {"name": "view-workflow-signature", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
  "generated_at": "2026-04-20T10:00:00Z",
  "window": {"from": "2026-03-20T00:00:00Z", "to": "2026-04-20T00:00:00Z"},
  "cycle_time_by_size": {
    "xs": {"p50_hours": 0.5, "p90_hours": 2.0, "sample_n": 42},
    "s":  {"p50_hours": 2.1, "p90_hours": 8.0, "sample_n": 18},
    "m":  {"p50_hours": 6.0, "p90_hours": 24.0, "sample_n": 7},
    "l":  {"p50_hours": 18.0, "p90_hours": 72.0, "sample_n": 3}
  },
  "rework_rate": {"overall": 0.12, "by_size": {"xs": 0.05, "s": 0.15, "m": 0.22, "l": 0.33}},
  "argus_flag_rate": {"overall": 0.28, "by_size": {"xs": 0.10, "s": 0.30, "m": 0.45, "l": 0.50}},
  "blocked_duration": {"p50_hours": 1.0, "p90_hours": 18.0, "count": 11},
  "row_count": 70
}
```

**Dimensions:** size, sliding window (30-day default + all-time). Frequency: weekly cron + on-demand.

### 3.2 View: `architecture-overview`

**Question answered:** "What is this codebase's *shape* right now?" — directory churn map, coupling signals (files touched together across debriefs), ADR references per area.

**Inputs:**
- Artifact kinds: `debrief` (files_touched lists), `adr` (area tags, deferred producer).
- Sample query: `SELECT json_extract(body_json, '$.diff_summary.files') FROM artifacts WHERE kind='debrief' AND occurred_at > ?`.

**Output schema** (`view-architecture-overview@1.0.0`):

```json
{
  "schema_version": {"name": "view-architecture-overview", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
  "generated_at": "…",
  "window": {"from": "…", "to": "…"},
  "churn_by_directory": [
    {"path": "src/ui/", "debrief_count": 23, "unique_files": 14, "last_touched": "…"}
  ],
  "coupling": [
    {"files": ["src/ui/Cart.swift", "src/net/CartSync.swift"], "co_touched_count": 8, "debriefs": ["<id>", "…"]}
  ],
  "adr_by_area": [
    {"area": "src/ui/", "adr_ids": [], "note": "no ADRs yet — Phase 4 producer not live"}
  ],
  "row_count": 23
}
```

**Graceful degradation:** ADR absence is expected pre-Phase 4. `adr_by_area[].note` flags it; `adr_ids: []` is valid.

**Dimensions:** directory prefix (configurable per project via `memory/config.yaml`), coupling min-count threshold (default 3). Frequency: weekly cron + on-demand.

### 3.3 View: `testing-health`

**Question answered:** "Are we keeping the test surface healthy?" — regression rate per release, flake rate, build/test debt counters over time, Argus-verdict distribution.

**Inputs:**
- Event types: `review_emitted` (verdict), `test_flake_detected` (Phase 3 event), `build_debt_incremented`, `test_debt_incremented`, `release_shipped`.
- Artifact kinds: `review`, `release`, `debrief` (for debt notes).
- Sample query: `SELECT json_extract(body_json, '$.verdict'), count(*) FROM artifacts WHERE kind='review' AND occurred_at BETWEEN ? AND ? GROUP BY 1`.

**Output schema** (`view-testing-health@1.0.0`):

```json
{
  "schema_version": {"name": "view-testing-health", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
  "generated_at": "…",
  "window": {"from": "…", "to": "…"},
  "argus_verdict_distribution": {"approved": 0.70, "flagged": 0.25, "blocked": 0.05, "sample_n": 140},
  "regression_rate_per_release": [
    {"release_id": "<id>", "shipped_at": "…", "regressions_reported_within_7d": 2}
  ],
  "flake_rate": {"overall": 0.03, "trend_last_4_weeks": [0.05, 0.04, 0.03, 0.03]},
  "debt_over_time": [
    {"week_start": "…", "build_debt_count": 4, "test_debt_count": 7}
  ],
  "row_count": 14
}
```

**Dimensions:** weekly buckets, release bucket, all-time cumulative. Frequency: weekly cron + on-demand; triggered on every `release_shipped` event (freshest when the question matters most).

### 3.4 View: `token-cost-budget`

**Question answered:** "Where is token spend going, and where is it leaking?" — per-agent, per-mode spend over time; `mode_budget_exceeded` frequency; cache-hit ratio (once Phase 3 adds the cache fields).

**Inputs:**
- Event types: `agent_session_completed` (tokens + cost_usd per 2.5 §3.12), `mode_budget_exceeded`.
- Phase-3 additive fields: `cache_hit_tokens`, `cache_miss_tokens` — view handles absence gracefully.
- Sample query: `SELECT json_extract(body, '$.producer.agent'), json_extract(body, '$.producer.mode'), sum(json_extract(body, '$.tokens')) FROM events WHERE type='agent_session_completed' GROUP BY 1, 2`.

**Output schema** (`view-token-cost-budget@1.0.0`):

```json
{
  "schema_version": {"name": "view-token-cost-budget", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
  "generated_at": "…",
  "window": {"from": "…", "to": "…"},
  "spend_by_agent_mode": [
    {"agent": "chanakya", "mode": "brief", "tokens": 120000, "cost_usd": 1.20, "session_count": 34, "p50_tokens": 3200, "p90_tokens": 7800}
  ],
  "budget_exceeded_events": [
    {"agent": "chanakya", "mode": "brief-all", "count": 3, "last_at": "…"}
  ],
  "cache_hit_ratio": {"overall": null, "note": "Phase 3 cache fields not live yet"},
  "row_count": 9
}
```

**Dimensions:** agent, mode, weekly buckets. Frequency: weekly cron + on-demand; triggered on every `mode_budget_exceeded` event (freshest when a budget just blew).

## 4. Hybrid synthesis engine

Q25 locked: incremental + periodic rebuild. Two paths, one db.

### 4.1 Incremental path

Hook into existing write primitives. No polling, no daemon.

- `scripts/write-event.sh` (2.6 §11) — after appending to `events/<date>.jsonl`, invokes `scripts/memory-ingest.sh --event <line>`. Upserts one row.
- `scripts/write-artifact.sh` (new, wraps YAML writes under `plans/**`) — after atomic rename of a new artifact, invokes `scripts/memory-ingest.sh --artifact <path>`. Upserts one row + FTS row.
- Slack-ingest modes (`chanakya/modes/ingest-slack.md` etc.) call `memory-ingest.sh --slack <row>` at the same point they write to their own ledger.

Each ingest is a ~5 ms SQLite transaction. Imperceptible at write time; zero RAM between writes.

### 4.2 Periodic rebuild path

`scripts/memory-rebuild.sh` — full rebuild as described in §2.4. Runs:

1. **Post-migration** — after any schema migration under `memory/migrations/` applies.
2. **Weekly cron** (opt-in, Phase 3 schedule) — catches any drift from crashed mid-write, manual edits, or missed hook invocations.
3. **On-demand** — `/chanakya knowledge rebuild`.

A rebuild is ~seconds at this project's scale. Acceptable rarely-blocked op.

### 4.3 Consistency guarantees

- **Monotonic:** FTS row never lags artifact row by more than one transaction. Both upserted in the same `BEGIN...COMMIT`.
- **Eventual for events:** if `write-event.sh` fails mid-hook, the event is on disk but not indexed. Weekly rebuild heals. Acceptable for 2.7.
- **No reader blocks writer:** WAL mode. View regens read a consistent snapshot via `BEGIN DEFERRED`.
- **Schema mismatch on read:** view generator emits `memory_schema_unknown` event, skips the row, continues. Fail-loud-but-don't-halt — one bad row never poisons a view.

## 5. View generation contract

Declared in `_shared/contracts/view-generation.md`. Every view generator conforms:

1. **Single output file.** `views/<view-name>/<date>.json` (or `.yaml` if declared). Atomic rename from tmp.
2. **Declared inputs.** Mode-pack frontmatter lists the SQL queries or kind+event-type combos the view reads. Enables static analysis of breakage on schema bump.
3. **Declared output schema.** File in `_shared/schemas/view-<name>.md` with `schema_version` history table.
4. **Idempotent.** Same substrate state → byte-identical output. No `generated_at` in the checksum region; hash over data fields only.
5. **No side effects.** Zero writes outside `views/<name>/`. No event emission except `view_generated`.
6. **Graceful absence.** Missing producer kinds (ADR, crash pre-Phase 4/5) → `row_count: 0` + a `note` field, never a crash.

### 5.1 Shared primitive — `scripts/run-view.sh`

Thin dispatcher. One entry point for every view:

```
scripts/run-view.sh <view-name> [--window 30d] [--output <path>]
```

Behavior:

1. Look up `<view-name>` in `_shared/schemas/view-manifest.json` (self-versioned, regenerated by pre-commit per capability-manifest pattern from 2.5 §3.10).
2. Exec the declared generator at `scripts/views/<view-name>.sh` with resolved args.
3. Validate output against schema on exit. Refuse to commit output if invalid.
4. Emit `view_generated` event.
5. Exit code: 0 = valid output; 1 = generator error; 2 = validation error.

## 6. Thin renderer layer

`scripts/render-view.sh <view-name> [--date <date>]` — optional, user-driven.

Behavior:

1. Read latest (or named) `views/<view-name>/<date>.json`.
2. Apply a per-view markdown template at `_shared/view-renderers/<view-name>.md.tmpl`. Templates are dumb — table layouts, no computation.
3. Emit to stdout (or `--out`). Not persisted by default.

**Why optional:** view outputs are agent-consumed first. The user skims renderer output only when they care. Keeping the renderer separate means:

- A broken renderer never blocks a view generator.
- Multiple render styles (terminal, HTML, a future Slack post) can consume the same JSON without duplicating logic.
- Token cost of loading a pretty renderer into an agent session is zero — the agent reads JSON directly.

One template per priority view ships in 2.7. Future renderers (HTML, Slack blocks) deferred.

## 7. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: 7 commits.

1. **Commit A — Tier A substrate.** `scripts/memory-ingest.sh` + `scripts/memory-rebuild.sh` + `memory/migrations/001-init.sql` + `resolve_memory_db` in `lib-paths.sh`. Schema + FTS5 table created on first run. Contract doc `contracts/memory-ingest.md`. Unit tests on a fixture artifact tree.
2. **Commit B — ingest hooks.** Wire `memory-ingest.sh --event` into `scripts/write-event.sh`. Wire `--artifact` into a new `scripts/write-artifact.sh` (or into existing writers — whichever is less invasive after 2.6 lands). Slack-ingest modes call `--slack`. Post-2.6-cutover bootstrap ingest runs once here.
3. **Commit C — view contract + dispatcher.** `contracts/view-generation.md` + `scripts/run-view.sh` + `schemas/view-manifest.json` (self-versioned, pre-commit regen). Empty manifest at first — validates the dispatch path without any views yet.
4. **Commit D — view: `workflow-signature`.** Generator + schema + renderer template + unit tests on fixture substrate. First end-to-end view.
5. **Commit E — views: `architecture-overview` + `testing-health`.** Generators + schemas + renderers. Both graceful on missing producers.
6. **Commit F — view: `token-cost-budget`.** Generator + schema + renderer. Hooks into Phase 2.5 `agent_session_completed` events.
7. **Commit G — Chanakya `knowledge` mode + weekly cron hook.** `chanakya/modes/knowledge.md` exposes `/chanakya knowledge view <name>`, `/chanakya knowledge rebuild`, `/chanakya knowledge list`. Opt-in weekly cron stanza added to `scripts/schedule-hooks.md` (lands fully when Phase 3's `/schedule` ships; 2.7 documents the intended config only).

Parallelizable: D ‖ E ‖ F once C merges. G merges last — thin mode-pack wrapper over the primitives from C–F.

## 8. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| FTS5 tokenizer mishandles code-identifier queries | Medium | Low | `porter unicode61` is decent for code-adjacent text. If a real query misses, add `tokenize='porter unicode61 tokenchars=_.'`. Revisit only on concrete miss. |
| Incremental ingest hook misses a write (script crash mid-hook) | Medium | Low | Weekly rebuild heals. `view_generated` event includes substrate checksum; a stale substrate shows up as view drift. |
| SQLite db corrupts on power loss | Low | Medium | WAL mode + `PRAGMA synchronous=NORMAL` survive typical crashes. If corrupt: delete db, rebuild from ledger (~seconds at this scale). |
| View output schema evolves and breaks a downstream agent | Medium | Medium | `schema_version` object per-view + `min_reader` + `deprecated_at`. Same contract as 2.5 Q10. Agents refuse to read unknown schemas (2.6 §8.2). |
| View generator takes >2s on a larger ledger | Low | Low | Profile at first slow run. Indexes on `(kind, occurred_at)` + `(kind, state)` cover the common paths. If still slow, precompute per-view cache tables. |
| Producer absent (crash, ADR) during early 2.7 — views look empty | High | Low | Contract requires `row_count: 0` + `note` on absence. No view is wrong; they're just sparse until Phase 4/5 feed lands. |
| Weekly cron runs concurrent with interactive rebuild | Low | Low | SQLite WAL + `BEGIN IMMEDIATE` in both — one waits for the other. Worst case: one skipped cron (weekly rerun catches up). |
| Slack rows mixed with artifact rows pollute kind-scoped queries | Low | Low | Every query SHOULD filter on `source` explicitly. View contract requires it; reviewer primitive (2.6 Argus) flags queries that don't. |
| Renderer template drifts from JSON schema | Medium | Low | Renderers are optional; a broken renderer doesn't break anything real. Warn tier in REVIEW.md, not block. |

## 9. Post-2.7 freeze rules

When Commit G merges:

- Tier A schema under `memory/artifacts.db` is **frozen at `v1.0.0`** — additions via migrations only, never ad-hoc column adds. Migration file numbered + applied in order.
- View output JSON shapes are **frozen per `schema_version`** — breaking changes bump major, new fields bump minor, always with `min_reader` + `deprecated_at` per 2.5 Q10.
- Every new view ships with: generator, schema spec under `_shared/schemas/view-<name>.md`, renderer template, manifest entry. No view ships without all four — pre-commit lint enforces.
- Direct `sqlite3` opens of `artifacts.db` outside `scripts/memory-*.sh` and `scripts/run-view.sh` are a lint block. One path in, one path out.

## 10. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **The other seven views.** Opt-in / later:
  - `feature-catalog` — what features exist, where they live. Needs ADRs (Phase 4) to be non-trivial.
  - `crash-detection` — crash-to-fix-to-release chain. Needs Phase 5 crash feed.
  - `performance-trend` — build time, test time, cold-start metrics. Needs Phase 5 instrumentation.
  - `user-feedback-theme-map` — cluster feedback by theme. Needs Slack-ingest volume + possibly a small embedding step (non-local-LLM alternative: FTS5 `snippet()` + manual thematic tags).
  - `decision-journal` — chronological ADR + debrief-decision timeline. Needs Phase 4 ADR producer.
  - `release-changelog-for-humans` — release-notes renderer from release artifacts + linked tasks. Deferred until the rendering style matters to a real audience.
  - `regression-correlation` — ties regressions back to the debrief that shipped them. Valuable but needs more signal than 2.7 has.
- **Agent consumers of views.** Chanakya brief mode reading `architecture-overview` for Step-0 context; Lu Ban (Phase 4) catalog lookup via `feature-catalog`; Argus reading `testing-health` to tune verdicts. Primary consumers in 2.7 are the generators themselves + the user via renderer.
- **Real-time view refresh.** Explicitly out of scope. Views are batch artifacts with sub-second staleness tolerance.
- **Decision-journal structure.** Deferred until Phase 4 ADRs exist — shape of the journal depends on ADR shape.
- **Cost-aware query throttling.** Only relevant if db grows past ~100 MB — at that point, per-view cached tables + query budget. Revisit on concrete growth. At this project's scale, expect <5 MB indefinitely.
- **Cross-project rollup.** Tier-2 per-project db by design. A future "compare projects" view would be a tier-3-sync + merge pattern, orthogonal to 2.7.
- **Embedding-based similarity.** Intentionally excluded. FTS5 covers the real needs; embeddings would require a local model or a paid API — both violate §0 standards.

## 11. Notes from initial drafting

- SQLite ships with macOS; FTS5 is compiled in. Zero install cost. The `sqlite3` binary at `/usr/bin/sqlite3` is already in the user's path.
- `events/YYYY-MM-DD.jsonl` (2.6 canonical) is a clean ingest source — one line per event, typed, schema-versioned. Ingest cost is trivial.
- The four priority views were chosen to cover: **how we work** (workflow-signature), **what we work on** (architecture-overview), **what we ship** (testing-health), **what it costs us** (token-cost-budget). Each is a distinct lens; together they characterize the project at a session-open glance.
- Renderer layer exists mostly for one user (the user) to skim. Keeping it thin avoids the trap of building a dashboard product.
