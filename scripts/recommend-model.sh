#!/usr/bin/env bash
# recommend-model.sh — deterministic task-level model recommendation.
#
# Usage:
#   scripts/recommend-model.sh --size xs|s|m|l --kind impl|test|docs|refactor|debug \
#       --cross-file-count <n> --novelty-score <0..3> [--preference best_result|fast_turnaround]

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CATALOG="$REPO_ROOT/_shared/schemas/model-catalog.yaml"
POLICY="$REPO_ROOT/_shared/rules/model-policy.yaml"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

SIZE=""
KIND=""
CROSS_FILE_COUNT=""
NOVELTY_SCORE=""
PREFERENCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --size) SIZE="${2:?}"; shift 2 ;;
    --kind) KIND="${2:?}"; shift 2 ;;
    --cross-file-count) CROSS_FILE_COUNT="${2:?}"; shift 2 ;;
    --novelty-score) NOVELTY_SCORE="${2:?}"; shift 2 ;;
    --preference) PREFERENCE="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'recommend-model: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

case "$SIZE" in xs|s|m|l) ;; *) printf 'recommend-model: --size must be xs|s|m|l\n' >&2; exit 2 ;; esac
case "$KIND" in impl|test|docs|refactor|debug) ;; *) printf 'recommend-model: --kind must be impl|test|docs|refactor|debug\n' >&2; exit 2 ;; esac
case "$CROSS_FILE_COUNT" in ''|*[!0-9]*) printf 'recommend-model: --cross-file-count must be a non-negative integer\n' >&2; exit 2 ;; esac
case "$NOVELTY_SCORE" in 0|1|2|3) ;; *) printf 'recommend-model: --novelty-score must be 0..3\n' >&2; exit 2 ;; esac

if [ -z "$PREFERENCE" ] && [ -f "$POLICY" ]; then
  PREFERENCE=$(grep -E '^default_preference:' "$POLICY" | head -1 | awk '{print $2}')
fi
[ -n "$PREFERENCE" ] || PREFERENCE="best_result"
case "$PREFERENCE" in best_result|fast_turnaround) ;; *) printf 'recommend-model: --preference must be best_result|fast_turnaround\n' >&2; exit 2 ;; esac

catalog_id() {
  local tier="$1"
  awk -v tier="$tier" '
    $0 ~ "^  " tier ":" { in_tier=1; next }
    in_tier && $0 ~ /^  [a-z]+:/ { in_tier=0 }
    in_tier && $1 == "id:" { print $2; exit }
  ' "$CATALOG" 2>/dev/null
}

best_tier="sonnet"
best_effort="medium"
reason="standard implementation against a bounded spec"

if [ "$KIND" = "debug" ] || [ "$NOVELTY_SCORE" -eq 3 ] || [ "$SIZE" = "l" ] || [ "$CROSS_FILE_COUNT" -ge 8 ]; then
  best_tier="opus"
  best_effort="high"
  reason="high-risk reasoning: kind=$KIND size=$SIZE cross_file_count=$CROSS_FILE_COUNT novelty_score=$NOVELTY_SCORE"
elif [ "$SIZE" = "xs" ] && [ "$NOVELTY_SCORE" -eq 0 ] && [ "$CROSS_FILE_COUNT" -le 2 ]; then
  case "$KIND" in
    docs|test|refactor)
      best_tier="haiku"
      best_effort="low"
      reason="mechanical low-novelty $KIND task"
      ;;
  esac
elif [ "$SIZE" = "s" ] && [ "$NOVELTY_SCORE" -eq 0 ] && [ "$CROSS_FILE_COUNT" -le 4 ]; then
  best_tier="sonnet"
  best_effort="low"
  reason="small low-novelty task with limited file spread"
fi

fast_tier="$best_tier"
fast_effort="$best_effort"
if [ "$best_tier" = "opus" ] && [ "$KIND" != "debug" ] && [ "$NOVELTY_SCORE" -lt 3 ] && [ "$CROSS_FILE_COUNT" -lt 8 ]; then
  fast_tier="sonnet"
  fast_effort="medium"
elif [ "$best_tier" = "sonnet" ] && [ "$SIZE" = "xs" ] && [ "$NOVELTY_SCORE" -eq 0 ]; then
  fast_tier="haiku"
  fast_effort="low"
fi

best_id=$(catalog_id "$best_tier")
fast_id=$(catalog_id "$fast_tier")
[ -n "$best_id" ] || best_id="$best_tier"
[ -n "$fast_id" ] || fast_id="$fast_tier"

selected_tier="$best_tier"
selected_id="$best_id"
selected_effort="$best_effort"
if [ "$PREFERENCE" = "fast_turnaround" ]; then
  selected_tier="$fast_tier"
  selected_id="$fast_id"
  selected_effort="$fast_effort"
fi

printf '{'
printf '"best_result":{"tier":"%s","model_id":"%s","reasoning_effort":"%s"},' "$best_tier" "$best_id" "$best_effort"
printf '"fast_turnaround":{"tier":"%s","model_id":"%s","reasoning_effort":"%s"},' "$fast_tier" "$fast_id" "$fast_effort"
printf '"selected":{"preference":"%s","tier":"%s","model_id":"%s","reasoning_effort":"%s"},' "$PREFERENCE" "$selected_tier" "$selected_id" "$selected_effort"
printf '"rationale":"%s"' "$reason"
printf '}\n'
