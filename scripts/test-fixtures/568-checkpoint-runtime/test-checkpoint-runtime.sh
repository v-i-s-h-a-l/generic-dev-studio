#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t checkpoint-runtime-568.XXXXXX)
HOME="$TMPROOT/home"
REPO="$TMPROOT/repo"
mkdir -p "$HOME" "$REPO"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Checkpoint Test"
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m init
git -C "$REPO" checkout -q -b feature/test

run_checkpoint() {
  (cd "$REPO" && HOME="$HOME" ACHILLES_PROJECT=test-project "$ROOT/scripts/studio-checkpoint.sh" "$@")
}

root="$HOME/.dev-studio/test-project/.runtime/v2/checkpoints"
created_id=$(run_checkpoint create \
  --role worker \
  --goal "Implement compact checkpoint runtime" \
  --completed "Path helpers added" \
  --next "Resume and inspect drift" \
  --evidence "$REPO/file.txt" \
  --checkpoint-id ckpt-runtime-create)

[ "$created_id" = "ckpt-runtime-create" ] || fail "create did not print checkpoint id"
created_dir="$root/sessions/$created_id"
[ -f "$created_dir/manifest.json" ] || fail "create did not write manifest"
[ -f "$created_dir/context.md" ] || fail "create did not write context"
[ ! -f "$created_dir/transcript.txt" ] || fail "checkpoint stored transcript"

jq -e '.kind == "studio-v2-checkpoint-index" and (.checkpoints[] | select(.checkpoint_id == "ckpt-runtime-create"))' "$root/index.json" >/dev/null \
  || fail "index missing created checkpoint"
jq -e '.checkpoint_id == "ckpt-runtime-create"' "$root/latest/worker/feature_test.json" >/dev/null \
  || fail "latest pointer missing created checkpoint"
jq -e '.schema_version.version == "1.0.0"' "$created_dir/manifest.json" >/dev/null \
  || fail "manifest schema version is not pinned"
if command -v check-jsonschema >/dev/null 2>&1; then
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-manifest.schema.json" "$created_dir/manifest.json" >/dev/null \
    || fail "created manifest failed schema validation"
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-state.schema.json" "$created_dir/state.json" >/dev/null \
    || fail "created state failed schema validation"
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-next-steps.schema.json" "$created_dir/next-steps.json" >/dev/null \
    || fail "created next steps failed schema validation"
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-evidence.schema.json" "$created_dir/evidence.json" >/dev/null \
    || fail "created evidence failed schema validation"
fi

updated_id=$(run_checkpoint update \
  --role worker \
  --goal "Continue compact checkpoint runtime" \
  --completed "Create flow works" \
  --next "Verify resume drift" \
  --checkpoint-id ckpt-runtime-update)

[ "$updated_id" = "ckpt-runtime-update" ] || fail "update did not print checkpoint id"
updated_dir="$root/sessions/$updated_id"
jq -e '.role_state.supersedes == "ckpt-runtime-create"' "$updated_dir/state.json" >/dev/null \
  || fail "update did not record lineage"
jq -e '.checkpoints[] | select(.checkpoint_id == "ckpt-runtime-create" and .status == "superseded")' "$root/index.json" >/dev/null \
  || fail "update did not supersede prior index entry"
jq -e '.checkpoint_id == "ckpt-runtime-update"' "$root/latest/worker/feature_test.json" >/dev/null \
  || fail "latest pointer did not advance"

trace="$TMPROOT/reads.txt"
resume_output=$(STUDIO_CHECKPOINT_TRACE_READS="$trace" run_checkpoint resume --latest --role worker --branch feature/test)
printf '%s\n' "$resume_output" | grep -Fq 'Drift: none' || fail "resume did not report clean drift"
head -n 2 "$trace" | tr '\n' ' ' | grep -Fq 'manifest.json context.md ' \
  || fail "resume did not read manifest and context first"

printf 'two\n' >> "$REPO/file.txt"
drift_output=$(run_checkpoint resume --latest --role worker --branch feature/test)
printf '%s\n' "$drift_output" | grep -Eq 'Drift: (possible|confirmed)' || fail "resume did not detect dirty drift"
jq -e 'select(.event == "checkpoint_resumed" and .drift.status != "unknown")' "$updated_dir/telemetry.jsonl" >/dev/null \
  || fail "resume drift telemetry missing"

budget_id=$(run_checkpoint create \
  --role worker \
  --goal "Budget warning checkpoint" \
  --completed "This deliberately creates a compact but warning-level default load." \
  --next "Inspect warning telemetry" \
  --checkpoint-id ckpt-runtime-budget \
  --budget-max-bytes 120 \
  --budget-max-tokens 30 2>"$TMPROOT/budget.err")
budget_dir="$root/sessions/$budget_id"
grep -Fq 'largest section:' "$TMPROOT/budget.err" || fail "budget warning did not list largest sections"
jq -e 'select(.event == "checkpoint_budget_warning")' "$budget_dir/telemetry.jsonl" >/dev/null \
  || fail "budget warning telemetry missing"

run_checkpoint usefulness --checkpoint-id ckpt-runtime-update --outcome helpful --notes "Resume context was useful"
jq -e 'select(.event == "checkpoint_usefulness_recorded" and .usefulness.resume_outcome == "helpful")' "$updated_dir/telemetry.jsonl" >/dev/null \
  || fail "usefulness telemetry missing"

git -C "$REPO" checkout -q -b feature/chain
manager_chain_id=$(run_checkpoint create \
  --role manager \
  --goal "Chain automation checkpoint" \
  --completed "Manager checkpoint for the active chain branch" \
  --next "Resume the chain branch" \
  --checkpoint-id ckpt-manager-chain)
manager_chain_dir="$root/sessions/$manager_chain_id"
run_checkpoint create \
  --role worker \
  --goal "Unrelated worker checkpoint" \
  --completed "Worker checkpoint on same branch must not be loaded by manager resume" \
  --checkpoint-id ckpt-worker-chain >/dev/null
git -C "$REPO" checkout -q -b feature/other
run_checkpoint create \
  --role manager \
  --goal "Unrelated manager checkpoint" \
  --completed "Manager checkpoint on another branch must not be loaded by chain resume" \
  --checkpoint-id ckpt-manager-other >/dev/null
scoped_output=$(run_checkpoint resume --latest --role manager --branch feature/chain)
printf '%s\n' "$scoped_output" | grep -Fq 'Checkpoint: `ckpt-manager-chain`' \
  || fail "manager resume loaded unrelated role or branch checkpoint"
jq -e '.checkpoint_id == "ckpt-manager-chain"' "$root/latest/manager/feature_chain.json" >/dev/null \
  || fail "manager latest pointer for feature/chain missing"
[ "$manager_chain_dir" = "$root/sessions/ckpt-manager-chain" ] \
  || fail "manager checkpoint directory was not in private runtime storage"
if command -v check-jsonschema >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | PYTHONWARNINGS=ignore check-jsonschema --schemafile "$ROOT/core/v2/schemas/checkpoint-telemetry-event.schema.json" - >/dev/null \
      || fail "runtime telemetry failed schema validation"
  done < "$updated_dir/telemetry.jsonl"
fi

printf 'PASS: checkpoint runtime create/update/resume/budget/latest\n'
