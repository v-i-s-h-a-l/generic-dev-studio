#!/usr/bin/env bash
# init-worker-manifest.sh — emit a default per-project worker manifest.
#
# Idempotent: refuses to overwrite an existing manifest unless --force.
#
# Usage
#   scripts/init-worker-manifest.sh           # create if missing
#   scripts/init-worker-manifest.sh --force   # overwrite

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
MANIFEST="$(resolve_project_root_for "$PROJECT")/worker-manifest.yaml"

if [ -f "$MANIFEST" ] && [ "$FORCE" = "0" ]; then
  printf 'manifest already exists: %s\n' "$MANIFEST" >&2
  printf 'use --force to overwrite\n' >&2
  exit 0
fi

mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<'YAML'
# worker-manifest.yaml — what every registered worker for this project
# should have. Read by scripts/sync-worker.sh (per-worker apply) and
# scripts/sync-workers-all.sh (fan-out across the fleet).
#
# Schema 1.

schema: 1

# Homebrew packages the worker needs. `required` blocks the gate when
# missing (sync-worker exits 3 if it can't install them). `optional`
# surfaces as drift but doesn't fail.
brew_packages:
  required:
    - jq            # node-dispatch reads nodes.json
    - yq            # sync-host-skills.sh, manifest parsing
    - rsync         # source-sync auto-rsync (#127)
    - coreutils     # gtimeout for SSH probe bounds
    - git
  optional:
    - fswatch       # only if the worker ever runs Achilles workers locally

# Minimum Xcode version the worker should run for parity. sync-worker
# warns (drift event) if the worker is below this; doesn't auto-fix
# (Xcode install is App Store / Apple-ID gated). Use `node-parity.sh
# --fix` (#131) when you want the auto-install path.
#
# Leave empty / omit if you don't run xcodebuild on workers.
xcode_version_min: ""

# Future: launchd agents to install on the worker (heartbeat, local
# janitor, etc.). Today this is empty — workers stay passive per the
# architecture; the manager schedules everything from its side.
launchd_agents: []

# Skill hosts to fan out on this worker. Each entry is a host slug from
# hosts/registry.yaml. sync-worker.sh rsyncs skill content to the worker
# then runs sync-host-skills.sh --all so the worker's per-host discovery
# dirs (e.g. ~/.claude/skills/, ~/.codex/skills/) get proper symlinks.
#
# Leave empty or omit to skip skill propagation entirely.
skills:
  hosts:
    - claude-code
    - codex
YAML
printf 'wrote default manifest: %s\n' "$MANIFEST"
printf 'edit it to declare what your fleet needs, then:\n'
printf '  scripts/sync-workers-all.sh           # fan out across registered workers\n'
printf '  scripts/sync-worker.sh <id>           # apply to one worker\n'
printf '  scripts/schedule-worker-sync.sh --install   # nightly cron, opt-in\n'
