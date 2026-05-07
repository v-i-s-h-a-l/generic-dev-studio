#!/usr/bin/env bash
# Wrapper for interactive/assistant GitHub CLI calls from this repo.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib-studio-context.sh
. "$SCRIPT_DIR/lib-studio-context.sh"

command -v gh >/dev/null 2>&1 || {
  printf 'studio-gh: gh is required on PATH\n' >&2
  exit 127
}

_lp_load_project_env 2>/dev/null || true

if ! studio_context_resolve github-operation; then
  printf 'studio-gh: failed to resolve GitHub context\n' >&2
  exit 1
fi

github_home=$(studio_context_get_cached github_home)
host_profile=$(studio_context_get_cached host_profile)

if [ -n "$github_home" ] && [ "$github_home" != "${HOME:-}" ]; then
  printf 'studio: HOME normalized for GitHub op (parent=%s)\n' "$host_profile" >&2
fi

HOME="$github_home" gh "$@"
