#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SPEC="$ROOT/core/v2/SPEC.md"
TMPROOT=$(mktemp -d -t v2-spec.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

require_line() {
  needle="$1"
  if ! grep -Fxq "$needle" "$SPEC"; then
    printf 'FAIL: missing exact line in core/v2/SPEC.md: %s\n' "$needle" >&2
    exit 1
  fi
}

require_text() {
  needle="$1"
  if ! grep -Fq "$needle" "$SPEC"; then
    printf 'FAIL: missing text in core/v2/SPEC.md: %s\n' "$needle" >&2
    exit 1
  fi
}

[ -f "$SPEC" ] || {
  printf 'FAIL: missing core/v2/SPEC.md\n' >&2
  exit 1
}

require_line '<!-- v2-bootstrap:a0.5-sign-off:complete -->'

for anchor in \
  '<!-- v2-spec:source-inputs -->' \
  '<!-- v2-spec:principles -->' \
  '<!-- v2-spec:host-floor -->' \
  '<!-- v2-spec:artifact-root -->' \
  '<!-- v2-spec:event-log -->' \
  '<!-- v2-spec:auth-permissions -->' \
  '<!-- v2-spec:roles-handoffs -->' \
  '<!-- v2-spec:project-profiles -->' \
  '<!-- v2-spec:context-budget -->' \
  '<!-- v2-spec:testing-release -->' \
  '<!-- v2-spec:bootstrap-gate -->' \
  '<!-- v2-spec:carryover -->'
do
  require_line "$anchor"
done

for term in \
  'A0 research map' \
  'A0a host capability matrix' \
  'A0b durable event-log semantics' \
  'A0c auth and permissions model' \
  'A0d role topology and handoff RFC' \
  'planner-output' \
  'worker-contract' \
  'reviewer-verdict' \
  'release-packet' \
  'phase-review wrapper usage'
do
  require_text "$term"
done

if [ -x "$ROOT/scripts/lint-v2-bootstrap.sh" ]; then
  REPO="$TMPROOT/repo"
  mkdir -p "$REPO/scripts" "$REPO/core/v2/hooks" "$REPO/core/v2/schemas"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test

  cp "$ROOT/scripts/lint-v2-bootstrap.sh" "$REPO/scripts/lint-v2-bootstrap.sh"
  cp "$ROOT/core/v2/SPEC.md" "$REPO/core/v2/SPEC.md"
  cp "$ROOT/core/v2/bootstrap.yaml" "$REPO/core/v2/bootstrap.yaml"
  cp "$ROOT/core/v2/BOOTSTRAP.md" "$REPO/core/v2/BOOTSTRAP.md"
  cp "$ROOT/core/v2/hooks/pre-commit" "$REPO/core/v2/hooks/pre-commit"
  cp "$ROOT/core/v2/schemas/bootstrap.schema.json" "$REPO/core/v2/schemas/bootstrap.schema.json"
  mkdir -p "$REPO/.githooks"
  cat > "$REPO/.githooks/pre-commit" <<'SH'
#!/usr/bin/env bash
scripts/lint-v2-bootstrap.sh --staged
SH

  git -C "$REPO" add .
  git -C "$REPO" commit -qm bootstrap
  printf 'print("post marker ok")\n' > "$REPO/core/v2/runtime.py"
  git -C "$REPO" add core/v2/runtime.py
  (cd "$REPO" && scripts/lint-v2-bootstrap.sh --staged >"$TMPROOT/out" 2>"$TMPROOT/err")
fi

printf 'PASS: v2 SPEC\n'
