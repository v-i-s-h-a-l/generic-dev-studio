#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-comment-idempotency.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TMPROOT/scripts"
cp "$ROOT/scripts/studio-comment.sh" "$TMPROOT/scripts/studio-comment.sh"
chmod +x "$TMPROOT/scripts/studio-comment.sh"
COMMENTS="$TMPROOT/comments.jsonl"
CALLS="$TMPROOT/calls.log"
: > "$COMMENTS"
: > "$CALLS"

cat > "$TMPROOT/scripts/studio-gh.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$STUDIO_GH_STUB_CALLS"

if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/issues/42/comments" ]; then
  python3 - "$STUDIO_GH_STUB_COMMENTS" <<'PY'
import json
import os
import sys

marker = os.environ["MARKER"]
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    item = json.loads(line)
    if item["body"].startswith(marker):
        print(item["id"])
PY
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "PATCH" ]; then
  comment_id="${4##*/}"
  body=""
  shift 4
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f)
        case "${2:-}" in
          body=*) body="${2#body=}" ;;
        esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  python3 - "$STUDIO_GH_STUB_COMMENTS" "$comment_id" "$body" <<'PY'
import json
import sys

path, comment_id, body = sys.argv[1], int(sys.argv[2]), sys.argv[3]
items = []
for line in open(path, encoding="utf-8"):
    if not line.strip():
        continue
    item = json.loads(line)
    if item["id"] == comment_id:
        item["body"] = body
    items.append(item)
with open(path, "w", encoding="utf-8") as fh:
    for item in items:
        print(json.dumps(item, sort_keys=True), file=fh)
PY
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  body=$(cat)
  python3 - "$STUDIO_GH_STUB_COMMENTS" "$body" <<'PY'
import json
import sys

path, body = sys.argv[1], sys.argv[2]
count = 0
for line in open(path, encoding="utf-8"):
    if line.strip():
        count += 1
with open(path, "a", encoding="utf-8") as fh:
    print(json.dumps({"id": count + 1, "body": body}, sort_keys=True), file=fh)
PY
  exit 0
fi

printf 'unexpected studio-gh call: %s\n' "$*" >&2
exit 3
SH
chmod +x "$TMPROOT/scripts/studio-gh.sh"

export STUDIO_GH_STUB_COMMENTS="$COMMENTS"
export STUDIO_GH_STUB_CALLS="$CALLS"

run_comment() {
  "$TMPROOT/scripts/studio-comment.sh" \
    --post \
    --target issue:42 \
    --repo owner/repo \
    --kind feedback-ingest \
    --idempotency-key feedback-ingest:issue-42:fixture \
    --source ingest-feedback \
    --summary "$1" \
    --planning-signal "Planning signal survives update-in-place." \
    --links "- Destination issue: https://github.com/owner/repo/issues/42"
}

run_comment "First summary" >/dev/null
run_comment "Updated summary" >/dev/null

[ "$(wc -l < "$COMMENTS" | tr -d ' ')" = "1" ] || fail "idempotent repost created a duplicate comment"
grep -q 'Updated summary' "$COMMENTS" || fail "idempotent repost did not update the existing comment"
grep -q '^api --method PATCH repos/owner/repo/issues/comments/1 ' "$CALLS" || fail "existing comment was not patched"

printf 'PASS: studio-comment idempotent update\n'
