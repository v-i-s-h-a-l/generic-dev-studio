#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CMD="$ROOT/scripts/v2-cutover.sh"
MANIFEST="$ROOT/core/v2/cutover/manifest.yaml"
FORWARDERS="$ROOT/core/v2/skills/dev-studio/forwarders.yaml"
ALLOW_ROLLED_BACK=0

case "${1:-}" in
  --allow-rolled-back) ALLOW_ROLLED_BACK=1 ;;
  "") ;;
  *) printf 'usage: %s [--allow-rolled-back]\n' "$0" >&2; exit 2 ;;
esac

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$CMD" ] || fail "cutover validator is not executable"
[ -f "$MANIFEST" ] || fail "missing cutover manifest"

if [ "$ALLOW_ROLLED_BACK" -eq 1 ]; then
  "$CMD" --validate --allow-rolled-back >/tmp/v2-cutover-validate.out 2>/tmp/v2-cutover-validate.err || {
    cat /tmp/v2-cutover-validate.err >&2
    fail "cutover validation failed"
  }
else
  "$CMD" --validate >/tmp/v2-cutover-validate.out 2>/tmp/v2-cutover-validate.err || {
    cat /tmp/v2-cutover-validate.err >&2
    fail "cutover validation failed"
  }
fi
grep -Fq 'v2-cutover: ok' /tmp/v2-cutover-validate.err || fail "validation did not report success"

"$CMD" --status --json | jq -e '.primary_invocation == "/dev-studio"' >/dev/null || fail "status json missing primary invocation"

[ "$(yq -r '.kind' "$MANIFEST")" = "studio-v2-cutover" ] || fail "manifest kind mismatch"
[ "$(yq -r '.leaf_issue' "$MANIFEST")" = "527" ] || fail "manifest leaf issue mismatch"
[ "$(yq -r '.status' "$MANIFEST")" = "v1-deleted" ] || fail "manifest should record A10 v1 deletion"
[ "$(yq -r '.traffic_switch.cutover_status' "$MANIFEST")" = "v1-deleted" ] || fail "traffic switch should record v1 deletion"
[ "$(yq -r '.transition.cutover_status' "$FORWARDERS")" = "v1-deleted" ] || fail "forwarder manifest should record v1 deletion"
[ "$(yq -r '.forwarders | length' "$FORWARDERS")" = "0" ] || fail "A10 should remove v1 forwarder rows"
[ "$(yq -r '.traffic_switch.compatibility_forwarders | length' "$MANIFEST")" = "0" ] || fail "A10 should remove compatibility forwarders"
[ "$(yq -r '[.archive.surfaces[] | select(.status != "deleted")] | length' "$MANIFEST")" = "0" ] || fail "A10 should mark every v1 surface deleted"

for evidence in core/v2/manager/proof-of-life.yaml core/v2/roles/worker.yaml core/v2/roles/reviewer.yaml core/v2/roles/perf.yaml; do
  yq -e ".parity.golden_scenarios[].evidence | select(. == \"$evidence\")" "$MANIFEST" >/dev/null || fail "missing parity evidence: $evidence"
done

printf 'PASS: v2 cutover manifest and rollback playbook\n'
