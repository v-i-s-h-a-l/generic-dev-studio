#!/usr/bin/env bash
# install-disk-headroom-launchagent.sh — render + load the disk-headroom LaunchAgent.
#
# Periodically invokes `scripts/sweep-janitor.sh --all-projects disk-headroom`
# so disk-space reclamation happens before headroom runs out, rather than
# on-demand after a build has already wedged. Pairs with #826 (the
# disk-headroom subcommand itself) and #821 (the original ask).
#
# Layout mirrors install-node-janitor-launchagent.sh:
#   - Template at hosts/launchagents/dev.studio.disk-headroom.plist.template
#   - Prefers the runtime-bin copy of sweep-janitor.sh (synced by sync-worker)
#   - Substitutes __SWEEP_SCRIPT__ + __HOME__
#   - Loads at install + every 4h thereafter
#
# Usage:
#   scripts/install-disk-headroom-launchagent.sh           # render + install + load
#   scripts/install-disk-headroom-launchagent.sh --uninstall
#   scripts/install-disk-headroom-launchagent.sh --dry-run # print rendered plist
#
# Requires: macOS (launchctl). On non-macOS hosts, exits 0 silently; users
# wire equivalent cron there. sweep-janitor.sh itself is portable.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

LABEL="dev.studio.disk-headroom"
TEMPLATE="$REPO_ROOT/hosts/launchagents/${LABEL}.plist.template"
DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

UNINSTALL=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'install-disk-headroom-launchagent: unknown flag %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'install-disk-headroom-launchagent: non-macOS host (%s); skipping (wire scripts/sweep-janitor.sh --all-projects disk-headroom into cron manually)\n' "$(uname -s)" >&2
  exit 0
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    printf 'install-disk-headroom-launchagent: uninstalled %s\n' "$DEST"
  else
    printf 'install-disk-headroom-launchagent: no LaunchAgent at %s\n' "$DEST"
  fi
  exit 0
fi

[ -f "$TEMPLATE" ] || { printf 'install-disk-headroom-launchagent: template missing: %s\n' "$TEMPLATE" >&2; exit 2; }

# Prefer the runtime-bin copy so the LaunchAgent is decoupled from the studio
# repo location; fall back to in-repo on first install before sync-worker has
# mirrored it.
# lint-runtime-paths:allow next-line — installer runs before resolver layer is mirrored; matches install-node-janitor-launchagent.sh shape.
RUNTIME_COPY="$HOME/.dev-studio/.runtime/bin/sweep-janitor.sh"
INREPO_COPY="$REPO_ROOT/scripts/sweep-janitor.sh"
if [ -x "$RUNTIME_COPY" ]; then
  SWEEP_SCRIPT="$RUNTIME_COPY"
elif [ -x "$INREPO_COPY" ]; then
  SWEEP_SCRIPT="$INREPO_COPY"
else
  printf 'install-disk-headroom-launchagent: sweep-janitor.sh not found at %s or %s\n' \
    "$RUNTIME_COPY" "$INREPO_COPY" >&2
  exit 2
fi

SED_DELIM=$'\001'
rendered=$(sed \
  -e "s${SED_DELIM}__SWEEP_SCRIPT__${SED_DELIM}${SWEEP_SCRIPT}${SED_DELIM}g" \
  -e "s${SED_DELIM}__HOME__${SED_DELIM}${HOME}${SED_DELIM}g" \
  "$TEMPLATE")

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$rendered"
  exit 0
fi

# Ensure log destinations exist (LaunchAgent won't create the parent dir).
# lint-runtime-paths:allow next-line — installer-side mkdir of the log dir; matches install-node-janitor-launchagent.sh shape.
mkdir -p "$HOME/.dev-studio/.runtime/logs" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
printf '%s\n' "$rendered" > "$DEST"

# Unload first in case an older copy is registered; ignore errors.
launchctl unload "$DEST" 2>/dev/null || true
if launchctl load "$DEST" 2>/dev/null; then
  printf 'install-disk-headroom-launchagent: loaded %s (interval 4h, RunAtLoad=true)\n' "$DEST"
else
  printf 'install-disk-headroom-launchagent: launchctl load failed for %s\n' "$DEST" >&2
  exit 2
fi
