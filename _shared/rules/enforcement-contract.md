---
name: Enforcement Contract
description: Machine-readable error codes emitted by scripts/lint-architecture.sh, each paired with a fix recipe. Authoritative reference when a pre-commit hook rejects a change.
type: reference
---

# Enforcement Contract

Every violation emitted by `scripts/lint-architecture.sh` carries a code from the table below. Lines are formatted as:

```
<CODE>:<file>[:<line>]:<detail> | <fix-hint>
```

Claude sessions and humans alike use this file to resolve failures without guessing. The goal is self-healing: every `E_` row has a mechanical fix; every `W_` row has a signal to evaluate.

## Block-tier (E_) — commit is rejected

| Code | When | Fix recipe |
|---|---|---|
| `E_ROUTER_SIZE` | `<skill>/SKILL.md` prose exceeds 100 lines once a `modes/` subdir exists | Move mode-specific prose out of the router into `<skill>/modes/<pack>.md`. Router keeps frontmatter + one-paragraph intro + dispatch table + intent rules only. |
| `E_CROSS_MODE_LOAD` | A file under `<skill>/modes/` references another path matching `modes/*.md` | Remove the import. Mode packs communicate via snapshots (filesystem artifacts), never by loading each other. See `_shared/patterns/router-pattern.md` §2. |
| `E_MISSING_SNAPSHOTS_DECL` | A mode pack lacks a `snapshots:` key in its frontmatter | Add `snapshots: []` (empty) or list the snapshot filenames the mode reads/writes. Declaring this up front is part of the mode-pack contract. |
| `E_FRONTMATTER` | A `_shared/*.md` or `*/modes/*.md` is missing required keys (`name`, `description`, `type`) | Add the missing keys at the top of the file between `---` fences. |
| `E_SURFACE_REMOVED` | An entry disappears from `docs-surface.json` between HEAD and staged | Removing a sub-command or command is a breaking change per RELEASES.md. Either restore the entry or escalate to ask-tier review before proceeding. |
| `E_DUP_PROSE` | Two or more files share an identical 10-line window | Extract the duplicated passage into `_shared/<topic>.md` and reference it from both. Prevents the documentation rot the router pattern was introduced to fix. |
| `E_MODE_SIZE` | A mode pack exceeds 600 lines of prose | Split the mode into two packs along a natural workflow boundary. 400–600 lines is a warning; above 600 is a hard block. |
| `E_MISSING_RW_DECL` | A `modes/*.md` lacks `reads:` or `writes:` frontmatter keys | Add `reads: []` / `writes: []` (empty list is a valid declaration — the key's presence is the point). Routers are exempt; their surfaces are auto-synthesized from mode packs. See `_shared/contracts/read-write-decls.md`. |
| `E_UNKNOWN_CONTRACT_REF` | A reference to `_shared/<subdir>/<file>` in prose does not resolve to an existing file | Move/rename the target, or fix the reference path. Matches repo-relative (`_shared/...`) and absolute (`~/.claude/skills/_shared/...`) forms. |
| `E_ORPHAN_FIXTURE` | A file under `tests/mode-packs/` names a `pack:` that no longer exists, or omits the `pack` field | Pack was renamed/removed — update the fixture's `pack:` field to match, or delete the fixture if the pack is gone. See `_shared/primitives/skill-testing.md`. |

## Warn-tier (W_) — stderr only, commit proceeds

| Code | When | Evaluate |
|---|---|---|
| `W_MODE_SIZE` | Mode pack prose between 400 and 600 lines | Plan a split at the next refactor. Not urgent. |
| `W_SNAPSHOT_FRESHNESS` | Mode declares non-empty `snapshots:` but never mentions `stale` or `freshness` | Either add a freshness check section to the mode pack, or confirm the snapshot is always regenerated on read. |
| `W_BUDGET_DRIFT` | Mode pack token estimate exceeds its `_shared/schemas/token-budgets.json` entry by more than 10% | Trim prose, or raise the budget deliberately if the mode genuinely grew. |
| `W_CAPABILITY_STALE` | `_shared/schemas/capability-manifest.json` is older than any `modes/*.md` file | Run `scripts/capability-manifest.sh --regen`. Never promoted to block — user regenerates intentionally during analysis sessions. |
| `W_MISSING_PACK_FIXTURE` | A mode pack (or agent `SKILL.md` with a sibling `modes/` dir) has no fixture at `tests/mode-packs/<agent>/<name>.yaml` | Author a fixture per `_shared/primitives/skill-testing.md` — `scripts/test-mode-pack.sh scaffold <agent>/<name>` writes a skeleton. Warn-tier by design; onboarding gradient, not a hard gate. |

## Emergency bypass

Setting `ARCH_LINT=0` disables the pre-commit enforcement for one commit:

```bash
ARCH_LINT=0 git commit -m "…"
```

**Rules:**
- Use for hotfixes only — production is stranded and the lint failure is orthogonal.
- When bypassed, the pre-commit hook auto-opens a follow-up GitHub issue (label `polish, theme/internal`) so the violation does not rot.
- Repeated bypass of the same rule indicates either the rule is wrong or the codebase is drifting; either gets escalated at the next weekly review.

Bypass leaves a paper trail: the `ARCH_LINT=0` env is visible in the commit's reflog entry if recorded, and the auto-issue references the commit SHA.

## Scope

- Pre-commit hook runs the linter with `--staged`, so only files in the commit are evaluated for per-file checks.
- Cross-file checks (`E_DUP_PROSE`, `E_SURFACE_REMOVED`, `W_CAPABILITY_STALE`) always scan the full tree — duplication, surface-removal, and manifest staleness are not local concerns.
- `_shared/patterns/router-pattern.md` and `_shared/patterns/singleton-invariants.md` are the source of truth for why these rules exist. This file is the operational mapping.
