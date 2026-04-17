---
description: Tag current commit, draft GitHub release, and submit build to App Store review
allowed-tools: [Bash, Read, Edit, Grep]
---

# Full Send to App Store

Tag the current commit, create a GitHub draft release with playful release notes, and set up an App Store Connect submission with manual release.

## Configuration
- Repo: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios`
- pbxproj: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj/project.pbxproj`
- App Store Connect Key ID: `WJQ6D76K8R`
- App Store Connect Issuer ID: `1fa9f26b-7b13-459a-9225-1ca8d9c51fca`
- App Store Connect Key file: `~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8`

---

## Step 1: Get current build number

```bash
grep -m1 "CURRENT_PROJECT_VERSION" /Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj/project.pbxproj | tr -dc '0-9'
```

This gives us `CURRENT_BUILD_NUMBER` (e.g. `3030`).

---

## Step 2: Get the previous release tag

```bash
git -C /Users/vishalsingh/Documents/Turnip.gg/turnip-ios tag --sort=-creatordate | grep -E '^[0-9]+-zaps$' | head -1
```

This is `PREV_TAG` (e.g. `3027-zaps`).

---

## Step 3: Get commits between previous tag and HEAD

Read full commit messages (subject + body) so the detailed context can inform release notes and App Store "What's New":
```bash
git -C /Users/vishalsingh/Documents/Turnip.gg/turnip-ios log <PREV_TAG>..HEAD --no-merges --format="%h %s%n%b%n---"
```

Filter out version/build bump commits (lines containing "Bump build", "Bump version"). These are the meaningful changes. Use the commit body (what/why/where) to write better, more informed release notes.

---

## Step 4: Compose release notes (two versions)

**Before composing**, classify each bug fix commit to determine if it belongs in the release notes:

For each commit that looks like a fix:
1. Identify what code/feature the fix touches
2. Check whether that code/feature existed at `PREV_TAG` (e.g. `git show <PREV_TAG>:<file>` or check if the feature was introduced after `PREV_TAG`)
3. If the buggy code was introduced **after** `PREV_TAG` → the fix is internal development iteration. Either fold it into the parent feature's bullet point or omit it entirely
4. If the buggy code existed **at or before** `PREV_TAG` → it's a real user-facing bug fix. Include it in the Bug Fixes section

Examples:
- "Fixed Select Frame gizmo not working on empty placeholders" — the gizmo was added in this cycle → omit
- "Fixed scroll-to-tap misinterpretation in grids" — image placeholder grids existed before → keep
- "Disabled crop on user-added stickers" — user-added stickers existed before → keep

Using the filtered and classified commits, write two versions of release notes:

**A) GitHub Draft Release Notes** — playful, user-friendly, past tense, written for a technical-but-fun audience. Group related changes under **bold section headers** (e.g. `**Editor**`, `**Collage**`, `**Bug Fixes**`). Short bullet points under each group. No emojis. Example:
```
**Editor**
- Fixed the canvas shrinking when opening the photo picker
- The collage viewport now stays put after filling a placeholder

**Bug Fixes**
- Fixed placeholder auto-focus not triggering correctly when tapped
```

**B) App Store "What's New"** — even more playful and user-facing, written like you're talking directly to the user. Keep it short (under 4000 chars, ideally under 500). No emojis. No bullet points — flowing sentences or short punchy lines. Example:
```
We tidied up the editor and it shows. The canvas stays the right size when you go to pick a photo, and tapping placeholders in your collage now works exactly the way you expect. Small things, big difference.
```

---

## Step 5: Show both to user and ask for confirmation

Display both versions clearly labelled and ask:
"Does this look good? You can say 'edit github notes', 'edit app store notes', or 'looks good' to proceed."

Wait for user approval or edits before continuing.

---

## Step 6: Push branch and create the git tag

```bash
git -C /Users/vishalsingh/Documents/Turnip.gg/turnip-ios push -u origin HEAD
git -C /Users/vishalsingh/Documents/Turnip.gg/turnip-ios tag <CURRENT_BUILD_NUMBER>-zaps
git -C /Users/vishalsingh/Documents/Turnip.gg/turnip-ios push origin <CURRENT_BUILD_NUMBER>-zaps
```

---

## Step 7: Create GitHub draft release

Make sure `gh` is using the `vishal-zaps` account:
```bash
gh auth switch --user vishal-zaps
```

```bash
gh release create <CURRENT_BUILD_NUMBER>-zaps \
  --repo turnip-ios/turnip-zaps \
  --title "<CURRENT_BUILD_NUMBER>-zaps" \
  --notes "<GITHUB_RELEASE_NOTES>" \
  --draft
```

Confirm the draft release URL to the user.

---

## Step 8: Ask which build number to submit to App Store

Ask the user:
"Which build number do you want to submit for App Store review? (default: `<CURRENT_BUILD_NUMBER>`)"

Wait for their answer. Use `SUBMISSION_BUILD_NUMBER` going forward.

---

## Step 9: Generate App Store Connect JWT

```bash
TOKEN=$(python3 -c "
import jwt, time
key = open('$(echo ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8)').read()
payload = {
    'iss': '1fa9f26b-7b13-459a-9225-1ca8d9c51fca',
    'iat': int(time.time()),
    'exp': int(time.time()) + 1200,
    'aud': 'appstoreconnect-v1'
}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': 'WJQ6D76K8R'}))
")
```

---

## Step 10: Find the build on App Store Connect

IMPORTANT: Use `-sg` flag with curl to disable glob expansion (required for URLs with square brackets):

```bash
curl -sg "https://api.appstoreconnect.apple.com/v1/builds?filter[version]=<SUBMISSION_BUILD_NUMBER>&include=preReleaseVersion&limit=1" \
  -H "Authorization: Bearer $TOKEN"
```

Parse the response to get:
- `BUILD_ID` — the build's `id` field
- `VERSION_STRING` — from `included[].attributes.version` (the marketing version like `26.3.1`)

---

## Step 11: Find or create the App Store Version

The App ID for Zaps is `6502945736` (bundle ID: `gg.zaps.ios`). Use this directly.

```bash
# Check for existing versions - list all and filter in Python
curl -sg "https://api.appstoreconnect.apple.com/v1/apps/6502945736/appStoreVersions?fields[appStoreVersions]=versionString,appStoreState,releaseType" \
  -H "Authorization: Bearer $TOKEN"
```

- If a version exists in `PREPARE_FOR_SUBMISSION` and its `versionString` matches `VERSION_STRING` → use it (`APP_STORE_VERSION_ID`)
- If no matching version exists → create one:

```bash
curl -s -X POST "https://api.appstoreconnect.apple.com/v1/appStoreVersions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "appStoreVersions",
      "attributes": {
        "platform": "IOS",
        "versionString": "<VERSION_STRING>",
        "releaseType": "MANUAL"
      },
      "relationships": {
        "app": {
          "data": { "type": "apps", "id": "<APP_ID>" }
        }
      }
    }
  }'
```

Save the new `APP_STORE_VERSION_ID`.

---

## Step 12: Set the build on the App Store version

```bash
curl -s -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersions/<APP_STORE_VERSION_ID>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "appStoreVersions",
      "id": "<APP_STORE_VERSION_ID>",
      "relationships": {
        "build": {
          "data": { "type": "builds", "id": "<BUILD_ID>" }
        }
      }
    }
  }'
```

Also ensure `releaseType` is `MANUAL`:

```bash
curl -s -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersions/<APP_STORE_VERSION_ID>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "appStoreVersions",
      "id": "<APP_STORE_VERSION_ID>",
      "attributes": {
        "releaseType": "MANUAL"
      }
    }
  }'
```

---

## Step 13: Update "What's New" for all localizations

First, get all localizations for this version:

```bash
curl -s "https://api.appstoreconnect.apple.com/v1/appStoreVersions/<APP_STORE_VERSION_ID>/appStoreVersionLocalizations" \
  -H "Authorization: Bearer $TOKEN"
```

For **each localization** returned, PATCH the `whatsNew` field with the App Store release notes text:

```bash
curl -s -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/<LOCALIZATION_ID>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "appStoreVersionLocalizations",
      "id": "<LOCALIZATION_ID>",
      "attributes": {
        "whatsNew": "<APP_STORE_WHATS_NEW>"
      }
    }
  }'
```

---

## Step 14: Create the App Store submission

NOTE: The old `appStoreVersionSubmissions` API is deprecated. Use the new `reviewSubmissions` API instead:

```bash
# Step 14a: Create a review submission
REVIEW_SUBMISSION_ID=$(curl -sg -X POST "https://api.appstoreconnect.apple.com/v1/reviewSubmissions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "reviewSubmissions",
      "attributes": { "platform": "IOS" },
      "relationships": {
        "app": { "data": { "type": "apps", "id": "6502945736" } }
      }
    }
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

# Step 14b: Add the app store version to the submission
curl -sg -X POST "https://api.appstoreconnect.apple.com/v1/reviewSubmissionItems" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"type\": \"reviewSubmissionItems\",
      \"relationships\": {
        \"reviewSubmission\": { \"data\": { \"type\": \"reviewSubmissions\", \"id\": \"$REVIEW_SUBMISSION_ID\" } },
        \"appStoreVersion\": { \"data\": { \"type\": \"appStoreVersions\", \"id\": \"<APP_STORE_VERSION_ID>\" } }
      }
    }
  }"

# Step 14c: Submit for review
curl -sg -X PATCH "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/$REVIEW_SUBMISSION_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"type\": \"reviewSubmissions\",
      \"id\": \"$REVIEW_SUBMISSION_ID\",
      \"attributes\": { \"submitted\": true }
    }
  }"
```

---

## Step 15: Post to #releases Slack channel

Slack channel: `C01PVRBMFJ6` (#releases)

Load the Slack bot token once for all subsequent calls (stored out-of-repo at `~/.claude/secrets/slack-bot-token`, chmod 600). If the file is missing, halt and ask the user to run `/chanakya sync-slack --configure-token`.

```bash
SLACK_BOT_TOKEN=$(cat ~/.claude/secrets/slack-bot-token)
```

**Main message** — format exactly like this (no @here or <!here>):
```
[iOS] v<VERSION_STRING> (build <SUBMISSION_BUILD_NUMBER>) has been submitted for App Store review

<GITHUB_RELEASE_NOTES>
```

```bash
PARENT_TS=$(curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"C01PVRBMFJ6\",\"text\":\"[iOS] v<VERSION_STRING> (build <SUBMISSION_BUILD_NUMBER>) has been submitted for App Store review\n\n<GITHUB_RELEASE_NOTES_ESCAPED>\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['ts'])")
```

**Reply 1** — GitHub release URL only:
```bash
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"C01PVRBMFJ6\",\"thread_ts\":\"$PARENT_TS\",\"text\":\"<GITHUB_RELEASE_URL>\"}"
```

**Reply 2** — App Store "What's New" with context header, two blank lines before the actual text:
```
App Store "What's New" submitted with this build:


<APP_STORE_WHATS_NEW>
```

```bash
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"C01PVRBMFJ6\",\"thread_ts\":\"$PARENT_TS\",\"text\":\"App Store \\\"What's New\\\" submitted with this build:\n\n\n<APP_STORE_WHATS_NEW_ESCAPED>\"}"
```

IMPORTANT: Escape newlines as `\n` and any double quotes in the message text before embedding in the JSON `-d` payload.

---

## Step 16: Done

Confirm to the user:
- Git tag created and pushed: `<CURRENT_BUILD_NUMBER>-zaps`
- GitHub draft release created (show URL)
- App Store submission created for version `<VERSION_STRING>` (build `<SUBMISSION_BUILD_NUMBER>`) with manual release
- Posted to #releases on Slack

Remind the user: the app will not go live automatically after approval — they need to manually release it from App Store Connect.
