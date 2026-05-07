---
name: TestFlight Push Contract
description: Authoritative procedure for studio-owned TestFlight / App Store Connect builds — prerequisites, archive, upload, dSYM, Slack draft, human-approval gate, send, event taxonomy, and the requires_secret_scope declaration that pins TF/AS work to laptop nodes.
type: reference
schema_version: 1
---

# TestFlight Push Contract

Authoritative recipe for the studio-owned TF/AS push procedure. Stage C (`scripts/studio-tf-push.sh`) and Stage E (`/pushTFBuild` / `/postSlackTesting` / `/fullSendToAppStore` wrappers) implement against this document. A future Nabu agent's mode pack imports the same contract — the procedure does not move when the entry point changes.

Project-specific knobs (paths, scheme, ASC key id/issuer, App ID, Crashlytics plist) live in `_shared/primitives/turnip-project-config.md`. Read those there; this contract names the *steps*, not the values.

## Dispatch declaration

The release driver declares:

```
requires_secret_scope: ["asc", "slack"]
role: release
```

`scripts/node-pick.sh --requires-secret-scope asc,slack release` filters the registry (`~/.dev-studio/.runtime/nodes.json`) to nodes whose `secret_scopes` array is a superset of `["asc", "slack"]`. Nodes with a missing or empty `secret_scopes` advertise no scopes and are filtered out. Today only the laptop entry advertises both scopes; mini's entry does not — TF/AS work routes to laptop, period. New machines join with `secret_scopes: []` by default and stay out of the release path until explicitly granted.

When no candidate qualifies, `node-pick.sh` falls back to `local` and emits `node_fallback` with `reason: fallback:secret-scope` (see `events.md` §Dispatch events). The driver halts on `local` rather than running secret-bearing code on an unauthorized host — the fallback exists for diagnostic visibility, not for permission inheritance.

## Prerequisites

Before Step 1:

- Repo at `_shared/primitives/turnip-project-config.md::project_root` is checked out and clean (`git status` shows no unstaged or staged paths). The version-bump commit in Step 5 must be the only delta this run introduces.
- The active branch is the branch the user wants on TestFlight. The driver does not switch branches.
- Project release config is readable at `~/.dev-studio/<project>/config/release.env`.
- ASC private key is readable at `~/.dev-studio/<project>/secrets/appstoreconnect/AuthKey_<key-id>.p8` or the `STUDIO_TF_ASC_KEY_PATH` configured in `release.env`.
- Slack bot token is readable per `_shared/primitives/slack-post.md` (`~/.dev-studio/<project>/secrets/slack-bot-token`, chmod 600).
- `python3` resolves and the `pyjwt` package is importable (used to mint the ASC JWT — see `_shared/primitives/appstore-connect-jwt.md`).
- Non-interactive GitHub push works for the active branch: `GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never git push --dry-run --porcelain -u origin HEAD` succeeds. This preflight runs before any build-number or version mutation; auth failures must not open a credential prompt or create a stranded release commit.
- Slack notification credentials are verified before mutation unless `STUDIO_TF_SLACK_DEFERRED=1` explicitly marks the run as upload-only/deferred-notification.
- Long-running push work can be started with `scripts/studio-tf-push.sh push --background`. The parent returns a JSON handle immediately and the child writes status/log/context artifacts under `~/.dev-studio/<project>/state/release-runs/<release-tag>/`.
- Every TF push creates an annotated git tag at the build-number commit before the archive phase: `tf-<version>-<build>` (for example `tf-26.4.17-3162`). The driver pushes both the active feature branch and that tag to origin before archiving so withdrawn or superseded TF builds still leave a stable diff/revert anchor.

Halt with `release_started` not emitted if any prerequisite fails. Stage C's wrapper surfaces the missing piece to the user.

## Procedure

The 14 logical steps below collapse into 6 substantive phases. Each phase names the events it must emit; ordering is strict.

### Step 1 — Resolve current ASC state

Mint a JWT per `_shared/primitives/appstore-connect-jwt.md`. Call:

- `GET /v1/builds?sort=-uploadedDate&limit=1&fields[builds]=version` — extract `LATEST_BUILD_NUMBER` (integer).
- `GET /v1/apps/{app_id}/appStoreVersions?filter[appStoreState]=READY_FOR_SALE&fields[appStoreVersions]=versionString` — extract `LIVE_VERSION` (string). `{app_id}` comes from `_shared/primitives/turnip-project-config.md::app_id` (currently `6502945736`); the top-level `appStoreVersions` collection is not readable for this check.

Read `CURRENT_VERSION` from the project's pbxproj (`MARKETING_VERSION`).

Emit `release_started` with `data: { build_from: LATEST_BUILD_NUMBER, live_version: LIVE_VERSION, current_version: CURRENT_VERSION, branch }`. This event opens the span; every later event in the run carries the same `task` field (the release tag — see §Idempotency).

If the live-version request fails, times out, returns an `errors` array, or returns `{"data":[]}`, halt before Step 3 with:

```
WARNING: Could not determine live App Store version
```

The driver must not treat an empty or failed live-version response as "no conflict".

### Step 2 — Decide new build number and version

`NEW_BUILD_NUMBER = LATEST_BUILD_NUMBER + 1` always.

Version rule (binary; the only inputs allowed are `CURRENT_VERSION` and `LIVE_VERSION`):

- `CURRENT_VERSION == LIVE_VERSION` → version MUST bump.
- `CURRENT_VERSION != LIVE_VERSION` → keep `CURRENT_VERSION`. Multiple TF builds at the same in-flight version is the normal state; testers distinguish by build number.

If a bump is required, compute `"YY.M.N"` where `YY` = last 2 digits of current year, `M` = current month with no leading zero. `N` = `parse(LIVE_VERSION)`'s third component plus 1 when `LIVE_VERSION` matches `YY.M.*` (same year + month); otherwise `N = 0`.

No menu. No "should I bump?". The rule is the contract — driver implementations that deviate are the bug.

### Step 3 — Update pbxproj and commit

Update every occurrence of `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` in `_shared/primitives/turnip-project-config.md::pbxproj_path`. Both keys appear multiple times — replace all.

Commit via `safe_git_commit` (see `_shared/primitives/safe-git.md`) with `CALLER_SKILL=studio-tf-push`. Message:

```
Bump build number to <NEW_BUILD_NUMBER>

Preparing TestFlight build <NEW_BUILD_NUMBER> (v<VERSION>) from branch <BRANCH>.

Co-Authored-By: Claude Opus 4.X (1M context) <noreply@anthropic.com>
```

Create an annotated TF anchor tag at the bump commit:

```
tf-<VERSION>-<NEW_BUILD_NUMBER>
```

Push the branch with `git push -u origin HEAD`, then push the tag with
`git push origin refs/tags/tf-<VERSION>-<NEW_BUILD_NUMBER>`. R11 (no
studio-initiated pushes to base branches) applies — the driver halts if the
active branch is `main` / `master` / `release/*`. Tag pushes are allowed because
they do not advance a base branch.

If a future push failure still occurs after the local bump commit, emit a
stranded-release-state warning naming the local commit, TF tag, and the next
safe recovery command. Do not write release artifacts or debriefs unless upload
later succeeds.

If a TF build is later withdrawn, mark the anchor by renaming it to:

```
tf-<VERSION>-<NEW_BUILD_NUMBER>-WITHDRAWN
```

Use `scripts/studio-tf-push.sh withdraw-tf-tag --version <VERSION> --build <NEW_BUILD_NUMBER>`.
The command creates an annotated withdrawn tag at the original commit, pushes
it, deletes the unqualified remote tag, and removes the local unqualified tag.
The withdrawn tag remains the stable anchor for diff/revert workflows while
making state visible in tag lists.

Withdrawn App Store/GitHub release convention:

- Keep the git tag; never delete the audit anchor.
- Rename the GitHub Release title to `[WITHDRAWN] <tag>`.
- Keep the GitHub Release as a draft and never promote it to Latest.
- Prepend a withdrawal banner to the release body with the replacement release link when known.
- Update the release artifact to `state: withdrawn` and set `superseded_by` to the replacement release-id once the replacement exists; the replacement artifact sets `replaces`.

No event emitted at the commit boundary; the next event closes the archive phase.

### Step 4 — Archive

Run `xcodebuild archive` against the project, scheme, and configuration declared in `turnip-project-config.md`. The archive lands at `/tmp/<SCHEME>-<NEW_BUILD_NUMBER>.xcarchive`.

When running in background mode, write `prepared-context.json` after Step 2 and before this archive starts. The file carries `release_tag`, `build`, `version`, `scheme`, `branch`, `archive_path`, `tf_tag`, and `prev_build`, allowing the wrapper to draft the Slack message while archive/upload continue. The wrapper must still wait for final `status.json` to reach `state=="succeeded"` before sending Slack.

Before invoking `xcodebuild archive`, enqueue the archive with `priority: "release"` in `~/.dev-studio/.runtime/build-queue/<node-id>/`, then acquire an `xcodebuild-lock/<node-id>/slot-<n>/` lock before starting the archive. The queue grants up to the node's `parallel_build_slots` and moves release entries ahead of queued task/background work without stopping any in-flight holder.

Authentication is JWT-based via `-authenticationKeyPath` / `-authenticationKeyID` / `-authenticationKeyIssuerID`. `CODE_SIGN_STYLE=Automatic`. Pipe through `xcpretty` for human-readable progress; raw output is preserved on a failure path.

Verify the `.xcarchive` directory exists at the expected path. If absent, halt — do not export, do not upload, do not draft Slack.

Emit `archive_completed` with `data: { build: NEW_BUILD_NUMBER, version, scheme, archive_path, duration_s }`.

### Step 5 — Export and upload

Write a transient `ExportOptions.plist` with `method=app-store-connect`, `destination=upload`, `signingStyle=automatic`. Run `xcodebuild -exportArchive` against the archive. The plist's `destination=upload` means xcodebuild posts the build directly to ASC — there is no separate upload step and no local IPA.

Do not pipe this command through `xcpretty`. The raw output is short and load-bearing for diagnosis.

Verify by scanning the captured output:

- `Export Succeeded` → upload succeeded.
- `** EXPORT FAILED **` or any `error:` line → upload failed; halt and surface the line. Common causes: ASC key auth failure (verify the key path), build-number collision on ASC (re-resolve Step 1).
- `warning:` lines about missing third-party-framework dSYMs (AppsFlyer, Firebase, etc.) are harmless. Ignore.

Emit `upload_completed` with `data: { build: NEW_BUILD_NUMBER, version, duration_s }` only on success. On failure, emit `release_failed` with `data: { stage: "upload", reason }` and halt.

### Step 6 — Upload dSYMs to Crashlytics

Run only when Step 5 succeeded.

`xcodebuild -exportArchive` does not trigger the Crashlytics run script, so dSYMs upload explicitly. Resolve `upload-symbols` from DerivedData (`~/Library/Developer/Xcode/DerivedData/Turnip-*/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols`); use the GoogleService-Info.plist named in `turnip-project-config.md`. Upload one dSYM at a time — bulk upload is known to crash on certain archives.

If `upload-symbols` is empty (DerivedData was cleaned), continue without it. The archive at `/tmp/<SCHEME>-<NEW_BUILD_NUMBER>.xcarchive` remains for manual upload later. dSYM upload failure is non-blocking for the rest of the run.

Emit `dsym_uploaded` with `data: { build: NEW_BUILD_NUMBER, count_succeeded, count_failed, count_skipped, reason: "derived_data_clean" | null }`. The event fires even on partial failure — the data carries the breakdown.

### Step 7 — Compose and draft Slack message

Run only when Steps 4 and 5 both verified successful.

Compose the build-message body from the user's commits since the last shared TF build. Resolve the Slack channel from `STUDIO_TF_SLACK_CHANNEL` in the project release config; run `/dev-studio release-manager configure` if it is absent. Find the last shared build via `scripts/slack-fetch.sh history --channel "$STUDIO_TF_SLACK_CHANNEL"` (wraps `conversations.history`), filtering for messages from the studio's posting bot identity that match `build NNNN is available on TestFlight`. The matching `Bump build number to NNNN` commit is the lower bound for `git log --no-merges --author="<owner>" --format=...`. Thread-reply scans for cc-mention attribution use `scripts/slack-fetch.sh replies --channel <id> --ts <parent-ts>`; display-name resolution uses `scripts/slack-fetch.sh user --user <U>`.

If a `tf-<version>-<build>` tag exists for the last shared build on this
branch, prefer it as the lower bound:

```
git log <last-tf-tag-on-this-branch>..HEAD --no-merges --author="<owner>" --format=...
```

This keeps Slack composition independent of whether the prior TF build was
eventually released, superseded, or withdrawn.

For a withdrawn-and-replaced build, update the existing announcement parent and
thread with the withdrawal and replacement context. Do not start a new top-level
post unless no parent announcement exists; the audit trail belongs in one
thread.

### Hotfix replacement workflow

The hotfix-replacement mode-pack contract is: import this contract and
`_shared/state-machines/release-lifecycle.md`, then chain the replacement flow in
one pass. The flow preflights the current release artifact, applies the
withdrawn/superseded state transition, preserves or renames the GitHub Release
and TF anchor, submits the replacement build, sets `replaces` /
`superseded_by`, and updates the existing announcement thread.

Format the parent and thread per `_shared/contracts/build-message-format.md`.
The default parent is brief: headline, one tester-facing summary, then
`Details in thread.` The detailed tester checklist goes in the first thread
reply. Group by product area/module when useful; otherwise use the standard
three-section shape (`*New*` / `*Fixed*` / `*Crash fixes*`, skip empty
sections), feature rollup, regression labelling, rollover bullet
`• includes changes from <PREV_BUILD_NUMBER>` when stacking on an unreleased TF.
Important technical notes go at the end under `*Technical notes*` only when
they affect testing or product expectations.

If the draft starts from git commits, use
`scripts/studio-tf-push.sh compose-message --channel testflight` against
git-log-style commit blocks to apply the commit taxonomy before hand-editing.
For App Store copy, run the same input through `--channel appstore`; TF-only
work-in-progress and internal buckets are intentionally omitted there.

Headline: `[iOS] build <NEW_BUILD_NUMBER> is available on TestFlight`. Prefix
`<!here>` only when `STUDIO_TF_SLACK_NOTIFY_HERE=1`; the configured default is
off.

Scan the last 3–4 build threads from the studio's posting bot in the configured TestFlight channel. For each composed bullet, check thread replies for matching bug reports or feature requests. Append `cc: <@USER_ID>` inline on bullets in the thread detail that match a reporter. Resolve display names via `users.info` for review only — the parenthesised name is not part of the final message.

Emit `slack_drafted` with `data: { build: NEW_BUILD_NUMBER, channel, bullet_count, cc_count }`. Persist the draft text and resolved cc-list to a transient artifact under `~/.dev-studio/<project>/state/release-drafts/<release-tag>.txt` for the approval gate.

### Step 8 — Human approval gate

Show the draft to the user verbatim — including the parenthesised display names next to each `<@USER_ID>` for review readability. Ask: *"Send this, or edit first?"*

Wait for explicit approval. Edits loop back through Step 7's emit (replace the artifact, re-emit `slack_drafted` with the same `release_tag` task field — idempotency-keyed, so consumers see one draft span with the latest content). No `slack_sent` until the user approves.

D1 of issue #217 locks this gate. The driver does not auto-send. A future iteration track (Phase 4) may improve the *format*; the gate itself stays.

### Step 9 — Send to Slack

Post the parent via `scripts/slack-post.sh --channel "$STUDIO_TF_SLACK_CHANNEL" --text <parent>` (wraps `chat.postMessage` per `_shared/primitives/slack-post.md`). Capture the response `ts` as `PARENT_TS`; assert non-empty before posting the detail thread via `scripts/slack-post.sh --thread-ts <PARENT_TS> --text <thread>`. Strip the parenthesised display names before sending — they are reviewer-only.

Emit `slack_sent` with `data: { build: NEW_BUILD_NUMBER, channel, parent_ts: PARENT_TS, message_chars }`.

If the post fails, emit `release_failed` with `data: { stage: "slack_send", reason }` and surface to the user. The build is already on TestFlight — the failure is in notification, not delivery — so the driver does not retry the upload steps.

## Event taxonomy

Every event below carries `agent: "studio"`, `mode: "release"` (per the OTel envelope in `events.md` §OTel GenAI conformance) and the same `task` value for the duration of the run. The release tag — `release-<NEW_BUILD_NUMBER>-<utc-yyyymmdd-hhmmss>` — is the `task` field. Stamp it on emit, not at the call site.

| Event | Required fields under `data` | Ordering | Idempotency |
|---|---|---|---|
| `release_started` | `build_from`, `live_version`, `current_version`, `branch` | First. Opens the span. | One per release tag. Re-runs use a new tag. |
| `archive_completed` | `build`, `version`, `scheme`, `archive_path`, `duration_s` | After Step 4 success. | One per release tag. |
| `upload_completed` | `build`, `version`, `duration_s` | After Step 5 success only. | One per release tag. |
| `dsym_uploaded` | `build`, `count_succeeded`, `count_failed`, `count_skipped`, `reason` (or `null`) | After Step 6, success or partial. | One per release tag. |
| `slack_drafted` | `build`, `channel`, `bullet_count`, `cc_count` | After Step 7. | Multiple permitted per release tag — each user edit re-emits with the same `task`; the latest is current. |
| `slack_sent` | `build`, `channel`, `parent_ts`, `message_chars` | After Step 9 success only. Closes the span. | One per release tag. |
| `release_failed` | `stage`, `reason` | Any stage; fatal. | One per release tag. Pairs with no later success event. |

`release_failed.stage` enum: `prereq` | `archive` | `upload` | `dsym` | `draft` | `approval_timeout` | `slack_send`. The driver does not collapse stages — `dsym` failure is non-blocking and emits `dsym_uploaded` with a non-zero `count_failed` instead of `release_failed`.

### Field semantics

- `build` is integer, `version` is the dotted string. Both stable across the run.
- `duration_s` is monotonic seconds for that step's wall-clock work. Apply the `[0, 86400]` plausibility check from `events.md` — on failure, omit the field rather than emit a poisoned value (and emit `duration_sanity_fail` per the same source).
- `reason` is a short string ≤ 200 chars. Truncate; never embed multiline output. Long error logs go to a transient artifact under `~/.dev-studio/<project>/logs/release/<release-tag>/<stage>.log`; the event names the path via a separate `log_path` data key when present.

### Idempotency

The release tag is the idempotency key. A re-run of Step 7 (after an edit during the approval gate) re-uses the same tag; `lib-ledger.sh::emit_event_keyed` dedupes accordingly. A re-run after `release_failed` mints a new tag — re-runs are not retries; they are fresh attempts.

This matches `_shared/contracts/idempotency.md` §Per-action keys: the writable boundary is the ASC upload (Step 5), the Slack post (Step 9), and the pbxproj commit (Step 3). Each is naturally idempotent at its own layer (ASC rejects duplicate build numbers; Slack `chat.postMessage` rejects no duplicates but the parent-once invariant in `_shared/primitives/slack-post.md` covers the failure mode; git rejects non-fast-forward).

## Cross-references

- `_shared/primitives/turnip-project-config.md` — project paths, scheme, ASC key id/issuer, bundle id.
- `_shared/primitives/appstore-connect-jwt.md` — JWT minting helper invoked in Step 1.
- `_shared/primitives/safe-git.md` — `safe_git_commit` wrapper used in Step 3.
- `_shared/primitives/slack-post.md` — token loading, `chat.postMessage`, `<!here>` rule, parent-once invariant.
- `scripts/slack-post.sh` — write primitive (`chat.postMessage`); used by Step 9.
- `scripts/slack-fetch.sh` — read primitive (`conversations.history` / `.replies` / `users.info`); used by Step 7.
- `_shared/contracts/build-message-format.md` — authoritative Slack-body composition rules referenced in Step 7.
- `_shared/contracts/events.md` — top-level event log schema; this contract registers the seven events above into that catalog.
- `_shared/contracts/idempotency.md` — keyed-emit dedupe semantics referenced under §Idempotency.
- `scripts/node-pick.sh` — implements `--requires-secret-scope` filter consumed by Stage C.
- REVIEW.md R11 — base-branch push prohibition; the driver halts before Step 3's `push -u origin HEAD` if the active branch is protected.
