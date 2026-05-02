#!/usr/bin/env bash
# check-model-catalog.sh — validate shared model catalog/policy metadata.
#
# Usage:
#   scripts/check-model-catalog.sh [--print-refresh-checklist]

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CATALOG="$REPO_ROOT/_shared/schemas/model-catalog.yaml"
POLICY="$REPO_ROOT/_shared/rules/model-policy.yaml"
PRINT_CHECKLIST=0

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --print-refresh-checklist) PRINT_CHECKLIST=1; shift ;;
    -h|--help) usage ;;
    *) printf 'check-model-catalog: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

[ -f "$CATALOG" ] || { printf 'check-model-catalog: missing catalog: %s\n' "$CATALOG" >&2; exit 1; }
[ -f "$POLICY" ] || { printf 'check-model-catalog: missing policy: %s\n' "$POLICY" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'check-model-catalog: yq is required\n' >&2; exit 1; }

failures=0
check() {
  local name="$1" expr="$2" file="${3:-$CATALOG}"
  if yq -e "$expr" "$file" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

check "catalog schema version" '.schema_version.name == "model-catalog" and .schema_version.version != null'
check "policy schema version" '.schema_version.name == "model-policy" and .schema_version.version != null' "$POLICY"
check "provider families present" '.provider_families.openai.adapters and .provider_families.anthropic.adapters'
check "reviewer adapters mapped to provider families" '.adapter_profiles."codex-reviewer".provider_family == "openai" and .adapter_profiles."claude-reviewer".provider_family == "anthropic"'
check "catalog has OpenAI reviewer model" '[.models[] | select(.provider_family == "openai" and ((.role_suitability // []) | contains(["reviewer"])) and ((.adapter_profiles // []) | contains(["codex-reviewer"])))] | length > 0'
check "catalog has Anthropic reviewer model" '[.models[] | select(.provider_family == "anthropic" and ((.role_suitability // []) | contains(["reviewer"])) and ((.adapter_profiles // []) | contains(["claude-reviewer"])))] | length > 0'
check "all models have verification metadata" '[.models[] | select((.source.url // "") == "" or (.source.last_verified_at // "") == "")] | length == 0'
check "all models declare reasoning support/default" '[.models[] | select(.reasoning_effort.supported == null or (.reasoning_effort.default // "") == "")] | length == 0'
check "reviewer policy requires independent provider family" '.roles."reviewer.heavyweight".independent_provider_family_required == true and .reviewer_selection.block_without_independent_reviewer == true' "$POLICY"

if command -v codex >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  codex_catalog=$(codex debug models 2>/dev/null || true)
  codex_default=$(printf '%s\n' "$codex_catalog" | jq -r '.models[]? | select(.visibility == "list") | .slug' 2>/dev/null | head -1)
  if [ -n "$codex_default" ]; then
    check "OpenAI reviewer default matches Codex CLI model catalog" \
      '.models.openai_gpt_5_5.id == "'"$codex_default"'" and ((.models.openai_gpt_5_5.adapter_profiles // []) | contains(["codex-reviewer"]))'
  fi
fi

if [ "$PRINT_CHECKLIST" -eq 1 ]; then
  cat <<'EOF'

Model catalog refresh checklist:
1. Run `codex debug models` and confirm the OpenAI/Codex default still matches the first listed model.
2. Open the official provider docs listed below.
3. Confirm each default model ID still exists and is not deprecated.
4. Prefer stable aliases for CLI defaults when the provider recommends them; keep dated snapshot IDs when exposed.
5. Confirm reasoning-effort levels before changing reviewer.reasoning_effort or implementer.heavyweight defaults.
6. Run scripts/check-model-catalog.sh and a PR-review fixture before committing.

Official sources:
EOF
  yq -r '.official_sources | to_entries[] | "- " + .key + ": " + .value.url + " last_verified_at=" + .value.last_verified_at' "$CATALOG"
fi

[ "$failures" -eq 0 ] || exit 1
