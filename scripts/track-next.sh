#!/usr/bin/env bash
# track-next.sh <track-name>
#
# Picks the next unassigned open issue for the given track label, assigns it
# to the authenticated GH user, checks out the track branch, and prints a
# structured work directive that Claude reads to start the issue.
#
# Exit 0  — issue claimed; directive printed to stdout
# Exit 1  — no open unassigned issues remain (track complete)
# Exit 2  — bad args / gh auth failure

set -euo pipefail

TRACK="${1:?usage: track-next.sh <track-name>}"
REPO="v-i-s-h-a-l/generic-dev-studio"
LABEL="track:${TRACK}"
BRANCH="track/${TRACK}"

# Verify branch exists
if ! git show-ref --verify --quiet "refs/heads/${BRANCH}" 2>/dev/null && \
   ! git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}" 2>/dev/null; then
  printf 'error: branch %s does not exist\n' "$BRANCH" >&2
  exit 2
fi

# Checkout track branch (no-op if already on it)
current=$(git branch --show-current 2>/dev/null || true)
if [ "$current" != "$BRANCH" ]; then
  git checkout "$BRANCH" --quiet
fi

# Pull latest from origin (best-effort — don't fail if offline)
git pull --quiet origin "$BRANCH" 2>/dev/null || true

# Find next unassigned open issue for this track
issue_json=$(gh issue list \
  --repo "$REPO" \
  --label "$LABEL" \
  --assignee "" \
  --state open \
  --limit 1 \
  --json number,title,body 2>/dev/null)

if [ -z "$issue_json" ] || [ "$issue_json" = "[]" ]; then
  printf 'TRACK_COMPLETE track=%s\n' "$TRACK"
  exit 1
fi

number=$(printf '%s' "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['number'])")
title=$(printf '%s' "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['title'])")
body=$(printf '%s' "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['body'])")

# Claim it
gh issue edit "$number" --add-assignee "@me" --repo "$REPO" >/dev/null

printf '=== TRACK WORK DIRECTIVE ===\n'
printf 'track:   %s\n' "$TRACK"
printf 'branch:  %s\n' "$BRANCH"
printf 'issue:   #%s — %s\n' "$number" "$title"
printf 'url:     https://github.com/%s/issues/%s\n' "$REPO" "$number"
printf '\n--- ISSUE BODY ---\n'
printf '%s\n' "$body"
printf '\n--- END DIRECTIVE ---\n'
printf 'Assigned to @me. Implement, commit to %s, close #%s when done.\n' "$BRANCH" "$number"
