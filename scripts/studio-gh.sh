#!/usr/bin/env bash
# Wrapper for interactive/assistant GitHub CLI calls from this repo.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

command -v gh >/dev/null 2>&1 || {
  printf 'studio-gh: gh is required on PATH\n' >&2
  exit 127
}

with_login_home_for_github gh "$@"
