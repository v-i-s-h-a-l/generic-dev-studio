#!/usr/bin/env bash
# test-node-pick-escape.sh — fixture for #820 item 6.
#
# Verifies the documented escape hatches:
#   STUDIO_DISPATCH_FORCE_LOCAL=1 — return `local` immediately, reason `forced-local`.
#   STUDIO_DISPATCH_PIN=<id>      — return that id when valid, hard-error otherwise.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PICK="$ROOT/scripts/node-pick.sh"
TMPROOT=$(mktemp -d -t node-pick-escape.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME/.dev-studio/.runtime"
REGISTRY="$HOME/.dev-studio/.runtime/nodes.json"

# Synthesize a small registry: one healthy worker mini, plus a disabled node.
cat > "$REGISTRY" <<'JSON'
{
  "nodes": [
    {"id": "mini", "host": "10.0.0.10", "enabled": true, "roles": ["worker", "release"], "secret_scopes": ["asc"]},
    {"id": "spare", "host": "10.0.0.20", "enabled": false, "roles": ["worker"], "secret_scopes": []}
  ]
}
JSON

pass=0
fail=0
assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

# Case 1: STUDIO_DISPATCH_FORCE_LOCAL=1 returns local immediately.
out=$(STUDIO_DISPATCH_FORCE_LOCAL=1 "$PICK" worker 2>"$TMPROOT/c1.err")
rc=$?
assert "force-local returns 'local'" '[ "$out" = "local" ]'
assert "force-local exits 0" '[ "$rc" -eq 0 ]'

# With reason file set, captures `forced-local`.
reason_file="$TMPROOT/reason1"
STUDIO_DISPATCH_FORCE_LOCAL=1 STUDIO_DISPATCH_REASON_FILE="$reason_file" "$PICK" worker >/dev/null
assert "force-local reason file says 'forced-local'" \
  '[ "$(cat "$reason_file" 2>/dev/null)" = "forced-local" ]'

# Case 2: STUDIO_DISPATCH_PIN to a valid node returns that id.
out=$(STUDIO_DISPATCH_PIN=mini "$PICK" worker 2>"$TMPROOT/c2.err")
rc=$?
assert "pin to valid node returns the id" '[ "$out" = "mini" ]'
assert "pin to valid node exits 0" '[ "$rc" -eq 0 ]'

reason_file="$TMPROOT/reason2"
STUDIO_DISPATCH_PIN=mini STUDIO_DISPATCH_REASON_FILE="$reason_file" "$PICK" worker >/dev/null
assert "valid pin reason file says 'pinned'" \
  '[ "$(cat "$reason_file" 2>/dev/null)" = "pinned" ]'

# Case 3: STUDIO_DISPATCH_PIN to a disabled node is a hard error.
out=$(STUDIO_DISPATCH_PIN=spare "$PICK" worker 2>"$TMPROOT/c3.err")
rc=$?
assert "pin to disabled node exits 2 (hard error)" '[ "$rc" -eq 2 ]'
assert "pin to disabled node names the node in the error" \
  'grep -q "spare" "$TMPROOT/c3.err"'
assert "pin to disabled node mentions force-local fallback hint" \
  'grep -q "FORCE_LOCAL" "$TMPROOT/c3.err"'

# Case 4: STUDIO_DISPATCH_PIN to a non-existent node is a hard error.
out=$(STUDIO_DISPATCH_PIN=ghost "$PICK" worker 2>"$TMPROOT/c4.err")
rc=$?
assert "pin to ghost node exits 2 (hard error)" '[ "$rc" -eq 2 ]'

# Case 5: pin without the required scope is a hard error.
out=$(STUDIO_DISPATCH_PIN=mini "$PICK" --requires-secret-scope slack worker 2>"$TMPROOT/c5.err")
rc=$?
assert "pin without required scope exits 2" '[ "$rc" -eq 2 ]'
assert "pin without required scope mentions scopes" \
  'grep -q "scopes=slack" "$TMPROOT/c5.err"'

# Case 6: pin WITH a satisfied scope succeeds.
out=$(STUDIO_DISPATCH_PIN=mini "$PICK" --requires-secret-scope asc worker 2>"$TMPROOT/c6.err")
rc=$?
assert "pin with satisfied scope returns the id" '[ "$out" = "mini" ]'
assert "pin with satisfied scope exits 0" '[ "$rc" -eq 0 ]'

# Case 7: force-local takes precedence over pin (defensive — both set).
out=$(STUDIO_DISPATCH_FORCE_LOCAL=1 STUDIO_DISPATCH_PIN=ghost "$PICK" worker 2>"$TMPROOT/c7.err")
rc=$?
assert "force-local + invalid pin: force-local wins" '[ "$out" = "local" ]'
assert "force-local + invalid pin: exits 0" '[ "$rc" -eq 0 ]'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: node-pick escape (%d/%d)\n' "$pass" "$pass"
