---
name: Achilles Push-TF
description: TestFlight Release wrapper (`/achilles push-tf`). Wraps the existing `/pushTFBuild` skill, adds pre-flight task collection and post-flight release artifact + debrief. The build workflow itself is unchanged — this mode exists to bind the release to Chanakya's task tracking.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 1500
reads:
  - plans/index.yaml                               # post-migration task + release index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/releases/*.yaml                          # prior TestFlight releases for shipping-task range (schema: _shared/schemas/release.md)
writes:
  - plans/releases/<release-id>.yaml               # canonical (schema: _shared/schemas/release.md, release@1.0.0, channel: testflight)
  - plans/debriefs/<debrief-id>.yaml               # paired release-type debrief (schema: _shared/schemas/debrief.md)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.release on each shipping task
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: TestFlight Release (`/achilles push-tf [--skip-debrief]`)

Wraps the existing `/pushTFBuild` skill. Achilles adds pre-flight task collection and post-flight release debrief — the build workflow itself is unchanged.

Slack message format (used by `/pushTFBuild`) is defined in `_shared/contracts/build-message-format.md`; this mode does not duplicate or override it.

## TF1 — Pre-flight: collect shipping tasks

1. Read prior releases. `scripts/query-plans.sh --kind=release --channel=testflight` enumerates prior TestFlight releases from `plans/releases/*.yaml`.
2. Find the last TestFlight entry (if any). Note its `commit_sha`.
3. Collect shipping tasks. `scripts/query-plans.sh --kind=task --state=merged,verified` returns candidates; filter by merge-SHA ancestry (ancestor of current HEAD, descendant of the last TestFlight commit_sha) and by absence of a `links.release` entry.
4. If no prior TestFlight release exists, collect all merged/verified tasks without a `links.release`.
5. Print the pre-flight summary:
   > "Pre-flight: <N> tasks will ship in this TestFlight build: T015, T016, T017. Proceeding to build..."

## TF2 — Invoke the skill

Run `/pushTFBuild` exactly as-is. Do not modify any step, prompt, or behavior. The user interacts with the skill normally (confirms version bump, approves Slack message, etc.).

If the skill fails at any point, stop. Do not write a debrief. Report: "TestFlight build failed. No debrief written."

### TF2a — Monitoring a backgrounded archive

When `xcodebuild archive` is run in the background and watched with the Monitor tool, **do not grep the log for completion strings.** The raw `** ARCHIVE SUCCEEDED **` marker is swallowed by xcpretty (which formats it as `▸ Archive Succeeded`); any grep pattern is fragile against xcpretty format changes. Use the filesystem directly:

```bash
# Check presence of the archive's Products/ subtree — present iff archive succeeded.
ARCHIVE_PATH="/tmp/<SCHEME>-<BUILD_NUMBER>.xcarchive"
[ -d "$ARCHIVE_PATH/Products" ]
```

**Polling shape:** filesystem check + timeout, never log grep + infinite loop.

```bash
elapsed=0
until [ -d "$ARCHIVE_PATH/Products" ]; do
  [ "$elapsed" -ge 1200 ] && {
    printf 'archive not complete after 20 min — check log at %s\n' "$LOG_PATH" >&2
    exit 2
  }
  sleep 15
  elapsed=$((elapsed + 15))
done
```

Archives typically take 8–15 min. The 20-min cap is a stuck-detection signal, not a hard deadline — surface via stderr so the user sees it and can inspect.

## TF3 — Capture outputs

After `/pushTFBuild` completes successfully, extract:
- `BUILD_NUMBER`: from the version bump commit message (pattern: `Bump build number to <N>`) or by reading `CURRENT_PROJECT_VERSION` from the project file.
- `VERSION`: from `MARKETING_VERSION` in the project file.
- `BRANCH`: current git branch.
- `HEAD_SHA`: `git rev-parse HEAD` (this is the version bump commit).

## TF4 — Write release artifact + debrief

If `--skip-debrief` was passed, skip this step entirely. Otherwise write **two** artifacts:

**Release artifact** — write to `~/.dev-studio/<project>/plans/releases/<release-id>.yaml` per schema `_shared/schemas/release.md` (`release@1.0.0`). Mint `id` as a UUIDv7. Populate `schema_version`, `channel: testflight`, `state: submitted` (per `_shared/state-machines/release-lifecycle.md`; TestFlight processes builds without formal review — state typically advances `submitted → released` on processing completion), `build_number`, `version`, `tag: "TF-<BUILD_NUMBER>"`, `commit_sha: <HEAD_SHA>`, `submitted_at`, `last_state_checked_at: null`, `released_at: null`, `tasks: [<task-id>…]`, `reviews: []`, `asc_metadata: null` (TestFlight does not use the App Store review queue; the watcher may still poll build-processing states), `slack: null` (filled when the release Slack post lands).

Update each shipping task's `plans/tasks/<task-id>.yaml`: set `links.release = <release-id>` (back-reference per §2.2 plan invariant), bump `updated_at`. Emit `release_state_changed` (null → submitted) via `scripts/write-event.sh`.

**Release debrief** — write the paired debrief as YAML to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` per schema `_shared/schemas/debrief.md` (`debrief@2.0.0`). Mint `id` as a UUIDv7. Populate `schema_version`, `task_id: null`, `brief_id: null`, `mode: task` (release treated as a task-mode variant; release-specific context lives in `key_learnings`), `completed_at`, `branch: {worked_on: <BRANCH>, merged_into: null, merge_sha: <HEAD_SHA>}`, `commits: []`, `diff_summary: {files: 0, added_lines: 0, removed_lines: 0}`, `decisions: []`, `tests: {added: [], modified: [], skipped_because: "release-mode debrief; per-task test coverage lives on the individual task debriefs"}`, `testability: null`, `build_gate: full-green`, `build_debt_override: false`, `debt: {build: false, test_unit: false, test_ui: false, notes: null}`, `performance: []`, `key_learnings: []`, `known_issues: []`, `follow_ups: []`, `open_questions: []`, `argus_review: {status: not-invoked, review_id: null, notes: "release-mode; argus gates per-task merges, not release submission"}`.

Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.

## TF5 — Report

> "TestFlight build <BUILD_NUMBER> (v<VERSION>) uploaded. Release artifact + debrief dropped for Chanakya — <N> tasks included (T015, T016, T017)."
