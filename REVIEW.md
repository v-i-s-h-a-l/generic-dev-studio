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
When scripts change, check for cross-references in `chanakya/SKILL.md`, `achilles/SKILL.md`, `argus/SKILL.md`, `_shared/*.md`, `README.md`, `scripts/README.md`. Stale examples and old flag names are a drift risk given how many cross-refs exist.

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

### R9 — Dual-write preserved during Phase 2.6 transition (tier: **block + auto-fix**)
Any mode pack or script that mutates a Phase 2.6 artifact (tasks / briefs / rounds / releases / debriefs / reviews) MUST preserve the dual-write contract per `_shared/patterns/dual-write-transition.md`: YAML first, legacy counterpart second, partial-failure loud (`dual_write_partial` event + exit 3). AND, not OR.

**Why:** `scripts/verify-ledger.sh` caught T218a drift (#76) because a writer mutated the legacy brief markdown without the paired YAML update. The `lib-ledger.sh` helpers (`transition_*`, `write_*_artifact`) make this structurally impossible when used correctly; this rule catches regressions that bypass the helpers.

**How to check:**
- New mode pack writing a Phase 2.6 artifact? Check frontmatter has `transition_notes: _shared/patterns/dual-write-transition.md`. Grep-checkable.
- New script mutating `plans/<kind>/*.yaml`? Check it uses the `lib-ledger.sh` writers, not ad-hoc `yq -i`. If ad-hoc, must explicitly call the paired `legacy_*` helper before returning success.
- Any `OR`/`fallback`/`if YAML unavailable` language in prose around a dual-writer? That's the T218a shape. Tighten to explicit AND.

**Fix pattern:** replace ad-hoc YAML writes with `lib-ledger.sh` helper calls; add `transition_notes` frontmatter to the mode pack; tighten prose to AND-not-OR.

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

### R11 — No studio-initiated pushes to base branches (tier: **block + auto-fix**)

Scripts and mode prose must never run `git push origin main` (or `master`, or any equivalent integration/base branch) against a project or studio repo. Remote base branches advance **only** through PR merges. Studio-initiated pushes may target feature branches (`push -u origin HEAD`, `push origin <feature-branch>`) or tags (`push origin <tag>`). Integration happens via `gh pr create` / `gh pr merge`, never direct ref advancement.

**Why:** a studio-initiated `git push origin main` was observed bypassing an open PR (#3150), silently advancing the remote while review was still in flight. The PR-gated integration workflow is load-bearing for Argus review, CI, and human sign-off; direct base pushes erase all three gates.

**How to check:**
- `grep -rnE 'git\s+push.*(origin|upstream).*(main|master|trunk|develop)' scripts/ commands/ chanakya/ achilles/ argus/ _shared/` — expected: zero hits.
- `git push -u origin HEAD` while on a base branch counts as a violation. Scripts must guard with `[ "$(git symbolic-ref --short HEAD)" != "main" ]` or equivalent before any `push -u HEAD`.
- Any prose in a SKILL.md or mode file instructing the agent to "push to main" / "update remote main" / "push the merge" is a violation — replace with "open a PR" or "merge via `gh pr merge`".

**Exception:** partition-sync repos (e.g. `scripts/sync-shared-remote.sh` against `~/.dev-studio/.cache/…`) where `main` is the data-store trunk and each machine writes to a disjoint subdirectory. The exception applies only when the push target is a dedicated sync/data repo — never a code repo.

**Fix pattern:** replace `git push origin main` with the PR flow:
```
git push -u origin "$FEATURE_BRANCH"
gh pr create --base main --head "$FEATURE_BRANCH" ...   # or gh pr edit if it exists
```
If the intent was to land an already-merged commit, the merge should have happened via `gh pr merge` in the first place — the rule catches the rationalization.

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
