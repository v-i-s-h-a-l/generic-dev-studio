# 01-audit, partial — Agent surface (Chanakya / Achilles / Argus)

**Source:** Session B Explore agent (id `a8331976`), completed 2026-04-24.
**Scope:** `chanakya/`, `achilles/`, `argus/` SKILL.md + modes. Pure inventory, no proposals.

---

## Chanakya — Project Manager (Router)

### 1. Router Summary

**SKILL.md**: 88 lines | **Mode dispatch**: Frontmatter `name`, `description`, `type` fields map sub-commands to mode files. **Trigger phrases** (description field): "status", "brief", "review", "sweep", "update", "test-manifest", "test-flow", "review-feedback", "compact", "sync-slack", "ship", "sweep-debt", "verify", "ingest-thread", "ingest-dm", "ingest-slack", "report-design", "report-product", "feedback-archive", "feedback-history", "studio-feedback", "auto-sweep". Default: `status` mode when no args. Intent detection priority: explicit arg → conversational switch → default.

### 2. Mode Pack Inventory

| Mode | Purpose | Lines | Explicit Inputs | Explicit Outputs |
|------|---------|-------|-----------------|------------------|
| `status.md` | Default: render master-plan summary, git state, blockers, push queue, test-flow round status, release status | 76 | `snapshots/briefs.json`, `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/releases/*.yaml`, `plans/chanakya-master.md` | `push-queue.jsonl` (display marks), terminal snapshot |
| `intake.md` | Initial task capture + planning; PRD → task groups with test-tiers, skills, master-plan YAML | 151 | User PRD/bullet points, `plans/index.yaml`, `plans/chanakya-master.md` | `plans/tasks/<task-id>.yaml`, `plans/index.yaml`, `plans/chanakya-master.md` (legacy), `events/<date>.jsonl` |
| `brief.md` | Generate self-contained briefs (brief@3.1.0) with Figma context, codebase refs, testability requirements; `brief-all` composite | 160 | `plans/index.yaml`, `plans/tasks/<task-id>.yaml`, `plans/briefs/*.yaml`, Figma MCP (if refs exist), LSP/grep for codebase context | `plans/briefs/<brief-id>.yaml`, `plans/tasks/<task-id>.yaml` (back-ref update), `plans/chanakya-tasks/<task-id>-<slug>.md` (legacy markdown), `events/<date>.jsonl` |
| `review.md` | PRD-delta: diff updated spec against master plan, mark tasks `needs-rework`, regenerate stale briefs | 61 | Updated PRD (file path or paste), `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/briefs/*.yaml`, `plans/chanakya-master.md` | `plans/tasks/<task-id>.yaml` (state + history), `plans/briefs/<brief-id>.yaml` (regenerated), `plans/index.yaml`, `events/<date>.jsonl` |
| `sweep.md` | Inbox-sweep-only invocation (Step 0A–0G from inbox-sweep.md); no status render | 29 | (none — routes to inbox-sweep.md) | Terminal output summary; Step 0's side effects |
| `update.md` | Cross-reference git state with master plan; auto-close merged task branches | 32 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/chanakya-master.md`, `git branch -a` | `plans/tasks/<task-id>.yaml` (state transitions), `plans/chanakya-master.md` (legacy), `plans/index.yaml` |
| `tests.md` | `test-manifest` + `test-flow` grouping: per-task checklist vs. journey-ordered walkthrough; handles `--promote`, `--diff`, `--scope` | 173 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/debriefs/*.yaml`, `plans/rounds/*.yaml`, `plans/chanakya-master.md`, `journey-map.md` (optional) | `plans/rounds/<round-id>.yaml`, `plans/user-testing.md`, `plans/user-testing-rounds/user-testing-round<N>.md` (legacy), `plans/index.yaml`, `events/<date>.jsonl` |
| `feedback.md` | `review-feedback` (apply user-testing.md edits → task state transitions + follow-ups), `feedback-archive` (promote verified records), `feedback-history` (search active+archive), `studio-feedback` (capture studio-level feedback) | 201 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/rounds/*.yaml`, `plans/feedback/*.yaml`, `plans/user-testing.md`, `feedback/active.md`, `feedback/archive/**/*.md` | `plans/tasks/<task-id>.yaml` (state bumps, follow-up mint), `plans/feedback/<feedback-id>.yaml` (state transitions), `plans/user-testing-archive/<ts>.md`, `feedback/active.md` (legacy prune), `feedback/archive/build-<N>.md` (legacy append), `events/<date>.jsonl` |
| `inbox-sweep.md` | Pre-dispatch Step 0 (0A–0G): ingest regular/release/build-check debriefs, run thresholds, janitor sweep, process events, emit feedback reminders, ingest studio-feedback | 182 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/debriefs/*.yaml`, `plans/reviews/*.yaml`, `plans/releases/*.yaml`, `plans/feedback/*.yaml`, `events/<date>.jsonl`, `feedback/active.md`, `plans/chanakya-master.md` (legacy fallback) | `plans/tasks/<task-id>.yaml` (state transitions), `plans/releases/<release-id>.yaml`, `plans/debriefs/<debrief-id>.yaml` (emitted → ingested), `plans/chanakya-master.md` (legacy), `events/<date>.jsonl` |
| `compact.md` | Archive verified tasks + rounds, regenerate dashboard + module index, trim master plan to ~500 lines, optionally sweep artifacts | 165 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/debriefs/*.yaml`, `plans/feedback/*.yaml`, `plans/rounds/*.yaml`, `plans/chanakya-master.md`, `plans/chanakya-archive.md`, `feedback/active.md`, `feedback/archive/**/*.md` | `plans/tasks/<task-id>.yaml` (state → archived), `plans/feedback/<feedback-id>.yaml`, `plans/rounds/<round-id>.yaml`, `archive/2026-pre-2.6/<task-id>.yaml`, `plans/chanakya-master.md` (slimmed), `plans/chanakya-archive.md` (legacy append), `events/<date>.jsonl` |
| `ship.md` | Brief + dispatch composite: resolve targets, check debt gates, brief pending, generate phased dispatch plan | 57 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/briefs/*.yaml`, `plans/chanakya-master.md`, `.runtime/achilles-inbox/worker-*/alive` (fleet detection) | `plans/briefs/<brief-id>.yaml` (state transitions via brief mode), `.runtime/achilles-inbox/queue/*.json` (fleet-mode queue enqueues), terminal dispatch plan |
| `sweep-debt.md` | Identify + brief all pending test sub-tasks and build checks | 36 | `plans/index.yaml`, `.runtime/state/chanakya-snapshots/*.json` (debt.json), `plans/chanakya-master.md` (legacy fallback) | (delegates to brief mode) |
| `verify.md` | Guided single-sitting: test-flow generation → user test → promote → review-feedback → file follow-ups | 33 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/rounds/*.yaml`, `plans/reviews/*.yaml`, `plans/chanakya-master.md` | (orchestrator — no direct writes; delegates to test-flow, review-feedback, intake sub-modes) |
| `sync-slack.md` | Sync Slack Lists bug tracker with master plan (status, dev notes, fixed-in-build) | 190 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/chanakya-master.md`, `project_slack_list_sync.md` (project memory), `~/.claude/secrets/slack-bot-token` | Slack API writes (reactions, threaded replies), `plans/tasks/<task-id>.yaml` (Slack sync timestamp), `plans/chanakya-master.md` (legacy writeback) |
| `ingest.md` | Ingest Slack threads, DMs, or channel posts into feedback | 84 | Slack thread/DM URLs or plain text, `plans/feedback/*.yaml`, `feedback/active.md` | `plans/feedback/<feedback-id>.yaml`, `plans/index.yaml`, `feedback/active.md` (legacy append), `events/<date>.jsonl` |
| `feedback-reports.md` | Render design and product feedback reports by build; summary tables + detail blocks | 65 | `plans/feedback/*.yaml`, `plans/chanakya-inbox/design-report-<date>.md` (legacy), `plans/chanakya-inbox/product-report-<date>.md` (legacy) | Terminal table + `plans/chanakya-inbox/design-report-<YYYY-MM-DD>.md`, `plans/chanakya-inbox/product-report-<YYYY-MM-DD>.md` (legacy) |

**Chanakya total**: 16 mode packs, 1751 lines

---

## Achilles — Worker Agent (Router)

### 1. Router Summary

**SKILL.md**: 85 lines | **Mode dispatch**: Frontmatter fields → `modes/` map. **Trigger phrases**: "task" (default via task-id pattern `T\d+[a-z]?` or brief file path), "build", "debrief", "push-tf", "app-store", "group", "next", "test-suite", "worker", "studio-feedback". Flags `--wait`, `--force-build`, `--ignore-build-debt`, `--dry-run` apply to `task.md`; `--skip-debrief` to release modes. Intent: explicit arg → task-id pattern → conversational switch → direct mode (default).

### 2. Mode Pack Inventory

| Mode | Purpose | Lines | Explicit Inputs | Explicit Outputs |
|------|---------|-------|-----------------|------------------|
| `task.md` | Primary execution pipeline (brief-mode + direct-mode): worktree isolation, self-review, LSP/full-build gate, Argus pre-merge, merge, debrief | 340 | Brief file (post-migration: `plans/briefs/<brief-id>.yaml`), `plans/tasks/<task-id>.yaml`, `plans/index.yaml`, git HEAD (for worktree base), user/direct instructions | `plans/debriefs/<debrief-id>.yaml`, `plans/tasks/<task-id>.yaml` (back-ref: `links.debrief`, state transitions), `plans/briefs/<brief-id>.yaml` (state: dispatched → debriefed), `plans/chanakya-tasks/<task-id>-*.md` (legacy brief fallback), `plans/chanakya-inbox/<task-id>-debrief.md` (legacy), `plans/chanakya-inbox/<task-id>-tests.md` (test cases for test-manifest), `events/<date>.jsonl` |
| `build.md` | Manual build verification at HEAD: green resets debt counter, red auto-bisects and files P0 fix | 151 | `plans/index.yaml`, `plans/chanakya-master.md` (## Build Debt block), git HEAD, xcodebuild infrastructure | `plans/debriefs/<debrief-id>.yaml` (build-check debrief), `plans/chanakya-inbox/<BUILD_ID>-debrief.md` (legacy), `events/<date>.jsonl` |
| `debrief.md` | Direct-debrief (no brief, no worktree, no Argus): capture in-chat bug-fix or quick-change into YAML debrief by scanning transcript + git diff | 135 | Session transcript (prior turns), `git diff HEAD`, user inline-feedback on tests needed | `plans/debriefs/<debrief-id>.yaml`, `events/<date>.jsonl` |
| `push-tf.md` | TestFlight release wrapper: pre-flight task collection → invoke `/pushTFBuild` → post-flight release artifact + debrief | 86 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/releases/*.yaml` (prior TF releases), `plans/chanakya-master.md` (legacy), `/pushTFBuild` skill output | `plans/releases/<release-id>.yaml`, `plans/debriefs/<debrief-id>.yaml` (release-type), `plans/tasks/<task-id>.yaml` (back-ref: `links.release`), `plans/chanakya-inbox/tf-<build>-debrief.md` (legacy), `events/<date>.jsonl` |
| `app-store.md` | App Store submission wrapper (parallel to `push-tf.md`): wraps `/fullSendToAppStore`, appends release artifact + debrief | 90 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/releases/*.yaml`, `/fullSendToAppStore` skill output | `plans/releases/<release-id>.yaml`, `plans/debriefs/<debrief-id>.yaml`, `plans/tasks/<task-id>.yaml` (back-ref), `events/<date>.jsonl` |
| `test-suite.md` | Run unit/UI/all test suites on demand; surfaces coverage + failure summary | 81 | Test target structure (`*Tests/`, `*UITests/`), `xcodebuild test` infrastructure | Terminal test report, `events/<date>.jsonl` (test_run event) |
| `worker.md` | Fleet pane mode: claims slot atomically, starts background watch loop, spawns fresh `claude -p "/achilles <id>"` per dispatched task | 58 | `.runtime/achilles-inbox/queue/*.json` (work queue), `git worktree list`, filesystem heartbeat markers | `.runtime/achilles-inbox/<slot>/state.jsonl`, `.runtime/achilles-inbox/<slot>/log.jsonl`, `events/<date>.jsonl` |
| `group.md` | Composite: execute implementation + unit + UI tests sequentially for a single task group | 36 | Task-id + suffix (e.g. `T001`, `T001a`, `T001c`), briefs for each | (delegates to task mode multiple times) |
| `next.md` | Auto-pick highest-priority ready task (or top N) and execute | 33 | `plans/index.yaml`, `plans/tasks/*.yaml`, `plans/briefs/*.yaml` | (delegates to task mode) |
| `studio-feedback.md` | Capture studio-internal issues (wrapper bug, brief-template defect, rule gap) | 26 | Conversational description of issue, severity/scope/kind judgments | `~/.dev-studio/generic-dev-studio/feedback-inbox/<source-project>/<ts>-<kind>-<slug>.md` |

**Achilles total**: 10 mode packs, 1036 lines

---

## Argus — Reviewer Agent (Router)

### 1. Router Summary

**SKILL.md**: 54 lines | **Version**: 1.1.0 | **Mode dispatch**: Two-stage routing. **Trigger phrases** (description + dispatch table): "spec-compliance" (Stage 1 only: does diff match brief?), "code-quality" (Stage 2 only: cross-file regression, edge cases, secrets, staleness, tests). Default: run both sequentially (spec-compliance first; on approved/flagged, then code-quality; on blocked, skip code-quality).

### 2. Mode Pack Inventory

| Mode | Purpose | Lines | Explicit Inputs | Explicit Outputs |
|------|---------|-------|-----------------|------------------|
| `spec-compliance.md` | Stage 1: narrow scope-match judgment — does diff implement exactly what brief asked for (no extra, no missed)? 5 checks: scope match, requirement coverage, over-building, under-building, brief-diff semantic coherence | 138 | `plans/briefs/<brief-id>.yaml` (brief spec), `plans/tasks/<task-id>.yaml` (size + type), Achilles worktree (diff extracted by `argus-diff-extract.sh`) | `events/<date>.jsonl` (`review_requested` stage: spec, `review_{approved,flagged,blocked}` stage: spec) |
| `code-quality.md` | Stage 2: cross-file regression risk, edge-case coverage, diff anomalies, secrets in diff, base-branch staleness, test-run (M/L only, TDD two-runs). 6 checks + size-driven test strategy. Writes `review@1.1.0` artifact. Week 1 posture: only staleness + secrets block; rest flag | 186 | `plans/tasks/<task-id>.yaml`, `plans/briefs/<brief-id>.yaml` (context only), Achilles worktree (diff), `xcodebuild test` (M/L/TDD size only) | `plans/reviews/<review-id>.yaml`, `plans/tasks/<task-id>.yaml` (back-ref: `links.reviews` append), `events/<date>.jsonl` (`review_requested` stage: quality, `review_{approved,flagged,blocked}` stage: quality) |

**Argus total**: 2 mode packs, 324 lines

---

## Contract / Schema References

### Chanakya References
- `_shared/contracts/agent-boot.md`
- `_shared/contracts/brief-formats/impl-brief.md`, `unit-test-brief.md`, `integration-test-brief.md`, `ui-test-brief.md`, `tdd-brief.md`
- `_shared/contracts/debrief-format.md`
- `_shared/contracts/events.md`
- `_shared/contracts/worker-report.md`
- `_shared/patterns/chanakya-principles.md`
- `_shared/patterns/dual-write-transition.md`
- `_shared/patterns/router-pattern.md`
- `_shared/patterns/singleton-invariants.md`
- `_shared/rules/cleanup-policy.md`
- `_shared/rules/debt-tracking.md`
- `_shared/rules/localization-rules.md`
- `_shared/schemas/brief.md` (brief@3.1.0)
- `_shared/schemas/debrief.md` (debrief@2.0.2)
- `_shared/schemas/feedback.md`
- `_shared/schemas/master-plan.md`
- `_shared/schemas/review.md` (review@1.1.0)
- `_shared/schemas/round.md` (round@1.0.0)
- `_shared/schemas/task.md` (task@1.0.0)
- `_shared/schemas/test-flow.md`
- `_shared/state-machines/feedback-lifecycle.md`
- `_shared/state-machines/task-lifecycle.md`

### Achilles References
- `_shared/contracts/agent-boot.md`
- `_shared/contracts/build-message-format.md`
- `_shared/contracts/debrief-format.md`
- `_shared/contracts/events.md`
- `_shared/contracts/worker-report.md`
- `_shared/patterns/dry-run.md`
- `_shared/patterns/dual-write-transition.md`
- `_shared/patterns/router-pattern.md`
- `_shared/patterns/singleton-invariants.md`
- `_shared/rules/localization-rules.md`
- `_shared/schemas/brief.md` (brief@3.1.0)
- `_shared/schemas/build-debt.md`
- `_shared/schemas/debrief.md` (debrief@2.0.1–2.0.2)
- `_shared/schemas/release.md` (release@1.0.0)
- `_shared/schemas/review.md` (review@1.1.0)
- `_shared/schemas/task.md` (task@1.0.0)
- `_shared/state-machines/release-lifecycle.md`

### Argus References
- `_shared/contracts/events.md`
- `_shared/patterns/dual-write-transition.md`
- `_shared/rules/review-rules.md`
- `_shared/schemas/review.md` (review@1.1.0)

---

## Host-Coupling Hotspots

**SessionStart reference**: `chanakya/modes/inbox-sweep.md:100` — "Also auto-runs on SessionStart here (`.claude/settings.json`)."

**`claude -p` references**:
- `achilles/modes/worker.md` — Fleet worker mode spawns fresh `claude -p "/achilles <id>"` per task; parent session is operator wrapper
- `achilles/modes/task.md` — "One-shot `claude -p` subagent (`scripts/achilles-worker.sh`)" when `ACHILLES_AUTONOMOUS=1`
- `achilles/modes/studio-feedback.md` — "Subagent emission discipline (one-shot `claude -p "/achilles <task-id>"`)"

**Agent tool reference**: `achilles/modes/task.md` Step 8.5 — "Argus runs in **two sequential stages** (both via Claude's Agent tool — not reachable from shell)"

**subagent references**:
- `argus/SKILL.md` and both stage mode packs: "`obra/superpowers/subagent-driven-development` measured..." — two-stage split motivation

---

## Cross-Agent References

**Achilles → Argus**:
- Task mode Step 8.5 auto-invokes `scripts/argus-dispatch.sh` (mandatory pre-merge gate for all merge paths except build.md, test-suite.md)
- Reads `plans/reviews/<review-id>.yaml` (post-dispatch) to resolve verdict

**Chanakya → Achilles**:
- `brief.md`: generates briefs that Achilles consumes
- `ship.md`: generates dispatch plan; briefs pending tasks; writes queue entries for fleet-mode worker
- `status.md`: suggests `/achilles push-tf` when tasks have merged since last TestFlight

**Chanakya → Argus** (indirect):
- `inbox-sweep.md` Step 0A: detects Argus-skip condition; emits `review_pending` event
- Auto-files follow-up tasks on `review_flagged` event

---

## Mode Packs Referencing Test-Mode-Pack Fixtures

No explicit test-mode-pack fixture references found in any mode pack per Phase 2.6.6 rule. Fixtures pattern appears in `test-suite.md` (mentions "existing test helpers, mocks, fixtures; check for a shared mock/stub library") but as a read operation, not a fixture dependency declaration.

---

## Mode Pack Inventory Totals

| Agent | Count | Total Lines |
|-------|-------|------------|
| Chanakya | 16 | 1751 |
| Achilles | 10 | 1036 |
| Argus | 2 | 324 |
| **Total** | **28** | **3111** |

---

## Summary

Three agents, 28 mode packs, ~3.1k lines of router + mode specification. Chanakya is the orchestrator (status, planning, briefing, dispatch, verification, feedback); Achilles is the executor (task implementation, build verification, releases, debrief capture); Argus is the pre-merge gate (two-stage: spec-compliance then code-quality). All agents emit to a shared event log; Chanakya processes events on sweep. Phase 2.6 dual-write transition is active (legacy markdown + new YAML in parallel until Commit H cutover). No test-mode-pack fixture dependencies declared. Host coupling: SessionStart hook in inbox-sweep, `claude -p` subagent dispatch in worker/task modes, Agent tool for Argus invocation from Achilles.
