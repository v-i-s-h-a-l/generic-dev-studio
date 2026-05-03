#!/usr/bin/env bash
# verify-install.sh — reports drift between this repo and the global install.
# Read-only. Prints a table, exits non-zero if anything is wrong.
#
# Categories:
#   OK       — symlink points at this repo as expected
#   MISSING  — no symlink and no file at the install path
#   DRIFT    — symlink exists but points somewhere else
#   CONFLICT — a real file (not a symlink) is occupying the install path
#
# Usage:
#   scripts/verify-install.sh
#
# Exits 0 only if every expected link is OK.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_CMDS="$HOME/.claude/commands"

AGENTS=(_shared scripts hosts)
COMMANDS=(
  pushTFBuild.md
  fullSendToAppStore.md
)

bad=0

check() {
  local src="$1" dst="$2" label="$3"
  if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    printf '%-8s %s (expected -> %s)\n' "MISSING" "$dst" "$src"
    bad=$((bad + 1))
    return
  fi
  if [ -L "$dst" ]; then
    local target
    target=$(readlink "$dst")
    if [ "$target" = "$src" ]; then
      printf '%-8s %s\n' "OK" "$label"
    else
      printf '%-8s %s (-> %s, expected -> %s)\n' "DRIFT" "$dst" "$target" "$src"
      bad=$((bad + 1))
    fi
    return
  fi
  printf '%-8s %s (exists as regular file, expected symlink to %s)\n' \
    "CONFLICT" "$dst" "$src"
  bad=$((bad + 1))
}

printf 'verify-install.sh — repo=%s\n\n' "$REPO_ROOT"

printf 'Agents (%s/):\n' "$CLAUDE_SKILLS"
for agent in "${AGENTS[@]}"; do
  check "$REPO_ROOT/$agent" "$CLAUDE_SKILLS/$agent" "$agent"
done

printf '\nCommands (%s/):\n' "$CLAUDE_CMDS"
for cmd in "${COMMANDS[@]}"; do
  check "$REPO_ROOT/commands/$cmd" "$CLAUDE_CMDS/$cmd" "$cmd"
done

printf '\n'
if [ $bad -eq 0 ]; then
  printf 'All %d Claude Code links verified.\n' \
    $((${#AGENTS[@]} + ${#COMMANDS[@]}))
else
  printf '%d Claude Code drift item(s). Run ./scripts/install.sh to fix.\n' "$bad"
fi

# Audit all detected hosts via sync-host-skills.sh --audit-only
printf '\n--- multi-host skill audit ---\n'
"$SCRIPT_DIR/sync-host-skills.sh" --all --audit-only 2>&1 || bad=$((bad + 1))

[ $bad -gt 0 ] && exit 1 || exit 0
