#!/usr/bin/env bash
# install.sh — idempotent installer for shared studio companions + slash commands.
#
# Creates symlinks from this repo into ~/.claude/skills/ and ~/.claude/commands/
# for shared companions and remaining Claude slash-command wrappers.
#
# After Claude Code-specific setup, runs sync-host-skills.sh --all to fan out
# skills to every detected host (Codex, Gemini, Cursor, etc.) whose binary is
# on PATH. New hosts added to hosts/registry.yaml are picked up automatically.
#
# The `dev-studio` command is installed globally for Claude Code. The
# `dev-studio` skill is installed globally for non-Claude hosts by
# sync-host-skills.sh so users can invoke the studio from the project they are
# actually working on without duplicate Claude slash-command picker rows.
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

# Shared companion roots. A10 removed the v1 top-level agent skills; v2 skill
# discovery is handled by sync-host-skills.sh from core/v2/skills.
AGENTS=(_shared scripts hosts)

# Commands globally installed. `dev-studio` is global; `studio-help` stays
# repo-local because it only opens this repo's docs page.
COMMANDS=(
  dev-studio.md
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

# Fan out to all detected hosts (Codex, Gemini, Cursor, etc.)
printf '\n--- multi-host skill fan-out ---\n'
if [ $DRY_RUN -eq 1 ]; then
  "$SCRIPT_DIR/sync-host-skills.sh" --all --dry-run 2>&1 || printf 'install.sh: multi-host fan-out reported drift; run sync-host-skills.sh --all to inspect\n'
else
  "$SCRIPT_DIR/sync-host-skills.sh" --all 2>&1 || printf 'install.sh: multi-host fan-out reported drift; run sync-host-skills.sh --all to inspect\n'
fi

[ $warned -gt 0 ] && exit 2 || exit 0
