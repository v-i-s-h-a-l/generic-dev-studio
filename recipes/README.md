---
name: Skill Recipe System
description: How the studio curates skills — recipes, profiles, vendoring lanes, install + update workflow, supply-chain hygiene.
type: reference
schema_version: 1
---

# Skill Recipe System

Studio operates as a **package manager** for skills. The user (or a profile curator) declares which upstream skills to vendor; the studio fetches, validates, vendors, fans out to every adapted host, and tracks upstream changes via PR-based auto-update. New machines get a single-command bootstrap; supply-chain risk is bounded by license + author allowlists + diff-scan flags.

Schema versions: recipe.json v1, license-allowlist.yaml v1, trusted-authors.yaml v1.

## Layout

```
recipes/
├── README.md                       # this file
├── trusted-authors.yaml            # author allowlist (supply-chain firewall)
├── profiles/
│   └── ios.yaml                    # curator-recommended bundle for iOS dev
└── <author-or-domain>/
    └── <recipe-name>.yaml          # one recipe per upstream skill
```

Schemas + allowlists live under `_shared/standards/`:
- `recipe.json` — JSON Schema for `recipes/<author>/<name>.yaml`.
- `license-allowlist.yaml` — SPDX licenses install-recipe.sh accepts without override.

## Vendoring lanes

Every recipe declares one strategy:

| Strategy | When | Maintained by | Lives at |
|---|---|---|---|
| `verbatim` | Trusted upstream; want exact behavior | Periodic SHA bump (auto-pr) | `skills/vendored/<author>/<name>/` |
| `inspired` | Learned from upstream then rewrote in standard | Studio (no upstream tracking) | `skills/owned/<name>/` + `INSPIRED_BY.md` |
| `owned` | Studio-authored from scratch | Studio | `skills/owned/<name>/` |

Verbatim is the default for high-quality upstream content — preserves correctness at the cost of stylistic drift from the studio's Authoring Standard. Declare `authoring_standard: exempt` for verbatim recipes so the linter only validates frontmatter.

## Workflow

### Install one recipe

```sh
scripts/install-recipe.sh <recipe-name>
```

Steps:
1. Validates recipe via `lint-recipe.sh`.
2. Checks license against `_shared/standards/license-allowlist.yaml`. Override with `--override-license=<spdx>` (logged).
3. Checks author against `recipes/trusted-authors.yaml`. First-time authors trigger a one-time interactive approval prompt (or use `--auto-approve-author` for batch / CI mode).
4. For `verbatim`: shallow-clones upstream at `pinned_sha`, copies subpath into `skills/vendored/<author>/<name>/`.
5. Writes `<vendor-dir>/vendor.yaml` recording source + SHA + license + attribution.
6. Triggers `sync-host-skills.sh --all` to fan out to every adapted host.

### Install a curated profile

```sh
scripts/install-recommended.sh ios          # default profile
scripts/install-recommended.sh --list       # available profiles
```

Iterates `recipes/profiles/<profile>.yaml` calling `install-recipe.sh` per entry. Final fan-out is a single `sync-host-skills.sh --all` (not per-recipe) for efficiency.

### Update upstream-tracked recipes

```sh
scripts/update-recipes.sh                   # check + open PRs for all auto-pr
scripts/update-recipes.sh <recipe-name>     # single recipe
scripts/update-recipes.sh --dry-run         # report drift; no PRs
scripts/update-recipes.sh --no-pr           # bump + commit on current branch
```

For each recipe with `update_policy: auto-pr`, fetches the upstream HEAD via `git ls-remote`. On drift:
1. Branch off `main` as `skills-bump-<name>-<date>`.
2. Update recipe.yaml's `pinned_sha`.
3. Re-run `install-recipe.sh` to re-vendor at the new SHA.
4. Run `lint-skill-prose.sh` against the new content.
5. Run a diff-scan reporting URL count, protected-path writes, network-call shell tokens.
6. Commit + push branch.
7. Open PR titled `[skills] bump <name> @ <sha-short> — lint:✅` (or ❌).
8. Emit `pr_review_ready` event into the studio event log.
9. SessionStart hook surfaces the PR-awaiting-review banner on the next session.

PRs are **never auto-merged**. The 10-second human review of the diff is the supply-chain firewall. Trust-mode auto-merge is deferred to issue #170.

## Supply-chain hygiene

Three layers, each independently auditable:

### License allowlist

`_shared/standards/license-allowlist.yaml` lists SPDX licenses install-recipe.sh accepts. Bumping the list is a Skill Authoring Standard change; removing a license is a major bump with a deprecation window.

Override per-install: `--override-license=<spdx>` (the override is logged in the install output and recorded in vendor.yaml).

### Author allowlist

`recipes/trusted-authors.yaml` lists GitHub user/org slugs vendored without prompting. First-time authors trigger an interactive approval. The list grows over time; trust here is "this author's content is allowed to enter the vendoring pipeline" — NOT "land without review."

### Diff-scan in update PRs

Every auto-pr update runs a diff-scan against the new vendored content:
- `urls=N`: count of `https?://` references
- `writes=N`: paths in protected dirs (`/etc/`, `/usr/`, `$HOME/`, `~/`, etc.)
- `netcalls=N`: shell tokens like `curl`, `wget`, `nc`, `fetch`

The numbers go in the PR body. Material changes from prior versions warrant inspection before merge. Diff-scan is **informational** — never blocks a PR, just flags surface area.

## Per-project domain filtering

A project can constrain which skill domains appear in its routing prose by writing a `.skill-domains` file at the project root:

```
# .skill-domains
swift
swiftui
ios
```

`scripts/generate-routing.sh <host>` reads `.skill-domains` (cwd first, then repo root) and filters skills whose `routing.yaml` declares any matching domain. Skills exist on disk but stay out of routing for non-matching projects — keeps context lean as recipe count grows.

## Adding a recipe

1. Find the upstream — `github.com/<author>/<repo>` containing the skill source.
2. Pin a SHA — usually `git ls-remote https://github.com/<author>/<repo>.git HEAD` then take the SHA.
3. Identify the SPDX license (LICENSE file in the upstream repo).
4. Write `recipes/<author>/<name>.yaml` against `_shared/standards/recipe.json`.
5. Add `<author>` to `recipes/trusted-authors.yaml` if not already present (or accept the install-time prompt).
6. Run `scripts/install-recipe.sh <name>` — fetches, validates, vendors, fans out.
7. (Optional) Add `<name>` to `recipes/profiles/<profile>.yaml` if it belongs in a curated bundle.

## Schema migration

The schema version of `recipe.json` and the allowlist files is `1`. Breaking changes (e.g. new required field, removed enum value) bump the major; the linter accepts both N and N+1 during a transition window then drops support for the older version once every recipe has migrated. The transition is managed via `_shared/contracts/EVOLUTION.md`.

## Out of scope (deferred)

- **Tier 1 routing composites** — mechanical shims that dispatch to overlapping recipes by sub-trigger. Issue #170; gated on 2-4 weeks of MVP use.
- **Tier 2 synthesis composites** — model-generated merge of multiple constituent skills. Issue #171; parking-lot.
- **Trust-mode auto-merge** — opt-in per recipe for highly-trusted authors. Issue #170.
- **Interactive `studio init` wizard** — replaces the one-shot `install-recommended` for new-machine setup. Issue #170.
- **LaunchAgent for cron-replacement updates** — Issue #170.
