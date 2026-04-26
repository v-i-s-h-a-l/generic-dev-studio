#!/usr/bin/env bash
# install-node-janitor-launchagent.sh — render + load the node-janitor LaunchAgent (#129).
#
# Mirrors install-skill-launchagent.sh. Renders the template at
# hosts/launchagents/dev.studio.node-janitor.plist.template into
# ~/Library/LaunchAgents/dev.studio.node-janitor.plist, substituting
# __JANITOR_SCRIPT__ + __HOME__, then loads the agent. RunAtLoad fires the
# first sweep immediately; StartInterval=21600 schedules every 6h thereafter.
#
# The agent points at the runtime-bin copy of node-janitor.sh (synced by
# sync-worker.sh into ~/.dev-studio/.runtime/bin/node-janitor.sh) when present;
# otherwise it points at the in-repo path, which the bootstrap caller passes
# explicitly. This decouples the LaunchAgent from the studio repo location on
# workers that may relocate it post-install.
#
# Usage:
#   scripts/install-node-janitor-launchagent.sh           # render + install + load
#   scripts/install-node-janitor-launchagent.sh --uninstall
#   scripts/install-node-janitor-launchagent.sh --dry-run # print rendered plist
#
# Requires: macOS (uses launchctl). On non-macOS hosts, exits 0 silently —
# the user is expected to wire equivalent cron there. The janitor script
# itself is portable.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

LABEL="dev.studio.node-janitor"
TEMPLATE="$REPO_ROOT/hosts/launchagents/${LABEL}.plist.template"
DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

UNINSTALL=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *) printf 'install-node-janitor-launchagent: unknown flag %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'install-node-janitor-launchagent: non-macOS host (%s); skipping (wire scripts/node-janitor.sh into cron manually)\n' "$(uname -s)" >&2
  exit 0
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    printf 'install-node-janitor-launchagent: uninstalled %s\n' "$DEST"
  else
    printf 'install-node-janitor-launchagent: no LaunchAgent at %s\n' "$DEST"
  fi
  exit 0
fi

[ -f "$TEMPLATE" ] || { printf 'install-node-janitor-launchagent: template missing: %s\n' "$TEMPLATE" >&2; exit 2; }

# Prefer the runtime-bin copy (synced by sync-worker.sh) so the LaunchAgent is
# decoupled from the studio repo location. Fall back to the in-repo path only
# if runtime-bin doesn't have it yet (first install before any sync).
RUNTIME_COPY="$HOME/.dev-studio/.runtime/bin/node-janitor.sh"
INREPO_COPY="$REPO_ROOT/scripts/node-janitor.sh"
if [ -x "$RUNTIME_COPY" ]; then
  JANITOR_SCRIPT="$RUNTIME_COPY"
elif [ -x "$INREPO_COPY" ]; then
  JANITOR_SCRIPT="$INREPO_COPY"
else
  printf 'install-node-janitor-launchagent: node-janitor.sh not found at %s or %s\n' \
    "$RUNTIME_COPY" "$INREPO_COPY" >&2
  exit 2
fi

SED_DELIM=$'\001'
rendered=$(
  sed -e "s${SED_DELIM}__JANITOR_SCRIPT__${SED_DELIM}${JANITOR_SCRIPT}${SED_DELIM}g" \
      -e "s${SED_DELIM}__HOME__${SED_DELIM}${HOME}${SED_DELIM}g" \
      "$TEMPLATE"
)

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$rendered"
  exit 0
fi

mkdir -p "$HOME/.dev-studio/.runtime/logs"
mkdir -p "$(dirname "$DEST")"

tmpfile=$(mktemp -t node-janitor-plist.XXXXXX)
printf '%s\n' "$rendered" > "$tmpfile"

if [ -f "$DEST" ] && cmp -s "$tmpfile" "$DEST"; then
  rm -f "$tmpfile"
  printf 'install-node-janitor-launchagent: plist unchanged at %s (already loaded)\n' "$DEST"
  exit 0
fi

launchctl unload "$DEST" 2>/dev/null || true
mv "$tmpfile" "$DEST"
launchctl load "$DEST"

printf 'install-node-janitor-launchagent: installed %s\n' "$DEST"
printf '  ExecPath:   %s\n' "$JANITOR_SCRIPT"
printf '  Schedule:   every 6h (StartInterval=21600), RunAtLoad=true\n'
printf '  Reload:     scripts/install-node-janitor-launchagent.sh\n'
printf '  Uninstall:  scripts/install-node-janitor-launchagent.sh --uninstall\n'
