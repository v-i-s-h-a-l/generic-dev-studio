#!/usr/bin/env bash
# Resolve and check Studio v2 context budgets across role, skill, and invocation dimensions.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/core/v2/context-budget/manifest.json"
FORMAT="text"
ACTION=""
ROLE=""
SKILL=""
INVOCATION=""
ESTIMATED_TOKENS=""
ROLES_CSV=""
OUTPUT=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-context-budget.sh [--manifest <path>] --validate
       scripts/v2-context-budget.sh [--manifest <path>] --resolve --role <role-or-alias> [--skill <name>] [--invocation <name>] [--estimated-tokens <n>] [--format text|json]
       scripts/v2-context-budget.sh [--manifest <path>] --report [--roles <csv>] [--format json|markdown] [--output <file>]
USAGE
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-context-budget: jq is required\n' >&2
    exit 3
  }
}

normalize_role() {
  "$REPO_ROOT/scripts/v2-role-resolve.sh" --format text "$1" 2>/dev/null
}

validate_manifest() {
  [ -r "$MANIFEST" ] || {
    printf 'v2-context-budget: manifest not readable: %s\n' "$MANIFEST" >&2
    exit 3
  }

  jq -e '
    .schema_version.name == "context-budget" and
    .kind == "studio-v2-context-budget" and
    (.defaults.max_context_tokens | type == "number") and
    (.defaults.warning_ratio < .defaults.exceeded_ratio) and
    (.roles | type == "array" and length > 0) and
    ([.roles[].role] | unique | length) == (.roles | length) and
    ([.skills[].skill] | unique | length) == (.skills | length) and
    ([.invocations[].invocation] | unique | length) == (.invocations | length)
  ' "$MANIFEST" >/dev/null || {
    printf 'v2-context-budget: invalid context-budget manifest: %s\n' "$MANIFEST" >&2
    exit 3
  }

  local role
  while IFS= read -r role; do
    [ -z "$role" ] && continue
    if ! "$REPO_ROOT/scripts/v2-role-resolve.sh" "$role" >/dev/null 2>&1; then
      printf 'v2-context-budget: unknown role in manifest: %s\n' "$role" >&2
      exit 3
    fi
  done < <(jq -r '.roles[].role' "$MANIFEST")

  local source
  while IFS= read -r source; do
    [ -z "$source" ] && continue
    if [ ! -r "$REPO_ROOT/$source" ]; then
      printf 'v2-context-budget: skill source not readable: %s\n' "$source" >&2
      exit 3
    fi
  done < <(jq -r '.skills[].source' "$MANIFEST")
}

resolve_budget() {
  [ -n "$ROLE" ] || { usage; exit 2; }
  case "$FORMAT" in
    text|json) ;;
    *) usage; exit 2 ;;
  esac
  case "$ESTIMATED_TOKENS" in
    ""|*[!0-9]*)
      [ -z "$ESTIMATED_TOKENS" ] || { usage; exit 2; }
      ;;
  esac

  local canonical_role
  canonical_role=$(normalize_role "$ROLE") || {
    printf 'v2-context-budget: unknown role or alias: %s\n' "$ROLE" >&2
    exit 1
  }

  local result
  result=$(jq -e \
    --arg role "$canonical_role" \
    --arg skill "$SKILL" \
    --arg invocation "$INVOCATION" \
    --argjson estimated "$(if [ -n "$ESTIMATED_TOKENS" ]; then printf '%s' "$ESTIMATED_TOKENS"; else printf 'null'; fi)" '
    . as $m |
    ($m.roles[] | select(.role == $role)) as $role_budget |
    (if $skill == "" then null else ($m.skills[]? | select(.skill == $skill)) end) as $skill_budget |
    (if $invocation == "" then null else ($m.invocations[]? | select(.invocation == $invocation)) end) as $invocation_budget |
    if $skill != "" and $skill_budget == null and $m.resolution.unknown_skill_policy == "reject" then
      error("unknown skill: " + $skill)
    elif $invocation != "" and $invocation_budget == null and $m.resolution.unknown_invocation_policy == "reject" then
      error("unknown invocation: " + $invocation)
    else
      [
        {"dimension": "default", "name": "default", "max_context_tokens": $m.defaults.max_context_tokens},
        {"dimension": "role", "name": $role, "max_context_tokens": $role_budget.max_context_tokens},
        (if $skill_budget == null then empty else {"dimension": "skill", "name": $skill, "max_context_tokens": $skill_budget.max_context_tokens} end),
        (if $invocation_budget == null then empty else {"dimension": "invocation", "name": $invocation, "max_context_tokens": $invocation_budget.max_context_tokens} end)
      ] as $matches |
      ($matches | min_by(.max_context_tokens)) as $effective |
      (if $estimated == null then null else ($estimated / $effective.max_context_tokens) end) as $ratio |
      (if $estimated == null then "unmeasured"
       elif $ratio >= $m.defaults.exceeded_ratio then "exceeded"
       elif $ratio >= $m.defaults.warning_ratio then "warning"
       else "ok" end) as $status |
      {
        schema_version: {"name": "context-budget-resolution", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
        role: $role,
        skill: (if $skill == "" then null else $skill end),
        invocation: (if $invocation == "" then null else $invocation end),
        effective_budget_tokens: $effective.max_context_tokens,
        limiting_dimension: $effective.dimension,
        limiting_name: $effective.name,
        matched_budgets: $matches,
        estimated_tokens: $estimated,
        ratio: (if $ratio == null then null else (($ratio * 1000 | round) / 1000) end),
        status: $status,
        telemetry_event: (if $status == "exceeded" then $m.telemetry.exceeded_event else $m.telemetry.resolved_event end)
      }
    end
  ' "$MANIFEST") || {
    printf 'v2-context-budget: failed to resolve budget\n' >&2
    exit 1
  }

  if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$result" | jq -r '
      "role=\(.role) skill=\(.skill // "none") invocation=\(.invocation // "none") budget=\(.effective_budget_tokens) limiting=\(.limiting_dimension):\(.limiting_name) status=\(.status) ratio=\(.ratio // "n/a") event=\(.telemetry_event)"
    '
  fi
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

common_surface_paths() {
  cat <<'PATHS'
core/v2/context-budget/manifest.json
core/v2/registry/roles.json
core/v2/BOOTSTRAP.md
PATHS
}

role_surface_paths() {
  local role="$1"
  common_surface_paths
  case "$role" in
    manager)
      cat <<'PATHS'
core/v2/skills/dev-studio/SKILL.md
core/v2/skills/dev-studio/routing.yaml
core/v2/skills/dev-studio/forwarders.yaml
core/v2/skills/dev-studio/portability.yaml
PATHS
      ;;
    host-adapter)
      cat <<'PATHS'
hosts/ADAPTER-SPEC.md
hosts/registry.yaml
.claude-plugin/capabilities.yaml
.claude-reviewer/capabilities.yaml
.codex-reviewer/capabilities.yaml
.codex/capabilities.yaml
PATHS
      ;;
    *)
      printf 'core/v2/roles/%s.yaml\n' "$role"
      ;;
  esac
}

report_roles() {
  if [ -n "$ROLES_CSV" ]; then
    printf '%s\n' "$ROLES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | unique_lines
  else
    jq -r '.roles[].role' "$MANIFEST"
  fi
}

json_array_from_lines() {
  jq -R . | jq -s .
}

role_report_row() {
  local role="$1"
  local budget paths_json missing_json bytes estimated row_status ratio

  budget=$(jq -er --arg role "$role" '.roles[] | select(.role == $role) | .max_context_tokens' "$MANIFEST") || {
    printf 'v2-context-budget: role not in manifest: %s\n' "$role" >&2
    exit 2
  }

  local paths_file missing_file
  paths_file=$(mktemp -t v2-context-budget-paths.XXXXXX) || exit 2
  missing_file=$(mktemp -t v2-context-budget-missing.XXXXXX) || exit 2
  role_surface_paths "$role" | unique_lines > "$paths_file"
  : > "$missing_file"

  bytes=0
  local path full_path path_bytes
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    full_path="$REPO_ROOT/$path"
    if [ ! -r "$full_path" ]; then
      printf '%s\n' "$path" >> "$missing_file"
      continue
    fi
    path_bytes=$(wc -c < "$full_path" | tr -d ' ')
    bytes=$((bytes + path_bytes))
  done < "$paths_file"

  paths_json=$(json_array_from_lines < "$paths_file")
  missing_json=$(json_array_from_lines < "$missing_file")
  rm -f "$paths_file" "$missing_file"

  if [ "$missing_json" != "[]" ]; then
    estimated=null
    ratio=null
    row_status="unmeasured"
  else
    estimated=$(((bytes + 2) / 3))
    ratio=$(jq -n --argjson estimated "$estimated" --argjson budget "$budget" '(($estimated / $budget) * 1000 | round) / 1000')
    row_status=$(jq -nr \
      --argjson estimated "$estimated" \
      --argjson budget "$budget" \
      --argjson warning "$(jq '.defaults.warning_ratio' "$MANIFEST")" \
      --argjson exceeded "$(jq '.defaults.exceeded_ratio' "$MANIFEST")" \
      '($estimated / $budget) as $ratio |
       if $ratio >= $exceeded then "over_budget" elif $ratio >= $warning then "warning" else "under_budget" end')
  fi

  jq -n \
    --arg role "$role" \
    --arg status "$row_status" \
    --arg estimator "ceil(bytes / 3)" \
    --argjson budget "$budget" \
    --argjson bytes "$bytes" \
    --argjson estimated "$estimated" \
    --argjson ratio "$ratio" \
    --argjson paths "$paths_json" \
    --argjson missing "$missing_json" \
    '{
      role: $role,
      budget_tokens: $budget,
      estimated_tokens: $estimated,
      source_bytes: $bytes,
      ratio: $ratio,
      status: $status,
      estimator: $estimator,
      evidence_files: $paths,
      missing_evidence_files: $missing
    }'
}

build_report_json() {
  validate_manifest

  local rows_file
  rows_file=$(mktemp -t v2-context-budget-report.XXXXXX) || exit 2
  : > "$rows_file"

  local role
  while IFS= read -r role; do
    [ -n "$role" ] || continue
    role=$(normalize_role "$role") || {
      printf 'v2-context-budget: unknown role or alias: %s\n' "$role" >&2
      rm -f "$rows_file"
      exit 2
    }
    role_report_row "$role" >> "$rows_file"
  done < <(report_roles)

  jq -s \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manifest_path "${MANIFEST#$REPO_ROOT/}" \
    --arg estimator "ceil(bytes / 3)" \
    --arg evidence_scope "static contract-surface lower bound; not runtime token telemetry" \
    --argjson warning_ratio "$(jq '.defaults.warning_ratio' "$MANIFEST")" \
    --argjson exceeded_ratio "$(jq '.defaults.exceeded_ratio' "$MANIFEST")" \
    '{
      schema_version: {"name": "context-budget-report", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
      generated_at: $generated_at,
      manifest_path: $manifest_path,
      estimator: $estimator,
      evidence_scope: $evidence_scope,
      warning_ratio: $warning_ratio,
      exceeded_ratio: $exceeded_ratio,
      roles: .,
      summary: {
        under_budget: [.[] | select(.status == "under_budget") | .role],
        warning: [.[] | select(.status == "warning") | .role],
        over_budget: [.[] | select(.status == "over_budget") | .role],
        unmeasured: [.[] | select(.status == "unmeasured") | .role]
      }
    }' "$rows_file"
  rm -f "$rows_file"
}

render_report_markdown() {
  jq -r '
    "# Studio v2 Context Budget Report",
    "",
    "- Manifest: `\(.manifest_path)`",
    "- Estimator: `\(.estimator)`",
    "- Evidence scope: \(.evidence_scope)",
    "",
    "This report measures the committed static files each role is expected to load first. It is a lower-bound estimate, not runtime token telemetry from a model invocation.",
    "",
    "On-demand skill content is excluded from each role surface and remains governed by the skill ceilings in the context-budget manifest.",
    "",
    "## Summary",
    "",
    "- Under budget: \((.summary.under_budget | length))",
    "- Warning: \((.summary.warning | length))",
    "- Over budget: \((.summary.over_budget | length))",
    "- Unmeasured: \((.summary.unmeasured | length))",
    "",
    "## Under Budget",
    "",
    (if (.summary.under_budget | length) == 0 then "_None_"
     else (.roles[] | select(.status == "under_budget") | "- `\(.role)`: \(.estimated_tokens) / \(.budget_tokens) tokens (ratio \(.ratio))")
     end),
    "",
    "## Warning",
    "",
    (if (.summary.warning | length) == 0 then "_None_"
     else (.roles[] | select(.status == "warning") | "- `\(.role)`: \(.estimated_tokens) / \(.budget_tokens) tokens (ratio \(.ratio))")
     end),
    "",
    "## Over Budget",
    "",
    (if (.summary.over_budget | length) == 0 then "_None_"
     else (.roles[] | select(.status == "over_budget") | "- `\(.role)`: \(.estimated_tokens) / \(.budget_tokens) tokens (ratio \(.ratio))")
     end),
    "",
    "## Unmeasured",
    "",
    (if (.summary.unmeasured | length) == 0 then "_None_"
     else (.roles[] | select(.status == "unmeasured") | "- `\(.role)`: missing \((.missing_evidence_files | map("`" + . + "`") | join(", ")))")
     end),
    "",
    "## Role Evidence",
    "",
    (.roles[] | "### `\(.role)`\n\n- Status: `\(.status)`\n- Budget tokens: \(.budget_tokens)\n- Estimated tokens: \(.estimated_tokens // "unmeasured")\n- Source bytes: \(.source_bytes)\n- Evidence files:\n\(.evidence_files | map("  - `" + . + "`") | join("\n"))")
  '
}

write_or_print() {
  if [ -n "$OUTPUT" ]; then
    cat > "$OUTPUT"
  else
    cat
  fi
}

report_budget() {
  local report_json
  report_json=$(build_report_json)
  case "$FORMAT" in
    json) printf '%s\n' "$report_json" | write_or_print ;;
    markdown) printf '%s\n' "$report_json" | render_report_markdown | write_or_print ;;
    *) usage; exit 2 ;;
  esac
}

require_jq

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MANIFEST="$2"
      shift 2
      ;;
    --validate)
      [ -z "$ACTION" ] || { usage; exit 2; }
      ACTION="validate"
      shift
      ;;
	    --resolve)
	      [ -z "$ACTION" ] || { usage; exit 2; }
	      ACTION="resolve"
	      shift
	      ;;
	    --report)
	      [ -z "$ACTION" ] || { usage; exit 2; }
	      ACTION="report"
	      FORMAT="json"
	      shift
	      ;;
    --role)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ROLE="$2"
      shift 2
      ;;
    --skill)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SKILL="$2"
      shift 2
      ;;
    --invocation)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      INVOCATION="$2"
      shift 2
      ;;
    --estimated-tokens)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ESTIMATED_TOKENS="$2"
      shift 2
      ;;
	    --format)
	      [ "$#" -ge 2 ] || { usage; exit 2; }
	      FORMAT="$2"
	      case "$FORMAT" in
	        text|json|markdown) ;;
	        *) usage; exit 2 ;;
	      esac
	      shift 2
	      ;;
	    --roles)
	      [ "$#" -ge 2 ] || { usage; exit 2; }
	      ROLES_CSV="$2"
	      shift 2
	      ;;
	    --output)
	      [ "$#" -ge 2 ] || { usage; exit 2; }
	      OUTPUT="$2"
	      shift 2
	      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$ACTION" in
  validate)
    validate_manifest
    printf 'v2-context-budget: ok\n' >&2
    ;;
	  resolve)
	    validate_manifest
	    resolve_budget
	    ;;
	  report)
	    report_budget
	    ;;
  *)
    usage
    exit 2
    ;;
esac
