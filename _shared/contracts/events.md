---
name: Event Log
description: Schema, atomicity contract, and offset-marker conventions for the shared append-only event log.
type: reference
---

# Shared: Event Log

All agents write to a shared append-only event log. Chanakya tails it on wake.

## File Location

```
<project-memory>/events/<YYYY-MM-DD>.jsonl
```

`<project-memory>` = `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/` (resolved at runtime from `~/.claude/skills/_shared/primitives/file-locations.md`).

One JSONL file per calendar day. Agents never rotate or delete these files — Chanakya compact handles rotation (see `_shared/rules/cleanup-policy.md`).

## Event Schema

Every event is a single JSON object on one line:

```json
{"ts":"2026-04-18T14:32:01Z","agent":"achilles","event":"task_completed","task":"T001","data":{}}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | ISO8601 string (UTC) | yes | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| `agent` | `achilles` \| `argus` \| `chanakya` | yes | |
| `event` | string | yes | See event catalog below |
| `task` | string | yes* | Task ID (`T001`, `build-20260418-143000`). Use `""` for system events. |
| `data` | object | yes | Event-specific payload. May be `{}`. |

## Atomicity Requirement

**Events MUST fit in a single line of ≤ 4096 bytes.** POSIX guarantees `O_APPEND` writes are atomic on pipes and regular files when the write is ≤ PIPE_BUF (4096 bytes on macOS/Linux). Exceeding this risks interleaved writes from concurrent agents.

- Keep `data` payloads concise. Truncate long strings (e.g., error excerpts at 200 chars).
- If a payload would exceed 4KB, split into multiple events or link to an artifact file.

## Append Pattern

```bash
EVENT_FILE="$PROJECT_MEMORY/events/$(date -u +%Y-%m-%d).jsonl"
mkdir -p "$(dirname "$EVENT_FILE")"
printf '%s\n' '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"achilles","event":"task_completed","task":"T001","data":{}}' >> "$EVENT_FILE"
```

Use `printf '%s\n'` (not `echo`) — portable and avoids trailing-space issues.

## Event Catalog

### Achilles events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `brief_started` | Achilles begins Step 1 (load spec) | `size` |
| `brief_summary_used` | Achilles Step 1 read only the brief's `summary` slice (`BRIEF_SLICE=summary`) instead of the full body — context-budget fallback per `_shared/schemas/brief.md` § summary. Pairs with `brief_started`; mutually exclusive with full-brief reads on the same task. | `brief_uuid`, `summary_tokens_est` (word_count × 1.3, matches `lint-brief.sh`), `reason` (`context_budget`\|`caller_request`) |
| `brief_completed` | All steps done, debrief written | `gate`, `gate_legacy`, `merge_sha`, `debrief_id` |
| `brief_failed` | Any unrecoverable failure | `reason`, `step` |
| `task_started` | Step 2 — task claimed, branch created | `branch`, `base_sha` |
| `task_completed` | Step 9 — merge succeeded | `merge_sha` |
| `task_merged` | Merge lock released | `merge_sha` |
| `review_requested` | Achilles calls Argus before merge | `worktree`, `derived_data`, `stage` (`spec`\|`quality`) |
| `review_approved` | Argus returned approve | `review_file`, `stage` (`spec`\|`quality`) |
| `review_flagged` | Argus returned flag | `review_file`, `finding_count`, `stage` (`spec`\|`quality`) |
| `review_blocked` | Argus returned block | `review_file`, `block_reason`, `stage` (`spec`\|`quality`) |
| `merge_conflict` | Merge failed with conflict | `branch`, `files` |
| `merge_safety_blocked` | `task-merge.sh` refused because two or more merge safety signals were absent, or because the latest review verdict was `review_blocked`. Composite gate for build, review, and staged debrief. | `branch`, `missing_signals` (array: `build`, `review`, `debrief`), `signal_count`; optional `reason`, `latest_review` |
| `merge_safety_warn` | `task-merge.sh` found exactly one absent merge safety signal and proceeded. | `branch`, `missing_signals`, `signal_count` |
| `merge_safety_override` | User passed `--force` to bypass a composite merge safety block. | `branch`, `missing_signals`, `signal_count` |
| `merge_deferred_on_flagged` | `task-merge.sh --require-approved` refused to merge because Argus returned `review_flagged`. | `branch`, `reason` (`review_flagged`), `require_approved`; optional `override` |
| `base_refreshed` | Step 8.4 auto-refreshed the worktree base (commits-behind ≥ threshold, merge clean). Idempotent: no event when below threshold. | `worktree`, `base_branch`, `commits_pulled`, `threshold` |
| `base_refresh_conflict` | Step 8.4 attempted a refresh merge and hit conflicts; merge aborted, worktree left clean, Argus not invoked. Caller surfaces to user. | `worktree`, `base_branch`, `commits_pulled`, `threshold`, `files` |
| `base_diverged_post_review` | `task-merge.sh` acquired the merge lock, fetched `origin/<base>`, and found the base tip no longer matches the SHA recorded at Argus handoff. Merge is refused; rerun from Step 8.4 so Argus reviews the current base. | `base_branch`, `reviewed_base_sha`, `current_base_sha`, `branch` |
| `build_check_started` | Step 6 build gate entry — LSP or xcodebuild run begins | `mode` (`lsp-only`\|`full-green`), `worktree`, `attempt` (1 for cold start, 2+ for retries within the same build-gate cycle; resets on any terminal event) |
| `build_check_passed` | Step 6 build gate green — gate clears the task for merge | `mode`, `attempt`, `files` (lsp-only) \| `warnings` (full-green), `scheme` (full-green) |
| `build_check_failed` | Step 6 build gate red — blocks merge; task left in-flight for the user to resolve | `mode`, `attempt`, `errors`, `warnings` (full-green), `xcode_exit_code` (full-green), `log_tail` (bounded to the last 200 lines when diagnostics are otherwise absent or the success marker is absent), `reason` (`locked_out` iff lock wait exceeded; `xcode_major_drift` per #136; `focused_verification_structurally_blocked` when the swift-test focused package path failed before compilation on manifest/package-layout resolution and must not auto-fallback to the heavy runner; `source_sync_failed`, `remote_shell_path_failed`, `build_invocation_failed`, `remote_timeout`, `remote_marker_writer_failed`, `remote_harness_failure` per `_shared/contracts/remote-build-dispatch.md`; `remote_marker_writer_failed` also carries bounded `remote_log_tail` and `remote_command_exit_code` when available; `success_marker_absent` per #265 — xcodebuild exited 0 without `** BUILD SUCCEEDED **` in the log, signalling silent success on unresolvable destination or other catalog-resolution failure), `scheme` (full-green); optional `verification_blocked`, `verdict_note` |
| `build_harness_failed` | Step 6 detected an infrastructure contradiction rather than a normal project compile failure. Emitted in addition to `build_check_failed` so sweeps can distinguish "project is red" from "the gate could not prove its own success contract." | `mode` (`full-green`), `node`, `scheme`, `attempt`, `reason` (`success_marker_absent`), `xcode_exit_code`, `log_tail`, `studio.dispatch.*` when dispatched |
| `build_check_aborted` | Step 6 build gate exited without a pass/fail verdict — `cd` failure, missing arg after start, signal (SIGINT/SIGTERM), or any other exit path between `build_check_started` and the normal terminal emitters. Closes the open span so dashboards can distinguish "still running" from "died silently". See #106 / #209. | `mode`, `attempt`, `exit_code` (process exit status at trap time; `255` paired with `reason: clean_exit_no_verdict` when the trap fires after a clean process exit that bypassed the terminal emit — analytics-detectable logic bug per #209), `reason` (optional: `clean_exit_no_verdict` only) |
| `build_queue_position` | A build/archive gate enqueued a waiter on the per-node priority queue (#266 / #218). Emitted exactly once per invocation at enqueue time, before any wait. `position == 1` means the entry is currently first by priority order; higher values mean entries are ahead. Joins to Achilles `build_check_*` events via `task` + `studio.dispatch.*` tags; studio release archives use the release tag. | `mode` (`full-green`\|`archive`), `node`, `position` (1-based), `depth` (entries in queue including ours), `slots`, `priority` (`release`\|`task`\|`background`), optional `attempt`, `secret_scope` |
| `build_queue_granted` | A queued build/archive entry became eligible to acquire one of the node's xcodebuild slots. | `node`, `task`, `priority`, `waited_s` |
| `build_queue_promoted` | A `release` entry moved ahead of older lower-priority queued entries. In-flight lock holders keep running; this event only describes queue ordering. | `node`, `promoted_task`, `promoted_priority`, `skipped_count`, `skipped_tasks`, `waited_s` |
| `build_debt_warned` | Build debt crosses warn threshold | `counter`, `threshold` |
| `build_debt_blocked` | Build debt crosses block threshold | `counter`, `override_attempted` (true when Achilles ran with `--ignore-build-debt` against an already-blocked counter) |
| `task_awaiting_user` | Subagent cannot pick a default and must block for user input. Always paired with a debrief at `status: blocked_awaiting_input`. | `question` (≤200 chars), `brief_excerpt` (≤200 chars, the Phase-0 block or the ambiguous spec line), `mode` (`autonomous`\|`interactive`) |
| `task_cancelled` | User cancelled a pending or in-flight task (`scripts/achilles-cancel.sh` or an Achilles abort). Paired with no `task_completed`. | `stage` (`pending`\|`in_flight`\|`merged`), `reason` (`user_abort`\|`replaced`\|`stale_brief`\|`other`), `worker` (`worker-N` if known) |
| `task_rescued` | Worker moved a task to `rescue/` — either `timeout` (rc=124 from `gtimeout`) or `silent_stuck` (rc=0 with no debrief written). Emitted by `scripts/achilles-worker.sh`. Visible equivalent of the rescue file, so Chanakya can surface + push without polling worker directories. | `reason` (`timeout`\|`silent_stuck`), `timeout_s` (only on timeout), `rc`, `debrief_written` (0\|1), `worker` (`worker-N`) |
| `self_review_iterated` | Step 5 triggered a fix-and-rerun — a material finding was found, fixed, and the skill stack re-invoked. Only emitted when `iteration >= 2` (i.e. the cap was reached). Paired with `self_review_path` pointing to the written artifact under `plans/self-reviews/`. | `iteration` (always 2 at cap), `converged` (false if material findings remained after the fix), `material_skills` (array of skill names that returned `material`) |

### Studio events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `precommit_review_passed` | `scripts/pre-commit-review.sh` received `approved` or `approved_with_fixes` for the staged diff. | `verdict`, `review_host`, `branch`, `head`, `patch_id`, `duration_s` |
| `precommit_review_blocked` | `scripts/pre-commit-review.sh` received `blocked` for the staged diff and rejected the commit. | `verdict`, `review_host`, `branch`, `head`, `patch_id`, `duration_s` |
| `precommit_review_bypassed` | User explicitly skipped the staged-diff review gate with `STUDIO_BYPASS_REVIEW=1` or `--bypass-review`. Assistants must not set this bypass on their own initiative. | `verdict` (`bypassed`), `review_host`, `branch`, `head`, `patch_id`, `bypass_source` (`env`\|`flag`), `duration_s` |
| `precommit_hook_completed` | `.githooks/pre-commit` completed its deterministic local gates. The default hook path does not spawn an LLM reviewer; run `scripts/pre-commit-review.sh` explicitly for risky local diffs. | `duration_s`, `exit_code`, `status` (`passed`\|`failed`), `branch`, `head`, `llm_review` (`manual_only`) |
| `pr_review_completed` | `scripts/pr-headless-review.sh` completed the PR-level no-secret reviewer gate and delegated to autopilot when eligible. | `duration_s`, `exit_code`, `status` (`passed`\|`blocked`\|`failed`), `pr`, `pr_url`, `head`, `review_host`, `selected_review_host`, `parent_host`, `eligible_review_hosts` (array of smoke-passing reviewer profiles), `cross_host` (boolean), `cross_host_required` (boolean), `fallback_from` (array), `fallback_failures` (optional), `cross_host_bypass_url` (optional), `verdict`, `method`, `tokens` (`{input, output, cache_read, cache_write}` — best-effort from the reviewer session log; omitted when unavailable) |
| `pr_autopilot_started` | `scripts/pr-autopilot.sh` posted, or is about to post, the parent-owned PR review gate marker for a reviewer verdict. Best-effort telemetry; failure to emit does not block the gate. | `pr`, `pr_url`, `method`, `verdict`, `review_host`, `selected_review_host`, `parent_host`, `eligible_review_hosts`, `cross_host`, `cross_host_required`, `fallback_from`, `fallback_failures`, `cross_host_bypass_url`, `status` (`started`), `duration_s` |
| `pr_autopilot_completed` | `scripts/pr-autopilot.sh` exited after posting the gate marker, stopping on `blocked`, or delegating to merge finalization. Emitted on success and failure. | `pr`, `pr_url`, `method`, `verdict`, `review_host`, `selected_review_host`, `parent_host`, `eligible_review_hosts`, `cross_host`, `cross_host_required`, `fallback_from`, `fallback_failures`, `cross_host_bypass_url`, `status` (`completed`\|`blocked`\|`failed`), `exit_code`, `duration_s` |
| `pr_merge_finalize_started` | `scripts/pr-merge-finalize.sh` read the PR metadata and is about to enforce the review marker and merge policy. Best-effort telemetry; failure to emit does not block merge safety checks. | `pr`, `pr_number`, `pr_url`, `method`, `base_ref`, `head_ref`, `head_sha`, `commit_count`, `status` (`started`), `duration_s` |
| `pr_merge_finalize_completed` | `scripts/pr-merge-finalize.sh` exited after GitHub merge and local cleanup, or after a merge-safety refusal. Emitted on success and failure. | `pr`, `pr_number`, `pr_url`, `method`, `base_ref`, `head_ref`, `head_sha`, `commit_count`, `status` (`completed`\|`failed`), `exit_code`, `duration_s`, `cleanup_failed`, `cleanup_notes`, `remote_merge_warning` |
| `chain_supervisor_decision`, `chain_run_started`, `chain_run_completed`, `chain_started`, `chain_completed`, `chain_issue_started`, `chain_issue_completed`, `chain_issue_closed`, `chain_pr_opened`, `chain_review_completed`, `chain_resume_attempt_started`, `chain_resume_attempt_completed`, `chain_halt_recorded`, `chain_decision_escrow_opened`, `chain_artifact_validation_failed`, `chain_worker_summary_ingested`, `chain_telemetry_gap`, `chain_auth_normalized` | `scripts/studio-chain-runner.sh` executes or resumes an autonomous issue chain. Shared events keep the legacy `data` shape for readers; the private per-run `events.jsonl` additionally uses the structured envelope in `_shared/contracts/chain-run-telemetry.md`. | `run_id`, `chain_run_id`, `issue_run_id`, `status`, `duration_s`, plus event-specific compact fields such as `action`, `stage`, `attempt_id`, `host`, `verdict`, `reason_id`, `gap_kind`, and private artifact pointers. |
| `session_start_completed` | `hooks/session-start` finished assembling bootstrap context. Emits a warning in `additionalContext` only when `duration_s > budget_s`. | `host`, `status` (`completed`\|`budget_exceeded`), `duration_s`, `budget_s` |

### Argus events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `review_requested` | Argus begins review | `task`, `size`, `worktree`, `stage` (`spec`\|`quality`) |
| `review_approved` | All checks pass | `checks_run`, `stage` |
| `review_flagged` | Non-blocking findings | `findings` (array of strings), `stage` |
| `review_blocked` | Hard block — cannot merge | `block_reason`, `check`, `stage` |
| `review_timeout` | `dispatch-review.sh` waited past its timeout without a verdict. The spawned review process is killed, and Achilles must surface the review as blocked rather than silently continue. | `stage`, `idem_key`, `timeout_s`, `elapsed_s`, `requested_at` (when available), `host`, `attempt` |
| `merge_deferred_on_flagged` | Achilles attempted a merge under `--require-approved`, but the latest Argus verdict was flagged rather than approved. No merge occurs; Chanakya surfaces the task for a user decision to fix first or explicitly merge flagged work. | `branch`, `reason` (`review_flagged`), `require_approved`; optional `override` (`--steal-flagged`) |
| `brief_review_flagged` | Chanakya brief-review (#104) found one or more checklist defects in an authored brief. Warn-tier; dispatch is not blocked. Empty `findings` is not emitted (clean runs don't emit). | `brief_uuid`, `finding_count`, `findings` (comma-joined C-item IDs, e.g. `"C1,C4,C7"`), `size`, `type` |
| `test_run_started` | Test phase begins. Argus M/L emits via `argus-run-tests.sh` (machine-local, test-slot semaphore). Achilles test-suite mode emits via `task-test-gate.sh` (node-dispatched, per-node xcodebuild lock — #215). | `slot` (argus) \| `node` (achilles), `suite` (argus) \| `scheme`+`test_target`+`worktree` (achilles), `attempt` (achilles) |
| `test_run_passed` | Tests green | `duration_s`, `test_count`; achilles path additionally carries `node`, `scheme`, `test_target`, `attempt` |
| `test_run_failed` | Tests red | `failing_tests` (array, argus) \| `node`+`scheme`+`test_target`+`duration_s`+`attempt`+`exit_code` (achilles); achilles also uses `reason: locked_out` + `waited_s` for the 30-min lock timeout and the remote-dispatch failure classes from `_shared/contracts/remote-build-dispatch.md` |
| `base_stale` | Base branch advanced since branch point | `base_sha`, `branch_sha` |
| `review_scoped` | A scope cap was triggered (diff cap, file cap, or xs_skip) | `cap` (`diff_size`\|`file_count`\|`xs_skip`), `value`, `limit` |
| `argus_rules_skipped` | Argus classified the diff and skipped rule packs whose `applies_when` metadata did not match. Emitted once per code-quality review after diff extraction. | `skipped` (array of rule-pack names), `classifier` (object from `scripts/argus-classify-diff.sh`) |
| `argus_gate_skipped` | Argus dispatch exited non-zero without a verdict, OR a `task_merged` fired with no preceding `review_(approved\|flagged\|blocked)` for the same task. Loud-skip sentinel for #154. | `stage`, `idem_key`, `reason` (`unknown_host`\|`missing_manifest`\|`missing_spawn_command`\|`secret_scope_floor_unmet`\|`mktemp_failed`\|`validator_unavailable`\|`handoff_schema_violation`\|`verdict_timeout_<N>s`\|`no_verdict_at_merge`\|`unknown_exit_<rc>`), `host` (node id where dispatch was attempted, e.g. `codex-mac-mini-1`; required for infra-broken reasons, optional otherwise), `exit_code` (where applicable) |
| `argus_preflight_failed` | Argus dispatch refused before spawn because the selected host could not satisfy the dispatch preflight. Emitted before the terminal `argus_gate_skipped` event so dashboards can count root causes without parsing stderr. | `stage`, `idem_key`, `reason` (`unknown_host`\|`missing_manifest`\|`missing_spawn_command`\|`secret_scope_floor_unmet`), `host`, `detail` |
| `duration_sanity_fail` | A computed `duration_s` failed the [0, 86400] plausibility check (clock skew, epoch-mismatch, or stale stamp). The emitting site falls back to `null` for the field rather than poison aggregations. Mirrors `emit-agent-session-completed.sh`'s warn-and-omit shape from #157. | `computed`, `start`, `end`, `caller` (script name) |
| `a11y_captured` | Post-test a11y-tree snapshot of the simulator written to `ui-evidence/<task-id>/<utc-ts>.json` via AXe (#174). Bounded summary in payload; full snapshot at `data.snapshot` for human review. `error_labels` flags labels matching `error\|failed\|alert\|crash` (heuristic, informational). | `slot`, `sim`, `snapshot` (relative path under `$HOME`), `elements` (count), `labels` (count), `error_labels` (count) |
| `a11y_capture_skipped` | AXe verification was unreachable — usually `axe_not_found` (xcodebuildmcp missing or older than 1.5.2) or `simulator_not_found`. Best-effort; never blocks the gate. | `slot`, `reason` (`axe_not_found`\|`simulator_not_found`), `sim` (when applicable) |
| `a11y_capture_failed` | AXe `describe-ui` returned non-zero. The error's first line is captured in `error` (truncated to 200 chars). Best-effort; never blocks the gate. | `slot`, `sim`, `error` |

### Chanakya events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `brief_dispatched` | Chanakya transitions a brief to `ready` (hand-off to dispatch queue). Chanakya-side audit anchor — lets sweep detect dispatched-but-never-started briefs without reading worker writes. Emitted after `transition_brief_state ready`; the matching `brief_started` fires Achilles-side at Step 1. | `brief_uuid`, `task_id`, `type`, `size`, `dispatch_agent` (`achilles`\|`apollo`) |
| `task_verified` | review-feedback promotes task | `method` (`review-feedback` \| `test-flow`) |
| `cleanup_completed` | compact sweep finishes | `archived`, `freed_gb` |
| `task_dispatched` | Chanakya writes a task file to a worker inbox (Ship/Dispatch/Sweep-debt modes) | `worker` (`worker-N` or `any`), `flags` (string), `from_brief` (`true`\|`false`) |
| `dispatch_routed` | `achilles-dispatch.sh` resolved which worker to use and why. Always emitted after dispatch; paired with `task_dispatched`. Feeds routing analytics and prefers_node / overlap-avoid observability (#254). | `task_id`, `node_id` (e.g. `worker-2`), `reason` (`round_robin` \| `prefers_node` \| `prefers_node_spill` \| `overlap_avoid`) |
| `task_train_run_started`, `task_train_resume_started`, `task_train_task_started`, `task_train_plan_review_completed`, `task_train_task_dispatched`, `task_train_task_completed`, `task_train_outcome_review_completed`, `task_train_halted`, `task_train_run_completed` | `scripts/chanakya-task-train.sh` runs one manually launched Chanakya task train with sibling plan/outcome reviews around Achilles dispatch. Parallel trains are separate user-started sessions, not auto-spawned by the runner. | `run_id`, `train`, `state_dir`, `uuid`, `stage`, `verdict`, `review_file`, `target`, `terminal_event`, `reason` |
| `feedback_ingested` | Feedback record minted from a Slack thread / DM / channel | `source`, `channel`, `thread_ts`, `reporter`, `build` |
| `feedback_archived` | Feedback record promoted to per-build archive | `build`, `reporter`, `linked_task` |
| `root_cause_promoted` | A `root_cause` label crossed 2+ instances and got its own file | `instances` (array of F-ids) |
| `task_redispatched` | Chanakya dispatches a task whose last prior event was already `task_completed` (or that appears in worker `done/`). Signals brief or output defect — user wasn't satisfied with the first run. | `prior_merge_sha` (if resolvable), `reason` (`user_retry`\|`follow_up`\|`rebase_needed`\|`other`) |
| `task_reopened` | Chanakya reopen mode transitioned a closed task (`verified`\|`merged`\|`archived`\|`cancelled`) back to `reopened`. Pairs with a `task_state_changed` for state-machine integrity; this event carries the domain semantics so downstream consumers (status mode, queries) need not re-read the task YAML. | `prior_state`, `reason` (≤280 chars; conventional prefix from `{qa-rejected\|design-rejected\|product-rejected\|regression\|incomplete}`), `prior_debrief_id` (UUIDv7 of the debrief appended to `reopen_chain`, or `null` if the task had no debrief), `chain_depth` (length of `reopen_chain` after this transition) |
| `brief_edited` | Detected in Step 0E: the brief file's mtime moved forward after the most recent `task_dispatched` for that task, and no `task_completed` has closed it. Signals brief-template defect — user had to hand-edit before the worker picked it up. | `age_s_since_dispatch`, `lines_changed_est` (optional; `wc -l` delta if prior size was recorded) |
| `debrief_edited` | Detected in Step 0E: a processed debrief file's mtime moved forward after it landed in `plans/chanakya-inbox/processed/`. Signals debrief-template defect — user corrected something the agent wrote. | `age_s_since_process`, `lines_changed_est` (optional) |
| `review_override` | User elects to merge / ship despite a `review_flagged` (e.g. "ship anyway" during ship or review-feedback). Signals potential false-positive Argus rule. | `review_file`, `finding_count`, `reason` (short string; ≤100 chars) |
| `review_pending` | Emitted by Chanakya in Step 0A when a processed debrief's `## Argus Review` section indicates Argus was skipped / not invoked on a non-exempt task. Cleared implicitly when a later `review_approved` / `review_flagged` / `review_blocked` lands for the same task. **Suppressed when a structured waive file exists at `~/.dev-studio/<project>/state/waives/<gate>.yaml`** — the waive's `accumulated_count` is still bumped so merge-volume remains visible, but the per-merge reminder is silenced (the "stop nagging" half of issues #83 / #103). | `merge_sha`, `reason` (`argus_skipped_in_debrief`); optional `sunset_on` (string — free-text predicate copied from the active waive file, if any; backward-compatible) |
| `direct_main_ungated_merge` | Post-fact audit. Fires from `sweep-ingest.sh` when an ingested debrief records a merge into a policy-protected integration branch (main, master, release/*, v/*, hotfix/*) with `argus_review.status: not-invoked` AND no external-review citation in `argus_review.reason` / `.notes` (any URL or `#<issue-or-pr>` satisfies the citation requirement). Purely observational — does not block ingest. The report surfaces these; the policy lives in `is_protected_branch` in lib-paths. See #108. | `merge_sha`, `merged_into`, `mode`, `reason` (`argus_not_invoked_no_citation`) |
| `debrief_concerns` | `sweep-ingest.sh` reconciled a debrief with `report_state: done_with_concerns`. Emitted with a stable debrief-derived idempotency key so re-running ingest against the same YAML repairs missing status/push visibility without duplicate task creation. | `debrief_id`, `report_state` (`done_with_concerns`), `reason` (`debrief_report_state`) |
| `debrief_needs_context` | `sweep-ingest.sh` reconciled a debrief with `report_state: needs_context`. Surfaces the blocked/needs-rebrief path when the original event stream missed the worker-report side effect. | `debrief_id`, `report_state` (`needs_context`), `reason` (`debrief_report_state`) |
| `follow_up_mint_failed` | `sweep-ingest.sh` found structured `follow_ups[]` but could not write the corresponding task artifact or the entry lacked a usable title. This is the visible failure path; structured follow-ups must not disappear silently. | `debrief_id`, `follow_up_index`, `reason` (`write_task_artifact_failed`\|`follow_up_title_missing`) |
| `task_awaiting_user_resolved` | Counterpart to `task_awaiting_user` — emitted when the user's answer lands (detected by a subsequent `task_redispatched` or explicit intake of the brief update). Enables "time waiting on user" measurement. | `wait_duration_s`, `resolved_by` (`user_answered`\|`timeout`\|`cancelled`) |
| `brief_awaiting_user` | Emitted by `write_brief_artifact` immediately after the standard `brief_state_changed` event when a brief is minted in `state: draft` AND its body contains an explicit author-decision section (`## Open questions`, `## Decisions pending`, `## Awaiting decision`, or `## Author pass`). Surfaces in inbox-sweep Step 0E as a `brief_awaiting_user` push-queue entry so a draft brief with unresolved decisions never sits invisible. Subject is the brief uuid (in the `task` column of the event row). Cleared implicitly when the brief transitions to `state: ready` (no separate `_resolved` event yet — sweep can dedupe by checking the brief's current state before re-surfacing). Idempotency key is the brief mint idem suffixed with `-awaiting`. | `task_id` (parent task uuid), `legacy_task_id` (parent task display id, e.g. `T352`), `questions` (array of up to 5 strings, ≤200 chars each, extracted from numbered list under the section heading) |
| `build_debt_incremented` | Counter goes up on an XS/S LSP-only merge (every skip, not only threshold crossings). Chanakya emits during inbox sweep when the incoming debrief's `build_gate: lsp-only`. Enables "which task sizes drive debt" analysis. | `counter` (`build`\|`test_unit`\|`test_ui`), `new_value`, `trigger` (`xs_skip`\|`s_skip`\|`tdd_skip`\|`other`) |
| `feedback_reminder_due` | `scripts/sweep-feedback-reminders.sh` fires when a row in `feedback/active.md` §Reminders has a `due_at` in the past. The row is removed atomically on emit (idempotent). Consumers invoke the ingest mode named in `ingest_mode_hint`. Task field is empty. | `reminder_body`, `ingest_mode_hint`, `due_at` |
| `sweep_phase_completed` | A mechanical inbox-sweep phase script completed or no-oped. Emitted by `scripts/lib-sweep-timing.sh` callers so latency reports can separate enumeration, ingest, event reconciliation, and reminders. Task field is empty. | `project`, `phase` (`enumerate`\|`ingest:<kind>`\|`process-events`\|`feedback-reminders`), `status` (`completed`\|`failed`\|`noop`), `item_count`, `duration_s` |
| `appstore_submitted` | `/fullSendToAppStore` writes the `pending-appstore-review.json` marker after posting to `#releases`. Task field = release tag. | `build`, `version`, `submitted_at` |
| `appstore_state_checked` | `scripts/appstore-watch.sh` completed a non-terminal ASC state poll. One emit per real API call (self-gated on `next_check_at`, so far less than one per sweep). | `state` (ASC `appStoreState` value) |
| `appstore_released` | Watcher observed terminal state (`PENDING_DEVELOPER_RELEASE` / `READY_FOR_SALE`) and finalized: draft published, Slack reply posted, marker deleted. | `final_state`, `tag` |
| `appstore_watch_stuck` | Watcher hit ≥3 consecutive failures (JWT, ASC query, `gh release edit`, or Slack post). Marker's `stuck: true` flag is set; next sweep will surface a banner and retry. | `reason`, `failures`, `state` (optional — present when failure was during finalize) |
| `legacy_artifact_read` | A runtime script read or detected a pre-Phase-2.6 artifact. For active fallback readers this means the post-2.6 ledger shape was unavailable (`plans/index.yaml` missing, `plans/debriefs/` absent, `yq` unavailable on the machine, or no YAML artifact carries the requested `legacy_task_id`). For `task-load-spec.sh`, legacy markdown is diagnostic-only: the event records that markdown existed while canonical task/brief YAML failed, but dispatch still exits non-zero. One emit per sweep per domain, or one emit per task-load diagnostic. Task field is empty for sweep-scoped domains; populated for `task-load-spec.sh`. | `domain` (`briefs`\|`debriefs`\|`candidates`), `reason` (`plans_index_missing`\|`plans_debriefs_missing`\|`yq_unavailable`\|`no_yaml_brief_for_legacy_id`\|`legacy_debrief_ingest`\|`canonical_layout_incomplete`\|`no_task_yaml_for_legacy_id`\|`task_yaml_missing_brief_link`\|`linked_brief_yaml_missing`\|`task_brief_parity_mismatch`), `caller` (script name), optional `diagnostic` (boolean), optional `legacy_path` |
| `legacy_event_source_retired` | `scripts/migrate-ledger.sh` cleanup phase moved a pre-2.6 event-log sibling (e.g. `event-log.jsonl`, `events.log`) to `archive/2026-pre-2.6/legacy-event-sources/` after verifying parity against the canonical day-partitioned files. Task field is empty. | `source` (relative path), `source_lines`, `canonical_lines` |
| `feedback_placeholder_pruned` | `scripts/migrate-ledger.sh` cleanup phase removed a `.gitkeep`-only subdir under `feedback/` (e.g. `feedback/root-causes/`). Recreated lazily on first real write. Task field is empty. | `path` (relative path) |
| `inbox_sweep_completed` | Step 0G1 of the inbox sweep — emits the run's counts regardless of whether work was processed. Primary sweep-run telemetry signal. Task field is empty. | `debriefs_ingested`, `orphans_backfilled`, `legacy_pickups`, `debriefs_missing` (#249 Phase 1; optional — back-compat: missing field reads as 0), `events_processed`, `reminders_fired` |
| `debrief_backfilled` | Step 0A.1 of the inbox sweep — `scripts/backfill-orphan-debriefs.sh --apply` detected a `state: done`/`ingested` debrief with no master-plan section and inserted the missing row. Task field is the legacy task id. | `legacy_task_id`, `source` (`orphan_backfill`), `report_state` |
| `debrief_missing` | Two emitters share this event under #249. **Phase 1 (post-hoc detection)** — Step 0E0 of the inbox sweep, `scripts/sweep-detect-missing-debriefs.sh`, detects a `task_merged` event whose paired debrief never landed in `plans/debriefs/`. Catches `task_merged` produced outside the Achilles pipeline or by a manual-mode session that bypassed Step 9–10.5. Stale window: only fires when `task_merged` is older than 600s. Idempotent per `(task, merge_sha)`. Reason field is implicit (no `reason` key) for back-compat. **Pre-merge composite gate** — `scripts/task-merge.sh` emits this event when no `state: emitted` debrief is staged for the task. `reason: pre_merge_blocked` means the #300 composite gate blocked because another safety signal was also absent; `reason: pre_merge_warn` means debrief was the only absent signal and the merge proceeded with a warning. Both phases surface in `/chanakya status` via push-queue. | Phase 1: `merge_sha`, `source_branch` (`achilles/<task-id>`), `age_s`. Pre-merge: `reason` (`pre_merge_blocked` \| `pre_merge_warn`), `branch` (`achilles/<task-id>`). |

#### `brief_completed.gate` taxonomy (issue #84)

Pre-#84 the `gate` field collapsed three distinct outcomes into one `full-green` literal. The expanded enum keeps the verification axis observable without parsing prose:

| `gate` value | Meaning | Source signals |
|---|---|---|
| `verified` | Build green + tests executed + Argus approved or flagged | `build_gate: full-green`, `argus_review.status ∈ {approved, flagged}`, `tests.skipped_because == null` |
| `build-only` | Build green but the test suite was disabled at suite level (no runtime execution) | `build_gate: full-green`, `argus_review.status ∈ {approved, flagged}`, `tests.skipped_because` non-null |
| `waived` | Build green but Argus was skipped / not-invoked on a non-exempt task-mode path | `build_gate: full-green`, `argus_review.status ∈ {skipped, not-invoked}` |
| `lsp-only` | XS/S task — LSP gate only, no xcodebuild, no merge-blocking Argus | `build_gate: lsp-only` |

Precedence: `waived` beats `build-only` when both apply. A waived review is the stronger drift signal, and the user needs to see waivers regardless of test-suite state.

**Backward compatibility.** The event also carries `gate_legacy` ∈ `{lsp-only, full-green}` — the pre-#84 value. Consumers that matched on the old literal keep working; consumers that want the verification split read `gate`. Both fields are emitted unconditionally. `gate_legacy` is a transitional field and may be removed once no consumer depends on it — track under a follow-up issue before deletion.

**Out of scope for this event:** `brief_started.gate_selected` still records the *selected* gate mode (`lsp-only | full-green`) — that's the input side and intentionally distinct from the outcome.

### Apollo events

Emitted by Apollo mode packs (`apollo/modes/*.md`). Agent field is `apollo`. Every Apollo event carries `mode` (`memory` | `thermal` | `battery` | `cpu`), `artifact_shape`, and `cohort` (`<modelCode>/<osMajor>`) at top level inside `data`. Names ship with #230 (memory mode pack); thermal (#231), battery (#232), and CPU (#406) reuse the same envelope.

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `apollo_capture_started` | A capture recipe begins (xctrace record, AXe scenario, MetricKit pastPayload pull) | `mode`, `class`, `recipe`, `cohort`, `scenario`, `signpost`, `tool` |
| `apollo_capture_completed` | Capture produced an artifact persisted under `apollo/captures/<id>/` | `mode`, `class`, `recipe`, `cohort`, `scenario`, `signpost`, `artifact_path`, `artifact_shape`, `discarded` (`true` when the cohort/noise gate from the mode pack rejected the run; payload retained for forensics, not consumed by the regression-detection layer) |
| `apollo_capture_deferred` | A required capture exceeds the session budget; row written to `apollo/deferred/<id>.yaml` | `mode`, `class`, `recipe`, `expected_duration_s`, `deferred_id`, `scheduled_at` |
| `apollo_recommendation` | A recommendation artifact is written at `apollo/recommendations/<id>.md` | `mode`, `class`, `recommendation_id`, `archetype`, `diff_target`, `code_area`, `expected_delta`, `evidence_paths` (array). Verification follow-ups reuse the same event with `status` ∈ {`verified`, `partial`, `regressed`} |
| `apollo_refused` | The strict-9 gate refused after exhausting the auto-capture decision tree | `mode`, `class`, `reason` (`no_evidence` \| `soft_evidence` \| `cohort_mismatch` \| `signpost_missing` \| `dsym_uuid_mismatch` \| `capability_unavailable` \| `human_required`), `attempted_paths` (array), `unblock_recipes` (array) |
| `apollo_advisory` | The 1/10 advisory channel fires with a curated canonical anti-pattern citation | `mode`, `class`, `advisory_id` (e.g. `mem:03`), `diff_target`, `measurement_blocked_reason` |

**Why scoped names.** Apollo is the first agent whose primary output is *evidence about other agents' work*, not a direct task mutation. Distinct event names keep regression dashboards (Apollo) separable from task-flow dashboards (Achilles / Argus / Chanakya). The `mode` + `class` pair is the cardinality axis — every Apollo finding is filterable by which signal it's about and which P0 mode owns it.

### Snapshot events (router-pattern)

Emitted by `scripts/chanakya-snap.sh` (producer side) and by mode packs that consume snapshots (reader side). See `_shared/patterns/router-pattern.md` §Freshness and fallback for the contract. Agent field is `chanakya` on all five.

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `snapshot_generated` | A snapshot producer finishes an atomic write successfully | `domain` (`briefs`\|`debt`\|`feedback-inbox`\|`events-tail`), `duration_ms`, `size_bytes`, `caller` (script name or `prewarm`) |
| `snapshot_hit` | Mode pack read a snapshot whose `generated_at` is within the mode's staleness window | `domain`, `age_seconds` |
| `snapshot_miss` | Mode pack tried to read a snapshot that is absent, empty, or corrupt (fell back to full-load) | `domain`, `reason` (`not_generated`\|`missing_file`\|`corrupt`) |
| `snapshot_stale` | Mode pack read a snapshot whose `generated_at` exceeds the mode's staleness window (fell back to full-load) | `domain`, `age_seconds`, `staleness_window_seconds` |
| `snapshot_failed` | Producer hit an error before the atomic mv — previous snapshot left in place | `domain`, `error` (short string; ≤100 chars) |

**Why five.** `generated` / `failed` on the producer side let us alert if a domain stops refreshing. `hit` / `miss` / `stale` on the consumer side let us measure the actual pre-warm win (ratio of hits to total reads) and detect when a staleness window is too tight (high stale-rate on a domain with frequent writes).

### Dispatch events (issue #137)

Emitted by `scripts/node-pick.sh` and `scripts/node-health.sh`. Agent field is `studio`, mode field is `dispatch`. Payload fields use the `studio.dispatch.*` namespace (see §"Non-conforming studio fields"). These are the discriminating events that close the R14 silent-skip gap on the dispatch layer — every fallback or probe failure leaves a queryable trace.

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `node_fallback` | `node-pick.sh` resolved to `local` because no remote candidate qualified — registry missing, role unknown, all role-bearing nodes disabled, or all enabled candidates unreachable | `studio.dispatch.requested_node` (currently always `""` — node-pick has no preferred-node concept), `studio.dispatch.resolved_node` (`local`), `studio.dispatch.role`, `studio.dispatch.reason` (`fallback:unreachable`\|`fallback:no-role`\|`fallback:disabled`) |
| `node_unreachable` | `node-health.sh` probe (uptime over ssh, or local uptime for self-entry) returned non-zero, or `node-monitor.sh` observed a configured unreachable streak. Node-pick may invoke node-health multiple times in a single `pick`, so a single user-facing operation can produce multiple health emits | `studio.dispatch.node`, `studio.dispatch.probe` (`ssh`\|`uptime`\|`monitor`), `studio.dispatch.error` (≤200 chars; truncated; backslashes/quotes JSON-escaped), optional monitor fields `studio.dispatch.streak_count`, `studio.dispatch.unreachable_hours` |
| `node_disabled_flip` | A node's `enabled` state flips (manual toggle via the `nodes` mode pack, or future auto-disable on N consecutive failures). **Schema-only registration today — no current writer.** Wire when a toggle script lands. | `studio.dispatch.node`, `studio.dispatch.from` (`enabled`\|`disabled`), `studio.dispatch.to`, `studio.dispatch.reason` (short string; e.g. `manual`\|`auto_failures`\|`other`) |
| `node_machine_id_drift` | `node-health.sh` probed the remote's `~/.dev-studio/.runtime/machine-id` and got a value that contradicts the registry's recorded `machine_id` for that id (#146). Hardware was replaced / OS was reinstalled / the id was rebound to a different physical machine. The probe still surfaces `moved` status (dispatch continues — the worker is reachable), but the event lets the user investigate and re-register. **Skipped silently** when either side lacks a machine_id (legacy entries pre-#146, or worker pre-Phase-2.5 H without `machine-id` provisioned). | `studio.dispatch.node`, `studio.dispatch.expected_machine_id` (registry value, ≤64 chars), `studio.dispatch.observed_machine_id` (probed value, ≤64 chars) |
| `dispatch_harvested` | A gate's reconnect-and-harvest probe (#271) found a prior in-flight UUID for `{task_id, node}` whose worker-side `<uuid>.exit` already landed. The gate fetched `<uuid>.log` + `<uuid>.exit` over rsync and used them as the result instead of re-running. Always paired with one of `build_check_passed` / `build_check_failed` / `test_run_passed` / `test_run_failed` carrying `harvested:true` for the same `task` — ordering is `dispatch_harvested` first. The matching registry entry is marked `status:"harvested"` on the laptop side. | `node`, `uuid`, `exit_code` (the rc the worker wrote into `<uuid>.exit`), `mode` (`full-green`\|`swift-test`\|`xcodebuild-test`), `attempt`, `studio.dispatch.*` (mirrored from the gate context) |

#### `studio.dispatch.*` fields stamped on existing gate events

`task-build-gate.sh`, `task-test-gate.sh`, and `swift-test-gate.sh` stamp the dispatch context on `build_check_started` / `build_check_passed` / `build_check_failed` / `build_check_aborted` / `build_queue_position` (build/swift-test gates) and `test_run_started` / `test_run_passed` / `test_run_failed` (test gate). LSP-only mode runs entirely local and emits no dispatch tags — distinguishable from a tagged-but-`local` full-green run.

| Field | Values | Notes |
|---|---|---|
| `studio.dispatch.node` | node id from `nodes.json`, or `local` | Same value as the legacy `node` field on these events; kept for back-compat. |
| `studio.dispatch.role` | `xcodebuild` \| `swift-test` | Capability label requested from `node-pick.sh`. |
| `studio.dispatch.reason` | `healthy` \| `fallback:unreachable` \| `fallback:no-role` \| `fallback:disabled` \| `override` (reserved) | `healthy` when a remote node was picked; `fallback:*` mirrors `node_fallback.reason`. `override` reserved for future env-driven local pinning. |
| `studio.dispatch.xcode_version` | semver string (e.g. `16.4`) or `""` | Best-effort pull from `~/.dev-studio/.runtime/node-parity-cache.json`. Empty when the cache hasn't probed the node yet. |

Side channel: gates set `STUDIO_DISPATCH_REASON_FILE` to a temp path before invoking `node-pick.sh`; node-pick writes one line (the reason value) to that file, gates read it, fold it into the payload, then unlink. Stdout of `node-pick.sh` remains the picked node id only — preserves the long-standing caller contract.

### Studio chain events

Emitted by `scripts/studio-chain-runner.sh`. Agent field is `studio`, mode field is `chain`. Every event carries UUID join keys in `data`: `run_id` for the whole invocation, `chain_run_id` for one manifest chain, and `issue_run_id` for one worker subprocess when applicable. Private run reports live under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/`.

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `chain_supervisor_decision` | `--auto <manifest>` chooses whether to start, resume, report completion, or refuse unattended continuation. `--explain-next` prints the same decision without emitting an event. | `run_id`, `manifest`, `action` (`start`\|`resume`\|`already_complete`\|`refused_ambiguous`\|`refused_escrow`\|`refused_hard_stop`\|`refused_lock`), `reason_id`, `selected_run_id`, `candidate_run_ids`, `lock_path` |
| `chain_run_started` | A chain-runner invocation starts after manifest resolution. | `run_id`, `manifest`, `only_chain`, `host_override`, `status` |
| `chain_started` | One manifest chain starts. | `run_id`, `chain_run_id`, `chain`, `branch`, `base`, `host`, `issue_count` |
| `chain_issue_started` | One issue worktree is prepared and the worker subprocess is about to run. | `run_id`, `chain_run_id`, `issue_run_id`, `issue_branch`, `host`, `commit_before` |
| `chain_issue_completed` | The worker subprocess exits and the parent validates or gap-fills `.studio/chain-worker-summary.json`. | `run_id`, `chain_run_id`, `issue_run_id`, `summary`, `commit_after`, `exit_code`, `worker_duration_s`, `telemetry_gaps` |
| `chain_issue_closed` | The runner closes or comments on an integrated source issue after the chain PR path succeeds. | `run_id`, `chain_run_id`, `issue_number`, `pr_url`, `status` |
| `chain_pr_opened` | The final chain PR is opened. | `run_id`, `chain_run_id`, `pr_number`, `pr_url`, `branch` |
| `chain_review_completed` | `scripts/pr-headless-review.sh <pr> --method auto` exits. | `run_id`, `chain_run_id`, `pr_url`, `exit_code`, `status`, `duration_s` |
| `chain_completed` | One manifest chain finishes its PR path. | `run_id`, `chain_run_id`, `chain`, `pr_url`, `duration_s` |
| `chain_run_completed` | The invocation writes its final private report or abort report. | `run_id`, `report`, `status`, `failure_reason`, `duration_s` |
| `chain_resume_attempt_started` | A manual or supervisor-selected resume invocation begins. | `run_id`, `attempt_id`, `status` |
| `chain_resume_attempt_completed` | A resume invocation finishes, including failed attempts normalized through halt records. | `run_id`, `attempt_id`, `status`, `duration_s`, `failure_reason` |
| `chain_halt_recorded` | A retryable, recoverable, review-needed, human-needed, or fatal halt is persisted. | `run_id`, `chain_run_id`, `issue_run_id`, `reason_id`, `halt_class`, `halt_record`, `status` |
| `chain_decision_escrow_opened` | A worker summary contains an assumption or decision that continued on a low-risk default and needs later review. | `run_id`, `chain_run_id`, `issue_run_id`, `decision_id`, `risk_class`, `status`, `escrow_record` |
| `chain_artifact_validation_failed` | A required child artifact is missing, malformed, or committed when it should remain private. | `run_id`, `chain_run_id`, `issue_run_id`, `artifact`, `reason_id`, `summary`, `status` |
| `chain_worker_summary_ingested` | A worker completion envelope is validated or gap-filled into the private summary root. | `run_id`, `chain_run_id`, `issue_run_id`, `summary`, `status`, `telemetry_gaps` |
| `chain_telemetry_gap` | A worker summary or chain stage lacks optional model, token, test, lint, or build telemetry. | `run_id`, `chain_run_id`, `issue_run_id`, `gap_kind`, `stage`, `reason`, `status` |
| `chain_auth_normalized` | The runner proves GitHub auth through the login-home path before live chain mutation. | `run_id`, `home_source`, `github_auth`, `secrets`, `status` |

### Cross-agent events (every agent emits)

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `agent_session_completed` | Final step of any agent session (any mode) | `mode` (e.g. `ship`, `T001`, `auto-sweep`), `duration_s` (non-negative integer ≤ 86400; **OMITTED when the emitter can't compute a trustworthy value** — see #107. Readers must treat an absent `duration_s` as "session recorded, timing unreliable" rather than default to zero or null), `tokens` (`{input, output, cache_read, cache_write}` — best-effort; may be omitted if not available), `files_read` (count), `files_written` (count), `model_selected` (optional model id), `model_fallback_reason` (optional reason when selection differs from recommendation) |
| `stale_index_lock_removed` | `safe_git_commit` (see `_shared/primitives/safe-git.md`) cleared a stale `.git/index.lock` with no live holder. Tracks frequency so the producer side can be root-caused if it rises. | `repo` (absolute path from `git rev-parse --show-toplevel`), `caller_skill` (e.g. `pushTFBuild`, `achilles-merge`, `gcpr`) |
| `boot_validation_failed` | **RETIRED 2026-04-26 (#210).** Was emitted by `emit-agent-boot.sh` when caller-supplied `skill_version` was non-semver (#158). #210 makes `<agent>/SKILL.md` frontmatter the SSOT, so the runtime now collapses parse failures to `skill_version: "unresolved"` rather than rejecting the boot. The lint (`E_MISSING_VERSION`/`E_BAD_VERSION` in `lint-skill-prose.sh`) is the new commit-time gate; runtime fallback writes a stderr warning. Historical events with this name remain in old logs. | (historical) `reason`, `value`, `session_id` |
| `dual_write_partial` | A Phase 2.6 dual-writer (see `_shared/patterns/dual-write-transition.md`) succeeded on the YAML side but failed on the legacy counterpart. Emitted by `scripts/lib-ledger.sh` helpers. Paired with exit code `3` from the caller so the next sweep surfaces the drift rather than it silently compounding. | `subject_kind` (`task`\|`brief`\|`round`\|`release`\|`debrief`\|`review`), `subject_uuid`, `legacy_path`, `reason` (short string; e.g. `permission_denied`\|`disk_full`\|`concurrent_lock`\|`other`) |

**Why `agent_session_completed`.** Without this we can't measure context cost or session duration per agent. Treat as required at the end of every Chanakya / Achilles / Argus session, regardless of how the session terminated. If token counts aren't available to the agent at emit time, omit the `tokens` key — duration alone is still useful.

## OTel GenAI conformance

Every event emitted by `scripts/lib-ledger.sh::emit_event_keyed` (and therefore by `scripts/write-event.sh`) carries three top-level OTel GenAI semantic convention attributes alongside the existing fields. Attribute placement is **top-level** — not nested under `data:` — for maximum compatibility with third-party dashboards (Datadog, Langfuse, Arize Phoenix, Traceloop) that consume the OTel GenAI span model natively.

Transport stays JSONL. These are attribute names, not a protocol change.

### Attribute set

| Attribute | Type | Values | Source | Notes |
|---|---|---|---|---|
| `gen_ai.system` | string | `claude-code` \| `codex` \| `aider-like` | `$STUDIO_HOST` env var (default `claude-code`) | Replaces the bespoke `host:` field that was planned but not shipped. Set by the spawning process (`hooks/session-start`, H8). |
| `gen_ai.agent.name` | string | `achilles` \| `argus` \| `chanakya` | `--agent` positional arg | Mirrors the existing top-level `agent` field; both are kept for back-compat during transition. |
| `gen_ai.operation.name` | string | `invoke_agent` \| `create_agent` \| `handoff` | Mapped from event name | See mapping table below. |

**Best-effort attributes** (add when available; omit when not):

| Attribute | Notes |
|---|---|
| `gen_ai.agent.id` | Task ID or round ID for the current operation. |
| `gen_ai.conversation.id` | Same as task ID — the logical conversation thread. |
| `gen_ai.request.model` | Model identifier (e.g. `claude-opus-4-7`). |
| `gen_ai.usage.input_tokens` | Integer. Omit when not available (e.g. most mid-session events). |
| `gen_ai.usage.output_tokens` | Integer. Omit when not available. |

Best-effort attributes are **not** stamped by `emit_event_keyed` automatically — callers include them in the `data:` payload or as future top-level extensions. The three required attributes above are stamped on every event.

### `gen_ai.operation.name` mapping

| Event pattern | Mapped value |
|---|---|
| Event name contains `handoff` | `handoff` |
| `agent_boot`, `agent_session_completed` | `create_agent` |
| All other events | `invoke_agent` |

### Non-conforming studio fields — `studio.*` namespace

Studio-specific fields that have no OTel GenAI equivalent live under the `studio.*` namespace in `data:`:

```json
{"data": {"studio.worktree": "/path/to/wt", "studio.brief_id": "..."}}
```

Never invent `gen_ai.*` attributes — use `studio.*` for anything not in the OTel GenAI spec.

### Backward compatibility

Pre-H5 events (written before host-agnostic workers v1) have no `gen_ai.*` attributes. Consumers must treat a missing `gen_ai.system` as `"claude-code"` — the only host that existed before v1. `scripts/read-events.sh --gen-ai-system <value>` applies this default automatically.

## Offset Marker (Consumer Pattern)

Chanakya maintains a byte offset in project memory to avoid re-processing events on every wake:

**File:** `<project-memory>/events_offset.md`

```markdown
# Event Log Offset
date: 2026-04-18
offset: 4096
```

On wake, Chanakya reads from `offset` bytes into today's JSONL file to EOF, processes new events, then updates the offset to the new EOF position.

**Offset reset:** When `date` in the offset file differs from today, reset offset to 0 and update the date field. (New file, no prior events to skip.)

**Reading from offset:**
```bash
tail -c +$((OFFSET + 1)) "$EVENT_FILE"   # +1 because tail -c counts from 1
```

After processing, update offset:
```bash
OFFSET=$(wc -c < "$EVENT_FILE")
```

## Push Queue

For push notifications, agents append to the per-project push queue at `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` (resolve via `scripts/lib-paths.sh resolve_push_queue`) — see `_shared/primitives/push-notifications.md`.
