#!/usr/bin/env bash
# similarity-probe.sh — find existing tasks that might be near-duplicates of a
# proposed brief or intake item. Used at brief-time to populate `similar_to`
# (suspected, soft hint) and at intake-time to surface duplicate-fold options
# (the user can then set `duplicate_of` and skip task creation).
#
# Usage:
#   scripts/similarity-probe.sh --title "<text>" [--touchpoints "glob1,glob2"] [--exclude <task-id>] [--limit N]
#
# Emits up to N ranked matches, one per line:
#   <score>\t<legacy_task_id-or-empty>\t<uuid>\t<state>\t<title>
#
# Ranking heuristic (deliberately simple — Phase 2.7 knowledge layer will
# replace this with embedding-based search):
#   score = title_overlap_weight * J(title_tokens, existing_title_tokens)
#         + touchpoint_overlap_weight * J(touchpoints, existing_touchpoints)
#   where J(a,b) = |a ∩ b| / |a ∪ b|  (Jaccard)
#
# Title tokens: lowercase, split on non-alphanumeric, drop stopwords + tokens
# of length < 3. Touchpoint matching is exact glob-string equality (cheap;
# upgrades to glob-intersection are tracked in #197).
#
# Open + closed-recent tasks are both candidates. Tasks already marked
# duplicate_of or in state {archived, cancelled} are skipped (they are by
# definition not the canonical target for a fold).
#
# Default --limit is 5. Default scoring threshold is 0.20 — matches below
# that score are dropped. Override via SIMILARITY_THRESHOLD env var.
#
# Compatible with bash 3.2 (macOS stock).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
TITLE=""
TOUCHPOINTS=""
EXCLUDE=""
LIMIT=5
THRESHOLD="${SIMILARITY_THRESHOLD:-0.20}"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)       PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --title=*)       TITLE="${1#--title=}"; shift ;;
    --title)         TITLE="${2:?--title requires text}"; shift 2 ;;
    --touchpoints=*) TOUCHPOINTS="${1#--touchpoints=}"; shift ;;
    --touchpoints)   TOUCHPOINTS="${2:-}"; shift 2 ;;
    --exclude=*)     EXCLUDE="${1#--exclude=}"; shift ;;
    --exclude)       EXCLUDE="${2:-}"; shift 2 ;;
    --limit=*)       LIMIT="${1#--limit=}"; shift ;;
    --limit)         LIMIT="${2:-5}"; shift 2 ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$TITLE" ]; then
  printf 'error: --title is required\n' >&2
  exit 2
fi

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug>.\n' >&2
    exit 2
  }
fi

if [ -n "${ACHILLES_PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$ACHILLES_PROJECT_ROOT"
else
  PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
fi

TASKS_DIR="$PROJECT_ROOT/plans/tasks"
[ -d "$TASKS_DIR" ] || { printf 'no tasks dir; nothing to probe\n' >&2; exit 0; }

if ! command -v yq >/dev/null 2>&1; then
  printf 'error: yq (v4+) is required\n' >&2
  exit 2
fi

# Token-extract the candidate title once.
TITLE_TOKENS=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-z0-9' '\n' \
  | awk 'length($0) >= 3' \
  | grep -Ev '^(the|and|for|with|from|into|that|this|these|those|when|then|than|over|under|while|will|been|being|have|has|had|are|was|were|but|not|all|any|each|some|none|via|per|new|old|use|using|user|users)$' \
  | sort -u)

# Token-extract the candidate touchpoints (split on comma, trim).
TP_TOKENS=""
if [ -n "$TOUCHPOINTS" ]; then
  TP_TOKENS=$(printf '%s' "$TOUCHPOINTS" | tr ',' '\n' | awk '{gsub(/^ +| +$/,""); if (length($0)) print}' | sort -u)
fi

# Jaccard score between two newline-separated token sets. Stdout = float in [0,1].
jaccard() {
  local a="$1" b="$2"
  if [ -z "$a" ] && [ -z "$b" ]; then
    printf '0'
    return
  fi
  local inter union
  inter=$(comm -12 <(printf '%s\n' "$a" | sort -u) <(printf '%s\n' "$b" | sort -u) | awk 'NF' | wc -l | awk '{print $1}')
  union=$(printf '%s\n%s\n' "$a" "$b" | awk 'NF' | sort -u | wc -l | awk '{print $1}')
  if [ "$union" -eq 0 ]; then
    printf '0'
    return
  fi
  awk -v i="$inter" -v u="$union" 'BEGIN { printf "%.4f", i/u }'
}

TITLE_W=0.7
TOUCH_W=0.3

# Find candidate task files.
TASK_FILES_LIST=$(find "$TASKS_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | sort)
[ -z "$TASK_FILES_LIST" ] && exit 0

RESULTS=""

while IFS= read -r f; do
  [ -z "$f" ] && continue

  state=$(yq -r '.state // ""' "$f")
  case "$state" in
    archived|cancelled) continue ;;
  esac
  dup=$(yq -r '.duplicate_of // ""' "$f")
  [ -n "$dup" ] && continue

  uid=$(yq -r '.id // ""' "$f")
  [ -z "$uid" ] && continue
  [ -n "$EXCLUDE" ] && { [ "$uid" = "$EXCLUDE" ] || [ "$(yq -r '.legacy_task_id // ""' "$f")" = "$EXCLUDE" ]; } && continue

  legacy=$(yq -r '.legacy_task_id // ""' "$f")
  ex_title=$(yq -r '.title // ""' "$f")
  ex_tokens=$(printf '%s' "$ex_title" | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '\n' \
    | awk 'length($0) >= 3' \
    | grep -Ev '^(the|and|for|with|from|into|that|this|these|those|when|then|than|over|under|while|will|been|being|have|has|had|are|was|were|but|not|all|any|each|some|none|via|per|new|old|use|using|user|users)$' \
    | sort -u)

  ex_tp=$(yq -r '.affinity.touchpoints[]?' "$f" 2>/dev/null | sort -u)

  title_j=$(jaccard "$TITLE_TOKENS" "$ex_tokens")
  touch_j=$(jaccard "$TP_TOKENS" "$ex_tp")

  score=$(awk -v t="$title_j" -v p="$touch_j" -v tw="$TITLE_W" -v pw="$TOUCH_W" \
    'BEGIN { printf "%.4f", tw*t + pw*p }')

  # Threshold filter.
  pass=$(awk -v s="$score" -v th="$THRESHOLD" 'BEGIN { print (s+0 >= th+0) ? 1 : 0 }')
  [ "$pass" = "1" ] || continue

  RESULTS="$RESULTS$score	$legacy	$uid	$state	$ex_title"$'\n'
done <<EOF
$TASK_FILES_LIST
EOF

[ -z "$RESULTS" ] && exit 0

printf '%s' "$RESULTS" | awk 'NF' | sort -t$'\t' -k1,1 -r | head -n "$LIMIT"
