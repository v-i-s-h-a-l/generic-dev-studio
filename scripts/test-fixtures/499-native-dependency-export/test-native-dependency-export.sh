#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/native-dependency-export.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -eu

path=""
for arg in "$@"; do
  path="$arg"
done
case "$path" in
  /repos/v-i-s-h-a-l/generic-dev-studio/issues/443)
    cat <<'JSON'
{"number":443,"title":"PM surface epic","state":"open","html_url":"https://example.test/443"}
JSON
    ;;
  /repos/v-i-s-h-a-l/generic-dev-studio/issues/443/dependencies/blocked_by)
    cat <<'JSON'
[
  {"number":498,"title":"Board contract","state":"closed","html_url":"https://example.test/498"},
  {"number":499,"title":"Dependency export","state":"open","html_url":"https://example.test/499"}
]
JSON
    ;;
  *)
    printf 'unexpected gh api path: %s\n' "$path" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$BIN/gh"

PATH="$BIN:$PATH" "$ROOT/scripts/studio-dependency-export.sh" \
  --repo v-i-s-h-a-l/generic-dev-studio \
  --issue 443 \
  >"$TMPROOT/graph.mmd"

grep -q 'flowchart TD' "$TMPROOT/graph.mmd"
grep -q 'I443\["#443: PM surface epic"\]' "$TMPROOT/graph.mmd"
grep -q 'I443 -->|blocked by| I498' "$TMPROOT/graph.mmd"
grep -q 'I443 -->|blocked by| I499' "$TMPROOT/graph.mmd"

printf 'native dependency export fixture passed\n'
