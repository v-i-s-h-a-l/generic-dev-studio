---
name: Capability Manifest CHANGELOG
description: Human-readable log of changes to the generated capability manifest. Schema-version bumps and the mode additions / removals they track. Appended to on every meaningful change — not every regeneration.
type: reference
---

# Capability Manifest — CHANGELOG

Append one entry per semantic change (new mode, removed mode, schema-version bump, breaking frontmatter change). Do NOT append for cosmetic regenerations (whitespace, description edits without surface changes).

Format:

```
## <schema-version> — <YYYY-MM-DD>
- <change type>: <what>
```

## 1.0.0 — 2026-04-22

- Initial publication. Manifest surfaces every agent in the repo with a `modes/` subdir (achilles, argus, chanakya) and their mode packs. Router-level `reads` / `writes` are computed as the union of mode-pack declarations; most mode packs do not yet declare these surfaces (Commit D landed the linter in warn-only mode; mode packs adopt `reads:` / `writes:` in Phase 2.6 rewrites). Per-mode `dry_run` defaults to `false` until mode packs opt in.
