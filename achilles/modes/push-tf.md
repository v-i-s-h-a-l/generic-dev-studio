---
name: Achilles Push-TF
description: TestFlight Release wrapper (`/achilles push-tf`). Wraps the existing `/pushTFBuild` skill, adds pre-flight task collection and post-flight release debrief. The build workflow itself is unchanged — this mode exists to bind the release to Chanakya's task tracking.
type: mode-pack
snapshots: []
budget_tokens: 1500
reads: []
writes: []
---

# Mode: TestFlight Release (`/achilles push-tf [--skip-debrief]`)

Wraps the existing `/pushTFBuild` skill. Achilles adds pre-flight task collection and post-flight release debrief — the build workflow itself is unchanged.

Slack message format (used by `/pushTFBuild`) is defined in `_shared/contracts/build-message-format.md`; this mode does not duplicate or override it.

## TF1 — Pre-flight: collect shipping tasks

1. Read `~/.dev-studio/<project>/plans/chanakya-master.md`.
2. Read the `## Release Log` table (if it exists). Find the last TestFlight entry and note its `HEAD SHA`.
3. Collect all tasks whose status is `done` or `verified` and whose `Merge commit:` SHA is an ancestor of current HEAD but a descendant of the last TestFlight build's HEAD SHA. These are the tasks shipping in this build.
4. If the Release Log is empty or has no TestFlight entries, fall back to collecting all `done` + `verified` tasks whose `Released in:` field does NOT already contain a `TF-` entry.
5. Print the pre-flight summary:
   > "Pre-flight: <N> tasks will ship in this TestFlight build: T015, T016, T017. Proceeding to build..."

## TF2 — Invoke the skill

Run `/pushTFBuild` exactly as-is. Do not modify any step, prompt, or behavior. The user interacts with the skill normally (confirms version bump, approves Slack message, etc.).

If the skill fails at any point, stop. Do not write a debrief. Report: "TestFlight build failed. No debrief written."

## TF3 — Capture outputs

After `/pushTFBuild` completes successfully, extract:
- `BUILD_NUMBER`: from the version bump commit message (pattern: `Bump build number to <N>`) or by reading `CURRENT_PROJECT_VERSION` from the project file.
- `VERSION`: from `MARKETING_VERSION` in the project file.
- `BRANCH`: current git branch.
- `HEAD_SHA`: `git rev-parse HEAD` (this is the version bump commit).

## TF4 — Write release debrief

If `--skip-debrief` was passed, skip this step.

Write to `~/.dev-studio/<project>/plans/chanakya-inbox/tf-<BUILD_NUMBER>-debrief.md`:

```markdown
# Debrief: tf-<BUILD_NUMBER> — TestFlight Release
Type: testflight-release
Completed: <YYYY-MM-DD HH:mm IST>
HEAD: <HEAD_SHA>
Branch: <BRANCH>

## Release Info
Build number: <BUILD_NUMBER>
Version: <VERSION>
Distribution: TestFlight
Covers: [T015, T016, T017, ...]

## Tasks Included
- T015 — <title> (done, merged <merge-date>)
- T016 — <title> (verified, merged <merge-date>)
- T017 — <title> (done, merged <merge-date>)
```

## TF5 — Report

> "TestFlight build <BUILD_NUMBER> (v<VERSION>) uploaded. Debrief dropped for Chanakya — <N> tasks included (T015, T016, T017)."
