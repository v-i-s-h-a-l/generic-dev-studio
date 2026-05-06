#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/prd-intake-normalize.sh"
TMPROOT=$(mktemp -d -t prd-intake.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/prd-intake-normalize.sh is not executable"

INPUT="$TMPROOT/source.md"
OUT="$TMPROOT/packet.md"

cat >"$INPUT" <<'EOF'
Convert a PRD, transcript, or issue brief into a normalized requirement packet.

Scope:
- Extract explicit requirements.
- Separate inferred behavior from stated requirements.
- Flag ambiguities and conflicts before planning.
- Preserve exact PRD language in the shaped brief.

Out of scope:
- Task decomposition.
- Worker dispatch.
- Review gating.

Acceptance:
- The output is deterministic enough to feed the planner.
- Conflicts and missing details are surfaced instead of silently resolved.
- The shaped artifact stays small and reviewable.
EOF

"$RUN" --title "Issue 647 Requirement Packet" --source issue-647 "$INPUT" >"$OUT"

grep -q '^# Issue 647 Requirement Packet$' "$OUT" \
  || fail "packet should use the requested title"
grep -q '`R001` line 1 - imperative brief language: "Convert a PRD, transcript, or issue brief into a normalized requirement packet."' "$OUT" \
  || fail "packet should preserve top-level PRD language as an explicit requirement"
grep -q '`R005` line 7 (Scope) - stated requirement: "Preserve exact PRD language in the shaped brief."' "$OUT" \
  || fail "packet should preserve exact source wording for scoped requirements"
grep -q '`N002` line 11 (Out of scope) - stated non-goal: "Worker dispatch."' "$OUT" \
  || fail "packet should keep stated non-goals out of requirements"
grep -q '`M001`: Output format or schema is not stated explicitly.' "$OUT" \
  || fail "packet should surface missing output format/schema"
grep -q '^- None detected deterministically.$' "$OUT" \
  || fail "packet should explicitly report empty inferred/conflict buckets"

CONFLICT_INPUT="$TMPROOT/conflict.md"
CONFLICT_OUT="$TMPROOT/conflict-packet.md"
cat >"$CONFLICT_INPUT" <<'EOF'
Requirements:
- The planner must include review gating.

Out of scope:
- Review gating.

Notes:
- Maybe use YAML?
EOF

"$RUN" "$CONFLICT_INPUT" >"$CONFLICT_OUT"

grep -q '`A001` line 8 (Notes) - ambiguous or underspecified language: "Maybe use YAML?"' "$CONFLICT_OUT" \
  || fail "packet should flag ambiguous language"
grep -q '`C001`: line 2 is required, but line 5 marks the same area out of scope' "$CONFLICT_OUT" \
  || fail "packet should flag requirement/non-goal conflicts"

printf 'PASS: prd intake normalization\n'
