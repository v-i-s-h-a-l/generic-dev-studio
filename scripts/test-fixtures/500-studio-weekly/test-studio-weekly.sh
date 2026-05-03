#!/usr/bin/env bash

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-weekly.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'v-i-s-h-a-l/generic-dev-studio\n'
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  state=""
  search=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --search) search="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$state:$search" in
    open:*)
      cat <<'JSON'
[
  {"number": 443, "title": "PM surface", "url": "https://github.com/owner/repo/issues/443", "createdAt": "2026-04-01T10:00:00Z", "updatedAt": "2026-05-03T10:00:00Z", "labels": [{"name":"track:B PM surface"}], "milestone": null},
  {"number": 500, "title": "Build weekly studio digest", "url": "https://github.com/owner/repo/issues/500", "createdAt": "2026-05-01T10:00:00Z", "updatedAt": "2026-05-03T10:00:00Z", "labels": [{"name":"enhancement"},{"name":"track:B PM surface"}], "milestone": null},
  {"number": 300, "title": "Old backlog item", "url": "https://github.com/owner/repo/issues/300", "createdAt": "2026-02-01T10:00:00Z", "updatedAt": "2026-03-01T10:00:00Z", "labels": [], "milestone": null}
]
JSON
      ;;
    all:in:title*)
      printf '[]\n'
      ;;
    all:created:*)
      cat <<'JSON'
[
  {"number": 500, "title": "Build weekly studio digest", "url": "https://github.com/owner/repo/issues/500", "createdAt": "2026-05-01T10:00:00Z", "state": "OPEN", "labels": [{"name":"enhancement"}]},
  {"number": 501, "title": "Follow-up", "url": "https://github.com/owner/repo/issues/501", "createdAt": "2026-05-02T10:00:00Z", "state": "CLOSED", "labels": [{"name":"polish"}]}
]
JSON
      ;;
    closed:closed:*)
      cat <<'JSON'
[
  {"number": 498, "title": "Set up board", "url": "https://github.com/owner/repo/issues/498", "createdAt": "2026-04-25T10:00:00Z", "closedAt": "2026-05-01T12:00:00Z", "labels": [{"name":"track:B PM surface"}], "milestone": null},
  {"number": 499, "title": "Dependency exporter", "url": "https://github.com/owner/repo/issues/499", "createdAt": "2026-04-26T10:00:00Z", "closedAt": "2026-05-02T12:00:00Z", "labels": [{"name":"enhancement"}], "milestone": null},
  {"number": 490, "title": "Older closure", "url": "https://github.com/owner/repo/issues/490", "createdAt": "2026-04-01T10:00:00Z", "closedAt": "2026-04-15T12:00:00Z", "labels": [{"name":"bug"}], "milestone": null}
]
JSON
      ;;
    *)
      printf 'unexpected issue list state/search: %s / %s\n' "$state" "$search" >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  printf 'https://github.com/owner/repo/issues/777\n'
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "pin" ]; then
  printf 'pinned %s\n' "$3"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  body_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) body_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cp "$body_file" "${GH_STUB_COMMENT:?}"
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export GH_STUB_LOG="$TMPROOT/gh.log"
export GH_STUB_COMMENT="$TMPROOT/comment.md"
export HOME="$TMPROOT/home"
mkdir -p "$HOME"

out="$TMPROOT/digest.md"
"$ROOT/scripts/studio-weekly.sh" --repo owner/repo --days 7 > "$out"

grep -q '# Weekly Studio Digest' "$out" || { cat "$out" >&2; exit 1; }
grep -q 'Open issues now: 3' "$out" || { cat "$out" >&2; exit 1; }
grep -q 'Opened this week: 2' "$out" || { cat "$out" >&2; exit 1; }
grep -q 'Closed this week: 2' "$out" || { cat "$out" >&2; exit 1; }
grep -q 'Net backlog change: 0' "$out" || { cat "$out" >&2; exit 1; }
grep -q 'track:B PM surface: 2' "$out" || { cat "$out" >&2; exit 1; }
grep -q '#300' "$out" || { cat "$out" >&2; exit 1; }

json="$TMPROOT/digest.json"
"$ROOT/scripts/studio-weekly.sh" --repo owner/repo --days 7 --json > "$json"
jq -e '.counts.open_now == 3 and .counts.closed == 2 and (.aged_open | length) == 2' "$json" >/dev/null || {
  cat "$json" >&2
  exit 1
}

: > "$GH_STUB_LOG"
rm -f "$GH_STUB_COMMENT"
"$ROOT/scripts/studio-weekly.sh" --repo owner/repo --days 7 --post > "$TMPROOT/post.out"
grep -q 'posted digest to owner/repo#777' "$TMPROOT/post.out" || { cat "$TMPROOT/post.out" >&2; exit 1; }
grep -q '^issue create ' "$GH_STUB_LOG" || { cat "$GH_STUB_LOG" >&2; exit 1; }
grep -q '^issue pin 777 ' "$GH_STUB_LOG" || { cat "$GH_STUB_LOG" >&2; exit 1; }
grep -q '^issue comment 777 ' "$GH_STUB_LOG" || { cat "$GH_STUB_LOG" >&2; exit 1; }
grep -q '# Weekly Studio Digest' "$GH_STUB_COMMENT" || { cat "$GH_STUB_COMMENT" >&2; exit 1; }

printf 'PASS: studio weekly digest\n'
