#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
EMIT="$ROOT/scripts/v2-topology-event.sh"
EVENT_LOG="$ROOT/scripts/v2-event-log.sh"
SCHEMA="$ROOT/core/v2/schemas/topology-runtime-event.schema.json"
TMPROOT=$(mktemp -d -t topology-telemetry-550.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"
[ -x "$EMIT" ] || fail "v2-topology-event.sh is not executable"

RUNTIME="$TMPROOT/runtime"
mkdir -p "$RUNTIME"

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:00Z \
  --failure-mode sibling_host_unavailable --subject '#445/C6' --producer-role manager \
  --data-json '{"status":"degraded","evidence_ref":"analysis/sibling-host-unavailable.md","review_host":"claude-reviewer","fallback_used":true}'

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:01Z \
  --failure-mode conflicting_reviews --subject '#445/C6' --producer-role manager \
  --data-json '{"status":"blocked","evidence_ref":"analysis/conflicting-reviews.md","review_refs":["r1","r2"],"escalation_ref":"manager:decision-1"}'

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:02Z \
  --failure-mode stale_plan --subject '#445/C6' --producer-role planner \
  --data-json '{"status":"blocked","evidence_ref":"analysis/stale-plan.md","plan_ref":"plan:123","stale_since":"2026-05-04T00:00:00Z"}'

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:03Z \
  --failure-mode worker_deadlock --subject '#445/C6' --producer-role worker \
  --data-json '{"status":"blocked","evidence_ref":"analysis/worker-deadlock.md","worker_ref":"worker-2","timeout_s":2700}'

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:04Z \
  --failure-mode partial_multi_spawn --subject '#445/C6' --producer-role qa-engineer \
  --data-json '{"status":"partial","evidence_ref":"analysis/partial-multi-spawn.md","completed_count":2,"expected_count":3}'

"$EMIT" emit --runtime-root "$RUNTIME" --quiet --occurred-at 2026-05-04T00:00:05Z \
  --failure-mode budget_exhaustion --subject '#445/C6' --producer-role release-manager \
  --data-json '{"status":"blocked","evidence_ref":"analysis/budget-exhaustion.md","budget_kind":"context","budget_limit":90000,"observed_value":97000}'

OUT="$TMPROOT/replay.jsonl"
"$EVENT_LOG" replay --runtime-root "$RUNTIME" --subscriber topology > "$OUT"
[ "$(wc -l < "$OUT" | tr -d ' ')" = 6 ] || fail "expected six replayed topology events"

for mode in sibling_host_unavailable conflicting_reviews stale_plan worker_deadlock partial_multi_spawn budget_exhaustion; do
  jq -e --arg mode "$mode" 'select(.data.failure_mode == $mode and (.data.evidence_ref | length > 0))' "$OUT" >/dev/null \
    || fail "missing replayed event for $mode"
done

while IFS= read -r line; do
  sample="$TMPROOT/sample.json"
  printf '%s\n' "$line" > "$sample"
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" "$sample" >/dev/null \
    || fail "schema rejected replayed topology event"
done < "$OUT"

if "$EMIT" emit --runtime-root "$RUNTIME" --quiet \
  --failure-mode unknown_mode --subject '#445/C6' --producer-role manager \
  --data-json '{"status":"blocked","evidence_ref":"analysis/bad.md"}' >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"; then
  fail "unknown failure mode was accepted"
fi
grep -q 'unknown failure mode: unknown_mode' "$TMPROOT/bad.err" || fail "unknown failure mode error was not explicit"

if "$EMIT" emit --runtime-root "$RUNTIME" --quiet \
  --failure-mode worker_deadlock --subject '#445/C6' --producer-role worker \
  --data-json '{"status":"blocked","evidence_ref":"analysis/missing.md","worker_ref":"worker-2"}' >"$TMPROOT/missing.out" 2>"$TMPROOT/missing.err"; then
  fail "missing required field was accepted"
fi
grep -q 'missing required data field(s) for worker_deadlock: timeout_s' "$TMPROOT/missing.err" \
  || fail "missing required field error was not explicit"

if "$EMIT" emit --runtime-root "$RUNTIME" --quiet \
  --failure-mode worker_deadlock --subject '#445/C6' --producer-role invalid-role \
  --data-json '{"status":"blocked","evidence_ref":"analysis/schema-rejected.md","worker_ref":"worker-2","timeout_s":2700}' >"$TMPROOT/schema.out" 2>"$TMPROOT/schema.err"; then
  fail "schema-invalid event was accepted"
fi
grep -q 'event failed schema validation' "$TMPROOT/schema.err" \
  || fail "schema validation error was not explicit"

printf 'PASS: topology runtime telemetry\n'
