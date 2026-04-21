# Phase 3 Execution Plan (draft)

Drafted 2026-04-20 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q20–Q23, Q39–Q41 are each marked locked; no open rows in the decisions table.

Phase 3 is the lightest plan in the sequence because the heavy design lives in 2.6 (structured ledger) and 2.7 (views). Phase 3 ships **three thin mechanisms** plus the glue between them (amended 2026-04-22 — scope expanded from two to three per issue [#65](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/65)):

1. **Prompt-caching instrumentation** — per-session cache-hit telemetry on the existing `agent_session_completed` event, plus `cache_control` breakpoints at mode-pack preamble boundaries. Delivered by 2.6's preamble split (Q39); 2.7's `token-consumption` view (renamed from `token-cost-budget` 2026-04-22) is the primary reader.
2. **Schedule-driven automation** — a scheduler mechanism (config file + cron dispatcher) that ships with **zero entries enabled by default**. Automation lights up case-by-case through a detect → suggest → user-approve → enable flow over 2.7's `workflow-signature` view.
3. **Task-level model recommendation** (issue #65, added 2026-04-22) — a deterministic rule function maps `(size, kind, cross_file_count, novelty_score) → {best_result_model, fast_turnaround_model}`. Briefs carry a `recommended_models: {...}` field; `agent_session_completed` gains `model_selected` + `model_fallback_reason` so telemetry feeds back into calibration. A `/chanakya model-refresh` mode + monthly scheduler reminder keeps the model catalog current.

A weekly-narrative generator rides on top of the same primitives as a first consumer.

See `ROADMAP.md` §Phase sequence, `PHASE-2-5-PLAN.md` / `PHASE-2-6-PLAN.md` / `PHASE-2-7-PLAN.md` for upstream contracts. Gated by 2.6 (preamble split + canonical event log) and 2.7 (`workflow-signature` + `token-cost-budget` views). Parallelizable with Phase 4.

## 0. Standards and non-negotiables

Unchanged from 2.5/2.6/2.7 §0, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale, not fit-for-enterprise.** Single-user workflow tool. Phase 3 specifically must stay **light at idle** (cron entry invokes a dispatcher; no daemon, no phone-home, no paid service) and **minimal at runtime** (caching is additive fields on an existing event; scheduler is a ~100-line shell dispatcher).
- **Agent-first design.** Cache telemetry is a machine-readable field pair on an already-machine-readable event. Scheduler config is YAML, human-auditable. No interactive prompts in any scheduled task.
- **Three-tier artifact paths.** Scheduler config + narrative outputs live in tier 2 (`~/.dev-studio/<project>/`). No tier-3 writes. All writes resolve via `scripts/lib-paths.sh` — never hardcode paths.
- **Minimal permission footprint.** macOS cron entry lands once during `install.sh`; user is told exactly what it runs. No new Bash command patterns in the allowlist beyond what `scripts/` already uses.
- **Additive telemetry only.** Event payloads never rename or remove fields. Phase 3 adds **exactly two** cache fields to `agent_session_completed` — that ceiling is a discipline guardrail (§2).
- **Automation is opt-in.** The scheduler never runs a task the user didn't approve. Config file is authoritative. No hidden auto-scheduling, no nag-loop, no daemon.

## 1. Decisions table — all locked

| # | Decision | Resolution |
|---|---|---|
| Q20 | Cache-hit telemetry shape | Lightweight: extend existing `agent_session_completed` event with `cache_read_tokens` + `cache_creation_tokens` pulled from the Anthropic API response. No new file, no new pipeline, no new directory. Readers compute cache-hit ratio on demand by filtering the event log. |
| Q21 | Stable-prefix cache strategy | Router + invariant mode-pack preambles. Each mode pack has a cacheable preamble section (identical per session) and a task-specific section (varies per call). Anthropic `cache_control` breakpoint sits at the preamble boundary. |
| Q22 | Schedule-driven automation default | Ship the mechanism; schedule **nothing** by default. Ramp up case-by-case based on detected patterns + user approval. |
| Q23 | Weekly narrative publish target | Private tier-2 file `~/.dev-studio/<project>/narrative/YYYY-Wnn.md`. No public publishing yet — deferred until content quality proven (§10). |
| Q39 | Where preamble split lands | In Phase 2.6 alongside mode-pack rewrites. Phase 3 assumes the structural split is done and wires `cache_control` on top. |
| Q40 | First-opt-in flow | **Detect → suggest → user-approve → enable.** System detects repeated manual patterns via the 2.7 `workflow-signature` view; surfaces opportunities via `/chanakya suggest-automations`; user replies `yes now` / `yes schedule <cron>` / `no`; cron-wrapper adds the entry or runs immediately. User is responsible for keeping the machine on during scheduled windows — no daemon, no phone-home reliability. |
| Q41 | Default views feeding narrative | `workflow-signature`, `testing-health`, `token-consumption` (renamed from `token-cost-budget` 2026-04-22 per Max-plan reframe), `regression-correlation` (promoted to priority 2026-04-22; gated on "data available" check per 2.7 §3.5 so it no-ops cleanly pre-Phase-5). Phase 5 adds release + crash highlights once those feeds exist. Other views toggleable via `narrative/config.yaml`. |
| Q65 | Task-level model recommendation (folded from issue [#65](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/65) 2026-04-22) | Deterministic rule function, not an ML classifier. Inputs: `size`, `kind`, `cross_file_count`, `novelty_score`. Outputs: `{best_result, fast_turnaround}` model choices. Rule lives in `_shared/rules/model-recommendation.md`; user default preference in `_shared/rules/model-policy.yaml`; hand-editable model roster in `_shared/schemas/model-catalog.yaml`. Semi-automatic catalog update via `/chanakya model-refresh` — Claude reports what it knows, user confirms, YAML updates. Brief YAML gains `recommended_models` field; `agent_session_completed` gains `model_selected` + `model_fallback_reason`. Monthly `model-refresh` reminder added via Phase 3's scheduler once that mechanism lands. |

## 2. Cache-hit telemetry

Two additive fields on `agent_session_completed`. That's the entire instrumentation surface.

### 2.1 Event-payload additions

`agent_session_completed` schema bumps minor: `v1.0.0 → v1.1.0` (additive, `min_reader` stays at `1.0.0`). New fields:

| Field | Type | Source | Notes |
|---|---|---|---|
| `cache_read_tokens` | integer ≥ 0 | Anthropic API `usage.cache_read_input_tokens` | Tokens served from cache on this turn. Zero if no cache hit. |
| `cache_creation_tokens` | integer ≥ 0 | Anthropic API `usage.cache_creation_input_tokens` | Tokens the turn *wrote into* cache. Non-zero only on cache-miss turns that create an ephemeral entry. |

No new file. No new event type. No new directory. This is the whole Phase 3 telemetry surface — and by design it's the ceiling. Adding a third cache field requires an explicit plan amendment (discipline guardrail per §0).

### 2.2 Sample event

```json
{
  "type": "agent_session_completed",
  "schema_version": {"name": "agent_session_completed", "version": "1.1.0", "min_reader": "1.0.0", "deprecated_at": null},
  "occurred_at": "2026-04-20T14:32:10Z",
  "producer": {"agent": "chanakya", "mode": "brief", "instance_id": "…"},
  "idempotency_key": "…",
  "session_id": "…",
  "tokens": 7420,
  "cache_read_tokens": 5800,
  "cache_creation_tokens": 0,
  "duration_ms": 12430
}
```

Cache-hit ratio for this turn: `cache_read_tokens / (cache_read_tokens + (tokens - cache_read_tokens))` = 5800 / 7420 ≈ 0.78. Readers compute this inline; no stored ratio field. No `cost_usd` field — user is on the Claude Max plan; token consumption is the honest unit. Historical events that carried `cost_usd` remain parseable but the value is ignored by post-2026-04-22 views.

### 2.3 Reader queries (shapes only — real queries live in 2.7 views)

```sql
-- Cache-hit ratio this week, by agent + mode
SELECT
  json_extract(body, '$.producer.agent')  AS agent,
  json_extract(body, '$.producer.mode')   AS mode,
  sum(json_extract(body, '$.cache_read_tokens')) * 1.0
    / nullif(sum(json_extract(body, '$.tokens')), 0) AS hit_ratio,
  count(*) AS sessions
FROM events
WHERE type = 'agent_session_completed'
  AND occurred_at >= date('now', '-7 days')
GROUP BY 1, 2
ORDER BY hit_ratio DESC;
```

```sql
-- Cache amplification this week — how many input tokens the cache saved us from re-sending
SELECT
  sum(json_extract(body, '$.cache_read_tokens')) AS cache_read_tokens_total,
  sum(json_extract(body, '$.tokens')) AS tokens_total,
  round(
    sum(json_extract(body, '$.cache_read_tokens')) * 1.0
    / nullif(sum(json_extract(body, '$.tokens')), 0),
    3
  ) AS cache_amplification_ratio
FROM events
WHERE type = 'agent_session_completed'
  AND occurred_at >= date('now', '-7 days');
```

Both queries become first-class in the 2.7 `token-consumption` view (renamed from `token-cost-budget` 2026-04-22 per Max-plan reframe) once this plan lands — the view already has a `cache_hit_ratio` slot that's null pre-Phase-3.

## 3. Stable-prefix cache implementation

### 3.1 Where the breakpoint sits

Every mode pack post-2.6 is structurally split:

```
modes/<mode>.md
  ── preamble ───────────────── (identical per session — role, envelope, router references)
  ── <cache_control breakpoint> ──────────────
  ── task-specific section ───── (varies per call — args, recent context)
```

The `cache_control: {type: "ephemeral"}` breakpoint is set on the **last block of the preamble**. Anthropic caches everything up to and including that block; the task-specific section below is uncached and varies per call.

Breakpoint placement is one line in the request-builder primitive (2.5) — not per-mode config. Primitive:

- Loads the mode pack.
- Splits at the preamble marker (`<!-- cache-breakpoint -->` HTML comment introduced in 2.6 §Q39).
- Emits the two content blocks with `cache_control` on the first.

No mode pack carries API-specific wiring in prose. If Anthropic changes the cache-control shape, we change one primitive.

### 3.2 TTL + ephemeral semantics (notes for future maintainers)

- Anthropic's ephemeral cache TTL is 5 minutes from last use. Sessions within 5 minutes of each other that share a preamble hit cache; longer gaps miss and re-create.
- Cache is scoped per prefix hash. Any change above the breakpoint — even whitespace — invalidates. The preamble is **deliberately invariant**; editing it bumps the mode-pack semver (2.6 contract) and is expected to cost one cache miss per mode per 5-min window.
- Phase 3 does not attempt cache-pressure eviction or multi-breakpoint strategies. If the single breakpoint proves insufficient (e.g. two tiers of shared context across mode packs), revisit in Phase 5+ (§10).

### 3.3 Dependency on 2.6 preamble split

Phase 3 assumes every mode pack has the `<!-- cache-breakpoint -->` marker. If 2.6 ships without the split, Phase 3 `cache_control` wiring is a no-op (breakpoint at position 0 = nothing cached). 2.6 Commit checklist must include a lint step asserting every mode pack has exactly one marker; that lint lands in 2.6, not 3.

## 4. Scheduler mechanism

### 4.1 Layout

```
scripts/scheduler/
  install.sh          # installs macOS cron entry (once; idempotent)
  uninstall.sh        # removes the cron entry
  dispatch.sh         # the ONLY command cron invokes; reads config + runs due tasks
  README.md           # short — what it is, how to approve new tasks, how to audit
```

Config lives at `~/.dev-studio/<project>/scheduler.yaml` (tier-2, per-project, resolved via `scripts/lib-paths.sh::resolve_scheduler_config`).

### 4.2 Config shape

```yaml
schema_version: {name: scheduler-config, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
tasks:
  - id: weekly-narrative
    cron: "0 9 * * MON"             # Monday 09:00 local
    command: "scripts/narrative/generate-weekly.sh"
    approved_at: 2026-04-21T10:14:00Z
    approved_via: "/chanakya suggest-automations"
    snoozed_until: null             # RFC3339 or null
```

Fields:

| Field | Purpose |
|---|---|
| `id` | Stable identifier; dispatcher dedupes by this. |
| `cron` | Standard 5-field cron expression. macOS cron syntax. |
| `command` | Path relative to repo root. Must resolve under `scripts/`. |
| `approved_at` | When the user said yes. Required; missing = not approved = dispatcher skips. |
| `approved_via` | How they approved — auditability. |
| `snoozed_until` | Optional pause without full removal. Dispatcher respects. |

No entry in `tasks[]` at install time. Zero default automations.

### 4.3 `install.sh`

Idempotent:

1. Resolve the dispatcher absolute path via `lib-paths.sh`.
2. Read current `crontab -l` (or empty if none).
3. If the dispatcher entry is already present, exit 0 with a note.
4. Otherwise append a single line: `* * * * * <dispatcher-abs-path> >> <log-path> 2>&1` (runs every minute; dispatcher itself decides whether anything is due).
5. `crontab -` the new content.
6. Print the exact line installed so the user can audit.

**Why every-minute wrap, not per-task cron entries:** one cron line the user can see and reason about. Per-task lines sprawl. The dispatcher does the routing; cron just wakes it up.

### 4.4 `dispatch.sh`

~80 lines. Behavior:

1. Resolve scheduler config path. If missing → exit 0 silently.
2. Parse `tasks[]`. For each task with `approved_at` set and `snoozed_until` null or in the past:
   - Compute whether the cron expression fires within the current minute window.
   - If yes: fork the command. Redirect stdout+stderr to `~/.dev-studio/<project>/scheduler/logs/<task-id>-<date>.log`.
   - Emit `scheduled_task_ran` event with `{task_id, command, exit_code, duration_ms}`.
3. Never blocks; longer tasks fork and detach.
4. On any parse error, emit `scheduler_config_invalid` warn event + exit 0. Bad config never silently re-runs cron; it fails loud in the event log.

### 4.5 Why macOS cron (not `launchd`, not a daemon)

- Zero-install: cron is on every Mac.
- User-visible: `crontab -l` shows exactly one line.
- No daemon means no restart discipline; user is responsible for the machine being on during scheduled windows. Explicit per Q40.
- `launchd` would be more robust but adds a plist, surface area, and a second concept the user has to audit. Not worth it at single-user scale.

## 5. Opportunity detection + suggestion flow (`/chanakya suggest-automations`)

### 5.1 New Chanakya sub-command

`chanakya/modes/suggest-automations.md` — new mode pack, ~120 lines. Invocation: `/chanakya suggest-automations`. Also surfaces inline during `/chanakya status` **at most once per status invocation** (§5.4 — no nagging).

### 5.2 Detection algorithm

Reads the 2.7 `workflow-signature` view's underlying SQL (not the rendered JSON — the substrate). Detects:

1. **Manual-invocation patterns.** A command (`/chanakya compact`, `/luban design`, a specific brief sweep) run ≥ 4 times within a rolling 30-day window where the times cluster (same weekday ± 1h, or same day-of-month ± 2 days).
2. **View-regen patterns.** A view the user manually re-runs ≥ 3 times in 14 days on the same cadence.
3. **Narrative-worthy cadence.** Weekly narrative opportunity surfaces once the project has ≥ 3 weeks of event-log history.

Detection runs each `/chanakya status` on read — cheap SQL against the 2.7 substrate, no persisted state.

### 5.3 Ranking

Suggestions are ranked by **(frequency × estimated-time-saved)** descending:

- `frequency` = count of manual invocations in the detection window.
- `estimated_time_saved` = median duration of the matching `agent_session_completed` events for that command.

Top 3 surface; the rest are held back. High-frequency but low-duration commands (like `/chanakya status` itself) are filtered — auto-scheduling a status ping would be noise.

### 5.4 Suggestion flow

1. `/chanakya suggest-automations` prints ranked suggestions:

   ```
   Candidates for automation:

   1. /chanakya compact — run 4 Sundays in a row at ~20:00. ~6 min/run. [yes now | yes schedule <cron> | no | snooze 14d]
   2. scripts/narrative/generate-weekly.sh — 3 weeks of history accumulated. [yes schedule "0 9 * * MON" | no | snooze 30d]
   ```

2. User replies inline. Chanakya parses the response:
   - `yes now` → runs immediately, no schedule addition.
   - `yes schedule <cron>` → appends to `scheduler.yaml` with `approved_at: <now>` + `approved_via: "/chanakya suggest-automations"`.
   - `no` → suppressed for this session; re-surfaces next run unless snoozed.
   - `snooze <duration>` → sets `snoozed_until: <now + duration>` on the suggestion's stable-id (not on a task — the task may not exist yet).
3. Emits `automation_suggested` / `automation_approved` / `automation_snoozed` / `automation_rejected` events for the 2.7 substrate to consume later.

### 5.5 Discipline: no nagging

- At most one suggestion surfaces per `/chanakya status`. The other two wait.
- A rejected suggestion is suppressed for 14 days by default; a snoozed one for the user-specified duration.
- Zero auto-run. The config file is authoritative and human-auditable — the user can `cat scheduler.yaml` and see every scheduled task.

## 6. Weekly narrative generator

### 6.1 `scripts/narrative/generate-weekly.sh`

Not enabled by default. Becomes a scheduled task only through §5's approval flow.

Behavior:

1. Resolve the week window — ISO week number, local timezone. `--week <YYYY-Wnn>` overrides.
2. Read the four default-enabled views (2.7 priority set, amended 2026-04-22) from `~/.dev-studio/<project>/views/`:
   - `workflow-signature/<date>.json`
   - `testing-health/<date>.json`
   - `token-consumption/<date>.json` (renamed from `token-cost-budget`)
   - `regression-correlation/<date>.json` (data-availability gated — §3.5 of PHASE-2-7-PLAN; emits a `"regression sources not live yet"` note pre-Phase-5)
3. Compose a markdown narrative per `_shared/narrative-templates/weekly.md.tmpl` (ships in Commit E). Regression-correlation section renders an "insufficient data" banner when the view reports `data_sources_live: []`.
4. Atomic-rename into `~/.dev-studio/<project>/narrative/YYYY-Wnn.md`.
5. Emit `narrative_generated` event `{week, views_consumed, output_path, overwrote_prior: bool}`.

### 6.2 Idempotence

Re-running for the same week overwrites the output. Same inputs → byte-identical body (no `generated_at` in the hashed region). Regenerating after the week's views refresh is the intended use: the narrative reflects the most current substrate.

### 6.3 Config file

`~/.dev-studio/<project>/narrative/config.yaml` lets the user toggle which views feed the narrative. Defaults to the four Q41 views (amended 2026-04-22):

```yaml
schema_version: {name: narrative-config, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
views:
  workflow-signature: true
  testing-health: true
  token-consumption: true
  regression-correlation: true
  # Toggle others on once they produce signal:
  architecture-overview: false
  recent-utilities: false    # typically a plan-phase primitive, not a weekly lens
```

### 6.4 Publication surface

None. Narrative is private-local (tier-2), read by the user directly or surfaced inline by `/chanakya status` when freshly generated. Phase 5+ may add a private-published surface (§10); public publishing stays deferred.

## 6B. Task-level model recommendation (issue #65 — added 2026-04-22)

Deterministic rule, not a classifier. Inputs come from signals already on the brief; outputs are two model picks the user can override.

### 6B.1 Inputs + outputs

**Inputs (all already on the brief post-Phase-2.6):**

| Input | Source | Notes |
|---|---|---|
| `size` | `brief.size` (`xs\|s\|m\|l`) | Direct. |
| `kind` | `brief.kind` (`feature\|fix\|refactor\|debrief\|crash-fix`) | Phase 2.6 brief schema. |
| `cross_file_count` | Chanakya's scan step during brief generation | Integer count of files likely touched. |
| `novelty_score` | Phase 7 `score-novelty.sh` output | `[0, 1]` — only populated if Phase 7 has landed; absent → treated as 0. |

**Outputs:**

```yaml
recommended_models:
  best_result: claude-opus-4-7           # model id from model-catalog
  fast_turnaround: claude-sonnet-4-6     # cheaper model for tight loops
  rule_version: 1                        # bump when rule file changes
  reason: "size=l + novelty=0.72 → best_result=opus; size=l → fast_turnaround=sonnet"
```

### 6B.2 Rule function (`_shared/rules/model-recommendation.md`)

Human-readable rules, no DSL. Achilles + Chanakya evaluate the rules at brief-write time. Example (v1 — tune empirically):

```
Let best_result = (default from policy).
Let fast_turnaround = (default from policy).

If size == "l":
  best_result = policy.models.heavyweight
  fast_turnaround = policy.models.midweight

If size == "m" AND (cross_file_count >= 3 OR novelty_score >= 0.5):
  best_result = policy.models.heavyweight

If kind == "crash-fix" OR kind == "refactor":
  best_result = policy.models.heavyweight  # never downgrade
```

Rule file is the single source of truth. Agents parse it via `scripts/model-recommendation.sh` (~50 lines bash) at brief emit; no runtime DSL interpreter.

### 6B.3 Model policy (`_shared/rules/model-policy.yaml`)

```yaml
schema_version: {name: model-policy, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
defaults:
  heavyweight: claude-opus-4-7            # best-result default
  midweight: claude-sonnet-4-6            # fast-turnaround default
  lightweight: claude-haiku-4-5           # sweep / status / orchestration
user_overrides:
  chanakya: {}                            # empty = inherit from defaults
  achilles: {}
  argus: {}
```

### 6B.4 Model catalog (`_shared/schemas/model-catalog.yaml`)

Hand-editable — the user is authoritative. `/chanakya model-refresh` (§6B.6) assists but never auto-commits.

```yaml
schema_version: {name: model-catalog, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
models:
  - id: claude-opus-4-7
    family: opus
    tier: heavyweight
    context_window: 200000
    notes: "Latest Opus. Primary choice for code generation + reasoning-heavy review."
    retired: false
  - id: claude-sonnet-4-6
    family: sonnet
    tier: midweight
    context_window: 200000
    notes: "Fast turnaround, good code quality, lower consumption than Opus."
    retired: false
  - id: claude-haiku-4-5
    family: haiku
    tier: lightweight
    context_window: 200000
    notes: "Sweeps, orchestration, event processing. Not for code generation."
    retired: false
```

### 6B.5 Brief + event additions

**Brief schema minor bump:** adds `recommended_models: {best_result, fast_turnaround, rule_version, reason}`. Additive — old briefs parse fine with null.

**`agent_session_completed` adds two fields (separate from the cache-telemetry pair in §2.1 — they share a minor bump but the cache fields and model fields are independent): `model_selected` (id from catalog) + `model_fallback_reason` (null if selected == recommended, else a short string like `"recommendation unavailable"`, `"user override"`, `"rate limit"`).**

Together with the cache fields, `agent_session_completed` goes `v1.0.0 → v1.2.0` in Phase 3 (two minor bumps in one phase for fields captured from the same source are fine — no consumer breakage). Schema spec gets a single update in Commit A covering all four new fields.

### 6B.6 `/chanakya model-refresh` mode

New mode pack `chanakya/modes/model-refresh.md`, ~80 lines. Invocation: `/chanakya model-refresh`.

Flow:
1. Claude reads the current `model-catalog.yaml`.
2. Reports what it knows about the listed models (e.g. "claude-opus-4-6 retired 2026-02-15; successor is claude-opus-4-7"), plus any models it knows of that aren't listed.
3. User confirms each proposed edit inline. Confirmed edits become a structured diff against the YAML.
4. Chanakya writes the diff atomically; emits `model_catalog_refreshed` event `{added: [...], retired: [...], edited_by: user}`.
5. Rule-version remains unchanged; only the catalog updates.

**Why semi-automatic:** the user is the only one who can validate model-knowledge claims against their Anthropic account / real usage. Auto-updating the catalog from Claude's training-data model roster would bake in stale info permanently.

### 6B.7 Scheduler reminder

When the Phase 3 scheduler lands (§4), `/chanakya suggest-automations` surfaces a monthly `model-refresh` reminder as an opt-in task:

```
Candidate: /chanakya model-refresh — monthly
Last refresh: 2026-03-22 (31 days ago)
Last catalog update discovered: 2 models retired, 1 added
[yes schedule "0 9 1 * *" | no | snooze 30d]
```

Reminder doesn't auto-execute; user always confirms.

## 7. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: **7 commits** (amended 2026-04-22 — up from 6, adding the model-recommendation Commit G).

1. **Commit A — cache-telemetry event fields + model-session fields.** Bump `agent_session_completed@1.0.0 → 1.2.0`. Schema spec under `_shared/schemas/events/agent_session_completed.md` gains the four additive fields (`cache_read_tokens`, `cache_creation_tokens`, `model_selected`, `model_fallback_reason`). Request-builder primitive captures the two cache values from the Anthropic response + records the model chosen. Unit test on fixture response. No consumer changes — the 2.7 `token-consumption` view already reads the fields (null pre-rollout).
2. **Commit B — `cache_control` wiring.** Primitive sets `cache_control: {type: "ephemeral"}` at the `<!-- cache-breakpoint -->` marker in every mode pack. Asserts the marker exists (lint from 2.6). Smoke test against a single Chanakya mode: two back-to-back invocations within 5 min → second emits a non-zero `cache_read_tokens`.
3. **Commit C — scheduler scaffold.** `scripts/scheduler/{install,uninstall,dispatch}.sh` + `scheduler.yaml` schema under `_shared/schemas/scheduler-config.md` + `resolve_scheduler_config` in `lib-paths.sh`. `tasks: []` by default. Unit test: install.sh is idempotent; dispatch.sh with empty config exits 0 silently; dispatch.sh with one approved task fires the command at the right minute.
4. **Commit D — suggestion flow.** `chanakya/modes/suggest-automations.md` + detection queries over the 2.7 substrate + `automation_*` events. Hook into `/chanakya status` for the once-per-invocation surface. Unit tests on the ranking function + the reply parser. Monthly `model-refresh` reminder lands in the candidate set (gated on Commit G having merged).
5. **Commit E — weekly narrative generator.** `scripts/narrative/generate-weekly.sh` + `_shared/narrative-templates/weekly.md.tmpl` + `narrative/config.yaml` defaults (four views, incl. `regression-correlation` gated on data availability). Idempotence test: two runs on the same week → byte-identical output. Not auto-scheduled — approval lands via §5.
6. **Commit F — docs sync (caching + scheduler + narrative).** `chanakya/docs.html` adds a "Suggest automations" card + a "Scheduler" card under Fleet. `README.md` TL;DR gains one line under Chanakya and one under scripts. `chanakya/README.md` walkthrough touches the approval flow. Open docs.html in Safari per CLAUDE.md routine.
7. **Commit G — model-recommendation system** (§6B, issue [#65](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/65)). `_shared/rules/model-recommendation.md` + `_shared/rules/model-policy.yaml` + `_shared/schemas/model-catalog.yaml`. `scripts/model-recommendation.sh` (parser + lookup). Brief schema minor bump adds `recommended_models`. `chanakya/modes/model-refresh.md` mode pack + docs-sync row for `/chanakya model-refresh`. Unit tests on 12 rule-evaluation fixtures + catalog-refresh diff handler. No ML, no classifier.

Parallelizable: A ‖ B (both primitive-level, different files). D ‖ E once C merges. G merges after A (needs the session-event schema bump) but is otherwise independent — can land in parallel with C/D/E/F.

## 8. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Anthropic response shape drifts and cache fields vanish | Low | Low | Primitive pulls via nullable-safe lookup (`usage.cache_read_input_tokens ?? 0`). Field absence emits zeros, not a crash. |
| Preamble split in 2.6 misses a mode pack → cache breakpoint at position 0 → nothing cached | Medium | Low | 2.6 lint asserts one marker per mode pack. Phase 3 smoke test catches any remaining gap — zero `cache_read_tokens` across a week is a detection trigger (surfaced via `token-cost-budget`). |
| User's machine is off when a scheduled task fires → task silently skipped | High | Low | Documented explicitly in scheduler README and §0. No daemon, no catch-up run. Dispatcher runs on next cron tick once machine is back. `scheduled_task_ran` event cadence makes skips visible in the event log. |
| Suggestion engine over-surfaces → feels naggy | Medium | Medium | Once-per-status cap + 14-day rejection suppression + snooze. Monitor `automation_rejected` rate in `workflow-signature`; tighten ranker if > 50% rejection over 30 days. |
| `scheduler.yaml` hand-edited into invalid YAML | Low | Low | `dispatch.sh` parse failure emits `scheduler_config_invalid` warn event + exit 0. Never silently re-runs the last-known-good config — user sees the fault in the log. |
| Cache TTL + busy mode-pack editing → chronic cache misses | Low | Low | Mode-pack semver (2.6) discourages drive-by edits. If still noisy, revisit breakpoint placement in Phase 5+. |
| Weekly narrative regen runs on incomplete view output | Low | Low | Narrative generator reads latest `<date>.json` in each view dir. If a view hasn't regenerated this week, the narrative notes "view last regenerated <date>" inline. |
| User approves a task whose command path no longer exists after a refactor | Low | Medium | Dispatcher pre-flights `command` with `[ -x "$path" ]`; missing → emits `scheduled_task_missing_command` warn event, skips. |

## 9. Post-Phase-3 freeze rules

When Commit F merges:

- **Cache fields on `agent_session_completed` are frozen at 2 (`cache_read_tokens` + `cache_creation_tokens`).** Adding a third requires an explicit plan amendment — the 2-field ceiling is load-bearing discipline. The two model fields (`model_selected`, `model_fallback_reason`) are a separate additive pair on the same event, frozen independently — raising either ceiling requires plan amendment.
- **Model-recommendation rule file is the single source of truth.** Agents never hard-code model choices. Rule-version bump captured by `rule_version` on each brief's `recommended_models` block.
- **Model catalog is user-authoritative.** `/chanakya model-refresh` proposes edits; only user confirmation commits them.
- **`cache_control` breakpoint placement is frozen at one per mode pack**, at the `<!-- cache-breakpoint -->` marker. Multi-breakpoint strategies revisit in Phase 5+ only if concrete pressure surfaces.
- **`scheduler.yaml` is authoritative.** No parallel schedule source. No auto-populated entries — every task lands via §5 approval. Hand-edits allowed (audit-friendly); invalid YAML surfaces loud.
- **The scheduler never runs an unapproved command.** `approved_at: null` = dispatcher skips. This is the non-negotiable trust contract.
- **Narrative output path is private (tier-2).** Any public publishing surface requires a new plan phase — Phase 3 closes the door deliberately.

## 10. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **Public narrative publishing.** Slack digest, committed summary, email — all deferred until content quality proven over ≥ 8 weeks of local-only reading.
- **Richer cache telemetry.** Per-breakpoint hit-ratio, cache-prefix hash debugging, cross-session cache-lifetime histograms. Only build when a real question surfaces the 2-field view can't answer.
- **Auto-schedule without user approval.** Probably never — the trust model depends on authoritative config. Revisit only if adaptive-trust data (CLAUDE.md §Auto-apply tiers) shows zero reverts over many cycles *and* the user explicitly asks.
- **Cache-pressure eviction strategy.** Relevant only if Anthropic adds explicit eviction controls or we hit the 4-breakpoint cap on a mode pack. Not an issue at this scale.
- **Per-mode budget feedback loop.** Reading `token-cost-budget` view → automatically tightening mode token budgets → suggesting prose trims. Interesting but depends on ≥ 30 days of post-Phase-3 data to avoid noise-tuning.
- **`launchd` migration.** If cron becomes a pain (macOS deprecations, permission friction), migrate to a single `launchd` plist. Today's pain level: zero.
- **Narrative archive view.** A 2.7-style view that reads all weekly narratives + surfaces trend lines. Needs ≥ 12 weeks of narratives first.
- **Cross-machine scheduler.** Mac mini running a different subset of scheduled tasks. Blocks on Phase 4's `target_machine` routing + tier-3 sync. Not Phase 3's problem.

## 11. Notes from initial drafting

- Phase 3 earns its place by **shipping mechanism without behavior**. The scheduler does nothing by default; the cache instrumentation adds two fields. Behavior lights up through user approval. This is the smallest diff that unblocks Phase 5's richer automation.
- The `(frequency × time-saved)` ranker is intentionally simple. If it surfaces bad candidates, the fix is in ranking data — not a second ranker. Keep one dimension; add weights only if the 30-day rejection rate stays high.
- The 2-field cache-telemetry ceiling is a **design brake**, not a technical limit. Without it, this file grows into observability sprawl. Phase 5 can raise it explicitly if a real question demands more.
- No new linter codes land in Phase 3. (The right-sizing rule says earn-your-place or skip — Phase 3 has no new invariant worth enforcing ahead of real data.)
