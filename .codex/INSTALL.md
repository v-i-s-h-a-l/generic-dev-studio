# Codex Adapter — Install Guide

Sets up the generic-dev-studio for use with the OpenAI Codex CLI (v0.120+). After completing these steps, Achilles and Argus run on Codex identically to how they run on Claude Code.

## Prerequisites

- Codex CLI v0.120 or later (hooks support added in v0.120).
- `jq` and `yq` installed (same as the Claude Code requirement).
- Repo cloned to a local path.

## Quick start

```sh
scripts/install.sh
```

This installs Claude Code links and then runs `sync-host-skills.sh --all`, which auto-detects Codex on PATH and creates symlinks at `~/.codex/skills/` for every skill declaring `hosts: all` in its `portability.yaml`.

## What gets linked

- **Agents:** `achilles`, `argus` (Chanakya is Claude Code-only today; see #141)
- **Companions:** `_shared`, `scripts` (so SKILL.md relative paths resolve)
- **Vendored skills:** all skills in `skills/vendored/` and `skills/owned/` that declare `hosts: all`

## Root instruction file

Codex reads `AGENTS.md` at the repo root as its primary instruction file. This is a symlink to `CLAUDE.md`.

## Hooks

`.codex/hooks-codex.json` (symlink to `hooks/hooks-codex.json`) wires session-start hooks. Point Codex at it:

```sh
export CODEX_HOOKS_CONFIG=".codex/hooks-codex.json"
```

## Verify

```sh
scripts/verify-install.sh        # audits all detected hosts including Codex
scripts/sync-host-skills.sh codex --audit-only   # Codex-only audit
```

## Conformance test

```sh
scripts/test-host.sh codex       # 4 happy-path + 4 failure-mode tasks
```

All tasks must PASS before the adapter is considered production-ready. By default uses the mock shim at `tests/conformance/mock-codex/`; set `STUDIO_CODEX_BIN` to test against a real Codex binary.

## Notes

- Codex's `sandbox_profile: workspace-write` satisfies the Achilles security floor (see `hosts/ADAPTER-SPEC.md`).
- Codex does **not** walk parent directories for `AGENTS.md` — it must be at the cwd.
- Codex scans `~/.codex/skills/` + `<cwd>/.codex/skills/` (merged, symlinks followed).
