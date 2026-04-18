#!/usr/bin/env bash
# analyze-collect.sh [--project <slug>] [--since <YYYY-MM-DD>]
#
# Gather mechanical stats for a usage-analysis pass (ANALYSIS.md). Prints to
# stdout — paste the output directly into today's analysis report, then add
# the human-judgment sections (patterns, public issues, "Wished I had").
#
# Reads the target project's event log, debriefs, reviews, and worker logs.
# Writes nothing. Defaults to the current project (from lib-paths.sh) and a
# 14-day window.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  if PROJECT=$(ACHILLES_PROJECT="" resolve_project 2>/dev/null); then :; else
    echo "error: no project resolved. Pass --project <slug> (e.g. turnip-ios)." >&2
    exit 1
  fi
fi

if [ -z "$SINCE" ]; then
  # 14 days back (portable date math: macOS = -v, GNU = -d)
  SINCE=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d)
fi

# Resolve project-memory path by looking for the one matching slug. The slug
# scheme is <repo-toplevel-path>/ → '-'-separated; we can't reverse-derive
# without the actual repo path, so glob ~/.claude/projects/ for a match.
find_memory() {
  local name="$1" d
  for d in "$HOME"/.claude/projects/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      *"-$name"|*"-${name}") printf '%s/memory\n' "$d"; return 0 ;;
    esac
  done
  return 1
}

MEMORY=$(find_memory "$PROJECT") || {
  echo "error: no project memory dir matched slug '$PROJECT' under ~/.claude/projects/" >&2
  echo "  Looked for a dir whose name ends in '-$PROJECT'." >&2
  exit 1
}

EVENT_DIR="$MEMORY/events"
REVIEW_DIR="$MEMORY/reviews"
INBOX_PROCESSED="$HOME/.dev-studio/$PROJECT/plans/chanakya-inbox/processed"
FLEET_ROOT="$HOME/.dev-studio/$PROJECT/.runtime/achilles-inbox"

echo "# analyze-collect: $PROJECT"
echo "window: $SINCE → $(date -u +%Y-%m-%d)"
echo "memory: $MEMORY"
echo

echo "## Event counts (by type)"
if [ -d "$EVENT_DIR" ]; then
  # JSONL filenames are YYYY-MM-DD.jsonl — lexicographic compare == date compare.
  out=$(
    for f in "$EVENT_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      d=$(basename "$f" .jsonl)
      [ "$d" \< "$SINCE" ] && continue
      cat "$f"
    done | sed -n 's/.*"event":"\([^"]*\)".*/\1/p' | sort | uniq -c | sort -rn
  )
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "(no events in window; earliest file = $(ls "$EVENT_DIR" 2>/dev/null | head -1 || echo none))"
  fi
else
  echo "(no event dir at $EVENT_DIR)"
fi
echo

echo "## Review verdict rates"
if [ -d "$REVIEW_DIR" ]; then
  approved=$(grep -l '^verdict: approved' "$REVIEW_DIR"/*.md "$REVIEW_DIR"/archive/*.md 2>/dev/null | wc -l | tr -d ' ')
  flagged=$(grep -l '^verdict: flagged' "$REVIEW_DIR"/*.md "$REVIEW_DIR"/archive/*.md 2>/dev/null | wc -l | tr -d ' ')
  blocked=$(grep -l '^verdict: blocked' "$REVIEW_DIR"/*.md "$REVIEW_DIR"/archive/*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "approved: $approved"
  echo "flagged:  $flagged"
  echo "blocked:  $blocked"
else
  echo "(no review dir at $REVIEW_DIR)"
fi
echo

echo "## Debriefs processed"
if [ -d "$INBOX_PROCESSED" ]; then
  count=$(find "$INBOX_PROCESSED" -name '*-debrief.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "count: $count"
  echo "most recent:"
  find "$INBOX_PROCESSED" -name '*-debrief.md' -type f 2>/dev/null \
    | xargs ls -lt 2>/dev/null | head -5 | awk '{print "  "$NF}'
else
  echo "(no inbox at $INBOX_PROCESSED)"
fi
echo

echo "## Worker activity"
if [ -d "$FLEET_ROOT" ]; then
  for d in "$FLEET_ROOT"/worker-*/; do
    [ -d "$d" ] || continue
    N=$(basename "$d" | sed 's/worker-//')
    done_ct=$(find "$d/done" -name '*.task' 2>/dev/null | wc -l | tr -d ' ')
    rescue_ct=$(find "$d/rescue" -name '*.task' 2>/dev/null | wc -l | tr -d ' ')
    echo "worker-$N: done=$done_ct rescue=$rescue_ct"
  done
else
  echo "(no fleet root at $FLEET_ROOT)"
fi
echo

echo "## Next steps"
echo "- Read the debriefs' 'Key Learnings' + 'Blockers' sections for patterns."
echo "- Diff the flag/block counts by rule (grep review files for 'rule:' frontmatter)."
echo "- Fill in the template sections in ~/.dev-studio/$PROJECT/analysis/$(date -u +%Y-%m-%d).md"
echo "- Keep the '## Wished I had' section first-class — that's what feeds #11."
