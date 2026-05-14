#!/usr/bin/env bash
# Verifies verified-resume routing and closeout inventory wiring.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'VERIFIED_RESUME=0' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner is missing verified resume state"
grep -Fq -- '--verified) VERIFIED_RESUME=1; shift ;;' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner does not parse --verified"
grep -Fq 'render_verified_resume_closeout "$status" "$run_state_json"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "finish summary does not render verified closeout"
grep -Fq 'verified_closeout_line "Worker summary ingested and validated"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "closeout inventory is missing worker summary row"
grep -Fq -- '--verified|--doctor' "$ROOT/scripts/manager-work-chain.sh" \
  || fail "manager front door does not treat --verified as an explicit runner mode"

if "$ROOT/scripts/studio-chain-runner.sh" --verified >/tmp/verified-resume.out 2>/tmp/verified-resume.err; then
  fail "--verified without --resume unexpectedly succeeded"
fi
grep -Fq -- '--verified requires --resume <run_id>' /tmp/verified-resume.err \
  || fail "--verified without --resume did not explain the route requirement"

printf 'PASS: verified resume routing\n'
