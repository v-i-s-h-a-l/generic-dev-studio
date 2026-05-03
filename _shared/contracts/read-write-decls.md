---
name: Read/Write Declarations
description: Mode-pack frontmatter declares the reads + writes it will perform. Pre-commit lint validates; no runtime write-guard. Router-level reads/writes are auto-synthesized by the capability manifest.
type: reference
---

# Read/Write Declarations

Every mode pack declares the filesystem surface it reads and writes in its frontmatter. The declaration is static-validated by the pre-commit linter — never enforced at runtime (see Q11 in `PHASE-2-5-PLAN.md`). Runtime guards cost agent context; static validation catches the drift that matters.

## Frontmatter shape

```yaml
---
name: Chanakya Brief
description: …
type: mode-pack
snapshots: []
budget_tokens: 4500
reads:
  - ~/.dev-studio/<project>/plans/master-plan.md
  - ~/.dev-studio/<project>/events/**.jsonl
writes:
  - ~/.dev-studio/<project>/plans/chanakya-tasks/*.md
  - ~/.dev-studio/<project>/events/<today>.jsonl
---
```

## Rules

1. **Paths may use placeholders.** `<project>` expands via `scripts/lib-paths.sh` (`resolve_project`). `<today>` expands to `date -u +%Y-%m-%d`. Placeholders make the declaration portable across projects and days.
2. **Globs allowed.** `*.md`, `**.jsonl` are fine. The linter treats them as patterns; the runtime resolver expands them.
3. **Empty list = `[]`.** A mode with no filesystem side-effects declares `reads: []` and/or `writes: []` explicitly. Omission trips `E_MISSING_RW_DECL`.
4. **Routers are exempt.** `SKILL.md` does not carry `reads` / `writes` — the router delegates to mode packs, and the mode packs declare their own surfaces. Router-level surfaces are **auto-synthesized** as the union of all declared surfaces by `scripts/capability-manifest.sh`. Never hand-maintained.
5. **Linter is the enforcement.** `E_MISSING_RW_DECL` (block) on any `modes/*.md` without both keys. No runtime filesystem hooks.
6. **Declarations are informational in prose.** Mode-pack prose doesn't need to repeat the list; the frontmatter is canonical.

## Example — Achilles task mode

```yaml
---
name: Achilles Task
description: …
type: mode-pack
snapshots: []
budget_tokens: 6000
reads:
  - ~/.dev-studio/<project>/plans/chanakya-tasks/*.md
  - ~/.dev-studio/<project>/events/**.jsonl
  - ~/.dev-studio/<project>/.runtime/achilles-inbox/**/*.task
writes:
  - ~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml
  - ~/.dev-studio/<project>/worktrees/*
  - ~/.dev-studio/<project>/events/<today>.jsonl
  - ~/.dev-studio/<project>/locks/*
---
```

## Non-goals

- Runtime write-guard. Explicitly rejected (Q11). Invisible to the main agent during orchestration.
- Per-invocation precision. The declaration is the superset of what the mode could touch; it doesn't change per-run.
- Cross-mode refs. A mode does not declare surfaces consumed through another mode; the other mode declares those.

## Related

- `rules/enforcement-contract.md` — `E_MISSING_RW_DECL` code and fix recipe.
- `patterns/capability-manifest.md` — aggregates all mode-pack declarations into a roster.
- `primitives/file-locations.md` — canonical root paths that show up in declarations.
- `primitives/agent-comms-boundary.md` — authoritative writer / co-writer / reader matrix that these declarations are linted against.
