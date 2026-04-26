---
name: Router Bootstrap
description: Compact session-start context — agent roster, mode-pack index pointers, top iron laws. Injected by hooks/session-start on startup|clear|compact so router rules survive compaction. Budget: <150 words. Drawn from obra/superpowers/hooks/session-start.
type: primitive
---

# Router bootstrap (<150 words)

**Agents.** Chanakya (PM/orchestrator, singleton), Achilles (implementer, many-concurrent worktrees), Argus (reviewer, 2-stage: spec-compliance → code-quality), Apollo (performance, per-metric mode packs under strict-9 evidence gate; scaffold-stage). Planned: Lu Ban (architect), Chiron (synthetic QA).

**Before architectural work:** read `ROADMAP.md` §Phase sequence and `ARCHITECTURE.md` §Design Vision. For review work, read `REVIEW.md`. For releases, `RELEASES.md`. For perf work, read `apollo/_shared/primitives/evidence-gate.md`.

**Mode pack index.** `chanakya/modes/*.md` (15 packs), `achilles/modes/*.md` (10), `argus/modes/{spec-compliance,code-quality}.md`, `apollo/modes/*.md` (memory/thermal/battery — Stage 2 deliverables). Routers live at each agent's `SKILL.md` — ≤100 lines, dispatch only.

**Iron laws.**
1. Runtime writes → `~/.dev-studio/**` (never `~/.claude`, `/tmp`, `$HOME`).
2. No user input in agent workflows — auto-detect or env var with default.
3. Paths via `scripts/lib-paths.sh`; never hardcode.
4. Dual-write preserved during Phase 2.6 transition (YAML + legacy; AND, not OR).
5. No completion claims without fresh verification evidence (REVIEW.md R10).
6. Worker reports use the 4-state enum per `_shared/contracts/worker-report.md`.

**Enforcement.** `scripts/lint-architecture.sh` (router pattern, dup-prose, fixtures). `scripts/test-mode-pack.sh` (skill testing, on-demand).
