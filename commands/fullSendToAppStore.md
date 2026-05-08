---
description: Tag current commit, draft GitHub release, and submit build to App Store review
allowed-tools: [Bash, Read, Edit, Grep]
---

# Full Send to App Store

Tag the current commit, create a GitHub draft release, and submit the build to App Store Connect for review with manual release. Mechanical work (tag + push, GitHub draft, ASC API calls, configured Slack posting, release artifact, and PR handoff) routes through `scripts/studio-tf-push.sh appstore` in the studio repo (`~/Documents/v-i-s-h-a-l/github/generic-dev-studio`). This wrapper drives release-notes composition, App Store "What's New" composition, and the human-approval gate before the script receives approved files.

Authoritative knobs: project release config (App ID, ASC ids, Slack channels),
`_shared/contracts/build-message-format.md` (release-notes shape). Configure
Slack release announcements with `/dev-studio release-manager configure`.

Operator path: use `/fullSendToAppStore` for the full App Store submission.
The split is intentional: this wrapper owns language and approval; the script
owns external mutations and durable handoff state.

## Ownership

| Surface | Owner |
|---|---|
| Release notes and App Store "What's New" drafts | `/fullSendToAppStore` wrapper |
| Human approval before any tag, GitHub release, ASC submission, or public Slack message | `/fullSendToAppStore` wrapper |
| Tag push, GitHub draft release creation, App Store Connect submission, localization update | `scripts/studio-tf-push.sh appstore` |
| Configured App Store Slack parent/thread post and PR link reply | `scripts/studio-tf-push.sh appstore` using the approved wrapper files |
| GitHub release publication, Slack link update, and PR promotion after `READY_FOR_SALE` | `scripts/appstore-watch.sh` after `scripts/pr-merge-finalize.sh` records release approval |
| Reporter `cc:` attribution | Not used for App Store release notes; TestFlight drafting owns reporter tagging |

## Step 1: Resolve build + previous tag + commits

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
CURRENT_BUILD_NUMBER=$(grep -m1 "CURRENT_PROJECT_VERSION" zaps-app/Turnip.xcodeproj/project.pbxproj | tr -dc '0-9')
VERSION=$(grep -m1 "MARKETING_VERSION" zaps-app/Turnip.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' ')
PREV_TAG=$(git tag --sort=-creatordate | grep -E '^[0-9]+-zaps$' | head -1)
git log "${PREV_TAG}..HEAD" --no-merges --format="%h %s%n%b%n---"
```

Read full commit messages (subject + body) for informed release notes.

## Step 2: Classify commits and compose two outputs

For each fix commit:
1. Identify what code/feature it touches.
2. `git show ${PREV_TAG}:<file>` (or feature-introduction check) to determine if the buggy code existed at `PREV_TAG`.
3. If introduced **after** `PREV_TAG` → fold into the parent feature bullet or omit (internal iteration).
4. If at or before `PREV_TAG` → real user-facing fix, include.

Compose two outputs:

**A) Slack parent body + GitHub release notes (unified).** Three-section shape per `build-message-format.md` (`*New*` / `*Fixed*` / `*Crash fixes*`, skip empty sections). Release-specific overrides:
- Drop regressions introduced and fixed within `PREV_TAG..HEAD` — net delta to users is zero.
- Crash bullets: `• Fixed crash <Crashlytics URL>` or `• Possible fix for crash <Crashlytics URL>`.
- No `cc:` mentions (release audience is broader). No rollover line.

**B) App Store "What's New".** Playful, user-facing, flowing sentences (no bullets, no emojis). Short — under 500 chars ideally.

## Step 3: Show both, get user approval

Show A and B clearly labelled. Ask: *"Does this look good? You can say 'edit github notes', 'edit app store notes', or 'looks good' to proceed."*

Wait for approval or edits before continuing.

## Step 4: Write approved text to files

```bash
cat > /tmp/release-notes.txt <<'EOF'
<approved release notes A>
EOF
cat > /tmp/whats-new.txt <<'EOF'
<approved what's new B>
EOF
```

## Step 5: Run the studio appstore submission

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
export STUDIO_RELEASE_PROJECT="${STUDIO_RELEASE_PROJECT:-<project>}"
export STUDIO_RELEASE_TAG="release-${CURRENT_BUILD_NUMBER}-$(date -u +%Y%m%d-%H%M%S)"
STUDIO_TF_PUSH_LIVE=1 ./scripts/studio-tf-push.sh appstore \
  --build "$CURRENT_BUILD_NUMBER" \
  --version "$VERSION" \
  --release-notes-file /tmp/release-notes.txt \
  --whatsnew-file /tmp/whats-new.txt
```

The script tags `${BUILD}-zaps`, pushes the tag, creates a GH draft release (account-switched to `vishal-zaps`), finds the build on ASC, creates or updates the App Store version, sets MANUAL release type with the build attached, and updates `whatsNew` for every localization.

After the pending App Store watcher marker is armed, the script immediately raises a PR from the current source branch to `main`. If that branch already has an open PR to `main`, it reuses the existing PR. If another branch already has a pending App Store PR, it surfaces: `There is already a PR pending from <branch>. This new build is from <new-branch>. Raising a separate PR.` The PR is intentionally left open until the watcher sees `READY_FOR_SALE`; the watcher then merges it with `gh pr merge --merge`.

The stable GH release URL — same for draft and published — is:

```
https://github.com/turnip-ios/turnip-zaps/releases/tag/${CURRENT_BUILD_NUMBER}-zaps
```

## Step 6: Optional configured Slack post

`scripts/studio-tf-push.sh appstore` reads the project release config and, when
`STUDIO_RELEASES_SLACK_CHANNEL` plus the App Store Slack toggles are enabled,
posts the release parent message and configured thread replies. It persists the
Slack channel id and parent `ts` into the pending App Store marker so
`scripts/appstore-watch.sh` can post lifecycle replies into the same thread.
While the GitHub release is still a draft, the thread link is the PR URL. When
ASC reaches `READY_FOR_SALE`, the watcher publishes the GitHub release and
updates that thread reply to the release URL. If Slack is not configured, the
script skips Slack cleanly and reports that release announcements are not
configured.

## Rollback

To revert this wrapper to the legacy version: `git revert` the commit that introduced this file in the studio repo. Legacy ran the ASC API calls + `gh release create` inline.
