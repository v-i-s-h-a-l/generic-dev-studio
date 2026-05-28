#!/usr/bin/env bash
# Materialize the Codex worker capability manifest as real CLI flags.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

resolve_codex_worker_home() {
  local login_home
  if [ -n "${CODEX_WORKER_HOME:-}" ]; then
    printf '%s\n' "$CODEX_WORKER_HOME"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
  elif [ -n "${HOME:-}" ] && [ -d "$HOME/.codex" ]; then
    printf '%s\n' "$HOME/.codex"
  else
    login_home=$(resolve_user_login_home 2>/dev/null || true)
    if [ -n "$login_home" ] && [ -d "$login_home/.codex" ]; then
      printf '%s\n' "$login_home/.codex"
    fi
  fi
}

codex_home=$(resolve_codex_worker_home)
[ -n "$codex_home" ] && [ -d "$codex_home" ] || {
  printf 'codex-worker-exec: Codex auth home not found; set CODEX_WORKER_HOME or CODEX_HOME to a directory containing Codex credentials\n' >&2
  exit 70
}

dev_studio_root="${STUDIO_CODEX_WRITABLE_ROOT:-${HOME:?HOME required}/.dev-studio}"
worker_sandbox="${STUDIO_CODEX_WORKER_SANDBOX:-workspace-write}"

exec env CODEX_HOME="$codex_home" codex exec \
  --ephemeral \
  --sandbox "$worker_sandbox" \
  --add-dir "$dev_studio_root" \
  -c approval_policy=never \
  "$@"
