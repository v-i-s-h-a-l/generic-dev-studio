#!/usr/bin/env bash
# Verifies A0.4 v2 bootstrap skeleton and pre-A0.5 code freeze.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t v2-bootstrap.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

"$ROOT/scripts/lint-v2-bootstrap.sh" --full >/dev/null

REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test

mkdir -p "$REPO/scripts" "$REPO/core/v2/hooks" "$REPO/core/v2/schemas" "$REPO/profiles"
cp "$ROOT/scripts/lint-v2-bootstrap.sh" "$REPO/scripts/lint-v2-bootstrap.sh"
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

printf 'print("not yet")\n' > "$REPO/core/v2/runtime.py"
git -C "$REPO" add core/v2/runtime.py
if (cd "$REPO" && scripts/lint-v2-bootstrap.sh --staged >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  printf 'FAIL: pre-A0.5 code was accepted\n' >&2
  exit 1
fi
grep -q 'E_V2_PRE_A05_CODE:core/v2/runtime.py' "$TMPROOT/err"

git -C "$REPO" reset -q
rm "$REPO/core/v2/runtime.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/profiles/runner"
git -C "$REPO" add profiles/runner
if (cd "$REPO" && scripts/lint-v2-bootstrap.sh --staged >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  printf 'FAIL: pre-A0.5 extensionless executable was accepted\n' >&2
  exit 1
fi
grep -q 'E_V2_PRE_A05_CODE:profiles/runner' "$TMPROOT/err"

git -C "$REPO" reset -q
rm "$REPO/profiles/runner"
printf 'notes only\n' > "$REPO/core/v2/notes.md"
git -C "$REPO" add core/v2/notes.md
(cd "$REPO" && scripts/lint-v2-bootstrap.sh --staged >"$TMPROOT/out" 2>"$TMPROOT/err")

printf 'PASS: v2 bootstrap gate\n'
