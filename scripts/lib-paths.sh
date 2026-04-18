#!/usr/bin/env bash
# lib-paths.sh — sourced by every fleet script.
#
# Exposes:
#   resolve_project          prints the project slug (or errors out)
#   resolve_display_name     prints a friendly display name (git remote → slug)
#   resolve_inbox_root       prints the current project's achilles-inbox root
#   resolve_inbox_root_for   prints the achilles-inbox root for a given slug
#   resolve_runtime_global   prints the machine-global runtime root
#   resolve_push_queue       prints the per-project push-queue path
#   detect_stack             prints ios|web|rust|python|go|mixed|unknown
#   list_fleet_projects      prints every project with an active fleet
#   mtime                    cross-platform file mtime (stat -f %m / -c %Y)
#
# Project resolution order:
#   1. ACHILLES_PROJECT env var (escape hatch for cross-project dispatch / testing)
#   2. basename of git rev-parse --show-toplevel (normal case)
#   3. fail with a helpful hint to stderr
#
# Root resolution order:
#   1. ACHILLES_INBOX_ROOT env var (explicit override — bypasses project resolution)
#   2. $HOME/.dev-studio/<project>/.runtime/achilles-inbox

# No `set -e` here — sourced into scripts that may or may not want strict mode.

resolve_project() {
  if [ -n "${ACHILLES_PROJECT:-}" ]; then
    printf '%s\n' "$ACHILLES_PROJECT"
    return 0
  fi
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    cat >&2 <<EOF
error: no project resolved.
  Either (a) run this from inside a git repo so \`git rev-parse --show-toplevel\`
  picks up the project name, or (b) set ACHILLES_PROJECT=<slug> explicitly
  (e.g. ACHILLES_PROJECT=turnip-ios).
EOF
    return 1
  }
  basename "$top"
}

resolve_inbox_root() {
  if [ -n "${ACHILLES_INBOX_ROOT:-}" ]; then
    printf '%s\n' "$ACHILLES_INBOX_ROOT"
    return 0
  fi
  local project
  project=$(resolve_project) || return 1
  resolve_inbox_root_for "$project"
}

# Build the inbox root for a specific project slug without running project
# resolution. Used by --all-projects loops to avoid re-forking git per project.
resolve_inbox_root_for() {
  local project="${1:?usage: resolve_inbox_root_for <slug>}"
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/achilles-inbox"
}

resolve_runtime_global() {
  printf '%s\n' "$HOME/.dev-studio/.runtime"
}

resolve_push_queue() {
  local project
  project=$(resolve_project) || return 1
  printf '%s\n' "$HOME/.dev-studio/$project/.runtime/state/push-queue.jsonl"
}

# Friendly display name. Auto-derived in this order:
#   1. ACHILLES_DISPLAY_NAME env var (explicit override)
#   2. basename of `git remote get-url origin` minus .git (e.g., turnip-ios from
#      git@github.com:Turnip-gg/turnip-ios.git — cleaner than the local dir name)
#   3. resolve_project slug (final fallback)
# Falls through silently; never errors — callers can use the slug directly.
resolve_display_name() {
  if [ -n "${ACHILLES_DISPLAY_NAME:-}" ]; then
    printf '%s\n' "$ACHILLES_DISPLAY_NAME"
    return 0
  fi
  local url name
  url=$(git remote get-url origin 2>/dev/null) || url=""
  if [ -n "$url" ]; then
    name=$(basename "$url" .git 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "$url" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  resolve_project 2>/dev/null || echo "(unknown)"
}

# Detect the project's tech stack from filesystem fingerprints at the git
# toplevel. Pure read, no side effects. Output: one of
#   ios | web | rust | python | go | mixed | unknown
detect_stack() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "unknown"; return 0; }
  # Accumulate newline-separated hits so we don't depend on word-splitting
  # (word-splitting an unquoted var behaves differently in bash vs zsh).
  local hits=""
  if find "$top" -maxdepth 2 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) \
      -print -quit 2>/dev/null | grep -q .; then
    hits="${hits}ios"$'\n'
  fi
  [ -f "$top/package.json" ]   && hits="${hits}web"$'\n'
  [ -f "$top/Cargo.toml" ]     && hits="${hits}rust"$'\n'
  [ -f "$top/pyproject.toml" ] && hits="${hits}python"$'\n'
  [ -f "$top/setup.py" ]       && hits="${hits}python"$'\n'
  [ -f "$top/go.mod" ]         && hits="${hits}go"$'\n'
  local unique count
  unique=$(printf '%s' "$hits" | sort -u | sed '/^$/d')
  count=$(printf '%s\n' "$unique" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$count" in
    0) echo "unknown" ;;
    1) echo "$unique" ;;
    *) echo "mixed" ;;
  esac
}

# List every project that has a .runtime/achilles-inbox dir. One slug per line.
# Used by --all-projects flags.
list_fleet_projects() {
  local base="$HOME/.dev-studio"
  [ -d "$base" ] || return 0
  shopt -s nullglob
  for d in "$base"/*/.runtime/achilles-inbox; do
    # Strip $base/ prefix and everything from the first / onward to get the
    # project slug. Pure parameter expansion — no subshell forks.
    local project="${d#$base/}"
    project="${project%%/*}"
    # Skip the machine-global .runtime dir (matches the glob because it too
    # contains an achilles-inbox, historically; but it isn't a project).
    [ "$project" = ".runtime" ] && continue
    printf '%s\n' "$project"
  done
  shopt -u nullglob
}

# Portable file mtime (epoch seconds). macOS uses stat -f, GNU uses stat -c.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
