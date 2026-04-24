# Codex Adapter — Install Guide

Sets up the generic-dev-studio for use with the OpenAI Codex CLI (v0.120+). After completing these steps, Achilles and Argus run on Codex identically to how they run on Claude Code.

## Prerequisites

- Codex CLI v0.120 or later (hooks support added in v0.120).
- `jq` and `yq` installed (same as the Claude Code requirement).
- Repo cloned to a local path.

## 1 — Symlink canonical content

Codex discovers skills, agents, and commands from the repo root. The canonical content lives there already; no symlinks are needed for the core skills.

For any host-specific overrides, place them under `.codex/` and prefix them so they don't shadow canonical names:

```sh
# No-op for standard setup. Custom skill overrides go here if needed.
ls .codex/
```

## 2 — Root instruction file

Codex reads `AGENTS.md` at the repo root as its primary instruction file (created in H7; forward-reference). If `AGENTS.md` does not yet exist, create a placeholder:

```sh
# Placeholder until H7 lands
echo "See CLAUDE.md for full instructions." > AGENTS.md
```

Once H7 ships, `AGENTS.md` will be a first-class file at the repo root with shared content between Claude Code (`CLAUDE.md`) and Codex.

## 3 — Wire hooks

Codex reads its hook configuration from `.codex/hooks-codex.json` (created in H8; forward-reference). Once H8 ships, point Codex at it:

```sh
# Codex CLI hook config (set in your Codex workspace settings or shell env)
export CODEX_HOOKS_CONFIG=".codex/hooks-codex.json"
```

The hook scripts themselves are canonical under `hooks/` at the repo root. `hooks-codex.json` maps Codex's hook event names to those scripts.

## 4 — Verify capabilities

```sh
python3 -c 'import yaml, sys; yaml.safe_load(open(sys.argv[1]))' .codex/capabilities.yaml && echo "capabilities.yaml: OK"
```

## 5 — Run conformance test

Once `scripts/test-host.sh` is available (H10), verify the adapter end-to-end:

```sh
scripts/test-host.sh codex
```

All four tasks must PASS before the adapter is considered production-ready.

## Notes

- Codex's `sandbox_profile: workspace-write` satisfies the Achilles security floor (see `hosts/ADAPTER-SPEC.md §Security floor`).
- Tool dialect is `openai` — mode packs that reference tools by name use OpenAI tool vocabulary when running on Codex. The canonical mode packs are dialect-neutral; tool-specific references live in host-adapter overlays.
