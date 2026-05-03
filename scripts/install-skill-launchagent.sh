#!/usr/bin/env bash
# install-skill-launchagent.sh — render and install the skill-fanout LaunchAgent.
#
# Reads hosts/launchagents/com.dev-studio.skill-fanout.plist.template, fills in
# __REPO_ROOT__ / __HOME__ / __WATCH_PATHS__ from the current environment, and
# writes the rendered plist to ~/Library/LaunchAgents/com.dev-studio.skill-fanout.plist.
#
# WatchPaths is auto-populated from canonical skill roots (anything with a
# SKILL.md, portability.yaml, or routing.yaml file underneath) so the agent
# fires whenever the studio's skill graph changes — adding / removing /
# editing portability or skill content all trigger fan-out.
#
# Usage:
#   scripts/install-skill-launchagent.sh           # render + install + load
#   scripts/install-skill-launchagent.sh --uninstall
#   scripts/install-skill-launchagent.sh --dry-run # print rendered plist
#
# Requires: macOS (uses launchctl). On non-macOS hosts, exits 0 silently —
# the cross-session drift safety net falls back to the SessionStart freshness
# check + git post-merge hook.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

LABEL="com.dev-studio.skill-fanout"
TEMPLATE="$REPO_ROOT/hosts/launchagents/${LABEL}.plist.template"
DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

UNINSTALL=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
    *) printf 'install-skill-launchagent: unknown flag %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Non-macOS: no LaunchAgent equivalent; the SessionStart hook + git post-merge
# hook are the cross-session drift safety net there.
if [ "$(uname -s)" != "Darwin" ]; then
  printf 'install-skill-launchagent: non-macOS host (%s); skipping (SessionStart + post-merge hooks suffice)\n' "$(uname -s)" >&2
  exit 0
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    printf 'install-skill-launchagent: uninstalled %s\n' "$DEST"
  else
    printf 'install-skill-launchagent: no LaunchAgent at %s\n' "$DEST"
  fi
  exit 0
fi

[ -f "$TEMPLATE" ] || { printf 'install-skill-launchagent: template missing: %s\n' "$TEMPLATE" >&2; exit 2; }

# Build watch-paths block: every dir containing a SKILL.md / portability.yaml
# / routing.yaml plus the host registry. De-duplicated; sorted.
build_watch_paths() {
  local dirs
  dirs=$(
    cd "$REPO_ROOT" && \
    find core/v2/skills skills/owned skills/vendored \
         -maxdepth 4 \
         \( -name 'SKILL.md' -o -name 'portability.yaml' -o -name 'routing.yaml' \) \
         -type f 2>/dev/null \
      | while IFS= read -r f; do dirname "$f"; done \
      | sort -u
  )
  printf '        <string>%s/hosts/registry.yaml</string>\n' "$REPO_ROOT"
  printf '        <string>%s/_shared/standards</string>\n' "$REPO_ROOT"
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    printf '        <string>%s/%s</string>\n' "$REPO_ROOT" "$d"
  done <<<"$dirs"
}

WATCH_PATHS_BLOCK=$(build_watch_paths)

# Render in two passes:
#   1. sed substitutes single-line tokens (__REPO_ROOT__, __HOME__).
#   2. awk substitutes the multi-line WATCH_PATHS block using a temp file
#      (awk -v can't carry newlines).
WATCH_TMP=$(mktemp -t skill-fanout-watch.XXXXXX)
printf '%s\n' "$WATCH_PATHS_BLOCK" > "$WATCH_TMP"

# Use a sed delimiter unlikely to appear in paths.
SED_DELIM=$'\001'
rendered=$(
  sed -e "s${SED_DELIM}__REPO_ROOT__${SED_DELIM}${REPO_ROOT}${SED_DELIM}g" \
      -e "s${SED_DELIM}__HOME__${SED_DELIM}${HOME}${SED_DELIM}g" \
      "$TEMPLATE" \
    | awk -v watch_file="$WATCH_TMP" '
        BEGIN { while ((getline l < watch_file) > 0) watch_block = watch_block l "\n"; close(watch_file) }
        /^__WATCH_PATHS__$/ { printf "%s", watch_block; next }
        { print }
      '
)
rm -f "$WATCH_TMP"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$rendered"
  exit 0
fi

mkdir -p "$HOME/.dev-studio/.runtime/logs"
mkdir -p "$(dirname "$DEST")"

# Atomic write: tmpfile then rename.
tmpfile=$(mktemp -t skill-fanout-plist.XXXXXX)
printf '%s\n' "$rendered" > "$tmpfile"

# If existing plist matches byte-for-byte, no-op (preserves load state).
if [ -f "$DEST" ] && cmp -s "$tmpfile" "$DEST"; then
  rm -f "$tmpfile"
  printf 'install-skill-launchagent: plist unchanged at %s (already loaded)\n' "$DEST"
  exit 0
fi

# Replace plist; reload LaunchAgent.
launchctl unload "$DEST" 2>/dev/null || true
mv "$tmpfile" "$DEST"
launchctl load "$DEST"

printf 'install-skill-launchagent: installed %s\n' "$DEST"
printf '  WatchPaths: %d entries\n' "$(printf '%s\n' "$WATCH_PATHS_BLOCK" | wc -l | tr -d '[:space:]')"
printf '  Reload:     scripts/install-skill-launchagent.sh\n'
printf '  Uninstall:  scripts/install-skill-launchagent.sh --uninstall\n'

# Detect TCC blockage (macOS Sequoia+: launchd lacks Full Disk Access for
# files inside ~/Documents/Downloads/Desktop). Touch a watched file to force
# a fire, sleep past the throttle floor, and inspect stderr.
case "$REPO_ROOT" in
  "$HOME/Documents"/*|"$HOME/Downloads"/*|"$HOME/Desktop"/*)
    err_log="$HOME/.dev-studio/.runtime/logs/skill-fanout.err"
    : > "$err_log" 2>/dev/null
    touch "$REPO_ROOT/hosts/registry.yaml" 2>/dev/null || true
    sleep 2
    if [ -s "$err_log" ] && grep -q 'Operation not permitted' "$err_log" 2>/dev/null; then
      printf '\nWARNING — LaunchAgent fired but was blocked by macOS TCC:\n' >&2
      printf '  %s\n' "$(head -1 "$err_log")" >&2
      printf '  Repo is inside a TCC-protected directory. See hosts/launchagents/INSTALL.md\n' >&2
      printf '  for resolutions (relocate repo, grant launchd Full Disk Access, or skip).\n' >&2
      printf '  SessionStart freshness check + git post-merge hook still cover drift.\n' >&2
    fi
    ;;
esac
