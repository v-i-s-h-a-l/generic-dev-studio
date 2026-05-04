#!/usr/bin/env bash
# Materialize the Codex worker capability manifest as real CLI flags.

set -euo pipefail
umask 022

dev_studio_root="${STUDIO_CODEX_WRITABLE_ROOT:-${HOME:?HOME required}/.dev-studio}"

exec codex exec \
  --ephemeral \
  --sandbox workspace-write \
  --add-dir "$dev_studio_root" \
  -c approval_policy=never \
  "$@"
