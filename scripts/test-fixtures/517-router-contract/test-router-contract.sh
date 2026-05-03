#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LINT="$ROOT/scripts/v2-router-lint.sh"
SCHEMA="$ROOT/core/v2/schemas/router-contract.schema.json"
CONTRACT="$ROOT/core/v2/routers/modular-router-contract.yaml"
TMPROOT=$(mktemp -d -t router-contract-517.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$LINT" ] || fail "router lint is not executable"
[ -f "$SCHEMA" ] || fail "missing router contract schema"
[ -f "$CONTRACT" ] || fail "missing router contract"

jq -e '.["$schema"] and .type == "object"' "$SCHEMA" >/dev/null || fail "schema is not a JSON schema"
yq -e '.schema_version == 1 and .kind == "studio-v2-router-contract" and .leaf_issue == 517' "$CONTRACT" >/dev/null || fail "contract envelope invalid"

"$LINT" --full >"$TMPROOT/full.out" 2>"$TMPROOT/full.err" || {
  cat "$TMPROOT/full.err" >&2
  fail "repo router lint failed"
}
grep -Fq 'v2-router-lint: ok (full' "$TMPROOT/full.err" || fail "router lint did not report success"

make_repo() {
  repo="$1"
  mkdir -p "$repo/scripts" "$repo/core/v2/routers" "$repo/core/v2/schemas"
  cp "$LINT" "$repo/scripts/v2-router-lint.sh"
  cp "$SCHEMA" "$repo/core/v2/schemas/router-contract.schema.json"
  cp "$CONTRACT" "$repo/core/v2/routers/modular-router-contract.yaml"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
}

GOOD="$TMPROOT/good"
make_repo "$GOOD"
cat > "$GOOD/core/v2/routers/router.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  run) exec core/v2/helpers/run ;;
  *) printf 'usage: router.sh run\n' >&2; exit 2 ;;
esac
SH

(cd "$GOOD" && scripts/v2-router-lint.sh --full >"$TMPROOT/good.out" 2>"$TMPROOT/good.err") || {
  cat "$TMPROOT/good.err" >&2
  fail "good router repo failed lint"
}

WARN="$TMPROOT/warn"
make_repo "$WARN"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "${1:-}" in\n'
  i=0
  while [ "$i" -lt 78 ]; do
    printf '  route%s) exec core/v2/helpers/route%s ;;\n' "$i" "$i"
    i=$((i + 1))
  done
  printf '  *) exit 2 ;;\n'
  printf 'esac\n'
} > "$WARN/core/v2/routers/router.sh"

(cd "$WARN" && scripts/v2-router-lint.sh --full >"$TMPROOT/warn.out" 2>"$TMPROOT/warn.err") || {
  cat "$TMPROOT/warn.err" >&2
  fail "warning-size router should not fail"
}
grep -q 'W_V2_ROUTER_SIZE:core/v2/routers/router.sh' "$TMPROOT/warn.err" || fail "warning-size router did not emit W_V2_ROUTER_SIZE"

BAD="$TMPROOT/bad"
make_repo "$BAD"
yq -i '.complexity.hard_max_non_comment_lines = 120' "$BAD/core/v2/routers/modular-router-contract.yaml"
{
  printf '#!/usr/bin/env bash\n'
  i=0
  while [ "$i" -lt 101 ]; do
    printf 'case_%s=true\n' "$i"
    i=$((i + 1))
  done
  printf 'git push origin feature/v2-router-work\n'
} > "$BAD/core/v2/routers/router.sh"

if (cd "$BAD" && scripts/v2-router-lint.sh --full >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"); then
  fail "bad router repo passed lint"
fi

grep -q 'E_V2_ROUTER_CONTRACT' "$TMPROOT/bad.err" || fail "bad contract did not fail schema validation"
grep -q 'E_V2_ROUTER_CONTRACT_FIELD:core/v2/routers/modular-router-contract.yaml:complexity.hard_max_non_comment_lines=120' "$TMPROOT/bad.err" || fail "weakened hard limit was not flagged"
grep -q 'E_V2_ROUTER_SIZE:core/v2/routers/router.sh' "$TMPROOT/bad.err" || fail "oversized router was not flagged"
grep -q 'E_V2_ROUTER_LOGIC:core/v2/routers/router.sh' "$TMPROOT/bad.err" || fail "router business logic was not flagged"

printf 'PASS: v2 router contract and lint\n'
