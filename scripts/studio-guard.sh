#!/usr/bin/env bash
# studio-guard.sh — pre-work "don't repeat yourself" probes.
#
# Before starting new work, grep git history, memory, and the backlog for
# prior mentions. Catches the "I forgot we shipped this" / "I forgot we
# tried this and it didn't work" / "I forgot there's an issue open" class
# of errors without loading context the model already has.
#
# Probes:
#   G1  Already-shipped   — git log + git tag + README Mermaid timeline
#   G2  Already-tried     — memory/*.md (user feedback + project notes)
#   G3  Already-in-backlog— gh issue list --state all (if gh authenticated)
#
# Usage:
#   scripts/studio-guard.sh "<search keywords>"        # human output
#   scripts/studio-guard.sh --json "<keywords>"        # machine-readable
#
# Exit codes:
#   0  — no prior mention found anywhere
#   1  — prior mention found in one or more channels (review output before proceeding)
#   2  — usage error (no keyword provided)
#
# Keywords are OR'd together. The probes are grep-only; no LLM calls.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

MODE=human
QUERY=""
for arg in "$@"; do
  case "$arg" in
    --json) MODE=json ;;
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    *) [ -z "$QUERY" ] && QUERY="$arg" || QUERY="$QUERY|$arg" ;;
  esac
done

if [ -z "$QUERY" ]; then
  printf 'usage: studio-guard.sh [--json] "<keywords>"\n' >&2
  exit 2
fi

PROJ_HASH=$(printf '%s' "$REPO_ROOT" | tr '/.' '-')
MEM_DIR="$HOME/.claude-personal/projects/$PROJ_HASH/memory"

g1_hits=""
g2_hits=""
g3_hits=""

# ──────────────────────────────────────────────────────────────────────────────
# G1 — Already shipped (git log + tags)
# ──────────────────────────────────────────────────────────────────────────────
probe_g1() {
  local log_hits tag_hits
  log_hits=$(git -C "$REPO_ROOT" log --all --oneline --grep "$QUERY" -i 2>/dev/null | head -10)
  tag_hits=$(git -C "$REPO_ROOT" tag | while read -r t; do
    msg=$(git -C "$REPO_ROOT" tag -l --format='%(contents:subject)' "$t" 2>/dev/null)
    if printf '%s %s' "$t" "$msg" | grep -qEi "$QUERY"; then
      printf '%s — %s\n' "$t" "$msg"
    fi
  done | head -5)
  if [ -n "$log_hits" ] || [ -n "$tag_hits" ]; then
    g1_hits=$(printf '%s\n%s' "$log_hits" "$tag_hits" | sed '/^$/d')
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# G2 — Already tried (memory)
# ──────────────────────────────────────────────────────────────────────────────
probe_g2() {
  [ -d "$MEM_DIR" ] || return
  local hits
  hits=$(grep -rliE "$QUERY" "$MEM_DIR" 2>/dev/null | head -5)
  if [ -n "$hits" ]; then
    g2_hits=$(printf '%s' "$hits" | while read -r f; do
      name=$(basename "$f" .md)
      desc=$(awk '/^description:/ {sub(/^description:[[:space:]]*/, ""); print; exit}' "$f")
      printf '  %s — %s\n' "$name" "$desc"
    done)
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# G3 — Already in backlog (gh issue list)
# ──────────────────────────────────────────────────────────────────────────────
probe_g3() {
  command -v gh >/dev/null 2>&1 || return
  with_login_home_for_github gh auth status >/dev/null 2>&1 || return
  local hits
  hits=$(with_login_home_for_github gh issue list --state all --search "$QUERY" --limit 10 --json number,title,state \
    --template '{{range .}}#{{.number}} [{{.state}}] {{.title}}{{"\n"}}{{end}}' 2>/dev/null || true)
  [ -n "$hits" ] && g3_hits="$hits"
}

probe_g1
probe_g2
probe_g3

total_hits=0
[ -n "$g1_hits" ] && total_hits=$((total_hits + 1))
[ -n "$g2_hits" ] && total_hits=$((total_hits + 1))
[ -n "$g3_hits" ] && total_hits=$((total_hits + 1))

if [ "$MODE" = json ]; then
  printf '{"query":"%s","hits":%d,"channels":{"g1_shipped":%s,"g2_tried":%s,"g3_backlog":%s}}\n' \
    "$QUERY" "$total_hits" \
    "$([ -n "$g1_hits" ] && echo true || echo false)" \
    "$([ -n "$g2_hits" ] && echo true || echo false)" \
    "$([ -n "$g3_hits" ] && echo true || echo false)"
else
  if [ $total_hits -eq 0 ]; then
    printf 'studio-guard: no prior mentions for "%s".\n' "$QUERY"
  else
    printf 'studio-guard: prior mentions found for "%s" — review before proceeding.\n\n' "$QUERY"
    [ -n "$g1_hits" ] && printf 'G1 already shipped (git log/tags):\n%s\n\n' "$g1_hits"
    [ -n "$g2_hits" ] && printf 'G2 already tried (memory):\n%s\n\n' "$g2_hits"
    [ -n "$g3_hits" ] && printf 'G3 already in backlog (gh issues):\n%s\n' "$g3_hits"
  fi
fi

[ $total_hits -eq 0 ] && exit 0 || exit 1
