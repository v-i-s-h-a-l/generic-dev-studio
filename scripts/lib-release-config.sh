#!/usr/bin/env bash
# lib-release-config.sh — project-scoped release config/secrets resolver.
#
# Release scripts may run from the studio repo while operating on a user
# project. Keep project credentials under ~/.dev-studio/<project>/, not under
# agent-owned config directories.

# No set -e here; callers source this from scripts with different strictness.

RELEASE_CONFIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$RELEASE_CONFIG_LIB_DIR/lib-paths.sh" 2>/dev/null || true

release_project_slug() {
  if [ -n "${STUDIO_RELEASE_PROJECT:-}" ]; then
    printf '%s\n' "$STUDIO_RELEASE_PROJECT"
    return 0
  fi
  if [ -n "${STUDIO_TF_PROJECT_SLUG:-}" ]; then
    printf '%s\n' "$STUDIO_TF_PROJECT_SLUG"
    return 0
  fi
  resolve_project
}

load_release_config() {
  RELEASE_PROJECT=$(release_project_slug) || return 1
  RELEASE_PROJECT_ROOT=$(resolve_project_root_for "$RELEASE_PROJECT") || return 1
  RELEASE_CONFIG_DIR="$RELEASE_PROJECT_ROOT/config"
  RELEASE_SECRETS_DIR="$RELEASE_PROJECT_ROOT/secrets"
  RELEASE_CONFIG_FILE="${STUDIO_RELEASE_CONFIG_FILE:-$RELEASE_CONFIG_DIR/release.env}"

  if [ -r "$RELEASE_CONFIG_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$RELEASE_CONFIG_FILE"
    set +a
  fi

  export RELEASE_PROJECT RELEASE_PROJECT_ROOT RELEASE_CONFIG_DIR RELEASE_SECRETS_DIR RELEASE_CONFIG_FILE
}

release_slack_token_file() {
  printf '%s\n' "${STUDIO_SLACK_TOKEN_FILE:-$RELEASE_SECRETS_DIR/slack-bot-token}"
}

release_asc_key_path() {
  local key_id="${1:-}"
  if [ -n "${STUDIO_TF_ASC_KEY_PATH:-}" ]; then
    printf '%s\n' "$STUDIO_TF_ASC_KEY_PATH"
    return 0
  fi
  [ -n "$key_id" ] || return 1
  printf '%s\n' "$RELEASE_SECRETS_DIR/appstoreconnect/AuthKey_${key_id}.p8"
}
