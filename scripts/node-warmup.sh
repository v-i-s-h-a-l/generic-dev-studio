#!/usr/bin/env bash
# node-warmup.sh — asynchronously prime a worker node for source/build dispatch.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-source-sync.sh
. "$SCRIPT_DIR/lib-source-sync.sh"

NODE_ID="${1:?usage: node-warmup.sh <node-id> [<project-slug>]}"
PROJECT="${2:-$(resolve_project 2>/dev/null || printf unknown)}"

if node_is_self "$NODE_ID"; then
  printf 'node-warmup: node %s is local; no remote warm-up needed\n' "$NODE_ID" >&2
  exit 0
fi

WORKTREE="${NODE_WARMUP_WORKTREE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$WORKTREE" ] || { printf 'node-warmup: worktree not found: %s\n' "$WORKTREE" >&2; exit 2; }

LOG_DIR="$(resolve_project_root_for "$PROJECT")/.runtime/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

REL_WORKTREE=$(NODE_SOURCE_SYNC_MODE=full sourcesync_push "$NODE_ID" "$WORKTREE") || {
  printf 'node-warmup: source sync failed for %s\n' "$NODE_ID" >&2
  exit 1
}
Q_WORKTREE=$(sourcesync_remote_quoted "$REL_WORKTREE")

REMOTE_CMD='[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)";'
REMOTE_CMD+=' [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)";'
REMOTE_CMD+=' cd '"$Q_WORKTREE"';'
REMOTE_CMD+=' if [ -f Package.swift ]; then swift package resolve >/dev/null 2>&1 || true; fi;'

SCHEME="${NODE_WARMUP_SCHEME:-}"
DESTINATION="${NODE_WARMUP_DESTINATION:-}"
PROJECT_RELPATH="${NODE_WARMUP_PROJECT_RELPATH:-}"
if [ -n "$SCHEME" ] && [ -n "$DESTINATION" ]; then
  REMOTE_CMD+=' if command -v xcodebuild >/dev/null 2>&1; then xcodebuild -resolvePackageDependencies'
  case "$PROJECT_RELPATH" in
    *.xcworkspace) REMOTE_CMD+=' -workspace '"$(printf '%q' "$PROJECT_RELPATH")" ;;
    *.xcodeproj)   REMOTE_CMD+=' -project '"$(printf '%q' "$PROJECT_RELPATH")" ;;
  esac
  REMOTE_CMD+=' -scheme '"$(printf '%q' "$SCHEME")"' >/dev/null 2>&1 || true; fi;'
fi

NODE_BUILD_TIMEOUT="${NODE_WARMUP_TIMEOUT:-900}" \
  "$SCRIPT_DIR/node-dispatch.sh" "$NODE_ID" sh -c "$REMOTE_CMD" \
  >"$LOG_DIR/node-warmup-${NODE_ID}.log" 2>&1
