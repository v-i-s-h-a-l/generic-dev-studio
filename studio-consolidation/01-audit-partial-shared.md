# 01-audit, partial — `_shared/**` substrate

**Source:** Session B Explore agent (id `af159edc`), completed 2026-04-24.
**Scope:** every file under `_shared/contracts/`, `_shared/patterns/`, `_shared/primitives/`, `_shared/rules/`, `_shared/state-machines/`, `_shared/schemas/`. Pure inventory.

**Total files:** 70 (contracts 16 incl. 5 brief-format templates; patterns 8; primitives 13; rules 5; state-machines 5; schemas 18; README 1).

---

## `contracts/`

### agent-boot.md
- **Purpose:** Minimal payload for the one `agent_boot` event every session emits on first write.
- **Key claims:** Payload = `agent` + `git_sha` + `skill_version`; emitted once per session on first write; read-only sessions never emit; idempotency key `<agent>:agent-boot:<session-id>`; ref impl `scripts/emit-agent-boot.sh`; sentinel `~/.dev-studio/<project>/.runtime/agent-boot-sent-<session-id>` prevents re-emission.
- **Refs:** `schema-version.md`, `events.md`, `patterns/chanakya-principles.md`.
- **Drift:** none.

### build-message-format.md
- **Purpose:** Slack post composition rules for TestFlight + App Store channels.
- **Key claims:** Three-section shape (New / Fixed / Crash fixes); TF-only rollover; bare Crashlytics links for crash fixes; CC-mentions parenthesized inline TF-only; terse Hinglish ok; no emojis in bullet format.
- **Refs:** implies `primitives/slack-post.md`.

### debrief-format.md
- **Purpose:** Legacy Markdown template for debrief files; superseded by `schemas/debrief.md` in 2.6, dual-written during transition.
- **Key claims:** Path `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`; 11 sections; `build_gate: lsp-only|full-green`; `build_debt_override: false` unless `--ignore-build-debt`.
- **Refs:** `schemas/debrief.md` (new YAML schema, dual-write active per Phase 2.6).

### event-emission.md
- **Purpose:** Producer-side rules for emitting events.
- **Key claims:** Every event carries `producer: {agent, mode, instance_id}`; writable events carry `idempotency_key`; ≤4096 bytes per line (POSIX atomicity); `printf >>` append; synthetic task IDs `direct:<debrief-uuid>`; `producer.agent` is authoritative; enum faithfulness mandatory.
- **Refs:** `message-contract.md`, `idempotency.md`, `events.md`, `chanakya-principles.md` Step 16.

### events.md
- **Purpose:** Event log schema + atomicity contract + authoritative catalog (100+ event types).
- **Key claims:** JSONL at `~/.dev-studio/<project>/events/<YYYY-MM-DD>.jsonl`; required fields `ts`, `agent`, `event`, `task`, `data`; optional `producer`, `idempotency_key` (minor bump); 4096-byte line limit; append via `printf`; offset marker at `events_offset.md`; catalog spans Achilles, Argus, Chanakya, cross-agent. `brief_completed.gate` enum: `verified | build-only | waived | lsp-only` (post-#84).
- **Refs:** `event-emission.md`, `message-contract.md`, `budget-telemetry.md`, `primitives/push-notifications.md`.

### idempotency.md
- **Purpose:** Idempotency key construction + dedupe rules.
- **Key claims:** Key = `<agent>:<mode>:<stable-subject>:<content-hash>`; producer-side dedupe → `action_deduped` event; no locks; retries reuse original key; readers dedupe via `(producer.agent, idempotency_key)`.
- **Refs:** `message-contract.md`, `event-emission.md`, `schema-version.md`.

### message-contract.md
- **Purpose:** Canonical envelope every inter-agent message carries.
- **Key claims:** 13 fields: `schema_version`, `message_id`, `correlation_id`, `idempotency_key`, `producer`, `recipient`, `intent`, `payload_schema`, `payload`, `reply_to`, `occurred_at`, `reads[]`, `writes[]`; `intent ∈ {request, response, event, handoff, cancel}`; transport-agnostic.
- **Refs:** `schema-version.md`, `idempotency.md`, `event-emission.md`, `read-write-decls.md`.

### plans-index-validator.md
- **Purpose:** Validator enforcing bidirectional consistency between `plans/index.yaml` and artifact back-refs.
- **Key claims:** 8 invariants; error codes `E_INDEX_MISSING_ENTRY`, `E_INDEX_DANGLING`, `E_LINK_ASYMMETRY`, `W_ARTIFACT_ORPHAN`, `E_INDEX_STALE`, `E_SCHEMA_VERSION_MISMATCH`, `E_SCHEMA_DEPRECATED`, `E_UUID_COLLISION`; impl `scripts/rebuild-index.sh` + `validate-plans-index.sh`; `task.links.{brief,debrief}` name latest only.
- **Refs:** 8 `schemas/` files, `schema-version.md`, `events.md`.

### read-write-decls.md
- **Purpose:** Mode-pack frontmatter declares reads/writes for static linting + router-level synthesis.
- **Key claims:** `reads: []`, `writes: []` lists, globs allowed, `<project>`/`<today>` placeholders ok; `E_MISSING_RW_DECL` blocks if missing; routers exempt; static linting only (no runtime enforcement per Q11).
- **Refs:** `patterns/router-pattern.md`, `patterns/capability-manifest.md`, `rules/enforcement-contract.md`.

### schema-version.md
- **Purpose:** SemVer envelope (name, version, min_reader, deprecated_at).
- **Key claims:** SemVer major=breaking/minor=additive/patch=fix; `min_reader` load-bearing, readers below reject loudly; `deprecated_at` RFC3339 UTC or null; one-time `schema_deprecated` event on emit; history table per schema; reject on missing required (`E_SCHEMA_REQUIRED_MISSING`), ignore unknown.
- **Refs:** `message-contract.md`, `idempotency.md`, `schemas/`, `events.md`.

### worker-report.md
- **Purpose:** 4-state `report_state` enum Achilles emits on every debrief.
- **Key claims:** 4 states: `done`, `done_with_concerns`, `blocked`, `needs_context`; Chanakya routing per state; backward-compat inference when absent; enforcement at `scripts/lib-ledger.sh::write_debrief_artifact`; telemetry in `debrief_emitted` events.
- **Refs:** `schemas/debrief.md` (2.0.2), `review-rules.md` R10, `budget-telemetry.md`, `events.md`.

### brief-formats/ (5 files)
- **impl-brief.md** — Implementation brief template; sections: Objective, Priority+Complexity, Branch, Skills, Figma, Codebase, Testability (SOLID/A11Y/L10n/Seams), Acceptance, Out-of-scope, Debrief. Size (XS/S/M/L) drives Achilles Step 6 gate.
- **unit-test-brief.md** — Unit-test brief; Scope, Framework, Reference, Key Areas (happy/edge/error), Organization, Mocks, Acceptance.
- **integration-test-brief.md** — Integration brief; Boundaries, Scenarios, Mock vs real, Organization.
- **ui-test-brief.md** — UI/XCUITest brief; A11Y Identifier Contract, Flows, Organization, Perf; regression test required for bug fixes.
- **tdd-brief.md** — TDD brief; Expected Interfaces, Scenarios (Given-When-Then), Stub Strategy, Acceptance (tests fail on stubs; blocked-by impl task).

---

## `state-machines/`

### brief-lifecycle.md
States: Draft → Ready → Dispatched → Debriefed → Superseded | Archived. Emits `brief_dispatched`, `brief_completed {gate}`.

### feedback-lifecycle.md
States: Ingested → Triaged → Linked → Resolved | Dismissed → Archived. Minimal in 2.6; knowledge-layer expansion in 2.7.

### release-lifecycle.md
States: Drafted → Submitted → In-Review → Pending-Developer-Release → Released | Rejected | Cancelled → Archived. Events `appstore_submitted`, `appstore_released`, `appstore_watch_stuck`.

### review-lifecycle.md
States: Pending → In-Progress → Approved | Flagged | Blocked → Acknowledged. Events `review_requested`, `review_{approved,flagged,blocked,scoped}`.

### task-lifecycle.md
States: Proposed → Briefed → Dispatched → In-Progress → Reviewed → Merged → Verified | Rejected → Archived. Done ≠ Verified (chanakya-principles #8). Events `task_completed`, `task_verified`, `task_redispatched`, `task_cancelled`. Five-state user view: pending → briefed → in-progress → done → verified.

---

## `patterns/`

### budget-telemetry.md
- `agent_session_completed` carries `tokens: {input, output, cache_read, cache_write}` (best-effort).
- Derived: `cache_hit_rate`, `ctx_util_pct`.
- `mode_budget_exceeded` when session > 1.1× budget.
- `budget-report.sh` aggregates daily/weekly by (agent, mode).
- Mode-pack frontmatter `budget_tokens`; fallback to `_shared/schemas/token-budgets.json`.
- User on Max plan — framing is consumption not spend.
- `model-rates.json` deprecated 2026-04-22 (unused post-reframe).

### capability-manifest.md
- JSON with `schema_version` + agents array; each agent has modes with name, path, type, reads, writes, snapshots, dry_run, budget_tokens.
- Regenerated by `scripts/capability-manifest.sh --regen` from mode-pack frontmatter.
- Validator diffs generated vs committed, exit 1 if differ; pre-commit auto-stages regen.
- Self-versioned 1.0.0; CHANGELOG at `_shared/schemas/capability-manifest-CHANGELOG.md`.
- Router reads/writes = union of modes (never hand-maintained).

### chanakya-principles.md
17 numbered principles governing Chanakya. Notable: #1 never sit idle, #2 briefs self-contained, #8 done ≠ verified, #16 event log first-class (read every sweep), #17 compact sweeps by default. Task status lifecycle pending → briefed → in-progress → done → verified. `agent_session_completed` mandatory every mode every session.

### dry-run.md
- Writes become `DRY-RUN write path=… bytes=… idempotency_key=…` log lines.
- Events buffer, print at end.
- External side effects no-op (Slack, TestFlight, git simulated).
- Exit: 0 (would succeed), 2 (problem found).
- Idempotency keys compute identically in dry/wet.
- Logs to stderr, summary to stdout.
- Pilot scope: Achilles task (Phase 2.5 Commit F); Argus fan-out in 2.6.

### dual-write-transition.md
- Phase 2.6 rule: YAML first, legacy second, AND not OR.
- Partial-failure loud: `dual_write_partial` event + exit 3.
- Index rebuild final step; batch via `WITHHOLD_INDEX=1` + `flush_index`.
- `DUAL_WRITE_MODE=both` default; `yaml-only` at Commit H.
- Dry-run preserves both (two `DRY-RUN write` lines).
- Scope: tasks, briefs, rounds, releases, debriefs, reviews.

### multi-machine-sync.md
- Tier 1 repo, Tier 2 per-machine runtime, Tier 3 multi-machine shared (partitioned per writer).
- Append-only within partition; merge at read-time; conflict-free by construction.
- Pluggable sync: git push/pull, rsync, S3, SMB.
- Primitives shipped 2.5: `machine-id.sh`, `write-shared.sh`, `read-shared.sh`, `sync-shared-remote.sh`.
- Read-time merge ordering: `(occurred_at, machine-id)` lex-sort.
- **No mode-pack consumer yet** (deferred per #56).

### router-pattern.md
- Router ≤100 lines, mode packs load on-demand, snapshots per-domain with fallback path.
- Intent priority: explicit arg → conversational switch → default.
- Router never prompts for clarification.
- Mode pack ~400 lines soft cap.
- Snapshots <1 page, `generated_at` + `schema` version, always have fallback.
- Applied: Chanakya (full), Achilles (full), Lu Ban (router-first), not Argus (single-purpose).
- Invariants non-negotiable.

### singleton-invariants.md
- **Chanakya** singleton per (machine, project). Reason: task-id collision, away-mode communication, snapshot file contention. Enforcement: advisory today; lockfile planned.
- **Achilles** NOT singleton (worktree-isolated, many concurrent).
- **Argus** NOT singleton (stateless); two on same task race — caller responsibility.
- **Lu Ban** NOT singleton per se; one session per design slug until `status: approved`.

---

## `primitives/`

### appstore-connect-jwt.md
ES256 JWT, `{iss, iat, exp (iat+1200), aud: "appstoreconnect-v1"}`, `kid` header. Credentials in `turnip-project-config.md`. Use `curl -sg` when URL contains brackets.

### derived-data.md
Per-task DerivedData at `/tmp/derived-data/<task-id>/`. 2–8 GB typical; persistence clean. Staleness guard: worktree HEAD ts vs newest build product mtime. Simulator convention: Argus `Argus-<slot-N>`, Achilles separate. Result bundle `/tmp/argus-<task-id>.xcresult`.

### file-locations.md
- Two canonical roots: `~/.dev-studio/<project>/` (per-project) + `~/.dev-studio/.runtime/` (machine-global, test-slot semaphore only).
- Project slug = basename of repo git toplevel.
- Never write outside; never use `~/.claude/` for runtime.
- Resolvers: `resolve_project`, `resolve_inbox_root`, `resolve_push_queue`, `resolve_runtime_global`, `list_fleet_projects`.
- Canonical post-2.6 layout: `plans/index.yaml`, `plans/{tasks,briefs,debriefs,reviews,rounds,releases,feedback,crashes}/*.yaml`, `events/<date>.jsonl`, `worktrees/<task-id>/`, `locks/`.
- Legacy layout (read-only post-2.6): `chanakya-master.md`, `chanakya-tasks/`, `chanakya-inbox/`, `user-testing.md`, `event-log.jsonl`.

### push-notifications.md
Append-only JSONL at `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl`. Each line `{ts, agent, trigger, task, message}` (max 200 chars). V1 queue-only; Chanakya status surfaces. V2 (deferred): digest bundling + MCP reply. Triggers: review_blocked, merge_conflict, watch_queue_drained, build_debt_blocked, error.

### router-bootstrap.md
Compact session-start context: agents (Chanakya/Achilles/Argus + planned Lu Ban/Chiron); before work → read ROADMAP/ARCHITECTURE/REVIEW/RELEASES; mode pack index; Iron Laws; enforcement (`lint-architecture.sh`, `test-mode-pack.sh`).

### safe-git.md
`safe_git_commit()` wrapper: detect stale `.git/index.lock` (no live process, or missing), remove if stale, emit `stale_index_lock_removed` event, run commit.

### skill-testing.md
- Baseline fixture YAML at `tests/mode-packs/<agent>/<mode>.yaml` or `tests/primitives/<primitive>.yaml`.
- Required: `schema`, `pack`, `scenario`, `failure_signals`, `success_signals`, optional `notes`.
- Pass: without-pack exhibits failures; with-pack exhibits success AND lacks failure_signals.
- On-demand; never per-commit.
- Lint gate `E_MISSING_PACK_FIXTURE` (existence only, not freshness).
- Phase 2.6.5 retroactive coverage: 5 packs.

### slack-post.md
Token at `~/.claude/secrets/slack-bot-token` (chmod 600). `chat.postMessage` pattern. Thread replies via `thread_ts` from parent `ts`. `<!here>` only in top-level, not thread replies.

### test-slot.md
`~/.dev-studio/.runtime/locks/test-slots/{slot-1,slot-2,slot-3}`. Acquire via `mkdir` atomicity; PID file `<pid>:<agent>:<task-id>:<acquired-at>`. Release on EXIT trap. Stale: PID dead OR age >2h. XS/S skip; M/L acquire before `xcodebuild test`; TDD acquires once for two runs. Max wait 30 min then `slot_timeout`.

### turnip-project-config.md
Turnip iOS-specific: repo path, scheme, ASC credentials, Crashlytics plist. **Flagged for move to `projects/turnip/` post-2.5** (README note).

---

## `rules/`

### cleanup-policy.md
- Ownership table 28 artifact types.
- Retention tiers: 0 (immediate), 1 (event), 2 (48h failure), 3 (time-based: events gzip@7d/delete@30d, reviews archive@30d, push queue@7d, failure artifacts@48h).
- `.argus-running` marker in worktree; Achilles waits (poll 30s, up to 10 min).
- Chanakya compact `--sweep-artifacts` (default on).
- `--auto-compact` doc-only in v1; v2 uses CronCreate MCP.

### debt-tracking.md
- Build debt: warn@6/block@12; auto-files TBUILD at warn; brief-mode refuses under block (except TBUILD).
- Unit-test debt: silent@0-3/warn@4-7/block@8; TUNIT autofile at 3→4.
- UI-test debt: silent@0-2/warn@3-5/block@6; TUI autofile at 2→3.
- Reset to 0 on full test-suite pass.

### enforcement-contract.md
- 9 block codes `E_*`: ROUTER_SIZE, CROSS_MODE_LOAD, MISSING_SNAPSHOTS_DECL, FRONTMATTER, SURFACE_REMOVED, DUP_PROSE, MODE_SIZE, MISSING_RW_DECL, UNKNOWN_CONTRACT_REF, ORPHAN_FIXTURE.
- 5 warn codes `W_*`: MODE_SIZE (400-600), SNAPSHOT_FRESHNESS, BUDGET_DRIFT, CAPABILITY_STALE, MISSING_PACK_FIXTURE.
- Bypass: `ARCH_LINT=0` auto-opens follow-up issue.
- Pre-commit `--staged`; cross-file checks scan full tree.

### localization-rules.md
- `"keyName".localized` for every user-visible string; camelCase with feature prefix.
- Three `.lproj`: en, hi, uk; `"TODO: translate"` placeholder if needed.
- Format strings via `{placeholder}` + `replacingOccurrences`, never concat.
- Flexible-width layouts (~30–50% expansion).
- Achilles Step 5 grep check; Chanakya Step 6A adds Localization brief section for user-visible strings.

### review-rules.md
- 4 scope caps: 10 neighbor files, 50 lines/file, 500 lines diff total, XS-trivial skip (<20 lines + single file + XS task).
- 6 checks: Cross-File Regression Risk, Edge-Case Generation, Test Adequacy, Diff Anomalies, Base-Branch Staleness, Secrets in Diff.
- TDD verification: red start, green HEAD.
- Verdict: Block / Flag / Approve.
- **Week 1 posture:** only compile failure, test failure (M/L), secrets, base staleness are blocks; rest flag-only.

---

## `schemas/`

| File | Schema name | Version | Phase | Notes |
|---|---|---|---|---|
| brief.md | brief | 3.1.0 (min_reader 3.0.0) | 2.6 | Post-migration; aligns with impl-brief.md template |
| crash.md | crash | 1.0.0 | 5 | Writer future |
| build-debt.md | build-debt | — | — | Referenced by debt-tracking.md |
| debrief.md | debrief | 2.0.0+ (min_reader 2.0.0) | 2.6 | Carries `report_state` (4-state) |
| feedback.md | feedback | 1.0.0 | 2.6 | Linked to feedback lifecycle |
| master-plan.md | master-plan | legacy | pre-2.6 | Superseded by per-task + index |
| release.md | release | 1.0.0 | 2.6 | Emission via `/fullSendToAppStore` |
| review.md | review | 1.1.0 | 2.6 | Aligns with review-rules checks |
| round.md | round | 1.0.0 | 2.6 | Immutable (chanakya-principles #12) |
| task.md | task | 1.0.0 | 2.6 | Canonical; replaces chanakya-master rows |
| test-flow.md | test-flow | legacy | pre-2.6 | Read-only post-2.6 |
| capability-manifest.json | capability-manifest | 1.0.0 | 2.5 | Regenerated |
| model-rates.json | — | **DEPRECATED 2026-04-22** | — | Max-plan reframe; removal at 2.7 |
| token-budgets.json | token-budgets | — | — | Fallback for mode-pack budgets |
| reader-versions.json | reader-versions | — | 2.6 | `validate-schema.sh` reads |
| capability-manifest-CHANGELOG.md | — | — | — | Companion to manifest |

---

## Cross-contract drift catalog

1. **Debrief duality** — legacy MD (`debrief-format.md`) + YAML (`schemas/debrief.md`) coexist per Phase 2.6 dual-write. **Intentional, not drift.**
2. **Brief vs task lifecycle states** — brief-lifecycle (Draft→Ready→Dispatched→Debriefed→Superseded|Archived), task-lifecycle (Proposed→Briefed→Dispatched→In-Progress→Reviewed→Merged→Verified|Rejected→Archived). 5-state user view in chanakya-principles is a projection. **No contradiction.**
3. **Debrief path** uses `<task-id>-debrief.md` (no slug); briefs use `<task-id>-<slug>.md`. Debriefs are one-per-task; briefs can be multi. **Consistent, not drift.**
4. **Build debt thresholds** warn@6/block@12 align with `events.md` `build_debt_warned`/`build_debt_blocked`. **Aligned.**
5. **Test debt tighter for UI** (warn@3/block@6 vs unit warn@4/block@8) — intentional comment in debt-tracking.md: "UI tests slower, more expensive."
6. **Argus Week 1 posture** staged rollout — only hard checks block; rest flag-only. **Intentional.**
7. **Schema deprecation** — `deprecated_at` past → `E_SCHEMA_DEPRECATED` block; future → `W_SCHEMA_DEPRECATION_PENDING` warn. **Aligned.**
8. **Capability manifest** regen + stale warning — automated pre-commit + non-blocking warn. **Aligned.**
9. **All 70 cross-file references resolve.** No dangling refs.
10. **Turnip project config** in `_shared/primitives/` — flagged for move to `projects/turnip/` post-2.5. **Documented intent, not drift.**
11. **`model-rates.json` deprecated 2026-04-22** — Max-plan reframe; kept one cycle; removal at 2.7 cutover. **Tracked.**
12. **Multi-machine sync** Tier 3 — primitives shipped 2.5, no mode-pack consumer yet. **Intentional deferral per #56.**

---

## Summary

70 files; all exist, readable, cross-references resolve; schema versions consistent with `schema-version.md` contract; event catalog complete; Phase 2.6 dual-write is documented transition; deprecations (model-rates, deferred consumers) tracked; linter enforcement tight. Zero true contradictions — all apparent differences are intentional layering (legacy vs. canonical, full lifecycle vs. user view, strict vs. staged rollout).
