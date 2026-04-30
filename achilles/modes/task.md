---
name: Achilles Task
description: Execution pipeline for brief-based and direct-mode work. Handles every task type (feature / bugfix / refactor / test-* / debug) via the shared Step 1–11 pipeline — size-driven build gate, mandatory Argus pre-merge, merge-lock, debrief.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 2700
dry_run: true
reads:
  - plans/index.yaml                               # post-migration task + brief index
  - plans/tasks/<task-id>.yaml                     # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/<brief-id>.yaml                   # post-migration brief artifacts (schema: _shared/schemas/brief.md)
  - plans/reviews/<review-id>.yaml                 # argus verdict resolution (schema: _shared/schemas/review.md)
  - events/<date>.jsonl                            # via scripts/read-events.sh
writes:
  - plans/debriefs/<debrief-id>.yaml               # canonical (schema: _shared/schemas/debrief.md, debrief@2.0.1, mode: task)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.debrief + state transitions per _shared/state-machines/task-lifecycle.md
  - plans/briefs/<brief-id>.yaml                   # brief state transition dispatched → debriefed per _shared/state-machines/brief-lifecycle.md
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/tests/<task-id>-tests.md                 # test-case artifact (read-write surface for test-manifest)
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Task Execution (`/achilles <task-id>` and `/achilles` bare)

Primary Achilles mode. Executes either a Chanakya-generated brief (`/achilles <task-id>`) or direct user instructions (`/achilles` with free-text). Both paths share the same pipeline; brief mode just starts from a richer spec. Flags `--wait`, `--force-build`, `--ignore-build-debt`, `--dry-run` apply here.

This mode covers all task types (`feature` / `bugfix` / `refactor` / `direct` / `test-unit` / `test-integration` / `test-ui` / `test-tdd` / `debug`) because they share worktree isolation, self-review, Argus gate, and merge scaffolding. The Step 4 sub-steps branch on task type.

---

## Autonomous vs. Interactive

Check `$ACHILLES_AUTONOMOUS` at the start of every session:

| Value | Meaning | Interaction rule |
|---|---|---|
| unset / `0` (default) | Interactive — user is at the keyboard | Asking clarifying questions is OK when a default isn't obvious |
| `1` | One-shot `claude -p` subagent (`scripts/achilles-worker.sh`) | **Never ask.** Pick the obvious default, proceed, document the assumption in the debrief's `## Assumptions` block |

The worker script exports `ACHILLES_AUTONOMOUS=1` automatically. `--wait` is the only sanctioned pause in autonomous mode and only applies to Step 6, not to brief-interpretation questions.

**Obvious-default pattern.** When the brief is ambiguous:

1. Identify the lowest-risk default consistent with the brief's spirit and the codebase's patterns.
2. Proceed with that default — do not ask.
3. In the debrief's `## Assumptions` block, record the ambiguity, chosen default, reason, and contrastive alternatives rejected. Example:
   ```
   ## Assumptions
   - Brief said "show error if fetch fails" without specifying UX. Chose inline banner (matches T124's pattern in same module) over modal alert. Alternatives rejected: modal (breaks flow), silent log (hides signal).
   ```
4. If the assumption turns out wrong on review, a follow-up task corrects it. Cheaper than blocking the slot.

**When no obvious default exists** (rare — usually a brief gap, not real ambiguity): write the debrief with `state: blocked` and the specific question, emit a `task_awaiting_user` event so Chanakya's Step 0E routes a push notification, exit. The worker's missing-debrief detector won't trip because the debrief is written.

**Never** end a session with no debrief in autonomous mode. That's what the silent-stuck detector catches, and it means the task costs a full dispatch cycle without any record of what happened. The debrief is the communication channel — use it.

---

## `--dry-run` mode (Phase 2.5 pilot)

`/achilles <task-id> --dry-run` runs the full pipeline with **every write replaced by a log line**. Reads, LSP, static analysis, and computed decisions run normally. Writes, event appends, merges, and external side effects do not. Contract: `_shared/patterns/dry-run.md`.

Set `DRY_RUN=1`. Every extraction script honors it — logging target + idempotency key on stderr, skipping the real mutation. Step 4 emits `DRY-RUN write path=…` for each planned file. Step 6 lsp-only runs normally (read-only); full-green logs the `xcodebuild` and skips it. Step 8.5 emits `DRY-RUN skip argus reason=not-yet-supported` and proceeds as if `approved` (Argus doesn't support `--dry-run` yet). Step 9 logs the staged debrief write; Step 10 logs the checkout/merge/worktree-remove/DerivedData-clean sequence; Step 10.5 logs the finalize state flips. Events buffer to `LEDGER_DRY_RUN_EVENTS`; print the buffer (`DRY-RUN events (N):`) before Step 11.

Exit codes: `0` — dry-run ran to completion; `2` — dry-run surfaced a blocker (ambiguous brief, LSP errors, would-block at a gate). Idempotency keys match wet-run byte-for-byte so dry-run output is `diff`-friendly against wet-run artifacts.

---

## Execution Pipeline

### Step 1 — Load spec

```bash
eval "$(scripts/task-load-spec.sh <task-id-or-empty>)"
```

Sets `TASK_MODE` (`brief` | `direct`), `BRIEF_PATH`, `BRIEF_UUID`, `SIZE`, `TYPE`, `BASE_BRANCH`, `ACCEPTANCE_JSON`. Resolves the YAML brief at `plans/briefs/<brief-id>.yaml`. Exits 2 with a helpful hint when a non-empty task-id has no brief — surface the message to the user and stop. Exits 5 when the task is in a terminal state (`merged` / `user-verifying` / `verified` / `archived`) — re-dispatch is refused (#263) to prevent duplicate worktrees, second debriefs, and re-runs of release actions in build / push-tf modes. Exits 6 when the brief is not `ready`; run the authoring step named in the error, or set `ACHILLES_ALLOW_NON_READY_BRIEF=1` only for intentional recovery. The user may override terminal-state refusal with `ACHILLES_REOPEN=1` (writes a follow-up debrief on the existing task) or escalate to `/chanakya reopen <task-id>` once the formal reopen lifecycle (#252) lands.

Read the brief body at `$BRIEF_PATH` for the narrative context. If the brief lists `## Required Skills`, invocation is MANDATORY — load them before Step 4. Additional skills are routed at Step 4.0 via `_shared/primitives/design-time-skill-routing.md`. If a listed skill is unavailable in the current host, surface via `report_state: needs_context` rather than proceeding without it.

**Skill-adherence tracking (#220 A2-2).** At Step 1, record two lists:

- `SKILLS_REQUIRED` — skill names listed under `## Required Skills` in the brief body (parse once; empty list if no section present).
- `SKILLS_INVOKED` — starts empty; **each time you invoke a `/skill-name` command during this session**, append the name. Maintain throughout Steps 4–5.

Both live in-context only. They feed `debt.skills_unused` at Step 11.

**`BRIEF_SLICE=summary` fallback (#256).** When the env var is set (caller is a sweep / dispatch decision / context-budget-tight subagent), read only the brief's `summary` field (`yq -r '.summary // ""' "$BRIEF_PATH"`) instead of the full body. Skip the body and the `## Required Skills` parse — both belong to the full-brief path. Emit `brief_summary_used` (per `_shared/contracts/events.md` § Achilles events) carrying `brief_uuid=$BRIEF_UUID`, `summary_tokens_est` (word-count × 1.3 — same heuristic as `scripts/lint-brief.sh`), and `reason=caller_request`. If the summary is null (legacy brief, pre-3.2.0), surface `report_state: needs_context` and stop — do not silently fall back to a full read; the caller asked for the slice for a reason. The summary slice is sufficient for sweep gating, dispatch-readiness checks, and status display, but **not** for execution work — Step 4 onward MUST run from the full brief, so callers that pass `BRIEF_SLICE=summary` are by contract not driving the execution pipeline.

Record `WAIT_FOR_USER` (from `--wait`, else `no`). Don't prompt — the flag is the only opt-in.

### Step 1.5 — Build-debt gate

```bash
scripts/task-build-debt-gate.sh ${IGNORE_BUILD_DEBT:+--override} || exit $?
```

No flag → silent pass. Flag present without `--override` → exit 2 and stop (the script prints the user-facing message). Flag + `--override` → warn on stderr, emit `build_debt_blocked` with `override_attempted: true`, proceed. See `~/.claude/skills/_shared/schemas/build-debt.md` for counter thresholds + banner text.

### Step 2 — Claim the task

```bash
scripts/task-claim.sh "$TASK_UUID" "$BRIEF_UUID" "$SIZE"
```

Flips `tasks/<uuid>.yaml` to `in-progress` and `briefs/<uuid>.yaml` to `dispatched`. Emits `brief_started`. Direct mode passes empty `$BRIEF_UUID` and the brief transition is skipped.

**Duplicate-claim guard (#221).** Before mutating state, the script checks whether the brief is already `dispatched` with a live worktree at `~/.dev-studio/$PROJECT/worktrees/$TASK_UUID`. If so, it exits `4` with a descriptive message — two Achilles sessions cannot hold the same brief. Recovery options:

| Override | Effect |
|---|---|
| `--steal` flag | Force-transfers the claim; warns on stderr. |
| `ACHILLES_RECLAIM_OK=1` | Env-based override; same effect as `--steal`. |

If the worktree is gone (orphan: Achilles crashed without cleanup), the script detects the stale claim and reclaims automatically. On a successful claim, a sidecar at `plans/briefs/<brief-uuid>.claim` records `worker_id` and `claimed_at`; it is removed by `task-merge.sh` at Step 10. See `_shared/state-machines/brief-lifecycle.md §Re-claim rules` for the full decision matrix.

### Step 3 — Isolate: branch from a clean slate

```bash
eval "$(scripts/task-worktree-setup.sh <task-id> <repo-root> "$BASE_BRANCH")"
```

Uses the brief's explicit `BASE_BRANCH` when present; otherwise captures `ORIG_BRANCH` + `ORIG_HEAD` from the committed tip (leaves the user's uncommitted work in the main checkout untouched), creates the worktree at `~/.dev-studio/$PROJECT/worktrees/<task-id>` on branch `achilles/<task-id>`, and exports `PROJECT`, `ORIG_BRANCH`, `ORIG_HEAD`, `WORKTREE`. All subsequent work runs inside `$WORKTREE`. Honors `DRY_RUN`.

### Step 4 — Implement

Work methodically through the brief's acceptance criteria (or the user's direct-mode description). Small logical commits. Check off criteria as you complete them.

**Task type awareness:** the brief's `Type:` field determines sub-step:

- **`feature` / `bugfix` / `refactor` / `direct`** → implementation task. Step 4A.
- **`test-unit` / `test-integration`** → Step 4B.
- **`test-ui`** → Step 4C.
- **`test-tdd`** → Step 4D.
- **`debug`** → Step 4A semantics with an emphasis on regression coverage. Reproduce the bug, isolate the cause, write a regression test first if possible, then fix.

#### Step 4.0 — Design-time skill routing (runs BEFORE the first production edit)

Read `_shared/primitives/design-time-skill-routing.md` and the matching stack routing table (Swift: `_shared/rules/swift-skill-routing.md`). Match the anticipated diff shape against the signal column; load every matching skill; apply guidance while writing. Carry a 2–4-line "Design choices" note in the first commit message per the primitive's commit-note invariant.

Briefs with an explicit `## Required Skills` section take precedence — load those plus whatever the routing table adds.

#### Step 4A — Implementation with testability

When the brief includes `## Testability Requirements`:

1. **SOLID checkpoints.** Before writing code, review the brief's architecture + test seams:
   - **SRP:** one purpose per type. >~100 lines → evaluate whether it has multiple responsibilities.
   - **OCP:** protocols + composition where the brief specifies extensibility.
   - **LSP:** protocol conformances must be substitutable against the brief's mock strategy.
   - **ISP:** focused protocols — only methods the consumer actually calls.
   - **DIP:** initializer injection per the brief's Test Seams section.

2. **Accessibility identifiers** (when the brief specifies an identifier file): enum namespace `AccessibilityID.<Screen>.<element> = "<module>.<screen>.<element>"`; apply via `.accessibilityIdentifier(...)`; cover interactive elements (buttons, text fields, toggles, pickers) + state-conveying display elements; commit the identifier file as a separate early commit — UI test tasks may depend on it.

3. **Localization** (brief has `### Localization`): follow `~/.claude/skills/_shared/rules/localization-rules.md`.

4. **Expose test seams** — define the protocol with clear docs, make production conform, use initializer injection (not service locators), extend existing seams rather than paralleling.

Don't over-engineer. Pure functions need no protocols. Simple value types need no abstraction. Only add seams where the brief calls for them or where a dependency genuinely needs substitution in tests.

#### Step 4B — Writing unit / integration tests

0. **Check the parent brief's `churn_layer`** per `_shared/rules/test-strategy.md`. If `ui` or `exploratory`, stop — unit tests are the wrong layer; escalate to Chanakya rather than silently writing unit tests that will calcify.
1. **Read the parent implementation first.** Check that the parent task (from `Group:` field) is `done` / `verified`. If still in-progress, stop: "Parent task <id> hasn't landed yet — cannot write tests against unmerged code."
2. **Scan existing tests.** Find the test target structure (`*Tests/`, `*UITests/`); identify reusable helpers, mocks, fixtures; check for a shared mock/stub library.
3. **Follow the brief's structure:** file placement per `## Test Organization`; descriptive names that read as specifications; Arrange/Act/Assert; no shared mutable state; mock external dependencies for unit tests, only external boundaries for integration tests.
4. **Refactoring awareness:** extract shared helpers after 3+ duplications; note a common-test-utilities refactor as a follow-up; don't refactor production code in a test task.
5. **Run the tests.** Include execution results in the debrief.

#### Step 4C — Writing UI tests

1. **Read the accessibility identifier contract.** If identifiers are missing, stop: "Parent task <id> is missing accessibility identifiers for <elements> — cannot write reliable UI tests."
2. **Use page object pattern** (or create screen abstractions): one screen object per major screen; encapsulate element queries by accessibility ID; expose user-level actions (`func tapFilter(_ name: String)`); reuse across tests.
3. **Flow tests per the brief:** happy path first; edge cases (empty, error, interruptions); regression tests for bug fixes; independent tests (reset app state in `setUp`).
4. **Remove redundancy.** If a new test covers the same ground more thoroughly, remove the old one. Note in the debrief.
5. **Run the tests** on the project's standard test destination.

#### Step 4D — TDD test task

1. The brief defines **expected interfaces** (protocols, signatures, behaviors) — no implementation yet.
2. Write tests against those interfaces. Tests fail (no implementation).
3. Define placeholder protocols/stubs that satisfy compilation but fail assertions.
4. Commit the failing tests. The implementation task (dependent on this task) will make them pass.
5. List the exact interfaces the implementation must satisfy in the debrief.

**Build discipline by task size:**

- **XS / S** (≤2 files, ≤~50 lines, no escalation triggers): rely on `swift-lsp` during implementation. No `xcodebuild`. Step 6 is LSP-only.
- **M / L** (or anything hitting escalation triggers — see Step 6): opportunistic building during implementation is allowed, but each build goes through Step 6's lock + per-task DerivedData.

If size is ambiguous, **treat it as M** — err toward more compiler feedback, not less.

### Step 5 — Self-review pass

Before asking the user to look, review your own diff.

**Step 5.0 — Re-invoke Step 4.0 skills against the actual diff.** Per `_shared/primitives/design-time-skill-routing.md`: walk the stack routing table against the real diff, run each matched skill's review lens, record per-skill verdict (`clean` / `minor` / `material`) in the debrief's `## Self-Review` block. A `material` finding triggers fix-then-rerun — don't rationalize it away.

**Step 5.1 — Invoke the `simplify` skill** on changed files. Target: duplication, dead code, over-abstraction; obvious regressions in neighboring paths; missing error handling at genuine boundaries; naming + Swift API guideline fit.

**Testability review** (implementation tasks with `## Testability Requirements`):
- Verify all brief-listed accessibility IDs are defined + applied.
- Verify test seams are exposed (protocols defined, DI wired).
- Check for new singletons / static mutable state in business logic (none).
- Confirm the identifier enum file is committed separately from implementation.
- Apply the localization self-review checklist when the brief has `### Localization`.

**Test review** (for test tasks): independent tests (no shared mutable state), descriptive names, no flaky patterns (timing assertions, simulator-state reliance), mocks minimal.

Fix what you find. **One iteration — structural cap (#222 A2-5).**

A material finding triggers one fix-and-rerun. If the second pass still surfaces material findings, stop. Set `debt.self_review_unconverged: true` in `$FIELDS_JSON`; `report_state` escalates to `done_with_concerns` at Step 11. Emit `self_review_iterated` (see `_shared/contracts/events.md`) whenever `iteration >= 2`.

**Test-coverage delta gate (#222 A2-6)** — feature, refactor, and direct tasks only; skip for bug-type and test-only tasks. After the fix pass: if the diff touched non-test implementation files but no test file was modified or added, populate `debt.tests_unaffected: [<changed symbols or file paths>]` in `$FIELDS_JSON` and escalate `report_state` to `done_with_concerns` at Step 11.

**Self-review artifact (#222 A2-4).** After the fix pass (or the single pass when no material finding), emit:

```bash
SELF_REVIEW_PATH=$(scripts/task-write-self-review.sh "$TASK_ID" "$SELF_REVIEW_JSON")
```

`$SELF_REVIEW_JSON` carries `iteration`, `converged`, `skill_verdicts`, `diff_stats`, `findings`, `coverage_delta_checked`, `coverage_delta_found`. Full schema: `_shared/schemas/self-review.md`. Argus Stage 2 reads this artifact.

### Step 6 — Build gate (size-driven, serialized across Achilles instances)

Select the gate from the brief's `Size:` field (or infer for direct mode). The judgment lives here; execution lives in the script.

**Default by size:** XS / S → `lsp-only`; M / L → `full-green`; direct mode (no size) → `full-green`.

**Escalation triggers — force `full-green` regardless of declared size.** Inspect the diff (`git diff --stat achilles/<task-id>` + full diff); any of these escalate: new `import` or `@_implementationOnly` line; `public` / `open` declaration added, removed, or changed; `protocol` / `extension` adding conformance; `actor` / `@MainActor` / `nonisolated` / `async` / `throws` signature change; generic parameter added or removed; changes to `Package.swift` / `Podfile` / `.xcconfig` / `project.pbxproj`; any new, deleted, or renamed file.

`--force-build` → force `full-green`. `--ignore-build-debt` → keeps default gate (the override bypasses the debt block, not the gate).

**Package-only fast path (#110).** Before the size-driven gate, try `swift-test-gate.sh`. When the diff lives entirely under a single SPM package directory it runs `swift test --package-path <pkg>` (no simulator, no xcodebuild lock) and the verdict stands; otherwise it exits 1 and the size-driven gate runs as the fallback. Skipped under `--force-build` since the user is opting in to xcodebuild explicitly.

**Snapshot reference sync (#113).** If the diff touches snapshot tests, pull the canonical reference images down first so the assertion compares against the canonical bytes rather than whatever is stale on this machine. Detection is name-based (`__Snapshots__/` directory or a path matching `*Snapshot*`), framework-agnostic. `snapshot-sync.sh` is a silent no-op when no canonical node is registered or reachable — infrastructure prep that will become load-bearing once the project adopts a snapshot framework.

```bash
if git diff --name-only "$(git merge-base HEAD "origin/${BASE:-main}")" HEAD \
   | grep -qE '(__Snapshots__/|Snapshot)' ; then
  scripts/snapshot-sync.sh
fi

if [ "${FORCE_BUILD:-0}" = "0" ]; then
  scripts/swift-test-gate.sh "$TASK_ID" "$WORKTREE"
  rc=$?
  case $rc in
    0) GATE=swift-test ;;
    1) scripts/task-build-gate.sh "$GATE" "$TASK_ID" "$WORKTREE" "$SCHEME" "$DESTINATION" "$PROJECT_RELPATH" ;;
    *) exit $rc ;;
  esac
else
  scripts/task-build-gate.sh "$GATE" "$TASK_ID" "$WORKTREE" "$SCHEME" "$DESTINATION" "$PROJECT_RELPATH"
fi
```

`$PROJECT_RELPATH` (#238) is the worktree-relative path to the canonical `.xcodeproj` or `.xcworkspace`, sourced from `_shared/primitives/turnip-project-config.md`'s `Project (worktree-relative)` field. Pinning prevents xcodebuild from auto-picking a stub project at the worktree root in multi-project repos. Pass empty string when the field is absent — the gate omits `-project` and falls back to xcodebuild's auto-detection (current behaviour for single-project repos).

The script emits `build_check_started` on entry and `build_check_passed` / `build_check_failed` on exit, or `build_check_aborted` if it exits between start and the normal terminal (arg failure, signal, unhandled exception — see events.md #106). `build_check_started` carries an `attempt` counter: 1 for a cold start, 2+ when a prior build-check for the same task emitted `started` without a paired terminal (e.g. a process that died, then got re-invoked). The counter resets on any terminal event. Full-green owns the atomic `mkdir`-based xcodebuild slot lock under `~/.dev-studio/.runtime/xcodebuild-lock/<node-id>/slot-<n>/` — scoped per dispatch target so a laptop-local build and a mini-dispatched build don't serialize on each other — with 45-minute per-slot staleness reclaim, per-task `-derivedDataPath`, and a trap that releases the slot on any exit. Slot count comes from the node's `parallel_build_slots` field in `nodes.json` (default 1; #218 Stage C / #268) — at 1 it's a single-holder lock pinned to `slot-1/`, at N>1 up to N concurrent holders run on distinct slot subdirs. The lock is fed by a per-node FIFO queue at `~/.dev-studio/.runtime/build-queue/<node-id>/` (#266 / #218 Stage A): every full-green invocation enqueues an entry on entry and waits until it is in the first `parallel_build_slots` positions before attempting `mkdir` on a slot, so concurrent invocations acquire in enqueue order rather than racing. The queue emits `build_queue_position` once per invocation with `{position, depth, slots}`; orphaned entries get GC'd after 45 min, matching the lock's own staleness threshold. Priority logic (TF/AS preempt) lands in #218-B. A separate per-task lock under `<project>/.runtime/state/build-check-locks/<task-id>/` (60-min staleness reclaim) refuses concurrent invocations for the same task — exit `4`, no `started`/`aborted` emitted (#209). Exit codes: `0` green, `2` red, `3` locked-out (30-minute wait exceeded — applies to both queue head-wait and inner mkdir-lock acquire), `4` refused (concurrent same-task invocation).

**Node dispatch (#112, #137).** Both `swift-test-gate.sh` and `task-build-gate.sh` full-green mode route through `scripts/node-pick.sh` — the swift-test gate asks for a `swift-test`-tagged node, the full-green gate asks for `xcodebuild`. When a healthy remote node answers (see `~/.dev-studio/.runtime/nodes.json`), the compile + test cost lands on that node over SSH. When no remote is registered, reachable, or role-matching, `node-pick` returns `local` and the gate runs on the laptop with no behavioural change. Every fallback emits a discriminating `node_fallback` event (so the unreachable-but-configured case is loud, per REVIEW.md R14), and every gate event carries `studio.dispatch.{node,role,reason,xcode_version}` so debug sessions can distinguish local-red from mini-red — and a fallback-because-the-mini-was-down from a deliberate local pin — without guessing. Successful remote Xcode build/test events also carry the node's `remote_derived_data_path`; set `NODE_ARTIFACT_RETRIEVE=1` to pull remote `.xcarchive` / `.xcresult` directories back to local DerivedData. See `_shared/contracts/events.md §Dispatch events` for the field shape.

**Xcode-drift guard (#136).** Before any remote dispatch, the gates call `scripts/check-xcode-parity.sh` to compare laptop ↔ target-node Xcode versions against the cache from `node-parity.sh` (refreshed lazily on a 7-day TTL). MAJOR drift blocks; minor and patch drift warn-and-allow. Set `STUDIO_IGNORE_XCODE_DRIFT=1` to override a major-drift block in the rare deliberate-divergence case (e.g. validating a build on the older SDK). On block, the gate exits 2 with reason `xcode_major_drift`; no lock is acquired, no SSH cost is paid.

**Red-gate handling:** stop — do **not** merge; leave branch + DerivedData intact; surface to user. If the fix is straightforward, fix, re-run Steps 5–6. Don't spiral. Never bypass the lock.

Record `GATE = "lsp-only" | "full-green" | "swift-test"` for the debrief's `## Build Verification` block.

### Step 7 — Write test cases

```bash
TEST_YAML=$(scripts/task-write-test-cases.sh "$TASK_ID" "$CASES_JSON")
```

Twin-writes `plans/tests/<task-id>-tests.md` (Chanakya's `/chanakya test-manifest` reads this) and returns the YAML block for splicing into the debrief's `tests.added:` field. Each case carries preconditions, steps, expected result. Runs regardless of `WAIT_FOR_USER`.

### Step 8 — Optional wait for user feedback

**`WAIT_FOR_USER=no` (default):** append `## Follow-up Tasks` — "Manual verification of <task-id> — user will test later." Proceed to Step 9.

**`WAIT_FOR_USER=yes` (from `--wait`):** prompt — "T001 implementation is done and the build is green. Test cases are at `<task-id>-tests.md`. Reply within 10 min with feedback, or I'll auto-merge." — then call `ScheduleWakeup` with `delaySeconds: 600` resuming Step 8 in timeout-merge mode. End the turn. Three resumptions:
- **User replies before wake:** iterate. Re-run Steps 5–6 if non-trivial. Loop back to Step 8. Cancel the pending wake; ignore it if it fires.
- **User approves before wake:** proceed to Step 9.
- **Wake fires with no reply:** append `## Follow-up Tasks` ("no reply within 10-min window"), proceed to Step 9.

Cleanup is guaranteed in every non-rejected branch — the wake exists so `--wait` cannot hang forever.

### Step 8.4 — Base-branch refresh (pre-review)

Only if Step 6 is green and the task is not on the XS-trivial path that skips Argus entirely. Argus blocks on base staleness in Stage 2 — cheap to avoid by refreshing the worktree first on drift above a small threshold.

```bash
scripts/achilles-refresh-base.sh "$TASK_ID" "$WORKTREE" "$ORIG_BRANCH" || exit $?
```

The script fetches `origin/$ORIG_BRANCH`, counts commits behind, and no-ops if below `ACHILLES_BASE_REFRESH_THRESHOLD` (default `2`). Above threshold it `git merge --no-ff origin/$ORIG_BRANCH` into the worktree branch — merge, not rebase, to match Step 10's convention and to avoid rewriting mid-task commits the debrief references. Exit codes: `0` fresh or refreshed cleanly; `2` merge conflict (script aborted the merge; worktree clean); `3` missing args / worktree gone.

- **Clean refresh:** emits `base_refreshed` with `commits_pulled`. Proceed to Step 8.5.
- **Fresh (below threshold):** silent no-op, no event. Proceed to Step 8.5.
- **Conflict:** emits `base_refresh_conflict`. Do **not** call Argus. Surface to user; include the conflict in the debrief (`report_state: blocked`, `debt.base_refresh_conflict: true`). Do not auto-resolve.

Override: `ACHILLES_BASE_REFRESH_THRESHOLD=<int>` env var (e.g. `0` disables the no-op band — always refresh on any drift; large value effectively disables the pre-refresh). Honors `DRY_RUN`.

### Step 8.5 — Argus pre-merge gate (two stages)

Only if Step 6 is green. **This gate runs on every dispatch path — interactive, worker-mode, `--wait`, `--no-wait`. No exceptions except `build-mode` and `test-suite-mode`.** Autonomous-vs-interactive governs clarifying-question latitude only, not compliance. Self-review has known blind spots (cross-file regressions, test adequacy, base staleness, spec divergence) that persist regardless of whether a human is watching. If Argus is genuinely unavailable, surface as a block and stop before merge.

```bash
eval "$(scripts/task-invoke-argus.sh "$TASK_ID" "$WORKTREE" "$ORIG_BRANCH" "$SIZE")"
```

Emits `review_requested` and exports `ACHILLES_REVIEW_REQUESTED_AT` (carried into the debrief for verdict-timing correlation).

Argus runs in **two sequential stages**, both dispatched via `scripts/dispatch-review.sh`. The script handles host adapter selection (Claude Code / Codex / future), env-scrubs the spawn (no API keys, no GH tokens), validates the handoff payload against `_shared/contracts/handoff.schema.json`, and tails the event log for the verdict — the contract is shell-reachable on every supported host.

#### Stage 1 — spec-compliance

```bash
SPEC_KEY="$TASK_ID:spec:1"
spec_out=$(scripts/dispatch-review.sh "$TASK_ID" spec --idempotency-key "$SPEC_KEY") \
  || { echo "spec-compliance dispatch failed; surface to user"; exit 1; }
eval "$spec_out"   # exports ARGUS_VERDICT=<approved|flagged|blocked>
```

Narrow question: does the diff match the brief?

- **`approved`** or **`flagged`:** proceed to Stage 2. Carry Stage 1 findings forward into the debrief.
- **`blocked`:** do NOT run Stage 2 — the spec is wrong at the structural level, re-reviewing code doesn't help. Surface block reason; attempt to fix (see below) or debrief with `report_state: blocked`.

Retry policy: validator rejection never auto-retries (per `_shared/contracts/idempotency.md`). Transient failures (timeout, spawn fork) may retry once with `--attempt 2` and a fresh idempotency-key suffix.

#### Stage 2 — code-quality

Only if Stage 1 returned `approved` or `flagged`.

```bash
QUAL_KEY="$TASK_ID:quality:1"
qual_out=$(scripts/dispatch-review.sh "$TASK_ID" quality --idempotency-key "$QUAL_KEY") \
  || { echo "code-quality dispatch failed; surface to user"; exit 1; }
eval "$qual_out"
```

Broad question: cross-file regression risk, edge cases, diff anomalies, secrets, base staleness, test run (M/L).

- **`approved`:** proceed to Step 9.
- **`flagged`:** proceed to Step 9 (stage debrief), then Step 10 (merge). Include a `## Argus Review` block in the debrief referencing both stages' review files + combined finding count.
- **`blocked`:** do NOT merge. Surface block reason + review file. Attempt to fix — **base staleness:** rebase, re-run Steps 5–8.5; **compile/test failure Achilles can fix:** fix, re-run Steps 5–6, re-run Step 8.5 (both stages); **secrets in diff:** remove, re-commit, re-run Step 8.5; **cannot address:** surface, do not merge, debrief with `report_state: blocked`.

Two `review_approved` / `review_flagged` / `review_blocked` events land per task (one per stage, distinguished by `stage: spec | quality`). Chanakya's inbox sweep reads both — see `chanakya/modes/inbox-sweep.md` Step 0A.

Maximum 3 fix-and-re-review cycles before surfacing to the user as unresolvable (cycle count spans both stages).

### Step 9 — Stage debrief (pre-merge)

Only if Step 6 is green, Argus returned approved or flagged, and the user hasn't rejected.

**Pre-merge order is load-bearing (#249 Phase 2).** The debrief is staged *before* `task-merge.sh` so the merge script can refuse to merge work that has no debrief — closing the silent-merge dark window where a session crash between merge and debrief left Chanakya holding `briefed` forever. Step 11 finalizes the artifact (stamps `merge_sha`, flips task → `merged`, brief → `debriefed`, emits `brief_completed`) after the merge succeeds.

Commit inside the worktree first (unlocked — each worktree has its own index), then stage the debrief:
```bash
cd "$WORKTREE"
git add -A
CALLER_SKILL=achilles-merge safe_git_commit -m "<task-id>: <summary>"   # or several small commits

DEBRIEF_UUID=$(scripts/task-emit-debrief.sh "$TASK_UUID" "$BRIEF_UUID" argus-reviewed "$FIELDS_JSON")
```

Mints a UUIDv7, writes `plans/debriefs/<debrief-id>.yaml` (schema: `_shared/schemas/debrief.md`, `debrief@2.0.1`) at `state: emitted`, sets `tasks/<uuid>.yaml` `links.debrief`, transitions the task to `argus-reviewed` (idempotent — Argus already moved it there). The brief→debriefed transition and `brief_completed` event are deferred to Step 11.

`$FIELDS_JSON` is a JSON object whose keys become debrief YAML fields — `branch`, `commits`, `diff_summary`, `decisions`, `tests`, `testability`, `build_gate`, `build_debt_override`, `debt`, `performance`, `key_learnings`, `known_issues`, `follow_ups`, `open_questions`, `argus_review`, plus `legacy_task_id` for compatibility with older task IDs. `argus_review.status` is Step 8.5's verdict — `approved` / `flagged` / `blocked`; `not-invoked` is only valid on exempted build-mode / test-suite-mode paths, which don't land here. If Argus returned `flagged`, reference the review file + finding count in `argus_review.notes`. Leave `branch.merge_sha` empty — Step 11 stamps it.

**Debrief is load-bearing for worker-mode detection.** The worker wrapper (`scripts/achilles-worker.sh`) treats a `claude -p` exit with `rc=0` and no debrief as a silent-stuck state and routes the task to `rescue/<task-id>-stuck.md`. Any meaningful outcome — completion, blocked, failed — must write a debrief before exit. Clarifying questions exit one-shot subagents cleanly and trip this detector; prefer the autonomous-default pattern instead of asking.

### Step 10 — Commit, merge back, clean up

**Respect `.argus-running` marker.** Before invoking the merge script, if `$WORKTREE/.argus-running` exists a standalone Argus is still reviewing — poll every 30s up to 10 min, then surface to user. Normal Step 8.5 flow clears the marker automatically.

```bash
scripts/task-merge.sh "$TASK_ID" "$WORKTREE" "$ORIG_BRANCH" "Merge <task-id> into $ORIG_BRANCH"
```

The script runs the **#300 composite merge safety gate** before acquiring the project-scoped merge lock under `~/.dev-studio/.runtime/merge-lock/<project>` (30-minute staleness reclaim, 30-minute wait envelope). The gate checks three signals: `build_check_passed`, `review_approved` or `review_flagged`, and a staged `state: emitted` debrief for `$TASK_ID`. Two or three absent signals refuse with exit `4` and emit `merge_safety_blocked`; exactly one absent signal emits `merge_safety_warn` and proceeds. Missing debrief also emits `debrief_missing` (`reason: pre_merge_blocked` or `pre_merge_warn`) for existing sweep surfaces. `--force` is emergency-only and emits `merge_safety_override`. After the gate, the script clears a stale `.git/index.lock` per `_shared/primitives/safe-git.md` (emits `stale_index_lock_removed`), checks out `$ORIG_BRANCH`, fetches best-effort, runs `git merge --no-ff achilles/<task-id>`, removes the worktree, cleans DerivedData, emits `task_merged`. Exit codes: `0` merged, `2` conflict (emits `merge_conflict`; worktree + DerivedData retained), `3` locked-out, `4` composite safety block. Prints `MERGE_SHA=<sha>` on success.

On conflict: branch stays alive, DerivedData kept, surface to user. **Do not force-resolve.** On red build (Step 6): don't call this script — the branch + DerivedData stay for the user to inspect.

### Step 10.5 — Finalize debrief (post-merge)

```bash
scripts/task-finalize-merge.sh "$TASK_UUID" "$BRIEF_UUID" "$DEBRIEF_UUID" "$MERGE_SHA" "$FIELDS_JSON"
```

Stamps `branch.merge_sha` into the staged debrief, transitions the task `argus-reviewed → merged`, flips the brief to `debriefed` (skip in direct-mode), emits `brief_completed`. Idempotent: state transitions no-op on a second invocation; the merge_sha set is value-equal-skip.

`done` ≠ user-verified — Chanakya promotes to `verified` after test-manifest feedback.

Print a short message to the user:

> "**T001 done.** Branched from `<ORIG_BRANCH>`@`<short-hash>`, implemented, self-reviewed, build green, Argus approved/flagged, merged back. Test cases at `<task-id>-tests.md`. Debrief dropped for Chanakya."

### Step 11 — Signal completion; sit idle

Pick a `report_state` for the debrief (set in `$FIELDS_JSON` before Step 9 stages the YAML) from the 4-state worker-report contract (`_shared/contracts/worker-report.md`):

| State | Pick when |
|---|---|
| `done` | Merged clean, Argus approved (or skipped for XS), all `debt.*: false`, no deferred tests |
| `done_with_concerns` | Merged, but at least one of: build debt accrued, tests skipped, Argus flagged, known issues surfaced |
| `blocked` | No merge — hard stop on external dependency, unresolvable state, or Argus `blocked` verdict |
| `needs_context` | No merge — brief missing information (ambiguous spec, absent reference, unstated decision) |


**Skills-unused audit (#220 A2-2).** Compute `SKILLS_UNUSED = SKILLS_REQUIRED - SKILLS_INVOKED` (set difference). If non-empty:
- Set `report_state: done_with_concerns` (or keep `blocked`/`needs_context` if already set).
- Populate `debt.skills_unused: [<list of skill names>]` in `$FIELDS_JSON` before Step 9.

A skill is considered "invoked" if its name appears in `SKILLS_INVOKED`. The check is strict — if you were unable to load a required skill (host limitation), surface via `report_state: needs_context` at Step 1 instead of reaching this point.

Pass `report_state=<value>` to `write_debrief_artifact` (via the debrief path documented in `_shared/schemas/debrief.md`). The helper validates the enum and refuses invalid values.

**Iron Law (REVIEW.md R10).** Never pick `done` to make a red build look green. If xcodebuild did not run or failed, the state is at most `done_with_concerns` (with `debt.build: true`). If tests were skipped, the state is at most `done_with_concerns` (with `tests.skipped_because` populated). Structural honesty — prose cannot paper over a missing field.

```bash
scripts/emit-agent-session-completed.sh achilles task "$TASK_ID" "auto:$TASK_ID" --verdict "$VERDICT"
```

The `auto:<session-id>` form reads the start-ts stamped by `emit-agent-boot.sh` at first-write and computes `now - start`. Every session path (normal dispatch, waived merge, direct, rescue) passes through agent-boot, so `duration_s` is populated unconditionally — no null on waive/direct. Callers that already track wall-clock may pass a pre-computed integer instead.

Supports optional `--tokens-input/--tokens-output/--tokens-cache-read/--tokens-cache-write` flags. Duration alone is still useful when token counts aren't available. See `~/.claude/skills/_shared/contracts/events.md` → "Cross-agent events".

After Step 10.5 + the session-completed event, **sit idle.** Do not self-select the next task. Do not schedule a wake. Do not prompt the user further. Chanakya will process the debrief on its next inbox sweep, read any `review_flagged` events + auto-file follow-ups, and surface to the user via `/chanakya status` or `--auto-sweep`. If the user wants immediate surfacing, they run `/chanakya status`.

---

## Follow-up-Surface Mode (deprecated)

The Step 11 scheduled wake has been removed. Follow-up surfacing is now event-driven via Chanakya's inbox sweep. This section is retained as a no-op placeholder — do not implement scheduled wakes for follow-up surfacing.
