#!/usr/bin/env bash
# Fixture for the issue context packet reader (#982).
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CMD="$ROOT/scripts/issue-context-packet.sh"
FIXTURE_DIR="$ROOT/scripts/test-fixtures/980-issue-context-packet"

[ -x "$CMD" ] || { printf 'FAIL: %s missing or not executable\n' "$CMD" >&2; exit 1; }

TMP=$(mktemp -d -t issue-context-packet.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

jq '. + [
  range(0; 14) as $i
  | {
      id: (1100 + $i),
      html_url: ("https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/982#issuecomment-" + ((1100 + $i) | tostring)),
      created_at: ("2026-05-16T22:" + (10 + $i | tostring) + ":00Z"),
      updated_at: ("2026-05-16T22:" + (10 + $i | tostring) + ":00Z"),
      user: {login: ("long-thread-human-" + ($i | tostring)), type: "User"},
      body: ("Long thread context " + ($i | tostring) + ": retained for provenance without becoming the direct prompt.")
    }
]' "$FIXTURE_DIR/comments.json" >"$TMP/comments-long.json"

"$CMD" \
  --issue-json "$FIXTURE_DIR/issue.json" \
  --comments-json "$TMP/comments-long.json" \
  --out-dir "$TMP/out" \
  --now "2026-05-16T22:30:00Z" >"$TMP/run.out"

[ -s "$TMP/out/packet.md" ] || { printf 'FAIL: packet.md was not written\n' >&2; exit 1; }
[ -s "$TMP/out/packet.json" ] || { printf 'FAIL: packet.json was not written\n' >&2; exit 1; }
[ -s "$TMP/out/raw/issue.json" ] || { printf 'FAIL: raw issue archive was not written\n' >&2; exit 1; }
[ -s "$TMP/out/raw/comments.json" ] || { printf 'FAIL: raw comments archive was not written\n' >&2; exit 1; }

grep -q '## Source Issues' "$TMP/out/packet.md" || { printf 'FAIL: missing source issues section\n' >&2; exit 1; }
grep -q '## Included Comment Range' "$TMP/out/packet.md" || { printf 'FAIL: missing comment range section\n' >&2; exit 1; }
grep -q '## Decisions' "$TMP/out/packet.md" || { printf 'FAIL: missing decisions section\n' >&2; exit 1; }
grep -q '## Constraints' "$TMP/out/packet.md" || { printf 'FAIL: missing constraints section\n' >&2; exit 1; }
grep -q '## Failures' "$TMP/out/packet.md" || { printf 'FAIL: missing failures section\n' >&2; exit 1; }
grep -q '## Acceptance Changes' "$TMP/out/packet.md" || { printf 'FAIL: missing acceptance changes section\n' >&2; exit 1; }
grep -q '## Conflicts' "$TMP/out/packet.md" || { printf 'FAIL: missing conflicts section\n' >&2; exit 1; }
grep -q '## Open Questions' "$TMP/out/packet.md" || { printf 'FAIL: missing open questions section\n' >&2; exit 1; }
grep -q '## Provenance' "$TMP/out/packet.md" || { printf 'FAIL: missing provenance section\n' >&2; exit 1; }
grep -q 'private/local; not a planner prompt' "$TMP/out/packet.md" || { printf 'FAIL: raw archive warning missing\n' >&2; exit 1; }

jq -e '
  .schema_version == 1
  and .kind == "issue-context-packet"
  and .source_issue.number == 982
  and .included_comment_range.total_count == 21
  and .included_comment_range.included_count == 20
  and .raw_archive.local_private == true
  and .raw_archive.planner_prompt_uses_raw_comments == false
  and ([.comments[].author.classification] | index("human"))
  and ([.comments[].author.classification] | index("marked_agent"))
  and ([.comments[].author.classification] | index("legacy_unmarked_agent"))
  and (.comments[] | select(.id == "1004") | .duplicate_of == "1005")
  and (.comments[] | select(.id == "1004") | .stale_reasons | index("superseded_duplicate_idempotency_key"))
  and (.comments[] | select(.id == "1006") | .stale_reasons | index("after_issue_closed"))
  and (.comments[] | select(.id == "1007") | .public_safe == false)
  and (.comments[] | select(.id == "1007") | .stale_reasons | index("private_or_secret_shaped_content_redacted"))
  and (.comments[] | select(.id == "1002") | .marker.kind == "chain-issue-started")
  and (.signals.decisions | length >= 2)
  and (.signals.constraints | length >= 1)
  and (.signals.failures | length >= 1)
  and (.signals.acceptance_changes | length >= 1)
  and (.signals.conflicts | length >= 1)
  and (.signals.open_questions | length >= 1)
' "$TMP/out/packet.json" >/dev/null || {
  printf 'FAIL: packet sidecar did not satisfy expected content\n' >&2
  jq . "$TMP/out/packet.json" >&2
  exit 1
}

if command -v check-jsonschema >/dev/null 2>&1; then
  PYTHONWARNINGS=ignore check-jsonschema \
    --schemafile "$ROOT/_shared/contracts/issue-comment-pipeline.schema.json" \
    "$TMP/out/packet.json" >/dev/null \
    || { printf 'FAIL: packet sidecar failed JSON schema validation\n' >&2; exit 1; }
else
  jq -e 'type == "object"' "$ROOT/_shared/contracts/issue-comment-pipeline.schema.json" >/dev/null \
    || { printf 'FAIL: schema is not JSON\n' >&2; exit 1; }
fi

printf 'PASS: issue-context-packet fixture (sections, classifications, stale duplicates, closed issue, sidecar JSON)\n'
