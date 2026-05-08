#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPHOME=$(mktemp -d -t release-handoff-docs.XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_line() {
  local pattern="$1" file="$2" label="$3"
  grep -Fq "$pattern" "$file" || fail "$label missing from $file"
}

require_line "The split between slash-command wrappers and \`scripts/studio-tf-push.sh\` is" \
  "$ROOT/_shared/contracts/release-tf-push.md" \
  "intentional wrapper/backend split"
require_line "| TestFlight push (\`/dev-studio release-manager tf-push\` or \`/pushTFBuild\`) |" \
  "$ROOT/_shared/contracts/release-tf-push.md" \
  "TestFlight ownership row"
require_line "| App Store submission (\`/fullSendToAppStore\`) |" \
  "$ROOT/_shared/contracts/release-tf-push.md" \
  "App Store ownership row"
require_line "tagging belongs to the TestFlight drafting paths" \
  "$ROOT/_shared/contracts/release-tf-push.md" \
  "reporter tagging owner"

require_line "Slack draft composition, recent-thread reporter \`cc:\` tagging" \
  "$ROOT/commands/pushTFBuild.md" \
  "TestFlight Slack draft owner"
require_line "Notification-only recovery for an already uploaded build" \
  "$ROOT/commands/pushTFBuild.md" \
  "notification-only recovery owner"
require_line "Configured App Store Slack parent/thread post and PR link reply" \
  "$ROOT/commands/fullSendToAppStore.md" \
  "App Store Slack post owner"
require_line "GitHub release publication, Slack link update, and PR promotion after \`READY_FOR_SALE\`" \
  "$ROOT/commands/fullSendToAppStore.md" \
  "App Store watcher owner"

HELP=$(HOME="$TMPHOME" STUDIO_RELEASE_PROJECT=handoff-fixture "$ROOT/scripts/studio-tf-push.sh" --help)
printf '%s\n' "$HELP" | grep -Fq "Slack draft, reporter tagging, approval" \
  || fail "script help does not say Slack drafting stays in wrappers"
printf '%s\n' "$HELP" | grep -Fq "Configured Slack posting, PR handoff, and release" \
  || fail "script help does not say appstore owns configured Slack/PR handoff"

require_line "release-manager tf-push\` -> TestFlight operator path" \
  "$ROOT/commands/dev-studio.md" \
  "release-manager tf-push help"
require_line "App Store submission remains \`/fullSendToAppStore\`" \
  "$ROOT/commands/dev-studio.md" \
  "App Store operator path help"
require_line "Live handoff ownership is explicit" \
  "$ROOT/core/v2/roles/release-manager.yaml" \
  "release-manager verification floor"

printf 'PASS: release handoff ownership docs\n'
