# Phase 4 Execution Plan (draft)

Drafted 2026-04-20 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q32–Q38 are each marked locked; no open rows in the decisions table. Deferred items in §13 have a recommended default in **bold** where the user will still want to weigh in.

Phase 4 introduces **Lu Ban**, a standalone architectural-design agent. Chanakya remains the single intake surface; it dispatches design work to Lu Ban the same way it dispatches implementation work to Achilles. Lu Ban consumes a structured `design-task` artifact, loads a short architecture catalog, studies the relevant code, and produces a **design YAML** that *becomes* the ADR when the user approves it. No separate ADR file; status is a field on the design. Lu Ban writes docs only — never code, never git actions beyond read.

See `ROADMAP.md` §Phase sequence, `PHASE-2-5-PLAN.md` / `PHASE-2-6-PLAN.md` / `PHASE-2-7-PLAN.md` for upstream contracts, and `ARCHITECTURE.md` §Design Vision for agent-roster rationale. Gated by 2.6 (needs YAML ledger + `plans/index.yaml`) and 2.7 (catalog ADR-index rebuild uses the FTS5 substrate for status lookups). Parallelizable with Phase 3 after 2.7 lands.

## 0. Standards and non-negotiables

Unchanged from 2.5/2.6/2.7 §0, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale, not fit-for-enterprise.** Single-user iOS workflow tool. Lu Ban is a *low-frequency, high-depth* agent: used sparingly (a handful of designs per month), allowed to run long, but must stay cheap at idle (it's another SKILL.md file; zero resident cost when not invoked).
- **Agent-first design.** Lu Ban's output is structured YAML consumed by Chanakya + the architecture catalog + future view generators. Markdown body is for humans, YAML envelope is for agents. No interactive prompts except a single inline approval step (§6).
- **Three-tier artifact paths.** Design YAMLs + design-tasks live in tier 2 (`~/.dev-studio/<project>/plans/…`). Architecture catalog lives in tier 1 (repo, `_shared/architecture-catalog.md`). No tier-3 writes.
- **Minimal permission footprint.** Lu Ban reads the repo + tier-2 plans; writes only to `plans/designs/` and `_shared/architecture-catalog.md`. No new allowlist asks.
- **Router pattern from 2.5 §3.** Lu Ban is router-first from birth. SKILL.md stays under 100 lines; all workflow logic in mode packs.
- **Contracts + schemas from 2.5/2.6.** Lu Ban's YAMLs carry the standard `schema_version` object, message envelope, producer tagging. Artifacts live under `plans/` per the 2.6 canonical layout.

## 1. Decisions table — all locked

| # | Decision | Resolution |
|---|---|---|
| Q32 | Agent shape | Standalone agent `/luban`, not a Chanakya mode. Used sparingly but runs long; folding into Chanakya would bloat its router cognitive surface. |
| Q33 | Intake flow (amended 2026-04-22 — dual review added) | User → Chanakya (`/chanakya design "…"` or conversational intake) → Chanakya writes a `design-task` artifact under `plans/design-tasks/<id>.yaml` and dispatches → Lu Ban produces design → **Lu Ban self-reviews before publishing** (mandatory, mirrors Achilles self-review pattern) → **Argus `/argus design-review` runs** (mandatory for designs producing ≥3 Achilles tasks, optional for smaller) → Lu Ban iterates on `argus_verdict ∈ {flagged, blocked}` or publishes on `approved` → emits `design_completed` → Chanakya ingests, decides how to break into Achilles briefs. User can force-publish via `/luban publish --override`; design carries `overrode: <argus-reason>` for audit. See §5.2 for revision-loop detail. |
| Q34 | Design output format | Single YAML artifact per design at `plans/designs/<design-id>.yaml`. Multi-line markdown body in a `body:` field. Consistent with 2.6's YAML-per-artifact pattern; indexable into 2.7's FTS5 substrate; no directory-per-artifact sprawl. |
| Q35 | Code-writing scope | Docs-only. Lu Ban never writes code. Achilles implements from Chanakya's briefs derived from Lu Ban's design. Whether Chanakya still needs to brief Achilles after a design lands is an **open observation** — monitor via 2.7's `workflow-signature` view before deciding. |
| Q36 | Architecture catalog shape (amended 2026-04-22 — cap removed) | `_shared/architecture-catalog.md` with three slim sections: **(1)** pattern library (proven iOS approaches, anti-patterns, when-to-use-what); **(2)** past-ADR index (every approved design: id, title, status, outcome); **(3)** technology inventory (frameworks/libraries in use, deprecated, approved). **No line cap — architect freely.** Catalog loaded only at Lu Ban session start (infrequent); prompt budget is a non-issue at current scale. When catalog crosses ~5000 lines, split into relevance-based sub-files — real-problem-later, not a now constraint. |
| Q37 | ADR lifecycle | **The design YAML *is* the ADR when `status: approved`.** No separate markdown file. Views filter designs by status to surface current ADRs. Avoids dual source of truth. |
| Q38 | Machine placement (amended 2026-04-22 — priority inverted) | Long-running work (Achilles / Argus / Lu Ban) follows the priority: **Studio (if online) → mini (if online) → laptop (fallback)**. Chanakya stays on the interaction machine (fast user round-trip). Hook reads presence via `ssh <host> true` at dispatch time; unavailable hosts drop out of the ordering gracefully. Natural-language override (`"run this on mac mini"`) still parses and pins a specific machine — overrides the priority. |

## 2. Lu Ban agent architecture

New agent under `luban/` at repo root, peer to `chanakya/`, `achilles/`, `argus/`:

```
luban/
  SKILL.md                    # router-only, <100 lines
  modes/
    design.md                 # the only mode in Phase 4
  README.md                   # long-form walkthrough (post-scaffold)
```

### 2.1 SKILL.md — router-first from birth

Constraints inherited from 2.5 `patterns/router-pattern.md`:

- Router prose enumerates every sub-command and routes to the mode pack.
- No workflow logic in SKILL.md. Only: frontmatter, agent identity, mode roster, safety envelope (what Lu Ban never does), load-at-start reads.
- `reads:` / `writes:` synthesized by `scripts/capability-manifest.sh` per 2.5 §3.5.

**Default sub-command:** `/luban design <design-task-id>` → `modes/design.md`. No args → mode pack inspects the Achilles/Lu Ban inbox and picks the oldest unclaimed design-task.

**Safety envelope (stated explicitly in SKILL.md):**

- Lu Ban **never** writes code or modifies files under `src/`, `Sources/`, test trees, Xcode projects, or any project source tree.
- Lu Ban **never** runs git write operations. Read-only git (`git log`, `git show`, `git diff`, `git ls-files`) is allowed for studying the codebase.
- Lu Ban **only** writes under `plans/designs/` and `_shared/architecture-catalog.md`. Anything else is a block.
- Argus may be invoked to review a design YAML (future); Lu Ban never invokes Achilles.

### 2.2 Mode packs — start minimal

Phase 4 ships **one** mode pack: `modes/design.md` (§6).

**Shipped in Phase 4 (2026-04-22 amendment — Q33 dual review):**

- `luban/modes/self-review.md` — mandatory self-review pass Lu Ban runs on its own design YAML before publishing. Mirrors Achilles's self-review discipline: decisions-vs-rationale consistency, rejected-alternatives coverage (0 alternatives = red flag), constraint satisfaction, catalog-deviation detection (flags a Phase 7 `architectural-concern` suggestion if present). Output is either "publish-ready" or a list of self-identified gaps to iterate on.
- `luban/modes/publish.md` — writes the design YAML to `plans/designs/` and emits `design_completed`. Runs after self-review + (conditional) Argus design-review. Supports `--override` flag for force-publish on Argus `flagged` / `blocked` verdicts.

**Explicitly deferred mode packs** (right-sizing per 2.5/2.6 pattern — don't build until a real need surfaces):

- `modes/catalog-curate.md` — sweep the catalog for stale entries, deprecated tech, orphan ADRs. Deferred until the catalog grows past ~5000 lines and drift becomes visible (line cap relaxed per 2026-04-22 Q36 amendment).
- `modes/superseded.md` — walk through marking a design as `superseded-by: <new-id>` with reason. Deferred until the second major rework lands.

## 3. Design YAML schema

`_shared/schemas/design.md`, `design@1.0.0`. Full field list:

```yaml
schema_version: {name: design, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
title: "…"
status: draft|review|approved|deprecated|superseded
status_reason: "…"                     # required when status in {deprecated, superseded}
superseded_by: <design-id>?            # required iff status=superseded
supersedes: [<design-id>…]             # inverse link
created_at: <rfc3339>
updated_at: <rfc3339>
approved_at: <rfc3339>?                # set when status first flips to approved
deprecated_at: <rfc3339>?
author: {agent: luban, skill_version: <semver>, git_sha: <short-sha>}

# Source inputs
design_task_id: <uuidv7>               # the task that triggered this design
related_task_ids: [<uuidv7>…]          # tasks that cite this design downstream
related_design_ids: [<uuidv7>…]        # adjacent designs (not supersede — peer)
related_file_paths: [<repo-rel-path>…] # load-bearing files the design touches

# The actual design
decisions:                             # structured decision list
  - what: "…"                          # the decision made
    why: "…"                           # rationale
    scope: "…"                         # where it applies (module, area, global)
rejected_alternatives:                 # structured — feeds decision journal (2.7 deferred view)
  - option: "…"
    why_rejected: "…"
    risk_if_revisited: "…"?            # what would make us reconsider

constraints:                           # constraints from the design-task that shaped the answer
  - "…"
open_questions: ["…"]                  # anything Lu Ban couldn't resolve in-session

# Human-readable narrative
body: |
  # Title
  
  ## Context
  …
  
  ## Decision
  …
  
  ## Consequences
  …

# Links — index-joinable
links:
  design_task: <design-task-id>
  briefs_derived: [<brief-id>…]        # populated by Chanakya post-ingest
  debriefs: [<debrief-id>…]            # populated as Achilles lands work citing this design

# Dispatch metadata (Q38)
target_machine: <machine-id>?          # null = any; otherwise filters which worker picks up a downstream task
```

**Status enum semantics:**

| Status | Meaning | Catalog ADR-index surfaces it? |
|---|---|---|
| `draft` | Lu Ban emitted, user has not approved. | No. |
| `review` | User or Argus is actively evaluating it. Terminal if abandoned. | No. |
| `approved` | User blessed it. **This is the ADR.** | Yes. |
| `deprecated` | Still on disk, no longer current guidance. `status_reason` explains. | Yes, tagged deprecated. |
| `superseded` | Replaced by a newer design. `superseded_by` required. | Yes, as back-reference from the replacement. |

State transitions emit `design_*` events (§9). State machine lives at `state-machines/design-lifecycle.md`, shipped in Commit B.

## 4. Design-task artifact

Chanakya writes this when dispatching to Lu Ban. `_shared/schemas/design-task.md`, `design-task@1.0.0`:

```yaml
schema_version: {name: design-task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
title: "…"                             # "Design: offline-first sync for cart"
created_at: <rfc3339>
created_by: chanakya
state: dispatched|claimed|completed|cancelled
claimed_by: luban?
claimed_at: <rfc3339>?

initial_context: |                     # multi-paragraph markdown — the "why we need this"
  …
constraints:                           # user-stated or Chanakya-inferred
  - "Must work offline for 24h"
  - "No new paid services"
related_code_paths: [<repo-rel-path>…] # hints from Chanakya; Lu Ban expands via git grep
urgency: low|normal|high               # affects whether Chanakya waits for Lu Ban before briefing Achilles on adjacent work
expected_output_shape:                 # optional hint — e.g. "new module layout + data-flow diagram"
  - "…"

target_machine: <machine-id>?          # null = any; set by Chanakya from user's natural-language "run on X" (Q38, §8)
links:
  origin_event_id: <uuidv7>?           # event that triggered the dispatch
  related_design_ids: [<uuidv7>…]      # Chanakya's guess at adjacent designs
```

**Where it's written:** `~/.dev-studio/<project>/plans/design-tasks/<id>.yaml`.

**Lifecycle:** state flows `dispatched → claimed → completed | cancelled`. Shipped as `state-machines/design-task-lifecycle.md` alongside `design-lifecycle.md` in Commit B.

## 5. Chanakya intake mode extensions

Lu Ban's existence requires Chanakya to gain a design-dispatch pathway. Opinionated recommendation: **new sub-command `/chanakya design` as a mode pack, not an extension of `brief`**.

Why a new mode rather than extending `brief`:

- `brief` mode's mental model is "implementation work → Achilles contract". Reusing it for "design work → Lu Ban contract" muddies the router prose and the token budget.
- A separate `design` mode is symmetric with `brief` and makes the two dispatch paths obvious in the Chanakya SKILL.md roster.
- Right-sized: ~80-line mode pack, doesn't bloat `brief`.

### 5.1 `chanakya/modes/design.md` — new mode

**Invocation:** `/chanakya design "<free-text problem statement>"` or conversational ("Chanakya, we need an architecture pass on sync").

**Steps:**

1. Parse the problem statement; extract title, initial context, constraints, related-code hints (via `git grep` over user-mentioned symbols).
2. Detect a `target_machine` directive in the user's text ("run this on mac mini") via the general multi-machine hook (§8). Default null.
3. Look up adjacent approved designs via the catalog's ADR-index (§7) — populate `related_design_ids`.
4. Write `plans/design-tasks/<uuidv7>.yaml` with state `dispatched`.
5. Emit `design_requested` event (§9).
6. Print a one-line handoff: "Dispatched design-task `<id>` to Lu Ban. Run `/luban design <id>` to begin."
7. Does **not** wait. Lu Ban may run in a different session, possibly a different machine.

### 5.2 Ingest path — post-design (amended 2026-04-22 — dual review)

Lu Ban produces the design → self-reviews (`luban/modes/self-review.md`) → Chanakya routes to Argus design-review if the design is "≥3-Achilles-tasks" sized → Argus verdict decides whether Lu Ban iterates or publishes. The verdict-loop sits *between* Lu Ban authorship and `design_completed`, not after it — the `design_completed` event fires only once the design is publication-ready.

**Sizing gate (Argus mandatory vs optional):** Lu Ban's self-review emits a preliminary `downstream_task_count_estimate` on the draft design (integer; Lu Ban's best guess at how many Achilles tasks it will spawn). Chanakya compares to the threshold in `_shared/routing/design-review-policy.yaml` (default 3):

- Estimate ≥ 3 → Argus design-review **mandatory**. Chanakya dispatches `/argus design-review <design-id>`.
- Estimate < 3 → Argus design-review **optional**. Lu Ban may skip and publish directly; user can still request review via `/argus design-review <design-id>` any time before approval.

**Revision loop:**

1. Lu Ban drafts `plans/designs/<design-id>.yaml` with `status: self-review-pending`.
2. Lu Ban self-review runs. On gap: Lu Ban iterates (no event); on ready: status → `review-pending`, emits `design_self_reviewed` `{design_id, gaps_found, iterations}`.
3. Chanakya's event processor routes to `/argus design-review <design-id>` if mandatory per sizing gate.
4. Argus emits `design_review_verdict` `{design_id, verdict: approved|flagged|blocked, findings: [...]}`:
   - `approved` → status → `draft` (ready for user approval). Emit `design_completed`. Chanakya surfaces to user per existing flow.
   - `flagged` → status stays `review-pending`; Lu Ban iterates on findings. Loop back to step 2. Emit `design_review_iteration_requested`.
   - `blocked` → same as `flagged` but findings are hard-blockers; user intervention recommended.
5. User can force-publish on `flagged` / `blocked` via `/luban publish --override`. Design YAML carries `overrode: {argus_verdict, reason, override_justification}` for audit; `design_completed` fires with `override: true`.

**Post-`design_completed` user-approval flow (unchanged from original §5.2):**

- On **approve**: Chanakya patches the YAML to `status: approved`, `approved_at: <now>`, emits `design_approved`. Triggers catalog ADR-index rebuild hook (§7.2).
- On **revise**: user comments captured as a revision note; Chanakya writes a new `design-task` with `related_design_ids: [<old-id>]` and dispatches again. Old design stays `draft`.
- On **reject**: Chanakya deletes the `design-task` `claimed → cancelled`, design remains `draft` (not auto-deleted; user can re-examine).

After approval, Chanakya evaluates whether Achilles briefs are needed to implement the design. This is the **open observation** from Q35 — measure via 2.7's `workflow-signature` view whether briefs are typically redundant post-design, and decide empirically.

## 5B. Achilles plan-review amendment (2026-04-22 — carved from Phase 7 Q52 discussion)

The architectural-concern triggers Phase 7 catches at Achilles self-review (post-implementation) miss a class of issues that are cheaper to catch earlier: duplicated utilities already in the codebase, subsystem-boundary risks, pattern choices that contradict the catalog. For `size: m|l` Achilles tasks that did **not** come from an upstream Lu Ban design, add a lightweight plan phase before implementation. Not a full Lu Ban hand-off — a short structured plan Achilles writes, Argus reviews, and Chanakya re-checks for novelty now that the plan text is richer than the brief.

### 5B.1 Scope

- Tasks with `size: m|l` AND `brief.source != "lu-ban-design"`.
- XS / S tasks skip. Crash-fix tasks (`kind: crash-fix`) skip (Phase 5's 3-step gate handles them differently).

### 5B.2 Plan artifact

New schema `_shared/schemas/achilles-plan.md`, `achilles-plan@1.0.0`. Stored at `plans/achilles-plans/<task-id>.yaml`:

```yaml
schema_version: {name: achilles-plan, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
task_id: <uuidv7>
brief_id: <uuidv7>
status: drafting|reviewed|approved|flagged
created_at: <rfc3339>
updated_at: <rfc3339>

approach:                               # 1-3 paragraphs, prose
  - "…"

files_likely_touched: [<rel-path>…]
introduced_symbols_expected: [<type|func|protocol>…]
patterns_chosen:
  - pattern: "…"
    rationale: "…"
    catalog_reference: <pattern-id>?
rejected_approaches:
  - option: "…"
    why_rejected: "…"
risks: ["…"]
open_questions: ["…"]

novelty_rescore:                        # populated by Chanakya on plan-phase re-run
  score: 0.0..1.0
  components: {catalog_absence, keyword_match, size}
  suggested_lu_ban_handoff: bool
```

### 5B.3 Flow

1. Achilles receives brief. If scope per §5B.1, drafts `plans/achilles-plans/<task-id>.yaml` with `status: drafting`.
2. Chanakya's event processor reacts to `achilles_plan_drafted`: re-runs the Phase 7 novelty heuristic against the plan text (richer than the intake). If the new score crosses the threshold, emits a Phase 7 `lu-ban-handoff` suggestion with `context.intake_text: "<plan excerpt>"` — user can promote before implementation starts. Plan still proceeds regardless (suggestion is non-blocking).
3. Chanakya dispatches `/argus plan-review <task-id>` — a new single-pass Argus mode. Verdict is **`approved`** or **`flagged`**; `blocked` is not available (plan-review is never a hard stop — the implementation loop can always proceed and course-correct).
4. Argus review checks: plan consistency with brief acceptance criteria; `patterns_chosen` against the catalog; `rejected_approaches` non-empty (0 alternatives = red flag — same heuristic as Lu Ban); `files_likely_touched` matches Chanakya's pre-brief scan (gross mismatch = scope drift).
5. Verdict `approved` → status → `approved`; Achilles proceeds to implementation. Verdict `flagged` → Chanakya surfaces findings to user; Achilles iterates or user decides to proceed-as-is (`status: flagged`, implementation continues with findings attached to the eventual debrief for post-hoc correlation).

### 5B.4 Argus `plan-review` mode

New mode pack `argus/modes/plan-review.md`, ~120 lines. Reuses Argus's existing read-only envelope + the 2.5 Argus-review primitives. Reviews a plan document (YAML + prose), not a diff — so no xcodebuild, no test run. Output schema reuses `review@<current>` with `kind: plan-review`.

### 5B.5 State machine

Task-lifecycle state machine `_shared/state-machines/task-lifecycle.md` gains an additive alternate path (additive = doesn't break Phase 2.5 contract):

```
proposed → briefed → dispatched → plan-drafting → plan-reviewed-approved → in-progress → self-reviewed → argus-reviewed → merged → …
                                ↘ plan-reviewed-flagged → in-progress (user override or iteration) → …
```

`plan-drafting` and the `plan-reviewed-*` states are additive. Existing tasks that skip the plan phase (XS/S, Lu-Ban-sourced, crash-fix) flow `dispatched → in-progress` as before. Phase 2.5's 2.5 Q6 idempotency guarantees are preserved — same dedup-key rules.

### 5B.6 Phase 2.7 dependency

The duplicated-utility trigger added to Phase 7 (Q52 expansion) needs to query "what helpers were introduced in recent debriefs?" at plan-phase. Phase 2.7 adds a new `recent-utilities` view (see PHASE-2-7-PLAN.md §3.6) — a lightweight query over debrief `introduced_symbols[]` field, windowed to 30d by default. Achilles reads this view at plan-phase; if any of its `introduced_symbols_expected` overlap with `recent-utilities`, it adds a `duplicated-utility` concern candidate to its plan.

### 5B.7 Events

| Event | Payload | When emitted |
|---|---|---|
| `achilles_plan_drafted` | `{task_id, plan_id, files_likely_touched_count, introduced_symbols_expected_count}` | Achilles writes plan YAML, status `drafting`. |
| `achilles_plan_novelty_rescored` | `{task_id, plan_id, old_score, new_score, suggested_lu_ban_handoff}` | Chanakya re-runs novelty heuristic at plan time. |
| `achilles_plan_reviewed` | `{task_id, plan_id, verdict, findings_count}` | Argus plan-review verdict lands. |

## 6. Lu Ban `modes/design.md` workflow

Step-by-step. Mode pack ~120 lines of prose.

1. **Boot.** Emit `agent_boot` event (2.6 §8). Record `git_sha`, `skill_version`.
2. **Load the catalog.** Read `_shared/architecture-catalog.md` in full. At <500 lines this is a single ~5k-token load at session start; worth it because every design decision should consult patterns + inventory + past-ADR-index.
3. **Read the design-task.** Pick up `plans/design-tasks/<id>.yaml` (argument or oldest unclaimed). Patch state `dispatched → claimed`, set `claimed_by: luban`, `claimed_at`. Emit `design_started`.
4. **Study related code.** Walk `related_code_paths` from the task. Expand via `git grep` on domain terms. Read files selectively — Lu Ban is allowed to be thorough here (this is the "run long" permission from Q32). Budget: no hard cap, but emit `luban_session_reading` event every ~10 files so the token-cost-budget view surfaces unusual sessions.
5. **Consult catalog sections** against the problem:
   - **Pattern library:** is there a proven iOS pattern that fits? An anti-pattern that rules out an obvious option?
   - **Past-ADR index:** are there prior designs that constrain or inform this one? Add their IDs to `related_design_ids`.
   - **Tech inventory:** what frameworks/libraries already in-use can be reused? What's deprecated and off-limits?
6. **Form the design.** Produce `decisions[]` + `rejected_alternatives[]` + narrative `body` markdown. Every meaningful choice gets both a `decisions[]` entry (terse, structured) and a paragraph in the body (rationale, tradeoffs, diagrams if helpful).
7. **Write design YAML.** Atomic rename into `plans/designs/<design-id>.yaml` with `status: draft`.
8. **Patch the design-task.** State `claimed → completed`. Links `design_task_id` mutually.
9. **Emit `design_completed` event.** Payload includes `{design_id, design_task_id, decision_count, rejected_alternative_count, target_machine}`.
10. **Inline approval (if mid-user-session).** If Lu Ban is running in an interactive session *with the user* (vs dispatched asynchronously), it prints the structured decisions list + a link to the YAML and asks: *"Approve as-is, request revision, or leave as draft?"* If async, skips — Chanakya handles approval per §5.2.

**Budget expectations (token-cost-budget view, 2.7 §3.4):** expect Lu Ban sessions to be 2–5× the cost of a Chanakya brief session. That's the bargain struck in Q32 — fewer sessions, each deeper.

**What Lu Ban does not do, restated:**

- No code edits. No touching `src/` / `Sources/` / test trees.
- No git writes. Read-only git is fine.
- No invocation of Achilles or Argus (in Phase 4).
- No writes outside `plans/designs/` and `_shared/architecture-catalog.md`.

## 7. Architecture catalog structure

`_shared/architecture-catalog.md`, three sections, total under 500 lines. Lu Ban loads it whole at session start; the rest of the studio references sections individually.

### 7.1 Section layout

```
# Architecture Catalog

## 1. Pattern Library
  ### 1.1 Proven patterns (iOS)
    - Pattern: <name>
      - When to use: …
      - When NOT to use: …
      - References: [<adr-id>, <file-path>]
  ### 1.2 Anti-patterns
    - Anti-pattern: <name>
      - Why it fails in this codebase: …
      - Seen in ADRs: [<adr-id>…]
  ### 1.3 When-to-use-what matrix
    | Problem shape | Preferred pattern | Fallback | Hard no |

## 2. Past-ADR Index
  ### (auto-generated — do not hand-edit)
  | ADR ID | Title | Status | Approved | Outcome / Note |
  |--------|-------|--------|----------|----------------|
  | <id>   | …     | approved | …      | one-line outcome |

## 3. Technology Inventory
  ### 3.1 In use
    - <framework/library> — version, area of use, ADR link
  ### 3.2 Approved (not yet used)
    - <name> — approved in <adr-id>, reason
  ### 3.3 Deprecated
    - <name> — deprecated in <adr-id>, migration path
```

### 7.2 ADR-index auto-rebuild

Section 2 is **generated**, not hand-edited. Rebuild rule:

- Pre-commit hook `scripts/rebuild-catalog-adr-index.sh` detects any staged change under `plans/designs/*.yaml` or any `design_approved`/`design_superseded`/`design_deprecated` event in today's event log.
- On detection: query 2.7's FTS5 substrate (`kind='adr'` with `status IN ('approved', 'deprecated', 'superseded')`) via `scripts/query-plans.sh --kind=design --state=approved,deprecated,superseded`.
- Regenerate Section 2 between `<!-- adr-index:start -->` / `<!-- adr-index:end -->` markers. Stable sort by `approved_at DESC`.
- Commit the updated catalog file in the same commit as the approval event. Fails the commit if the user hand-edited inside the markers.

Sections 1 and 3 are **hand-edited** (Lu Ban may append to them during a `modes/catalog-curate.md` session once that mode lands — deferred). Manual edits to §1 / §3 do not trigger the index rebuild.

### 7.3 Initial content (Phase 4 Commit E)

Seed the catalog with:

- §1.1 — 4–6 iOS patterns Lu Ban should know: MVVM + Combine, coordinator pattern, DI via constructor, feature-module layout, SwiftUI-UIKit interop, etc. (Curated from existing implicit knowledge in the codebase + user input during commit review.)
- §1.2 — 2–3 anti-patterns already seen in debriefs (e.g. "massive view controllers", "shared mutable singletons without clear ownership").
- §2 — empty table (no approved designs yet).
- §3.1 — inventory auto-derived from `Package.swift` / `Podfile` / `*.xcodeproj` once on seed (ad-hoc script; not a permanent auto-sync — the inventory is a curated list, not an inventory dump).

## 8. Cross-machine dispatch hook (Q38 — contract only)

**Scope:** the hook applies to every dispatchable artifact type (brief, design-task, eventually test-task / build-task), not Lu Ban-specific. Phase 4 specifies the contract; Phase 4 does **not** implement cross-machine routing — that waits for Mac mini onboarding Stage 2+ (per 2.5 §8 deferred).

### 8.1 `target_machine` field on every dispatchable artifact

Shipped in Phase 4 schemas:

- `design-task@1.0.0` — `target_machine: <machine-id>?`
- `design@1.0.0` — `target_machine: <machine-id>?`
- `achilles-plan@1.0.0` (2026-04-22) — `target_machine: <machine-id>?`

Phase 2.6 brief schema (`brief@3.1.0`) does not carry this yet; we add it additively in Phase 4 Commit A as a bump to `brief@3.2.0` (minor — new field with null default). Other dispatchable kinds inherit the pattern from there.

### 8.2 Dispatch priority and natural-language directives (2026-04-22 amendment — priority inverted)

Dispatch picks a machine in this order, evaluated at dispatch time via `ssh <host> true`:

| Rank | Host | Applies to |
|---|---|---|
| 1 | **Studio** (office machine, when online) | Achilles, Argus, Lu Ban — long-running work |
| 2 | **mini** (M1 Mac mini, when online) | Achilles, Argus, Lu Ban |
| 3 | **laptop** (daily driver) | Fallback only — used when 1+2 both unreachable |
| — | Chanakya stays on the interaction machine regardless | Fast round-trip for user |

**Natural-language overrides** still parse and pin a specific machine (hook location `chanakya/modes/_shared/machine-dispatch-parser.md`; referenced from any Chanakya mode that writes a dispatchable artifact — `brief`, `design`, `achilles-plan`, future test-dispatch):

- Regex + keyword over user input: `/run (this|it) on (mac ?mini|laptop|studio|<machine-name>)/i`, `/on the (mac ?mini|laptop|studio)/i`, etc.
- Resolve name → machine-id via `~/.dev-studio/.runtime/known-machines.yaml` (seeded lazily; `scripts/machine-id.sh` from 2.5 §3.13 writes entries on first boot per machine).
- Unknown name → emit `machine_dispatch_unresolved` warn event + fall back to priority order (not `null` — the default is no longer "any machine" but "walk the priority list").
- Explicit "any machine" / "wherever" → `target_machine: null` (dispatch walks the priority list).

### 8.3 Worker-side filtering (deferred implementation)

Contract: each worker (Achilles, Lu Ban, future test-worker) reads its inbox and filters out artifacts whose `target_machine` is set and doesn't match the local machine-id. This is **documented in the contract now, implemented when Mac mini onboarding Stage 2 lands**. Until then, all workers ignore `target_machine` and pick up everything — effectively laptop-only until mini onboarding completes.

### 8.4 Why ship contract empty-implementation

Field + parser now means: no schema migration later (~30-line filter is all Mac mini Stage 2 adds); historical dispatches are tagged correctly even while filtering is off; prevents a later phase from adding this field three incompatible ways. The 2026-04-22 priority inversion is a parser rule change, not a schema change — no new field, no new migration.

## 9. Event types added

All events carry the standard 2.5 envelope (`producer`, `idempotency_key`, `occurred_at`, `schema_version`).

| Event | Payload | When emitted |
|---|---|---|
| `design_requested` | `{design_task_id, title, urgency, target_machine}` | Chanakya writes the design-task. |
| `design_started` | `{design_id_placeholder, design_task_id, claimed_by: luban}` | Lu Ban claims the task. |
| `design_self_reviewed` | `{design_id, gaps_found, iterations}` | Lu Ban self-review finishes (2026-04-22 amendment Q33). |
| `design_review_verdict` | `{design_id, verdict, findings: [...]}` | Argus design-review verdict lands (2026-04-22 amendment Q33). |
| `design_review_iteration_requested` | `{design_id, verdict, iteration_count}` | Argus returned `flagged`/`blocked`; Lu Ban iterates. |
| `design_completed` | `{design_id, design_task_id, decision_count, rejected_alternative_count, status: draft, target_machine, override: bool}` | Lu Ban publishes the design YAML (after dual review or user override). |
| `design_approved` | `{design_id, approved_by: user, approved_at}` | Chanakya patches status to approved. |
| `design_superseded` | `{design_id, superseded_by, reason}` | User (via Chanakya) marks supersede. |
| `design_deprecated` | `{design_id, reason}` | User (via Chanakya) marks deprecated. |
| `machine_dispatch_unresolved` | `{raw_text, artifact_id, artifact_kind}` | §8.2 natural-language parse fails. Warn. |
| `luban_session_reading` | `{design_task_id, files_read_so_far, tokens_so_far}` | Every ~10 files Lu Ban reads during §6 step 4. Feeds 2.7 `token-consumption` view (renamed from `token-cost-budget` 2026-04-22). |
| `achilles_plan_drafted` | `{task_id, plan_id, files_likely_touched_count, introduced_symbols_expected_count}` | Achilles writes plan YAML (2026-04-22 §5B). |
| `achilles_plan_novelty_rescored` | `{task_id, plan_id, old_score, new_score, suggested_lu_ban_handoff}` | Chanakya re-runs novelty at plan-time (2026-04-22 §5B). |
| `achilles_plan_reviewed` | `{task_id, plan_id, verdict, findings_count}` | Argus plan-review verdict (2026-04-22 §5B). |

Payload schemas live at `_shared/schemas/events/<event-name>.md`, following the 2.6 per-type schema pattern.

## 10. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: **8 commits** (amended 2026-04-22 — up from 6; adds Commit G for Lu Ban self-review + Argus design-review, and Commit H for the Achilles plan-review amendment).

1. **Commit A — schemas land.** `_shared/schemas/design.md` + `design-task.md` + `achilles-plan.md` (§5B.2) + event-payload schemas (§9). Bump `brief@3.1.0 → brief@3.2.0` adding `target_machine` field (additive, minor). Pre-commit validates. No script/agent changes yet.
2. **Commit B — state machines + catalog skeleton.** `state-machines/design-lifecycle.md` + `design-task-lifecycle.md` + `task-lifecycle.md` additive plan-phase path (§5B.5). `_shared/architecture-catalog.md` with the three-section skeleton + seed content for §1 and §3 (§7.3). `<!-- adr-index:start/end -->` markers in §2 with an empty table. **No line cap** on the catalog (2026-04-22 Q36 amendment).
3. **Commit C — Lu Ban agent scaffold.** `luban/SKILL.md` (router-only, <100 lines) + `luban/modes/design.md` (§6 workflow). `luban/README.md` long-form walkthrough. `scripts/scaffold-agent.sh` runs clean. Capability manifest regenerates with Lu Ban's `reads/writes`. Smoke test: `/luban` with no args prints help; `/luban design` against a fixture design-task produces a valid YAML.
4. **Commit D — Chanakya `design` mode + dispatch parser hook.** `chanakya/modes/design.md` (§5.1) + `chanakya/modes/_shared/machine-dispatch-parser.md` (§8.2 — **Studio → mini → laptop priority walker**). Chanakya debrief-ingest loop branch for `design_completed` (§5.2). Parser referenced from `chanakya/modes/brief.md` too (so briefs can carry `target_machine` immediately). Unit tests on the natural-language parser with ~10 phrasings + priority walker with different host-availability combinations.
5. **Commit E — catalog ADR-index auto-rebuild.** `scripts/rebuild-catalog-adr-index.sh` + pre-commit hook wiring. Seed content for §2 stays empty (no approved designs yet). Unit test: a fixture approved design triggers the rebuild and populates §2; a hand-edit inside the markers fails pre-commit.
6. **Commit F — docs sync + event wiring.** `chanakya/docs.html` adds a "Design" card alongside Brief, Review. `README.md` TL;DR + roster updated (Lu Ban added). Event types registered in `contracts/events.md`. `_shared/schemas/events/design-*.md` validated. Open docs.html in Safari per CLAUDE.md routine. End-to-end smoke: Chanakya dispatches a design-task → Lu Ban completes it → Chanakya ingests → user approves → catalog ADR-index rebuilds with the new row.
7. **Commit G — Lu Ban self-review + Argus design-review (Q33 dual-review amendment).** `luban/modes/self-review.md` + `luban/modes/publish.md` (with `--override`). New Argus mode `argus/modes/design-review.md` (~150 lines, reuses Argus read-only envelope). `_shared/routing/design-review-policy.yaml` (sizing threshold default 3). Chanakya event-processor branches for `design_self_reviewed` + `design_review_verdict` + `design_review_iteration_requested` (§5.2 revision loop). Unit tests: self-review gap-detection fixtures, design-review verdict routing, override-audit persistence.
8. **Commit H — Achilles plan-review amendment (§5B).** Achilles `modes/plan.md` (plan-drafting step). Argus `modes/plan-review.md` (single-pass, approved|flagged). Chanakya novelty-rescore hook on `achilles_plan_drafted`. `_shared/schemas/achilles-plan.md` finalizes against the 2.7 `recent-utilities` view. Docs-sync: Argus docs.html gets a plan-review card; Achilles README walkthrough updated. Unit tests on 6 plan-review fixtures + duplicated-utility detection via 2.7 view.

Parallelizable: A ‖ B. D ‖ E once C merges. F merges after D/E. G merges after F (needs the Chanakya design-completed branch to plug the dual-review into). H merges after Phase 2.7's `recent-utilities` view lands — if 2.7 slips, H can ship with the duplicated-utility trigger feature-flagged off, re-enabled when 2.7 Commit G merges.

## 11. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Lu Ban runs long but produces shallow designs | Medium | Medium | `rejected_alternatives[]` + `decisions[]` are structured — 0-entry arrays visible on inspection. Review pattern: 0 rejected alternatives = didn't consider tradeoffs. |
| Catalog drift — §1 / §3 go stale, Lu Ban loads misleading patterns | High | Medium | `modes/catalog-curate.md` deferred but tracked. Each `design_approved` nudges hand-review once catalog passes 300 lines. |
| Approved design implies code changes Achilles never gets briefed on (Q35) | Medium | High | Open observation via 2.7 `workflow-signature` view. If post-design briefs go missing, tighten Chanakya's brief-after-design step empirically. |
| Natural-language machine parser false-positive | Low | Medium | `machine_dispatch_unresolved` on ambiguity, default null. `raw_text` logged for audit. User can edit YAML before approval. |
| Catalog ADR-index rebuild loops on itself | Low | Low | Hook detects only `plans/designs/*.yaml` + events; skips when only the catalog file is staged. |
| Lu Ban violates safety envelope (writes outside allowed set) | Low | High | New linter code `E_WRITE_SCOPE_VIOLATION` in Commit C, scoped to `luban/modes/*.md`. |
| Chanakya writes `target_machine` but no worker filters → feels broken | Low | Low | Documented §8.3 — laptop-only until Mac mini Stage 2. Directive recorded but ignored. |

## 12. Post-Phase-4 freeze rules

When Commit F merges:

- **Design artifact shape is frozen at `design@1.0.0`.** New fields are additive (minor bump); breaking changes follow the 2.5 `min_reader` / `deprecated_at` protocol.
- **ADR lifecycle goes through design YAML only.** No freestanding ADR markdown files under any subdir. Any `*.md` that looks like an ADR outside `plans/designs/` is a lint block.
- **Catalog §2 is auto-generated.** Hand-edits inside the `<!-- adr-index:* -->` markers fail pre-commit. §1 / §3 remain hand-edited.
- **`target_machine` is a contract field.** Any future dispatchable artifact schema adds it — not adding it is a plan error. Worker filtering implementation lands with Mac mini Stage 2.
- **Lu Ban write scope is frozen to `plans/designs/` + `_shared/architecture-catalog.md`.** New destinations require a new mode pack + explicit SKILL.md update — ask-first tier per CLAUDE.md.

## 13. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **`luban/modes/catalog-curate.md`.** Deferred until catalog §1 / §3 pass ~5000 lines (cap relaxed per 2026-04-22 Q36). Line-count trigger, not time.
- **`luban/modes/superseded.md`.** Deferred until first real rework.
- **Two-pass plan-review** (2026-04-22) — adding a Lu Ban plan-sanity-check pass alongside Argus plan-review. Keep it single-pass for now; escalate only if telemetry shows Argus consistently misses architectural issues in plans.
- **Catalog auto-generation from debrief history.** 2.7's `feature-catalog` view could seed §1 anti-patterns. Deferred until 2.7's view is producing signal.
- **Q35 empirical observation — "does Chanakya still need to brief after Lu Ban?"** Monitor via 2.7 `workflow-signature`. **Acceptance: ≥5 approved designs with downstream work, then decide.**
- **Cross-machine dispatch real implementation (Q38).** Worker filtering + design-task sync lands with Mac mini Stage 2. Dependent on tier-3 sync.
- **Argus review of designs.** Conflict detection vs existing ADRs / catalog anti-patterns. **Recommend: revisit after ≥3 approved designs.**
- **Design dependency graph view.** Tier-B of 2.7 — queryable `related_design_ids` / `supersedes` web. **Recommend: `view-design-graph` post-2.7.**
- **Decision-journal view.** Deferred in 2.7 §10 pending ADR producer — Phase 4 *is* that producer; view buildable post-Phase-4 but out of scope.

## 14. Notes from initial drafting

- Lu Ban (魯班) — Chinese patron of architects + master builders; matches Chanakya / Achilles / Argus naming.
- Design-YAML-is-the-ADR (Q37) is the single most load-bearing choice — eliminates dual-source-of-truth drift that kills markdown-ADR systems.
- `target_machine` ships now because it's cheap now and expensive to retrofit across artifact types.
