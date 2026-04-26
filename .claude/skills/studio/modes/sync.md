---
name: Studio Sync
description: Re-sync all studio-managed skills to every installed AI provider. Ensures symlink farms are current after recipe changes, host installs, or drift.
type: mode-pack
schema_version: 1
budget_tokens: 300
snapshots: []
reads:
  - hosts/registry.yaml
  - skills/**/portability.yaml
writes:
  - ~/.claude/skills/, ~/.codex/skills/, etc. (symlinks only, via sync-host-skills.sh)
---

# Mode: Sync

Fired when the user wants to ensure all studio-managed skills are available on every installed AI provider. This is a mechanical re-fan-out — no discovery of unmanaged skills, no importing, no surprises.

For adding new skills to the workflow, use `/studio add <url>` instead.

## Step 1 — Run sync

```sh
scripts/sync-host-skills.sh --all
```

This:
1. Reads `hosts/registry.yaml` for all known hosts
2. Skips hosts whose CLI binary isn't on PATH (`detect_binary` check)
3. For each detected host, links every skill declaring `hosts: all` (or the specific host) into the host's global skill dir
4. Reaps stale symlinks from prior fan-outs
5. Injects skill routing instructions from `_shared/skill-routing.md` into each host's global instructions file (e.g. `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`) between `<!-- studio:skill-routing:start/end -->` markers
6. Audits the final state

## Step 2 — Report

Show the user:
- Which hosts were synced (and which were skipped)
- Any audit issues (drift, conflicts, missing canonicals)
- Total skills linked per host

If the sync is fully clean, one line is enough: "All N hosts in sync — M skills linked."

## When to suggest sync

- After `/studio add` (already auto-syncs, but mention sync exists)
- After pulling new commits that changed recipes or portability files
- After installing a new AI CLI (e.g., `brew install gemini-cli`)
- If `verify-install.sh` reports drift

## Error modes

- **No hosts detected** — all binaries missing from PATH. Suggest checking PATH or running from the right shell.
- **Audit failures** — DRIFT or CONFLICT on a symlink. Surface the specific path; suggest manual resolution.
