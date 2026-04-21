# Phase 6 Execution Plan (draft)

Drafted 2026-04-21 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q47–Q50 are each marked locked; no open rows in the decisions table. Deferred items in §13 have a recommended default in **bold** where the user will still want to weigh in.

Phase 6 introduces the **Studio Dashboard**, a native macOS SwiftUI MenuBarExtra app that reads the per-project YAML ledger + event log and surfaces (a) the *Now* state of in-flight work, (b) *Week / Month / Quarter* aggregate views, and (c) a unified **approvals queue** where every pending user-action item is decided. Manual refresh only — no polling, no file-watcher, no push. The dashboard is a read-mostly view onto the studio's existing ground truth; the only writes are approval decisions that Chanakya ingests on the next sweep.

See `ROADMAP.md` §Phase sequence, `PHASE-2-6-PLAN.md` for the YAML ledger contract, `PHASE-2-7-PLAN.md` for the FTS5 substrate Now queries ride on, `PHASE-4-PLAN.md` (Lu Ban design approvals) + `PHASE-5-PLAN.md` (candidate-fix approvals) for approval producers. Gated by 2.6 (needs `plans/index.yaml` + canonical YAML artifacts). Reads-only from 2.7; if 2.7 slips, dashboard falls back to parsing YAML directly (slower but functional).

## 0. Standards and non-negotiables

Unchanged from 2.5/2.6/2.7/3/4/5 §0, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale.** Single-user iOS workflow tool. Dashboard is a *read-view*, not an orchestrator. **Zero network** (local filesystem only). **Zero login** (owner = only user). **Zero paid services.** **Runs at idle when the menu-bar icon is visible**, costs ~30 MB RSS — well under SwiftUI-simple-app norms.
- **Agent-first design.** The dashboard consumes the same YAML + JSONL that agents consume. It adds no new ground-truth storage. Approval decisions land as ordinary YAML under `approvals/`; Chanakya ingests them via the same sweep that ingests crash events. No dashboard-only state that agents can't see.
- **Three-tier artifact paths.** Approval artifacts live in tier 2 (`~/.dev-studio/<project>/approvals/`). Dashboard user preferences (current project, last-opened zoom) live in tier 2 UserDefaults keyed by bundle id; per-machine but per-project. No tier-3 writes.
- **Minimal permission footprint.** Dashboard reads everything under `~/.dev-studio/**` via `lib-paths.sh` — already allowlisted. Writes only to `~/.dev-studio/<project>/approvals/` and `~/.dev-studio/<project>/events/<date>.jsonl`. No new Bash patterns. SwiftUI app is sandboxed but granted user-selected read/write to `~/.dev-studio/**` on first launch.
- **Additive to existing contracts.** Dashboard never breaks event shapes. New approval events use the 2.5 envelope. No existing agent changes are required for the dashboard to render — agents remain the source of truth.
- **No daemon.** Dashboard is a regular foreground app; when closed, zero cost. MenuBarExtra stays resident only while menu bar is visible; opt-out via quit.
- **Right-sizing.** No cross-platform toolkit (Electron/Tauri rejected). No Catalyst (iPad port not the point). No custom renderer (SwiftUI native list + chart views are enough). No server component. No auth.

## 1. Decisions table — all locked

| # | Decision | Resolution |
|---|---|---|
| Q47 | Stack / packaging | **SwiftUI native macOS app with MenuBarExtra.** Click the menu-bar icon → popover opens with zoom tabs + approvals queue. No Dock icon (`LSUIElement = YES`). Rejected: Electron/Tauri (overhead + ~150 MB RSS), SwiftUI+AppKit mixed (no need), TUI (approvals need good tap targets). |
| Q48 | Zoom levels | **Now / Week / Month / Quarter**, exactly four. Each is a tab in the popover. Now is the default on open. Rejected: Day (too granular; Now covers it) and Year (too coarse; Quarter is the ceiling). Tab switching is cheap — no data pre-load. |
| Q49 | Approvals routing | **All pending-user-action items route to the dashboard approvals queue.** Unified across producers: candidate-fix (Phase 5), task verification (`user-verifying`), Lu Ban design approval (Phase 4), auto-apply ask-tier (CLAUDE.md), schedule-opt-in (Phase 3). One queue, one decision surface. Producers emit `approval_requested`; dashboard writes `approval_resolved`; Chanakya ingests on sweep. |
| Q50 | Refresh model | **Manual refresh only.** Cmd-R or toolbar button re-reads the ledger + event-log tail + approvals directory. No `fswatch`, no polling, no push. Rationale: dashboard is consulted, not stared at. Manual refresh keeps the cost footprint obvious and eliminates a class of "why did the UI just change" bugs. Auto-refresh tracked as deferred (§13). |

## 2. App architecture

### 2.1 Repo layout

Dashboard lives at `studio-dashboard/` at repo root, peer to `chanakya/`, `achilles/`, `argus/`, `luban/`:

```
studio-dashboard/
  StudioDashboard.xcodeproj/
  StudioDashboard/
    App.swift                    # MenuBarExtra entry
    Views/
      RootView.swift             # popover container + tabs + approvals banner
      NowView.swift
      WeekView.swift
      MonthView.swift
      QuarterView.swift
      ApprovalsView.swift
      ProjectPicker.swift
    Models/
      Ledger.swift               # parsed artifact index
      EventLog.swift              # tail-read jsonl
      Approval.swift              # pending + resolved
    Services/
      LedgerReader.swift         # reads plans/index.yaml + artifacts
      EventReader.swift          # tails events/<date>.jsonl
      ApprovalStore.swift        # read pending, write decisions
      PathResolver.swift         # mirrors lib-paths.sh (Swift-side)
    Package.swift                # swiftpm — Yams dep only
  StudioDashboardTests/
    LedgerReaderTests.swift
    ApprovalStoreTests.swift
    fixtures/                    # anonymized sample ledger + events
  README.md                      # install + build
  .gitignore                     # Xcode user-specific + DerivedData
```

One new top-level subtree. Rejected: separate repo (cross-ref overhead, versioning mismatch risk). Extracting to its own repo tracked as deferred (§13) for the case where non-studio consumers want it.

### 2.2 Bundle + launch shape

- Bundle id: `com.v-i-s-h-a-l.studio-dashboard` (personal, no org prefix; matches studio).
- `LSUIElement = YES` — no Dock icon, menu-bar only.
- Launch-at-login via user-toggled `SMAppService` registration. Off by default.
- Code signing: **local-only dev-signed**. No notarization, no App Store. User grants "allow app downloaded from unknown developer" once on first launch.
- Sandboxed: yes, with `com.apple.security.files.user-selected.read-write` entitlement for `~/.dev-studio/**`. Security-scoped bookmark stored in UserDefaults after first launch. Rationale: forces the studio path to be explicit, catches misconfiguration early.

### 2.3 Dependencies

- **Yams** (pure-Swift YAML, MIT, de-facto iOS/macOS standard). Via SwiftPM. Single dependency.
- **No Charts library** in Phase 6. Week/Month/Quarter surfaces use `Swift Charts` (Apple-native, macOS 14+) for simple bar/line visuals. Zero third-party.
- **No Firebase / analytics / telemetry.** Local tool.

### 2.4 Min-supported macOS

macOS 14 (Sonoma). Justification: `MenuBarExtra` lands in macOS 13; `Swift Charts` polished in 14; `SMAppService` in 13. User's laptop is current. No downlevel need.

## 3. Data contracts

### 3.1 What the dashboard reads

All paths resolved via `PathResolver` (Swift mirror of `lib-paths.sh`). Paths given relative to `~/.dev-studio/<project>/` unless noted.

| Source | Purpose | Read frequency |
|---|---|---|
| `plans/index.yaml` | Ledger index — lists every artifact with id, kind, status, updated_at. | Every refresh. |
| `plans/<kind>/<id>.yaml` | Artifact body — loaded lazily on card tap or aggregate. | On demand. |
| `events/<date>.jsonl` | Event tail — last 3 files (today + 2 prior) for Now; 30 prior for Month; 90 for Quarter. | Every refresh; seeked by last-read offset per file. |
| `approvals/<id>.yaml` | Pending approvals. | Every refresh. |
| `approvals/resolved/<id>.yaml` | Resolved approvals (audit trail). | Only in approvals "resolved" tab. |
| `~/.dev-studio/` children (excluding `.runtime/`) | Project picker enumeration. | App launch + picker click. |
| 2.7 FTS5 index (`~/.dev-studio/<project>/.runtime/state/fts5.db`) | Optional fast-path for aggregate queries. | Read-only, open as URI read-only. |

### 3.2 FTS5 fallback

If 2.7's FTS5 substrate is absent, dashboard falls back to full-scan YAML parsing. Cost difference on a 500-artifact ledger: ~3s (YAML full scan) vs ~100ms (FTS5). Acceptable for Phase 6 since refresh is manual. Detected via `FileManager.fileExists(atPath: fts5_db_path)`.

### 3.3 What the dashboard writes

Only two write paths:

1. **Approval decisions** → `approvals/resolved/<id>.yaml` + delete/move the pending file. Atomic: write new file, then `rename` the pending file. If either step fails, the decision is treated as unresolved on next refresh.
2. **`approval_resolved` event** → appended to `events/<today>.jsonl` with the standard 2.5 envelope.

No other writes. Dashboard never touches briefs, debriefs, designs, crashes, or tasks directly.

### 3.4 Read-only constraint enforcement

`LedgerReader` + `EventReader` open all non-approval files with `FileHandle(forReadingAtPath:)`. `ApprovalStore` is the sole type with write access; integration test asserts other services can't write (read-only file handles throw on write attempts).

## 4. Zoom-level surfaces

### 4.1 Now

Intent: "what needs my attention in the next hour." Single-pane, no scrolling for a typical day.

Sections (vertical stack, collapsible):

1. **Approvals pending** (count badge in menu-bar icon) — always first.
2. **In-flight tasks** — tasks with `status ∈ {dispatched, in-progress, self-reviewed, argus-reviewed, user-verifying}`. One row per task: id (clickable → brief), size, status chip, owner (Achilles/Argus/user), duration-in-state.
3. **Crashes unhandled** — crashes with `status: open` and no linked `fix_task_ids[]`. Count + top-3 list.
4. **Build debt** — if build-debt counter (from Phase 2.5) is non-zero: red pill with "run `/achilles build`" hint.
5. **Recent events (last 20)** — compressed timeline; filterable by producer. Hidden behind a disclosure triangle, closed by default.

Source queries:
- Section 1: `approvals/*.yaml` directly.
- Section 2: `plans/index.yaml` filtered by kind=task + status set.
- Section 3: FTS5 `SELECT id FROM artifacts WHERE kind='crash' AND json_extract(body_json, '$.status') = 'open' AND json_array_length(json_extract(body_json, '$.links.fix_task_ids')) = 0`.
- Section 4: `~/.dev-studio/<project>/.runtime/state/build-debt.json` → counter.
- Section 5: `events/<today>.jsonl` + yesterday if <20 events today.

### 4.2 Week

Intent: "what shipped, what broke, what's still warm." Rolling 7-day window.

Sections:

1. **Shipped tasks** — count + grouped by size (XS/S/M/L). Bar chart (Swift Charts).
2. **Crashes arrived vs fixed** — two stacked series over 7 days.
3. **Argus verdicts** — approved/flagged/blocked counts.
4. **Smoke regressions caught** — Phase 5 data. Count + list of `regression_detected` events.
5. **Release-worthy since last tag** — count of shipped tasks since the most recent git tag.

Source queries: mostly FTS5 window joins on the event log. Full-scan fallback acceptable — the read is manual-refresh only.

### 4.3 Month

Intent: "velocity + health trends." Rolling 30-day window.

Sections:

1. **Weekly velocity chart** — shipped tasks per week, 4-week bar.
2. **Test-flow health** — `test_flow_quality` debrief field aggregated; flags chronically-`removed` generators.
3. **Time-in-state** — median hours per task in `in-progress`, `self-reviewed`, `argus-reviewed`. Spots stalls.
4. **Architectural decisions** — Lu Ban designs `approved` in the window.
5. **Releases** — tags landed.

### 4.4 Quarter

Intent: "story of the last 90 days." Reads like a dashboard-first-glance narrative.

Sections:

1. **Themes shipped** — grouping by `body.tags[]` or derived from title. Small multiples chart.
2. **Architectural debt** — open deferred-items count across all phase plans (parsed from `PHASE-*-PLAN.md §13`).
3. **Crash halflife** — median days between `crash_detected` and `crash_fixed`.
4. **Agent health** — each agent's block rate (`argus-reviewed → blocked`, Lu Ban rejected designs).
5. **Narrative** — a single auto-generated paragraph that Chanakya writes (Phase 3 weekly narrative aggregated; deferred until 3 narratives exist — §13).

## 5. Approvals queue

The unifying surface. Every producer uses the same pattern: *request → pending artifact → dashboard surfaces → user decides → resolved artifact + event → Chanakya ingests.*

### 5.1 Approval artifact schema

`_shared/schemas/approval.md`, `approval@1.0.0`:

```yaml
schema_version: {name: approval, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
kind: candidate-fix|task-verification|design-approval|auto-apply-ask|schedule-proposal
producer: chanakya|achilles|argus|luban|system
created_at: <rfc3339>
expires_at: <rfc3339>?               # optional; defaults by kind (§5.3)

# One-line human hook shown in queue list
summary: "<≤80 chars — what the user is deciding>"

# Kind-specific context — rendered by a kind-specific view
context:
  task_id: <uuidv7>?
  crash_id: <uuidv7>?
  design_id: <uuidv7>?
  auto_apply_diff_path: <abs>?
  schedule_proposal_path: <abs>?
  candidates: [...]                  # candidate-fix kind only
  full_brief_path: <abs>?

# Decision schema — null until resolved
decision:
  choice: <kind-specific-enum>       # e.g. "candidate:2" or "approve" or "reject"
  decided_at: <rfc3339>
  decided_via: dashboard|cli|other   # dashboard always for Phase 6
  notes: "<optional free-text, ≤500 chars>"

status: pending|resolved|expired
```

Pending artifacts: `~/.dev-studio/<project>/approvals/<id>.yaml`. Resolved: move to `approvals/resolved/<id>.yaml`.

### 5.2 Producer pattern

Each producer already described in its phase plan, now normalized to:

1. Producer writes `approvals/<id>.yaml` with `status: pending`.
2. Producer emits `approval_requested` event.
3. User opens dashboard → sees pending approval → picks `decision.choice`.
4. Dashboard writes decision fields + `status: resolved`, atomically moves file to `approvals/resolved/<id>.yaml`.
5. Dashboard emits `approval_resolved` event.
6. Chanakya's sweep ingests `approval_resolved`: routes to kind-specific handler (candidate-fix → dispatch task; task-verification → transition state; etc.).

Dashboard is not in the handler chain — it's the decision surface. Routing logic lives in Chanakya. This keeps the dashboard dumb and the agent layer authoritative.

### 5.3 Per-kind behavior

| Kind | Producer | Choice enum | Default expiry | Handler on resolve |
|---|---|---|---|---|
| `candidate-fix` | Achilles (§6.1, Phase 5) | `candidate:<id>` \| `more` \| `abort` | 7d | Chanakya dispatches selected candidate. |
| `task-verification` | Chanakya (on `user-verifying`) | `verified` \| `rejected` | 14d | Chanakya transitions task state. |
| `design-approval` | Lu Ban (Phase 4) | `approve` \| `revise` \| `reject` | 14d | Chanakya sets design status; on `approve`, promotes to ADR + breaks into briefs. |
| `auto-apply-ask` | Claude session (CLAUDE.md ask-tier) | `approve` \| `reject` \| `approve-always` | 3d | Session-on-resume applies change; `approve-always` adjusts auto-apply tier. |
| `schedule-proposal` | Chanakya (Phase 3 detect → suggest) | `approve` \| `reject` \| `modify` | 30d | Chanakya writes to `scheduler.yaml`. |

Expiry past → `status: expired`, same move to `resolved/`, `approval_expired` event. Producers may re-request if still relevant.

### 5.4 Dashboard view

Approvals queue = list view at top of every zoom tab (count badge in menu-bar icon reflects pending count). Tap a row → kind-specific detail sheet with inline approve/reject. No modal — just a push navigation inside the popover.

Non-blocking: user can browse Week/Month while pending approvals exist. Menu-bar badge keeps them visible.

## 6. Manual refresh semantics

### 6.1 What a refresh does

1. Re-read `plans/index.yaml` (full — small file).
2. Re-scan `approvals/*.yaml` (small directory; glob is fine).
3. Tail-read `events/<today>.jsonl` + `events/<today-1>.jsonl` from last-read byte offset; for Week/Month/Quarter zoom, read N days of event files.
4. FTS5 aggregate queries re-run (if DB present).
5. Artifact bodies are *lazy* — re-loaded only when the user taps a card that displays body content.

Typical refresh: <200 ms on a 500-artifact ledger. Fits the "press Cmd-R" tempo.

### 6.2 Last-read offset persistence

`~/.dev-studio/<project>/.runtime/state/dashboard-offsets.json`:

```json
{"events/2026-04-21.jsonl": 18420, "events/2026-04-20.jsonl": 42191, ...}
```

Per-date byte offsets. On date rollover, offset for the new date file starts at 0. Rotated files past the 30-day Month window are cleaned from this map.

### 6.3 What a refresh does *not* do

- Does not run FTS5 rebuilds (2.7 job).
- Does not trigger agent invocations.
- Does not resolve approvals — requires explicit user decision.
- Does not emit events.

### 6.4 When refresh happens automatically

Three cases. Each is a **one-shot re-read**, not a poll:

- App launch.
- Returning focus to the popover after switching away (`scenePhase → active`).
- Immediately after the user resolves an approval (so the queue updates without a manual press).

Periodic polling, file-watching, and push notifications all deferred (§13).

## 7. Persistence + state

### 7.1 UserDefaults

Dashboard-local state only, keyed by bundle id:

- `currentProjectPath` (security-scoped bookmark data)
- `lastOpenedZoom` (`now|week|month|quarter`, default `now`)
- `collapsedNowSections` (array of section ids)
- `launchAtLogin` (bool)

No sensitive data; no keychain.

### 7.2 In-memory state

Models are `@Observable` (Swift 5.9 macro). Refresh rebuilds them. Retained across view switches within a single popover open; released when the popover closes.

### 7.3 No Core Data

No on-device persistence of ledger/event data. Ground truth = filesystem. Dashboard is a stateless viewer.

## 8. Distribution + install

### 8.1 Build

From `studio-dashboard/`:

```bash
xcodebuild -project StudioDashboard.xcodeproj -scheme StudioDashboard \
  -configuration Release -derivedDataPath build/ archive \
  -archivePath build/StudioDashboard.xcarchive
xcodebuild -exportArchive -archivePath build/StudioDashboard.xcarchive \
  -exportPath build/export -exportOptionsPlist scripts/export-dev.plist
```

`scripts/export-dev.plist` uses developer-id-local export (no notarization). `scripts/install-dashboard.sh` does: build → copy `.app` to `/Applications/` → print "launch once to grant `~/.dev-studio/**` read-write".

### 8.2 Install flow

Single command: `./scripts/install-dashboard.sh`. Idempotent; replaces existing install. User confirms Gatekeeper prompt on first launch.

### 8.3 Mac mini parity

Dashboard builds + runs on both laptop + mini. Preference is to run on the laptop (closer to the user) but the mini is a valid secondary display — useful for glanceable Week/Month on a side screen. No sync needed: both machines read the same `~/.dev-studio/<project>/` via the multi-machine-sync layer (Phase 2.5).

### 8.4 Uninstall

`./scripts/install-dashboard.sh --uninstall` — removes `/Applications/StudioDashboard.app`, unregisters SMAppService, deletes UserDefaults. Does **not** touch `~/.dev-studio/<project>/`.

## 9. Event types added

All events carry the standard 2.5 envelope.

| Event | Payload | When emitted |
|---|---|---|
| `approval_requested` | `{approval_id, kind, producer, context_summary, expires_at}` | Producer creates a pending approval. |
| `approval_resolved` | `{approval_id, kind, choice, resolution_duration_sec}` | Dashboard writes a decision. |
| `approval_expired` | `{approval_id, kind, created_at, expired_at}` | Expiry past + no decision. |
| `dashboard_refresh_completed` | `{duration_ms, zoom, artifacts_read, events_read}` | Opt-in telemetry; default OFF in Phase 6 (§13). |

Approval events feed Chanakya's ingest path (§5.2 step 6). `dashboard_refresh_completed` is deferred — no event emission in Phase 6.

## 10. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: **6 commits.**

1. **Commit A — schemas + path library + skeleton.** `_shared/schemas/approval.md` + `approval_*` event payload schemas. `lib-paths.sh::resolve_approval_root` + `resolve_approval_resolved_root`. Xcode project skeleton at `studio-dashboard/` with MenuBarExtra shell + Yams via SwiftPM + sandbox entitlement. README. Capability manifest regenerates. Smoke: project builds, menu-bar icon appears.
2. **Commit B — data layer.** `PathResolver.swift`, `LedgerReader`, `EventReader`, `ApprovalStore`. Fixtures under `StudioDashboardTests/fixtures/` — anonymized sample ledger + events + approvals. Unit tests: parse, tail-read with offsets, approval write-and-move atomicity. FTS5 fallback path tested (run tests with DB absent + present).
3. **Commit C — Now view + approvals queue.** `NowView`, `ApprovalsView`, `ProjectPicker`, `RootView` tabs + menu-bar badge. Kind-specific detail sheets for `candidate-fix`, `task-verification`, `design-approval`, `auto-apply-ask`, `schedule-proposal`. Atomic approval-resolve flow wired end-to-end against fixtures. First end-to-end smoke on real `~/.dev-studio/<project>/`.
4. **Commit D — Week / Month / Quarter views.** Swift Charts bars + lines for velocity, crash arrived/fixed, Argus verdicts, time-in-state. Shared presenter types. Fixtures extended with 90 days of events. Aggregate-query unit tests.
5. **Commit E — Chanakya approval ingest + producers.** New `chanakya/modes/approval-ingest.md`. Producers (Lu Ban, Achilles, Chanakya candidate-fix, schedule-proposal) updated to write `approvals/<id>.yaml` + emit `approval_requested`. Event processor routes `approval_resolved` by kind to the existing handlers. Unit tests on the router.
6. **Commit F — docs sync + install script + distribution.** `scripts/install-dashboard.sh` + `scripts/export-dev.plist`. `chanakya/docs.html` Dashboard card under Fleet. `README.md` + `chanakya/README.md` updated. Open docs.html in Safari per CLAUDE.md. End-to-end smoke: build → install → launch → resolve an approval → Chanakya ingests on sweep.

Parallelizable: A ‖ B. D ‖ E once C merges. F merges last.

## 11. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Sandbox entitlement denied by user → dashboard can't read | Low | High | First-launch onboarding sheet explains + re-prompts. Clear error state ("Grant access to `~/.dev-studio/` via System Settings → Privacy") if denied. No crash. |
| YAML schema drift between agents + dashboard parser | Medium | Medium | Dashboard parser tolerates unknown fields (Yams strictness off). Schema-version-aware: warns + gracefully degrades if `schema_version.name` unknown. |
| Event-log tail-read corrupts offset after log rotation | Low | Medium | Offset validated against file size on read; if offset > size, reset to 0. Same protocol as ROADMAP edge cases. Unit-tested. |
| 500+ pending approvals after an automation bug | Low | Low | Queue paginated (50 per page). "Dismiss all" option only for kinds where it's safe (`schedule-proposal`). Kinds requiring per-item decision never bulk-dismiss. |
| Swift Charts renders slowly on 90-day Quarter view | Low | Low | Aggregate to daily buckets before passing to Charts; 90 data points is trivial. |
| Sandboxed app can't write to `~/.dev-studio/.runtime/state/` | Medium | Medium | Security-scoped bookmark covers `~/.dev-studio/**` (not just project subdir). Tested in Commit A. |
| Dashboard writes an approval decision but Chanakya doesn't run → decision stalls | Medium | Medium | `/chanakya status` surfaces "N resolved approvals awaiting ingest." Dashboard shows a badge on resolved approvals more than 1h old. |
| MenuBarExtra popover dismissed mid-decision → half-written approval | Low | Low | Approval write is atomic (temp file + rename). Dismissal cancels unsubmitted state; nothing persists until the user taps Approve/Reject. |
| Opening body of a large debrief freezes UI | Low | Low | Body loaded on a background task; spinner during load. Bodies are small (<10 KB) so this is defensive, not corrective. |
| Xcode project files create noisy diffs in review | Low | Low | `.gitignore` excludes xcuserstate + DerivedData. Review only the source files; tolerate occasional pbxproj churn. |
| SwiftPM dependency resolution fails offline | Low | Medium | Yams vendored as git submodule fallback in Commit A. |

## 12. Post-Phase-6 freeze rules

When Commit F merges:

- **Approval artifact frozen at `approval@1.0.0`.** Additive fields OK (minor bump); new kinds require plan amendment since they expand dashboard UI.
- **Choice enums frozen per kind.** New choice values require plan amendment — Chanakya's handler depends on exhaustive enum coverage.
- **Manual-refresh-only frozen.** Auto-refresh (file-watcher or polling) requires plan amendment. Deferred on purpose.
- **MenuBarExtra-only frozen.** No full-window mode; no Dock icon. Different app shape requires plan amendment.
- **Local-only frozen.** No network, no cloud sync, no companion-device app. Future iOS companion tracked as deferred.
- **Dashboard never orchestrates.** It decides + displays; agents act. New "dashboard invokes X" features require plan amendment.
- **One-binary install.** No multi-window, no preference pane, no helper app.

## 13. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **Auto-refresh via `fswatch` or `DispatchSource.makeFileSystemObjectSource`.** Revisit if manual-refresh friction shows up in use. **Recommend: add when user logs ≥ 3 "forgot to refresh" incidents.**
- **macOS UserNotifications for high-urgency approvals** (candidate-fix blocking a fix-the-crash push; task-verification on a stale >48h approval). Deferred to Phase 9 alongside the rest of notification routing.
- **iOS companion app** — read-only mirror for on-the-go approvals. Distant. Requires a sync surface (iCloud or a thin server). Out of scope until remote-orchestration is real.
- **Export to its own repo.** Do this only if a non-studio consumer emerges. Until then, subfolder is cheaper.
- **Historical charts with >90-day window.** Event log rotation + on-disk cache needed. Revisit after 6 months of data exist.
- **Approval "bulk approve" with policy.** E.g. "approve all `schedule-proposal` from a given cadence." Needs careful auth UX. Deferred to Phase 9.
- **Command palette (Cmd-K).** Power-user navigation. Defer; menu-bar popover is small enough that tabs suffice.
- **Dark-mode polish + accessibility audit.** SwiftUI defaults are adequate for Phase 6. Full pass post-Phase-6.
- **Dashboard as also-on-remote-machine.** Currently local-only. Multi-machine follows the ledger sync path (2.5), not the dashboard code path.
- **`dashboard_refresh_completed` telemetry.** Opt-in, off by default. Adds nothing immediately; useful later for perf tuning.
- **Widget extension for Today/Notification Center.** Requires a different bundle + target. Deferred.
- **Narrative paragraph in Quarter view.** Requires ≥ 3 Phase-3 narratives to exist. Gated on Phase 3 maturity.
- **Signed + notarized builds.** Needed if the dashboard is ever shared publicly. Personal-tool scope → not yet.

## 14. Notes from initial drafting

- Manual-refresh-only is load-bearing. Polling and file-watching introduce a class of bugs ("why did the UI just change") that the dashboard's *purpose* (consulted, not stared at) makes unnecessary. Cmd-R is ritual enough.
- Approval unification across producers is the biggest conceptual win. Before Phase 6 each producer had ad-hoc surfaces (Chanakya status text, CLI prompts, iMessage). Routing everything through one queue with one schema cuts cognitive surface — and lets the dashboard be dumb.
- MenuBarExtra over full-window: approvals + Now are short. Week/Month/Quarter could pressure this — if charts feel cramped, the escape hatch is a "pop out to window" button, but don't add it pre-emptively.
- SwiftUI native (vs Electron) was the easiest call. User is an iOS dev; no learning tax. Electron would cost 150 MB RSS and a Node toolchain in a Bash+Markdown repo.
- `LSUIElement = YES` (no Dock icon) is deliberate — dashboard is ambient, not a first-class app. Dock presence would compete with Xcode and the user's real work apps.
- Sandbox was tempting to skip for a personal tool, but keeping it on forces clean FS boundaries and surfaces misconfig early. Cost: one grant click on first launch.
- Event-log tail-read with offsets is identical to Chanakya's reader (Phase 2.6). One implementation; Swift mirrors the bash logic. Same correctness guarantees.
- Dashboard doesn't orchestrate. Tempting to add "approve + re-dispatch" shortcuts, but that's Chanakya's job. Violating the separation makes the dashboard the de-facto boss, which conflicts with agent-first design.
- Quarter view is the one with the most "what goes here" freedom. Current picks reflect what the user would skim in a 30-second Monday glance. If they turn out cramped or irrelevant, adjust post-Phase-6.
