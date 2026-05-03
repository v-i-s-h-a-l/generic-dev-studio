#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t phase-review-feedback.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Source only the extractor function; the full runner executes on load.
extractor="$TMPROOT/extractor.sh"
sed -n '/^compact_phase_review_feedback_json()/,/^}/p' "$ROOT/scripts/studio-chain-runner.sh" > "$extractor"
# shellcheck source=/dev/null
. "$extractor"

review="$TMPROOT/review.md"
cat > "$review" <<'MD'
PHASE_REVIEW_VERDICT=clean

## Warnings

- dash bullet
* star bullet with "quoted text"
1. numbered dot with "quoted text"
2) numbered paren

## Recommendations

1. recommendation with "quoted text"

## Fatal blockers

- must not be forwarded

## Accepted plan adjustments

- accepted adjustment with "quoted text"
MD

json=$(compact_phase_review_feedback_json "$review")

printf '%s\n' "$json" | jq -e '
  length == 6
  and any(.[]; .kind == "warnings" and .text == "dash bullet")
  and any(.[]; .kind == "warnings" and .text == "star bullet with \"quoted text\"")
  and any(.[]; .kind == "warnings" and .text == "numbered dot with \"quoted text\"")
  and any(.[]; .kind == "warnings" and .text == "numbered paren")
  and any(.[]; .kind == "recommendations" and .text == "recommendation with \"quoted text\"")
  and any(.[]; .kind == "accepted plan adjustments" and .text == "accepted adjustment with \"quoted text\"")
  and all(.[]; (.text | contains("\\\"") | not))
  and all(.[]; .text != "must not be forwarded")
' >/dev/null

printf 'PASS: phase-review feedback extraction preserves bullets and quotes\n'
