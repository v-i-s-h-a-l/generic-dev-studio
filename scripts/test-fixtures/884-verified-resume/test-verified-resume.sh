#!/usr/bin/env bash
# Verifies verified-resume routing and closeout inventory wiring.
# shellcheck disable=SC2016

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
grep -Fq 'verified_closeout_line "Source issue closure handoff"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "closeout inventory is missing source issue closure row"
grep -Fq 'parent_closeout_already_completed "$chain_run_id"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume path does not skip already completed parent closeout"
grep -Fq 'log "resume skip completed parent closeout for #$parent_issue in chain $chain_name"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume idempotency does not explain skipped parent closeout"
grep -Fq 'mark_parent_closeout_completed "$chain_run_id" "$parent_issue"' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "parent closeout completion is not persisted for verified resumes"
grep -Fq -- '--verified|--doctor' "$ROOT/scripts/manager-work-chain.sh" \
  || fail "manager front door does not treat --verified as an explicit runner mode"
grep -Fq -- 'scripts/studio-chain-runner.sh --resume <run_id> [--verified] [--yes] [--host <host>]' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume usage does not document host override"
grep -Fq '.host_override = $host_override' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume path does not persist host override"
grep -Fq 'if (.status // "pending") == "completed" then' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume host override rewrites completed chains"
grep -Fq '.git_metadata_strategy = $git_metadata_strategy' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "resume host override does not recompute git metadata strategy"

if "$ROOT/scripts/studio-chain-runner.sh" --verified >/tmp/verified-resume.out 2>/tmp/verified-resume.err; then
  fail "--verified without --resume unexpectedly succeeded"
fi
grep -Fq -- '--verified requires --resume <run_id>' /tmp/verified-resume.err \
  || fail "--verified without --resume did not explain the route requirement"

printf 'PASS: verified resume routing\n'
