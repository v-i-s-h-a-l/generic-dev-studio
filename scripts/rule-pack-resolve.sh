#!/usr/bin/env bash
# rule-pack-resolve.sh - resolve Studio v2 rule-pack summaries for a chain/task context.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

MANIFEST=""
CHAIN_NAME=""
ISSUE_NUMBER=""
PROFILE=""
ROLE="worker"
MODE="chain_runner"
PHASE="implementation"
CLASSIFIER_JSON="{}"
CATALOG="$REPO_ROOT/core/v2/rule-packs/catalog.yaml"

usage() {
  cat >&2 <<'EOF'
usage: rule-pack-resolve.sh --manifest <path> [--chain <name>] [--issue <number>] [--profile <path>] [--role <role>] [--mode <mode>] [--phase <phase>] [--classifier-json <json>|--classifier-file <path>] [--catalog <path>]

Resolves chain/task manifest rule_packs plus deterministic applicability
predicates into machine-readable selected/skipped rule-pack summaries.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest requires a path}"; shift 2 ;;
    --manifest=*) MANIFEST="${1#--manifest=}"; shift ;;
    --chain) CHAIN_NAME="${2:?--chain requires a name}"; shift 2 ;;
    --chain=*) CHAIN_NAME="${1#--chain=}"; shift ;;
    --issue) ISSUE_NUMBER="${2:?--issue requires a number}"; shift 2 ;;
    --issue=*) ISSUE_NUMBER="${1#--issue=}"; shift ;;
    --profile) PROFILE="${2:?--profile requires a path}"; shift 2 ;;
    --profile=*) PROFILE="${1#--profile=}"; shift ;;
    --role) ROLE="${2:?--role requires a role}"; shift 2 ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    --mode) MODE="${2:?--mode requires a mode}"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    --phase) PHASE="${2:?--phase requires a phase}"; shift 2 ;;
    --phase=*) PHASE="${1#--phase=}"; shift ;;
    --classifier-json) CLASSIFIER_JSON="${2:?--classifier-json requires JSON}"; shift 2 ;;
    --classifier-json=*) CLASSIFIER_JSON="${1#--classifier-json=}"; shift ;;
    --classifier-file) CLASSIFIER_JSON=$(cat "${2:?--classifier-file requires a path}"); shift 2 ;;
    --classifier-file=*) CLASSIFIER_JSON=$(cat "${1#--classifier-file=}"); shift ;;
    --catalog) CATALOG="${2:?--catalog requires a path}"; shift 2 ;;
    --catalog=*) CATALOG="${1#--catalog=}"; shift ;;
    -h|--help) usage ;;
    *)
      if [ -z "$MANIFEST" ]; then
        MANIFEST="$1"
        shift
      else
        printf 'rule-pack-resolve: unexpected argument: %s\n' "$1" >&2
        usage
      fi
      ;;
  esac
done

[ -n "$MANIFEST" ] || usage
[ -f "$MANIFEST" ] || { printf 'rule-pack-resolve: manifest not found: %s\n' "$MANIFEST" >&2; exit 2; }
[ -f "$CATALOG" ] || { printf 'rule-pack-resolve: catalog not found: %s\n' "$CATALOG" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'rule-pack-resolve: jq is required\n' >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { printf 'rule-pack-resolve: yq is required\n' >&2; exit 2; }
printf '%s' "$CLASSIFIER_JSON" | jq empty >/dev/null 2>&1 || {
  printf 'rule-pack-resolve: classifier JSON is invalid\n' >&2
  exit 2
}

TMPROOT=$(mktemp -d -t rule-pack-resolve.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

MANIFEST_JSON="$TMPROOT/manifest.json"
CATALOG_JSON="$TMPROOT/catalog.json"
PROFILE_JSON="$TMPROOT/profile.json"
REQUESTS_JSON="$TMPROOT/requests.json"
CONTEXT_JSON="$TMPROOT/context.json"
RESOLVED_CATALOG_JSON="$TMPROOT/resolved-catalog.json"

yq -o=json '.' "$MANIFEST" >"$MANIFEST_JSON"
yq -o=json '.' "$CATALOG" >"$CATALOG_JSON"
if [ -n "$PROFILE" ] && [ -f "$PROFILE" ]; then
  yq -o=json '.' "$PROFILE" >"$PROFILE_JSON"
else
  printf '{}\n' >"$PROFILE_JSON"
fi

catalog_dir=$(cd "$(dirname "$CATALOG")" && pwd)
cp "$CATALOG_JSON" "$RESOLVED_CATALOG_JSON"
while IFS=$'\t' read -r pack_id metadata_path; do
  [ -n "$pack_id" ] || continue
  case "$metadata_path" in
    ""|null) continue ;;
    "$CATALOG"|"$REPO_ROOT/"*catalog.yaml|core/v2/rule-packs/catalog.yaml) continue ;;
  esac
  if [ -f "$REPO_ROOT/$metadata_path" ]; then
    overlay_path="$REPO_ROOT/$metadata_path"
  elif [ -f "$catalog_dir/$metadata_path" ]; then
    overlay_path="$catalog_dir/$metadata_path"
  else
    continue
  fi
  case "$(basename "$overlay_path")" in
    pack.yaml|pack.yml) ;;
    *) continue ;;
  esac
  overlay_json="$TMPROOT/overlay-$pack_id.json"
  yq -o=json '.' "$overlay_path" >"$overlay_json"
  jq --arg id "$pack_id" --slurpfile overlay "$overlay_json" '
    .packs |= map(if .id == $id then (. * $overlay[0]) else . end)
  ' "$RESOLVED_CATALOG_JSON" >"$RESOLVED_CATALOG_JSON.next"
  mv "$RESOLVED_CATALOG_JSON.next" "$RESOLVED_CATALOG_JSON"
done < <(jq -r '.packs[] | [.id, (.metadata_path // "")] | @tsv' "$CATALOG_JSON")

jq -n \
  --slurpfile manifest "$MANIFEST_JSON" \
  --arg chain "$CHAIN_NAME" \
  --arg issue "$ISSUE_NUMBER" '
  def ids($v):
    if $v == null then []
    elif ($v | type) == "array" then [$v[] | tostring]
    elif ($v | type) == "string" then [$v]
    else []
    end;
  def spec($v):
    if $v == null then {required:[], optional:[], advisory:[], disabled:[]}
    elif ($v | type) == "array" then {required:ids($v), optional:[], advisory:[], disabled:[]}
    elif ($v | type) == "string" then {required:[$v], optional:[], advisory:[], disabled:[]}
    elif ($v | type) == "object" then {
      required: ids($v.required // $v.require),
      optional: ids($v.optional),
      advisory: ids($v.advisory),
      disabled: ids($v.disabled // $v.exclude // $v.excluded)
    }
    else {required:[], optional:[], advisory:[], disabled:[]}
    end;
  def merge_specs($items):
    reduce $items[] as $item (
      {required:[], optional:[], advisory:[], disabled:[]};
      .required += ($item.required // [])
      | .optional += ($item.optional // [])
      | .advisory += ($item.advisory // [])
      | .disabled += ($item.disabled // [])
    )
    | .required |= unique
    | .optional |= unique
    | .advisory |= unique
    | .disabled |= unique;

  ($manifest[0]) as $m
  | spec($m.rule_packs) as $root
  | (if $chain == "" then null else ($m.chains // [] | map(select(.name == $chain)) | first) end) as $chain_obj
  | spec(($chain_obj // {}).rule_packs) as $chain_spec
  | (if $issue == "" or ($chain_obj == null) then null
     else (($chain_obj.issues // [])
       | map(select((type == "object") and (((.number // .issue) | tostring) == $issue)))
       | first)
     end) as $issue_obj
  | spec(($issue_obj // {}).rule_packs) as $issue_spec
  | merge_specs([$root, $chain_spec, $issue_spec])
  ' >"$REQUESTS_JSON"

jq -n \
  --slurpfile manifest "$MANIFEST_JSON" \
  --slurpfile profile "$PROFILE_JSON" \
  --argjson classifier "$CLASSIFIER_JSON" \
  --slurpfile requests "$REQUESTS_JSON" \
  --arg role "$ROLE" \
  --arg mode "$MODE" \
  --arg phase "$PHASE" \
  --arg chain "$CHAIN_NAME" \
  --arg issue "$ISSUE_NUMBER" '
  def key($prefix; $value):
    if ($value // "") == "" then {}
    else {($prefix + "_" + ($value | ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; ""))): true}
    end;
  def pack_key($prefix; $id):
    {($prefix + "_" + ($id | gsub("-"; "_"))): true};

  ($manifest[0]) as $m
  | ($profile[0]) as $p
  | ($requests[0]) as $r
  | ([($r.required // []), ($r.optional // []), ($r.advisory // [])] | flatten | unique) as $requested
  | ({}
    + $classifier
    + key("role"; $role)
    + key("mode"; $mode)
    + key("phase"; $phase)
    + (if (($m.chains // []) | length) > 0 then {manifest_chain_run:true} else {} end)
    + (if $issue != "" then {manifest_task_assignment:true} else {} end)
    + (if $chain != "" then {mode_chain_runner:true} else {} end)
    + (if (($p.stack // "") | ascii_downcase) == "ios" then {platform_ios:true} else {} end)
    + (if (($p.profile // "") | test("ios"; "i")) then {platform_ios:true} else {} end)
    + (reduce $requested[] as $id ({}; . + pack_key("manifest_requires"; $id)))
  ) as $predicates
  | {
      role:$role,
      mode:$mode,
      phase:$phase,
      chain:(if $chain == "" then null else $chain end),
      issue:(if $issue == "" then null else ($issue | tonumber? // $issue) end),
      predicates:$predicates,
      true_predicates: ($predicates | to_entries | map(select(.value == true) | .key) | sort)
    }
  ' >"$CONTEXT_JSON"

jq -n \
  --slurpfile catalog "$RESOLVED_CATALOG_JSON" \
  --slurpfile requests "$REQUESTS_JSON" \
  --slurpfile context "$CONTEXT_JSON" \
  --arg manifest "$MANIFEST" \
  --arg catalog_path "$CATALOG" \
  --arg repo_root "$REPO_ROOT" '
  def estimate($path):
    if ($path // "") == "" then 0
    else (((($repo_root + "/" + $path) | @sh) as $p | 0))
    end;
  def matches($pack; $predicates):
    (($pack.applicability.any_of // []) as $any
    | ($pack.applicability.all_of // []) as $all
    | ($pack.applicability.none_of // []) as $none
    | (($any | length) == 0 or any($any[]; ($predicates[.] == true)))
      and all($all[]; ($predicates[.] == true))
      and (all($none[]; ($predicates[.] != true))));
  def requirement($id; $r):
    if (($r.required // []) | index($id)) then "required"
    elif (($r.optional // []) | index($id)) then "optional"
    elif (($r.advisory // []) | index($id)) then "advisory"
    else null
    end;
  def source_for($requirement):
    if $requirement == null then "applicability" else "manifest" end;
  def reason_for($requirement):
    if $requirement == "required" then "required_by_manifest"
    elif $requirement == "optional" then "optional_manifest_pack_available"
    elif $requirement == "advisory" then "advisory_manifest_pack_available"
    else "applicability_predicates_matched"
    end;

  ($catalog[0]) as $cat
  | ($requests[0]) as $req
  | ($context[0]) as $ctx
  | ($cat.packs // []) as $packs
  | ($packs | map(.id)) as $known
  | ($req.disabled // []) as $disabled
  | ([($req.required // [])[] as $id | select(($known | index($id)) == null) | {
      type:"missing_required_pack",
      pack_id:$id,
      source:"manifest.rule_packs.required",
      reason_id:"rule_pack_required_missing",
      halt_class:"fatal",
      retry_action:"add the pack to core/v2/rule-packs/catalog.yaml or remove it from required rule_packs"
    }]) as $missing_required
  | ([($req.optional // [])[], ($req.advisory // [])[]] | map(. as $id | select(($known | index($id)) == null)) | unique | map({
      type:"missing_optional_pack",
      pack_id:.,
      source:"manifest.rule_packs.optional_or_advisory",
      reason:"optional or advisory pack is not in the catalog; continuing without it"
    })) as $missing_optional
  | ([
      $packs[]
      | . as $pack
      | (requirement($pack.id; $req)) as $requirement
      | (matches($pack; $ctx.predicates)) as $matched
      | select(($disabled | index($pack.id) | not) and (($requirement != null) or $matched))
      | {
          id:$pack.id,
          requirement:($requirement // "auto"),
          source:source_for($requirement),
          reason:reason_for($requirement),
          status:$pack.status,
          owner:$pack.owner,
          summary_path:$pack.summary_path,
          full_doc_path:$pack.full_doc_path,
          metadata_path:$pack.metadata_path,
          applicability:$pack.applicability,
          enforcement_policy:$pack.enforcement_policy,
          enforcement_hooks:$pack.enforcement_hooks,
          fixture_refs:$pack.fixture_refs
        }
    ]) as $selected_raw
  | ([
      $selected_raw[]
      | select((.status // "active") != "active" and (.requirement == "required"))
      | {
          type:"invalid_required_pack",
          pack_id:.id,
          source:"manifest.rule_packs.required",
          reason_id:"rule_pack_required_invalid",
          halt_class:"fatal",
          detail:"required pack is not active",
          retry_action:"select an active replacement or remove the required pack"
        }
    ]) as $inactive_required
  | ([
      $selected_raw[]
      | select((.requirement == "required") and ((.summary_path // "") == ""))
      | {
          type:"invalid_required_pack",
          pack_id:.id,
          source:"manifest.rule_packs.required",
          reason_id:"rule_pack_required_invalid",
          halt_class:"fatal",
          detail:"required pack has no summary_path",
          retry_action:"add summary_path or remove the required pack"
        }
    ]) as $missing_summary_required
  | ([
      $packs[]
      | . as $pack
      | (requirement($pack.id; $req)) as $requirement
      | (matches($pack; $ctx.predicates)) as $matched
      | select(($selected_raw | map(.id) | index($pack.id) | not))
      | {
          id:$pack.id,
          source:(if ($disabled | index($pack.id)) then "manifest" else "applicability" end),
          reason:(if ($disabled | index($pack.id)) then "disabled_by_manifest" else "applicability_predicates_not_matched" end),
          status:$pack.status,
          summary_path:$pack.summary_path
        }
    ]) as $skipped
  | ($missing_required + $inactive_required + $missing_summary_required) as $blockers
  | {
      schema_version:1,
      kind:"studio-v2-rule-pack-resolution",
      status:(if ($blockers | length) > 0 then "halt" else "ok" end),
      manifest:$manifest,
      catalog:$catalog_path,
      context:$ctx,
      requests:$req,
      selected_packs:$selected_raw,
      skipped_packs:$skipped,
      warnings:$missing_optional,
      blockers:$blockers,
      estimated_context_cost:{
        token_estimate:($cat.budget_policy.token_estimate // "chars_div_4_rounded_up"),
        always_loaded_budget_tokens:($cat.budget_policy.always_loaded_budget_tokens // 700),
        per_pack_summary_budget_tokens:($cat.budget_policy.per_pack_summary_budget_tokens // null),
        selected_summary_bundle_budget_tokens:($cat.budget_policy.selected_summary_bundle_budget_tokens // null),
        selected_pack_count:($selected_raw | length),
        summary_tokens_estimated:null
      },
      halt:(if ($blockers | length) > 0 then {
        reason_id:"rule_pack_resolution_blocked",
        halt_class:"fatal",
        blockers:$blockers,
        bypass:"Remove or fix required rule_packs; optional/advisory packs may be moved out of required."
      } else null end),
      compatibility:{
        argus_frontmatter_compatible:($cat.matching_policy.argus_frontmatter_compatible // false),
        divergence:"catalog pack applicability reuses Argus any_of/all_of/none_of semantics; resolver adds manifest/profile/role/mode predicates before matching"
      }
    }
  ' >"$TMPROOT/result.base.json"

cp "$TMPROOT/result.base.json" "$TMPROOT/result.json"

# jq cannot stat files portably, so fill summary estimates in shell while keeping
# the JSON shape deterministic.
summary_tokens=0
missing_selected_paths="$TMPROOT/missing-required-paths"
missing_optional_paths="$TMPROOT/missing-optional-paths"
: >"$missing_selected_paths"
: >"$missing_optional_paths"
while IFS=$'\t' read -r pack_id requirement path; do
  [ -n "$path" ] || continue
  if [ -f "$REPO_ROOT/$path" ]; then
    chars=$(wc -c < "$REPO_ROOT/$path" | tr -d ' ')
    summary_tokens=$((summary_tokens + ((chars + 3) / 4)))
  else
    case "$requirement" in
      optional|advisory)
        printf '%s\t%s\t%s\n' "$pack_id" "$requirement" "$path" >>"$missing_optional_paths"
        ;;
      *)
        printf '%s\t%s\t%s\n' "$pack_id" "$requirement" "$path" >>"$missing_selected_paths"
        ;;
    esac
  fi
done < <(jq -r '.selected_packs[] | [.id, (.requirement // "auto"), (.summary_path // "")] | @tsv' "$TMPROOT/result.json")

jq --argjson tokens "$summary_tokens" --rawfile missing "$missing_selected_paths" --rawfile optional_missing "$missing_optional_paths" '
  .estimated_context_cost.summary_tokens_estimated = $tokens
  | .warnings += (
      $optional_missing
      | split("\n")
      | map(select(length > 0) | split("\t"))
      | map({
          type:"missing_optional_summary_path",
          pack_id:.[0],
          requirement:.[1],
          source:"catalog.summary_path",
          reason:"optional or advisory selected pack summary is missing; continuing without blocking required context",
          summary_path:.[2]
        })
    )
  | .blockers += (
      $missing
      | split("\n")
      | map(select(length > 0) | split("\t"))
      | map({
          type:"missing_selected_summary_path",
          pack_id:.[0],
          requirement:.[1],
          source:"catalog.summary_path",
          reason_id:"rule_pack_summary_missing",
          halt_class:"fatal",
          summary_path:.[2],
          retry_action:"restore the summary path or remove the selected pack"
        })
    )
  | .status = (if (.blockers | length) > 0 then "halt" else "ok" end)
  | .halt = (if (.blockers | length) > 0 then {
      reason_id:"rule_pack_resolution_blocked",
      halt_class:"fatal",
      blockers:.blockers,
      bypass:"Remove or fix required rule_packs; optional/advisory packs may be moved out of required."
    } else null end)
' "$TMPROOT/result.json" >"$TMPROOT/result.final.json"
cat "$TMPROOT/result.final.json"

if jq -e '.status == "halt"' "$TMPROOT/result.final.json" >/dev/null 2>&1; then
  exit 3
fi
