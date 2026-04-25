---
name: Achilles App-Store
description: App Store Release wrapper (`/achilles app-store`). Wraps the existing `/fullSendToAppStore` skill, captures App Store–specific data (git tag, GitHub release URL) alongside the release artifact + release debrief that bind the submission to Chanakya's task tracking.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 1500
reads:
  - plans/index.yaml                               # post-migration task + release index for shipping-task collection
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/releases/*.yaml                          # prior releases for previous-tag lookup (schema: _shared/schemas/release.md)
  - plans/chanakya-master.md                       # legacy fallback (## Release Log) until Commit H
writes:
  - plans/releases/<release-id>.yaml               # post-migration canonical (schema: _shared/schemas/release.md, release@1.0.0, channel: appstore)
  - plans/debriefs/<debrief-id>.yaml               # paired release-type debrief (schema: _shared/schemas/debrief.md, mode: task — release surface)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.release on each shipping task
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh
  - plans/chanakya-inbox/release-<build>-debrief.md  # legacy markdown debrief during Phase 2.6 transition
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: App Store Release (`/achilles app-store [--skip-debrief]`)

Wraps the existing `/fullSendToAppStore` skill. Same wrapper pattern as TestFlight mode but captures additional App Store–specific data (git tag, GitHub release URL).

Slack message format (used by `/fullSendToAppStore`) is defined in `_shared/contracts/build-message-format.md`; this mode does not duplicate or override it.

## AS1 — Pre-flight: collect shipping tasks

1. Read prior releases. Post-migration: `scripts/query-plans.sh --kind=release --channel=appstore` enumerates prior App Store releases from `plans/releases/*.yaml`. Legacy fallback reads the `## Release Log` table in `chanakya-master.md`.
2. Find the last App Store entry (if any). Note its `tag`, `commit_sha`, and `released_at`.
3. Collect shipping tasks the same way as TF1 in the TestFlight release mode, but scoped to the App Store release range. Post-migration: query `scripts/query-plans.sh --kind=task --state=verified,merged` and filter by merge-SHA ancestry against the previous App Store commit_sha.
4. Also record the previous release tag (for the release artifact's `tag` lineage + the debrief's `Previous release tag:` legacy field). If no prior App Store release exists, use the oldest available tag matching `^[0-9]+-zaps$`.
5. Print the pre-flight summary:
   > "Pre-flight: <N> tasks will ship in this App Store release: T015, T016, T017. Previous release: <PREV_TAG>. Proceeding..."

## AS2 — Invoke the skill

Run `/fullSendToAppStore` exactly as-is. The user interacts with the skill normally (confirms release notes, approves submission, etc.).

If the skill fails, stop. No debrief. Report the failure.

## AS3 — Capture outputs

After `/fullSendToAppStore` completes successfully, extract:
- `BUILD_NUMBER`: the submission build number (may differ from current if the user picked a different build at the skill's Step 8).
- `VERSION`: the App Store version string.
- `GIT_TAG`: the tag created by the skill (format: `<BUILD_NUMBER>-zaps`). Verify it exists with `git tag -l`.
- `GITHUB_RELEASE_URL`: from the `gh release create` output, or reconstruct from the tag.
- `HEAD_SHA`: `git rev-parse HEAD`.

## AS4 — Write release artifact + debrief

If `--skip-debrief` was passed, skip this step entirely. Otherwise write **two** artifacts (no dual-write for the release artifact itself — it is a net-new shape):

**Release artifact** — write to `~/.dev-studio/<project>/plans/releases/<release-id>.yaml` per schema `_shared/schemas/release.md` (`release@1.0.0`). Mint `id` as a UUIDv7. Populate `schema_version`, `channel: appstore`, `state: submitted` (per `_shared/state-machines/release-lifecycle.md`; the watcher drives subsequent transitions), `build_number`, `version`, `tag: <GIT_TAG>`, `commit_sha: <HEAD_SHA>`, `submitted_at`, `last_state_checked_at: null`, `released_at: null`, `tasks: [<task-id>…]`, `reviews: []`, `asc_metadata: {asc_build_id: null, app_store_state: null, last_poll_at: null, next_check_at: <submitted_at+30min>, consecutive_failures: 0, stuck: false}` (the watcher populates these on first poll), and `slack` block (filled when the release Slack post lands; null pre-post).

Update each shipping task's `plans/tasks/<task-id>.yaml`: set `links.release = <release-id>` (back-reference per §2.2 plan invariant), bump `updated_at`. Emit `release_state_changed` (null → submitted) per `_shared/contracts/events.md` via `scripts/write-event.sh`.

**Release debrief** — write the paired debrief as YAML to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` per schema `_shared/schemas/debrief.md` (`debrief@2.0.0`). Mint `id` as a UUIDv7. Populate `schema_version`, `task_id: null` (release debriefs aggregate many tasks — no single parent), `brief_id: null`, `mode: task` (release is treated as a task-mode debrief variant; the `key_learnings` / `follow_ups` fields carry per-release context), `completed_at`, `branch: {worked_on: <BRANCH>, merged_into: null, merge_sha: <HEAD_SHA>}`, `commits: []` (the release itself is not a commit series — the `tag` on the release artifact is the authoritative pointer), `diff_summary: {files: 0, added_lines: 0, removed_lines: 0}` (placeholder — release debriefs do not carry a per-file diff), `decisions: []`, `tests: {added: [], modified: [], skipped_because: "release-mode debrief; per-task test coverage lives on the individual task debriefs"}`, `testability: null`, `build_gate: full-green` (the release pipeline verified build), `build_debt_override: false`, `debt: {build: false, test_unit: false, test_ui: false, notes: null}`, `performance: []`, `key_learnings: []`, `known_issues: []`, `follow_ups: []`, `open_questions: []`, `argus_review: {status: not-invoked, review_id: null, notes: "release-mode; argus gate is on per-task merges, not the release submission"}`.

Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.

**Phase 2.6 transition note:** also write the legacy markdown debrief at `~/.dev-studio/<project>/plans/chanakya-inbox/release-<BUILD_NUMBER>-debrief.md` so Chanakya's inbox sweep (until Commit H cutover) still sees the release:

```markdown
# Debrief: release-<BUILD_NUMBER> — App Store Release
Type: appstore-release
Completed: <YYYY-MM-DD HH:mm IST>
HEAD: <HEAD_SHA>
Branch: <BRANCH>

## Release Info
Build number: <BUILD_NUMBER>
Version: <VERSION>
Git tag: <GIT_TAG>
GitHub release: <GITHUB_RELEASE_URL>
Distribution: App Store
Covers: [T015, T016, T017, ...]
Previous release tag: <PREV_TAG>

## Tasks Included
- T015 — <title> (verified, merged <merge-date>)
- T016 — <title> (verified, merged <merge-date>)
- T017 — <title> (done, merged <merge-date>)
```

## AS5 — Report

> "App Store build <BUILD_NUMBER> (v<VERSION>) submitted. Tag: <GIT_TAG>. Release artifact + debrief dropped for Chanakya — <N> tasks included."
