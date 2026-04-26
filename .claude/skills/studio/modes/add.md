---
name: Studio Add Skill
description: Add a skill from a git URL to the studio — auto-generates a recipe, vendors the skill, and fans it out to every installed AI provider in one command.
type: mode-pack
schema_version: 1
budget_tokens: 600
snapshots: []
reads:
  - recipes/ (existing recipes, for duplicate detection)
  - recipes/trusted-authors.yaml
  - _shared/standards/license-allowlist.yaml
  - hosts/registry.yaml
writes:
  - recipes/<author>/<name>.yaml (new recipe)
  - skills/vendored/<author>/<name>/ (vendored skill content)
  - ~/.claude/skills/, ~/.codex/skills/, etc. (symlink fan-out via sync-host-skills.sh)
---

# Mode: Add Skill

Fired when the user wants to add a skill from a git URL (or mentions adding a third-party skill). This is the primary entry point for skill acquisition — one URL in, skill available on every installed AI provider out.

## Step 1 — Collect the URL

If the user provided a URL in their message, use it directly. Accept:
- `https://github.com/<author>/<repo>`
- `github.com/<author>/<repo>`
- `git@github.com:<author>/<repo>.git`

If no URL was provided, ask for one. One question only.

If the repo contains multiple skills, the script will list them. Ask the user which one (or offer to install all).

## Step 2 — Run add-skill.sh

Execute:

```sh
scripts/add-skill.sh <url> [--path=<subpath>] [--auto-approve] [--dry-run]
```

Flags:
- `--path=<subpath>` — if the user specified a skill within a multi-skill repo
- `--name=<name>` — if the user wants to override the skill name
- `--domain=<d1,d2>` — if the user specifies domains
- `--auto-approve` — add if the author is already in trusted-authors.yaml; otherwise the script will prompt interactively
- `--dry-run` — if the user asked to preview first

The script handles: clone → SKILL.md discovery → license detection → author trust gate → recipe generation → vendoring via install-recipe.sh → host fan-out via sync-host-skills.sh --all.

## Step 3 — Report results

On success:
1. Name the skill that was added and its source
2. List which hosts received the symlink (from sync-host-skills.sh output)
3. Note the recipe path for future reference
4. Suggest: "Run `/studio add <url>` again to add more, or `scripts/update-recipes.sh` to check for upstream updates."

On failure, surface the specific error:
- **No SKILL.md found** — upstream repo doesn't have a SKILL.md; suggest creating the recipe manually
- **License not in allowlist** — tell the user which license was detected and how to override
- **Author not trusted** — explain the first-time trust gate; offer to approve
- **Recipe already exists** — point to the existing recipe and suggest `install-recipe.sh` for updates

## Step 4 — Commit (auto-apply tier)

Adding a skill through `/studio add` is auto-apply tier per CLAUDE.md — the user explicitly initiated it. Commit the new recipe + vendored content in a single commit:

```
#198 — add skill: <name> from <author> (via /studio add)
```

Do not push unless the user asks.

## Error modes

- **Multi-skill repo, no --path** — script lists all skills; ask the user to pick
- **Git clone fails** — likely a private repo or typo; surface the error
- **Script not executable** — run `chmod +x scripts/add-skill.sh` and retry

## Fixture

`tests/mode-packs/studio/add.yaml` — validates URL parsing, dry-run output, duplicate detection, and license gate messaging.
