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
# Fetch ALL open unassigned issues on the track. We sort by issue number
# ascending in python below — foundational work is almost always filed
# first, so lowest number is a good tiebreaker when Blocked-by is absent.
# The Blocked-by filter is the correctness guarantee; number-order is the
# pick heuristic when multiple issues are unblocked.
issue_json=$(gh issue list \
  --repo "$REPO" \
  --label "$LABEL" \
  --assignee "" \
  --state open \
  --limit 100 \
  --json number,title,body 2>/dev/null)

if [ -z "$issue_json" ] || [ "$issue_json" = "[]" ]; then
  printf 'TRACK_COMPLETE track=%s\n' "$TRACK"
  exit 1
fi

# Pick the first issue whose "Blocked by: #N" references are all closed.
# "Blocked by:" may appear on its own line, inside tables, or inline —
# pattern match case-insensitively on `Blocked by:` followed by #<digits>,
# take the union of all such numbers, and check each is closed via gh.
pick_json=$(REPO="$REPO" ISSUES_JSON="$issue_json" python3 <<'PY'
import json, os, re, subprocess, sys

issues = json.loads(os.environ["ISSUES_JSON"])
issues.sort(key=lambda it: it["number"])
repo = os.environ["REPO"]
blocked_line_pat = re.compile(r'Blocked by:([^\n]+)', re.IGNORECASE)
num_pat = re.compile(r'#(\d+)')

def is_open(n):
    try:
        r = subprocess.run(
            ["gh", "issue", "view", str(n), "--repo", repo, "--json", "state"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(r.stdout)["state"] == "OPEN"
    except subprocess.CalledProcessError as e:
        # Issue not found or auth failure — treat as closed so we don't
        # block forever on a stale dep reference. The claim step will
        # surface real problems.
        return False

for it in issues:
    body = it.get("body") or ""
    deps = set()
    for m in blocked_line_pat.finditer(body):
        for n in num_pat.findall(m.group(1)):
            deps.add(int(n))
    if not any(is_open(n) for n in deps):
        print(json.dumps(it))
        sys.exit(0)

# All remaining issues are blocked.
sys.exit(42)
PY
) || pick_rc=$?

if [ "${pick_rc:-0}" = "42" ]; then
  printf 'TRACK_BLOCKED track=%s (all open issues have open Blocked-by deps)\n' "$TRACK" >&2
  exit 1
fi

number=$(printf '%s' "$pick_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
title=$(printf '%s' "$pick_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
body=$(printf '%s' "$pick_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")

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
