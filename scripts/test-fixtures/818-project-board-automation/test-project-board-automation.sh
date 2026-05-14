#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=scripts/lib-artifact-cleanup.sh
. "$ROOT/scripts/lib-artifact-cleanup.sh"
TMPROOT=$(mktemp -d -t project-board-automation.XXXXXX)
register_artifact tmpdir "$TMPROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "project" ] && [ "$2" = "item-list" ]; then
  cat <<'JSON'
{
  "items": [
    {
      "content": {"number": 1, "title": "PM item", "url": "https://github.com/example/repo/issues/1"},
      "repository": "example/repo",
      "type": "Issue",
      "Status": "Todo",
      "Track": "B PM surface",
      "Phase": "B2",
      "Size": "S",
      "Sibling host reviewed": "Needs review",
      "labels": ["track:pm-surface"],
      "milestone": null
    },
    {
      "content": {"number": 2, "title": "Substrate item", "url": "https://github.com/example/repo/issues/2"},
      "repository": "example/repo",
      "type": "Issue",
      "Status": "Done",
      "Track": "A substrate",
      "Phase": "A1",
      "Size": "M",
      "Sibling host reviewed": "Outcome clean",
      "labels": ["track:host-agnostic"],
      "milestone": {"title": "v0.test"}
    }
  ]
}
JSON
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 9
FAKE_GH
chmod +x "$TMPROOT/bin/gh"

track=$(. "$ROOT/scripts/lib-project-board.sh"; printf '["track:pm-surface"]\n' | project_board_infer_track_from_labels)
[ "$track" = "B PM surface" ] || fail "track:pm-surface did not infer B PM surface"

ambiguous=$(. "$ROOT/scripts/lib-project-board.sh"; printf '["track:pm-surface","track:apollo"]\n' | project_board_infer_track_from_labels)
[ -z "$ambiguous" ] || fail "ambiguous track labels should not infer a Track"

repo_from_url=$(. "$ROOT/scripts/lib-project-board.sh"; project_board_repo_slug_from_issue_url "https://github.com/example/repo/issues/123")
[ "$repo_from_url" = "example/repo" ] || fail "issue URL did not expose repo slug"

PATH="$TMPROOT/bin:$PATH" \
STUDIO_PROJECT_OWNER=example \
STUDIO_PROJECT_REPO=example/repo \
  "$ROOT/scripts/studio-project-state.sh" --by-track > "$TMPROOT/by-track.out"
grep -q '## B PM surface (1)' "$TMPROOT/by-track.out" || fail "--by-track missing B PM surface group"
grep -Fq '#1 [Todo] PM item' "$TMPROOT/by-track.out" || fail "--by-track missing PM item"

PATH="$TMPROOT/bin:$PATH" \
STUDIO_PROJECT_OWNER=example \
STUDIO_PROJECT_REPO=example/repo \
  "$ROOT/scripts/studio-project-state.sh" --needs-review > "$TMPROOT/needs-review.out"
grep -Fq '#1 [Todo] PM item' "$TMPROOT/needs-review.out" || fail "--needs-review missing Needs review item"
if grep -Fq '#2' "$TMPROOT/needs-review.out"; then
  fail "--needs-review included item that does not need review"
fi

PATH="$TMPROOT/bin:$PATH" \
STUDIO_PROJECT_OWNER=example \
STUDIO_PROJECT_REPO=example/repo \
  "$ROOT/scripts/studio-project-state.sh" --json --needs-review > "$TMPROOT/needs-review.json"
jq -e 'length == 1 and .[0].issue_number == 1' "$TMPROOT/needs-review.json" >/dev/null \
  || fail "--json --needs-review shape mismatch"

printf 'PASS: project board automation\n'
