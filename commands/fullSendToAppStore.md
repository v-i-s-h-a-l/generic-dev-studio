---
description: Tag current commit, draft GitHub release, and submit build to App Store review
allowed-tools: [Bash, Read, Edit, Grep]
---

# Full Send to App Store

Tag the current commit, create a GitHub draft release, and submit the build to App Store Connect for review with manual release. Mechanical work (tag + push, GH draft, ASC API calls) routes through `scripts/studio-tf-push.sh appstore` in the studio repo (`~/Documents/v-i-s-h-a-l/github/generic-dev-studio`). This wrapper drives release-notes composition, the human-approval gate, and the optional Slack post.

Authoritative knobs: `_shared/primitives/turnip-project-config.md` (App ID, ASC ids), `_shared/contracts/build-message-format.md` (release-notes shape).

Authentication is App Store Connect API key based. The appstore driver uses `STUDIO_TF_ASC_KEY_PATH` when configured, otherwise derives `~/.dev-studio/<project>/secrets/appstoreconnect/AuthKey_<key-id>.p8` from `STUDIO_TF_ASC_KEY_ID`; `STUDIO_TF_ASC_ISSUER_ID` is required in both cases. Session auth, fastlane discovery, and third-party credential schemes are not automatic fallbacks for submission.

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

If the script reports a missing `STUDIO_TF_ASC_*` value or unreadable `.p8` key, fix the ASC API-key configuration in `~/.dev-studio/${STUDIO_RELEASE_PROJECT}/config/release.env` or the project secret root and rerun. Do not switch to session-based upload credentials.

The stable GH release URL — same for draft and published — is:

```
https://github.com/turnip-ios/turnip-zaps/releases/tag/${CURRENT_BUILD_NUMBER}-zaps
```

## Step 6: Optional Slack post

Post the unified A body via:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
export STUDIO_RELEASE_PROJECT="${STUDIO_RELEASE_PROJECT:-<project>}"
./scripts/slack-post.sh --channel <release-channel-id> --text "$RELEASE_BODY"
```

Confirm to the user with the Slack permalink and the GH release URL.

## Rollback

To revert this wrapper to the legacy version: `git revert` the commit that introduced this file in the studio repo. Legacy ran the ASC API calls + `gh release create` inline.
