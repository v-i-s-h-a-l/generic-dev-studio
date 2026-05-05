---
description: Bump build number/version, archive, and push to TestFlight via App Store Connect
allowed-tools: [Bash, Read, Edit, Grep]
---

# Push iOS Build to TestFlight

Hybrid wrapper around `scripts/studio-tf-push.sh` (studio repo at `~/Documents/v-i-s-h-a-l/github/generic-dev-studio`). The studio script owns all mechanical work — bump, archive, export+upload, dSYMs — and emits the four pre-Slack events. This wrapper drives Slack composition + the human-approval gate, then emits `slack_drafted` / `slack_sent` via the same script's `emit` subcommand so all six events share one release-tag.

Authoritative procedure: `_shared/contracts/release-tf-push.md`. Project knobs
(paths, scheme, ASC ids, Crashlytics plist) live in the project release config.
Slack body rules: `_shared/contracts/build-message-format.md`. Configure
channel and notification shape with `/dev-studio release-manager configure`.

## Arguments

- `--scheme <name>` *(optional, default `Zaps`)* — pass-through to `studio-tf-push.sh push --scheme`. Use `Zaps-Internal` for the HUD-enabled internal-tester build.
- `--background` *(optional)* — start the mechanical push in the background and keep this session available for Slack drafting while archive/upload runs.

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
TF_TAG=$(echo "$CTX" | jq -r .tf_tag)
BRANCH=$(echo "$CTX" | jq -r .branch)
PREV_BUILD=$(echo "$CTX" | jq -r .prev_build)
. ./scripts/lib-release-config.sh
load_release_config
```

The script creates and pushes `tf-<version>-<build>` at the bump-build commit before archiving, then emits `release_started`, `archive_completed`, `upload_completed`, `dsym_uploaded` along the way. If it exits non-zero it has already emitted `release_failed` with the stage that broke — surface stderr to the user and stop. Do NOT continue to Slack steps.

The script reads release config from `~/.dev-studio/${STUDIO_RELEASE_PROJECT}/config/release.env` and secrets from `~/.dev-studio/${STUDIO_RELEASE_PROJECT}/secrets/`. It preflights non-interactive GitHub push auth, ASC key/JWT prerequisites, Slack token readability, and the app-scoped live-version lookup before it mutates the pbxproj. If it prints `WARNING: Could not determine live App Store version`, stop and resolve ASC/API access first; do not infer that there is no version conflict. For an intentionally upload-only run with Slack deferred, set `STUDIO_TF_SLACK_DEFERRED=1`.

Required Slack config for notification:

```bash
STUDIO_TF_SLACK_CHANNEL=<Slack channel id>
STUDIO_TF_SLACK_CHANNEL_NAME="#testing"          # display only
STUDIO_TF_SLACK_NOTIFY_HERE=0                    # opt-in only
STUDIO_TF_SLACK_PARENT_MODE=brief
STUDIO_TF_SLACK_DETAILS_MODE=thread
STUDIO_TF_SLACK_GROUPING=module
STUDIO_TF_SLACK_TECHNICAL_FOOTER=1
```

### Background option

When `--background` is present, start the push and immediately return to the conversation:

```bash
BG=$(STUDIO_TF_PUSH_LIVE=1 ./scripts/studio-tf-push.sh push --background ${SCHEME:+--scheme "$SCHEME"})
RELEASE_TAG=$(echo "$BG" | jq -r .release_tag)
STATUS_PATH=$(echo "$BG" | jq -r .status_path)
PREPARED_CONTEXT_PATH=$(echo "$BG" | jq -r .prepared_context_path)
CONTEXT_PATH=$(echo "$BG" | jq -r .context_path)
LOG_PATH=$(echo "$BG" | jq -r .log_path)
```

Poll `PREPARED_CONTEXT_PATH` for up to 90 seconds. It is written after ASC state, version decision, and build-number commit, before the long archive/upload phase:

```bash
for _ in $(seq 1 18); do
  [ -s "$PREPARED_CONTEXT_PATH" ] && break
  sleep 5
done
[ -s "$PREPARED_CONTEXT_PATH" ] || { echo "release context not ready; inspect $LOG_PATH"; exit 1; }
CTX=$(cat "$PREPARED_CONTEXT_PATH")
NEW_BUILD_NUMBER=$(echo "$CTX" | jq -r .build)
VERSION=$(echo "$CTX" | jq -r .version)
TF_TAG=$(echo "$CTX" | jq -r .tf_tag)
BRANCH=$(echo "$CTX" | jq -r .branch)
PREV_BUILD=$(echo "$CTX" | jq -r .prev_build)
```

Proceed to Slack drafting while the background run continues. Before sending Slack, require `STATUS_PATH` to show `state=="succeeded"` and load final `CTX` from `CONTEXT_PATH`; if it shows `failed`, surface `LOG_PATH` and stop.

## Step 3: Compose the Slack message

Compose from the user's commits since the last shared TF build, per `_shared/contracts/build-message-format.md`.

Find the last shared build and prefer its TF tag as the lower bound:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
TF_CHANNEL="${STUDIO_TF_SLACK_CHANNEL:?run /dev-studio release-manager configure first}"
LAST_SHARED_BUILD=$(./scripts/slack-fetch.sh history --channel "$TF_CHANNEL" --limit 10 \
  | jq -r 'select(.user=="U0AJYVC8P8X") | .text' \
  | grep -oE 'build [0-9]+ is available on TestFlight' \
  | head -1 | grep -oE '[0-9]+')
```

Then:

```bash
cd /Users/vishalsingh/Documents/Turnip.gg/turnip-ios
LAST_SHARED_TF_TAG=$(git tag --merged HEAD --sort=-creatordate \
  | grep -E "^tf-[0-9]+[.][0-9]+[.][0-9]+-${LAST_SHARED_BUILD}(-WITHDRAWN)?$" \
  | head -1)
if [ -n "$LAST_SHARED_TF_TAG" ]; then
  LOWER_BOUND="$LAST_SHARED_TF_TAG"
else
  LOWER_BOUND=$(git log --oneline --all --grep="Bump build number to $LAST_SHARED_BUILD" | head -1 | cut -d' ' -f1)
fi
git log --no-merges --author="vishal" --format="%h | %s%n%b%n---" ${LOWER_BOUND}..HEAD | grep -viE "Bump (build|version)"
```

Read full commit messages (subject + body). Compose per `build-message-format.md`:

- Parent: brief tester-facing summary since the last posted TF build, then `Details in thread.`
- Thread detail: grouped tester checklist. Prefer module/product-area groups when useful; otherwise use `*New*` / `*Fixed*` / `*Crash fixes*`.
- Feature rollup under *New*; bare crash-link bullets under *Crash fixes*.
- Name regressions explicitly under *Fixed* as `• regression bug fix: <thing>`.
- Rollover line `• includes changes from <PREV_BUILD_NUMBER>` when stacking on an unreleased TF (compare `LAST_SHARED_BUILD` vs `PREV_BUILD` from the context — if they differ, prepend a rollover bullet).
- Headline: `[iOS] build <NEW_BUILD_NUMBER> is available on TestFlight`. Prefix `<!here>` only when `STUDIO_TF_SLACK_NOTIFY_HERE=1`.
- Technical notes go at the end of the thread under `*Technical notes*`, only when they materially affect testing or product expectations.

## Step 4: Scan recent threads for cc-tag attribution

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
./scripts/slack-fetch.sh history --channel "$TF_CHANNEL" --limit 15
# For each Vishal-CLI build message with replies:
./scripts/slack-fetch.sh replies --channel "$TF_CHANNEL" --ts <MESSAGE_TS>
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
              --arg ch "${STUDIO_TF_SLACK_CHANNEL_NAME:-$TF_CHANNEL}" \
              '{build:$b, channel:$ch, bullet_count:$bc, cc_count:$cc}')"
```

## Step 6: Human-approval gate

Show the draft to the user verbatim — include parenthesised display names next to each `<@USER_ID>` for review readability. Ask: **"Send this, or edit first?"**

If the user edits, update the draft and re-emit `slack_drafted` with the same `--release-tag` (the ledger keys on it; consumers see one drafted span with the latest content). Wait for explicit approval before Step 7.

## Step 7: Send to Slack

Strip parenthesised display names from the body, then:

```bash
cd ~/Documents/v-i-s-h-a-l/github/generic-dev-studio
RESP=$(./scripts/slack-post.sh --channel "$TF_CHANNEL" --text "$FINAL_PARENT_BODY")
PARENT_TS=$(echo "$RESP" | jq -r .ts)
[ -n "$PARENT_TS" ] && [ "$PARENT_TS" != "null" ] || { echo "slack-post returned no ts"; exit 1; }
./scripts/slack-post.sh --channel "$TF_CHANNEL" --thread-ts "$PARENT_TS" --text "$FINAL_THREAD_BODY" >/dev/null

CHARS=$(printf '%s%s' "$FINAL_PARENT_BODY" "$FINAL_THREAD_BODY" | wc -c | tr -d ' ')
./scripts/studio-tf-push.sh emit slack_sent --release-tag "$RELEASE_TAG" \
  --data "$(jq -nc --argjson b "$NEW_BUILD_NUMBER" --arg ts "$PARENT_TS" --argjson c "$CHARS" \
              --arg ch "${STUDIO_TF_SLACK_CHANNEL_NAME:-$TF_CHANNEL}" \
              '{build:$b, channel:$ch, parent_ts:$ts, message_chars:$c}')"
```

If the post fails:

```bash
./scripts/studio-tf-push.sh emit release_failed --release-tag "$RELEASE_TAG" \
  --data "$(jq -nc --arg r "$REASON" '{stage:"slack_send", reason:$r}')"
```

The build is already on TestFlight; the failure is in notification, not delivery. Do not re-run upload.

## Rollback

To revert this wrapper to the legacy prose-driven runbook: `git revert` the commit that introduced this version in the studio repo's `commands/pushTFBuild.md`. The legacy version drove every step inline without `studio-tf-push.sh`.
