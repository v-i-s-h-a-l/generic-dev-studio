#!/usr/bin/env bash
# studio-tf-push.sh — studio-owned TestFlight / App Store Connect push driver.
#
# Implements `_shared/contracts/release-tf-push.md` Steps 1–6 (TF push) and
# the App Store Connect submission path. Step 7–9 (Slack draft + human
# approval + send) live in the slash-command wrapper because they need LLM
# judgment and a user-approval gate; the wrapper emits `slack_drafted` /
# `slack_sent` via `studio-tf-push.sh emit` so the event taxonomy stays
# under one roof.
#
# Subcommands:
#   push       (default) — Steps 1–6 of release-tf-push.md. Bumps build /
#              version, archives, exports + uploads to ASC, uploads dSYMs.
#              Outputs a one-line JSON context blob on stdout for the wrapper
#              (release_tag, build, version, scheme, branch, archive_path,
#              prev_build, tf_tag).
#   appstore   — App Store submission: tag + push tag, GH draft release,
#              find build on ASC, create/update version, set MANUAL release,
#              update whatsNew per localization. Inputs (release notes, what's
#              new) come from files prepared by the wrapper after user
#              approval.
#   withdraw-tf-tag — rename a TF anchor tag to tf-<version>-<build>-WITHDRAWN.
#   emit       — emit one release event (`slack_drafted` / `slack_sent` /
#              `release_failed`) with the same release-tag the wrapper
#              captured from `push`. Lets the wrapper participate in the
#              event taxonomy without exposing `lib-ledger.sh` directly.
#
# Usage:
#   scripts/studio-tf-push.sh [push] [--scheme <name>] [--version <X.Y.Z>] [--dry-run] [--background]
#   scripts/studio-tf-push.sh appstore --build <n> --version <v> \
#                              --release-notes-file <path> --whatsnew-file <path> \
#                              [--dry-run]
#   scripts/studio-tf-push.sh withdraw-tf-tag --build <n> --version <v> [--dry-run]
#   scripts/studio-tf-push.sh emit <event> --release-tag <tag> --data <json>
#
# Env:
#   STUDIO_TF_PUSH_LIVE=1         required for non-dry-run external effects.
#                                 Wrappers set this; bare CLI invocations do
#                                 not, so accidental live pushes are blocked.
#   STUDIO_RELEASE_PROJECT        project slug for release config/secrets under
#                                 ~/.dev-studio/<project>/.
#   STUDIO_RELEASE_CONFIG_FILE    override config file path (default:
#                                 ~/.dev-studio/<project>/config/release.env).
#   STUDIO_RELEASE_TAG            if set, `push` reuses this tag instead of
#                                 minting one. Wrappers generate the tag up
#                                 front so that `push` and later `emit` calls
#                                 share one idempotency key.
#   STUDIO_TF_FORCE_VERSION       explicit MARKETING_VERSION for `push`.
#                                 Equivalent to `push --version`; the flag
#                                 wins when both are set.
#   STUDIO_TF_PUSH_FIXTURE_NODE   override the resolved node id (smoke tests).
#   STUDIO_TF_PUSH_SKIP_NODE_PICK=1   skip the node-pick gate (fixtures only).
#   STUDIO_RELEASE_TAG            reused by --background so parent, child, and
#                                 later Slack emit calls share one release span.
#   STUDIO_TF_PUSH_PREPARED_CONTEXT_PATH
#                                 optional path where `push` writes build/version
#                                 context before the long archive phase.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-build-queue.sh
. "$SCRIPT_DIR/lib-build-queue.sh"
# shellcheck source=lib-release-config.sh
. "$SCRIPT_DIR/lib-release-config.sh"

STUDIO_RELEASE_PROJECT="${STUDIO_RELEASE_PROJECT:-${STUDIO_TF_PROJECT_SLUG:-}}"
load_release_config || {
  printf 'studio-tf-push: could not resolve release config project\n' >&2
  exit 2
}

# Project config is loaded from ~/.dev-studio/<project>/config/release.env.
# STUDIO_TF_* env overrides keep synthetic fixtures out of the real checkout.
PROJECT_ROOT="${STUDIO_TF_PROJECT_ROOT:-/Users/vishalsingh/Documents/Turnip.gg/turnip-ios}"
PBXPROJ="${STUDIO_TF_PBXPROJ:-$PROJECT_ROOT/zaps-app/Turnip.xcodeproj/project.pbxproj}"
PROJECT_RELPATH="${STUDIO_TF_PROJECT_RELPATH:-zaps-app/Turnip.xcodeproj}"
ASC_KEY_ID="${STUDIO_TF_ASC_KEY_ID:-}"
ASC_ISSUER_ID="${STUDIO_TF_ASC_ISSUER_ID:-}"
ASC_KEY_PATH=$(release_asc_key_path "$ASC_KEY_ID" 2>/dev/null || true)
APP_ID="${STUDIO_TF_APP_ID:-}"
GSIP_PATH="${STUDIO_TF_GSIP_PATH:-$PROJECT_ROOT/zaps-app/Zaps/Firebase/Prod/GoogleService-Info.plist}"
XCPRETTY="${STUDIO_TF_XCPRETTY:-/Users/vishalsingh/.gem/ruby/2.6.0/bin/xcpretty}"
ASC_TIMEOUT="${STUDIO_TF_ASC_TIMEOUT:-20}"
SLACK_TOKEN_FILE=$(release_slack_token_file)

_json_obj() {
  local out='{}'
  for kv in "$@"; do
    case "$kv" in
      *=*)
        local k="${kv%%=*}" v="${kv#*=}"
        out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}')
        ;;
    esac
  done
  printf '%s' "$out"
}

emit_release() {
  local event="$1" data="${2:-{\}}"
  if [ "${DRY_RUN_FLAG:-0}" = "1" ]; then
    data=$(printf '%s' "$data" | jq -c '. + {"mode":"dry-run"}')
  fi
  emit_event_keyed studio release "$event" "$RELEASE_TAG" "$data" >/dev/null
}

halt_failed() {
  local stage="$1" reason="$2"
  local data
  data=$(_json_obj "stage=$stage" "reason=$reason")
  emit_release release_failed "$data"
  printf 'studio-tf-push: halted at %s — %s\n' "$stage" "$reason" >&2
  exit 1
}

failure_excerpt() {
  local log="$1"
  if [ ! -r "$log" ]; then
    printf 'no readable log'
    return 0
  fi
  grep -Ei '(^|: )(error|fatal):|ARCHIVE FAILED|BUILD FAILED|CodeSign|Provisioning|No profiles|Signing' "$log" \
    | tail -20 \
    | sed 's/"/'\''/g' \
    | tr '\n' ' ' \
    | cut -c 1-1200
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || halt_failed prereq "$name required before release mutation"
}

tf_tag_name() {
  local version="$1" build="$2"
  case "$version" in
    *[!0-9.]*|.*|*.) printf 'tf_tag: invalid version %s\n' "$version" >&2; return 2 ;;
  esac
  printf '%s\n' "$version" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' || {
    printf 'tf_tag: invalid version %s\n' "$version" >&2
    return 2
  }
  case "$build" in
    ''|*[!0-9]*) printf 'tf_tag: invalid build %s\n' "$build" >&2; return 2 ;;
  esac
  printf 'tf-%s-%s\n' "$version" "$build"
}

local_tag_commit() {
  local tag="$1"
  git rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null || true
}

ensure_tf_tag() {
  local tag="$1" target="$2" version="$3" build="$4" branch="$5"
  local existing
  existing=$(local_tag_commit "$tag")
  if [ -n "$existing" ]; then
    local target_full
    target_full=$(git rev-parse "$target^{commit}" 2>/dev/null || true)
    if [ "$existing" != "$target_full" ]; then
      halt_failed prereq "TF tag $tag already points at $existing, not bump commit $target_full"
    fi
    printf 'studio-tf-push: TF tag %s already exists at bump commit; reusing\n' "$tag" >&2
    return 0
  fi
  git tag -a "$tag" "$target" -m "TestFlight build ${build} (v${version}) from ${branch}"
}

push_tf_tag() {
  local tag="$1"
  git push origin "refs/tags/${tag}"
}

preflight_push_release() {
  local branch="$1"

  require_cmd git
  require_cmd jq
  require_cmd curl
  require_cmd python3

  [ -d "$PROJECT_ROOT/.git" ] || halt_failed prereq "project git checkout missing at $PROJECT_ROOT; no mutation occurred"
  [ -r "$PBXPROJ" ] || halt_failed prereq "pbxproj unreadable at $PBXPROJ; no mutation occurred"
  [ -n "$APP_ID" ] || halt_failed prereq "STUDIO_TF_APP_ID missing in $RELEASE_CONFIG_FILE; no mutation occurred"
  [ -n "$ASC_KEY_ID" ] || halt_failed prereq "STUDIO_TF_ASC_KEY_ID missing in $RELEASE_CONFIG_FILE; no mutation occurred"
  [ -n "$ASC_ISSUER_ID" ] || halt_failed prereq "STUDIO_TF_ASC_ISSUER_ID missing in $RELEASE_CONFIG_FILE; no mutation occurred"
  [ -n "$ASC_KEY_PATH" ] || halt_failed prereq "STUDIO_TF_ASC_KEY_PATH missing and no key-id default could be derived; no mutation occurred"
  case "$branch" in
    main|master|trunk|develop|release/*)
      halt_failed prereq "active branch '$branch' is a base branch — no mutation occurred; switch to a feature branch"
      ;;
    ""|unknown|HEAD)
      halt_failed prereq "could not resolve a feature branch for release push; no mutation occurred"
      ;;
  esac

  local push_probe
  if ! push_probe=$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never \
      git -C "$PROJECT_ROOT" push --dry-run --porcelain -u origin HEAD 2>&1); then
    halt_failed prereq "GitHub push auth/preflight failed before mutation; no build-number commit created. Run: gh auth status && git -C '$PROJECT_ROOT' push --dry-run -u origin HEAD. Details: $push_probe"
  fi

  [ -r "$ASC_KEY_PATH" ] || halt_failed prereq "ASC key unreadable at $ASC_KEY_PATH; no mutation occurred"
  if ! python3 - <<'PY' >/dev/null 2>&1
import jwt
PY
  then
    halt_failed prereq "Python jwt dependency missing before mutation; install PyJWT in the release environment"
  fi
  if [ "${STUDIO_TF_SLACK_DEFERRED:-0}" != "1" ]; then
    [ -r "$SLACK_TOKEN_FILE" ] || halt_failed prereq "Slack token unreadable at $SLACK_TOKEN_FILE; no mutation occurred. Set STUDIO_TF_SLACK_DEFERRED=1 only for an intentionally upload-only run."
    [ -s "$SLACK_TOKEN_FILE" ] || halt_failed prereq "Slack token file is empty at $SLACK_TOKEN_FILE; no mutation occurred. Set STUDIO_TF_SLACK_DEFERRED=1 only for an intentionally upload-only run."
  fi
}

asc_get() {
  local url="$1" fixture_file="${2:-}"
  if [ -n "$fixture_file" ]; then
    cat "$fixture_file"
    return 0
  fi
  curl -sgS --max-time "$ASC_TIMEOUT" "$url" \
    -H "Authorization: Bearer $TOKEN"
}

warn_live_version_unresolved() {
  local reason="$1"
  halt_failed prereq "WARNING: Could not determine live App Store version; no mutation occurred. $reason"
}

extract_latest_build_number() {
  local resp="$1" build
  if printf '%s' "$resp" | jq -e '.errors? | length > 0' >/dev/null 2>&1; then
    halt_failed prereq "could not determine latest TF build from ASC response: $(printf '%s' "$resp" | jq -c '.errors')"
  fi
  build=$(printf '%s' "$resp" | jq -r '.data[0].attributes.version // empty')
  [ -n "$build" ] || halt_failed prereq "could not parse latest TF build from ASC response"
  printf '%s\n' "$build"
}

extract_live_version() {
  local resp="$1" version
  if printf '%s' "$resp" | jq -e '.errors? | length > 0' >/dev/null 2>&1; then
    warn_live_version_unresolved "ASC returned errors: $(printf '%s' "$resp" | jq -c '.errors')"
  fi
  version=$(printf '%s' "$resp" | jq -r '.data[0].attributes.versionString // empty')
  [ -n "$version" ] || warn_live_version_unresolved "ASC returned no READY_FOR_SALE appStoreVersions for app_id=$APP_ID."
  printf '%s\n' "$version"
}

mint_jwt() {
  python3 - <<PY 2>/dev/null
import jwt, time
key = open('$ASC_KEY_PATH').read()
payload = {'iss': '$ASC_ISSUER_ID', 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': '$ASC_KEY_ID'}))
PY
}

route_to_release_node() {
  if [ "${STUDIO_TF_PUSH_SKIP_NODE_PICK:-0}" = "1" ]; then
    NODE="local-skipped"
    return
  fi
  if [ -n "${STUDIO_TF_PUSH_FIXTURE_NODE:-}" ]; then
    NODE="$STUDIO_TF_PUSH_FIXTURE_NODE"
  else
    NODE=$("$SCRIPT_DIR/node-pick.sh" --requires-secret-scope asc,slack release 2>/dev/null || echo local)
  fi
  if [ "$NODE" = "local" ]; then
    halt_failed prereq "no node advertises asc,slack scopes — refusing to run secret-bearing work locally"
  fi
}

cmd_push_background() {
  local scheme="$1" dry_run_flag="$2"

  require_cmd jq

  local release_tag="${STUDIO_RELEASE_TAG:-release-pending-$(date -u +%Y%m%d-%H%M%S)}"
  local run_dir="$RELEASE_PROJECT_ROOT/state/release-runs/$release_tag"
  local log_path="$run_dir/push.log"
  local status_path="$run_dir/status.json"
  local context_path="$run_dir/context.json"
  local prepared_context_path="$run_dir/prepared-context.json"
  mkdir -p "$run_dir" || {
    printf 'push: could not create release run dir %s\n' "$run_dir" >&2
    exit 2
  }

  jq -nc \
    --arg release_tag "$release_tag" \
    --arg state "starting" \
    --arg log_path "$log_path" \
    --arg context_path "$context_path" \
    --arg prepared_context_path "$prepared_context_path" \
    '{release_tag:$release_tag,state:$state,log_path:$log_path,context_path:$context_path,prepared_context_path:$prepared_context_path,started_at:null,pid:null,exit_code:null}' \
    >"$status_path"

  local -a child_args
  child_args=(push --scheme "$scheme")
  [ "$dry_run_flag" = "1" ] && child_args+=(--dry-run)

  (
    local started_at rc bg_child_pid
    bg_child_pid="${BASHPID:-$$}"
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc \
      --arg release_tag "$release_tag" \
      --arg state "running" \
      --arg started_at "$started_at" \
      --arg log_path "$log_path" \
      --arg context_path "$context_path" \
      --arg prepared_context_path "$prepared_context_path" \
      --argjson pid "$bg_child_pid" \
      '{release_tag:$release_tag,state:$state,started_at:$started_at,log_path:$log_path,context_path:$context_path,prepared_context_path:$prepared_context_path,pid:$pid,exit_code:null}' \
      >"$status_path"
    if [ -n "${STUDIO_TF_PUSH_BACKGROUND_CHILD_DELAY_S:-}" ]; then
      sleep "$STUDIO_TF_PUSH_BACKGROUND_CHILD_DELAY_S"
    fi
    if STUDIO_RELEASE_TAG="$release_tag" \
        STUDIO_TF_PUSH_PREPARED_CONTEXT_PATH="$prepared_context_path" \
        "$SCRIPT_DIR/studio-tf-push.sh" "${child_args[@]}" >"$context_path.tmp" 2>"$log_path"; then
      mv "$context_path.tmp" "$context_path"
      jq -nc \
        --arg release_tag "$release_tag" \
        --arg state "succeeded" \
        --arg started_at "$started_at" \
        --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg log_path "$log_path" \
        --arg context_path "$context_path" \
        --arg prepared_context_path "$prepared_context_path" \
        --argjson pid "$bg_child_pid" \
        '{release_tag:$release_tag,state:$state,started_at:$started_at,ended_at:$ended_at,log_path:$log_path,context_path:$context_path,prepared_context_path:$prepared_context_path,pid:$pid,exit_code:0}' \
        >"$status_path"
    else
      rc=$?
      rm -f "$context_path.tmp"
      jq -nc \
        --arg release_tag "$release_tag" \
        --arg state "failed" \
        --arg started_at "$started_at" \
        --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg log_path "$log_path" \
        --arg context_path "$context_path" \
        --arg prepared_context_path "$prepared_context_path" \
        --argjson pid "$bg_child_pid" \
        --argjson rc "$rc" \
        '{release_tag:$release_tag,state:$state,started_at:$started_at,ended_at:$ended_at,log_path:$log_path,context_path:$context_path,prepared_context_path:$prepared_context_path,pid:$pid,exit_code:$rc}' \
        >"$status_path"
      exit "$rc"
    fi
  ) </dev/null >>"$log_path" 2>&1 &
  local pid=$!

  jq -nc \
    --arg release_tag "$release_tag" \
    --argjson pid "$pid" \
    --arg log_path "$log_path" \
    --arg status_path "$status_path" \
    --arg context_path "$context_path" \
    --arg prepared_context_path "$prepared_context_path" \
    '{release_tag:$release_tag, background:true, pid:$pid, log_path:$log_path, status_path:$status_path, context_path:$context_path, prepared_context_path:$prepared_context_path}'
}

cmd_emit() {
  local event="${1:-}"; shift || true
  case "$event" in
    slack_drafted|slack_sent|release_failed) ;;
    *) printf 'emit: event must be slack_drafted|slack_sent|release_failed (got %s)\n' "$event" >&2; exit 2 ;;
  esac
  local rt="" data="{}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --release-tag) rt="${2:?}"; shift 2 ;;
      --data) data="${2:?}"; shift 2 ;;
      *) printf 'emit: unknown arg %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [ -n "$rt" ] || { printf 'emit: --release-tag required\n' >&2; exit 2; }
  printf '%s' "$data" | jq -e . >/dev/null 2>&1 || { printf 'emit: --data must be valid JSON\n' >&2; exit 2; }
  emit_event_keyed studio release "$event" "$rt" "$data" >/dev/null
}

release_bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

appstore_notify_slack() {
  local build="$1" version="$2" tag="$3" release_notes_file="$4" whatsnew_file="$5" release_url="$6" dry_run_flag="$7"
  APPSTORE_SLACK_STATUS="skipped_not_configured"
  APPSTORE_SLACK_CHANNEL_USED=""
  APPSTORE_SLACK_PARENT_TS=""

  local channel="${STUDIO_RELEASES_SLACK_CHANNEL:-}"
  if [ -z "$channel" ]; then
    printf 'studio-tf-push: Slack release announcements not configured; skipping Slack post. Run /dev-studio release-manager configure to enable.\n' >&2
    return 0
  fi
  if ! release_bool_enabled "${STUDIO_RELEASES_SLACK_APPSTORE_PARENT:-1}"; then
    printf 'studio-tf-push: Slack release parent disabled by config; skipping App Store Slack post.\n' >&2
    APPSTORE_SLACK_STATUS="skipped_parent_disabled"
    return 0
  fi

  APPSTORE_SLACK_CHANNEL_USED="$channel"
  local parent_text whatsnew_text whatsnew_reply resp parent_ts
  parent_text=$(cat "$release_notes_file")
  whatsnew_text=$(cat "$whatsnew_file")

  if [ "$dry_run_flag" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would post App Store Slack parent to %s for build=%s version=%s tag=%s\n' \
      "$channel" "$build" "$version" "$tag" >&2
    if release_bool_enabled "${STUDIO_RELEASES_SLACK_WHATSNEW_REPLY:-1}"; then
      printf 'studio-tf-push: [dry-run] would post App Store What'\''s New as a thread reply\n' >&2
    fi
    if release_bool_enabled "${STUDIO_RELEASES_SLACK_GITHUB_REPLY:-1}"; then
      printf 'studio-tf-push: [dry-run] would post GitHub release URL as a thread reply\n' >&2
    fi
    APPSTORE_SLACK_STATUS="dry_run"
    return 0
  fi

  if ! resp=$(STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
      --channel "$channel" --text "$parent_text" 2>&1); then
    printf 'studio-tf-push: Slack parent post failed after App Store submission was prepared: %s\n' "$resp" >&2
    APPSTORE_SLACK_STATUS="failed_parent"
    return 0
  fi
  parent_ts=$(printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null || true)
  if [ -z "$parent_ts" ]; then
    printf 'studio-tf-push: Slack parent post returned no ts; watcher thread replies disabled for this release.\n' >&2
    APPSTORE_SLACK_STATUS="failed_no_ts"
    return 0
  fi
  APPSTORE_SLACK_PARENT_TS="$parent_ts"

  if release_bool_enabled "${STUDIO_RELEASES_SLACK_WHATSNEW_REPLY:-1}"; then
    whatsnew_reply=$(cat <<EOF
App Store "What's New" submitted with this build:


$whatsnew_text
EOF
)
    if ! STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
        --channel "$channel" --thread-ts "$parent_ts" --text "$whatsnew_reply" >/dev/null; then
      printf 'studio-tf-push: warning: Slack What'\''s New thread reply failed\n' >&2
    fi
  fi

  if release_bool_enabled "${STUDIO_RELEASES_SLACK_GITHUB_REPLY:-1}"; then
    if ! STUDIO_RELEASE_PROJECT="$RELEASE_PROJECT" "$SCRIPT_DIR/slack-post.sh" \
        --channel "$channel" --thread-ts "$parent_ts" --text "$release_url" >/dev/null; then
      printf 'studio-tf-push: warning: Slack GitHub release thread reply failed\n' >&2
    fi
  fi

  APPSTORE_SLACK_STATUS="posted"
}

write_appstore_pending_marker() {
  local build="$1" version="$2" tag="$3" version_id="$4" build_id="$5" release_url="$6"
  local state_dir marker_path watcher_replies
  state_dir="$RELEASE_PROJECT_ROOT/.runtime/state"
  marker_path="$state_dir/pending-appstore-review.json"
  mkdir -p "$state_dir" || {
    printf 'studio-tf-push: could not create marker state dir %s\n' "$state_dir" >&2
    return 1
  }
  if release_bool_enabled "${STUDIO_RELEASES_SLACK_WATCHER_REPLIES:-1}"; then
    watcher_replies=true
  else
    watcher_replies=false
  fi
  jq -nc \
    --arg project "$RELEASE_PROJECT" \
    --arg tag "$tag" \
    --arg version "$version" \
    --arg asc_app_id "$APP_ID" \
    --arg repo "${STUDIO_TF_GH_REPO:-turnip-ios/turnip-zaps}" \
    --arg github_release_url "$release_url" \
    --arg asc_key_id "$ASC_KEY_ID" \
    --arg asc_issuer_id "$ASC_ISSUER_ID" \
    --arg build_id "$build_id" \
    --arg appstore_version_id "$version_id" \
    --arg slack_channel "$APPSTORE_SLACK_CHANNEL_USED" \
    --arg slack_parent_ts "$APPSTORE_SLACK_PARENT_TS" \
    --arg slack_post_status "$APPSTORE_SLACK_STATUS" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg build "$build" \
    --argjson watcher_replies "$watcher_replies" \
    '{
      project:$project,
      tag:$tag,
      version:$version,
      build:($build | tonumber? // $build),
      asc_app_id:$asc_app_id,
      repo:$repo,
      github_release_url:$github_release_url,
      asc_key_id:$asc_key_id,
      asc_issuer_id:$asc_issuer_id,
      asc_build_id:$build_id,
      appstore_version_id:$appstore_version_id,
      slack_channel:$slack_channel,
      slack_parent_ts:$slack_parent_ts,
      slack_post_status:$slack_post_status,
      slack_watcher_replies:$watcher_replies,
      created_at:$created_at,
      next_check_at:null,
      failures:0,
      finalize_draft_published:false,
      finalize_slack_posted:false
    }' >"$marker_path"
  chmod 600 "$marker_path" 2>/dev/null || true
  printf 'studio-tf-push: pending App Store marker: %s\n' "$marker_path" >&2
}

cmd_push() {
  DRY_RUN_FLAG=0
  local BACKGROUND_FLAG=0
  local SCHEME="Zaps"
  local FORCE_VERSION="${STUDIO_TF_FORCE_VERSION:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN_FLAG=1; shift ;;
      --background) BACKGROUND_FLAG=1; shift ;;
      --scheme) SCHEME="${2:?}"; shift 2 ;;
      --version) FORCE_VERSION="${2:?}"; shift 2 ;;
      *) printf 'push: unknown arg %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  if [ -n "$FORCE_VERSION" ]; then
    case "$FORCE_VERSION" in
      *[!0-9.]*|.*|*.) printf 'push: --version must look like X.Y.Z (got %s)\n' "$FORCE_VERSION" >&2; exit 2 ;;
    esac
    if ! printf '%s\n' "$FORCE_VERSION" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$'; then
      printf 'push: --version must look like X.Y.Z (got %s)\n' "$FORCE_VERSION" >&2
      exit 2
    fi
  fi

  if [ "$BACKGROUND_FLAG" = "1" ]; then
    cmd_push_background "$SCHEME" "$DRY_RUN_FLAG"
    return
  fi

  local CONFIGURATION="Release"
  case "$SCHEME" in
    Zaps) CONFIGURATION="Release" ;;
    Zaps-Internal) CONFIGURATION="Internal" ;;
  esac

  RELEASE_TAG="${STUDIO_RELEASE_TAG:-release-pending-$(date -u +%Y%m%d-%H%M%S)}"
  local LIVE="${STUDIO_TF_PUSH_LIVE:-0}"
  if [ "$DRY_RUN_FLAG" != "1" ] && [ "$LIVE" != "1" ]; then
    halt_failed prereq "STUDIO_TF_PUSH_LIVE=1 required for non-dry-run; refusing real archive/upload (R14)"
  fi

  route_to_release_node
  local BRANCH
  BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$DRY_RUN_FLAG" != "1" ]; then
    preflight_push_release "$BRANCH"
  fi

  # Phase 1 — ASC state + version decision (Steps 1–2).
  local LATEST_BUILD_NUMBER=0 LIVE_VERSION="0.0.0" CURRENT_VERSION="0.0.0"
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    :
  else
    local TOKEN
    TOKEN=$(mint_jwt)
    [ -n "$TOKEN" ] || halt_failed prereq "ASC JWT mint failed (check $ASC_KEY_PATH)"

    local builds_resp versions_resp
    builds_resp=$(asc_get \
      "https://api.appstoreconnect.apple.com/v1/builds?sort=-uploadedDate&limit=1&fields[builds]=version" \
      "${STUDIO_TF_BUILDS_RESPONSE_FILE:-}") \
      || halt_failed prereq "could not reach ASC builds endpoint before mutation"
    versions_resp=$(asc_get \
      "https://api.appstoreconnect.apple.com/v1/apps/${APP_ID}/appStoreVersions?filter[appStoreState]=READY_FOR_SALE&fields[appStoreVersions]=versionString" \
      "${STUDIO_TF_VERSIONS_RESPONSE_FILE:-}") \
      || warn_live_version_unresolved "ASC request failed or timed out."
    LATEST_BUILD_NUMBER=$(extract_latest_build_number "$builds_resp") || exit 1
    LIVE_VERSION=$(extract_live_version "$versions_resp") || exit 1
    CURRENT_VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' ')
    [ -n "$CURRENT_VERSION" ] || halt_failed prereq "could not parse MARKETING_VERSION from pbxproj"
  fi

  local NEW_BUILD_NUMBER=$((LATEST_BUILD_NUMBER + 1))
  local VERSION="$CURRENT_VERSION"
  local VERSION_SOURCE="pbxproj"
  local VERSION_DECISION=""

  if [ -n "$FORCE_VERSION" ]; then
    VERSION="$FORCE_VERSION"
    VERSION_SOURCE="override"
    VERSION_DECISION="using explicit version override"
  elif [ "$DRY_RUN_FLAG" != "1" ] && [ "$CURRENT_VERSION" = "$LIVE_VERSION" ]; then
    local YY MM N
    YY=$(date -u +%y)
    MM=$(date -u +%-m)
    if [[ "$LIVE_VERSION" =~ ^${YY}\.${MM}\.([0-9]+)$ ]]; then
      N=$(( ${BASH_REMATCH[1]} + 1 ))
    else
      N=0
    fi
    VERSION="${YY}.${MM}.${N}"
    VERSION_SOURCE="auto-bump"
    VERSION_DECISION="pbxproj matched live version; auto-bumping"
  else
    VERSION_DECISION="keeping pbxproj MARKETING_VERSION"
  fi

  RELEASE_TAG="${STUDIO_RELEASE_TAG:-release-${NEW_BUILD_NUMBER}-$(date -u +%Y%m%d-%H%M%S)}"

  printf 'studio-tf-push: version decision: pbxproj=%s live=%s resolved=%s source=%s (%s)\n' \
    "$CURRENT_VERSION" "$LIVE_VERSION" "$VERSION" "$VERSION_SOURCE" "$VERSION_DECISION" >&2

  emit_release release_started "$(_json_obj \
    "build_from=$LATEST_BUILD_NUMBER" \
    "live_version=$LIVE_VERSION" \
    "current_version=$CURRENT_VERSION" \
    "resolved_version=$VERSION" \
    "version_source=$VERSION_SOURCE" \
    "branch=$BRANCH")"

  printf 'studio-tf-push: routed to %s (release-tag=%s, dry-run=%s, scheme=%s)\n' \
    "$NODE" "$RELEASE_TAG" "$DRY_RUN_FLAG" "$SCHEME" >&2

  if [ "$DRY_RUN_FLAG" != "1" ]; then
    local version_resp rejected_state
    version_resp=$(curl -sg "https://api.appstoreconnect.apple.com/v1/apps/${APP_ID}/appStoreVersions?fields[appStoreVersions]=versionString,appStoreState" \
      -H "Authorization: Bearer $TOKEN")
    printf '%s' "$version_resp" | jq -e '.data | type == "array"' >/dev/null 2>&1 \
      || halt_failed prereq "ASC version-state preflight returned an unreadable response"
    rejected_state=$(printf '%s' "$version_resp" | jq -r --arg v "$VERSION" '
      .data[]?
      | select(.attributes.versionString == $v)
      | .attributes.appStoreState
      | select(test("^(INVALID_BINARY|DEVELOPER_REJECTED|REJECTED|METADATA_REJECTED)$"))
    ' | head -1)
    if [ -n "$rejected_state" ]; then
      halt_failed prereq "STUDIO_TF_REJECTED_VERSION: resolved MARKETING_VERSION=$VERSION has App Store state $rejected_state. Set STUDIO_TF_FORCE_VERSION=<new> or update pbxproj before re-running."
    fi
    if [ -n "$FORCE_VERSION" ]; then
      local existing_live_state
      existing_live_state=$(printf '%s' "$version_resp" | jq -r --arg v "$VERSION" '
        .data[]?
        | select(.attributes.versionString == $v)
        | .attributes.appStoreState
        | select(. == "READY_FOR_SALE")
      ' | head -1)
      if [ -n "$existing_live_state" ]; then
        halt_failed prereq "explicit version $VERSION already exists in ASC as $existing_live_state; choose a new STUDIO_TF_FORCE_VERSION"
      fi
    fi
  fi

  # Phase 1.5 — pbxproj bump + commit + push (Step 3).
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would bump pbxproj to build=%s version=%s and push branch=%s\n' \
      "$NEW_BUILD_NUMBER" "$VERSION" "$BRANCH" >&2
  else
    if ! sed -i '' \
        -e "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD_NUMBER};/g" \
        -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${VERSION};/g" \
        "$PBXPROJ"; then
      halt_failed prereq "pbxproj sed bump failed"
    fi
    local oldpwd bump_commit
    oldpwd=$PWD
    cd "$PROJECT_ROOT" || halt_failed prereq "cd $PROJECT_ROOT failed"
    local lock
    lock="$(git rev-parse --git-dir)/index.lock"
    if [ -e "$lock" ] && ! pgrep -f "git .* $PROJECT_ROOT" >/dev/null; then
      rm -f "$lock"
    fi
    git add zaps-app/Turnip.xcodeproj/project.pbxproj
    if git diff --cached --quiet -- zaps-app/Turnip.xcodeproj/project.pbxproj; then
      printf 'studio-tf-push: pbxproj already at target build=%s version=%s; skipping bump commit\n' \
        "$NEW_BUILD_NUMBER" "$VERSION" >&2
    elif ! git commit -m "$(cat <<EOF
Bump build number to ${NEW_BUILD_NUMBER}

Preparing TestFlight build ${NEW_BUILD_NUMBER} (v${VERSION}) from branch ${BRANCH}.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"; then
      cd "$oldpwd" || true
      halt_failed prereq "version-bump commit failed"
    fi
    bump_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
    local TF_TAG
    TF_TAG=$(tf_tag_name "$VERSION" "$NEW_BUILD_NUMBER") || {
      cd "$oldpwd" || true
      halt_failed prereq "could not derive TF tag for version=$VERSION build=$NEW_BUILD_NUMBER"
    }
    ensure_tf_tag "$TF_TAG" "$bump_commit" "$VERSION" "$NEW_BUILD_NUMBER" "$BRANCH" || {
      cd "$oldpwd" || true
      halt_failed prereq "TF tag creation failed"
    }
    if ! git push -u origin HEAD; then
      cd "$oldpwd" || true
      halt_failed prereq "STRANDED_RELEASE_STATE: build-number commit ${bump_commit:0:12} and TF tag $TF_TAG exist locally but branch push failed after mutation. Next safe command: git -C '$PROJECT_ROOT' push -u origin HEAD && git -C '$PROJECT_ROOT' push origin refs/tags/$TF_TAG"
    fi
    if ! push_tf_tag "$TF_TAG"; then
      cd "$oldpwd" || true
      halt_failed prereq "STRANDED_RELEASE_STATE: build-number commit ${bump_commit:0:12} is on origin but TF tag $TF_TAG was not pushed. Next safe command: git -C '$PROJECT_ROOT' push origin refs/tags/$TF_TAG"
    fi
    cd "$oldpwd" || halt_failed prereq "return to studio repo failed after version bump"
  fi

  # Phase 2 — Archive (Step 4).
  # Acquire priority-queue slot before running xcodebuild so TF/AS builds
  # jump ahead of queued Achilles task builds without preempting in-flight
  # ones (#267). Priority=release → rank 0 → sorts before task (rank 1).
  local ARCHIVE_PATH="/tmp/${SCHEME}-${NEW_BUILD_NUMBER}.xcarchive"
  local TF_TAG
  TF_TAG=$(tf_tag_name "$VERSION" "$NEW_BUILD_NUMBER") || halt_failed prereq "could not derive TF tag for version=$VERSION build=$NEW_BUILD_NUMBER"
  if [ -n "${STUDIO_TF_PUSH_PREPARED_CONTEXT_PATH:-}" ]; then
    mkdir -p "$(dirname "$STUDIO_TF_PUSH_PREPARED_CONTEXT_PATH")" 2>/dev/null || true
    jq -nc \
      --arg release_tag "$RELEASE_TAG" \
      --argjson build "$NEW_BUILD_NUMBER" \
      --arg version "$VERSION" \
      --arg scheme "$SCHEME" \
      --arg branch "$BRANCH" \
      --arg archive_path "$ARCHIVE_PATH" \
      --arg tf_tag "$TF_TAG" \
      --argjson prev_build "$LATEST_BUILD_NUMBER" \
      '{release_tag:$release_tag, build:$build, version:$version, scheme:$scheme, branch:$branch, archive_path:$archive_path, tf_tag:$tf_tag, prev_build:$prev_build, prepared:true}' \
      >"$STUDIO_TF_PUSH_PREPARED_CONTEXT_PATH"
  fi
  local archive_started_at archive_duration_s=0
  archive_started_at=$(date +%s)

  local _bq_dir _bq_entry="" _bq_lock="" _bq_slots=1
  _bq_dir="$(resolve_runtime_global)/build-queue/$NODE"
  if [ "$DRY_RUN_FLAG" != "1" ] && [ "${STUDIO_TF_PUSH_SKIP_NODE_PICK:-0}" != "1" ]; then
    _bq_slots=$(bq_node_slots "$NODE")
    _bq_entry=$(STUDIO_BUILD_PRIORITY=release bq_enqueue "$_bq_dir" \
      "release-${NEW_BUILD_NUMBER}" release xcodebuild asc,slack) \
      || halt_failed prereq "build-queue enqueue failed"
    local _bq_depth _bq_position _bq_queue_data
    _bq_depth=$(find "$_bq_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    case "$_bq_depth" in ''|*[!0-9]*) _bq_depth=1 ;; esac
    [ "$_bq_depth" -lt 1 ] && _bq_depth=1
    _bq_position=$(find "$_bq_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
      | sort | awk -v me="$_bq_entry" '{ if ($0 == me) { print NR; exit } }')
    case "$_bq_position" in ''|*[!0-9]*) _bq_position="$_bq_depth" ;; esac
    _bq_queue_data=$(printf '{"mode":"archive","node":"%s","position":%s,"depth":%s,"slots":%s,"priority":"release","secret_scope":"asc,slack"}' \
      "$NODE" "$_bq_position" "$_bq_depth" "$_bq_slots")
    emit_event_keyed studio release build_queue_position "$RELEASE_TAG" "$_bq_queue_data" >/dev/null 2>&1 || true
    trap 'bq_release_slot_lock "${_bq_lock:-}"; bq_release "${_bq_entry:-}"' EXIT INT TERM
    bq_wait "$_bq_dir" "$_bq_entry" "$_bq_slots" 1800 "$RELEASE_TAG" "$NODE" studio release \
      || halt_failed prereq "build-queue wait timed out"
    _bq_lock=$(bq_acquire_slot_lock "$(resolve_runtime_global)/xcodebuild-lock/$NODE" "$_bq_slots" 1800) \
      || halt_failed prereq "xcodebuild slot lock wait timed out"
  fi

  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would archive scheme=%s build=%s → %s\n' \
      "$SCHEME" "$NEW_BUILD_NUMBER" "$ARCHIVE_PATH" >&2
  else
    local archive_log="/tmp/${SCHEME}-${NEW_BUILD_NUMBER}-archive.log"
    (
      cd "$PROJECT_ROOT" || exit 1
      xcodebuild archive \
        -project "$PROJECT_RELPATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tee "$archive_log" | { [ -x "$XCPRETTY" ] && "$XCPRETTY" || cat; }
      exit "${PIPESTATUS[0]}"
    )
    archive_rc=$?
    if [ "$archive_rc" -ne 0 ]; then
      halt_failed archive "archive command failed with exit $archive_rc (log: $archive_log; excerpt: $(failure_excerpt "$archive_log"))"
    fi
    [ -d "$ARCHIVE_PATH" ] || halt_failed archive "archive command succeeded but xcarchive missing at $ARCHIVE_PATH (log: $archive_log; expected artifact path may be wrong)"
    archive_duration_s=$(( $(date +%s) - archive_started_at ))
  fi
  # Release the physical build slot as soon as archive completes; upload does not use xcodebuild.
  bq_release_slot_lock "${_bq_lock:-}"
  _bq_lock=""
  bq_release "${_bq_entry:-}"
  _bq_entry=""

  emit_release archive_completed "$(_json_obj \
    "build=$NEW_BUILD_NUMBER" \
    "version=$VERSION" \
    "scheme=$SCHEME" \
    "archive_path=$ARCHIVE_PATH" \
    "duration_s=$archive_duration_s")"

  # Phase 3 — Export + upload (Step 5).
  local upload_started_at upload_duration_s=0
  upload_started_at=$(date +%s)

  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would export + upload build %s to ASC\n' "$NEW_BUILD_NUMBER" >&2
  else
    local export_plist="/tmp/ExportOptions-${NEW_BUILD_NUMBER}.plist"
    cat > "$export_plist" <<'PLIST'
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
    local export_log="/tmp/${SCHEME}-${NEW_BUILD_NUMBER}-export.log"
    if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "/tmp/${SCHEME}-${NEW_BUILD_NUMBER}-export" \
        -exportOptionsPlist "$export_plist" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        >"$export_log" 2>&1; then
      halt_failed upload "xcodebuild -exportArchive exit non-zero (log: $export_log)"
    fi
    if grep -q '\*\* EXPORT FAILED \*\*' "$export_log" || grep -E '^error:' "$export_log" >/dev/null; then
      halt_failed upload "export reported failure (log: $export_log)"
    fi
    grep -qiE 'Export Succeeded|\*\* EXPORT SUCCEEDED \*\*' "$export_log" || halt_failed upload "no 'Export Succeeded' marker (log: $export_log)"
    upload_duration_s=$(( $(date +%s) - upload_started_at ))
  fi

  emit_release upload_completed "$(_json_obj \
    "build=$NEW_BUILD_NUMBER" \
    "version=$VERSION" \
    "duration_s=$upload_duration_s")"

  # Phase 4 — dSYM upload (Step 6).
  local dsym_succeeded=0 dsym_failed=0 dsym_skipped=0 dsym_reason=""

  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would upload dSYMs to Crashlytics\n' >&2
    dsym_reason="dry_run"
  else
    local upload_symbols
    upload_symbols=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 -type f -name upload-symbols 2>/dev/null \
                       | grep -m1 'firebase-ios-sdk/Crashlytics/upload-symbols' || true)
    if [ -z "$upload_symbols" ]; then
      dsym_reason="derived_data_clean"
    else
      local dsyms_dir="$ARCHIVE_PATH/dSYMs"
      shopt -s nullglob
      for dsym in "$dsyms_dir"/*.dSYM; do
        if "$upload_symbols" -gsp "$GSIP_PATH" -p ios "$dsym" 2>&1 | grep -q "Successfully uploaded"; then
          dsym_succeeded=$((dsym_succeeded + 1))
        else
          dsym_failed=$((dsym_failed + 1))
        fi
      done
      shopt -u nullglob
    fi
  fi

  local dsym_data
  if [ -n "$dsym_reason" ]; then
    dsym_data=$(_json_obj \
      "build=$NEW_BUILD_NUMBER" \
      "count_succeeded=$dsym_succeeded" \
      "count_failed=$dsym_failed" \
      "count_skipped=$dsym_skipped" \
      "reason=$dsym_reason")
  else
    dsym_data=$(jq -nc \
      --argjson build "$NEW_BUILD_NUMBER" \
      --argjson s "$dsym_succeeded" --argjson f "$dsym_failed" --argjson k "$dsym_skipped" \
      '{build:$build, count_succeeded:$s, count_failed:$f, count_skipped:$k, reason:null}')
  fi
  emit_release dsym_uploaded "$dsym_data"

  jq -nc \
    --arg release_tag "$RELEASE_TAG" \
    --argjson build "$NEW_BUILD_NUMBER" \
    --arg version "$VERSION" \
    --arg scheme "$SCHEME" \
    --arg branch "$BRANCH" \
    --arg archive_path "$ARCHIVE_PATH" \
    --arg tf_tag "$TF_TAG" \
    --argjson prev_build "$LATEST_BUILD_NUMBER" \
    '{release_tag:$release_tag, build:$build, version:$version, scheme:$scheme, branch:$branch, archive_path:$archive_path, tf_tag:$tf_tag, prev_build:$prev_build}'
}

cmd_withdraw_tf_tag() {
  DRY_RUN_FLAG=0
  local BUILD="" VERSION=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN_FLAG=1; shift ;;
      --build) BUILD="${2:?}"; shift 2 ;;
      --version) VERSION="${2:?}"; shift 2 ;;
      *) printf 'withdraw-tf-tag: unknown arg %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [ -n "$BUILD" ] || { printf 'withdraw-tf-tag: --build required\n' >&2; exit 2; }
  [ -n "$VERSION" ] || { printf 'withdraw-tf-tag: --version required\n' >&2; exit 2; }
  local OLD_TAG NEW_TAG
  OLD_TAG=$(tf_tag_name "$VERSION" "$BUILD") || exit 2
  NEW_TAG="${OLD_TAG}-WITHDRAWN"
  RELEASE_TAG="${STUDIO_RELEASE_TAG:-withdraw-${OLD_TAG}-$(date -u +%Y%m%d-%H%M%S)}"

  if [ "$DRY_RUN_FLAG" != "1" ] && [ "${STUDIO_TF_PUSH_LIVE:-0}" != "1" ]; then
    halt_failed prereq "STUDIO_TF_PUSH_LIVE=1 required to rename/push TF withdrawal tags"
  fi

  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would rename TF tag %s to %s and push withdrawn marker\n' "$OLD_TAG" "$NEW_TAG" >&2
    jq -nc --arg old "$OLD_TAG" --arg new "$NEW_TAG" '{old_tag:$old, withdrawn_tag:$new, dry_run:true}'
    return 0
  fi

  require_cmd git
  (
    cd "$PROJECT_ROOT" || exit 1
    git fetch --tags origin >/dev/null 2>&1 || exit 1
    local old_commit new_commit
    old_commit=$(local_tag_commit "$OLD_TAG")
    [ -n "$old_commit" ] || { printf 'withdraw-tf-tag: source tag %s not found\n' "$OLD_TAG" >&2; exit 1; }
    new_commit=$(local_tag_commit "$NEW_TAG")
    if [ -n "$new_commit" ] && [ "$new_commit" != "$old_commit" ]; then
      printf 'withdraw-tf-tag: %s already points at %s, not %s\n' "$NEW_TAG" "$new_commit" "$old_commit" >&2
      exit 1
    fi
    if [ -z "$new_commit" ]; then
      git tag -a "$NEW_TAG" "$old_commit" -m "WITHDRAWN: TestFlight build ${BUILD} (v${VERSION})"
    fi
    git push origin "refs/tags/${NEW_TAG}" || exit 1
    git push origin ":refs/tags/${OLD_TAG}" || exit 1
    git tag -d "$OLD_TAG" >/dev/null 2>&1 || true
  ) || halt_failed prereq "TF withdrawn tag rename failed"

  jq -nc --arg old "$OLD_TAG" --arg new "$NEW_TAG" '{old_tag:$old, withdrawn_tag:$new}'
}

cmd_appstore() {
  DRY_RUN_FLAG=0
  local BUILD="" VERSION="" RELEASE_NOTES_FILE="" WHATSNEW_FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN_FLAG=1; shift ;;
      --build) BUILD="${2:?}"; shift 2 ;;
      --version) VERSION="${2:?}"; shift 2 ;;
      --release-notes-file) RELEASE_NOTES_FILE="${2:?}"; shift 2 ;;
      --whatsnew-file) WHATSNEW_FILE="${2:?}"; shift 2 ;;
      *) printf 'appstore: unknown arg %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [ -n "$BUILD" ] || { printf 'appstore: --build required\n' >&2; exit 2; }
  [ -n "$VERSION" ] || { printf 'appstore: --version required\n' >&2; exit 2; }
  [ -n "$RELEASE_NOTES_FILE" ] && [ -r "$RELEASE_NOTES_FILE" ] || { printf 'appstore: --release-notes-file unreadable\n' >&2; exit 2; }
  [ -n "$WHATSNEW_FILE" ] && [ -r "$WHATSNEW_FILE" ] || { printf 'appstore: --whatsnew-file unreadable\n' >&2; exit 2; }

  local LIVE="${STUDIO_TF_PUSH_LIVE:-0}"
  RELEASE_TAG="${STUDIO_RELEASE_TAG:-release-${BUILD}-$(date -u +%Y%m%d-%H%M%S)}"
  if [ "$DRY_RUN_FLAG" != "1" ] && [ "$LIVE" != "1" ]; then
    halt_failed prereq "STUDIO_TF_PUSH_LIVE=1 required for non-dry-run appstore submission"
  fi
  if [ "$DRY_RUN_FLAG" != "1" ]; then
    [ -n "$APP_ID" ] || halt_failed prereq "STUDIO_TF_APP_ID missing in $RELEASE_CONFIG_FILE"
    [ -n "$ASC_KEY_ID" ] || halt_failed prereq "STUDIO_TF_ASC_KEY_ID missing in $RELEASE_CONFIG_FILE"
    [ -n "$ASC_ISSUER_ID" ] || halt_failed prereq "STUDIO_TF_ASC_ISSUER_ID missing in $RELEASE_CONFIG_FILE"
    [ -n "$ASC_KEY_PATH" ] || halt_failed prereq "STUDIO_TF_ASC_KEY_PATH missing and no key-id default could be derived"
    [ -r "$ASC_KEY_PATH" ] || halt_failed prereq "ASC key unreadable at $ASC_KEY_PATH"
  fi
  route_to_release_node

  local TAG="${BUILD}-zaps"
  local GH_REPO="${STUDIO_TF_GH_REPO:-turnip-ios/turnip-zaps}"
  local RELEASE_URL="https://github.com/${GH_REPO}/releases/tag/${TAG}"
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    printf 'studio-tf-push: [dry-run] would tag %s, push, gh release create --draft, ASC submit build=%s version=%s\n' \
      "$TAG" "$BUILD" "$VERSION" >&2
    appstore_notify_slack "$BUILD" "$VERSION" "$TAG" "$RELEASE_NOTES_FILE" "$WHATSNEW_FILE" "$RELEASE_URL" "$DRY_RUN_FLAG"
    return 0
  fi

  local appstore_branch
  appstore_branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  case "$appstore_branch" in
    main|master|trunk|develop|release/*) halt_failed prereq "active branch '$appstore_branch' is a base branch — R11 forbids studio-initiated push" ;;
  esac
  (
    cd "$PROJECT_ROOT" || exit 1
    git push -u origin HEAD || exit 1
    git tag "$TAG" || exit 1
    git push origin "$TAG" || exit 1
  ) || halt_failed prereq "git tag/push failed"

  gh auth switch --user vishal-zaps >/dev/null 2>&1 || true
  if ! gh release create "$TAG" \
      --repo "$GH_REPO" \
      --title "$TAG" \
      --notes-file "$RELEASE_NOTES_FILE" \
      --draft >/dev/null; then
    halt_failed prereq "gh release create failed"
  fi
  printf 'studio-tf-push: GH draft release: %s\n' "$RELEASE_URL" >&2

  local TOKEN
  TOKEN=$(mint_jwt)
  [ -n "$TOKEN" ] || halt_failed prereq "ASC JWT mint failed"

  local build_resp build_id
  build_resp=$(curl -sg "https://api.appstoreconnect.apple.com/v1/builds?filter[version]=${BUILD}&include=preReleaseVersion&limit=1" \
    -H "Authorization: Bearer $TOKEN")
  build_id=$(printf '%s' "$build_resp" | jq -r '.data[0].id // empty')
  [ -n "$build_id" ] || halt_failed prereq "ASC: build $BUILD not found"

  local versions_resp version_id
  versions_resp=$(curl -sg "https://api.appstoreconnect.apple.com/v1/apps/${APP_ID}/appStoreVersions?fields[appStoreVersions]=versionString,appStoreState,releaseType" \
    -H "Authorization: Bearer $TOKEN")
  version_id=$(printf '%s' "$versions_resp" \
    | jq -r --arg v "$VERSION" '.data[] | select(.attributes.appStoreState=="PREPARE_FOR_SUBMISSION" and .attributes.versionString==$v) | .id' \
    | head -1)
  if [ -z "$version_id" ]; then
    local create_resp
    create_resp=$(curl -s -X POST "https://api.appstoreconnect.apple.com/v1/appStoreVersions" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg v "$VERSION" --arg app "$APP_ID" '{data:{type:"appStoreVersions",attributes:{platform:"IOS",versionString:$v,releaseType:"MANUAL"},relationships:{app:{data:{type:"apps",id:$app}}}}}')")
    version_id=$(printf '%s' "$create_resp" | jq -r '.data.id // empty')
    [ -n "$version_id" ] || halt_failed prereq "ASC: appStoreVersion create failed: $create_resp"
  fi

  curl -s -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersions/${version_id}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg id "$version_id" --arg bid "$build_id" '{data:{type:"appStoreVersions",id:$id,attributes:{releaseType:"MANUAL"},relationships:{build:{data:{type:"builds",id:$bid}}}}}')" \
    >/dev/null

  local locs_resp whatsnew_text
  whatsnew_text=$(cat "$WHATSNEW_FILE")
  locs_resp=$(curl -s "https://api.appstoreconnect.apple.com/v1/appStoreVersions/${version_id}/appStoreVersionLocalizations" \
    -H "Authorization: Bearer $TOKEN")
  local loc_count=0
  for loc_id in $(printf '%s' "$locs_resp" | jq -r '.data[].id'); do
    curl -s -X PATCH "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/${loc_id}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg id "$loc_id" --arg w "$whatsnew_text" '{data:{type:"appStoreVersionLocalizations",id:$id,attributes:{whatsNew:$w}}}')" \
      >/dev/null
    loc_count=$((loc_count + 1))
  done

  printf 'studio-tf-push: appstore submission ready (build=%s version=%s, %d localizations updated)\n' \
    "$BUILD" "$VERSION" "$loc_count" >&2

  appstore_notify_slack "$BUILD" "$VERSION" "$TAG" "$RELEASE_NOTES_FILE" "$WHATSNEW_FILE" "$RELEASE_URL" "$DRY_RUN_FLAG"
  write_appstore_pending_marker "$BUILD" "$VERSION" "$TAG" "$version_id" "$build_id" "$RELEASE_URL" \
    || printf 'studio-tf-push: warning: pending App Store marker write failed; watcher will not thread lifecycle replies\n' >&2

  jq -nc \
    --arg release_tag "$RELEASE_TAG" \
    --arg tag "$TAG" \
    --arg github_release_url "$RELEASE_URL" \
    --arg version_id "$version_id" \
    --arg build_id "$build_id" \
    --arg slack_status "$APPSTORE_SLACK_STATUS" \
    --arg slack_channel "$APPSTORE_SLACK_CHANNEL_USED" \
    --arg slack_parent_ts "$APPSTORE_SLACK_PARENT_TS" \
    --argjson loc_count "$loc_count" \
    '{release_tag:$release_tag, tag:$tag, github_release_url:$github_release_url, version_id:$version_id, build_id:$build_id, localizations:$loc_count, slack:{status:$slack_status, channel_id:$slack_channel, message_ts:$slack_parent_ts}}'
}

case "${1:-}" in
  push|""|--dry-run|--scheme|--version|--background)
    [ "${1:-}" = "push" ] && shift
    cmd_push "$@" ;;
  appstore) shift; cmd_appstore "$@" ;;
  withdraw-tf-tag) shift; cmd_withdraw_tf_tag "$@" ;;
  emit) shift; cmd_emit "$@" ;;
  -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'studio-tf-push: unknown subcommand %s\n' "$1" >&2; exit 2 ;;
esac
