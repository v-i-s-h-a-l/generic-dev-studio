---
name: Achilles App-Store
description: App Store Release wrapper (`/achilles app-store`). Wraps the existing `/fullSendToAppStore` skill, captures App Store–specific data (git tag, GitHub release URL) alongside the release debrief that binds the submission to Chanakya's task tracking.
type: mode-pack
snapshots: []
budget_tokens: 1500
---

# Mode: App Store Release (`/achilles app-store [--skip-debrief]`)

Wraps the existing `/fullSendToAppStore` skill. Same wrapper pattern as TestFlight mode but captures additional App Store–specific data (git tag, GitHub release URL).

Slack message format (used by `/fullSendToAppStore`) is defined in `_shared/build-message-format.md`; this mode does not duplicate or override it.

## AS1 — Pre-flight: collect shipping tasks

1. Read the master plan and `## Release Log`.
2. Find the last App Store entry (if any). Note its git tag and HEAD SHA.
3. Collect tasks the same way as TF1 in the TestFlight release mode, but scoped to the App Store release range.
4. Also record the previous release tag (for the `Previous release tag:` field in the debrief). If no prior App Store release exists, use the oldest available tag matching `^[0-9]+-zaps$`.
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

## AS4 — Write release debrief

If `--skip-debrief` was passed, skip this step.

Write to `~/.dev-studio/<project>/plans/chanakya-inbox/release-<BUILD_NUMBER>-debrief.md`:

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

> "App Store build <BUILD_NUMBER> (v<VERSION>) submitted. Tag: <GIT_TAG>. Debrief dropped for Chanakya — <N> tasks included."
