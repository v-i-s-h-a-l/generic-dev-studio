#!/usr/bin/env bash
# release-manager-configure.sh — project release notification setup.
#
# Usage:
#   scripts/release-manager-configure.sh --project <slug> --quick \
#     --tf-slack-channel C... --appstore-slack-channel C...
#
# Writes reusable release-manager notification settings to the project-scoped
# release config. Secrets stay in the existing project secrets directory; this
# script never asks for token text.

set -u
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-release-config.sh
. "$SCRIPT_DIR/lib-release-config.sh"

PROJECT=""
QUICK=0
DRY_RUN=0
SEND_TEST=0
ENABLE_TF=1
ENABLE_APPSTORE=1
TF_CHANNEL=""
TF_CHANNEL_NAME="#testing"
APPSTORE_CHANNEL=""
APPSTORE_CHANNEL_NAME="#releases"
DESCRIPTIVE_INTAKE=""

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project requires value}"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --send-test-message) SEND_TEST=1; shift ;;
    --tf-slack-channel|--testflight-slack-channel) TF_CHANNEL="${2:?--tf-slack-channel requires value}"; shift 2 ;;
    --tf-slack-channel-name|--testflight-slack-channel-name) TF_CHANNEL_NAME="${2:?--tf-slack-channel-name requires value}"; shift 2 ;;
    --appstore-slack-channel|--releases-slack-channel) APPSTORE_CHANNEL="${2:?--appstore-slack-channel requires value}"; shift 2 ;;
    --appstore-slack-channel-name|--releases-slack-channel-name) APPSTORE_CHANNEL_NAME="${2:?--appstore-slack-channel-name requires value}"; shift 2 ;;
    --disable-testflight) ENABLE_TF=0; shift ;;
    --disable-appstore) ENABLE_APPSTORE=0; shift ;;
    --describe) DESCRIPTIVE_INTAKE="${2:?--describe requires value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'release-manager-configure: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -n "$PROJECT" ]; then
  export STUDIO_RELEASE_PROJECT="$PROJECT"
fi
load_release_config || {
  printf 'release-manager-configure: could not resolve project release config\n' >&2
  exit 2
}

TF_CHANNEL="${TF_CHANNEL:-${STUDIO_TF_SLACK_CHANNEL:-}}"
APPSTORE_CHANNEL="${APPSTORE_CHANNEL:-${STUDIO_RELEASES_SLACK_CHANNEL:-}}"
TF_CHANNEL_NAME="${TF_CHANNEL_NAME:-${STUDIO_TF_SLACK_CHANNEL_NAME:-#testing}}"
APPSTORE_CHANNEL_NAME="${APPSTORE_CHANNEL_NAME:-${STUDIO_RELEASES_SLACK_CHANNEL_NAME:-#releases}}"

if [ "$QUICK" = "0" ] && [ -z "$DESCRIPTIVE_INTAKE" ]; then
  printf 'release-manager-configure: no setup mode supplied; use --quick or --describe\n' >&2
  exit 2
fi
if [ "$ENABLE_TF" = "1" ] && [ -z "$TF_CHANNEL" ] && [ "$ENABLE_APPSTORE" = "1" ] && [ -z "$APPSTORE_CHANNEL" ]; then
  printf 'release-manager-configure: provide --tf-slack-channel or --appstore-slack-channel\n' >&2
  exit 2
fi

quote_env() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

upsert_env_line() {
  local file="$1" key="$2" value="$3" tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if [ -f "$file" ]; then
    awk -v key="$key" -v val="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" key "=" { print key "=" val; done = 1; next }
      { print }
      END { if (!done) print key "=" val }
    ' "$file" > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" "$file"
}

write_setting() {
  local key="$1" value="$2" quoted
  quoted=$(quote_env "$value")
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s=%s\n' "$key" "$quoted"
  else
    upsert_env_line "$RELEASE_CONFIG_FILE" "$key" "$quoted"
  fi
}

validate_channel_shape() {
  local name="$1" channel="$2"
  [ -z "$channel" ] && return 0
  case "$channel" in
    C*|G*|D*) return 0 ;;
    *) printf 'release-manager-configure: warning: %s channel id usually starts with C/G/D: %s\n' "$name" "$channel" >&2 ;;
  esac
}

[ "$DRY_RUN" = "1" ] || mkdir -p "$RELEASE_CONFIG_DIR"

validate_channel_shape testflight "$TF_CHANNEL"
validate_channel_shape appstore "$APPSTORE_CHANNEL"

write_setting STUDIO_RELEASE_NOTIFICATIONS_CONFIGURED 1
write_setting STUDIO_RELEASE_NOTIFICATION_PROFILE quick
[ -n "$DESCRIPTIVE_INTAKE" ] && write_setting STUDIO_RELEASE_NOTIFICATION_INTAKE "$DESCRIPTIVE_INTAKE"

if [ "$ENABLE_TF" = "1" ] && [ -n "$TF_CHANNEL" ]; then
  write_setting STUDIO_TF_SLACK_CHANNEL "$TF_CHANNEL"
  write_setting STUDIO_TF_SLACK_CHANNEL_NAME "$TF_CHANNEL_NAME"
  write_setting STUDIO_TF_SLACK_NOTIFY_HERE 0
  write_setting STUDIO_TF_SLACK_PARENT_MODE brief
  write_setting STUDIO_TF_SLACK_DETAILS_MODE thread
  write_setting STUDIO_TF_SLACK_GROUPING module
  write_setting STUDIO_TF_SLACK_TECHNICAL_FOOTER 1
fi

if [ "$ENABLE_APPSTORE" = "1" ] && [ -n "$APPSTORE_CHANNEL" ]; then
  write_setting STUDIO_RELEASES_SLACK_CHANNEL "$APPSTORE_CHANNEL"
  write_setting STUDIO_RELEASES_SLACK_CHANNEL_NAME "$APPSTORE_CHANNEL_NAME"
  write_setting STUDIO_RELEASES_SLACK_APPSTORE_PARENT 1
  write_setting STUDIO_RELEASES_SLACK_WHATSNEW_REPLY 1
  write_setting STUDIO_RELEASES_SLACK_GITHUB_REPLY 1
  write_setting STUDIO_RELEASES_SLACK_WATCHER_REPLIES 1
fi

if [ "$DRY_RUN" = "1" ]; then
  printf 'release-manager-configure: dry-run only; no file written\n' >&2
else
  chmod 600 "$RELEASE_CONFIG_FILE" 2>/dev/null || true
  printf 'release-manager-configure: wrote %s\n' "$RELEASE_CONFIG_FILE"
fi

if [ "$SEND_TEST" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  if [ -n "$TF_CHANNEL" ]; then
    STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
      --channel "$TF_CHANNEL" --text "Release notification test for ${RELEASE_PROJECT}" >/dev/null
  elif [ -n "$APPSTORE_CHANNEL" ]; then
    STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
      --channel "$APPSTORE_CHANNEL" --text "Release notification test for ${RELEASE_PROJECT}" >/dev/null
  else
    printf 'release-manager-configure: no Slack channel configured for test message\n' >&2
  fi
elif [ -n "$TF_CHANNEL" ]; then
  STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
    --channel "$TF_CHANNEL" --text "Release notification dry run for ${RELEASE_PROJECT}" --dry-run >/dev/null
fi
