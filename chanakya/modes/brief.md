---
name: Chanakya Brief
description: Brief Generation + Brief-All composite. Writes self-contained Achilles briefs with Figma + codebase context. Runs a similarity probe before authoring (populates `similar_to`, offers duplicate-fold).
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json, debt.json]
budget_tokens: 5350
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/*.yaml                            # post-migration brief artifacts for in-progress overlap checks
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/briefs/<brief-id>.yaml                   # canonical (schema: _shared/schemas/brief.md, brief@3.1.0)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.brief + state bump
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Brief Generation (`/chanakya brief <task-id>`)

This is the most critical mode. The brief must be **completely self-contained** — a worker reads ONLY this file. It must also be compact enough to execute: author executable Achilles briefs as XS/S/M slices by default, with measurable acceptance and verification evidence that Argus can evaluate without guessing intent.

Snapshots: `snapshots/briefs.json` (tolerates 5-minute freshness — regenerate via `scripts/chanakya-snap.sh briefs` if older; fallback is `scripts/query-plans.sh --kind=task,brief`). `snapshots/debt.json` is checked on entry to refuse under block state (fallback: `scripts/query-plans.sh --kind=debt`).

## Step 1 — Read task

Post-migration surface: resolve the task via `scripts/query-plans.sh --kind=task --id=<task-id>` against `plans/tasks/<task-id>.yaml` (schema: `_shared/schemas/task.md`, `task@1.0.0`). If the task is `direct` type, note this in the output ("T003 is a direct task — briefing anyway") and continue.


## Step 1B — Reopen-aware context (when task state == reopened)

When Step 1 reports `state: reopened`, this is a re-brief. The brief MUST surface the reason and prior outcome verbatim so Achilles knows the work is round-2 and what went wrong the first time. Skip this step entirely when `state: proposed` (fresh task, normal flow).

Pull two values from the task YAML loaded in Step 1:

- `reopen_reason` — required when state is `reopened`; rendered verbatim under a `## Reopen reason` section in the brief body.
- `reopen_chain[-1]` — the most recent prior debrief id. If present, read `plans/debriefs/<id>.yaml` and quote the prior `key_learnings` / `decisions` / `unresolved` blocks under a `## Prior debrief` section. If the debrief artifact is missing, proceed with reason-only context.

The brief author does not re-derive Figma context, codebase context, or scope from scratch — it inherits them from the prior brief at `links.brief` (if present) and notes the delta the reopen exposed. This keeps re-briefs cheap and makes the reopen reason the load-bearing change.

Append `prior_debrief: <id>` to the brief frontmatter so downstream tooling (Argus, status mode, queries) can correlate the chain without re-reading the task.

## Step 1C — Similarity probe (populates `similar_to`)

Before authoring the brief, run a duplicate-fold probe against open tasks. This catches "we already briefed something close to this" — saves the worker from doing redundant work and gives the user a chance to fold instead of fork.

```bash
scripts/similarity-probe.sh --title "<task title>" \
  --touchpoints "<comma-joined affinity.touchpoints>" \
  --exclude "<this-task-id>"
```

Returns up to 5 ranked matches: `<score>\t<legacy>\t<uuid>\t<state>\t<title>`. Below the 0.20 threshold the script emits nothing — proceed to Step 2 silently.

When matches return, surface a soft hint *before* authoring:

> "T347 (`Add filter preset row to photo editor`, state: briefed, score 0.62) looks similar. Treat as:
> - **(d)uplicate** — confirmed; mark this task `duplicate_of: T347`, transition to `cancelled`, no brief authored.
> - **(s)imilar** — knowledge-layer hint; populate `similar_to: [T347]` on the task, then continue to Step 2.
> - **(n)ew** — distinct work; continue to Step 2 with no edge recorded."

`similar_to` is *suspected*, not blocking — never use it to gate dispatch. `duplicate_of` is *confirmed* and requires `state ∈ {cancelled, archived}` per `_shared/schemas/task.md`. When the user picks `(d)uplicate`, transition state via `lib-ledger` and emit the corresponding `task_state_changed` event; do not author a brief.

When the user picks `(s)imilar`, write the `similar_to` edge to `plans/tasks/<task-id>.yaml` before continuing — the brief authored in Step 6 will reference the prior task in its "Prior context" section automatically.

## Step 2 — File overlap detection

Check if the task's likely target files overlap with files listed in any `in-progress` task's brief. `scripts/query-plans.sh --kind=brief --state=dispatched` enumerates the active briefs; match the union of each brief's `writes:` + `reads:` arrays against the new task's expected targets. On overlap warn the user:

"T003 will touch PhotoEditorContainerView.swift, which T001 is currently modifying. Recommend waiting for T001 to finish, or coordinating on separate sections."

## Step 3 — Gather Figma context

If the task has Figma references:
1. Call `mcp__figma__get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` for each node
2. Call `mcp__figma__get_screenshot(fileKey, nodeId)` — note the screenshot path
3. Call `mcp__figma__get_variable_defs(fileKey, nodeId)` for design tokens
4. **Inline everything** into the brief — the worker must not need MCP access

If no Figma refs AND task type is `feature` or UI-related: ask "Does this task have a Figma design? Paste the URL or say 'no design'." Otherwise skip silently and continue to Step 4.

## Step 4 — Gather codebase context

Use Glob and Grep to find:
1. **Files to modify** — primary files the worker will touch
2. **Files to read** — adjacent files for context (view models, protocols, models)
3. **Patterns to follow** — find a similar existing feature and reference it
4. **Architectural constraints** — read relevant memory files from project memory
5. **Testing context** — find existing test files for the module (`*Tests.swift`, `*UITests.swift`), existing accessibility identifier enums, test helpers/utilities, and the project's test organization pattern

## Step 4A — Infer and write affinity.touchpoints

After authoring the "Files to Modify" list in Step 4, write those paths to `affinity.touchpoints` on the task YAML. This lets `achilles-dispatch.sh` detect parallel-unsafe tasks and lets Argus scope its neighbor scan (#254).

```bash
source scripts/lib-paths.sh && source scripts/lib-ledger.sh
# Annotation write — bumps updated_at + rebuilds index; no state event emitted.
set_task_touchpoints "<task-uuid>" "<path1>" "<path2>"
```

Skip when `affinity.touchpoints` is already non-empty, or the task has no "Files to Modify" section (direct / test-run-only types).

## Step 5 — Determine branch strategy

- Independent task: propose a new branch name (convention: `v/<feature-slug>` or `achilles/<task-id>`)
- Dependent task: note the base branch
- Include exact git commands to create the worktree (Achilles handles the actual worktree add; the brief only names conventions)

## Step 5B — Shape executable scope

Before writing an implementation brief, decide whether the task is executable or a parent planning container:

- **Executable worker task:** direct Achilles or Apollo work. Default `size` to `xs`, `s`, or `m`. If the loaded task is `size: l`, split it into smaller child tasks before dispatch unless the user has explicitly waived splitting.
- **Parent planning task:** design container, epic, release bucket, or broad workstream. It can remain `size: l`, but do not dispatch it directly to Achilles; author child executable briefs instead.
- **Waived L implementation:** allowed only with an explicit `## L-size reason`, `## Size waiver`, `## Split rationale`, or `## Why not split` section in the body. The reason must explain why one worker context is safer than splitting.

Every executable brief must include: concise objective, explicit non-goals / out-of-scope, measurable acceptance criteria, verification/evidence guidance, structured model recommendations, and dependencies/handoff notes only when they affect execution. Long background belongs in linked design/context docs or in the ≤500-token `summary`, not in the worker body.

For audit-shaped tasks ("survey every module for X"), reference the optional parallel `Explore` recipe in `_shared/contracts/brief-formats/impl-brief.md`; do not make it mandatory.

## Step 6 — Write the brief (type-aware)

Render the type-specific narrative from the template corresponding to the task type (see §6A-D below) into a tempfile, then call `write_brief_artifact` with `schema_version=3.8.0` — it writes the YAML canonical form (schema `_shared/schemas/brief.md`, `brief@3.8.0`), emits `brief_state_changed null → draft`, and regenerates `plans/index.yaml`.

`brief@3.8.0` turns the quality bar into a pre-ready lint gate via `scripts/validate-brief.sh`. See `_shared/schemas/brief.md` §Executable Brief Quality Contract for the exact checked fields.

### Summary (`brief@3.2.0`, required for new briefs)

Every brief MUST carry a `summary` — a ≤500-token compact slice that downstream consumers (`/chanakya dispatch-ready`, Achilles agent-boot under `BRIEF_SLICE=summary`) render directly without re-parsing the full body. Author it as the **shortest fact-dense description that lets a reader decide whether to load the full brief**. Three sentences max:

1. What this task changes (one sentence).
2. Why it matters / what triggers it (one sentence).
3. Key constraint or non-obvious assumption (one sentence).

Not a TLDR of acceptance criteria — those live in `acceptance`. Pass it as a single-line `summary="..."` k=v to `write_brief_artifact`. Lint refuses summaries longer than 500 tokens (`scripts/lint-brief.sh` — run on the written artifact before transitioning to `ready`).

### Dispatch routing (`brief@3.3.0`)

Default `dispatch_agent: achilles` and leave `perf_mode` / `evidence` null — the standard worker path.

Set `dispatch_agent: apollo` when the task is iOS-performance-flavored: memory regression / leak / OOM, thermal throttling, battery / energy drain. In that case:

- `perf_mode` MUST be one of `memory` | `thermal` | `battery` (selects Apollo's mode pack).
- `evidence` MUST be populated. Either:
  - `artifacts: [...]` cites pre-captured `.trace` / `MXMetricPayload` / `.xcresult` paths, OR
  - `capture_plan: "..."` declares the auto-capture Apollo will run before recommending a fix (XcodeBuildMCP / AXe / `xctrace` invocation).
- `baseline_ref` names the git ref the baseline was captured against — drives Apollo's pre-merge re-measure delta.

If neither artifacts nor capture_plan is available at brief time, `/apollo measure <metric> --capture-only` is the right pre-flight tool to populate `artifacts` before authoring the brief. Briefs that route to Apollo without `evidence` will be refused at dispatch (strict-9 gate, `apollo/_shared/primitives/evidence-gate.md`).

**Required header fields** — every brief MUST include these three fields in its Priority & Complexity / Recommendations block (per `_shared/rules/brief-model-effort.md`):

1. **Recommended model** — `Opus | Sonnet | Haiku` + one-line rationale.
2. **Model reasoning effort** — `low | medium | high` + one-line rationale.
3. **Size** (a.k.a. task effort) — `XS | S | M | L`. (Existing field; drives Step 6 build gate downstream.)

The first two govern thinking cost; the third governs diff cost. They are independent — a small (`S`) crash fix can warrant `Opus / high` because diagnosis is the cost driver, not the diff. Defaults by task shape are documented in the rules file. Briefs missing any of the three fail brief-review (warn-tier) and the worker session has to guess — the whole point of the rule is to remove that guess.

**Concrete invocation** (run in the Bash tool; all paths are resolver-derived per REVIEW.md R3):

```bash
source scripts/lib-paths.sh
source scripts/lib-ledger.sh

PROJECT_ROOT=$(resolve_project_root)
mkdir -p "$PROJECT_ROOT/.runtime/tmp"
BODY_FILE="$PROJECT_ROOT/.runtime/tmp/brief-body-<LEGACY_ID>.md"

# Use Write tool to author $BODY_FILE with the rendered §6A-D body.
# Then:

BRIEF_UUID=$(mint_uuidv7)
# Mint as draft for the lint+transition flow (default authoring path).
# Pass `awaiting_user=true` instead if the brief intentionally ships with
# `## Open questions` / `## Decisions pending` for the user to resolve;
# pass `state=ready` to skip draft entirely when the brief is final at mint.
write_brief_artifact "$BRIEF_UUID" "<parent-task-uuid>" "<type>" "<size>" \
  awaiting_user=false \
  schema_version=3.8.0 \
  legacy_task_id=<T-number> \
  slug=<short-kebab-slug> \
  summary="<one-sentence change>. <one-sentence why>. <one-sentence key constraint>." \
  recommended_models='{"best_result":{"tier":"sonnet","model_id":"claude-sonnet-default","reasoning_effort":"medium"},"fast_turnaround":{"tier":"haiku","model_id":"claude-haiku-default","reasoning_effort":"low"},"rationale":"Small implementation against established patterns."}' \
  body_file="$BODY_FILE"

# Self-review before flipping to ready: lints the summary slice and (if any
# predecessor debrief paths are passed via --predecessor) fails the brief if
# any inherited concern's keywords are absent from the body. Closes the
# silent-absorb gap (#162). For first-time briefs pass no flags.
BRIEF_PATH="$(resolve_briefs_dir_for "$(resolve_project)")/$BRIEF_UUID.yaml"
scripts/self-review-brief.sh "$BRIEF_PATH" || exit $?

# Flip draft → ready so the brief becomes claimable.
transition_brief_state "$BRIEF_UUID" ready chanakya "authored by $USER"

# Emit Chanakya-side dispatch anchor (#220 A2-3 / events.md §brief_dispatched).
# Lets sweep detect dispatched-but-never-started briefs without reading worker writes.
TASK_YAML="$(resolve_tasks_dir_for "$(resolve_project)")/<parent-task-uuid>.yaml"
BRIEF_DISPATCH_TYPE=$(yq -r '.type // "impl"' "$TASK_YAML")
BRIEF_DISPATCH_SIZE=$(yq -r '.size // "m"' "$TASK_YAML")
BRIEF_DISPATCH_AGENT=$(yq -r '.dispatch_agent // "achilles"' "$BRIEF_PATH")
emit_event_keyed chanakya brief brief_dispatched "$BRIEF_UUID" \
  "$(jq -nc --arg bu "$BRIEF_UUID" --arg ti "<parent-task-uuid>" \
             --arg ty "$BRIEF_DISPATCH_TYPE" --arg sz "$BRIEF_DISPATCH_SIZE" \
             --arg da "$BRIEF_DISPATCH_AGENT" \
     '{brief_uuid:$bu, task_id:$ti, type:$ty, size:$sz, dispatch_agent:$da}')"
```

The helper special-cases `body_file=` (and `body=` for inline) — the YAML emits `body: |` block-scalar. Do not hand-write the YAML via the Write tool; the helper owns schema + write + event + index-rebuild as a unit.

State transitions follow `_shared/state-machines/brief-lifecycle.md`. `write_brief_artifact` requires explicit mint intent — pass `awaiting_user=false` (default authoring path: brief lands as `draft`, caller transitions to `ready` after lint), `awaiting_user=true` + `## Open questions` body section (when the brief intentionally ships with author-resolvable decisions; fires `brief_awaiting_user` for sweep surface), or `state=ready` (atomic flows that skip the draft phase entirely). Calls without one of these are refused.

### 6A — Implementation brief (Type: feature | bugfix | refactor | direct)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/impl-brief.md`.

The `## Testability Requirements` section (captured both as the `testability:` array field and inlined in `body:`) must include: SOLID principles, accessibility identifiers, localization (if task touches UI strings — see `~/.claude/skills/_shared/rules/localization-rules.md` for the full ruleset), and test seams.
**Bug briefs (task `type: bug`):** render the `## Bug Context` section from the impl-brief template (Steps to Reproduce, Expected, Actual, Affected Files, Linked Issues) — all mandatory for bug briefs. Pass `reproducer="<steps>"` to `write_brief_artifact` so the YAML field is populated. `scripts/validate-brief.sh` (via `self-review-brief.sh`) blocks the `draft → ready` flip if neither the body section nor the YAML field is present (#220 A2-1 / brief@3.4.0).

### 6B — Unit test brief (Type: test-unit)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/unit-test-brief.md`.

### 6C — Integration test brief (Type: test-integration)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/integration-test-brief.md`.

### 6D — UI test brief (Type: test-ui)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/ui-test-brief.md`.

## Step 7 — Update task back-reference and state

Use `set_task_link` and `transition_task_state` from lib-ledger — both write the YAML, emit the right event, and rebuild the index. Do not hand-edit the task YAML via `yq -i` or Write.

```bash
# Still in the Bash tool session from Step 6 (helpers already sourced).
set_task_link "<parent-task-uuid>" brief "$BRIEF_UUID"
transition_task_state "<parent-task-uuid>" briefed chanakya "brief minted"
```

On re-brief (task already in `briefed`), `set_task_link` overwrites `links.brief` with the new brief-id and `transition_task_state briefed chanakya` is a same-state no-op — safe to call.

On re-brief from `reopened` (after `/chanakya reopen <task-id>`), the same call transitions `reopened → briefed`. `transition_task_state` handles this transparently — no special path. The reopen lineage is already on the task (`reopen_reason`, `reopen_chain`); Step 1B is what carries it into the new brief body.

## Step 7A — Invalidate briefs snapshot

After the brief write, fire the briefs snapshot producer in the background so the next status read is fresh inside the 60-second window:

```bash
scripts/chanakya-snap.sh briefs &
```

Don't wait for it. The producer is ~50ms and idempotent; worst case the next status invocation falls back to a full-load. Why: a user who briefs a task then immediately runs `/chanakya` expects to see the new `briefed` status without a 60-second lag.

## Step 8 — Suggest next action

"T001 brief ready (`plans/briefs/<brief-id>.yaml`). Next: T002 is independent and P1 — brief it with `/chanakya brief T002` or launch a worker with `/achilles T001`."

When `dispatch_agent: apollo`, suggest `/apollo <perf_mode> T001` instead of `/achilles T001`.

---

# Composite: Brief-All (`/chanakya brief-all`)

Brief every `pending` task, in priority order, without asking for confirmation between each one.

## Steps

1. Enumerate via `scripts/query-plans.sh --kind=task --state=pending`. Exclude `direct` type — those don't need briefs.
2. If zero candidates, report: "No pending tasks to brief." Return.
3. Sort by priority (P0 first), then by task ID.
4. **Check debt gates.** If build or test debt is in `block` state, filter out implementation tasks and keep only test sub-tasks and TBUILD/TUNIT/TUI tasks. If nothing remains after filtering, report the block and return.
5. For each task, run Brief Generation mode (Steps 1–8) sequentially. Skip user confirmation between briefs — the user already approved by running `brief-all`.
6. **Invalidate once, at the end.** Skip Step 7A's per-task snapshot refresh while iterating; fire one `scripts/chanakya-snap.sh briefs &` after the loop finishes. Avoids N redundant producer runs on a batch brief.
7. Report: "Briefed N tasks: T001, T002, T003a, T004c. All ready for `/achilles`. Suggest: `/achilles ship next` to start executing."

**Guard:** If a brief fails (e.g., missing Figma context, file overlap conflict), log the failure, skip that task, and continue with the next. Report skipped tasks at the end.

## Brief formats (shared)

Implementation brief format: `~/.claude/skills/_shared/contracts/brief-formats/impl-brief.md`
Unit test brief format: `~/.claude/skills/_shared/contracts/brief-formats/unit-test-brief.md`
Integration test brief format: `~/.claude/skills/_shared/contracts/brief-formats/integration-test-brief.md`
UI test brief format: `~/.claude/skills/_shared/contracts/brief-formats/ui-test-brief.md`
TDD brief format: `~/.claude/skills/_shared/contracts/brief-formats/tdd-brief.md`

Debrief format (for the `## Debrief Instructions` section in every brief): `~/.claude/skills/_shared/contracts/debrief-format.md`
