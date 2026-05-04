#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
FIXTURE="$ROOT/core/v2/checkpoints/fixtures/compact-default"
MANIFEST="$FIXTURE/manifest.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v check-jsonschema >/dev/null 2>&1 || fail "check-jsonschema is required"

[ -f "$ROOT/core/v2/checkpoints/CONTRACT.md" ] || fail "missing checkpoint contract"
[ -f "$MANIFEST" ] || fail "missing compact manifest fixture"

PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-manifest.schema.json" "$MANIFEST" >/dev/null \
  || fail "schema rejected checkpoint manifest"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-index.schema.json" "$ROOT/core/v2/checkpoints/fixtures/index.json" >/dev/null \
  || fail "schema rejected checkpoint index"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-state.schema.json" "$FIXTURE/state.json" >/dev/null \
  || fail "schema rejected checkpoint state"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-next-steps.schema.json" "$FIXTURE/next-steps.json" >/dev/null \
  || fail "schema rejected checkpoint next steps"
PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-evidence.schema.json" "$FIXTURE/evidence.json" >/dev/null \
  || fail "schema rejected checkpoint evidence"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s\n' "$line" | PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-telemetry-event.schema.json" - >/dev/null \
    || fail "schema rejected checkpoint telemetry event"
done < "$FIXTURE/telemetry.jsonl"

jq -e '
  .kind == "studio-v2-checkpoint-manifest" and
  .default_load.files == ["manifest.json", "context.md"] and
  ([.artifacts[] | select(.load_policy == "initial") | .path] | sort) == ["context.md", "manifest.json"] and
  ([.artifacts[] | select(.load_policy == "lazy") | .path] | sort) == ["evidence.json", "next-steps.json", "state.json"] and
  ([.artifacts[] | select(.load_policy == "append-only") | .path] == ["telemetry.jsonl"]) and
  .budgets.over_budget_behavior == "emit-warning-telemetry" and
  .forbidden_content.transcripts == "forbidden" and
  .forbidden_content.large_embedded_command_output == "forbidden" and
  ((.ownership.shared_schema | sort) == ["budgets", "index", "lazy-load", "storage", "telemetry"])
' "$MANIFEST" >/dev/null || fail "manifest does not declare compact lazy-load contract"

jq -e '
  .kind == "studio-v2-checkpoint-index" and
  (.checkpoints[] | select(.checkpoint_id == "ckpt-019df316-compact-default" and .session_dir == "sessions/ckpt-019df316-compact-default"))
' "$ROOT/core/v2/checkpoints/fixtures/index.json" >/dev/null || fail "index fixture does not point at compact checkpoint"

default_max_bytes=$(jq -r '.budgets.default_load_max_bytes' "$MANIFEST")
default_bytes=$(wc -c < "$FIXTURE/manifest.json" | tr -d ' ')
default_bytes=$((default_bytes + $(wc -c < "$FIXTURE/context.md" | tr -d ' ')))
[ "$default_bytes" -le "$default_max_bytes" ] || fail "default-loaded fixture exceeds manifest byte budget"

jq -e '
  .size.default_load_bytes >= 0 and
  .size.estimated_default_load_tokens >= 0 and
  (.drift.status | IN("unknown", "none", "possible", "confirmed")) and
  (.usefulness.loaded_files == ["manifest.json", "context.md"]) and
  has("v1_tuning")
' "$FIXTURE/telemetry.jsonl" >/dev/null || fail "telemetry is missing budget, drift, usefulness, or v1 tuning signals"

jq -e 'select(.event == "checkpoint_budget_warning")' "$FIXTURE/telemetry.jsonl" >/dev/null \
  || fail "fixture does not include over-budget warning telemetry"

grep -Fq 'MUST NOT store raw transcripts' "$ROOT/core/v2/checkpoints/CONTRACT.md" \
  || fail "contract does not explicitly forbid transcripts"
grep -Fq 'large embedded command output' "$ROOT/core/v2/checkpoints/CONTRACT.md" \
  || fail "contract does not explicitly forbid large embedded command output"
grep -Fq 'MUST NOT be silently truncated' "$ROOT/core/v2/checkpoints/CONTRACT.md" \
  || fail "contract does not define over-budget warning behavior"

printf 'PASS: checkpoint contract schemas and compact fixture\n'
