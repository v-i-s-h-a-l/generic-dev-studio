---
name: Achilles Task
description: Execution pipeline for brief-based and direct-mode work. Handles all task types (feature / bugfix / refactor / test-unit / test-integration / test-ui / test-tdd / debug) through the shared Step 1–11 pipeline, including size-driven build gate, mandatory Argus pre-merge review, merge-lock serialization, and debrief.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 6000
dry_run: true
reads:
  - plans/index.yaml                               # post-migration task + brief index
  - plans/tasks/<task-id>.yaml                     # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/<brief-id>.yaml                   # post-migration brief artifacts (schema: _shared/schemas/brief.md)
  - plans/reviews/<review-id>.yaml                 # argus verdict resolution (schema: _shared/schemas/review.md)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-tasks/<task-id>-*.md            # legacy brief fallback until Commit H
  - events/<date>.jsonl                            # via scripts/read-events.sh
writes:
  - plans/debriefs/<debrief-id>.yaml               # post-migration canonical (schema: _shared/schemas/debrief.md, debrief@2.0.0, mode: task)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.debrief + state transitions per _shared/state-machines/task-lifecycle.md
  - plans/briefs/<brief-id>.yaml                   # brief state transition dispatched → debriefed per _shared/state-machines/brief-lifecycle.md
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/chanakya-master.md                       # legacy master-plan status mutation during Phase 2.6 transition
  - plans/chanakya-inbox/<task-id>-debrief.md      # legacy debrief markdown retained during Phase 2.6 transition
  - plans/chanakya-inbox/<task-id>-tests.md        # test-case artifact (read-write surface for test-manifest)
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Task Execution (`/achilles <task-id>` and `/achilles` bare)

Primary Achilles mode. Executes either a Chanakya-generated brief (`/achilles <task-id>`) or direct user instructions (`/achilles` with free-text). Both paths share the same pipeline; brief mode just starts from a richer spec. Flags `--wait`, `--force-build`, `--ignore-build-debt`, `--dry-run` apply here.

This mode covers all task types (`feature` / `bugfix` / `refactor` / `direct` / `test-unit` / `test-integration` / `test-ui` / `test-tdd` / `debug`) because they share worktree isolation, self-review, Argus gate, and merge scaffolding. The Step 4 sub-steps branch on task type.

---

## Autonomous vs. Interactive

Check `$ACHILLES_AUTONOMOUS` at the start of every session:

| `$ACHILLES_AUTONOMOUS` | Meaning | Interaction rule |
|---|---|---|
| unset / `0` (default) | Interactive session — user is at the keyboard | Asking clarifying questions is OK when a default isn't obvious |
| `1` | One-shot `claude -p` subagent (spawned by `scripts/achilles-worker.sh`) | **Never ask.** No user is on the other end. Pick the obvious default, proceed, document the assumption in the debrief's `## Assumptions` block |

The worker script exports `ACHILLES_AUTONOMOUS=1` automatically for every dispatched task. The `--wait` flag is the only sanctioned pause in autonomous mode and only applies to Step 6 (build/test verification), not to brief-interpretation questions.

**Obvious-default pattern.** When the brief is ambiguous:

1. Identify the lowest-risk default consistent with the brief's spirit and the codebase's existing patterns.
2. Proceed with that default — do not ask.
3. In the debrief's `## Assumptions` block, record: the ambiguity, the default chosen, the reason, and the contrastive alternatives rejected. Example:
   ```
   ## Assumptions
   - Brief said "show error if fetch fails" without specifying UX. Chose inline banner (matches T124's pattern in same module) over modal alert. Alternatives rejected: modal (breaks flow), silent log (hides signal).
   ```
4. If the assumption turns out wrong on review, a follow-up task corrects it. Cheaper than blocking the slot.

**When no obvious default exists** (rare — usually a brief gap, not a real ambiguity):

1. Write the debrief with `status: blocked_awaiting_input` and the specific question.
2. Emit a `task_awaiting_user` event so Chanakya's Step 0E routes a push notification (important in away mode — the debrief alone only surfaces on next sweep):
   ```bash
   printf '%s\n' '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"achilles","event":"task_awaiting_user","task":"<task-id>","data":{"question":"<≤200 chars>","brief_excerpt":"<≤200 chars>","mode":"autonomous"}}' >> "$EVENT_FILE"
   ```
3. Exit.

The worker's missing-debrief detector won't trip because the debrief is written. Chanakya processes the event + debrief on next sweep and pushes the question to the user.

**Never** end a session with no debrief in autonomous mode. That's what the silent-stuck detector catches, and it means the task costs a full dispatch cycle without any record of what happened. The debrief is the communication channel — use it.

---

## `--dry-run` mode (Phase 2.5 pilot)

`/achilles <task-id> --dry-run` runs the full pipeline with **every write replaced by a log line**. Reads, LSP, static analysis, and computed decisions run normally. Writes, event appends, merges, and external side effects do not happen. Contract: `_shared/patterns/dry-run.md`.

Set `DRY_RUN=1` for the session when `--dry-run` is passed. Every writable step below branches:

```bash
if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'DRY-RUN write path=%s bytes=%d idempotency_key=%s\n' \
    "$target" "$(printf '%s' "$payload" | wc -c)" "$idem_key" >&2
else
  printf '%s' "$payload" > "$target"
  append_event achilles "$event" "$task_id" "$data"
fi
```

Per-step adaptations under `DRY_RUN=1`:

- **Step 2 — Claim:** log `DRY-RUN write path=<master-plan> …` in place of the status update.
- **Step 3 — Worktree:** log `DRY-RUN git worktree add <WORKTREE> -b achilles/<task-id> <ORIG_HEAD>`; skip the real `git worktree add`. All subsequent file paths under `$WORKTREE` are simulated; edits are computed and logged per file but not written.
- **Step 4 — Implement:** compute the change plan from the brief. For each file that would be written, emit one `DRY-RUN write path=… bytes=<estimated>` line with the planned byte delta (use `wc -c` on the in-memory payload).
- **Step 5 — Self-review:** runs normally; read-only.
- **Step 6 — Build gate:** LSP path runs normally (read-only). `full-green` path logs `DRY-RUN xcodebuild scheme=<s> destination=<d> -derivedDataPath=<tmp>` and skips the real xcodebuild. Build-debt counters are NOT incremented in dry-run.
- **Step 7 — Test cases:** log both write targets (`<task-id>-tests.md` in debrief + standalone artifact). Do not create the files.
- **Step 8 — Optional wait:** dry-run treats `--wait` as a no-op (the scheduled wake is a write).
- **Step 8.5 — Argus:** if Argus does not yet support `--dry-run` (adoption lands in 2.6), emit `DRY-RUN skip argus reason=not-yet-supported` and proceed as if Argus returned `approved`. A real wet-run still invokes Argus — this simulation only.
- **Step 9 — Commit + merge:** log `DRY-RUN commit message=<m>`, `DRY-RUN merge achilles/<task-id> → <base>`, and `DRY-RUN worktree remove <WORKTREE>`. Do not touch the repo state. DerivedData cleanup is also skipped.
- **Step 10 — Debrief:** log the write target; do not write the debrief. Do not update master plan.
- **Events:** every `append_event` call collects the event into an in-memory buffer instead of writing to the log. At end-of-session (before Step 11), print:
  ```
  DRY-RUN events (N):
    <one per line, full JSON envelope>
  ```

**Exit codes:**

- `0` — dry-run ran to completion; a wet-run on the same inputs would succeed.
- `2` — dry-run surfaced a problem (ambiguous brief, missing upstream, LSP errors, would-block at a gate). Distinct from `1` (crash / bug).

**Idempotency keys match wet-run byte-for-byte.** Keys logged by dry-run are the same keys a wet-run would write, so dry-run output is `diff`-friendly against wet-run artifacts.

**Session-completion event** is also buffered (not appended). The buffered line prints in the closing `DRY-RUN events (N):` block.

This pilot catches contract bugs before 2.6 rewrites apply `--dry-run` to 30+ modes. Report any surprises in the debrief's `## Assumptions` block — a real wet-run uses the same code paths.

---

## Execution Pipeline

### Step 1 — Load spec

- **Brief mode (post-migration):** resolve the brief for `<task-id>` via `scripts/query-plans.sh --kind=brief --task-id=<task-id> --state=ready,dispatched` against `plans/briefs/<brief-id>.yaml` (schema: `_shared/schemas/brief.md`, `brief@3.1.0`). The structured `reads` / `writes` / `acceptance` / `testability` / `figma` fields drive Steps 2–4; the `body:` multi-line string carries the narrative context.
- **Brief mode (legacy fallback):** if no YAML brief exists (migration not run), read from `plans/chanakya-tasks/<task-id>-*.md` and emit one `legacy_artifact_read` event. If both surfaces miss, tell the user to run `/chanakya brief <task-id>` or switch to direct mode.
- **Direct mode:** ask the user what needs to be done. Keep clarifications minimal. No `brief_id` is resolved — the debrief will carry `brief_id: null`.

Invoke any skills the brief lists (e.g., `swiftui-pro`, `figma-to-swiftui`).

Record `WAIT_FOR_USER` (from `--wait` flag, else `no`). Do not prompt the user about it — the flag is the only opt-in.

### Step 1.5 — Build-debt gate

Schema, counter rules, banner text, and gate behavior: see `~/.claude/skills/_shared/schemas/build-debt.md` (Achilles section).

### Step 2 — Claim the task

Post-migration: transition `plans/tasks/<task-id>.yaml` state `briefed → dispatched → in-progress` per `_shared/state-machines/task-lifecycle.md` (two transitions if the task was still at `briefed` on pickup). Append the `history:` entry for each transition, bump `updated_at`, and emit `task_state_changed` per transition. In parallel, transition the brief `plans/briefs/<brief-id>.yaml` `ready → dispatched` per `_shared/state-machines/brief-lifecycle.md`. Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.

**Phase 2.6 transition note:** also mutate `~/.dev-studio/<project>/plans/chanakya-master.md` — set the legacy status row from `briefed` to `in-progress` — until Commit H cutover. (Direct-mode work without a task entry skips this.)

Emit event:
```json
{"ts":"...","agent":"achilles","event":"brief_started","task":"<task-id>","data":{"size":"<SIZE>","gate_selected":"<lsp-only|full-green>"}}
```

### Step 3 — Isolate: branch from a clean slate

Compute the project slug and capture the current branch + committed HEAD — **not** the working-tree state. The user's uncommitted changes stay put in the main checkout.

```bash
PROJECT=$(basename "$(git -C <repo-root> rev-parse --show-toplevel)")
ORIG_BRANCH=$(git -C <repo-root> rev-parse --abbrev-ref HEAD)
ORIG_HEAD=$(git -C <repo-root> rev-parse HEAD)
WORKTREE=~/.dev-studio/$PROJECT/worktrees/<task-id>
mkdir -p ~/.dev-studio/$PROJECT/worktrees

git -C <repo-root> worktree add "$WORKTREE" -b achilles/<task-id> "$ORIG_HEAD"
```

All subsequent work runs inside `$WORKTREE`. Record `PROJECT`, `ORIG_BRANCH`, `ORIG_HEAD`, and `$WORKTREE` — you need them through Step 11.

### Step 4 — Implement

Work methodically through the brief's acceptance criteria (or the user's direct-mode description). Small logical commits. Check off criteria as you complete them.

**Task type awareness:**

The brief's `Type:` field determines what you're implementing:

- **`feature` / `bugfix` / `refactor` / `direct`** → Implementation task. Follow the `## Testability Requirements` section in the brief (if present). See Step 4A below.
- **`test-unit`** → Unit test task. Write unit tests per the test brief. See Step 4B below.
- **`test-integration`** → Integration test task. Write integration tests per the test brief. See Step 4B below.
- **`test-ui`** → UI test task. Write UI tests per the test brief. See Step 4C below.
- **`test-tdd`** → TDD test task. Write failing tests first that define the expected interfaces. See Step 4D below.
- **`debug`** → Debug task. Reproduce the bug, isolate the cause, write a regression test first if possible, then fix. Follows Step 4A semantics with an emphasis on regression coverage.

#### Step 4A — Implementation with testability

When the brief includes `## Testability Requirements`:

1. **SOLID checkpoints** — Before writing code, review the brief's architecture and test seam requirements. As you implement:
   - **S**ingle Responsibility: each new type/struct has one clear purpose. If a type grows beyond ~100 lines, evaluate whether it has multiple responsibilities.
   - **O**pen/Closed: use protocols and composition over inheritance where the brief specifies extensibility.
   - **L**iskov: protocol conformances must be substitutable — if the brief defines a mock strategy, ensure the real implementation satisfies the same contract.
   - **I**nterface Segregation: protocols should be focused. If you're defining a protocol for testing, only include the methods the consumer actually calls.
   - **D**ependency Inversion: inject dependencies via initializer as specified in the brief's Test Seams section. High-level modules depend on abstractions, not concrete types.

2. **Accessibility identifiers** — When the brief specifies an identifier file:
   - Create or update the identifier enum file at the specified path
   - Use the naming pattern: `enum AccessibilityID { enum <Screen> { static let <element> = "<module>.<screen>.<element>" } }`
   - Apply identifiers in views: `.accessibilityIdentifier(AccessibilityID.<Screen>.<element>)`
   - Cover all interactive elements (buttons, text fields, toggles, pickers) and key display elements (labels, images that convey state)
   - Commit the identifier file as a separate, early commit — UI test tasks may depend on it

3. **Localization** — When the task introduces or modifies any user-visible strings (brief's `### Localization` section present): follow all rules at `~/.claude/skills/_shared/rules/localization-rules.md`.

4. **Expose test seams** — For each item in the brief's Test Seams section:
   - Define the protocol with clear documentation
   - Make the production implementation conform to the protocol
   - Use initializer injection (not property injection or service locators)
   - If a seam already exists (check the brief's codebase context), extend it rather than creating a parallel one

Don't over-engineer for testability. Pure functions need no protocols. Simple value types need no abstraction. Only add seams where the brief explicitly calls for them or where a dependency genuinely needs substitution in tests.

#### Step 4B — Writing unit / integration tests

When the task type is `test-unit` or `test-integration`:

1. **Read the parent implementation first.** Check that the parent task (from `Group:` field) is `done` or `verified`. If it's still in-progress, stop and report: "Parent task <id> hasn't landed yet — cannot write tests against unmerged code."

2. **Scan existing tests.** Before writing, check what already exists:
   - Find the test target structure (`*Tests/`, `*UITests/`)
   - Look for existing test files for the same module
   - Identify test helpers, mocks, fixtures that can be reused
   - Check for a shared mock/stub library

3. **Write tests following the brief's structure:**
   - File placement: as specified in the brief's `## Test Organization`
   - Naming: descriptive names that read as specifications (e.g., `func testFilterApply_withLargeImage_completesWithinTimeout()`)
   - Structure: Arrange/Act/Assert (or Given/When/Then)
   - Independence: no shared mutable state between tests, no ordering dependency
   - For unit tests: mock external dependencies, test one unit at a time
   - For integration tests: mock only external boundaries (network, disk), let real modules interact

4. **Refactoring awareness:**
   - If you find yourself duplicating mock setup across 3+ tests, extract a shared helper
   - If the shared helper belongs in a common test utilities module, note it in the debrief as a follow-up refactor task
   - Don't refactor production code in a test task — file a separate refactor task

5. **Run the tests.** Execute the test suite to verify all tests pass. Include test execution results in the debrief.

#### Step 4C — Writing UI tests

When the task type is `test-ui`:

1. **Read the accessibility identifier contract.** Find the identifier enum file created by the parent implementation task. If identifiers are missing, stop and report: "Parent task <id> is missing accessibility identifiers for <elements> — cannot write reliable UI tests."

2. **Use page object pattern** (if the project has one) or create screen abstractions:
   - One screen/page object per major screen
   - Encapsulate element queries using accessibility identifiers
   - Expose user-level actions (e.g., `func tapFilter(_ name: String)`) not raw element interactions
   - Reuse across test methods

3. **Write flow tests per the brief:**
   - Happy path flows first
   - Edge case flows (empty states, error recovery, interruptions)
   - Regression tests for bug fixes (reproduce the original bug scenario, verify it's fixed)
   - Each test should be independent — reset app state in setUp

4. **Remove redundancy.** If a new test covers the same ground as an existing test more thoroughly, remove the old one. Note removals in the debrief.

5. **Run the tests.** UI tests require a simulator or device. Use the project's standard test destination.

#### Step 4D — TDD test task

When the task type is `test-tdd`:

1. The brief defines **expected interfaces** (protocols, method signatures, expected behaviors) — not an existing implementation.
2. Write tests against those interfaces. Tests will fail (no implementation exists yet).
3. Define placeholder protocols/stubs that satisfy compilation but fail assertions.
4. Commit the failing tests. The implementation task (which depends on this task) will make them pass.
5. In the debrief, list the exact interfaces the implementation must satisfy.

**Build discipline by task size:**

- **XS / S** (≤2 files, ≤~50 lines changed, no escalation triggers): rely entirely on the `swift-lsp` plugin for diagnostics. No `xcodebuild` during implementation. Step 6 will also be LSP-only — see below.
- **M / L** (or anything hitting escalation triggers — see Step 6): building opportunistically during implementation is allowed. Each such build must go through the Step 6 lock and per-task `-derivedDataPath`. Step 6 remains the authoritative gate.

If task size is ambiguous, **treat it as M** — err toward more compiler feedback, not less.

### Step 5 — Self-review pass

Before asking the user to look, review your own diff. Invoke the `simplify` skill on the changed files. Target:
- Duplication, dead code, over-abstraction
- Obvious regressions in neighboring code paths
- Missing error handling at genuine boundaries
- Naming, Swift API guideline fit

**Testability review** (for implementation tasks with `## Testability Requirements` in the brief):
- Verify all accessibility identifiers listed in the brief are defined and applied
- Verify all test seams from the brief are exposed (protocols defined, DI wired)
- Check that no new singletons or static mutable state were introduced in business logic
- Confirm the identifier enum file is committed separately from implementation
- **Localization** (if brief has `### Localization`): apply the self-review checklist from `~/.claude/skills/_shared/rules/localization-rules.md`.

**Test review** (for test tasks):
- Verify tests are independent (no shared mutable state, no ordering assumptions)
- Verify test names are descriptive and read as specifications
- Check for flaky patterns (timing-dependent assertions, reliance on specific simulator state)
- Verify mocks are minimal (only mock what's necessary, not everything)

Fix what you find. This is **one** iteration — don't spiral.

### Step 6 — Build gate (size-driven, serialized across Achilles instances)

Select the gate mode from the brief's `Size:` field (or infer for direct mode):

#### Gate selection

1. **Default by size:**
   - **XS / S** → `lsp-only`
   - **M / L** → `full-green`
   - **Direct mode** (no size declared) → `full-green`

2. **Escalation triggers — force `full-green` regardless of declared size.** Inspect the diff (`git diff --stat achilles/<task-id>` and full diff); if any of these hit, escalate:
   - Any line containing `import` (new imports) or `@_implementationOnly`
   - Any `public` / `open` declaration added, removed, or changed
   - Any `protocol` / `extension` adding conformance
   - Any `actor` / `@MainActor` / `nonisolated` / `async` / `throws` signature change
   - Any generic parameter added or removed
   - Changes to `Package.swift`, `Podfile`, `.xcconfig`, or `project.pbxproj`
   - Any new file, deleted file, or file rename

3. **`--force-build` flag** → force `full-green` regardless of size and triggers.

4. **`--ignore-build-debt` override tasks** → keep default gate selection; overrides bypass the debt block, not the gate.

Record the selected gate in a local variable `GATE` for the debrief.

#### `lsp-only` path

Run the `swift-lsp` plugin against every changed file:

```bash
# Collect changed files in the worktree
CHANGED=$(cd "$WORKTREE" && git diff --name-only "$ORIG_HEAD" HEAD -- '*.swift')
# Invoke swift-lsp diagnostics on each (plugin API)
# If any file reports errors (not warnings), treat as a red gate and abort the task.
```

No lock needed — LSP is a local, read-only analysis. No DerivedData is created on this path. If LSP reports errors, stop: do **not** merge, leave the branch and (non-existent) DerivedData alone, surface to the user. This is rare because the escalation triggers catch most error-likely diffs.

#### `full-green` path

With 6–10 Achilles instances potentially running in parallel, `xcodebuild` invocations **must** be serialized. Parallel builds race on the shared SPM cache (`~/Library/Caches/org.swift.swiftpm`), the Clang module cache, and simulator locks — producing flaky "module cache locked" / "couldn't resolve package" failures.

Use an atomic `mkdir`-based file lock (portable on macOS, no `flock` needed). The lock is held only while `xcodebuild` runs. Each task uses an **explicit per-task `-derivedDataPath`** so artifacts are deterministic and cleanup at Step 9 is trivial.

```bash
LOCK_DIR=~/.dev-studio/$PROJECT/locks
LOCK=$LOCK_DIR/xcodebuild.lock
DERIVED=/tmp/derived-data/<task-id>
mkdir -p "$LOCK_DIR" "$DERIVED"

while true; do
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    break
  fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    echo "Stale xcodebuild lock (>45min), reclaiming" >&2
    rm -rf "$LOCK"
    continue
  fi
  sleep 10
done
trap 'rm -rf "$LOCK"' EXIT INT TERM

xcodebuild -scheme <scheme> -destination <dest> -derivedDataPath "$DERIVED" build
BUILD_STATUS=$?

rm -rf "$LOCK"
trap - EXIT INT TERM

[ $BUILD_STATUS -eq 0 ] || { echo "Build failed"; exit $BUILD_STATUS; }
```

**Rules (full-green path):**
- Acquire the lock **only** around `xcodebuild`. Do not hold it during implementation, self-review, or test-writing.
- If the build fails, release the lock before fixing, then re-acquire for the retry.
- If you can't resolve a failure, release the lock, stop, and surface — do **not** merge. Leave the DerivedData folder in place for debugging.
- Never bypass the lock.

#### What to record

Whichever path ran, remember the outcome for the debrief:

```
GATE = "lsp-only" | "full-green"
```

No `full-red` value — red gates stop before reaching the debrief. The field goes into Step 10's `## Build Verification` block.

### Step 7 — Write test cases

Always write:
1. A `## Test Cases` section into the debrief-in-progress.
2. A standalone artifact at `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md`.

Each case: preconditions, steps, expected result. This happens regardless of `WAIT_FOR_USER`.

### Step 8 — Optional wait for user feedback

Branches on `WAIT_FOR_USER`:

**`WAIT_FOR_USER=no` (default):**
- Add a `## Follow-up Tasks` entry to the debrief: "Manual verification of <task-id> — user will test later."
- Proceed to Step 9 immediately. No user prompt, no wait, no scheduled wake.

**`WAIT_FOR_USER=yes` (from `--wait`):**
- Prompt the user:
  > "T001 implementation is done and the build is green. Test cases are at `<task-id>-tests.md`. Reply within 10 min with feedback, or I'll auto-merge."
- Call `ScheduleWakeup` with `delaySeconds: 600` and a prompt that resumes Step 8 for this task in **timeout-merge mode**. Then end the turn.
- Three possible resumptions:
  - **User replies with feedback before the wake:** iterate on the implementation. Re-run Steps 5–6 if the fix is non-trivial. Loop back to Step 8 (still with `--wait` semantics). Cancel the pending wake if possible, else ignore it when it fires.
  - **User approves before the wake:** proceed to Step 9.
  - **Wake fires with no reply:** add a `## Follow-up Tasks` entry to the debrief ("Manual verification of <task-id> — no reply within 10-min window"), proceed to Step 9.

**Cleanup is guaranteed in every non-rejected branch** — the wake exists precisely so the `--wait` case cannot hang forever.

### Step 8.5 — Argus pre-merge gate

Only if Step 6 is green. After self-review and optional user feedback, invoke Argus before merging.

**This gate runs on every dispatch path — interactive, worker-mode, `--wait`, and `--no-wait`. No exceptions except `build-mode` and `test-suite-mode`.** The "Autonomous vs. Interactive" section above governs clarifying-question latitude only; it does not authorize skipping compliance steps. If you are tempted to skip Argus because you are in an interactive session, do not — the gate exists because self-review has known blind spots (cross-file regressions, test adequacy, base staleness) that persist regardless of whether a human is watching. If Argus is genuinely unavailable, surface that as a block and stop before merge; do not silently proceed.

Emit event:
```json
{"ts":"...","agent":"achilles","event":"review_requested","task":"<task-id>","data":{"worktree":"<WORKTREE>","derived_data":"/tmp/derived-data/<task-id>"}}
```

Invoke `/argus <task-id>` with `TASK_SIZE`, `WORKTREE`, and `BASE_BRANCH` in context.

Wait for Argus to return a verdict. Read the `ARGUS_VERDICT` output line.

**On `approved`:**
- Emit `review_approved` event.
- Proceed to Step 9 immediately.

**On `flagged`:**
- Emit `review_flagged` event with `review_file` and `finding_count` from Argus's output.
- Proceed to Step 9 (merge). Findings are captured in the debrief for Chanakya to process.
- Include a `## Argus Review` block in the debrief referencing the review file path and finding count.

**On `blocked`:**
- Emit `review_blocked` event with `block_reason`.
- Do NOT merge. Surface Argus's block reason and review file to the user.
- Attempt to fix the block:
  - If the block is **base staleness**: rebase the worktree branch onto the current base, then re-run Steps 5–8.5.
  - If the block is a **compile/test failure** Achilles can fix: fix the code, re-run Steps 5–6, then re-run Step 8.5.
  - If the block is **secrets in diff**: remove the secret, re-commit, re-run Step 8.5.
  - If Achilles **cannot address** the block (e.g., ambiguous scope creep, secrets in a config file requiring product input): surface to the user. Do not merge. Debrief with `status: blocked`.

Re-run Step 8.5 after each fix attempt. Maximum 3 fix-and-re-review cycles before surfacing to the user as unresolvable.

---

### Step 9 — Commit, merge back, clean up (serialized across Achilles instances)

Only if Step 6 is green, Argus returned approved or flagged, and the user hasn't rejected the work.

**Respect `.argus-running` marker:** Before running `git worktree remove`, check:
```bash
if [ -f "$WORKTREE/.argus-running" ]; then
  echo "Argus is still reviewing $WORKTREE — waiting..." >&2
  # Poll every 30s, up to 10 min, then surface to user
fi
```
This guard is a safety net for standalone Argus invocations running concurrently. In the normal flow (Step 8.5), Argus will have already returned its verdict and removed the marker before Step 9 runs.

The merge happens in the **shared main checkout**, so concurrent Achilles instances race on `.git/index.lock`, the branch checkout, and `$ORIG_BRANCH`'s tip. Serialize this section with a second `mkdir`-based lock under the project's lock dir. The critical section is short (seconds), so contention is negligible even at 10 workers.

The committing inside the worktree is safe to run unlocked (each worktree has its own index). Acquire the lock **only** for the main-checkout block. DerivedData cleanup happens unlocked after the lock is released.

```bash
# 1. Inside the worktree — safe to run unlocked
# Pre-step: clear stale .git/index.lock if safe (see _shared/primitives/safe-git.md).
cd "$WORKTREE"
git add -A && CALLER_SKILL=achilles-merge safe_git_commit -m "<task-id>: <summary>"   # or several small commits

# 2. Acquire the merge lock before touching the main checkout
LOCK_DIR=~/.dev-studio/$PROJECT/locks
MERGE_LOCK=$LOCK_DIR/git-merge.lock
mkdir -p "$LOCK_DIR"
while true; do
  if mkdir "$MERGE_LOCK" 2>/dev/null; then
    echo $$ > "$MERGE_LOCK/pid"
    break
  fi
  if [ -n "$(find "$MERGE_LOCK" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
    echo "Stale merge lock (>45min), reclaiming" >&2
    rm -rf "$MERGE_LOCK"
    continue
  fi
  sleep 5
done
trap 'rm -rf "$MERGE_LOCK"' EXIT INT TERM

# 3. Inside the lock — checkout, refresh tip, merge, remove worktree
cd <repo-root>
git checkout "$ORIG_BRANCH"
git fetch origin "$ORIG_BRANCH" 2>/dev/null || true   # refresh in case a sibling advanced it
git merge --no-ff achilles/<task-id> -m "Merge <task-id> into $ORIG_BRANCH"
MERGE_STATUS=$?

git worktree remove "$WORKTREE"

# 4. Release
rm -rf "$MERGE_LOCK"
trap - EXIT INT TERM

if [ $MERGE_STATUS -ne 0 ]; then
  # Emit merge conflict event
  # {"ts":"...","agent":"achilles","event":"merge_conflict","task":"<task-id>","data":{"branch":"achilles/<task-id>"}}
  echo "Merge failed (likely conflict) — branch left intact, DerivedData retained"
  exit $MERGE_STATUS
fi

# Emit task_merged event
# {"ts":"...","agent":"achilles","event":"task_merged","task":"<task-id>","data":{"merge_sha":"<sha>"}}

# 5. Cleanup DerivedData for this task (only after a successful merge, unlocked)
rm -rf /tmp/derived-data/<task-id>
```

**Rules:**
- Acquire the merge lock **only** around the main-checkout block. Do not hold it during commit-in-worktree, debrief writing, DerivedData cleanup, or anything else.
- If the merge has conflicts (a sibling Achilles or the user committed to `$ORIG_BRANCH` while you worked): release the lock, leave the branch intact, **keep the DerivedData** (useful for debugging), surface it to the user. **Do not force-resolve.**
- If the build was not green (Step 6), do **not** merge. Leave `achilles/<task-id>` alive and keep the DerivedData for the user to inspect.
- DerivedData is removed **only** on a clean merge. Any failure path preserves it.
- Never bypass the merge lock — `.git/index.lock` failures from siblings are silent corruption risks.

### Step 10 — Debrief + short user summary

Write the debrief as YAML to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` per schema `_shared/schemas/debrief.md` (`debrief@2.0.1`). Mint `id` as a UUIDv7. Populate `schema_version`, `task_id: <task-id>`, `brief_id: <brief-id>` (null for direct-mode without brief), `mode: task`, `state: emitted`, `completed_at`, `branch: {worked_on, merged_into, merge_sha}`, `commits: [{sha, message}…]`, `diff_summary: {files, added_lines, removed_lines}`, the structured `decisions` / `tests` / `testability` / `debt` / `performance` / `key_learnings` / `known_issues` / `follow_ups` arrays/objects, `build_gate: <lsp-only|full-green>` (from Step 6), `build_debt_override`, `open_questions: []` (task mode rarely uses this), and `argus_review: {status, review_id, notes}` derived from the Step 8.5 verdict (status `approved` / `flagged` / `blocked`; `not-invoked` only for exempted build-mode/test-suite-mode paths, which don't land here anyway — Argus is mandatory).

Then transition `plans/tasks/<task-id>.yaml` state `argus-reviewed → merged` per `_shared/state-machines/task-lifecycle.md`, set `links.debrief = <debrief-id>`, append `links.reviews` with `argus_review.review_id` when present. Transition the paired brief `plans/briefs/<brief-id>.yaml` `dispatched → debriefed`. Emit `task_state_changed`, `brief_state_changed`, and `debrief_emitted` via `scripts/write-event.sh`. Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.

**Debrief is load-bearing for worker-mode detection.** The worker wrapper (`scripts/achilles-worker.sh`) treats a `claude -p` exit with `rc=0` and no debrief for the task as a silent-stuck state and routes the task to `rescue/<task-id>-stuck.md`. Any meaningful outcome — completion, blocked, failed — must write a debrief (post-migration: plans/debriefs/<debrief-id>.yaml; legacy: plans/chanakya-inbox/<task-id>-debrief.md) before exit. Clarifying questions exit one-shot subagents cleanly and trip this detector; prefer the autonomous-default pattern (pick the obvious default, proceed, note the assumption in the debrief) instead of asking.

**Phase 2.6 transition note:** also write the legacy markdown debrief at `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md` (format: `_shared/contracts/debrief-format.md`) so the worker's silent-stuck detector + in-flight Chanakya sessions that haven't yet migrated still see the debrief. If Argus returned `flagged`, the legacy markdown includes a `## Argus Review` block referencing the review file path and finding count. Also mutate `chanakya-master.md`: status → `done`, record commit hashes + merge commit. `done` ≠ user-verified — Chanakya promotes the task state to `verified` after test-manifest feedback. Cutover removes the legacy debrief + master-plan writes at Commit H.

Emit event:
```json
{"ts":"...","agent":"achilles","event":"brief_completed","task":"<task-id>","data":{"gate":"<lsp-only|full-green>","merge_sha":"<sha>"}}
```

Print a short message to the user:

> "**T001 done.** Branched from `<ORIG_BRANCH>`@`<short-hash>`, implemented, self-reviewed, build green, Argus approved/flagged, merged back. Test cases at `<task-id>-tests.md`. Debrief dropped for Chanakya."

### Step 11 — Signal completion; sit idle

The 15-minute wake for surfacing Chanakya follow-ups has been replaced by event-driven processing. Chanakya's `--auto-sweep` loop reads the event log and processes `brief_completed` events without a separate wake.

Before sitting idle, **emit `agent_session_completed`** to close the session record:

```json
{"ts":"...","agent":"achilles","event":"agent_session_completed","task":"<task-id>","data":{"mode":"<task-id>","duration_s":<seconds_from_brief_started>,"files_read":<count>,"files_written":<count>}}
```

Include `tokens` (`{input, output, cache_read, cache_write}`) if you have access to your own session token totals; omit otherwise. Duration alone is still useful for analysis. See `~/.claude/skills/_shared/contracts/events.md` → "Cross-agent events".

After Step 10 + the session-completed event, **sit idle.** Do not self-select the next task. Do not schedule a wake. Do not prompt the user further.

Chanakya will:
- Process the debrief on its next inbox sweep.
- Read any `review_flagged` events and auto-file follow-up tasks.
- Surface follow-ups to the user via `/chanakya status` or `--auto-sweep`.

If the user wants immediate follow-up surfacing, they run `/chanakya status`.

---

## Follow-up-Surface Mode (deprecated)

The Step 11 scheduled wake has been removed. Follow-up surfacing is now event-driven via Chanakya's inbox sweep. This section is retained as a no-op placeholder — do not implement scheduled wakes for follow-up surfacing.
