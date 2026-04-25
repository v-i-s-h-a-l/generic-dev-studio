# Ideas

Capture file for ideas that surface in conversation. `/capture` appends here retrospectively by scanning the recent session transcript. Promoted to GitHub issues when scoped; archived when shipped or rejected.

**Lifecycle:** `Captured` → `In design` → `Planned (#N)` → `Shipped` or `Archived`.

**Promotion rules:**
- Duplicates are merged into existing entries (see "Dedup" below).
- Items already tracked in `ROADMAP.md` §Phase sequence or open GitHub issues are *not* captured here — they're already preserved.
- Rejected-alternatives already listed in `ARCHITECTURE.md` §Design Vision are *not* captured here.

**Dedup:** `/capture` checks existing entries by keyword + theme overlap before appending. Matches update existing entries with a new date stamp; non-matches create new entries.

---

## Captured

- 2026-04-20 14:23 — Add a short "debrief-only" mode to Achilles (e.g., `/achilles debrief`) — for when the user fixes a bug directly in chat (no Chanakya brief, no worktree, no Argus). After the fix lands, invoke this mode and Achilles generates a Chanakya-format debrief from the conversation/diff. Most such bugs are tiny and skip unit/UI tests; if tests are needed, user tells Achilles explicitly and the debrief reflects that. Purpose: keep the ledger consistent even for ad-hoc direct-to-Claude fixes that bypass the normal brief → worktree → Argus pipeline. [theme/internal]

- 2026-04-25 12:00 — Multi-host skill distribution v1: per-skill `portability.yaml` (default `hosts: [claude-code]` until proven), neutral skill roots (`~/.dev-studio/skills/personal/`, `<repo>/skills/`, `<project>/.studio-skills/`) so `~/.claude/skills/` and `~/.codex/skills/` become destinations not sources, one fan-out script `scripts/sync-host-skills.sh` driven by a `hosts/registry.yaml` (skill_dir + routing_file + invocation_syntax: slash|prose|tool-call), migration is opt-in per skill gated on conformance. Breakable into 4 sub-issues: (a) portability.yaml schema + linter, (b) sync script + host registry, (c) AGENTS.md generator, (d) personal-skill migration. [theme/host-agnostic]

- 2026-04-25 12:01 — No-manual-sync design for cross-host skill distribution: solve content drift via Stow-style symlink farms (host skill_dir entries are symlinks into canonical roots, so SKILL.md edits propagate instantly with zero sync); solve structural drift with three overlapping triggers — SessionStart hook freshness check (mtime compare + cheap re-fan-out), macOS LaunchAgent WatchPaths on canonical roots (mirrors the existing `claude-dirs-maintenance` pattern), git `post-merge`/`post-checkout` hooks for pulled skill changes. Add a self-validating audit at the bottom of `sync-host-skills.sh` (every host-dir entry must symlink to a known canonical root; every declared host must have a matching symlink) gated behind `STUDIO_SKILL_AUDIT=1`. [theme/host-agnostic]

- 2026-04-25 12:02 — AGENTS.md prose-routing preamble for hosts without slash-command parity: Codex CLI 0.123 receives `/achilles T347` as a prompt string, not a dispatched command, so interactive-TUI parity needs a prose block at repo root teaching the model to interpret slash-style invocations ("if user types `/achilles <id>`, read `<repo>/achilles/SKILL.md` and follow it with that brief ID"). Today `AGENTS.md` is just a symlink to `CLAUDE.md` — needs to be host-shaped. The sync script should generate this routing block from the same portability metadata so AGENTS.md and CLAUDE.md never drift. [theme/host-agnostic]

- 2026-04-25 12:03 — Diagnostics scaffolding for first real Codex dispatch (#166): add `STUDIO_DEBUG=1` verbosity to `spawn-worker.sh` / `dispatch-review.sh` (log resolved capability manifest, env-after-scrub, spawn argv, event-tail position), and a post-run capture that archives event-log slice + debrief + verdict + host stderr to `~/.dev-studio/<project>/analysis/codex-smoke/<ts>/` so rough edges aren't lost. Off by default; load-bearing for the "let me run it a couple of times and we'll find out" workflow. [theme/observe]

- 2026-04-25 12:04 — Research gaps to close before committing to symlink-farm design: (1) Codex CLI's actual skill-discovery semantics — does `~/.codex/skills/` get read, are symlinks followed across filesystems, is discovery cached (caching defeats content-drift-via-symlink and forces back to active sync); (2) how `obra/superpowers` (cited prior art across 7 hosts) actually solves it — symlinks vs copies vs generator, and which problems they hit. ~30 min wall-time empirical poking would confirm or revise the load-bearing assumption. [theme/host-agnostic]

- 2026-04-25 12:05 — Studio skill consolidation refactor: top-level `chanakya/`, `achilles/`, `argus/`, `.claude/skills/studio/` all become `<repo>/skills/<name>/` to match the neutral-roots model. Significant churn (load-bearing scripts have hardcoded paths) — defer or bundle with multi-host v1. Related: existing `<project>/.claude/skills/` becomes a symlink to `<project>/.studio-skills/`; personal skills move from `~/.claude/skills/` to `~/.dev-studio/skills/personal/` with a back-symlink (or sync *from* `~/.claude/skills/` as canonical-for-now if zero-risk preferred). [theme/internal]

---

## In design

*(Empty — promoted when an idea becomes an active discussion thread.)*

---

## Planned

*(Empty — each entry links to the GitHub issue that tracks it.)*

---

## Archived

*(Empty — rejected or superseded ideas, one-line reason per entry.)*
