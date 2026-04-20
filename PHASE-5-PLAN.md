# Phase 5 Execution Plan (draft)

Drafted 2026-04-20 for the `refactor/intent-router` branch. **Status: draft — will lock with user before execution.** Decisions Q42–Q46 are each marked locked; no open rows in the decisions table. Deferred items in §13 have a recommended default in **bold** where the user will still want to weigh in.

Phase 5 introduces **Chiron**, a synthetic-QA agent that runs simulator-matrix tests against TestFlight builds and crash fixes; and a **Crashlytics auto-brief loop** that polls crash-reporting and materializes a brief per new crash. A **3-step gate** wires crash-fix work into the existing task lifecycle with a `reproducer | possible-fixes` fallback. Chiron never writes product code — reads diff + test flows, runs simulator tests, emits structured reports.

See `ROADMAP.md` §Phase sequence, `PHASE-2-5-PLAN.md` through `PHASE-4-PLAN.md` for upstream contracts, and `ARCHITECTURE.md` §Design Vision for agent-roster rationale. Gated by 2.5 (event envelopes + `multi-machine-sync`), 2.6 (YAML ledger + task lifecycle), and 2.7 (FTS5 substrate for report indexing). Phase 5 is the capstone of the current refactor.

## 0. Standards and non-negotiables

Unchanged from 2.5/2.6/2.7/3/4 §0, restated for self-containment:

- **World-class — fit-for-purpose at this project's scale.** Single-user iOS workflow tool. Phase 5 must stay **zero paid services** (no cloud device farm, no LLM-scenario synthesis), **light on the laptop** (Chiron runs on the Mac mini; laptop never a fallback), and **cheap at idle** (crash-watch is a self-gated cron tick, same shape as `appstore-watch.sh`).
- **Agent-first design.** Crash briefs + Chiron reports are structured YAML first, markdown rendered on demand (same pattern as 2.7 views). No interactive prompts in Chiron. Only user touchpoint in the crash-fix loop: candidate-fix selection in the `possible-fixes` fallback (§6).
- **Three-tier artifact paths.** Crashes, briefs, debriefs, test-flows, Chiron reports live in tier 2. Tier 3 only if cross-machine needs it (deferred — §13). All writes via `scripts/lib-paths.sh`.
- **Minimal permission footprint.** `crash-watch.sh` calls Crashlytics API read-only (key via keychain/env, same pattern as ASC key). No new Bash patterns in allowlist.
- **Additive to existing contracts.** Phase 5 never breaks event shapes. New events use the 2.5 envelope. Task lifecycle extends with `fix_mode` metadata (additive) — states unchanged.
- **Chiron never writes product code.** Reads diff + flows, runs simulator tests, emits reports. No `src/` writes. No git writes. Mirrors Lu Ban's safety envelope (Phase 4 §2.1).
- **Right-sizing.** No new linter codes, no multi-GB dbs, no paid APIs. Dedup via stack-signature hash (§2.3) — not an ML classifier.

## 1. Decisions table — all locked

| # | Decision | Resolution |
|---|---|---|
| Q42 | Chiron implementation | Local simulator matrix (XCUITest-based). Runs on Mac mini by default. If mini is unavailable, Chanakya/Chiron suggests connecting it; user continues on laptop, Chiron paused until mini online. **No LLM scenario synthesis, no paid cloud device farm.** |
| Q43 | Test-flow source | Hybrid. Auto-expanded from briefs by default — every `size: m\|l` Achilles task adds its own flows during the brief → debrief round-trip. User manually surfaces critical flows via `/chiron add-flow <name>` (mode deferred — §13) or inline when Chanakya sees gaps. |
| Q44 | Chiron trigger | Three triggers: TestFlight build availability (hook on `appstore-watch.sh`) + Crashlytics alert (new `crash-watch.sh`) + ad-hoc `/chiron run`. **No default schedule at launch.** User adds schedule later if warranted, via Phase 3's detect → suggest → approve flow over `scheduler.yaml`. |
| Q45 | 3-step gate (with fallback) | **Step 1:** reproducer test written — or `possible-fixes` path if the crash is non-replicable in simulator. **Step 2:** reproducer red→green, OR user-selected candidate fix lands. **Step 3:** Chiron replays core flows → no regression. Debrief YAML carries `fix_mode: reproducer \| possible-fixes` and `candidates: [...]` (ordered by Achilles confidence). |
| Q46 | Chiron placement | Mac mini by default once onboarding Stage 2 complete. Falls back to **paused, awaiting mini** — not laptop fallback. Simulator matrix on the laptop alongside Xcode + live-preview simulators is a bad citizen; pausing is the honest answer. Future: Mac Studio as an additional worker node (§13). |

## 2. Crashlytics auto-brief loop

### 2.1 `scripts/crash-watch.sh` — single-tick observer

Modeled on `appstore-watch.sh`. Invoked by Chanakya Step 0B. Self-gated on marker `next_check_at` — most ticks exit immediately.

**Marker file** at `~/.dev-studio/<project>/.runtime/state/crash-watch.json` (resolved via `lib-paths.sh::resolve_crash_watch_marker`) holds: `project`, `last_check_at`, `next_check_at`, `last_event_id_seen`, `failures`, `last_error`, `api_key_ref` (e.g. `keychain://crashlytics/api-key`).

Absent marker → one-time bootstrap on first `/chanakya crash-setup` (seeds `api_key_ref`, sets `next_check_at: now`). Wrong project → no-op. Missing = not configured; Phase 5 ships the mechanism, doesn't demand setup.

### 2.2 Poll cadence

- Default: 15 min between crashes, jittered ±3 min (avoids sync across parallel dev-studio instances).
- On any new crash: 5 min for the next hour (post-bad-build flurries are common), then back to 15.
- On `appstore_released`: 5 min for 24h (release-window spike).
- On 3 consecutive failures: 60 min + emit `crash_watch_stuck`. Same `failures` counter shape as `appstore-watch.sh`.

No daemon. Phase 3's `scripts/scheduler/dispatch.sh` invokes `crash-watch.sh` every minute; it self-gates.

### 2.3 Dedup rule — stack-signature hash

Mandatory. **Crashes with identical stack signatures produce ONE brief, not N.** Non-negotiable.

Signature computation (`scripts/crash-signature.sh`, ~40 lines):

1. Take the top **5 frames** of the crash stack, symbolicated (Crashlytics provides symbolicated frames).
2. Strip line numbers + column offsets (same crash shifts by a line across versions).
3. Strip memory addresses, thread IDs, timestamps.
4. Strip product-version-string (same bug across v1.2.3 and v1.2.4 is one bug).
5. Canonicalize whitespace.
6. `sha256` the result → 16-char hex prefix = `crash_signature`.

Dedup lookup against 2.7's FTS5 substrate: `SELECT id FROM artifacts WHERE kind='crash' AND json_extract(body_json, '$.crash_signature') = ?`.

- Hit → append to `occurrences[]` on the existing crash artifact, emit `crash_occurrence_added`. **No new brief.**
- Miss → write a new crash artifact (§2.4), materialize a brief, emit `crash_detected` + `crash_brief_created`.

### 2.4 Crash artifact schema

`_shared/schemas/crash.md`, `crash@1.0.0`:

```yaml
schema_version: {name: crash, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
crash_signature: <16-hex>              # §2.3 output
first_seen_at: <rfc3339>
last_seen_at: <rfc3339>
occurrences:                           # append-only; dedup bumps count here
  - event_id: <crashlytics-event-id>
    occurred_at: <rfc3339>
    app_version: "1.2.3 (456)"
    os_version: "iOS 17.4"
    device_model: "iPhone15,3"
top_frames: [<symbolicated-frame>…]    # 5 frames, post-canonicalization
raw_frames: [<symbolicated-frame>…]    # full stack, first occurrence
exception_type: "…"                    # e.g. NSInvalidArgumentException, EXC_BAD_ACCESS
exception_reason: "…"                  # the message if present
links:
  brief_id: <uuidv7>?                  # set once brief materializes
  fix_task_ids: [<uuidv7>…]            # set as Achilles tasks claim the fix
status: open|in-progress|fixed|wont-fix
```

Lives at `~/.dev-studio/<project>/plans/crashes/<id>.yaml`.

### 2.5 Brief auto-creation schema

Crash briefs are ordinary `brief@3.2.0` (Phase 4 added `target_machine`) with an added `source: crash` field (minor bump → `brief@3.3.0`; additive). Commit D extends Chanakya's brief-writer to accept a crash artifact and produce:

- `title`: `"Fix crash: <exception_type> — <top-frame function>"`.
- `body.context`: exception reason + first-seen metadata + occurrence count.
- `body.acceptance`: reproducer red→green (`fix_mode: reproducer`) OR user-selected candidate lands (`fix_mode: possible-fixes`); and Chiron core-flow replay shows no regression.
- `body.testability`: stack trace + reproduction hints from FTS5-joined prior debriefs on adjacent `top_frames` function names.
- `fix_mode`: defaults `reproducer`; flipped to `possible-fixes` if Achilles can't reproduce (§6 step 1).
- `links.crash_id`. `target_machine: null` (user redirects via Phase 4 §8 natural language).

### 2.6 Chanakya handoff event

`crash_brief_created` (§9) triggers the ordinary inbox sweep. Achilles picks it up via `/achilles <brief-id>` or sweep. **No new dispatch pathway** — crash briefs are briefs with `source: crash`.

## 3. Chiron agent architecture

New agent under `chiron/` at repo root, peer to `chanakya/`, `achilles/`, `argus/`, `luban/`:

```
chiron/
  SKILL.md                    # router-only, <100 lines
  modes/
    run.md                    # the only mode in Phase 5
  README.md                   # long-form walkthrough (post-scaffold)
```

### 3.1 SKILL.md — router-first from birth

Constraints inherited from 2.5 `patterns/router-pattern.md` + Phase 4 Lu Ban precedent:

- Router prose enumerates every sub-command and routes to the mode pack.
- No workflow logic in SKILL.md. Only: frontmatter, agent identity, mode roster, safety envelope, load-at-start reads.
- `reads:` / `writes:` synthesized by `scripts/capability-manifest.sh` per 2.5 §3.5.

**Routes:**

| Sub-command | Mode pack | Notes |
|---|---|---|
| `/chiron run` | `modes/run.md` | Ad-hoc or trigger-invoked. Runs the full simulator matrix against HEAD + test flows. |
| `/chiron run <build-id>` | `modes/run.md` | Explicit build target (TestFlight build id or a git-sha). |
| `/chiron status` | `modes/run.md` | Reports last run summary + in-flight simulator allocations. Same mode pack handles both. |
| `/chiron add-flow <name>` | `modes/add-flow.md` | **Mode deferred — §13.** Until it lands, route prints a stub pointing at manual YAML authoring in `plans/test-flows/`. |

**Safety envelope (stated explicitly in SKILL.md):**

- **Never** writes code or modifies files under `src/`, `Sources/`, test trees, Xcode projects, or any product source tree. Test flows live outside the product tree in `plans/test-flows/`.
- **Never** runs git writes. Read-only git (`git log/show/diff/ls-files`, `git checkout <sha>` into a work-tree) is allowed.
- **Only** writes under `plans/test-flows/` (via deferred `/chiron add-flow`), `plans/chiron-reports/`, and `.runtime/state/chiron/`.
- Never invokes Achilles or Lu Ban. Chanakya invokes Chiron; Chiron reports back; Chanakya decides follow-up.

### 3.2 Mode packs — start minimal

Phase 5 ships **one** mode pack: `modes/run.md` (§6 step 3 + §7 matrix execution).

**Explicitly deferred mode packs** (right-sizing per Phase 4 precedent):

- `modes/add-flow.md` — structured test-flow authoring. Deferred until auto-expansion signal (§5) shows where manual curation is actually needed. Meanwhile `/chiron add-flow` prints a stub pointing at `_shared/schemas/test-flow.md`.
- `modes/tune-matrix.md` — per-flow matrix override. Deferred until the default matrix (§7.3) proves under- or over-broad.

## 4. Test-flow schema

`_shared/schemas/test-flow.md`, `test-flow@1.0.0`:

```yaml
schema_version: {name: test-flow, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: <uuidv7>
name: "<human-readable-slug>"          # e.g. "add-to-cart-happy-path"
created_at: <rfc3339>
created_by: chanakya|user|achilles     # source (§5 auto-expansion tags achilles)
source_brief_id: <uuidv7>?             # set when auto-expanded from an m|l task
source_task_id: <uuidv7>?              # the task that produced this flow
tags: [core|regression|crash|smoke|…]  # drives which runs include this flow

# XCUITest pointer — the test lives in the product repo's UITests target.
xcuitest:
  target: "<AppName>UITests"
  class: "<ClassName>"
  method: "<testMethodName>"

# Optional structured steps (docs + add-flow mode; execution goes through xcuitest).
setup: [ "…", … ]
steps: [ "…", … ]
assertions: [ "…", … ]

# Simulator matrix (§7)
matrix:
  devices: ["iPhone 15", "iPhone SE (3rd gen)"]
  ios_versions: ["17.5", "16.4"]        # user-min-supported + latest
  pairs: []                              # empty = full cartesian

links:
  recent_run_ids: [<run-id>…]            # last 10; populated by Chiron
```

**Where they live:** `~/.dev-studio/<project>/plans/test-flows/<flow-id>.yaml`. Tier 2. Tier 3 only if cross-machine needs it — deferred (§13).

**Tags drive matrix selection:** `core` runs on every trigger; `smoke` only on ad-hoc `/chiron run`; `regression` + `crash` on TestFlight + Crashlytics triggers. Rules live in `chiron/modes/run.md`.

## 5. Auto-expansion from briefs

### 5.1 When it fires

Every `size: m|l` Achilles task adds its own flows during brief → debrief. `xs|s` — no auto-flow (too small; accumulates via tag updates on adjacent flows). `m` — 1 flow (primary acceptance). `l` — 2–3 flows (primary + edge-cases).

### 5.2 Who writes the flow

**Chanakya, during brief generation.** Brief-writer side-effect: for `size: m|l`, emit a draft test-flow at `plans/test-flows/<flow-id>.yaml` with `created_by: chanakya` + `source_brief_id`. XCUITest pointer is the *expected* method name (`test<BriefTitleCamelCased>`); Achilles writes the real method during the task and patches `xcuitest.method` in the debrief step.

Why Chanakya not Achilles: briefs carry user-visible acceptance *first*, before implementation narrows. The flow reflects acceptance shape, not implementation. Achilles makes the XCUITest match the flow's contract.

### 5.3 What's in the auto-generated flow vs user-curated

| Aspect | Auto-generated | User-curated |
|---|---|---|
| `name` | Derived from brief title (slugified). | Free text, often cross-cutting. |
| `tags` | `[regression]` + `[core]` if the brief is tagged `flagship`. | Any — often `[smoke]` or `[crash]`. |
| `setup` / `steps` / `assertions` | Derived from brief acceptance bullets (best-effort markdown → list parse). | Hand-authored, higher fidelity. |
| `matrix.devices` / `matrix.ios_versions` | Project default (§7.3). | Can be narrowed or widened. |
| `xcuitest.*` | Placeholder; Achilles patches in debrief. | Hand-pointed to an existing UITests method. |

### 5.4 Quality vs noise tradeoff

Auto-expansion will produce noise — briefs whose acceptance doesn't map cleanly to UI, internal refactors with no flow need. Mitigations:

- Brief-writer detects "internal refactor" shape (bullets starting with "internal" / "refactor" / "cleanup" / "no behavior change") and **skips** auto-flow emission.
- Every auto-flow carries `created_by: chanakya` — user can grep + cull. Future sweep mode (deferred) can retire flows unexercised in N runs.
- Debrief field `test_flow_quality: kept|trimmed|removed` tags usefulness; 2.7 `testing-health` aggregates and surfaces chronically-bad generators.

**Accept imperfect auto-expansion.** Demanding hand-authored flows before every M|L task breaks minimal-intervention. Noise is cheaper to cull than absence is to author.

## 6. 3-step gate with `possible-fixes` fallback

Ties into 2.5's task-lifecycle (`proposed → briefed → dispatched → in-progress → self-reviewed → argus-reviewed → merged → user-verifying → verified | rejected`). Phase 5 extends the lifecycle **metadata** — not the states — with `fix_mode` + `candidates[]`.

### 6.1 Step 1 — reproducer or fallback

On crash-fix task dispatch:

1. Achilles reads the crash's `top_frames` + `raw_frames` + `exception_*`.
2. Writes an XCUITest reproducer attempt in the UITests target; runs locally.
3. **Red (crash reproduces):** `fix_mode: reproducer`. Debrief carries the reproducer path. Proceed to Step 2.
4. **Green (non-replicable):** `fix_mode: possible-fixes`. Achilles emits `candidates: [{id, summary, rationale, confidence: 0..1, diff_sketch}, …]` ordered by confidence. Chanakya surfaces: *"Crash non-replicable. 3 candidate fixes ordered by confidence. Pick one, or ask for more options."* User selects → selected candidate is the task payload; proceed to Step 2.

### 6.2 Step 2 — the fix lands

- **`fix_mode: reproducer`:** Achilles implements the fix; reproducer red → green in self-review; Argus reviews the diff + re-runs the reproducer. Task advances `in-progress → self-reviewed → argus-reviewed`.
- **`fix_mode: possible-fixes`:** Achilles lands the user-selected candidate. No reproducer (non-replicable by definition). Argus reviews the diff against `top_frames` + the candidate's `rationale`. Self-review skips red→green; debrief notes the mode + why.

### 6.3 Step 3 — Chiron regression replay

Blocker on `argus-reviewed → merged`. Chanakya invokes `/chiron run <task-id>` with the task branch in a Chiron work tree. Chiron executes:

- All flows tagged `core`.
- Any flow whose `source_task_id` touches the same files (FTS5 query over the debrief index's `source_file_paths`).

Pass → `chiron_run_completed` with `regression: false` → task advances to `merged`. Fail → `regression_detected` with flow id + device/iOS cell + logs → task blocks at `argus-reviewed`; Chanakya surfaces *"Chiron found regression on `<flow>` (`<device>`/`<ios>`)."*; user decides fix & re-run, revert, or override.

### 6.4 Debrief field additions

Additive to `debrief@<current>` — bump minor.

| Field | Type | When set |
|---|---|---|
| `fix_mode` | `reproducer\|possible-fixes\|null` | Set when task's brief carries `source: crash`. Null otherwise. |
| `candidates` | `[{id, summary, rationale, confidence, diff_sketch, selected: bool}]` | Non-empty only when `fix_mode: possible-fixes`. |
| `crash_id` | `<uuidv7>?` | Set when task originated from a crash brief. |
| `chiron_run_id` | `<uuidv7>?` | Set on Chiron replay pass/fail. |
| `test_flow_quality` | `kept\|trimmed\|removed` | §5.4 — Achilles tags the auto-generated flow. |

### 6.5 State-machine touch-points

No new states. Transitions affected:

- `self-reviewed → argus-reviewed`: skip red→green assertion if `fix_mode: possible-fixes`.
- `argus-reviewed → merged`: requires `chiron_run_id` set and `regression: false` **iff** task is crash-sourced or flagged `requires_chiron_check`. Other tasks bypass — Phase 5 does not make Chiron universal.

## 7. Simulator-matrix management

### 7.1 Named simulator allocation

Borrows Phase 2.5 Commit H's stable per-writer partition pattern. Each Chiron worker holds a bounded pool of **named simulators** allocated up-front — e.g. `Chiron-1` (iPhone 15, iOS 17.5), `Chiron-2` (iPhone 15, iOS 16.4), `Chiron-3` (iPhone SE 3rd gen, iOS 17.5).

- Fixed naming `Chiron-<n>`, `n ∈ 1..N`, `N = 3` default. Env var `CHIRON_SIMULATOR_POOL_SIZE`.
- Allocation recorded at `~/.dev-studio/<project>/.runtime/state/chiron/simulator-pool.json`: `{name, device, ios, udid, status: idle|running|booting|shutting-down, last_used_at}`.
- Pool created lazily on first `/chiron run` via `scripts/chiron-pool.sh` (`xcrun simctl`).
- **No parallel runs share a simulator.** Flow claims its cell for the XCUITest duration; concurrency = pool size; flows queue.

### 7.2 RAM / disk footprint + cleanup

Each booted simulator ≈ 1.5 GB RAM + 2 GB disk (runtime shared across same-iOS sims). Pool of 3 ≈ 4.5 GB resident. **Cleanup policy:** `shutdown` (not `erase`) at end-of-run — ~2s vs ~30s; frees RAM. Weekly full `erase` via opt-in scheduler task (handles CoreData/UserDefaults drift). `simctl delete` never runs.

### 7.3 iOS-version + device coverage

Default matrix for auto-generated flows: **user's min-supported iOS** (from `Info.plist` `MinimumOSVersion`, or `~/.dev-studio/<project>/config.yaml:ios.min_supported`) + **latest released iOS** (highest-installed sim runtime). Two versions only. Middle versions opt-in per-flow via `matrix.ios_versions`. Devices: **one common form factor** (`iPhone 15`) + **one compact** (`iPhone SE (3rd gen)`); iPad opt-in per-flow. Total default 2×2 = 4 cells, bounded by pool size 3 → one cell queues.

### 7.4 Why not broader

Broader matrix = slower feedback + more flakes + more maintenance. Goal is regression detection, not compatibility grid. Compatibility bugs escape → user adds the missing cell to the failing flow's YAML. One-line diff, documented escalation.

## 8. Trigger integration

### 8.1 TestFlight hook (reuse `appstore-watch.sh`)

`appstore-watch.sh` already emits `appstore_released`. Phase 5 adds an upstream event `testflight_build_available`, emitted when a build first becomes available on TestFlight (pre-`PENDING_DEVELOPER_RELEASE`) — observable from ASC today; ~10 lines added in Commit B.

On `testflight_build_available`: Chanakya's event processor (2.6) invokes `/chiron run <build-id>` asynchronously; Chiron runs `core` + `regression` flows against the build's git-sha; emits `chiron_run_started` → `chiron_run_completed` | `regression_detected`.

### 8.2 Crashlytics hook (new `crash-watch.sh`)

Per §2. On new crash post-dedup: `crash_detected` → brief materialization (§2.5) → `crash_brief_created` → Achilles inbox sweep picks up the brief. Chiron runs as Step 3 of the 3-step gate (§6.3).

### 8.3 Ad-hoc `/chiron run`

Args: `<build-id|git-sha|task-id>` (default `HEAD`) + `--flows <tag>,<tag>` (default `core`).

### 8.4 No default schedule

Phase 5 ships **zero** default scheduled Chiron runs. `scheduler.yaml` is available; user opts in via Phase 3's detect → suggest → approve flow. Anti-patterns to avoid: every-midnight full matrix (noise); every-commit full matrix (overlaps Argus).

## 9. Event types added

All events carry the standard 2.5 envelope (`producer`, `idempotency_key`, `occurred_at`, `schema_version`). Payload schemas live at `_shared/schemas/events/<event-name>.md`.

| Event | Payload | When emitted |
|---|---|---|
| `crash_detected` | `{crash_id, crash_signature, first_seen_at, exception_type, top_frame}` | Signature not yet in substrate. |
| `crash_occurrence_added` | `{crash_id, crash_signature, occurrence_event_id, total_occurrences}` | Signature match — no new brief. |
| `crash_brief_created` | `{crash_id, brief_id, target_machine}` | Chanakya materializes a brief. |
| `possible_fixes_emitted` | `{task_id, crash_id, candidate_count, top_confidence}` | Achilles flips to `possible-fixes`. |
| `chiron_run_started` | `{run_id, trigger: testflight\|crashfix\|adhoc, git_sha, flows: […], matrix: […]}` | Run begins. |
| `chiron_run_completed` | `{run_id, duration_ms, flow_count, pass_count, fail_count, regression: bool}` | Run finishes. |
| `regression_detected` | `{run_id, flow_id, flow_name, device, ios_version, failure_excerpt, blocking_task_id?}` | One per failing (flow, cell) pair. |
| `testflight_build_available` | `{build_id, version, build_number, asc_app_id}` | `appstore-watch.sh` detects a new TF build. |
| `crash_watch_stuck` | `{failures, last_error}` | 3 consecutive failures. Warn. |

Chiron reports land as structured YAML at `~/.dev-studio/<project>/plans/chiron-reports/<run-id>.yaml`; markdown rendered on demand by `scripts/chiron-render.sh` (same pattern as 2.7 views — renderer is thin). No real-time browsing; user reads on notification. The dashboard surface (Phase 6) is the intended long-term reader.

## 10. Execution order

Sequential unless `‖`. Small commits, independently revertible. Estimate: **7 commits**.

1. **Commit A — schemas.** `_shared/schemas/crash.md` + `test-flow.md` + event-payload schemas (§9). Bump `brief@3.2.0 → 3.3.0` (adds `source`, additive). Bump `debrief` minor (adds `fix_mode` / `candidates` / `crash_id` / `chiron_run_id` / `test_flow_quality`). Pre-commit validates. No script/agent changes.
2. **Commit B — `crash-watch.sh` + TestFlight-availability event.** `scripts/crash-watch.sh` + `scripts/crash-signature.sh` + `lib-paths.sh::resolve_crash_watch_marker`. `appstore-watch.sh` gains `testflight_build_available` (~10 lines). `/chanakya crash-setup` one-time bootstrap (writes marker; doc-only keychain guidance). Unit tests on signature hashing + dedup fixture.
3. **Commit C — Chiron agent scaffold.** `chiron/SKILL.md` (<100 lines) + `chiron/modes/run.md` + `chiron/README.md`. `scripts/scaffold-agent.sh` runs clean. Capability manifest regenerates. Smoke test: `/chiron run` against fixture flow + pool produces valid report YAML.
4. **Commit D — Chanakya crash-brief writer + auto-flow expansion.** Brief-writer `source: crash` branch (§2.5) + `size: m|l` auto-flow side-effect (§5.2). Internal-refactor regex (§5.4). Unit tests on ~8 brief shapes.
5. **Commit E — 3-step gate.** Achilles crash-fix path in `achilles/modes/task.md`: step 1 reproducer attempt + flip to `possible-fixes`. Chanakya surfaces candidate selection. Argus tolerates missing red→green when `possible-fixes`. State machine updated — `argus-reviewed → merged` requires `chiron_run_id` for crash-sourced tasks. Unit tests on state machine + Argus branch.
6. **Commit F — Chiron run mode + simulator pool.** `chiron/modes/run.md` full workflow + `scripts/chiron-pool.sh` (allocation + idempotent provisioning + reconcile) + `scripts/chiron-render.sh` (report → markdown). Report schema `_shared/schemas/chiron-run.md`. Integration test against mock simctl. Cleanup-after-run verified.
7. **Commit G — docs sync + trigger integration.** `chanakya/docs.html` "Crash" + "Chiron" cards under Fleet. `README.md` + `chanakya/README.md` updated. Events registered in `contracts/events.md`. TestFlight → Chiron wired via Chanakya's event processor. Open docs.html in Safari per CLAUDE.md. End-to-end smoke: `testflight_build_available` → `/chiron run` → report → no regression.

Parallelizable: A ‖ B. D ‖ E once C merges. G merges last.

## 11. Risk register

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Stack-signature collisions merge unrelated crashes | Low | Medium | 5-frame + exception-type canonicalization is robust at this scale. Debrief field `crash_dedup_wrong` lets user override; signature function amendable additively. |
| Mac mini offline → Chiron paused, crashes pile up | Medium | Medium | `/chanakya status` surfaces "Chiron paused, N crashes waiting" once pause > 24h. Briefs still materialize; only Step 3 replay waits. User can override merge with explicit flag. |
| Auto-expanded flows low-quality → false-positive regressions | High | Medium | §5.4 mitigations. `test_flow_quality` feeds 2.7 `testing-health`; chronically-bad patterns surface quarterly. Cull via grep + rm. |
| `possible-fixes` lands but doesn't fix crash → re-ignites post-release | Medium | High | `links.fix_task_ids[]` on crash; post-release crash-watch flags "fix ineffective, re-consider candidates" in `/chanakya status`. |
| Simulator pool leak — shutdown fails, RAM pinned | Low | Low | `chiron-pool.sh` reconcile mode enumerates `xcrun simctl list booted` + shuts down `Chiron-*`. Commit F. |
| TestFlight hook auto-triggers pre-onboarding → noise | Medium | Low | Gated on `scripts/chiron-ready.sh` (returns 0 iff pool provisioned). Pre-onboarding runs log `chiron_not_ready` warn + exit 0. |
| `crash-watch.sh` API key missing → silent no-op | Low | Low | Absent marker = "not configured" (intentional). Present with unresolvable `api_key_ref` → `crash_watch_stuck`. |
| Auto-flow emits on internal-refactor briefs despite filter | Medium | Low | `test_flow_quality: removed` feeds a regex refinement loop via 2.7 `workflow-signature`. Tightened empirically. |
| Chiron YAML balloons on large matrices | Low | Low | Per-cell output capped at 1000 log lines; full logs paged to `plans/chiron-reports/logs/<run-id>/<cell>.log`. |

## 12. Post-Phase-5 freeze rules

When Commit G merges:

- **Crash artifact frozen at `crash@1.0.0`.** Additive fields OK (minor bump); breaking changes follow 2.5 `min_reader` / `deprecated_at` protocol.
- **Stack-signature algorithm frozen at 5-frame canonicalization.** Retroactive change re-classifies historical crashes — requires explicit plan amendment.
- **Dedup is mandatory.** No path creates a crash artifact without consulting the substrate first. Any new producer routes through `scripts/crash-signature.sh`.
- **Chiron write scope frozen to `plans/test-flows/` + `plans/chiron-reports/` + `.runtime/state/chiron/`.** New destinations = new mode pack + SKILL.md update (ask-first tier).
- **`fix_mode` enum frozen at `reproducer | possible-fixes`.** Third mode requires plan amendment.
- **Simulator pool naming frozen at `Chiron-<n>`.** Stable names across machines enable future multi-mini fleets without re-mapping.
- **No default schedules.** Scheduler exists (Phase 3); Phase 5 adds zero entries. Defaults require plan amendment.

## 13. Deferred items (tracked, not lost)

GitHub issue per item post-plan-lock.

- **`chiron/modes/add-flow.md`.** Structured flow authoring + inline validation. **Recommend: revisit after ≥ 20 auto-flows exist and user has culled ≥ 3.**
- **`chiron/modes/tune-matrix.md`.** Per-flow matrix override. Deferred until default matrix proves under- or over-broad.
- **LLM scenario synthesis (hybrid).** Only if hand-curated + auto-expanded flows empirically fail to catch regressions. Gate: ≥ 3 shipped crashes Chiron could-have-but-didn't catch on an LLM-synthesizable flow.
- **Mac Studio as additional worker node.** Multi-mini fleets for parallelized matrix. Blocks on 2.5 Commit H sync past Stage 3. **Recommend: revisit once a single mini is resource-bound.**
- **Cross-project Chiron sharing.** Requires tier-3 test-flow sync + per-project pool isolation. Out of scope until a second project onboards.
- **Public test-flow library.** Post-Phase-6; privacy-sanitized per CLAUDE.md "Analysis sessions" — flows likely carry business-logic specifics.
- **Tier-3 for test flows.** Moves from tier-2 only if cross-machine coordination requires it.
- **Chiron as Argus regression-replay upgrade.** Extending replay to every M|L task would replace Argus's targeted `xcodebuild test`. Big contract change; out of scope.
- **Full-erase-weekly cleanup.** Opt-in Phase 3 scheduled task; cleanup script ships in Commit F.
- **Dashboard surface.** Phase 6 — near-real-time view. Phase 5 ships YAML + on-demand markdown only.

## 14. Notes from initial drafting

- Chiron (Χείρων) — centaur mentor who trained Achilles; fitting for the QA agent checking Achilles's work.
- Crash-signature dedup is the single most load-bearing mechanism — without it, one bad build produces N briefs for one bug and buries everything else.
- The `possible-fixes` fallback keeps the 3-step gate honest for non-replicable bugs. Without it, every unreproducible crash stalls indefinitely or forces a lossy close-and-hope path.
- Laptop-fallback-for-Chiron considered and rejected. Simulator matrix alongside live Xcode + active-dev simulators produces noise (resource-contention false-positives) and bad citizenship (stealing CPU from real work). Paused-awaiting-mini is the honest answer.
- Structured-YAML-first reports (Phase 5) + dashboard-later (Phase 6) preserves the agent-first design principle.
- `target_machine` (Phase 4 §8) carries through naturally once multi-mini fleets exist.
