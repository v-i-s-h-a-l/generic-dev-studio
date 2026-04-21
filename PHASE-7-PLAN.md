# Phase 7 Execution Plan (draft)

Drafted 2026-04-21 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q51–Q53 locked from user biases stated in resume context (2026-04-21 session start); flagged inline for explicit OK before execution. Deferred items in §13 have a recommended default in **bold** where the user will still want to weigh in.

Phase 7 introduces **cross-agent routing intelligence**. The principle: *always suggestion, never hard routing*. Chanakya's intake pipeline gains a **novelty heuristic** that proposes Lu Ban handoff when the work doesn't match an existing architectural pattern. Achilles debriefs gain a structured **`architectural_concerns[]`** field that captures smells-in-passing — circular deps, unexpected abstractions, catalog deviations — which Chanakya aggregates into suggestions. Both surfaces (Chanakya status + dashboard Now view) display suggestions non-blockingly; the user decides whether to act.

See `ROADMAP.md` §Phase sequence, `PHASE-4-PLAN.md` for Lu Ban contracts, `PHASE-2-7-PLAN.md` for the FTS5 substrate novelty queries ride on, `PHASE-6-PLAN.md` §4.1 for the dashboard Now view the new "Suggestions" section plugs into. Gated by 2.6 (YAML ledger + debrief schema) and 2.7 (FTS5 for catalog-absence queries). Parallelizable with Phase 6 after 2.7 lands.

## 0. Standards and non-negotiables

Unchanged from 2.5 onward, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale.** Single-user iOS workflow tool. Phase 7 adds *suggestion-only* signals, not an automated router. No ML classifier. No training loop. No runtime cost (scoring is bash + SQL over an already-warm FTS5). Suggestions are cheap to ignore — user's day is not interrupted by a proposal.
- **Agent-first design.** Suggestions are structured YAML (`plans/suggestions/<id>.yaml`), surfaced through existing display paths. No new interactive prompts. Users acknowledge via dashboard (Phase 6) or dismiss via `/chanakya suggestion dismiss <id>`.
- **Never hard-route.** Phase 7's central invariant. The system never dispatches Lu Ban without user OK. Achilles never gets a brief re-assigned to Lu Ban mid-work. Chanakya proposes; user disposes.
- **Three-tier artifact paths.** Suggestions tier 2 (`plans/suggestions/`). Heuristic config tier 1 (`_shared/routing/novelty-weights.yaml`). No tier-3.
- **Minimal permission footprint.** All reads under `~/.dev-studio/<project>/` + repo-root `_shared/`. Writes only to `plans/suggestions/` + the event log. No new allowlist asks.
- **Additive to existing contracts.** `architectural_concerns[]` is an additive debrief field (minor bump). Novelty heuristic is a new Chanakya Step 0C — doesn't touch existing steps' outputs.
- **Right-sizing.** Single-file scoring function (~60 lines bash). Weights tunable in YAML; the empirical tuning loop is manual via debrief-tagged feedback. No new linter codes.

## 1. Decisions table — locked from user biases (2026-04-21)

| # | Decision | User bias (resume context) | Resolution |
|---|---|---|---|
| Q51 | Novelty heuristic for Lu Ban handoff | (d) weighted combo | **Weighted score = 0.5·catalog-absence + 0.3·keyword-match + 0.2·size-weight**, threshold ≥ 0.5 → suggest. Components (§3.1): catalog-absence from FTS5 query against `_shared/architecture-catalog.md`; keyword-match against a 12-word intake vocabulary; size-weight driven by Chanakya's size estimate. Weights live in `_shared/routing/novelty-weights.yaml`, tunable without code change. |
| Q52 | Achilles architectural-concern trigger | "confirm — all-of-list as structured `architectural_concerns[]` in debrief" | **Debrief schema gains `architectural_concerns: [{id, description, severity, suggested_followup, file_paths}]`, additive minor bump.** Concerns are opt-in observations Achilles makes *while working*, not blockers. Chanakya aggregates post-merge, turns any `severity ∈ {medium, high}` with `suggested_followup: lu-ban` into a Phase 7 suggestion. Cap: 3 concerns per debrief (noise mitigation). |
| Q53 | Delivery surface | (c) both | **Suggestions surface in `/chanakya status` + dashboard Now view.** Same underlying YAML artifact (`plans/suggestions/<id>.yaml`); two readers. Chanakya status shows as a section after "Pending tasks." Dashboard shows as a collapsible "Suggestions" section in NowView with count badge. Never in the approvals queue — suggestions aren't decisions. |

## 2. Suggestion artifact schema

`_shared/schemas/suggestion.md`, `suggestion@1.0.0`:

```yaml
schema_version: {name: suggestion, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
kind: lu-ban-handoff|architectural-concern|pattern-deviation
producer: chanakya|achilles|argus
created_at: <rfc3339>
expires_at: <rfc3339>                # default 14d; kind-adjustable
score: 0.0..1.0                      # heuristic confidence
summary: "<≤100 chars>"              # queue row label
rationale: "<≤500 chars>"            # why the system thinks this
context:
  intake_text: "<verbatim intake if lu-ban-handoff>"
  task_id: <uuidv7>?                 # if derived from an Achilles task
  debrief_id: <uuidv7>?
  concern_id: <uuidv7>?              # points into debrief's architectural_concerns[]
  file_paths: [<rel-path>…]?
  cluster: [<related-suggestion-ids>…]?  # populated by aggregator (§4.3)
  related_catalog_entries: [<pattern-id>…]?  # from novelty scoring
resolution:
  choice: promote-to-luban|dismiss|ignore-wontfix|duplicate   # null until acted
  decided_at: <rfc3339>?
  decided_via: chanakya|dashboard|cli?
  followup_design_task_id: <uuidv7>?  # set on promote-to-luban
  notes: "<optional free-text, ≤500 chars>"
status: pending|acted|expired|superseded
```

**Lifecycle states:**

- `pending` — live suggestion visible in both surfaces.
- `acted` — user chose `promote-to-luban` (followup created) or `dismiss`.
- `expired` — past `expires_at`, no user action.
- `superseded` — another suggestion absorbed this one via clustering (§4.3).

Suggestions are never retroactively revived. If the system re-detects the same novelty later, a new suggestion emits — aggregator links them via `cluster[]` for visibility.

## 3. Novelty heuristic (Q51)

### 3.1 Scoring function

Lives at `scripts/score-novelty.sh` (bash). Reads intake text + Chanakya's preliminary task size + catalog. Emits JSON:

```json
{"score": 0.72, "components": {"catalog_absence": 0.8, "keyword_match": 1.0, "size": 0.5}, "matched_keywords": ["refactor", "platform"], "nearest_catalog_entries": [{"id": "pat-coordinator-flow", "distance": 0.71}]}
```

**Component formulas:**

- **`catalog_absence`** (weight 0.5):
  - FTS5 query: `SELECT pattern_id, bm25(patterns) AS score FROM patterns WHERE patterns MATCH ? ORDER BY score LIMIT 3`, match on intake-token cleanup.
  - Map nearest-neighbor distance to [0, 1]:
    - Zero matches → 1.0 (totally novel)
    - Top hit bm25 distance > 5.0 → 0.7 (weak match)
    - Top hit bm25 distance ≤ 5.0 → 0.3 (moderate match)
    - Top hit bm25 distance ≤ 2.0 → 0.0 (strong match; not novel)
  - Rebuilt on catalog edit; cached in `~/.dev-studio/<project>/.runtime/state/catalog-fts5.db`.

- **`keyword_match`** (weight 0.3):
  - Intake tokenized (lowercase, strip punctuation). Any hit in the 12-word vocabulary → 1.0; else 0.
  - Vocabulary v1 (in `novelty-weights.yaml`): `architecture, design, redesign, refactor, cross-cutting, platform, module, module-boundary, new-subsystem, interfaces, abstraction, migration`.
  - Tuned empirically post-launch; Phase 7 ships the 12-word default.

- **`size_weight`** (weight 0.2):
  - `L` (from Chanakya's preliminary size estimate) → 1.0
  - `M` with ≥ 3 files likely touched (inferred by Chanakya's scan step) → 0.5
  - `M` with < 3 files → 0.0
  - `XS | S` → 0.0

- **Final score** = `0.5 * catalog_absence + 0.3 * keyword_match + 0.2 * size_weight`, range [0, 1].
- **Suggest threshold**: `≥ 0.5`. Below → no suggestion emitted. Above → `lu-ban-handoff` suggestion written.

### 3.2 Configuration file

`_shared/routing/novelty-weights.yaml`:

```yaml
version: 1
weights:
  catalog_absence: 0.5
  keyword_match: 0.3
  size_weight: 0.2
thresholds:
  suggest: 0.5
  cluster_distance: 2.0          # catalog-absence FTS5 distance below which we call it "pattern match"
keyword_vocabulary:
  - architecture
  - design
  - redesign
  - refactor
  - cross-cutting
  - platform
  - module
  - module-boundary
  - new-subsystem
  - interfaces
  - abstraction
  - migration
size_signal:
  large: 1.0
  medium_multi_file: 0.5
  medium_single_file: 0.0
  small_or_xs: 0.0
```

Weights + vocabulary tunable by hand. Any edit re-sources on next `/chanakya` invocation — no restart. Changes logged via `novelty_heuristic_tuned` event (§7).

### 3.3 Chanakya integration (Step 0C)

Added to `chanakya/modes/intake.md`. Runs *after* the size estimate (Step 0B) and *before* brief generation. Flow:

1. `scripts/score-novelty.sh` called with intake text + size.
2. If `score ≥ threshold.suggest`:
   - Write `plans/suggestions/<id>.yaml` with `kind: lu-ban-handoff`, score, rationale (human-readable from components).
   - Emit `suggestion_created` event.
   - Append one line to the current Chanakya response: *"Suggestion: this intake scores {score} on novelty (reasons). Promote to Lu Ban? — tracked as `<id>` in your queue."*
3. If below threshold: no suggestion, no message. Silent.

Brief generation proceeds regardless. User's decision to promote is async; they can choose `promote-to-luban` later, at which point Chanakya creates the `design-task` artifact (Phase 4 §4), dispatches to Lu Ban, and marks the original brief `superseded-by-design: <design-task-id>`.

### 3.4 Calibration

First 20 suggestions after Phase 7 lands: user marks each on dismiss as `{appropriate|false-positive|false-negative}`. Aggregated via 2.7's `workflow-signature` view. If false-positive rate > 40% after N=20, drop `catalog_absence` weight to 0.4; if false-negative rate > 25% (novel work shipped without suggestion), raise to 0.6. **Empirical tuning only — no auto-adjust.**

## 4. Achilles architectural-concerns channel (Q52)

### 4.1 Debrief field addition

Additive to current `debrief@<current>` — bump minor.

```yaml
architectural_concerns:
  - id: <uuidv7>
    description: "<one sentence, ≤200 chars — the smell observed>"
    severity: low|medium|high
    suggested_followup: lu-ban|debate|self-resolve|none
    file_paths: [<rel-path>…]   # scope of the concern
    created_at: <rfc3339>
```

**Cap: 3 concerns per debrief.** Beyond 3 = Achilles is firehose-flagging; debrief likely smells wrong itself. Chanakya surfaces "Achilles emitted >3 concerns on `<task-id>` — review debrief" as a warn-tier event.

### 4.2 Triggers — when Achilles adds a concern

Achilles adds a concern *during self-review step*, not during implementation. Triggers (each is a rule-line Achilles reads at self-review):

| Trigger | Example | Default severity | Default followup |
|---|---|---|---|
| **Circular dep introduced** | Module A now imports B which imports A. | high | lu-ban |
| **New cross-module abstraction** | Protocol added with ≥ 3 conformers across modules. | medium | lu-ban |
| **Shared mutable state across modules** | Global singleton or mutable dependency-inject'd across module lines. | medium | lu-ban |
| **Catalog deviation** | Pattern chosen in implementation contradicts a documented pattern in `_shared/architecture-catalog.md`. | medium | debate |
| **Repetition smell** | Third implementation of similar flow-shape across recent tasks (Achilles-level memory, hinted via 2.7). | low | debate |
| **Subsystem boundary crossed** | File touches a subsystem marked `stable: true` in the catalog but wasn't scoped in the brief. | high | lu-ban |

Triggers live in `_shared/routing/concern-triggers.md` (human-readable rules, no DSL). Achilles reads at self-review; matches by pattern. Phase 7 ships these 6 triggers; additions require plan amendment.

### 4.3 Chanakya aggregation

Post-merge, Chanakya's event processor (Phase 2.6) reads the debrief's `architectural_concerns[]`:

1. For each concern with `severity ∈ {medium, high}` AND `suggested_followup: lu-ban`:
   - Check if a suggestion already exists with matching `file_paths` overlap ≥ 50% and same kind.
   - **If exists**: append concern id to existing suggestion's `cluster[]`, update `score` as `max(existing, new concern-score)`. Emit `suggestion_clustered`.
   - **If not**: write new `plans/suggestions/<id>.yaml` with `kind: architectural-concern`, summary from `description`, rationale listing cluster. Emit `suggestion_created`.
2. Concerns with `severity: low` OR `suggested_followup ∈ {self-resolve, none}`: log to FTS5 substrate (2.7) for longitudinal tracking, no suggestion emitted.
3. `suggested_followup: debate` (not Lu-Ban-bound) emits a `pattern-deviation` suggestion instead — shown same way, but `promote-to-luban` is greyed; user chooses `dismiss` or `ignore-wontfix`.

**Clustering horizon: 30 days.** Concerns on debriefs older than 30d don't cluster against current suggestions; they surface as independent. Keeps recency meaningful.

### 4.4 Severity knob

Severity is Achilles's judgement. Phase 7 trusts it. If severity proves systematically wrong (calibration §6.3 below), `_shared/routing/concern-triggers.md` tightens the wording for the misbehaving trigger — no tier auto-adjust.

## 5. Delivery surfaces (Q53)

### 5.1 Chanakya status — "Suggestions" section

Added to `chanakya/modes/status.md` output layout, after "Pending tasks," before "Recent events":

```
## Suggestions (3 pending)
  1. [lu-ban-handoff] score=0.78 · "Refactor sync-engine to protocol-first layering"
     reasons: catalog-absence(0.9), keyword-match(1.0), size(L)
     promote: /chanakya suggestion promote <id>
     dismiss: /chanakya suggestion dismiss <id>
  2. [architectural-concern] score=0.65 · "Concern cluster on SyncCoordinator (3 debriefs)"
     from: debrief-t042, t047, t051 — circular-dep flagged 3x
     promote: /chanakya suggestion promote <id>
  …
```

Section hidden when zero pending. Max 5 shown; "+N more" link for the rest.

### 5.2 Chanakya CLI sub-commands

Added to `chanakya/SKILL.md` mode roster:

| Sub-command | Mode pack | Notes |
|---|---|---|
| `/chanakya suggestion list` | `modes/suggestion.md` | List pending + recent resolved. |
| `/chanakya suggestion promote <id>` | `modes/suggestion.md` | Creates Lu Ban `design-task`; transitions `status: acted`. Kind must be `lu-ban-handoff` or `architectural-concern`. |
| `/chanakya suggestion dismiss <id> [--reason "…"]` | `modes/suggestion.md` | Marks `acted` with `choice: dismiss`. |
| `/chanakya suggestion show <id>` | `modes/suggestion.md` | Full detail (rationale + cluster + related catalog entries). |

### 5.3 Dashboard Now view — "Suggestions" section

New section in `studio-dashboard/.../NowView.swift` (Phase 6 §4.1). Position: between "In-flight tasks" and "Crashes unhandled." Collapsible, collapsed-by-default. Badge on section header shows pending count. Menu-bar icon badge does *not* reflect suggestions (that's approvals-only per Phase 6 §4.1).

Row tap → detail sheet with:
- Summary, rationale, score components bar chart.
- Related catalog entries (for lu-ban-handoff) — tappable → opens catalog pattern in a read-only sheet.
- Cluster list (for architectural-concern) — tappable → opens debrief artifact sheet.
- Action buttons: "Promote to Lu Ban" (if eligible), "Dismiss" (with optional reason), "Ignore" (won't fix).

Promoting from dashboard emits `suggestion_resolved` with `decided_via: dashboard`; Chanakya's event processor handles the same as CLI promotion.

### 5.4 Suggestions never enter the approvals queue

Suggestions ≠ approvals. Approvals (Phase 6 §5) are *pending decisions that block an agent*. Suggestions are *observations the user can ignore*. Different UX, different schema, different producer contract. Conflating them would make the approvals queue noisy; keeping them separate keeps each surface pure.

## 6. Expiry + lifecycle management

### 6.1 Expiry

Default 14d for every suggestion. Scheduler tick (Phase 3) runs `scripts/suggestion-expire.sh` daily:

- Any `status: pending` + `expires_at < now` → `status: expired`, emit `suggestion_expired`.
- No file move; lifecycle-state field change only (suggestions don't archive to a `resolved/` subdir; they stay in `plans/suggestions/` with status field reflecting state — suggestions are lighter than approvals).

### 6.2 Supersession

Aggregator (§4.3) may mark older suggestions `superseded` if a newer one absorbs them. User sees superseded ones only via `/chanakya suggestion list --all`.

### 6.3 Calibration events

| Event | Purpose |
|---|---|
| `suggestion_created` | Fires whenever a suggestion emits. `producer`, `kind`, `score`. |
| `suggestion_resolved` | `choice`, `decided_via`, `resolution_duration_sec`. |
| `suggestion_expired` | `kind`, `score`, `created_at`. Useful calibration signal — high-score expireds may indicate UX issues. |
| `suggestion_clustered` | `original_id`, `absorbed_id`. |
| `novelty_heuristic_tuned` | Weights file edit — captures `{old_weights, new_weights}` for audit. |

Joined via 2.7's `workflow-signature` view: *"Of last 30 suggestions, X% were promoted, Y% dismissed, Z% expired."* Surfaced in Phase 6 Month view.

## 7. Event types added

All events carry the standard 2.5 envelope.

| Event | Payload | When emitted |
|---|---|---|
| `suggestion_created` | `{suggestion_id, kind, producer, score, rationale_summary}` | New suggestion YAML written. |
| `suggestion_clustered` | `{original_id, absorbed_id, kind}` | Aggregator merges into existing. |
| `suggestion_resolved` | `{suggestion_id, kind, choice, decided_via, resolution_duration_sec}` | User promotes/dismisses/ignores. |
| `suggestion_expired` | `{suggestion_id, kind, score, age_days}` | Past `expires_at` with no action. |
| `novelty_heuristic_tuned` | `{old_weights, new_weights, changed_by}` | `_shared/routing/novelty-weights.yaml` edit. |
| `architectural_concern_logged` | `{debrief_id, concern_id, severity, suggested_followup}` | Achilles adds a concern during self-review. |

## 8. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: **5 commits.**

1. **Commit A — schemas + config.** `_shared/schemas/suggestion.md`, `concern-triggers.md`, `novelty-weights.yaml`. Debrief schema minor bump (adds `architectural_concerns[]`). Event payload schemas (§7). Capability manifest regenerates. Pre-commit validates.
2. **Commit B — novelty heuristic.** `scripts/score-novelty.sh` + FTS5 catalog-index rebuild step (hooks into 2.7's existing rebuild). Chanakya `modes/intake.md` Step 0C integration. Unit tests: 12 fixtures covering score ranges + vocabulary hits + catalog-absence edge cases.
3. **Commit C — Achilles concern emission.** `achilles/modes/task.md` self-review step gains concern-detection rules from `_shared/routing/concern-triggers.md`. Unit tests on 6 trigger fixtures. Cap-of-3 enforcement + warn event when exceeded.
4. **Commit D — Chanakya aggregation + CLI + status section.** `chanakya/modes/suggestion.md` mode pack. Event-processor aggregation logic (§4.3). `modes/status.md` adds Suggestions section. `scripts/suggestion-expire.sh` + scheduler hook (Phase 3). Unit tests on aggregator clustering + 30-day horizon.
5. **Commit E — Dashboard surface + docs sync.** `studio-dashboard/.../NowView.swift` adds Suggestions section + detail sheet + promote/dismiss actions. `chanakya/docs.html` Suggestions card under Fleet. `README.md` + `chanakya/README.md` updated. Open docs.html in Safari per CLAUDE.md. End-to-end smoke: high-novelty intake → suggestion in status + dashboard → dashboard promote → Chanakya creates design-task.

Parallelizable: B ‖ C once A merges. E merges last; gated on Phase 6's dashboard scaffold existing.

## 9. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Heuristic floods user with low-value suggestions | High | Medium | Threshold 0.5 conservative at launch; calibrate down only if false-negative signal shows. Cap of 3 concerns per debrief. Dismiss-with-reason data feeds §3.4 calibration loop. |
| Achilles severity-calls prove systematically wrong | Medium | Medium | Calibration via `suggestion_expired` + `suggestion_resolved` joined with debrief — surfaces in Month view. Trigger wording tightens empirically. |
| Aggregator clustering merges unrelated concerns | Medium | Low | 50% file-path overlap is the gate; empirically safe for module-scoped concerns but risky cross-module. If misfires, tighten to 75% in weights file. `suggestion_clustered` event provides audit. |
| FTS5 catalog index absent (2.7 slipped) | Medium | High | `score-novelty.sh` falls back to grep-based string match on catalog.md (lower precision but functional). Score emits with `degraded: true` flag. Surfaces in status. |
| User ignores all suggestions → system drifts | High | Low | Intended. Suggestions are suggestions. Month-view surfaces "N suggestions expired unacted — worth a sweep?" once past threshold. |
| `promote-to-luban` creates orphan design-tasks if Lu Ban rejects | Low | Low | Lu Ban's rejection path (Phase 4 §5.2) links back to the suggestion; suggestion reverts to `pending` with a "rejected by Lu Ban" rationale bump. User can re-decide. |
| Concern-trigger rule drift between Achilles and Chanakya aggregator | Low | Medium | Single source: `_shared/routing/concern-triggers.md`. Achilles reads at self-review, aggregator reads the same file. Unit test asserts parsing equivalence. |
| Suggestions section in status clutters terse-preferring users | Medium | Low | Hidden when empty. Cap at 5 visible. User can globally mute via `novelty-weights.yaml::suggestion_threshold: 1.0` (effectively off). |
| Keyword vocabulary misses domain-specific novelty language | Medium | Medium | v1 is 12 words; vocabulary edit is a one-line change + `novelty_heuristic_tuned` event. Expect monthly tweaks in first quarter. |
| Dashboard suggestion row tap crashes on malformed YAML | Low | Low | Swift parser tolerant (schema-version-aware from Phase 6 §11); malformed entry renders as "⚠ parse error — open raw" row with file-path link. |

## 10. Post-Phase-7 freeze rules

When Commit E merges:

- **`suggestion@1.0.0` frozen.** Additive fields OK (minor); new `kind` values allowed; new `resolution.choice` values require plan amendment since Chanakya's handler enumerates them.
- **Never hard-route.** Any future change that dispatches agents based on suggestion scores — without user OK — requires explicit plan amendment. This is the phase's load-bearing invariant.
- **Heuristic stays bash + YAML.** No ML classifier, no Python service, no embedding model. Calibration is empirical via human weight edits. Promotion to ML-based scoring = plan amendment.
- **Cap of 3 concerns per debrief frozen.** Raising requires plan amendment; noise risk is real.
- **Trigger list frozen at 6.** Additions via plan amendment; removals only via 3-month "no hits" data.
- **Approvals queue and Suggestions queue stay separate.** Merging them = plan amendment.
- **Weight-file edits always emit `novelty_heuristic_tuned`.** No silent tuning.

## 11. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **Repetition-smell trigger that reads 2.7's `workflow-signature` view.** Needs Month view in Phase 6 first to have baseline data. **Recommend: revisit after Phase 6 ships + 30 days of debrief history.**
- **Auto-tuning of novelty weights via empirical loop** (closed-loop reinforcement from resolution outcomes). Keep manual in Phase 7; revisit only if manual tuning proves tedious.
- **Cross-project pattern library** — catalog patterns shared across user's projects. Out of scope until multi-project is real.
- **Natural-language intake novelty classifier** (LLM call instead of bash+FTS5). Rejected at Phase 7 scope; revisit if the 12-word vocabulary proves fundamentally too narrow.
- **Suggestion auto-dismiss on obvious false positives** (e.g., file-path exclusions for test fixtures). Emerges empirically; add when noise-in-practice is quantified.
- **Achilles "architectural concern during implementation"** (not just self-review). Phase 7 keeps concerns at self-review to avoid mid-implementation distraction. Revisit if concerns-from-self-review miss smells caught earlier in the flow.
- **Argus cross-reviewing suggestions.** Argus could flag low-quality Lu-Ban design candidates; out of scope for Phase 7.
- **Suggestion "snooze for 7 days."** Defer-without-dismiss. Add if users start dismissing suggestions they actually want to revisit.
- **Weekly digest of resolved/expired suggestions** posted to iMessage/Slack. Ties into Phase 9 narrative polish.
- **Heuristic component explainer view** — detail sheet currently shows the number; long-term, a "why this scored 0.72" explanation with sparkline. Polish, not correctness.
- **Concern-severity inference audit tool.** After 50 concerns logged, a `/chanakya suggestion audit` report comparing Achilles's severity calls with post-hoc outcome data. Tooling-heavy; defer.

## 12. Notes from initial drafting

- Suggestion-not-route is the phase's entire posture. Automating the dispatch *feels* like an efficiency win, but at single-user scale the human review is the cheap part; the system being wrong and silently dispatching to the wrong agent is the expensive part.
- Weighted-combo for novelty picked over catalog-absence-only because intake text is genuinely informative — "refactor platform layer" is a better signal than the catalog query alone. 50/30/20 weights reflect a bias toward catalog evidence without making keywords irrelevant.
- Vocabulary is deliberately small (12). Huge vocabularies become sticky — adding a word is easy, removing one is rare, and false-positive inflation compounds. 12 is enough to catch clear novelty hints without drowning in terms.
- Cap of 3 architectural concerns is empirical: if Achilles has >3 concerns, something's wrong at the brief level, not the concern level. Flagging the debrief itself is the right response, not doubling the cap.
- Clustering across debriefs is where this gets interesting long-term — three debriefs each independently flagging "circular dep in SyncCoordinator" become one high-confidence Lu Ban handoff suggestion. Without clustering, each becomes a separate low-signal suggestion; with clustering, the pattern surfaces.
- Dashboard and Chanakya status carry the same data, two readers. No tension — the user picks whichever surface is at hand. Dashboard wins for glance-discovery; status wins for CLI workflows.
- Calibration relies on manual dismiss-with-reason. Auto-tuning is tempting but would require a proper eval harness; the manual loop is tight enough for this scale.
