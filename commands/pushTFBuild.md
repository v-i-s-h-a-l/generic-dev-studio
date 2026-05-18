---
description: Bump build number/version, archive, and push to TestFlight via App Store Connect
allowed-tools: [Bash, Read, Edit, Grep]
---

# Push iOS Build to TestFlight

Hybrid wrapper around `scripts/studio-tf-push.sh` (studio repo at `~/Documents/v-i-s-h-a-l/github/generic-dev-studio`). The studio script owns all mechanical work — bump, archive, export+upload, dSYMs — and emits the four pre-Slack events. This wrapper drives Slack composition + the human-approval gate, then emits `slack_drafted` / `slack_sent` via the same script's `emit` subcommand so all six events share one release-tag.

Authoritative procedure: `_shared/contracts/release-tf-push.md`. Project knobs (paths, scheme, ASC ids, Crashlytics plist): `_shared/primitives/turnip-project-config.md`. Slack body rules: `_shared/contracts/build-message-format.md`.

Authentication is App Store Connect API key based. The push driver uses `STUDIO_TF_ASC_KEY_PATH` when configured, otherwise derives `~/.dev-studio/<project>/secrets/appstoreconnect/AuthKey_<key-id>.p8` from `STUDIO_TF_ASC_KEY_ID`; `STUDIO_TF_ASC_ISSUER_ID` is required in both cases. Session auth, fastlane discovery, and third-party credential schemes are not automatic fallbacks for upload.

## Arguments

- `--scheme <name>` *(optional, default `Zaps`)* — pass-through to `studio-tf-push.sh push --scheme`. Use `Zaps-Internal` for the HUD-enabled internal-tester build.

## Step 1: Pre-mint the release tag (idempotency key)

```bash
export STUDIO_RELEASE_PROJECT="${STUDIO_RELEASE_PROJECT:-<project>}"
export STUDIO_RELEASE_TAG="release-pending-$(date -u +%Y%m%d-%H%M%S)"
```

The `push` subcommand reuses this if set; later `emit` calls reuse it too so all six events share one task field.

## Step 2: Run the studio push script (Steps 1–6 of the contract)

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
CTX=$(STUDIO_TF_PUSH_LIVE=1 ./scripts/studio-tf-push.sh push ${SCHEME:+--scheme "$SCHEME"} | tail -1)
RELEASE_TAG=$(echo "$CTX" | jq -r .release_tag)
NEW_BUILD_NUMBER=$(echo "$CTX" | jq -r .build)
VERSION=$(echo "$CTX" | jq -r .version)
BRANCH=$(echo "$CTX" | jq -r .branch)
PREV_BUILD=$(echo "$CTX" | jq -r .prev_build)
```

The script emits `release_started`, `archive_completed`, `upload_completed`, `dsym_uploaded` along the way. If it exits non-zero it has already emitted `release_failed` with the stage that broke — surface stderr to the user and stop. Do NOT continue to Slack steps.

The script reads release config from `~/.dev-studio/${STUDIO_RELEASE_PROJECT}/config/release.env` and secrets from `~/.dev-studio/${STUDIO_RELEASE_PROJECT}/secrets/`. It preflights non-interactive GitHub push auth, ASC key/JWT prerequisites, Slack token readability, and the app-scoped live-version lookup before it mutates the pbxproj. If it reports a missing `STUDIO_TF_ASC_*` value or unreadable `.p8` key, fix the ASC API-key configuration and rerun; do not switch to session-based upload credentials. If it prints `WARNING: Could not determine live App Store version`, stop and resolve ASC/API access first; do not infer that there is no version conflict. For an intentionally upload-only run with Slack deferred, set `STUDIO_TF_SLACK_DEFERRED=1`.

## Step 3: Compose the Slack message

Compose from the user's commits since the last shared TF build, per `_shared/contracts/build-message-format.md`.

Find the last shared build:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
LAST_SHARED_BUILD=$(./scripts/slack-fetch.sh history --channel C016BNCGDM2 --limit 10 \
  | jq -r 'select(.user=="U0AJYVC8P8X") | .text' \
  | grep -oE 'build [0-9]+ is available on TestFlight' \
  | head -1 | grep -oE '[0-9]+')
```

Then:

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
LAST_SHARED_BUMP=$(git log --oneline --all --grep="Bump build number to $LAST_SHARED_BUILD" | head -1 | cut -d' ' -f1)
git log --no-merges --author="vishal" --format="%h | %s%n%b%n---" ${LAST_SHARED_BUMP}..HEAD | grep -viE "Bump (build|version)"
```

Read full commit messages (subject + body). Compose per `build-message-format.md`:

- Three sections: `*New*` / `*Fixed*` / `*Crash fixes*` — skip empty sections.
- Feature rollup under *New*; bare crash-link bullets under *Crash fixes*.
- Name regressions explicitly under *Fixed* as `• regression bug fix: <thing>`.
- Rollover line `• includes changes from <PREV_BUILD_NUMBER>` when stacking on an unreleased TF (compare `LAST_SHARED_BUILD` vs `PREV_BUILD` from the context — if they differ, prepend a rollover bullet).
- Headline: `<!here> [iOS] build <NEW_BUILD_NUMBER> is available on TestFlight`. Drop `<!here>` for buddy/internal/silent builds.

## Step 4: Scan recent threads for cc-tag attribution

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
./scripts/slack-fetch.sh history --channel C016BNCGDM2 --limit 15
# For each Vishal-CLI build message with replies:
./scripts/slack-fetch.sh replies --channel C016BNCGDM2 --ts <MESSAGE_TS>
# Resolve display names (review only):
./scripts/slack-fetch.sh user --user <USER_ID>
```

Append `cc: <@USER_ID>` inline on bullets that match a thread reply. Show parenthesised display name to the user only — strip before sending.

## Step 5: Emit `slack_drafted`

```bash
BULLETS=$(echo "$BODY" | grep -c '^•')
CCS=$(echo "$BODY" | grep -oE 'cc: <@[A-Z0-9]+>' | wc -l | tr -d ' ')
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
./scripts/studio-tf-push.sh emit slack_drafted --release-tag "$RELEASE_TAG" \
  --data "$(jq -nc --argjson b "$NEW_BUILD_NUMBER" --argjson bc "$BULLETS" --argjson cc "$CCS" \
              '{build:$b, channel:"#testing", bullet_count:$bc, cc_count:$cc}')"
```

## Step 6: Human-approval gate

Show the draft to the user verbatim — include parenthesised display names next to each `<@USER_ID>` for review readability. Ask: **"Send this, or edit first?"**

If the user edits, update the draft and re-emit `slack_drafted` with the same `--release-tag` (the ledger keys on it; consumers see one drafted span with the latest content). Wait for explicit approval before Step 7.

## Step 7: Send to Slack

Strip parenthesised display names from the body, then:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
RESP=$(./scripts/slack-post.sh --channel C016BNCGDM2 --text "$FINAL_BODY")
PARENT_TS=$(echo "$RESP" | jq -r .ts)
[ -n "$PARENT_TS" ] && [ "$PARENT_TS" != "null" ] || { echo "slack-post returned no ts"; exit 1; }

CHARS=$(printf '%s' "$FINAL_BODY" | wc -c | tr -d ' ')
./scripts/studio-tf-push.sh emit slack_sent --release-tag "$RELEASE_TAG" \
  --data "$(jq -nc --argjson b "$NEW_BUILD_NUMBER" --arg ts "$PARENT_TS" --argjson c "$CHARS" \
              '{build:$b, channel:"#testing", parent_ts:$ts, message_chars:$c}')"
```

If the post fails:

```bash
./scripts/studio-tf-push.sh emit release_failed --release-tag "$RELEASE_TAG" \
  --data "$(jq -nc --arg r "$REASON" '{stage:"slack_send", reason:$r}')"
```

The build is already on TestFlight; the failure is in notification, not delivery. Do not re-run upload.

## Rollback

To revert this wrapper to the legacy prose-driven runbook: `git revert` the commit that introduced this version in the studio repo's `commands/pushTFBuild.md`. The legacy version drove every step inline without `studio-tf-push.sh`.
