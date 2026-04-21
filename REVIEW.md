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
