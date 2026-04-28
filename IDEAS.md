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

- 2026-04-25 12:03 — Diagnostics scaffolding for first real Codex dispatch (#166): add `STUDIO_DEBUG=1` verbosity to `spawn-worker.sh` / `dispatch-review.sh` (log resolved capability manifest, env-after-scrub, spawn argv, event-tail position), and a post-run capture that archives event-log slice + debrief + verdict + host stderr to `~/.dev-studio/<project>/analysis/codex-smoke/<ts>/` so rough edges aren't lost. Off by default; load-bearing for the "let me run it a couple of times and we'll find out" workflow. [theme/observe]

- 2026-04-25 12:04 — Research gaps to close before committing to symlink-farm design: (1) Codex CLI's actual skill-discovery semantics — does `~/.codex/skills/` get read, are symlinks followed across filesystems, is discovery cached (caching defeats content-drift-via-symlink and forces back to active sync); (2) how `obra/superpowers` (cited prior art across 7 hosts) actually solves it — symlinks vs copies vs generator, and which problems they hit. ~30 min wall-time empirical poking would confirm or revise the load-bearing assumption. [theme/host-agnostic]
  - Updated 2026-04-25 — Codex 0.123 empirical findings (gap closed): scans `~/.codex/skills/` + `<cwd>/.codex/skills/` merged; follows symlinks; resolves to canonical paths; **no caching across `codex exec` invocations** (TUI session caches in-process only) — symlink-farm design is viable; AGENTS.md does **not** parent-dir walk; `<repo>/skills/` is **not** auto-discovered. [theme/discovery]

- 2026-04-25 13:02 — Three-bucket drift typology for skill design (mental model, not implementation): **contract-anchored drift** (mitigated by JSON schemas + linters — already in scope), **model-dependent drift** (mitigated by deterministic verbs, decision tables not nested conditionals, SKILL.md-as-grammar — Phase A), **interpretation drift** (mitigated by sentinel vocabulary STOP/PROCEED/RETRY/SKIP/ESCALATE/EMIT/RECORD/BLOCK + numbered procedures + pre/post-conditions). Useful framework for sequencing future skill-quality work and explaining *why* the Authoring Standard takes the shape it does. [theme/internal]

- 2026-04-28 08:35 — Forge/Field doctrine: make `Forge` the repo's official control-plane term and `Field` the Apple-project execution plane. Forge should first dogfood orchestration automation on its own work: conversation/web intake, key-tap triage, issue graph links, phase planning, and quantitative reliability gates. Field ingestion sources such as Slack, PRDs, and Figma stay out of Forge until a specific Forge mode adopts them. [theme/internal]

- 2026-04-28 08:36 — Studio model roles as a future host-agnostic control surface: define roles such as `forge-architect`, `forge-verifier`, `forge-editor`, and `forge-triage`, then let a studio sub-command or wrapper spawn a fresh host session with the right model capability. Default provider can be OpenAI/Codex, but explicit provider requests such as Anthropic should resolve through the same role map instead of hardcoded commands. [theme/host-agnostic]

- 2026-04-28 08:37 — Host-agnostic capture wrapper: existing `/capture` is useful but Claude-shaped through transcript paths and the Agent tool. Future work should preserve the behavior (dedupe session ideas into `IDEAS.md`, remind when pickable) behind a Forge wrapper that can read host-specific transcript/session state through adapters. [theme/host-agnostic]

---

## In design

*(Empty — promoted when an idea becomes an active discussion thread.)*

---

## Planned

Promoted from Captured on 2026-04-25 — implementation tracked in GitHub issues:

**Phase 1 — Host infrastructure (next up)**
- Skill Authoring Standard v1 (grammar + sentinel vocabulary + linter + scaffold + per-host routing generator) → **#167**
- Multi-host skill distribution v1 (Stow-style symlink farms + portability.yaml + 3-trigger drift detection: SessionStart freshness + LaunchAgent WatchPaths + git post-merge; borrows polyglot `run-hook.cmd` + env-var payload-shape sniffing from `obra/superpowers`; AGENTS.md prose-routing generator) → **#168**
- Migrate studio agents to portable skill standard (Achilles/Argus/Chanakya/studio router; folds in studio skill consolidation refactor) → **#172**

**Phase 2 — Skill curator (after Phase 1)**
- Skill recipe system v1 MVP (curated iOS profile + install/update + PR-based auto-update + PR-notification spec [event + SessionStart one-liner + osxnotifier + iMessage + studio status row + lint-encoded titles] + license/author allowlists + per-project domain filter + migrate existing `~/.claude/skills/` + `imported` sub-strategy + add-personal-recipe path) → **#169**
- Skill recipe system v2 (Tier 1 routing composites + interactive `studio init` wizard + LaunchAgent for auto-update + trust-mode opt-in per recipe) → **#170**
- Skill recipe system v3 (Tier 2 model-assisted prose synthesis composites; parking-lot, only if Tier 1 proves insufficient) → **#171**

---

## Archived

*(Empty — rejected or superseded ideas, one-line reason per entry.)*
