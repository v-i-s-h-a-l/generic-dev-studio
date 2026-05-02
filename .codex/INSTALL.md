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
- **Project-scoped studio router:** `.codex/skills/studio` points at the canonical `.claude/skills/studio` router, so `$studio` is visible only inside this repo.

## Root instruction file

Codex reads `AGENTS.md` at the repo root as its primary instruction file. This is a symlink to `CLAUDE.md`.

## Hooks

`.codex/hooks-codex.json` (symlink to `hooks/hooks-codex.json`) wires session-start hooks. Point Codex at it:

```sh
export CODEX_HOOKS_CONFIG=".codex/hooks-codex.json"
```

## Permissions

Codex must be able to write the studio runtime root as well as the active project worktree. This is the Codex equivalent of the Claude `permissions.allow` entries in the main README; without it, Achilles build gates can still prompt when they write `~/.dev-studio/**` or per-task DerivedData.

One-shot launch:

```sh
codex --sandbox workspace-write --add-dir ~/.dev-studio
```

Persistent config in `~/.codex/config.toml`:

```toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
writable_roots = ["/Users/<you>/.dev-studio"]
```

For unattended workers, also use the non-interactive approval policy:

```sh
codex --sandbox workspace-write --add-dir ~/.dev-studio --ask-for-approval never
```

## GitHub Auth Parity

Codex worker sessions must launch with the same login `HOME`, keychain, ssh-agent, and GitHub credential-helper surface that Claude-backed sessions use. The studio chain runner sets `HOME` to the login home before spawning Codex so `gh` and `git` see the user's normal credentials instead of a scratch home.

Before task work starts, `scripts/host-preflight.sh <host> <repo-root>` runs:

```sh
gh auth status
git -C <repo-root> ls-remote --exit-code "$(git -C <repo-root> remote get-url origin)" HEAD
```

The second check is the credential-helper proof for later fetch and commit-resolution steps. If either check fails, the session stops before edits. Emergency bypass: `STUDIO_BYPASS_GITHUB_AUTH_PREFLIGHT=1`, which is intentionally loud.

## Verify

```sh
scripts/verify-install.sh        # audits all detected hosts including Codex
scripts/sync-host-skills.sh codex --audit-only   # Codex-only audit
scripts/host-preflight.sh codex /path/to/private/project
```

## Conformance test

```sh
scripts/test-host.sh codex       # 4 happy-path + 4 failure-mode tasks
```

All tasks must PASS before the adapter is considered production-ready. By default uses the mock shim at `tests/conformance/mock-codex/`; set `STUDIO_CODEX_BIN` to test against a real Codex binary.

## Notes

- Codex's `sandbox_profile: workspace-write` satisfies the Achilles security floor when `~/.dev-studio` is included as a writable root (see `hosts/ADAPTER-SPEC.md`).
- Codex does **not** walk parent directories for `AGENTS.md` — it must be at the cwd.
- Codex scans `~/.codex/skills/` + `<cwd>/.codex/skills/` (merged, symlinks followed).
