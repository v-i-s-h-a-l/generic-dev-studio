---
description: Bump build number/version, archive, and push to TestFlight via App Store Connect
allowed-tools: [Bash, Read, Edit, Grep]
---

# Push iOS Build to TestFlight

Archive the current branch and upload it to TestFlight, automatically bumping the build number and version if needed.

## Configuration
- Project: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj`
- Scheme: `Zaps`
- pbxproj: `/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj/project.pbxproj`
- App Store Connect Key ID: `WJQ6D76K8R`
- App Store Connect Issuer ID: `1fa9f26b-7b13-459a-9225-1ca8d9c51fca`
- App Store Connect Key file: `~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8`

## Steps

### Step 1: Fetch App Store Connect info

Generate a JWT token and call the App Store Connect API to get:

**a) Latest TestFlight build number** — call the builds endpoint, sort by uploadedDate descending, take the first result's `version` field (this is the build number).

**Use the App Store Connect REST API directly:**

```bash
# Step 1a: Generate JWT using python3
TOKEN=$(python3 -c "
import jwt, time, sys
key = open('$(echo ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8)').read()
payload = {'iss': '1fa9f26b-7b13-459a-9225-1ca8d9c51fca', 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': 'WJQ6D76K8R'}))
")

# Step 1b: Get latest build number from TestFlight
curl -sg "https://api.appstoreconnect.apple.com/v1/builds?sort=-uploadedDate&limit=1&fields[builds]=version" \
  -H "Authorization: Bearer $TOKEN"

# Step 1c: Get current live App Store version
curl -sg "https://api.appstoreconnect.apple.com/v1/appStoreVersions?filter[appStoreState]=READY_FOR_SALE&fields[appStoreVersions]=versionString" \
  -H "Authorization: Bearer $TOKEN"
```

Parse the JSON responses to extract:
- `LATEST_BUILD_NUMBER` (integer, e.g. 3030)
- `LIVE_VERSION` (string, e.g. "26.2.0")

### Step 2: Determine new build number and version

**New build number:** `LATEST_BUILD_NUMBER + 1`

**Version check:**
- Get `CURRENT_VERSION` from pbxproj: `grep -m1 "MARKETING_VERSION" <pbxproj>`
- If `CURRENT_VERSION == LIVE_VERSION`, we must bump the version (it's already live on App Store)
- If `CURRENT_VERSION != LIVE_VERSION`, keep the current version (it's still in TestFlight review)

**If version bump needed**, compute new version:
- `YY` = last 2 digits of current year (e.g. `26`)
- `M` = current month, no leading zero (e.g. `3` for March)
- `N`:
  - Parse `LIVE_VERSION` — if it matches `YY.M.*` (same year and month), take its third part and add 1
  - Otherwise (different month/year), start at `0`
- New version = `"YY.M.N"`

### Step 3: Show plan to user and ask for confirmation

Display a summary like:
```
Ready to push build:
  Version:       26.3.1  (bumped from 26.3.0)   ← or "unchanged"
  Build number:  3031    (was 3030)
  Branch:        <current git branch>
  Scheme:        Zaps

Proceed? (yes / no / edit version)
```

Wait for user confirmation before continuing. If the user says "edit version", let them provide a custom version string.

### Step 4: Update project.pbxproj

Use the Edit tool to update `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` in:
`/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Turnip.xcodeproj/project.pbxproj`

Both values appear multiple times — update ALL occurrences using `replace_all`.

### Step 5: Commit the version bump

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
git add zaps-app/Turnip.xcodeproj/project.pbxproj
git commit -m "$(cat <<EOF
Bump build number to <NEW_BUILD_NUMBER>

Preparing TestFlight build <NEW_BUILD_NUMBER> (v<VERSION>) from branch <BRANCH_NAME>.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Step 5.5: Push branch to remote

Push the branch including the version bump commit before archiving:
```bash
git push -u origin HEAD
```

### Step 6: Archive

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
xcodebuild archive \
  -project zaps-app/Turnip.xcodeproj \
  -scheme Zaps \
  -configuration Release \
  -archivePath /tmp/Zaps-<NEW_BUILD_NUMBER>.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8 \
  -authenticationKeyID WJQ6D76K8R \
  -authenticationKeyIssuerID 1fa9f26b-7b13-459a-9225-1ca8d9c51fca \
  CODE_SIGN_STYLE=Automatic \
  | /Users/vishalsingh/.gem/ruby/2.6.0/bin/xcpretty || cat
```

This step takes several minutes. Keep the user informed that archiving is in progress.

**Verify:** After archiving, confirm the `.xcarchive` exists at `/tmp/Zaps-<NEW_BUILD_NUMBER>.xcarchive`. If it does not exist, the archive failed — stop here and report the error to the user. Do NOT continue to export or upload.

### Step 7: Export and Upload to App Store Connect

The export options use `destination: upload`, which means `xcodebuild -exportArchive` uploads directly to App Store Connect. No local IPA is produced — there is no separate upload step.

**IMPORTANT:** Do NOT pipe this command through xcpretty. The raw output is short and must be read to verify success or diagnose errors.

```bash
cat > /tmp/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath /tmp/Zaps-<NEW_BUILD_NUMBER>.xcarchive \
  -exportPath /tmp/Zaps-<NEW_BUILD_NUMBER>-export \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8 \
  -authenticationKeyID WJQ6D76K8R \
  -authenticationKeyIssuerID 1fa9f26b-7b13-459a-9225-1ca8d9c51fca \
  2>&1
```

**Verify:** Check the raw output carefully:
- If output contains `** EXPORT FAILED **` or `error:` lines → the upload failed. Stop here and report to the user. Common causes:
  - "Failed to Use Accounts" → API key authentication issue. Verify the key file exists at `~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8`.
  - "bundle version must be higher" → build number already exists on App Store Connect.
- `warning:` lines about missing dSYMs for third-party frameworks (AppsFlyer, Firebase, etc.) are harmless — ignore them.
- If output contains `Export Succeeded` → the build was uploaded successfully.

Do NOT offer to send a Slack notification unless this step succeeded.

### Step 7.5: Upload dSYMs to Crashlytics

**Only run this step if Step 7 succeeded.**

The `xcodebuild -exportArchive` pipeline does not trigger the Crashlytics run script, so dSYMs must be uploaded explicitly. Upload them one at a time (bulk upload can crash on certain archives).

```bash
UPLOAD_SYMBOLS=$(find ~/Library/Developer/Xcode/DerivedData/Turnip-*/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols -maxdepth 0 2>/dev/null | head -1)
GSIP="/Users/vishalsingh/Documents/Turnip.gg/turnip-ios/zaps-app/Zaps/Firebase/Prod/GoogleService-Info.plist"
DSYMS_DIR="/tmp/Zaps-<NEW_BUILD_NUMBER>.xcarchive/dSYMs"

failed=()
for dsym in "$DSYMS_DIR"/*.dSYM; do
  name=$(basename "$dsym")
  result=$("$UPLOAD_SYMBOLS" -gsp "$GSIP" -p ios "$dsym" 2>&1)
  if echo "$result" | grep -q "Successfully uploaded"; then
    echo "✓ $name"
  else
    echo "✗ $name"
    failed+=("$name")
  fi
done

if [ ${#failed[@]} -eq 0 ]; then
  echo "All dSYMs uploaded to Crashlytics."
else
  echo "Failed: ${failed[*]}"
fi
```

If `UPLOAD_SYMBOLS` is empty (DerivedData was cleaned), report that dSYMs could not be uploaded but continue — it's non-blocking. The archive at `/tmp/Zaps-<NEW_BUILD_NUMBER>.xcarchive` will be available for manual upload later.

### Step 8: Compose Slack notification

**Only reach this step if Steps 6 and 7 both succeeded with verified outputs.**

Immediately proceed to compose the Slack message — do NOT ask whether to notify first. After composing, show the draft to the user and ask if they'd like to make any edits or send it as-is.

### Step 9: Get relevant commits for message composition

The Slack message should be composed from **the user's (vishal) commits only** on the current branch. Use the bump-to-bump range to find commits since the last build that was shared on #testing.

**Step 10a: Find the last build that was posted to #testing.** Fetch recent messages from #testing posted by Vishal-CLI (bot user `U0AJYVC8P8X`) and find the most recent build number mentioned.

Load the Slack bot token once for all subsequent calls (stored out-of-repo at `~/.claude/secrets/slack-bot-token`, chmod 600). If the file is missing, halt and ask the user to run `/chanakya sync-slack --configure-token`.

```bash
SLACK_BOT_TOKEN=$(cat ~/.claude/secrets/slack-bot-token)
curl -s "https://slack.com/api/conversations.history?channel=C016BNCGDM2&limit=10" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"
```

Look for the last message from Vishal-CLI that contains "build NNNN is available on TestFlight" and extract that build number as `LAST_SHARED_BUILD`.

**Step 10b: Get vishal's commits since that build:**

```bash
LAST_SHARED_BUMP=$(git log --oneline --all --grep="Bump build number to <LAST_SHARED_BUILD>" | head -1 | cut -d' ' -f1)
git log --no-merges --author="vishal" --format="%h | %s%n%b%n---" ${LAST_SHARED_BUMP}..HEAD | grep -viE "Bump (build|version)"
```

Read the full commit messages (subject + body) to understand the user-facing impact.

### Step 9.5: Compose the message

Compose the message from vishal's commits **first**, before scanning for reporters:
- First line: `<!here> [iOS] build {NEW_BUILD_NUMBER} is available on TestFlight` — **always** use `<!here>` when posting a new message (not a thread reply). Slack does not support `<!here>` in thread replies, so never use it there.
- Blank line after the first line.
- Bullet points: plain, non-technical language for product owners (focus on user-facing impact, not implementation details). Derive each bullet from vishal's commit subjects and bodies.

### Step 9.6: Scan recent Vishal-CLI build threads for bug reporters

**After composing the message**, scan the last 3–4 build/TestFlight message threads posted by Vishal-CLI (bot user `U0AJYVC8P8X`) in #testing. Only look at threads started by Vishal-CLI that are build notifications.

```bash
# Get recent #testing messages, filter for Vishal-CLI build messages
curl -s "https://slack.com/api/conversations.history?channel=C016BNCGDM2&limit=15" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"

# For each Vishal-CLI build message with replies, fetch the thread
curl -s "https://slack.com/api/conversations.replies?channel=C016BNCGDM2&ts=MESSAGE_TS" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"

# Resolve user display names (for showing to user only)
curl -s "https://slack.com/api/users.info?user=USER_ID" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"
```

For each composed bullet point, check if any thread reply in those 3–4 build threads reported the same bug or requested the same feature. If there's a match, append `cc: <@USER_ID>` to that bullet. **Do not change the language of the bullet points** — only add the tag.

When showing the draft to the user, display the person's real name in parentheses next to the tag — e.g. `cc: <@U12345> (John)`. The parenthesised name is for the user's reference only and must NOT be included in the final Slack message.

**Always show the draft to the user and ask: "Want me to send this, or would you like to make any edits?"** Wait for explicit user approval before sending.

### Step 10: Send to Slack

```bash
curl -s -X POST https://slack.com/api/chat.postMessage \
  --data-urlencode "channel=C016BNCGDM2" \
  --data-urlencode "text=MESSAGE_HERE" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN"
```

Replace `MESSAGE_HERE` with the final approved message text. Confirm to the user that the message was sent successfully.

**Thread replies:** When posting a follow-up to an existing build thread (e.g. updating status), use the `thread_ts` parameter set to the original message's `ts`. Do NOT use `<!here>` in thread replies — Slack ignores it.
