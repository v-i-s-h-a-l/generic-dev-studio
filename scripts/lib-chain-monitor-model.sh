#!/usr/bin/env bash
# Row identity, source precedence, and snapshot shaping for chain monitor data.

# No `set -e` here. This file is sourced by scripts and fixture harnesses.

CHAIN_MONITOR_MODEL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-chain-monitor-config.sh disable=SC1091
. "$CHAIN_MONITOR_MODEL_LIB_DIR/lib-chain-monitor-config.sh"
# shellcheck source=lib-chain-run-state.sh disable=SC1091
. "$CHAIN_MONITOR_MODEL_LIB_DIR/lib-chain-run-state.sh"

chain_monitor_key_component() {
  printf '%s' "$1" | tr '\n\r\t:' '____'
}

chain_monitor_source_id_from_path() {
  local input_path="${1:?usage: chain_monitor_source_id_from_path <path>}"
  local rel="$input_path"
  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    case "$input_path" in "$git_root"/*) rel=${input_path#"$git_root/"} ;; esac
  fi
  printf '%s' "$rel" | sed -E 's#^\./##; s#[/:[:space:]]+#-#g; s#^-+##; s#-+$##'
}

chain_monitor_chain_key() {
  local source_kind="${1:?usage: chain_monitor_chain_key <source-kind> <source-id> <chain-id-or-name>}"
  local source_id="${2:?usage: chain_monitor_chain_key <source-kind> <source-id> <chain-id-or-name>}"
  local chain_id="${3:?usage: chain_monitor_chain_key <source-kind> <source-id> <chain-id-or-name>}"
  printf 'chain:%s:%s:%s\n' \
    "$(chain_monitor_key_component "$source_kind")" \
    "$(chain_monitor_key_component "$source_id")" \
    "$(chain_monitor_key_component "$chain_id")"
}

chain_monitor_issue_task_key() {
  local parent_chain_key="${1:?usage: chain_monitor_issue_task_key <parent-chain-key> <issue-number>}"
  local issue_number="${2:?usage: chain_monitor_issue_task_key <parent-chain-key> <issue-number>}"
  printf 'task:%s:issue:%s\n' "$parent_chain_key" "$(chain_monitor_key_component "$issue_number")"
}

chain_monitor_named_task_key() {
  local parent_chain_key="${1:?usage: chain_monitor_named_task_key <parent-chain-key> <task-id-or-slug>}"
  local task_id="${2:?usage: chain_monitor_named_task_key <parent-chain-key> <task-id-or-slug>}"
  printf 'task:%s:task:%s\n' "$parent_chain_key" "$(chain_monitor_key_component "$task_id")"
}

chain_monitor_source_precedence_rank() {
  case "$1" in
    persisted-run) printf '1\n' ;;
    runtime-manifest) printf '2\n' ;;
    repo-manifest) printf '3\n' ;;
    slack-legacy) printf '4\n' ;;
    *) printf '99\n' ;;
  esac
}

chain_monitor_effective_status() {
  local raw="${1:-}" updated_epoch="${2:-0}" completed_epoch="${3:-0}" now_epoch="${4:-0}"
  local stale_threshold_s="${5:-$CHAIN_MONITOR_STALE_THRESHOLD_S}"
  local completed_retention_s="${6:-$CHAIN_MONITOR_COMPLETED_RETENTION_S}"
  local normalized base age
  normalized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_ ' '--')
  case "$normalized" in
    available|ready|open) base="available" ;;
    queued|pending|planned) base="queued" ;;
    running|active|in-progress|inprogress) base="running" ;;
    paused|halted|waiting) base="paused" ;;
    blocked|implementation-scope-blocked) base="blocked" ;;
    failed|failure|error) base="failed" ;;
    completed|merged|closed|done|success) base="completed" ;;
    archived) base="archived" ;;
    ""|null|unknown) base="unknown" ;;
    *) base="unknown" ;;
  esac

  if [ "$base" = "completed" ] \
    && [ "${completed_epoch:-0}" -gt 0 ] \
    && [ "${now_epoch:-0}" -gt 0 ] \
    && [ "${completed_retention_s:-0}" -gt 0 ]; then
    age=$((now_epoch - completed_epoch))
    if [ "$age" -ge "$completed_retention_s" ]; then
      printf 'archived\n'
      return 0
    fi
  fi

  case "$base" in
    available|queued|running|paused)
      if [ "${updated_epoch:-0}" -gt 0 ] \
        && [ "${now_epoch:-0}" -gt 0 ] \
        && [ "${stale_threshold_s:-0}" -gt 0 ]; then
        age=$((now_epoch - updated_epoch))
        if [ "$age" -ge "$stale_threshold_s" ]; then
          printf 'stale\n'
          return 0
        fi
      fi
      ;;
  esac

  printf '%s\n' "$base"
}

chain_monitor_status_cases_json() {
  local table="${1:?usage: chain_monitor_status_cases_json <table-json>}"
  local now_epoch stale_threshold_s completed_retention_s
  now_epoch=$(jq -r '.now_epoch' "$table")
  stale_threshold_s=$(jq -r '.stale_threshold_s' "$table")
  completed_retention_s=$(jq -r '.completed_retention_s' "$table")
  jq -c '.cases[]' "$table" | while IFS= read -r row; do
    local name raw updated completed expected actual
    name=$(printf '%s\n' "$row" | jq -r '.name')
    raw=$(printf '%s\n' "$row" | jq -r '.raw_status // ""')
    updated=$(printf '%s\n' "$row" | jq -r '.updated_epoch // 0')
    completed=$(printf '%s\n' "$row" | jq -r '.completed_epoch // 0')
    expected=$(printf '%s\n' "$row" | jq -r '.expected')
    actual=$(chain_monitor_effective_status "$raw" "$updated" "$completed" "$now_epoch" "$stale_threshold_s" "$completed_retention_s")
    jq -cn --arg name "$name" --arg raw_status "$raw" --arg expected "$expected" --arg actual "$actual" \
      '{name:$name, raw_status:$raw_status, expected:$expected, actual:$actual, passed:($expected == $actual)}'
  done | jq -s '{schema_version:1, cases:.}'
}

chain_monitor_claims_from_manifest_json() {
  local source_kind="${1:?usage: chain_monitor_claims_from_manifest_json <source-kind> <source-id> <manifest-path> <now-epoch> <stale-threshold-s> <completed-retention-s>}"
  local source_id="${2:?usage: chain_monitor_claims_from_manifest_json <source-kind> <source-id> <manifest-path> <now-epoch> <stale-threshold-s> <completed-retention-s>}"
  local manifest_path="${3:?usage: chain_monitor_claims_from_manifest_json <source-kind> <source-id> <manifest-path> <now-epoch> <stale-threshold-s> <completed-retention-s>}"
  local now_epoch="${4:-0}" stale_threshold_s="${5:-$CHAIN_MONITOR_STALE_THRESHOLD_S}" completed_retention_s="${6:-$CHAIN_MONITOR_COMPLETED_RETENTION_S}"
  local precedence manifest_json default_status
  command -v yq >/dev/null 2>&1 || { printf 'chain-monitor: yq required for manifest claims\n' >&2; return 2; }
  precedence=$(chain_monitor_source_precedence_rank "$source_kind")
  manifest_json=$(yq -o=json '.' "$manifest_path") || return 1
  case "$source_kind" in
    runtime-manifest) default_status="queued" ;;
    *) default_status="available" ;;
  esac
  jq -c \
    --arg source_kind "$source_kind" \
    --arg source_id "$source_id" \
    --argjson precedence "$precedence" \
    --arg manifest_label "$(basename "$manifest_path")" \
    --arg default_status "$default_status" \
    --argjson now_epoch "$now_epoch" \
    --argjson stale_threshold_s "$stale_threshold_s" \
    --argjson completed_retention_s "$completed_retention_s" \
    '
    def clean: tostring | gsub("[:\n\r\t]"; "_");
    def epoch:
      if . == null then 0
      elif type == "number" then .
      elif type == "string" then (try fromdateiso8601 catch 0)
      else 0 end;
    def effective($raw; $updated; $completed):
      (($raw // "") | tostring | ascii_downcase | gsub("[_ ]"; "-")) as $r
      | (if ["available","ready","open"] | index($r) then "available"
        elif ["queued","pending","planned"] | index($r) then "queued"
        elif ["running","active","in-progress","inprogress"] | index($r) then "running"
        elif ["paused","halted","waiting"] | index($r) then "paused"
        elif ["blocked","implementation-scope-blocked"] | index($r) then "blocked"
        elif ["failed","failure","error"] | index($r) then "failed"
        elif ["completed","merged","closed","done","success"] | index($r) then "completed"
        elif $r == "archived" then "archived"
        else "unknown" end) as $base
      | if $base == "completed" and (($completed | epoch) > 0) and ($now_epoch > 0) and (($now_epoch - ($completed | epoch)) >= $completed_retention_s)
        then "archived"
        elif (["available","queued","running","paused"] | index($base)) and (($updated | epoch) > 0) and ($now_epoch > 0) and (($now_epoch - ($updated | epoch)) >= $stale_threshold_s)
        then "stale"
        else $base end;
    def title_with_id($name; $id):
      if (($id // "") != "" and ($id // "") != ($name // "")) then "\($name) [\($id)]" else $name end;
    def issue_number($item):
      if ($item | type) == "number" then $item
      elif ($item | type) == "object" then ($item.number // $item.issue // empty)
      else empty end;
    def task_slug($item):
      if ($item | type) == "object" then ($item.task // $item.task_id // $item.slug // empty)
      else empty end;
    def title_for($item):
      if ($item | type) == "object" then ($item.title // $item.summary // "")
      else "" end;
    . as $root
    | [
      (.chains // [])[]
      | . as $chain
      | ($chain.name // $chain.id // "unknown-chain" | tostring) as $chain_name
      | ($chain.chain_run_id // $chain.chain_id // $chain.id // $chain_name | tostring) as $chain_id
      | "chain:\($source_kind | clean):\($source_id | clean):\($chain_id | clean)" as $chain_key
      | "chain:\($chain_name | clean)" as $logical_key
      | [($chain.issues // [])[]? | issue_number(.) | tonumber?] as $issue_numbers
      | [($chain.issues // [])[]? | task_slug(.) | select(. != "")] as $task_slugs
      | (($chain.status // $default_status) | tostring) as $raw_status
      | effective($raw_status; ($chain.updated_at // $chain.created_at // null); ($chain.completed_at // null)) as $status
      | {
          claim_kind:"chain",
          logical_key:$logical_key,
          row_key:$chain_key,
          source:{kind:$source_kind,id:$source_id,precedence:$precedence},
          chain_name:$chain_name,
          issue_numbers:$issue_numbers,
          snapshot:{
            schema_version:1,
            row_key:$chain_key,
            row_type:"chain",
            source:{kind:$source_kind,id:$source_id,precedence:$precedence},
            fields:{
              title:title_with_id($chain_name; $chain_id),
              status:$status,
              manifest:$manifest_label,
              summary:($chain.summary // ""),
              progress:(if (($issue_numbers | length) + ($task_slugs | length)) > 0 then "\(($issue_numbers | length) + ($task_slugs | length)) tasks defined" else "" end),
              blocker:($chain.blocker // "")
            }
          }
        },
        (($chain.issues // [])[]?
          | . as $task
          | (issue_number($task) | tostring) as $issue
          | (task_slug($task) | tostring) as $slug
          | select(($issue != "") or ($slug != ""))
          | if $issue != "" then
              "task:\($chain_key):issue:\($issue | clean)" as $row_key
              | {
                  claim_kind:"task",
                  parent_logical_key:$logical_key,
                  parent_row_key:$chain_key,
                  row_key:$row_key,
                  source:{kind:$source_kind,id:$source_id,precedence:$precedence},
                  snapshot:{
                    schema_version:1,
                    row_key:$row_key,
                    row_type:"task",
                    parent_row_key:$chain_key,
                    source:{kind:$source_kind,id:$source_id,precedence:$precedence},
                    fields:{
                      title:("Issue #\($issue)"),
                      status:(effective(($task.status // "queued"); ($task.updated_at // null); ($task.completed_at // null))),
                      manifest:$manifest_label,
                      summary:(title_for($task)),
                      progress:"",
                      blocker:($task.blocker // "")
                    }
                  }
                }
            else
              "task:\($chain_key):task:\($slug | clean)" as $row_key
              | {
                  claim_kind:"task",
                  parent_logical_key:$logical_key,
                  parent_row_key:$chain_key,
                  row_key:$row_key,
                  source:{kind:$source_kind,id:$source_id,precedence:$precedence},
                  snapshot:{
                    schema_version:1,
                    row_key:$row_key,
                    row_type:"task",
                    parent_row_key:$chain_key,
                    source:{kind:$source_kind,id:$source_id,precedence:$precedence},
                    fields:{
                      title:$slug,
                      status:(effective(($task.status // "queued"); ($task.updated_at // null); ($task.completed_at // null))),
                      manifest:$manifest_label,
                      summary:(title_for($task)),
                      progress:"",
                      blocker:($task.blocker // "")
                    }
                  }
                }
            end)
    ] | flatten
    ' <<<"$manifest_json"
}

chain_monitor_claims_from_persisted_run_json() {
  local source_id="${1:?usage: chain_monitor_claims_from_persisted_run_json <source-id> <state-json> <now-epoch> <stale-threshold-s> <completed-retention-s>}"
  local state_json_path="${2:?usage: chain_monitor_claims_from_persisted_run_json <source-id> <state-json> <now-epoch> <stale-threshold-s> <completed-retention-s>}"
  local now_epoch="${3:-0}" stale_threshold_s="${4:-$CHAIN_MONITOR_STALE_THRESHOLD_S}" completed_retention_s="${5:-$CHAIN_MONITOR_COMPLETED_RETENTION_S}"
  local precedence events_json_path projection_json_path jq_rc
  precedence=$(chain_monitor_source_precedence_rank persisted-run)
  events_json_path=$(chain_run_state_events_path_for_state "$state_json_path")
  projection_json_path=$(mktemp -t chain-monitor-run-projection.XXXXXX)
  if ! chain_run_state_projection_file "$state_json_path" "$events_json_path" "$projection_json_path" 2>/dev/null; then
    rm -f "$projection_json_path"
    return 1
  fi
  jq -c \
    --arg source_kind "persisted-run" \
    --arg source_id "$source_id" \
    --argjson precedence "$precedence" \
    --argjson now_epoch "$now_epoch" \
    --argjson stale_threshold_s "$stale_threshold_s" \
    --argjson completed_retention_s "$completed_retention_s" \
    '
    def clean: tostring | gsub("[:\n\r\t]"; "_");
    def epoch:
      if . == null then 0
      elif type == "number" then .
      elif type == "string" then (try fromdateiso8601 catch 0)
      else 0 end;
    def effective($raw; $updated; $completed):
      (($raw // "") | tostring | ascii_downcase | gsub("[_ ]"; "-")) as $r
      | (if ["available","ready","open"] | index($r) then "available"
        elif ["queued","pending","planned"] | index($r) then "queued"
        elif ["running","active","in-progress","inprogress"] | index($r) then "running"
        elif ["paused","halted","waiting"] | index($r) then "paused"
        elif ["blocked","implementation-scope-blocked"] | index($r) then "blocked"
        elif ["failed","failure","error"] | index($r) then "failed"
        elif ["completed","merged","closed","done","success"] | index($r) then "completed"
        elif $r == "archived" then "archived"
        else "unknown" end) as $base
      | if $base == "completed" and (($completed | epoch) > 0) and ($now_epoch > 0) and (($now_epoch - ($completed | epoch)) >= $completed_retention_s)
        then "archived"
        elif (["available","queued","running","paused"] | index($base)) and (($updated | epoch) > 0) and ($now_epoch > 0) and (($now_epoch - ($updated | epoch)) >= $stale_threshold_s)
        then "stale"
        else $base end;
    def rollup_status($base; $issue_statuses):
      if $base == "unknown" then "unknown"
      elif ($issue_statuses | index("unknown")) then "unknown"
      elif $base == "archived" then "archived"
      elif $base == "completed" then "completed"
      elif ($issue_statuses | index("failed")) then "failed"
      elif ($issue_statuses | index("blocked")) then "blocked"
      elif ($issue_statuses | index("paused")) then "paused"
      elif $base == "stale" then "stale"
      elif ($issue_statuses | index("running")) then "running"
      elif ($issue_statuses | index("queued")) and (["available","queued"] | index($base)) then "queued"
      else $base end;
    def title_with_id($name; $id):
      if (($id // "") != "" and ($id // "") != ($name // "")) then "\($name) [\($id)]" else $name end;
    . as $root
    | [
      (.chains // [])[]
      | . as $chain
      | ($chain.name // $chain.chain_run_id // "unknown-chain" | tostring) as $chain_name
      | ($chain.chain_run_id // $chain.chain_id // $chain.id // $chain.name // "unknown-chain" | tostring) as $chain_id
      | "chain:\($source_kind | clean):\($source_id | clean):\($chain_id | clean)" as $chain_key
      | "chain:\($chain_name | clean)" as $logical_key
      | [($chain.issues // [])[]? | .number? // .issue? // empty | tonumber?] as $issue_numbers
      | [($chain.issues // [])[]? | select((.status // "") == "completed" or (.integrated // false) == true)] as $completed_issues
      | (($chain.status // "unknown") | tostring) as $raw_status
      | effective($raw_status; ($chain.updated_at // $root.updated_at // null); ($chain.completed_at // null)) as $base_status
      | [($chain.issues // [])[]? | effective((.status // "unknown"); (.updated_at // $root.updated_at // null); (.completed_at // null))] as $issue_statuses
      | rollup_status($base_status; $issue_statuses) as $status
      | {
          claim_kind:"chain",
          logical_key:$logical_key,
          row_key:$chain_key,
          source:{kind:$source_kind,id:$source_id,precedence:$precedence},
          chain_name:$chain_name,
          issue_numbers:$issue_numbers,
          snapshot:{
            schema_version:1,
            row_key:$chain_key,
            row_type:"chain",
            source:{kind:$source_kind,id:$source_id,precedence:$precedence},
            fields:{
              title:title_with_id($chain_name; $chain_id),
              status:$status,
              manifest:(($root.manifest // "") | tostring | split("/") | last),
              summary:($chain.summary // ""),
              progress:"\(($completed_issues | length))/\(($chain.issues // []) | length) completed",
              blocker:($chain.failure_reason // ([($chain.issues // [])[]? | select((.status // "") == "failed" or (.status // "") == "blocked") | "#\(.number): \(.failure_reason // .status)"] | join("; ")))
            }
          }
        },
        (($chain.issues // [])[]?
          | . as $task
          | (($task.number // $task.issue // empty) | tostring) as $issue
          | select($issue != "")
          | "task:\($chain_key):issue:\($issue | clean)" as $row_key
          | {
              claim_kind:"task",
              parent_logical_key:$logical_key,
              parent_row_key:$chain_key,
              row_key:$row_key,
              source:{kind:$source_kind,id:$source_id,precedence:$precedence},
              snapshot:{
                schema_version:1,
                row_key:$row_key,
                row_type:"task",
                parent_row_key:$chain_key,
                source:{kind:$source_kind,id:$source_id,precedence:$precedence},
                fields:{
                  title:($task.title // "Issue #\($issue)"),
                  status:(effective(($task.status // "unknown"); ($task.updated_at // $root.updated_at // null); ($task.completed_at // null))),
                  manifest:(($root.manifest // "") | tostring | split("/") | last),
                  summary:($task.summary // ""),
                  progress:"",
                  blocker:($task.failure_reason // $task.blocker // "")
                }
              }
            })
    ] | flatten
    ' "$projection_json_path"
  jq_rc=$?
  rm -f "$projection_json_path"
  return "$jq_rc"
}

chain_monitor_claims_from_legacy_slack_json() {
  local source_id="${1:?usage: chain_monitor_claims_from_legacy_slack_json <source-id> <rows-json>}"
  local rows_json_path="${2:?usage: chain_monitor_claims_from_legacy_slack_json <source-id> <rows-json>}"
  local precedence
  precedence=$(chain_monitor_source_precedence_rank slack-legacy)
  jq -c \
    --arg source_kind "slack-legacy" \
    --arg source_id "$source_id" \
    --argjson precedence "$precedence" \
    '
    def clean: tostring | gsub("[:\n\r\t]"; "_");
    [
      (.rows // [])[]
      | . as $row
      | ($row.fields.title // $row.title // (($row.row_key // "") | split(":") | last) // "unknown-chain" | tostring) as $chain_name
      | ($row.row_key // "chain:\($source_kind | clean):\($source_id | clean):\($chain_name | clean)") as $row_key
      | {
          claim_kind:"chain",
          logical_key:"chain:\($chain_name | clean)",
          row_key:$row_key,
          source:{kind:$source_kind,id:$source_id,precedence:$precedence},
          chain_name:$chain_name,
          issue_numbers:[],
          legacy_row_id:($row.row_id // null),
          snapshot:{
            schema_version:1,
            row_key:$row_key,
            row_type:"chain",
            source:{kind:$source_kind,id:$source_id,precedence:$precedence},
            fields:{
              title:$chain_name,
              status:($row.fields.status // "unknown"),
              manifest:($row.fields.manifest // ""),
              summary:($row.fields.summary // ""),
              progress:($row.fields.progress // ""),
              blocker:($row.fields.blocker // "")
            }
          }
        }
    ]
    ' "$rows_json_path"
}

chain_monitor_reconcile_claims_json() {
  local claims_path="${1:?usage: chain_monitor_reconcile_claims_json <claims-json-array>}"
  jq -n --slurpfile claims "$claims_path" '
    def claim_summary: {source:.source,row_key:.row_key,issue_numbers:(.issue_numbers // [])};
    def status_rank:
      ((.fields.status // "unknown") | tostring) as $status
      | if $status == "running" then 0
        elif $status == "blocked" then 1
        elif $status == "failed" then 2
        elif $status == "paused" then 3
        elif $status == "queued" then 4
        elif $status == "available" then 5
        elif $status == "stale" then 6
        elif $status == "unknown" then 7
        elif $status == "completed" then 8
        elif $status == "archived" then 9
        else 10 end;
    ($claims[0] // []) as $claims
    | reduce ([ $claims[] | select(.claim_kind == "chain") | .logical_key ] | unique[]) as $logical_key
        ({schema_version:1, rows:[], collisions:[], recoveries:[]};
          ($claims | map(select(.claim_kind == "chain" and .logical_key == $logical_key))) as $group
          | ($group | sort_by(.source.precedence)[0]) as $selected
          | ($group | map(select(.source.kind != "slack-legacy" and ((.issue_numbers // []) | length) > 0))) as $issue_claims
          | ($issue_claims | map(.issue_numbers) | unique) as $issue_lists
          | .collisions += (
              if ($issue_lists | length) > 1 then
                [{
                  kind:"incompatible_issue_lists",
                  logical_key:$logical_key,
                  selected_source:$selected.source,
                  selected_row_key:$selected.row_key,
                  claims:($issue_claims | map(claim_summary))
                }]
              else [] end
            )
          | .recoveries += (
              $group
              | map(select(.source.kind == "slack-legacy"))
              | map({
                  purpose:(if $selected.source.kind == "slack-legacy" then "legacy-migration" else "row-id-recovery" end),
                  logical_key:$logical_key,
                  selected_row_key:(if $selected.source.kind == "slack-legacy" then null else $selected.row_key end),
                  legacy_row_key:.row_key,
                  legacy_row_id:(.legacy_row_id // null)
                })
            )
          | if $selected.source.kind == "slack-legacy" then .
            else
              .rows += [$selected.snapshot]
              | .rows += ($claims | map(select(.claim_kind == "task" and .parent_row_key == $selected.row_key) | .snapshot))
            end
        )
    | .rows |= sort_by(if .row_type == "chain" then status_rank else 100 end, if .row_type == "chain" then 0 else 1 end, (.parent_row_key // .row_key), .row_key)
    | .collisions |= sort_by(.logical_key, .kind)
    | .recoveries |= sort_by(.legacy_row_key)
  '
}

chain_monitor_build_rows_json() {
  local now_epoch=0 stale_threshold_s="$CHAIN_MONITOR_STALE_THRESHOLD_S" completed_retention_s="$CHAIN_MONITOR_COMPLETED_RETENTION_S"
  local claims_tmp source_id
  claims_tmp=$(mktemp -t chain-monitor-claims.XXXXXX)
  printf '[]\n' > "$claims_tmp"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now-epoch) now_epoch="${2:?--now-epoch requires a value}"; shift 2 ;;
      --stale-threshold-s) stale_threshold_s="${2:?--stale-threshold-s requires a value}"; shift 2 ;;
      --completed-retention-s) completed_retention_s="${2:?--completed-retention-s requires a value}"; shift 2 ;;
      --persisted-run)
        source_id=$(jq -r '.run_id // "persisted-run"' "$2")
        chain_monitor_claims_from_persisted_run_json "$source_id" "$2" "$now_epoch" "$stale_threshold_s" "$completed_retention_s" \
          | jq -s 'add' > "$claims_tmp.next"
        jq -s '.[0] + .[1]' "$claims_tmp" "$claims_tmp.next" > "$claims_tmp.merge"
        mv "$claims_tmp.merge" "$claims_tmp"
        rm -f "$claims_tmp.next"
        shift 2
        ;;
      --runtime-manifest)
        source_id=$(chain_monitor_source_id_from_path "$2")
        chain_monitor_claims_from_manifest_json runtime-manifest "$source_id" "$2" "$now_epoch" "$stale_threshold_s" "$completed_retention_s" \
          | jq -s 'add' > "$claims_tmp.next"
        jq -s '.[0] + .[1]' "$claims_tmp" "$claims_tmp.next" > "$claims_tmp.merge"
        mv "$claims_tmp.merge" "$claims_tmp"
        rm -f "$claims_tmp.next"
        shift 2
        ;;
      --repo-manifest)
        source_id=$(chain_monitor_source_id_from_path "$2")
        chain_monitor_claims_from_manifest_json repo-manifest "$source_id" "$2" "$now_epoch" "$stale_threshold_s" "$completed_retention_s" \
          | jq -s 'add' > "$claims_tmp.next"
        jq -s '.[0] + .[1]' "$claims_tmp" "$claims_tmp.next" > "$claims_tmp.merge"
        mv "$claims_tmp.merge" "$claims_tmp"
        rm -f "$claims_tmp.next"
        shift 2
        ;;
      --legacy-slack)
        source_id=$(chain_monitor_source_id_from_path "$2")
        chain_monitor_claims_from_legacy_slack_json "$source_id" "$2" \
          | jq -s 'add' > "$claims_tmp.next"
        jq -s '.[0] + .[1]' "$claims_tmp" "$claims_tmp.next" > "$claims_tmp.merge"
        mv "$claims_tmp.merge" "$claims_tmp"
        rm -f "$claims_tmp.next"
        shift 2
        ;;
      *)
        printf 'chain-monitor: unknown build flag: %s\n' "$1" >&2
        rm -f "$claims_tmp"
        return 2
        ;;
    esac
  done
  chain_monitor_reconcile_claims_json "$claims_tmp"
  rm -f "$claims_tmp"
}
