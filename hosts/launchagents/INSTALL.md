---
name: Skill-Fanout LaunchAgent
description: macOS LaunchAgent that fans out skill symlinks to every adapted host whenever canonical skill content changes. One leg of the three-trigger drift-detection net.
type: reference
schema_version: 1
---

# Skill-Fanout LaunchAgent

Watches the studio's canonical skill roots (`achilles/`, `argus/`, `chanakya/`, `.claude/skills/`, `skills/owned/`, `skills/vendored/`, `_shared/standards/`, `hosts/registry.yaml`). On any mtime change, fires `scripts/sync-host-skills.sh --all` to refresh the symlink farm at every host's discovery dir.

## Why this exists

The symlink farm propagates content edits to every host for free (a SKILL.md edit shows up immediately at `~/.codex/skills/<name>/SKILL.md` because `<name>` is a symlink). Structural changes — adding a new skill, removing one, widening `portability.yaml hosts:` — require new or removed symlinks. The three-trigger drift net catches these:

| Trigger | Catches |
|---|---|
| `hooks/session-start` freshness check | Drift since last session start, on the host being booted |
| `.githooks/post-merge` | Drift introduced by `git pull` / `git merge` |
| **This LaunchAgent** | Drift introduced by `git checkout`, manual edits between sessions, IDE saves on a different host |

Each trigger alone covers ~99% of real drift. All three together approach completeness.

## Install

```sh
scripts/install-skill-launchagent.sh
```

This renders `com.dev-studio.skill-fanout.plist.template` with your repo path + `$HOME` + an auto-detected `WatchPaths` list, writes the plist to `~/Library/LaunchAgents/`, and `launchctl load`s it. Re-running is idempotent: byte-identical plist → no-op. WatchPaths is regenerated fresh each install, so you can re-run after adding new skills to refresh the watch set.

## Uninstall

```sh
scripts/install-skill-launchagent.sh --uninstall
```

Unloads the LaunchAgent and removes the plist.

## Logs

`~/.dev-studio/.runtime/logs/skill-fanout.{out,err}` — captured stdout/stderr from each invocation. Rotated by macOS log policy.

## Throttling

`ThrottleInterval = 60` — the LaunchAgent fires at most once every 60 seconds even if many files change in a burst (e.g. during a `git pull`). Trades latency for quietness; intentional.

## Non-macOS hosts

`scripts/install-skill-launchagent.sh` exits silently on non-Darwin hosts. The other two triggers (SessionStart freshness check + git post-merge hook) are sufficient cross-session safety nets without a watcher daemon.
