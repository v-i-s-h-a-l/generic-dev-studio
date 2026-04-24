#!/usr/bin/env bash
# install.sh — idempotent installer for globally-installed agents + slash commands.
#
# Creates symlinks from this repo into ~/.claude/skills/ and ~/.claude/commands/
# so /chanakya, /achilles, /argus are reachable anywhere (typically your iOS
# project), and the corresponding slash commands work anywhere.
#
# The `studio` skill is deliberately NOT installed globally — it lives at
# .claude/skills/studio/ inside this repo and auto-loads only when your cwd
# is inside generic-dev-studio. Installing it globally would cause studio
# ops to misfire from unrelated projects.
#
# Usage:
#   scripts/install.sh            # apply, print summary
#   scripts/install.sh --dry-run  # print what would change, don't touch anything
#
# Idempotent: re-running after a repo pull just re-verifies the links.
# Pre-existing correct symlinks are skipped; pre-existing wrong files warn
# loudly (we never overwrite unknown content).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_CMDS="$HOME/.claude/commands"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Agents globally installed as skill roots. `studio` is omitted on purpose —
# it is project-scoped via .claude/skills/studio/.
AGENTS=(chanakya achilles argus _shared scripts)

# Commands globally installed. `studio-help` is omitted on purpose — it lives
# at .claude/commands/studio-help.md and only fires in this repo.
COMMANDS=(
  chanakya-help.md
  pushTFBuild.md
  fullSendToAppStore.md
)

created=0
skipped_ok=0
warned=0

ensure_dir() {
  local d="$1"
  if [ ! -d "$d" ]; then
    if [ $DRY_RUN -eq 1 ]; then
      printf '[dry-run] mkdir -p %s\n' "$d"
    else
      mkdir -p "$d"
    fi
  fi
}

link() {
  local src="$1" dst="$2"
  if [ ! -e "$src" ]; then
    printf 'MISSING SOURCE: %s (skipping %s)\n' "$src" "$dst" >&2
    warned=$((warned + 1))
    return
  fi
  if [ -L "$dst" ]; then
    local existing
    existing=$(readlink "$dst")
    if [ "$existing" = "$src" ]; then
      skipped_ok=$((skipped_ok + 1))
      return
    fi
    printf 'DRIFT: %s -> %s (expected %s) — leaving in place; remove manually if intended\n' \
      "$dst" "$existing" "$src" >&2
    warned=$((warned + 1))
    return
  fi
  if [ -e "$dst" ]; then
    printf 'CONFLICT: %s exists and is not a symlink — leaving in place\n' "$dst" >&2
    warned=$((warned + 1))
    return
  fi
  if [ $DRY_RUN -eq 1 ]; then
    printf '[dry-run] ln -s %s %s\n' "$src" "$dst"
  else
    ln -s "$src" "$dst"
  fi
  created=$((created + 1))
}

ensure_dir "$CLAUDE_SKILLS"
ensure_dir "$CLAUDE_CMDS"

for agent in "${AGENTS[@]}"; do
  link "$REPO_ROOT/$agent" "$CLAUDE_SKILLS/$agent"
done

for cmd in "${COMMANDS[@]}"; do
  link "$REPO_ROOT/commands/$cmd" "$CLAUDE_CMDS/$cmd"
done

printf '\n'
printf 'install.sh — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  created: %d  already-correct: %d  warnings: %d\n' \
  "$created" "$skipped_ok" "$warned"
if [ $DRY_RUN -eq 1 ]; then
  printf '  mode: dry-run (no changes applied)\n'
fi
[ $warned -gt 0 ] && exit 2 || exit 0
