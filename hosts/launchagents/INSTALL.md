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

### macOS TCC caveat (Sequoia / 15+)

If your studio repo lives inside `~/Documents/`, `~/Downloads/`, `~/Desktop/`, or any other TCC-protected location, the LaunchAgent will fail with `Operation not permitted` because launchd processes do not inherit Full Disk Access by default. The repo itself is fine for interactive use (you've granted Terminal/iTerm full disk access historically); the LaunchAgent runs outside that context.

Three resolutions, in increasing order of permanence:

1. **Skip the LaunchAgent.** The SessionStart freshness check + git post-merge hook cover ~99% of real drift. The LaunchAgent is incremental coverage; not having it is acceptable. Run `scripts/install-skill-launchagent.sh --uninstall` to clean up if it's been installed.
2. **Move the repo outside TCC-protected dirs.** A clone at `~/work/generic-dev-studio/` or `~/code/generic-dev-studio/` works without any FDA grants.
3. **Grant Full Disk Access to launchd.** System Settings → Privacy & Security → Full Disk Access → "+" → ⌘⇧G `/sbin/launchd`. Heaviest hammer; affects every LaunchAgent on the system. Only do this if you understand the security tradeoff.

Detection: after install, check `~/.dev-studio/.runtime/logs/skill-fanout.err`. Any `Operation not permitted` line indicates TCC is blocking; choose one of the resolutions above.

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
