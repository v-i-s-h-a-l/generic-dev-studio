---
description: Post an iOS TestFlight build notification to the #testing Slack channel
allowed-tools: [Bash, Read, Grep]
---

# Post TestFlight Build Notification to Slack

Notification-only path — for when a build was already pushed (perhaps manually or out-of-band) and only the Slack message is missing. Uses the studio's `slack-fetch.sh` / `slack-post.sh` primitives. No archive, no upload, no version bump.

If you want the full push path (bump → archive → upload → Slack), use `/pushTFBuild` instead.

Authoritative composition rules: `_shared/contracts/build-message-format.md` in the studio repo.

## Step 1: Get the latest build number from TestFlight

```bash
TOKEN=$(python3 -c "
import jwt, time
key = open('$(echo ~/.appstoreconnect/private_keys/AuthKey_WJQ6D76K8R.p8)').read()
payload = {'iss': '1fa9f26b-7b13-459a-9225-1ca8d9c51fca', 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': 'WJQ6D76K8R'}))
")
BUILD_NUMBER=$(curl -sg "https://api.appstoreconnect.apple.com/v1/builds?sort=-uploadedDate&limit=1&fields[builds]=version" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.data[0].attributes.version')
```

## Step 2: Get commits for this build

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
CURRENT_BUMP=$(git log --oneline --all --grep="Bump build number to ${BUILD_NUMBER}" | head -1 | cut -d' ' -f1)
PREV_BUMP=$(git log --oneline --all --grep="Bump build number" | sed -n '2p' | cut -d' ' -f1)
if [ -n "$PREV_BUMP" ] && [ -n "$CURRENT_BUMP" ]; then
  git log ${PREV_BUMP}..${CURRENT_BUMP} --oneline --no-merges | grep -viE "Bump (build|version)"
else
  git log main..HEAD --oneline --no-merges | grep -viE "Bump (build|version)"
fi
```

## Step 3: Scan recent #testing threads for cc-tag attribution

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
./scripts/slack-fetch.sh history --channel C016BNCGDM2 --limit 3
# For messages with replies:
./scripts/slack-fetch.sh replies --channel C016BNCGDM2 --ts <MESSAGE_TS>
# Resolve display names (review only):
./scripts/slack-fetch.sh user --user <USER_ID>
```

Append `<@USER_ID>` to bullets that match a thread reply.

## Step 4: Compose, show to user, wait for approval

Compose per `build-message-format.md`:

- First line: `<!here> [iOS] build ${BUILD_NUMBER} is available on TestFlight`
- Bullet points in plain, non-technical language — translate technical commits into user-facing impact.

Show the draft with parenthesised display names next to each `<@USER_ID>` (review only). Ask: **"Does this look good, or would you like to edit anything before sending?"**

Wait for approval. If edits, re-show.

## Step 5: Send

Strip parenthesised names, then:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
./scripts/slack-post.sh --channel C016BNCGDM2 --text "$FINAL_BODY"
```

Confirm to the user that the message was sent.

## Rollback

To revert this wrapper to the legacy inline-curl version: `git revert` the commit that introduced this file in the studio repo's `commands/postSlackTesting.md`.
