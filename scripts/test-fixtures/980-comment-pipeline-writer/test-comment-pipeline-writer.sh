#!/usr/bin/env bash
# Fixture for the studio-comment:v1 writer and lint gate (#981).
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WRITER="$ROOT/scripts/studio-comment.sh"
LINT="$ROOT/scripts/lint-studio-comments.sh"

[ -x "$WRITER" ] || { printf 'FAIL: %s missing or not executable\n' "$WRITER" >&2; exit 1; }
[ -x "$LINT" ] || { printf 'FAIL: %s missing or not executable\n' "$LINT" >&2; exit 1; }

TMP=$(mktemp -d -t studio-comment.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/payload.json"
"$WRITER" \
  --dry-run \
  --target issue:981 \
  --kind chain-issue-completed \
  --idempotency-key centralized-comment-pipeline:issue-981:chain-issue-completed \
  --summary "Issue #981 completed local implementation." \
  --evidence "- bash -n scripts/studio-comment.sh: passed" \
  --next "Chain runner will integrate after review." >"$OUT"

python3 - "$OUT" <<'PY'
import json
import re
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["schema_version"] == 1
assert payload["dry_run"] is True
assert payload["kind"] == "chain-issue-completed"
assert payload["target"] == "issue:981"
assert payload["idempotency_key"] == "centralized-comment-pipeline:issue-981:chain-issue-completed"
assert payload["marker"] == payload["body"].splitlines()[0]
assert re.match(r"^<!-- studio-comment:v1 kind=chain-issue-completed idempotency_key=[A-Za-z0-9._:/-]+ target=issue:981 source=studio-comment -->$", payload["marker"])
assert "### Summary\nIssue #981 completed local implementation." in payload["body"]
assert "### Evidence\n- bash -n scripts/studio-comment.sh: passed" in payload["body"]
assert "### Next\nChain runner will integrate after review." in payload["body"]
assert "/Users/" not in payload["body"]
assert "/private/" not in payload["body"]
assert len(payload["body_sha256"]) == 64
PY

if "$WRITER" --dry-run --target issue:981 --kind unsupported --idempotency-key bad:key --summary "x" >"$TMP/bad-kind.out" 2>"$TMP/bad-kind.err"; then
  printf 'FAIL: unsupported kind was accepted\n' >&2
  exit 1
fi
grep -q 'unsupported kind' "$TMP/bad-kind.err" \
  || { printf 'FAIL: unsupported kind did not produce useful error\n' >&2; cat "$TMP/bad-kind.err" >&2; exit 1; }

if "$WRITER" --dry-run --target issue:981 --kind chain-progress --idempotency-key ok:key --summary "see /Users/example/private-log" >"$TMP/private-path.out" 2>"$TMP/private-path.err"; then
  printf 'FAIL: private path was accepted in public comment body\n' >&2
  exit 1
fi
grep -q 'local/private path' "$TMP/private-path.err" \
  || { printf 'FAIL: private path rejection did not produce useful error\n' >&2; cat "$TMP/private-path.err" >&2; exit 1; }

mkdir -p "$TMP/case-clean/scripts"
cat > "$TMP/case-clean/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
"$SCRIPTS/studio-comment.sh" --dry-run --target issue:1 --kind chain-progress --idempotency-key demo:issue-1:chain-progress --summary "ok"
SH
if ! "$LINT" "$TMP/case-clean/scripts/clean.sh" >"$TMP/clean.out" 2>"$TMP/clean.err"; then
  printf 'FAIL: lint rejected structured writer use\n' >&2
  cat "$TMP/clean.out" "$TMP/clean.err" >&2
  exit 1
fi

mkdir -p "$TMP/case-polluted/scripts"
cat > "$TMP/case-polluted/scripts/polluted.sh" <<'SH'
#!/usr/bin/env bash
"$SCRIPTS/studio-gh.sh" issue comment 981 --body "unstructured"
gh pr comment 12 --body "also unstructured"
SH
if "$LINT" "$TMP/case-polluted/scripts/polluted.sh" >"$TMP/polluted.out" 2>"$TMP/polluted.err"; then
  printf 'FAIL: lint accepted unstructured comment writers\n' >&2
  exit 1
fi
grep -q 'E_UNSTRUCTURED_STUDIO_COMMENT:.*:2:' "$TMP/polluted.out" \
  || { printf 'FAIL: lint did not flag studio-gh issue comment\n' >&2; cat "$TMP/polluted.out" >&2; exit 1; }
grep -q 'E_UNSTRUCTURED_STUDIO_COMMENT:.*:3:' "$TMP/polluted.out" \
  || { printf 'FAIL: lint did not flag gh pr comment\n' >&2; cat "$TMP/polluted.out" >&2; exit 1; }

mkdir -p "$TMP/case-annotated/scripts"
cat > "$TMP/case-annotated/scripts/annotated.sh" <<'SH'
#!/usr/bin/env bash
# lint-studio-comments:allow next-line — documenting a legacy migration call
"$SCRIPTS/studio-gh.sh" issue comment 981 --body "legacy"
SH
if ! "$LINT" "$TMP/case-annotated/scripts/annotated.sh" >"$TMP/annotated.out" 2>"$TMP/annotated.err"; then
  printf 'FAIL: lint rejected allow-annotated legacy call\n' >&2
  cat "$TMP/annotated.out" "$TMP/annotated.err" >&2
  exit 1
fi

if ! STUDIO_BYPASS_COMMENT_STRUCTURE_LINT=1 "$LINT" "$TMP/case-polluted/scripts/polluted.sh" >"$TMP/bypass.out" 2>"$TMP/bypass.err"; then
  printf 'FAIL: bypass did not exit 0\n' >&2
  cat "$TMP/bypass.out" "$TMP/bypass.err" >&2
  exit 1
fi
grep -q 'STUDIO_BYPASS_COMMENT_STRUCTURE_LINT=1' "$TMP/bypass.err" \
  || { printf 'FAIL: bypass did not emit audit line\n' >&2; cat "$TMP/bypass.err" >&2; exit 1; }

REPO="$TMP/staged"
git init -q "$REPO"
(
  cd "$REPO"
  git config user.email "fixture@local"
  git config user.name "fixture"
  mkdir -p scripts
  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
"$SCRIPTS/studio-gh.sh" issue comment 1 --body "pre-existing"
SH
  git add scripts/preexisting.sh
  git commit -q -m "seed"

  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
"$SCRIPTS/studio-gh.sh" issue comment 1 --body "pre-existing"
echo "unrelated edit"
SH
  git add scripts/preexisting.sh
  export LINT_STUDIO_COMMENTS_REPO_ROOT="$REPO"
  if ! "$LINT" --staged >"$TMP/staged-clean.out" 2>"$TMP/staged-clean.err"; then
    printf 'FAIL: staged lint flagged a pre-existing unstructured comment call\n' >&2
    cat "$TMP/staged-clean.out" "$TMP/staged-clean.err" >&2
    exit 1
  fi

  cat > scripts/preexisting.sh <<'SH'
#!/usr/bin/env bash
"$SCRIPTS/studio-gh.sh" issue comment 1 --body "pre-existing"
echo "unrelated edit"
"$SCRIPTS/studio-gh.sh" pr comment 2 --body "new"
SH
  git add scripts/preexisting.sh
  if "$LINT" --staged >"$TMP/staged-fail.out" 2>"$TMP/staged-fail.err"; then
    printf 'FAIL: staged lint accepted newly-added unstructured comment call\n' >&2
    exit 1
  fi
  grep -q 'E_UNSTRUCTURED_STUDIO_COMMENT:scripts/preexisting.sh:' "$TMP/staged-fail.out" \
    || { printf 'FAIL: staged lint did not report newly-added unstructured comment call\n' >&2; cat "$TMP/staged-fail.out" >&2; exit 1; }
  if grep -q 'preexisting.sh:2:' "$TMP/staged-fail.out"; then
    printf 'FAIL: staged lint flagged pre-existing line 2 retroactively\n' >&2
    cat "$TMP/staged-fail.out" >&2
    exit 1
  fi
)

printf 'PASS: studio-comment fixture (writer payload, kind validation, public safety, lint pass/fail, annotation, bypass, staged mode)\n'
