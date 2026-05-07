# Review Guide

Project-specific review rules for generic-dev-studio. Living doc — update when a correction comes in (either a false positive the reviewer raised, or a real issue it missed). The rule file *is* the memory.

Not a general code-quality checklist. For generic concerns (reuse, efficiency, readability) use `/simplify`. This file captures only what's specific to **this** repo's invariants.

## How to use

When reviewing a diff (manually or via a reviewer agent):

1. Walk each rule below. For each finding, tag it with a tier.
2. **Auto-fix tier** — fix it, report what changed.
3. **Ask tier** — surface to the user before changing. Describe the tradeoff.
4. **Warn tier** — fix unless it's intentional; one-line note either way.

When to trigger a review: any script change, any SKILL.md change, any `_shared/*` change, or diffs >100 lines. Single-line doc fixes skip review.

## Rules

### R1 — Zero new permission surface (tier: **ask**)
All runtime writes must stay under `~/.dev-studio/**` (already in allowlist). Any new path outside that tree — or any new Bash command pattern — is a block. Exception: genuinely critical system actions (installing hooks, modifying `~/.claude/settings.json`). Those must be explicit + documented in README.md's permissions section.

**Why:** user operates remotely; a new permission prompt strands the pipeline. `_shared/primitives/file-locations.md` documents the two canonical roots.

**How to check:** grep the diff for writes to paths not under `~/.dev-studio/` or `/tmp/`. Grep for new `Bash(…)` patterns that aren't already in the README's allowlist snippet.

### R2 — Zero new user input in agent workflows (tier: **block + auto-fix**)
Never add a step that requires the user to type, confirm, or provide config at runtime. Auto-detect from filesystem / git / env. Required config = `ACHILLES_*` env var with a sensible default.

**Why:** minimal-intervention is a hard requirement (`memory/feedback_no_manual_input.md`).

**How to check:** search the diff for `read -p`, interactive prompts, `if [ -z "$..." ]; then echo "please set ..."`, and any "ask the user" language in SKILL.md steps.

**Fix pattern:** replace with auto-detection (filesystem fingerprint, git query) or an env-var override with a documented default.

### R3 — Path resolution via `scripts/lib-paths.sh` (tier: **block + auto-fix**)
Scripts must not hardcode `~/.dev-studio/<project>/…` or `~/.dev-studio/.runtime/…`. Always go through `resolve_project`, `resolve_inbox_root`, `resolve_inbox_root_for`, `resolve_push_queue`, `resolve_runtime_global`. Docs may use `<project>` as a placeholder.

**Why:** single source of truth; override via env var (`ACHILLES_PROJECT`, `ACHILLES_INBOX_ROOT`) stays consistent across the codebase.

**How to check:** `grep -n 'dev-studio/\.runtime/\|dev-studio/[a-z]' scripts/*.sh`. Expected: only `lib-paths.sh` itself contains the formulas.

**Fix pattern:** source `lib-paths.sh`, replace literal paths with resolver calls.

### R4 — Per-project vs machine-global split (tier: **ask**)
New artifact? Default to per-project (`~/.dev-studio/<project>/`). Machine-global (`~/.dev-studio/.runtime/`) is only for resources physically shared on the machine (simulator semaphore; future GPU queues). Workflow state — inboxes, queues, briefs, event logs — is per-project.

**Why:** multi-project is the target; cross-project contention on workflow state is a correctness bug.

**How to check:** for any new artifact in the diff, ask: could two projects on this machine each need their own? If yes → per-project. Flag anything in `~/.dev-studio/.runtime/` that isn't a physical-resource lock.

### R5 — Bash + zsh portability for `scripts/*.sh` (tier: **block + auto-fix**)
Scripts have `#!/usr/bin/env bash` shebangs but users may `source` them from zsh. Avoid bash-only constructs in sourced files (`compgen`, `shopt`-only patterns, unquoted expansions that rely on word-splitting).

**Why:** `lib-paths.sh` is sourced from both shells in practice. One regression already cost debugging time.

**How to check:** `zsh -c 'source scripts/lib-paths.sh && <exercise new code>'` after any edit. Look for unquoted `$var` where word-splitting is load-bearing.

**Fix pattern:** newline-separated accumulators + quoted expansions; `find` instead of glob expansion.

### R6 — SKILL.md kept in sync with script behavior (tier: **warn**)
When scripts change, check for cross-references in `core/v2/skills/dev-studio/SKILL.md`, `core/v2/roles/*.yaml`, `core/v2/handoffs/*.yaml`, `_shared/*.md`, `README.md`, and `scripts/README.md`. Stale examples and old flag names are a drift risk given how many cross-refs exist.

**How to check:** after any script edit, `grep -rn '<script-name>\|<old-flag>' --include="*.md"` and verify each hit still matches reality.

### R7 — Comments: WHY not WHAT (tier: **block + auto-fix**)
Delete comments that narrate the code, reference the current task, or explain what a well-named identifier already conveys. Keep comments that encode non-obvious WHY (invariants, workarounds, subtle ordering constraints).

**Fix pattern:** delete. If in doubt, delete — identifiers should carry the meaning.

### R8 — Token-cost awareness for skill prose (tier: **warn**)
SKILL.md files load wholesale into every session that invokes the skill. Long prose has recurring cost. When adding a section >20 lines, consider:
- Can it live in `_shared/` and be referenced instead?
- Is it stack-specific (iOS, App Store) and therefore a candidate for a future stack module?
- Can tables replace prose?

**How to check:** after any SKILL.md edit, note the line-count delta. Flag additions >50 lines for a second look.

### R9 — YAML-only writes for Phase 2.6 artifacts (tier: **block + auto-fix**)
Any mode pack or script that mutates a Phase 2.6 artifact (tasks / briefs / rounds / releases / debriefs / reviews) MUST write only the YAML side via the `lib-ledger.sh` writers (`transition_*`, `write_*_artifact`). The legacy markdown surfaces were archived to `plans/.legacy-archive/` under #245 A.4 and the `legacy_*_helpers` are stub-fail (#245 A.5) — calling them, or writing directly into `chanakya-tasks/` / `chanakya-inbox/<task>-debrief.md`, is a regression.

**Why:** the dual-write window closed under #245 A.4/A.5. `scripts/verify-ledger.sh` originally caught T218a drift (#76) because a writer mutated the legacy markdown without the paired YAML update; the helper-only discipline that emerged from that incident is now structurally enforced (legacy paths have no live writer). The `_shared/patterns/dual-write-transition.md` primitive is preserved for future migrations of the same shape.

**How to check:**
- New script mutating `plans/<kind>/*.yaml`? Check it uses the `lib-ledger.sh` writers, not ad-hoc `yq -i`. Ad-hoc `yq -i` against a Phase 2.6 artifact bypasses the event emission + index rebuild contract.
- New writes to `plans/chanakya-master.md` outside `scripts/render-master-plan.sh`? `scripts/lint-comms-boundary.sh` blocks via B4 (post-#245 A.4/A.5) — but if the diff bypasses the manifest declaration, catch it here.
- New writes to `plans/chanakya-tasks/` or `plans/chanakya-inbox/<task>-debrief.md`? Those paths are archived. Reject.
- Any call to `legacy_master_plan_*` / `legacy_inbox_*` / `legacy_brief_*` / `legacy_release_log_*`? Those helpers are fail-loud stubs; remove the call site or replace with the YAML writer equivalent.

**Fix pattern:** replace ad-hoc YAML writes with `lib-ledger.sh` helper calls; remove any call to a `legacy_*` helper; if a script is genuinely re-establishing a dual-write window for a *new* migration, follow the `_shared/patterns/dual-write-transition.md` "For future migrations using this pattern" checklist.

### R10 — No completion claims without fresh verification evidence (tier: **block + auto-fix**)

**Iron Law: NO "task complete" / "green build" / "tests pass" / "merge clean" / "no regressions" CLAIM WITHOUT FRESH EVIDENCE IN THE DEBRIEF.**

Every completion-style claim in a debrief (YAML or prose) must cite a specific, timestamped artifact. Claims without evidence are hallucinations; the dual-write has to fail loudly rather than encode a lie.

| Claim | Required evidence |
|---|---|
| "build passes" | `xcodebuild` exit 0 captured in debrief's `build_log` field; timestamp within the last 10 min |
| "tests pass" | Test runner output captured with pass/fail counts; timestamp within last 10 min |
| "merge clean" | `git status` output showing clean tree and branch up-to-date |
| "no regressions" | Argus verdict = `approved` referenced by `review_id` |
| "LSP-clean only" | Build-debt acknowledged in `build_debt` field (XS/S tasks that skipped xcodebuild) |

**Why:** prose claims drift; structured fields don't. A debrief that reads "all tests pass" without a matching `tests_output` is indistinguishable from an honest green run — until the next session reads it, trusts it, and acts on a false floor. The Iron Law punches through the failure mode of rationalizing skipped verification.

**How to check:**
- In a debrief diff, every `status: done` (or equivalent) must be paired with `build_log`, `tests_output`, or `build_debt` — not all three required, but at least one must carry fresh timestamp + real content.
- Prose like "confirmed passing" or "all green" that doesn't reference a field → reject; ask where the evidence is.
- XS/S tasks that skipped xcodebuild must emit `done_with_concerns`-equivalent state and `build_debt: acknowledged` — they may not self-claim unqualified "passing".

**Fix pattern:** either capture the evidence and paste it into the debrief, or downgrade the claim to "LSP-clean, build-debt acknowledged" with the matching field set. Never rewrite the claim to pass the rule — the claim is the symptom; the missing evidence is the failure.

**Interaction:** when the 4-state worker-report contract (#79) lands, `done` vs `done_with_concerns` becomes the structural enforcement of this rule. Until then, R10 is the prose-level gate.

**Gate taxonomy (issue #84).** The `brief_completed.gate` event field distinguishes four outcomes: `verified` (build green + tests ran + Argus approved), `build-only` (build green, suite disabled), `waived` (build green, Argus skipped on a non-exempt path), `lsp-only` (LSP gate). Use this vocabulary in reviews + debriefs — "full-green" is legacy and ambiguous. A debrief reading `gate: build-only` or `gate: waived` without a matching explanation in `key_learnings` / `decisions` is an R10 hit: the structural signal is present but the WHY is missing. See `_shared/contracts/events.md` → `brief_completed.gate` taxonomy for source-signal rules.

**Reviewer test rerun policy (issue #604).** R10 requires trustworthy, fresh verification evidence; it does not require reviewers to blindly repeat a worker's test command. Reviewers inspect the worker evidence first: exact command, timestamp, exit status or pass/fail output, environment, commit or diff covered, and whether the suite reaches the changed surface. A reviewer reruns tests only when one of these is true:

- Evidence is missing, stale, incomplete, or not tied to the reviewed diff.
- The diff changed after the worker's verification run.
- The worker ran only a narrow suite and the changed surface needs broader coverage.
- The command is cheap and high-value for the reviewed risk.
- The change is risky enough that independent reproduction materially changes confidence.
- The reviewer needs to reproduce a suspicious pass, failure, flake, or environment-dependent result.

When a reviewer accepts worker evidence instead of rerunning, the verdict must say `verified_by_worker_evidence` and cite the evidence. When a reviewer reruns, the verdict must say `independently_rerun_by_reviewer` and include the command, timestamp, and result. Do not collapse both into "tests pass"; downstream sessions need the confidence level and cost model. Gates that mandate independent reruns must document why the added latency is worth it, what failure mode it catches, and when the rerun can be skipped or made async.

**Same-host self-review gate (issue #605).** Worker outputs must show `self_review_performed`, `self_review_findings`, `self_review_fixes`, and `final_verification_evidence`; planner outputs must show `self_review_performed`, `self_review_findings`, and `self_review_fixes` before cross-host plan review. Reviewers inspect those fields before requesting extra reruns. Missing self-review is a workflow defect: flag as `warn` when risk is low and block when the target is non-trivial, risky, or final verification claims depend on the missing review.

### R11 — No studio-initiated pushes to base branches (tier: **block + auto-fix**)

Scripts and mode prose must never run `git push origin main` (or `master`, or any equivalent integration/base branch) against a project or studio repo. Remote base branches advance **only** through PR merges. Studio-initiated pushes may target feature branches (`push -u origin HEAD`, `push origin <feature-branch>`) or tags (`push origin <tag>`). Integration happens via `gh pr create` / `gh pr merge`, never direct ref advancement.

**Why:** a studio-initiated `git push origin main` was observed bypassing an open PR (#3150), silently advancing the remote while review was still in flight. The PR-gated integration workflow is load-bearing for Argus review, CI, and human sign-off; direct base pushes erase all three gates.

**How to check:**
- `grep -rnE 'git\s+push.*(origin|upstream).*(main|master|trunk|develop)' scripts/ commands/ core/v2/skills/ core/v2/roles/ _shared/` — expected: zero hits.
- `git push -u origin HEAD` while on a base branch counts as a violation. Scripts must guard with `[ "$(git symbolic-ref --short HEAD)" != "main" ]` or equivalent before any `push -u HEAD`.
- Any prose in a SKILL.md or mode file instructing the agent to "push to main" / "update remote main" / "push the merge" is a violation — replace with "open a PR" or "merge via `gh pr merge`".

**Exception:** partition-sync repos (e.g. `scripts/sync-shared-remote.sh` against `~/.dev-studio/.cache/…`) where `main` is the data-store trunk and each machine writes to a disjoint subdirectory. The exception applies only when the push target is a dedicated sync/data repo — never a code repo.

**Fix pattern:** replace `git push origin main` with the PR flow:
```
git push -u origin "$FEATURE_BRANCH"
gh pr create --base main --head "$FEATURE_BRANCH" ...   # or gh pr edit if it exists
```
If the intent was to land an already-merged commit, the merge should have happened via `gh pr merge` in the first place — the rule catches the rationalization.

### R12 — Portability: new capabilities via file I/O + shell + single session only (tier: **block**)

Every worker capability must be implementable via file I/O on the repo + `~/.dev-studio/**`, a POSIX shell, and a single model session with a system-prompt + turn loop. No new capability may depend on a host primitive that isn't available across all declared adapters in `hosts/ADAPTER-SPEC.md`.

**Commit signal:** authors add `portable: yes` in the commit message for any new capability. Reviewers reject when the implementation depends on Claude-Code-specific primitives not available in every adapter.

**How to check:** grep the diff for tool-name dialects (`Agent tool`, `Read tool`, `Write tool`, `Edit tool`, `Bash tool`), `SessionStart hook` (when load-bearing, not as fallback description), `subagent primitive`, `CLAUDE_PLUGIN_ROOT`. `scripts/lint-host-agnostic.sh --staged` catches these automatically in pre-commit.

### R13 — Zero new third-party runtime deps in worker paths (tier: **block**)

Worker-facing code paths (`core/v2/roles/worker.yaml`, `core/v2/roles/reviewer.yaml`, and their referenced mode/rule payloads) stay on POSIX + `jq` + `yq` + `check-jsonschema` — the set frozen at host-agnostic v1. Adding a runtime dependency requires an ADR filed as a GitHub issue before the commit lands. Infrastructure scripts (`scripts/`) may use additional tools; they are not worker code.

**How to check:** `scripts/lint-host-agnostic.sh --staged` greps for `npm install`, `pip install`, `brew install`, `gem install` in v2 worker/reviewer payloads. Any new package-manager invocation outside a comment is a block.

### R14 — Graceful degradation as loud failure, never silent skip (tier: **block + auto-fix**)

Any capability a host adapter cannot fulfill must fail loud — exit non-zero with a clear message — not silently degrade or no-op. Specifically: if a host declares `supports_hooks: false` and a worker step depends on a hook for correctness, the step must detect the absent capability and refuse, not silently skip the hook and proceed.

**How to check:** grep the diff for `|| true`, `2>/dev/null`, `|| :` immediately following a step that reads from adapter capabilities. A silent swallow on a capability-gated path is the failure mode. Exception: best-effort telemetry (`emit_event_keyed ... >/dev/null 2>&1 || true`) — event loss is acceptable; logic loss is not.

**Fix pattern:** replace silent fallback with an explicit capability check:
```bash
if [ "$(yaml_field "$CAPS" supports_hooks)" != "true" ]; then
  printf 'error: this step requires hooks; host does not support them\n' >&2; exit 1
fi
```

### R15 — Single retry layer: bounded retries only at declared orchestration edges (tier: **ask**)

`dispatch-review.sh` and `spawn-worker.sh` retry a failed spawn at most once. No worker script may implement its own inner retry loop. Validator rejections never auto-retry (per `_shared/contracts/idempotency.md §Per-step retry classification`). Prevents cascading retry amplification that could double-emit events or consume API quota unexpectedly.

Exception: `scripts/studio-chain-runner.sh` may use its declared chain execution retry policy for idempotent infrastructure operations only: auth/preflight probes, remote ref reads, fetches, and pushes that are safe to repeat after an ambiguous client-side failure. The retry budget must be finite, surfaced in plan/state/envelopes/halt records, and exhausted retries must write a typed halt record. Do not wrap non-idempotent GitHub mutations such as PR creation, issue close/comment, or telemetry comments.

**How to check:** grep the diff for `for _ in 1 2`, `while retry`, `attempt=`, or `RETRY_COUNT` patterns in `scripts/*.sh`. If a loop implements retry semantics that isn't the single allowed outer retry in dispatch/spawn scripts, flag for review.

### R16 — Worker-to-worker handoffs forbidden; all routing through the manager (tier: **ask**)

Workers and reviewers do not route to each other directly. Reviewer verdicts return to the manager (via the event log and verdict artifact), not directly to the worker. Worker review dispatch goes through `dispatch-review.sh`, which emits a handoff event that the manager observes — the architecture remains hub-and-spoke, not peer-to-peer.

**How to check:** grep the diff for direct worker-to-reviewer calls that bypass the event log (for example, verdict emission from the worker loop instead of via `dispatch-review.sh`). Any path where the reviewer mutates state that only the manager should own is a violation.

### R17 — Ownership of mutations (tier: **ask**)

| Actor | What it may mutate |
|---|---|
| Worker | Worktree files, task state, debriefs |
| Manager | `briefs/`, task state (via `plans/`), event sweeps |
| Reviewer | Verdict events and artifacts; append-only back-refs on `task.links.reviews` per the comms-boundary primitive; read-only on the diff |

Reviewers must not mutate task YAML payload, `briefs/`, `debriefs/`, or the worktree. Append-only back-refs (`links.reviews`) are permitted as a lifecycle co-writer per `_shared/primitives/agent-comms-boundary.md` — they uphold the bidirectional invariant in `_shared/contracts/plans-index-validator.md` (`task.links.reviews[] ⇔ review.subject`). Workers must not write to `briefs/`. Managers must not write to the worktree. `scripts/lint-host-agnostic.sh` enforces path-ownership greps; flag any diff that crosses these lines.

**How to check:** in a diff that touches reviewer role payloads or verdict emission, verify writes against `plans/tasks/<task-id>.yaml` are confined to `links.reviews` append (no payload field changes); no writes reach `plans/briefs/`, `plans/debriefs/`, or worktree paths. In worker diffs, verify no `briefs/` mutations.

### R18 — Skill Authoring Standard conformance (tier: **block + auto-fix**)

Every owned `SKILL.md`, mode-pack `modes/*.md`, `routing.yaml`, and `portability.yaml` MUST pass `scripts/lint-skill-prose.sh` on commit. Vendored skills (declared `authoring_standard: exempt` in their `vendor.yaml`) are validated for frontmatter only and skip the body grammar checks. The Authoring Standard itself lives at `_shared/standards/skill-authoring.md`; the sentinel verb set at `_shared/standards/sentinel-vocabulary.md`.

**Why:** prose drift across hosts is the operational risk that contracts and schemas don't catch. Different models read soft modals differently — "should" gets interpreted as license to skip; "consider" reads as "do." Treating SKILL.md as a programming language with a defined grammar closes that gap. Recorded in `project_skill_distribution_arc.md` as load-bearing decision #1.

**How to check:** the pre-commit hook (Gate 3, `lint-skill-prose.sh --staged`) runs the linter on staged SKILL.md / mode-pack / routing.yaml / portability.yaml files. Findings format: `<CODE>:<file>[:<line>]:<detail>`. Codes documented in `_shared/standards/skill-authoring.md §Linter codes`.

**Fix pattern:** for every linter `E_*` finding —

| Finding | Fix |
|---|---|
| `E_MISSING_FRONTMATTER` / `E_MISSING_REQUIRED_KEY` / `E_INVALID_FRONTMATTER` | Add the missing keys (`name`, `description`, `type`, `schema_version: 1`); ensure description ≤ 280 chars |
| `E_BAD_TYPE` / `E_BAD_NAME` | Set `type` to one of the six allowed values; rename to kebab-case for executable skill kinds |
| `E_SOFT_MODAL_IN_PROCEDURE` | Replace `should`/`may`/`might`/`consider` with imperative verbs |
| `E_MISSING_SENTINEL` | Start each step with one of `READ`, `WRITE`, `RUN`, `CHECK`, `EMIT`, `RECORD`, `STOP`, `PROCEED`, `RETRY`, `SKIP`, `ESCALATE`, `BLOCK` |
| `E_MISSING_PRE_POST` | Add `Before:` and `After:` lines under each numbered step |
| `E_MISSING_FAILURE_MODES` / `E_BAD_FAILURE_CLASSIFICATION` | Add a `## Failure modes` table with the three-column shape; classify each failure as `transient`, `permanent`, or `ambiguous` |
| `E_INVALID_ROUTING` / `E_INVALID_PORTABILITY` | Schema validation hint will name the offending field; consult the JSON Schema in `_shared/standards/` |

Soft modals are linter-blocks specifically because procedures are not optional — they are the contract. If a step is genuinely conditional, model it via a decision table, not "should" prose.

**Migration carve-out:** historical v1 mode-pack fixtures under `tests/mode-packs/` are inert regression fixtures and remain grandfathered. Active v2 skills and roles are block-level alongside every other owned skill surface.

### R19 — Mode pack discipline (tier: **block + auto-fix** for inline dups; **ask** for missing references; **warn** for token-budget headroom)

Authoritative rule + linter: `_shared/rules/mode-pack-discipline.md` and `scripts/lint-mode-pack.sh` (pre-commit Gate 2e). Three failure shapes to watch in review prose, on top of the structural lint:

- **block + auto-fix** — inline restatement of `_shared/contracts/`, `_shared/rules/`, `_shared/primitives/`, or `_shared/schemas/` content in a mode pack. Replace with a reference. The linter catches 4+ consecutive lines via exact match; reviewers catch paraphrased duplications the heuristic misses.
- **ask** — a new mode pack that doesn't reference at least one `_shared/` primitive. Almost certainly missed reuse — the agent layer is supposed to compose from shared building blocks. Surface before merging.
- **warn** — mode pack token estimate (`chars / 4`) > 70% of `budget_tokens`. Heading toward overflow; consider trimming or raising the budget before it crosses.

**Why:** routers stayed nominally lean while mode packs absorbed the prose the routers shed. Without structural enforcement, the cluster duplicates rules and each restatement drifts independently. The lint is the structural gate; this rule is the human-reviewer gate for the cases the lint can't see.

**How to check:**
- For any `*/modes/*.md` change, eyeball the diff for paragraphs that read like `_shared/`. If they do, grep `_shared/` for the same idea — if a primitive exists, replace with a reference.
- For any new mode pack added, confirm at least one `_shared/contracts/`, `_shared/rules/`, or `_shared/primitives/` reference is present.
- Note token-budget headroom from the lint output (warning lines start with `W_MP1_BUDGET_OVER`).

### R20 — Worktree isolation: never edit the main checkout (tier: **block**)

Every session that writes to this repo must work in a dedicated `git worktree` (see CLAUDE.md §Worktree protocol). The main checkout is read-only during concurrent sessions.

Local `main` is a mirror of `origin/main`, not a work branch. Do not commit,
merge, rebase, or cherry-pick onto local `main`; do not use local `main` as a
PR staging branch. The pre-commit hook blocks base-branch commits unless the
user explicitly sets `STUDIO_BYPASS_MAIN_COMMIT_GUARD=1`. If local `main`
diverges, preserve any unique commit on a backup branch and realign `main` to
`origin/main` only with explicit user approval for the destructive reset.

**Why:** parallel Claude Code sessions share the same filesystem and git index. `git add` and `git reset` in one session can silently pick up the other session's unstaged edits, producing accidental co-mingling in commits. The pathspec workaround (`git commit -- <paths>`) is insufficient — it only filters the working-tree layer; pre-staged index pollution from the other session still commits regardless. Worktree isolation is the structural fix.

**How to check:** before making any edit in this repo, confirm `git worktree list` shows a dedicated non-main path as the active worktree. If the current working directory is the main checkout, stop — create a worktree first. Before any commit, confirm the active branch is not `main`, `master`, `trunk`, or `develop`.

**Retired:** the previous guidance to use `git commit -- <paths>` + `git restore --staged :/` (memory: `feedback_session_scoped_commits.md`) is superseded by this rule. Pathspec is no longer the mitigation; worktree isolation is.

**Fix pattern:** delete the inlined block; insert `See _shared/<area>/<file>.md`. If the duplication is intentional and load-bearing, annotate with `<!-- shared-dup-allowed: <reason> -->` directly above — the lint records the reason but does not block.

**Interaction:** R8 is the soft sibling on token-cost awareness; R19 is the structural gate. R18 + the prose linter handle grammar; R19 + the mode-pack linter handle economics + reuse. Both pre-commit hooks run; both must pass.

### R21 — Retired-pattern hygiene: update catalog on every retirement (tier: **block + auto-fix**)

When any script, lib (`lib-ledger.sh`, `lib-paths.sh`, etc.), or shared contract retires a write path, naming convention, or behavioral pattern:

1. Add the ERE to `_shared/rules/retired-patterns.md` (catalog table + patterns block) **in the same commit**.
2. Run `scripts/lint-mode-pack.sh` across all mode packs immediately and fix every hit in the same commit.
3. Note the retired pattern in the commit message so the trail is traceable.

The lint (MP5) is the machine gate — it blocks at pre-commit on any mode pack or SKILL.md that references a cataloged pattern. This rule is the human-reviewer gate for **paraphrased** references (e.g., "write the markdown file" instead of "write the legacy markdown") that grep can't see.

**Why:** retired patterns don't respect agent boundaries. A pattern retired from lib-ledger can silently persist in Achilles, Argus, Chanakya, or Apollo mode packs. Agents on script-backed hosts (claude-code) follow the scripts and ignore stale prose; agents on prose-driven hosts (Codex) execute the prose literally. Without a cross-agent catalog, each host diverges independently and the only signal is a bug report.

**How to check:** for any diff that modifies `lib-ledger.sh`, `lib-paths.sh`, or a `_shared/contracts/*.md` or `_shared/patterns/*.md` file — ask: "did this retire a write path or remove a behavior?" If yes, confirm `_shared/rules/retired-patterns.md` has a new entry. If the entry is missing, this is a block.

**Fix pattern:**
1. Add entry to `_shared/rules/retired-patterns.md` catalog table.
2. Add ERE to the `<!-- lint:patterns:start -->` block.
3. Run `scripts/lint-mode-pack.sh` — fix all `E_MP5_RETIRED_PATTERN` hits.

### R22 — Workflow economics before mandatory gates (tier: **ask** for >20% common-loop latency; **block** for 2x+ common-loop latency without explicit user approval)

Token/context savings are default only when the wall-clock delta is nominal. Any change that introduces or makes mandatory a workflow step for token savings, context reduction, isolation, review depth, or extra pass coverage must include an economics check before it lands:

- Expected token/context benefit.
- Expected wall-clock cost.
- Frequency of the step: per edit, per commit, per PR, per release, or scheduled.
- Failure/retry cost.
- Whether the step blocks the human or runs asynchronously.

**Ask tier:** changes expected to add more than 20% latency to common loops (edit, commit, review, dispatch, merge) require the tradeoff to be surfaced before merge, even when the token savings are real.

**Block tier:** changes expected to double or more than double wall-clock time in a common loop require explicit user approval before they become mandatory. Without that approval, move the work to the least frequent safe boundary, make it asynchronous, or keep it opt-in.

**Telemetry requirement:** new gates must emit or record timing telemetry before they become mandatory. At minimum, record start/end duration, the loop boundary where the gate ran, whether it blocked the human, and retry count or failure reason. Use measured baseline data when available; otherwise land the gate as opt-in or warn-only until baseline timing exists.

**Non-goal:** safety-critical checks are not rejected solely because they are slow. Preserve the safety property, but shift it to the least frequent safe boundary or run it asynchronously when possible.

### R23 — Field-agent cross-host review through wrapper only (tier: **block + auto-fix**)

Field-agent review setup in mode packs, briefs, manifests, scripts, and issue acceptance criteria must not hand-compose raw `claude -p` or `codex exec` reviewer commands. Route sibling-host / cross-host review through `scripts/phase-review.sh` or a successor wrapper that preserves reviewer auth-home selection, no-secret env scrubbing, MCP isolation, sandbox-readable payload handoff, and failure-detail surfacing.

If a Claude reviewer fails with Claude Code subscription/403 access errors, `scripts/phase-review.sh` may fall back to `codex-reviewer` and must surface `PHASE_REVIEW_FALLBACK_*` lines so callers record the degraded reviewer choice. User-controlled override: `STUDIO_DISABLE_PHASE_REVIEW_CLAUDE_403_FALLBACK=1`.

Legitimate mentions are allowed only when documenting the banned pattern, testing wrapper behavior, or using an explicit `lint-field-review:allow next-line` annotation with a reason. `STUDIO_BYPASS_FIELD_REVIEW_WRAPPER=1` is the documented emergency/debug override; it must be user-controlled and recorded in the plan/outcome artifact, never used silently by an assistant.

**How to check:** run `scripts/lint-field-review-surfaces.sh --staged`. The pre-commit hook runs it as Gate 2g.

**Fix pattern:** replace raw review-host snippets with:

```bash
scripts/phase-review.sh --review-host claude-reviewer --kind plan --input phase-plan.md --output ~/.dev-studio/generic-dev-studio/analysis/<date>-<phase>-plan-review.md
```

### R24 — Commit discipline and taxonomy (tier: **block + ask + warn**)

Commit discipline is part of review quality for host-routed changes:

- **Block (hard gate):**
  - Commit messages are missing an explicit taxonomy label (`feature`, `bugfix-shipped`, `bugfix-wip`, `regression-fix`, `refactor`, `docs`, `test`, `chore`, `release`) in the subject or body.
  - Feature-branch history includes merge commits before the PR merge/rebase path.

- **Ask (investigate before merge):**
  - Subject does not explain *why* the change was made.
  - Non-trivial change lacks `Problem`, `Solution`, or `Implementation notes` sections in the commit body.
  - Subject/body does not distinguish `bugfix-shipped` vs `bugfix-wip` for a bugfix change.

- **Warn (note but proceed unless risk increases):**
  - Missing or shallow `Caveats` for behavior-risky changes.
  - Host identity is only inferred from `Co-authored-by:` text while machine-readable host metadata exists in `.studio/chain-task-start.json` / `.studio/chain-worker-summary.json`.

**How to check:**
- Prefer machine-readable host identity from `.studio/chain-task-start.json` / `.studio/chain-worker-summary.json` (`host`, `model`, `model_version`) over parsing `Co-authored-by:` in commit footers.
- Verify the commit subject is imperative and change-oriented; use `git log`/`git show` on staged commits or PR payload to validate body structure.
- Verify taxonomy labels stay within the canonical set above.
- Block-and-ask findings should be explicit in review output; hard blocks must state the minimum fix.

## Deferred / known gaps

Not rules yet — track here so we remember:
- PID-recycling guard for workers (ROADMAP edge cases)
- Cross-project simulator name collision (phase 3 — only matters when 2+ iOS projects run in parallel)
- Per-project `config.yml` for override cases (phase 2 — lazy-created only)
- Stack modules (`ios-toolkit/`, etc.) as opt-in skills (phase 2)

## Rule evolution

When a review misses something or over-flags:
1. If it's a one-off, just correct the review.
2. If the pattern will recur, add or amend a rule here.
3. Rules that prove noisy for multiple cycles → downgrade tier or delete.

Cheap to change this file; expensive to let rules rot.
