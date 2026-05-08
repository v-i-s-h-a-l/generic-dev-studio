#!/usr/bin/env bash
# studio-tf-slack.sh — script-backed TestFlight Slack draft/send bridge.
#
# This owns the deterministic Step 7-9 rail from
# _shared/contracts/release-tf-push.md. Assistants may edit the generated
# parent/thread files before approval, but they should not freehand the
# release events, linter gate, or Slack posting sequence.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-release-config.sh
. "$SCRIPT_DIR/lib-release-config.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/studio-tf-slack.sh draft --context <context.json> --commits <commits.txt> [--summary <text>] [--output-dir <dir>] [--dry-run]
  scripts/studio-tf-slack.sh send --draft <draft.json> --approve [--dry-run]

Draft renders parent/thread/combined files, validates the TestFlight message
shape, persists draft metadata, and emits slack_drafted. Send refuses without
--approve, posts parent then thread, and emits slack_sent. Dry-run events carry
dry_run:true. On send failure it emits release_failed with stage "slack_send".
EOF
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'studio-tf-slack: %s required\n' "$1" >&2
    exit 2
  }
}

json_get() {
  local file="$1" filter="$2"
  jq -r "$filter // empty" "$file"
}

release_emit() {
  local event="$1" release_tag="$2" data="$3"
  ACHILLES_PROJECT="$RELEASE_PROJECT" STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/studio-tf-push.sh" emit "$event" \
    --release-tag "$release_tag" --data "$data"
}

message_char_count() {
  wc -c "$@" | awk 'END {print $1}'
}

cmd_draft() {
  local context_path="" commits_path="" summary="" output_dir="" dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context_path="${2:?--context requires a path}"; shift 2 ;;
      --context=*) context_path="${1#--context=}"; shift ;;
      --commits) commits_path="${2:?--commits requires a path}"; shift 2 ;;
      --commits=*) commits_path="${1#--commits=}"; shift ;;
      --summary) summary="${2:?--summary requires text}"; shift 2 ;;
      --summary=*) summary="${1#--summary=}"; shift ;;
      --output-dir) output_dir="${2:?--output-dir requires a path}"; shift 2 ;;
      --output-dir=*) output_dir="${1#--output-dir=}"; shift ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage ;;
      *) printf 'studio-tf-slack draft: unknown arg %s\n' "$1" >&2; usage ;;
    esac
  done

  [ -n "$context_path" ] || usage
  [ -r "$context_path" ] || { printf 'studio-tf-slack draft: context not readable: %s\n' "$context_path" >&2; exit 2; }
  [ -n "$commits_path" ] || usage
  [ -r "$commits_path" ] || { printf 'studio-tf-slack draft: commits not readable: %s\n' "$commits_path" >&2; exit 2; }

  load_release_config || {
    printf 'studio-tf-slack: could not resolve release config project\n' >&2
    exit 2
  }
  require_cmd jq

  local release_tag build version prev_build channel channel_name headline parent_path thread_path combined_path metadata_path composer_json bullet_count cc_count lint_status
  release_tag=$(json_get "$context_path" '.release_tag')
  build=$(json_get "$context_path" '.build')
  version=$(json_get "$context_path" '.version')
  prev_build=$(json_get "$context_path" '.prev_build')
  [ -n "$release_tag" ] || { printf 'studio-tf-slack draft: context missing release_tag\n' >&2; exit 2; }
  [ -n "$build" ] || { printf 'studio-tf-slack draft: context missing build\n' >&2; exit 2; }
  [ -n "$version" ] || version="unknown"
  [ -n "$prev_build" ] || prev_build="null"

  channel="${STUDIO_TF_SLACK_CHANNEL:-}"
  [ -n "$channel" ] || { printf 'studio-tf-slack draft: STUDIO_TF_SLACK_CHANNEL missing; run /dev-studio release-manager configure\n' >&2; exit 2; }
  channel_name="${STUDIO_TF_SLACK_CHANNEL_NAME:-$channel}"

  if [ -z "$output_dir" ]; then
    output_dir="$RELEASE_PROJECT_ROOT/state/release-drafts/$release_tag"
  fi
  mkdir -p "$output_dir"

  parent_path="$output_dir/parent.txt"
  thread_path="$output_dir/thread.txt"
  combined_path="$output_dir/message.txt"
  metadata_path="$output_dir/draft.json"
  composer_json="$output_dir/composer.json"

  "$SCRIPT_DIR/studio-tf-push.sh" compose-message --channel testflight --input "$commits_path" >"$thread_path"
  "$SCRIPT_DIR/studio-tf-push.sh" compose-message --channel testflight --input "$commits_path" --json >"$composer_json"

  if [ -z "$summary" ]; then
    summary="Build $build is ready for testing."
  fi

  headline="[iOS] build $build is available on TestFlight"
  {
    printf '%s\n\n' "$headline"
    printf '%s\n' "$summary"
    printf 'Details in thread.\n'
  } >"$parent_path"

  if [ "$prev_build" != "null" ] && [ -n "$prev_build" ] && [ "$prev_build" != "$build" ] && [ "${STUDIO_TF_SLACK_INCLUDE_ROLLOVER:-0}" = "1" ]; then
    printf '\n- includes changes from %s\n' "$prev_build" >>"$thread_path"
  fi

  {
    cat "$parent_path"
    printf '\n'
    cat "$thread_path"
  } >"$combined_path"

  "$SCRIPT_DIR/lint-build-release-message.sh" --file "$combined_path" --channel testflight
  lint_status="passed"

  bullet_count=$(grep -Ec '^[-] ' "$thread_path" || true)
  cc_count=$({ grep -Eo 'cc: <@[A-Z0-9]+>' "$thread_path" || true; } | wc -l | tr -d ' ')

  jq -nc \
    --arg release_tag "$release_tag" \
    --argjson build "$build" \
    --arg version "$version" \
    --arg channel "$channel" \
    --arg channel_name "$channel_name" \
    --arg parent_path "$parent_path" \
    --arg thread_path "$thread_path" \
    --arg combined_path "$combined_path" \
    --arg composer_json "$composer_json" \
    --arg lint_status "$lint_status" \
    --argjson bullet_count "$bullet_count" \
    --argjson cc_count "$cc_count" \
    --argjson dry_run "$dry_run" \
    '{schema_version:1,kind:"testflight-slack-draft",release_tag:$release_tag,build:$build,version:$version,channel:$channel,channel_name:$channel_name,parent_path:$parent_path,thread_path:$thread_path,combined_path:$combined_path,composer_json:$composer_json,lint_status:$lint_status,bullet_count:$bullet_count,cc_count:$cc_count,dry_run:$dry_run,approved:false}' \
    >"$metadata_path"

  release_emit slack_drafted "$release_tag" "$(jq -nc \
    --argjson build "$build" \
    --arg channel "$channel_name" \
    --argjson bullet_count "$bullet_count" \
    --argjson cc_count "$cc_count" \
    --arg draft_path "$metadata_path" \
    --argjson dry_run "$dry_run" \
    '{build:$build,channel:$channel,bullet_count:$bullet_count,cc_count:$cc_count,draft_path:$draft_path,dry_run:$dry_run}')"

  printf '%s\n' "$metadata_path"
}

cmd_send() {
  local draft_path="" approve=0 dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) draft_path="${2:?--draft requires a path}"; shift 2 ;;
      --draft=*) draft_path="${1#--draft=}"; shift ;;
      --approve) approve=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage ;;
      *) printf 'studio-tf-slack send: unknown arg %s\n' "$1" >&2; usage ;;
    esac
  done

  [ -n "$draft_path" ] || usage
  [ -r "$draft_path" ] || { printf 'studio-tf-slack send: draft not readable: %s\n' "$draft_path" >&2; exit 2; }
  if [ "$approve" -ne 1 ]; then
    printf 'studio-tf-slack send: refusing to post without --approve\n' >&2
    exit 4
  fi

  load_release_config || {
    printf 'studio-tf-slack: could not resolve release config project\n' >&2
    exit 2
  }
  require_cmd jq

  local release_tag build channel parent_path thread_path parent_ts resp chars
  release_tag=$(json_get "$draft_path" '.release_tag')
  build=$(json_get "$draft_path" '.build')
  channel=$(json_get "$draft_path" '.channel')
  parent_path=$(json_get "$draft_path" '.parent_path')
  thread_path=$(json_get "$draft_path" '.thread_path')
  [ -n "$release_tag" ] || { printf 'studio-tf-slack send: draft missing release_tag\n' >&2; exit 2; }
  [ -n "$build" ] || { printf 'studio-tf-slack send: draft missing build\n' >&2; exit 2; }
  [ -n "$channel" ] || { printf 'studio-tf-slack send: draft missing channel\n' >&2; exit 2; }
  [ -r "$parent_path" ] || { printf 'studio-tf-slack send: parent not readable: %s\n' "$parent_path" >&2; exit 2; }
  [ -r "$thread_path" ] || { printf 'studio-tf-slack send: thread not readable: %s\n' "$thread_path" >&2; exit 2; }

  if [ "$dry_run" -eq 1 ]; then
    "$SCRIPT_DIR/slack-post.sh" --channel "$channel" --text "$(cat "$parent_path")" --dry-run >/dev/null
    "$SCRIPT_DIR/slack-post.sh" --channel "$channel" --thread-ts "dry-run-parent-ts" --text "$(cat "$thread_path")" --dry-run >/dev/null
    parent_ts="dry-run-parent-ts"
  else
    if ! resp=$(STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" --channel "$channel" --text "$(cat "$parent_path")" 2>&1); then
      release_emit release_failed "$release_tag" "$(jq -nc --arg reason "$resp" '{stage:"slack_send",reason:$reason}')"
      printf 'studio-tf-slack send: Slack parent post failed: %s\n' "$resp" >&2
      exit 1
    fi
    parent_ts=$(printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null || true)
    if [ -z "$parent_ts" ]; then
      release_emit release_failed "$release_tag" "$(jq -nc --arg reason "Slack parent post returned no ts" '{stage:"slack_send",reason:$reason}')"
      printf 'studio-tf-slack send: Slack parent post returned no ts\n' >&2
      exit 1
    fi
    if ! resp=$(STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" --channel "$channel" --thread-ts "$parent_ts" --text "$(cat "$thread_path")" 2>&1); then
      release_emit release_failed "$release_tag" "$(jq -nc --arg reason "$resp" '{stage:"slack_send",reason:$reason}')"
      printf 'studio-tf-slack send: Slack thread post failed: %s\n' "$resp" >&2
      exit 1
    fi
  fi

  chars=$(message_char_count "$parent_path" "$thread_path")
  release_emit slack_sent "$release_tag" "$(jq -nc \
    --argjson build "$build" \
    --arg channel "$channel" \
    --arg parent_ts "$parent_ts" \
    --argjson message_chars "$chars" \
    --argjson dry_run "$dry_run" \
    '{build:$build,channel:$channel,parent_ts:$parent_ts,message_chars:$message_chars,dry_run:$dry_run}')"

  jq --arg parent_ts "$parent_ts" --argjson dry_run "$dry_run" \
    '.approved = true | .sent = {parent_ts:$parent_ts,dry_run:$dry_run}' "$draft_path" >"$draft_path.tmp"
  mv "$draft_path.tmp" "$draft_path"
  printf '%s\n' "$draft_path"
}

case "${1:-}" in
  draft) shift; cmd_draft "$@" ;;
  send) shift; cmd_send "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
