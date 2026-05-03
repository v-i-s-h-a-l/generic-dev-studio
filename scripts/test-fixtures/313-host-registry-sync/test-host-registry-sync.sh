#!/usr/bin/env bash
# Fixture for #313: host skill sync deploys hosts/registry.yaml with companions.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t host-registry-sync-313.XXXXXX)
trap 'rm -rf "$TMPROOT"; rm -f "$ROOT/.codex/skills/studio"; rmdir "$ROOT/.codex/skills" 2>/dev/null || true' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"

if ! bash "$ROOT/scripts/sync-host-skills.sh" codex >"$TMPROOT/out" 2>"$TMPROOT/err"; then
  printf 'FAIL: sync-host-skills codex failed\n' >&2
  sed -n '1,120p' "$TMPROOT/err" >&2
  exit 1
fi

skill_dir="$HOME/.codex/skills"
if [ ! -L "$skill_dir/hosts" ]; then
  printf 'FAIL: hosts companion was not linked\n' >&2
  exit 1
fi
if [ "$(readlink "$skill_dir/hosts")" != "$ROOT/hosts" ]; then
  printf 'FAIL: hosts companion points at wrong target: %s\n' "$(readlink "$skill_dir/hosts")" >&2
  exit 1
fi
if [ ! -f "$skill_dir/hosts/registry.yaml" ]; then
  printf 'FAIL: deployed hosts companion does not expose registry.yaml\n' >&2
  exit 1
fi
if ! bash "$ROOT/scripts/sync-host-skills.sh" codex --audit-only >"$TMPROOT/audit.out" 2>"$TMPROOT/audit.err"; then
  printf 'FAIL: audit-only reported drift after sync\n' >&2
  sed -n '1,120p' "$TMPROOT/audit.err" >&2
  exit 1
fi

printf 'PASS: #313 host registry sync\n'
