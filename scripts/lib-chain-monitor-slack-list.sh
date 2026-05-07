#!/usr/bin/env bash
# Row-level Slack List reconciliation for chain monitor row snapshots.

# No `set -e` here. This file is sourced by scripts and fixture harnesses.

CHAIN_MONITOR_SLACK_LIST_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-chain-monitor-model.sh disable=SC1091
. "$CHAIN_MONITOR_SLACK_LIST_LIB_DIR/lib-chain-monitor-model.sh"

CHAIN_MONITOR_SLACK_LIST_STATE_SCHEMA_VERSION=1
CHAIN_MONITOR_SLACK_LIST_API_BASE="${STUDIO_CHAIN_MONITOR_SLACK_LIST_API_BASE:-https://slack.com/api}"
CHAIN_MONITOR_SLACK_LIST_RECREATE_ERRORS="row_not_found invalid_row_id uneditable_column update_requires_recreate recreate_required invalid_row_id"

chain_monitor_slack_list_bool_active() {
  case "${1:-0}" in 1|true|TRUE|yes|YES) return 0 ;; esac
  return 1
}

chain_monitor_slack_list_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    printf 'chain-monitor: shasum or sha256sum required\n' >&2
    return 2
  fi
}

chain_monitor_slack_list_closed_field_keys_json() {
  jq -cn --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" '$fields | split(" ")'
}

chain_monitor_slack_list_columns_json() {
  local field_columns="${STUDIO_CHAIN_MONITOR_SLACK_FIELD_COLUMNS_JSON:-{}}"
  jq -cn --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" --argjson columns "$field_columns" '
    reduce ($fields | split(" "))[] as $key ({}; .[$key] = ($columns[$key] // $key))
  '
}

chain_monitor_slack_list_normalize_desired_rows() {
  local input_path="${1:?usage: chain_monitor_slack_list_normalize_desired_rows <input-json> <output-json>}"
  local output_path="${2:?usage: chain_monitor_slack_list_normalize_desired_rows <input-json> <output-json>}"
  jq --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" '
    def closed_fields($row):
      reduce ($fields | split(" "))[] as $key
        ({}; .[$key] = (($row.fields[$key] // "") | tostring));
    [
      (if type == "array" then .[] else (.rows // [])[] end)
      | select((.row_key // "") != "")
      | {
          schema_version: 1,
          row_key: .row_key,
          row_type: (.row_type // (if (.parent_row_key // "") != "" then "task" else "chain" end)),
          parent_row_key: (.parent_row_key // null),
          source: (.source // {}),
          fields: closed_fields(.)
        }
      | if .parent_row_key == null then del(.parent_row_key) else . end
    ]
    | sort_by(if .row_type == "chain" then 0 else 1 end, .row_key)
  ' "$input_path" > "$output_path"
}

chain_monitor_slack_list_row_hash_file() {
  local row_path="${1:?usage: chain_monitor_slack_list_row_hash_file <row-json>}"
  jq -S -c '{
    schema_version: 1,
    row_key,
    row_type,
    parent_row_key: (.parent_row_key // null),
    source: (.source // {}),
    fields: (.fields // {})
  }' "$row_path" | chain_monitor_slack_list_sha256
}

chain_monitor_slack_list_cells_json() {
  local row_path="${1:?usage: chain_monitor_slack_list_cells_json <row-json> [row-id]}"
  local row_id="${2:-}"
  local columns
  columns=$(chain_monitor_slack_list_columns_json) || return 1
  jq -c \
    --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" \
    --arg row_id "$row_id" \
    --argjson columns "$columns" \
    '
    def rich_text($text):
      [{
        type: "rich_text",
        elements: [{
          type: "rich_text_section",
          elements: [{type: "text", text: (($text // "") | tostring)}]
        }]
      }];
    [
      ($fields | split(" "))[] as $key
      | {
          column_id: ($columns[$key] // $key),
          rich_text: rich_text(.fields[$key] // "")
        }
        + (if $row_id == "" then {} else {row_id: $row_id} end)
    ]
    ' "$row_path"
}

chain_monitor_slack_list_empty_state_json() {
  local list_id="${1:?usage: chain_monitor_slack_list_empty_state_json <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local owner_home="${2:?usage: chain_monitor_slack_list_empty_state_json <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local owner_project="${3:?usage: chain_monitor_slack_list_empty_state_json <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local source_fingerprint="${4:-}"
  jq -n \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$owner_project" \
    --arg source_fingerprint "$source_fingerprint" \
    --argjson schema_version "$CHAIN_MONITOR_SLACK_LIST_STATE_SCHEMA_VERSION" \
    '{
      schema_version: $schema_version,
      list_id: $list_id,
      owner_home: $owner_home,
      owner_project: $owner_project,
      source_fingerprint: $source_fingerprint,
      rows: []
    }'
}

chain_monitor_slack_list_state_needs_live_bootstrap() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_needs_live_bootstrap <state-path> <list-id> <owner-home> <owner-project>}"
  local list_id="${2:?usage: chain_monitor_slack_list_state_needs_live_bootstrap <state-path> <list-id> <owner-home> <owner-project>}"
  local owner_home="${3:?usage: chain_monitor_slack_list_state_needs_live_bootstrap <state-path> <list-id> <owner-home> <owner-project>}"
  local owner_project="${4:?usage: chain_monitor_slack_list_state_needs_live_bootstrap <state-path> <list-id> <owner-home> <owner-project>}"
  [ -s "$state_path" ] || return 0
  jq -e \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$owner_project" \
    '
      .schema_version == 1
      and .list_id == $list_id
      and .owner_home == $owner_home
      and .owner_project == $owner_project
      and ((.rows // null) | type == "array")
      and ((.rows // []) | length > 0)
    ' "$state_path" >/dev/null 2>&1
  case "$?" in
    0) return 1 ;;
    *) return 0 ;;
  esac
}

chain_monitor_slack_list_api_call() {
  local method="${1:?usage: chain_monitor_slack_list_api_call <method> <payload-json-file>}"
  local payload_path="${2:?usage: chain_monitor_slack_list_api_call <method> <payload-json-file>}"
  local handler token token_file

  if [ -n "${STUDIO_CHAIN_MONITOR_SLACK_LIST_API_FUNCTION:-}" ] \
    && declare -F "$STUDIO_CHAIN_MONITOR_SLACK_LIST_API_FUNCTION" >/dev/null 2>&1; then
    "$STUDIO_CHAIN_MONITOR_SLACK_LIST_API_FUNCTION" "$method" "$payload_path"
    return $?
  fi

  if [ -n "${STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND:-}" ]; then
    "$STUDIO_CHAIN_MONITOR_SLACK_LIST_API_COMMAND" "$method" "$payload_path"
    return $?
  fi

  command -v curl >/dev/null 2>&1 || {
    jq -cn --arg error "curl_missing" '{ok:false,error:$error}'
    return 1
  }

  token="${STUDIO_SLACK_TOKEN:-${SLACK_TOKEN:-}}"
  token_file="${STUDIO_SLACK_TOKEN_FILE:-${SLACK_TOKEN_FILE:-}}"
  if [ -z "$token" ] && [ -n "$token_file" ] && [ -r "$token_file" ]; then
    token=$(tr -d '\r\n' < "$token_file")
  fi
  if [ -z "$token" ]; then
    jq -cn --arg error "slack_token_missing" '{ok:false,error:$error}'
    return 1
  fi

  handler="$CHAIN_MONITOR_SLACK_LIST_API_BASE/$method"
  curl -fsS \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary @"$payload_path" \
    "$handler"
}

chain_monitor_slack_list_summary_init() {
  local summary_path="${1:?usage: chain_monitor_slack_list_summary_init <summary-path> <list-id> <dry-run> <full-rewrite>}"
  local list_id="${2:?usage: chain_monitor_slack_list_summary_init <summary-path> <list-id> <dry-run> <full-rewrite>}"
  local dry_run="${3:-false}" full_rewrite="${4:-false}"
  jq -n \
    --arg list_id "$list_id" \
    --argjson dry_run "$dry_run" \
    --argjson full_rewrite "$full_rewrite" \
    '{
      schema_version: 1,
      kind: "chain_monitor_slack_list_reconcile",
      list_id: $list_id,
      dry_run: $dry_run,
      full_rewrite_requested: $full_rewrite,
      bootstrapped_from_live: false,
      would_fetch_live: false,
      writes: {create: 0, update: 0, archive: 0},
      noops: 0,
      skipped: 0,
      failed: [],
      operations: []
    }' > "$summary_path"
}

chain_monitor_slack_list_summary_patch() {
  local summary_path="${1:?usage: chain_monitor_slack_list_summary_patch <summary-path> <jq-filter>}"
  local filter="${2:?usage: chain_monitor_slack_list_summary_patch <summary-path> <jq-filter>}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-summary.XXXXXX) || return 1
  jq "$filter" "$summary_path" > "$tmp_path" && mv "$tmp_path" "$summary_path"
}

chain_monitor_slack_list_summary_add_operation() {
  local summary_path="${1:?usage: chain_monitor_slack_list_summary_add_operation <summary-path> <action> <row-key> <row-id> <outcome> [detail]}"
  local action="${2:?usage: chain_monitor_slack_list_summary_add_operation <summary-path> <action> <row-key> <row-id> <outcome> [detail]}"
  local row_key="${3:-}" row_id="${4:-}" outcome="${5:-ok}" detail="${6:-}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-summary.XXXXXX) || return 1
  jq \
    --arg action "$action" \
    --arg row_key "$row_key" \
    --arg row_id "$row_id" \
    --arg outcome "$outcome" \
    --arg detail "$detail" \
    '
      .operations += [{
        action: $action,
        row_key: $row_key,
        row_id: $row_id,
        outcome: $outcome,
        detail: $detail
      }]
      | if $action == "create" and $outcome == "ok" then .writes.create += 1 else . end
      | if $action == "update" and $outcome == "ok" then .writes.update += 1 else . end
      | if $action == "archive" and $outcome == "ok" then .writes.archive += 1 else . end
      | if $action == "noop" then .noops += 1 else . end
      | if ($action | startswith("skip")) then .skipped += 1 else . end
      | if $outcome == "failed" then .failed += [{action:$action,row_key:$row_key,row_id:$row_id,error:$detail}] else . end
    ' "$summary_path" > "$tmp_path" && mv "$tmp_path" "$summary_path"
}

chain_monitor_slack_list_api_request() {
  local method="${1:?usage: chain_monitor_slack_list_api_request <method> <payload-file> <response-file>}"
  local payload_path="${2:?usage: chain_monitor_slack_list_api_request <method> <payload-file> <response-file>}"
  local response_path="${3:?usage: chain_monitor_slack_list_api_request <method> <payload-file> <response-file>}"
  if ! chain_monitor_slack_list_api_call "$method" "$payload_path" > "$response_path"; then
    if ! jq -e . "$response_path" >/dev/null 2>&1; then
      jq -cn --arg error "adapter_failed" '{ok:false,error:$error}' > "$response_path"
    fi
    return 1
  fi
  jq -e . "$response_path" >/dev/null 2>&1 || {
    jq -cn --arg error "adapter_invalid_json" '{ok:false,error:$error}' > "$response_path"
    return 1
  }
}

chain_monitor_slack_list_fetch_live_rows() {
  local list_id="${1:?usage: chain_monitor_slack_list_fetch_live_rows <list-id> <output-json>}"
  local output_path="${2:?usage: chain_monitor_slack_list_fetch_live_rows <list-id> <output-json>}"
  local payload_path
  payload_path=$(mktemp -t chain-monitor-list-payload.XXXXXX) || return 1
  jq -n --arg list_id "$list_id" '{list_id:$list_id, archived:false}' > "$payload_path"
  chain_monitor_slack_list_api_request "slackLists.items.list" "$payload_path" "$output_path"
  rm -f "$payload_path"
  jq -e '.ok == true' "$output_path" >/dev/null 2>&1
}

chain_monitor_slack_list_state_from_live() {
  local live_path="${1:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  local desired_path="${2:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  local list_id="${3:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  local owner_home="${4:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  local owner_project="${5:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  local source_fingerprint="${6:-}"
  local now_epoch="${7:-0}"
  local output_path="${8:?usage: chain_monitor_slack_list_state_from_live <live-json> <desired-json> <list-id> <owner-home> <owner-project> <source-fingerprint> <now-epoch> <output-json>}"
  jq -n \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$owner_project" \
    --arg source_fingerprint "$source_fingerprint" \
    --arg fields "$CHAIN_MONITOR_SLACK_FIELDS" \
    --argjson schema_version "$CHAIN_MONITOR_SLACK_LIST_STATE_SCHEMA_VERSION" \
    --argjson now_epoch "$now_epoch" \
    --slurpfile live "$live_path" \
    --slurpfile desired "$desired_path" \
    '
    def key_list: $fields | split(" ");
    def field_value($field):
      if ($field.text // null) != null then ($field.text | tostring)
      elif (($field.select // null) | type) == "array" then (($field.select[0] // "") | tostring)
      elif (($field.date // null) | type) == "array" then (($field.date[0] // "") | tostring)
      elif (($field.user // null) | type) == "array" then (($field.user | join(",")) | tostring)
      elif ($field.value // null) != null then ($field.value | tostring)
      else "" end;
    def live_fields($item):
      if (($item.fields // null) | type) == "object" then
        reduce key_list[] as $key ({}; .[$key] = (($item.fields[$key] // "") | tostring))
      elif (($item.fields // null) | type) == "array" then
        (reduce ($item.fields[]? | select((.key // "") != "")) as $field
          ({}; .[$field.key] = field_value($field))) as $raw
        | reduce key_list[] as $key ({}; .[$key] = (($raw[$key] // "") | tostring))
      else
        reduce key_list[] as $key ({}; .[$key] = "")
      end;
    def row_id_for($item; $idx): (($item.id // $item.row_id // "live-\($idx)") | tostring);
    ($desired[0] // []) as $desired_rows
      | {
        schema_version: $schema_version,
        list_id: $list_id,
        owner_home: $owner_home,
        owner_project: $owner_project,
        source_fingerprint: $source_fingerprint,
        rows: [
          (($live[0].items // $live[0].rows // []) | to_entries[]) as $entry
          | ($entry.value) as $item
          | live_fields($item) as $display
          | (($item.row_key // $item.metadata.row_key // "") | tostring) as $live_key
          | (
              if $live_key != "" then
                ($desired_rows | map(select(.row_key == $live_key))[0] // null)
              else
                ($desired_rows | map(select(.fields.title == ($display.title // "")))) as $title_matches
                | if ($title_matches | length) == 1 then $title_matches[0] else null end
              end
            ) as $match
          | if $match == null then
              {
                row_id: row_id_for($item; $entry.key),
                row_key: ("orphan:" + row_id_for($item; $entry.key)),
                parent_row_key: null,
                source_fields: {kind:"slack-live", id:$list_id, precedence:99},
                display_fields: $display,
                status: "stale",
                activity_timestamp: $now_epoch,
                last_synced_hash: null,
                row_id_history: [],
                orphan: true,
                orphaned_at: $now_epoch,
                stale_since: $now_epoch
              }
            else
              {
                row_id: row_id_for($item; $entry.key),
                row_key: $match.row_key,
                parent_row_key: ($match.parent_row_key // null),
                source_fields: ($match.source // {}),
                display_fields: $display,
                status: (($display.status // "") as $s | if $s == "" then $match.fields.status else $s end),
                activity_timestamp: (($item.updated_timestamp // $now_epoch) | tonumber? // $now_epoch),
                last_synced_hash: null,
                row_id_history: []
              }
            end
        ]
      }
      | .rows |= sort_by(.row_key)
    ' > "$output_path"
}

chain_monitor_slack_list_state_refresh_owner() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_refresh_owner <state-json> <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local list_id="${2:?usage: chain_monitor_slack_list_state_refresh_owner <state-json> <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local owner_home="${3:?usage: chain_monitor_slack_list_state_refresh_owner <state-json> <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local owner_project="${4:?usage: chain_monitor_slack_list_state_refresh_owner <state-json> <list-id> <owner-home> <owner-project> <source-fingerprint>}"
  local source_fingerprint="${5:-}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-state.XXXXXX) || return 1
  jq \
    --arg list_id "$list_id" \
    --arg owner_home "$owner_home" \
    --arg owner_project "$owner_project" \
    --arg source_fingerprint "$source_fingerprint" \
    '
      .schema_version = 1
      | .list_id = $list_id
      | .owner_home = $owner_home
      | .owner_project = $owner_project
      | .source_fingerprint = $source_fingerprint
      | .rows = (.rows // [])
    ' "$state_path" > "$tmp_path" && mv "$tmp_path" "$state_path"
}

chain_monitor_slack_list_state_get_row() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_get_row <state-json> <row-key>}"
  local row_key="${2:?usage: chain_monitor_slack_list_state_get_row <state-json> <row-key>}"
  jq -c --arg row_key "$row_key" '.rows[]? | select(.row_key == $row_key)' "$state_path" | head -n 1
}

chain_monitor_slack_list_state_parent_row_id() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_parent_row_id <state-json> <parent-row-key>}"
  local parent_row_key="${2:?usage: chain_monitor_slack_list_state_parent_row_id <state-json> <parent-row-key>}"
  jq -r --arg row_key "$parent_row_key" '
    .rows[]?
    | select(.row_key == $row_key and ((.archived_at // null) == null) and (.status != "archived"))
    | .row_id // ""
  ' "$state_path" | head -n 1
}

chain_monitor_slack_list_row_history_with_current() {
  local existing_row_json="${1:-}"
  if [ -z "$existing_row_json" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$existing_row_json" | jq -c '
    ((.row_id_history // []) + (if (.row_id // "") == "" then [] else [.row_id] end)) | unique
  '
}

chain_monitor_slack_list_existing_history() {
  local existing_row_json="${1:-}"
  if [ -z "$existing_row_json" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$existing_row_json" | jq -c '(.row_id_history // [])'
}

chain_monitor_slack_list_state_upsert_desired_row() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_upsert_desired_row <state-json> <row-json> <row-id> <hash> <now-epoch> <history-json> [archived-at]}"
  local row_path="${2:?usage: chain_monitor_slack_list_state_upsert_desired_row <state-json> <row-json> <row-id> <hash> <now-epoch> <history-json> [archived-at]}"
  local row_id="${3:-}" row_hash="${4:-}" now_epoch="${5:-0}" history_json="${6:-[]}" archived_at="${7:-null}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-state.XXXXXX) || return 1
  jq \
    --slurpfile row "$row_path" \
    --arg row_id "$row_id" \
    --arg row_hash "$row_hash" \
    --argjson now_epoch "$now_epoch" \
    --argjson history "$history_json" \
    --argjson archived_at "$archived_at" \
    '
      ($row[0]) as $desired
      | .rows = (
          ((.rows // []) | map(select(.row_key != $desired.row_key)))
          + [{
              row_id: $row_id,
              row_key: $desired.row_key,
              parent_row_key: ($desired.parent_row_key // null),
              source_fields: ($desired.source // {}),
              display_fields: ($desired.fields // {}),
              status: ($desired.fields.status // "unknown"),
              activity_timestamp: $now_epoch,
              last_synced_hash: $row_hash,
              row_id_history: $history
            }
            + (if $archived_at == null then {} else {archived_at:$archived_at} end)]
        )
      | .rows |= sort_by(.row_key)
    ' "$state_path" > "$tmp_path" && mv "$tmp_path" "$state_path"
}

chain_monitor_slack_list_state_mark_stale() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_mark_stale <state-json> <row-key> <now-epoch>}"
  local row_key="${2:?usage: chain_monitor_slack_list_state_mark_stale <state-json> <row-key> <now-epoch>}"
  local now_epoch="${3:-0}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-state.XXXXXX) || return 1
  jq --arg row_key "$row_key" --argjson now_epoch "$now_epoch" '
    .rows |= map(
      if .row_key == $row_key then
        . + {
          status: "stale",
          orphan: true,
          orphaned_at: (.orphaned_at // $now_epoch),
          stale_since: (.stale_since // $now_epoch),
          activity_timestamp: $now_epoch
        }
      else . end
    )
  ' "$state_path" > "$tmp_path" && mv "$tmp_path" "$state_path"
}

chain_monitor_slack_list_state_mark_archived() {
  local state_path="${1:?usage: chain_monitor_slack_list_state_mark_archived <state-json> <row-key> <now-epoch>}"
  local row_key="${2:?usage: chain_monitor_slack_list_state_mark_archived <state-json> <row-key> <now-epoch>}"
  local now_epoch="${3:-0}"
  local tmp_path
  tmp_path=$(mktemp -t chain-monitor-state.XXXXXX) || return 1
  jq --arg row_key "$row_key" --argjson now_epoch "$now_epoch" '
    .rows |= map(
      if .row_key == $row_key then
        . + {
          status: "archived",
          archived_at: (.archived_at // $now_epoch),
          activity_timestamp: $now_epoch
        }
      else . end
    )
  ' "$state_path" > "$tmp_path" && mv "$tmp_path" "$state_path"
}

chain_monitor_slack_list_create_row() {
  local list_id="${1:?usage: chain_monitor_slack_list_create_row <list-id> <row-json> <parent-row-id> <response-json>}"
  local row_path="${2:?usage: chain_monitor_slack_list_create_row <list-id> <row-json> <parent-row-id> <response-json>}"
  local parent_row_id="${3:-}"
  local response_path="${4:?usage: chain_monitor_slack_list_create_row <list-id> <row-json> <parent-row-id> <response-json>}"
  local initial_fields payload_path
  initial_fields=$(chain_monitor_slack_list_cells_json "$row_path") || return 1
  payload_path=$(mktemp -t chain-monitor-create.XXXXXX) || return 1
  jq -n \
    --arg list_id "$list_id" \
    --arg parent_row_id "$parent_row_id" \
    --argjson initial_fields "$initial_fields" \
    --slurpfile row "$row_path" \
    '
      {
        list_id: $list_id,
        row_key: $row[0].row_key,
        row: $row[0],
        initial_fields: $initial_fields
      }
      + (if $parent_row_id == "" then {} else {parent_item_id:$parent_row_id} end)
    ' > "$payload_path"
  chain_monitor_slack_list_api_request "slackLists.items.create" "$payload_path" "$response_path"
  rm -f "$payload_path"
  jq -e '.ok == true' "$response_path" >/dev/null 2>&1
}

chain_monitor_slack_list_update_row() {
  local list_id="${1:?usage: chain_monitor_slack_list_update_row <list-id> <row-id> <row-json> <response-json>}"
  local row_id="${2:?usage: chain_monitor_slack_list_update_row <list-id> <row-id> <row-json> <response-json>}"
  local row_path="${3:?usage: chain_monitor_slack_list_update_row <list-id> <row-id> <row-json> <response-json>}"
  local response_path="${4:?usage: chain_monitor_slack_list_update_row <list-id> <row-id> <row-json> <response-json>}"
  local cells payload_path
  cells=$(chain_monitor_slack_list_cells_json "$row_path" "$row_id") || return 1
  payload_path=$(mktemp -t chain-monitor-update.XXXXXX) || return 1
  jq -n \
    --arg list_id "$list_id" \
    --arg row_id "$row_id" \
    --argjson cells "$cells" \
    --slurpfile row "$row_path" \
    '{
      list_id: $list_id,
      row_id: $row_id,
      row_key: $row[0].row_key,
      row: $row[0],
      cells: $cells
    }' > "$payload_path"
  chain_monitor_slack_list_api_request "slackLists.items.update" "$payload_path" "$response_path"
  rm -f "$payload_path"
  jq -e '.ok == true' "$response_path" >/dev/null 2>&1
}

chain_monitor_slack_list_archive_row() {
  local list_id="${1:?usage: chain_monitor_slack_list_archive_row <list-id> <row-id> <row-key> <response-json>}"
  local row_id="${2:?usage: chain_monitor_slack_list_archive_row <list-id> <row-id> <row-key> <response-json>}"
  local row_key="${3:-}"
  local response_path="${4:?usage: chain_monitor_slack_list_archive_row <list-id> <row-id> <row-key> <response-json>}"
  local payload_path
  payload_path=$(mktemp -t chain-monitor-archive.XXXXXX) || return 1
  jq -n \
    --arg list_id "$list_id" \
    --arg row_id "$row_id" \
    --arg row_key "$row_key" \
    '{list_id:$list_id, id:$row_id, row_id:$row_id, row_key:$row_key, archive:true}' > "$payload_path"
  chain_monitor_slack_list_api_request "slackLists.items.delete" "$payload_path" "$response_path"
  rm -f "$payload_path"
  jq -e '.ok == true' "$response_path" >/dev/null 2>&1
}

chain_monitor_slack_list_error_requires_recreate() {
  local response_path="${1:?usage: chain_monitor_slack_list_error_requires_recreate <response-json>}"
  local error
  error=$(jq -r '.error // ""' "$response_path")
  case " $CHAIN_MONITOR_SLACK_LIST_RECREATE_ERRORS " in
    *" $error "*) return 0 ;;
    *) return 1 ;;
  esac
}

chain_monitor_slack_list_extract_created_row_id() {
  local response_path="${1:?usage: chain_monitor_slack_list_extract_created_row_id <response-json>}"
  jq -r '.item.id // .row_id // .id // empty' "$response_path"
}

chain_monitor_slack_list_reconcile_json() {
  local desired_path="" state_path="" list_id="" owner_home="" owner_project="" source_fingerprint=""
  local now_epoch=0 archive_retention_s="$CHAIN_MONITOR_ARCHIVE_RETENTION_S"
  local dry_run=false full_rewrite=false repair_orphans=false
  local tmpdir desired_rows state_work summary live_response rc failed_count would_fetch=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --desired) desired_path="${2:?--desired requires a path}"; shift 2 ;;
      --state) state_path="${2:?--state requires a path}"; shift 2 ;;
      --list-id) list_id="${2:?--list-id requires a value}"; shift 2 ;;
      --owner-home) owner_home="${2:?--owner-home requires a value}"; shift 2 ;;
      --owner-project) owner_project="${2:?--owner-project requires a value}"; shift 2 ;;
      --source-fingerprint) source_fingerprint="${2:-}"; shift 2 ;;
      --now-epoch) now_epoch="${2:?--now-epoch requires a value}"; shift 2 ;;
      --archive-retention-s) archive_retention_s="${2:?--archive-retention-s requires a value}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --full-rewrite) full_rewrite=true; shift ;;
      --repair-orphans) repair_orphans=true; shift ;;
      *)
        printf 'chain-monitor: unknown Slack List reconcile flag: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  [ -n "$desired_path" ] || { printf 'chain-monitor: --desired required\n' >&2; return 2; }
  [ -n "$state_path" ] || { printf 'chain-monitor: --state required\n' >&2; return 2; }
  [ -n "$list_id" ] || { printf 'chain-monitor: --list-id required\n' >&2; return 2; }
  [ -n "$owner_home" ] || { printf 'chain-monitor: --owner-home required\n' >&2; return 2; }
  [ -n "$owner_project" ] || { printf 'chain-monitor: --owner-project required\n' >&2; return 2; }

  tmpdir=$(mktemp -d -t chain-monitor-slack-list.XXXXXX) || return 1
  desired_rows="$tmpdir/desired-rows.json"
  state_work="$tmpdir/state.json"
  summary="$tmpdir/summary.json"
  live_response="$tmpdir/live-response.json"
  rc=0

  chain_monitor_slack_list_normalize_desired_rows "$desired_path" "$desired_rows" || {
    rm -rf "$tmpdir"
    return 1
  }
  chain_monitor_slack_list_summary_init "$summary" "$list_id" "$dry_run" "$full_rewrite" || {
    rm -rf "$tmpdir"
    return 1
  }

  if [ "$full_rewrite" = "true" ]; then
    if ! chain_monitor_recovery_mode_active; then
      jq '. + {error:"full_rewrite_requires_explicit_recovery_flag"}' "$summary"
      rm -rf "$tmpdir"
      return 2
    fi
    if [ "$dry_run" != "true" ]; then
      jq '. + {error:"full_rewrite_is_dry_run_only"}' "$summary"
      rm -rf "$tmpdir"
      return 2
    fi
    jq --slurpfile desired "$desired_rows" '
      . + {
        recovery: {
          full_rewrite: true,
          dry_run_only: true,
          would_create_count: (($desired[0] // []) | length),
          would_archive_active_count: null
        }
      }
    ' "$summary"
    rm -rf "$tmpdir"
    return 0
  fi

  if chain_monitor_slack_list_state_needs_live_bootstrap "$state_path" "$list_id" "$owner_home" "$owner_project"; then
    if [ "$dry_run" = "true" ]; then
      would_fetch=true
      chain_monitor_slack_list_empty_state_json "$list_id" "$owner_home" "$owner_project" "$source_fingerprint" > "$state_work"
    else
      if chain_monitor_slack_list_fetch_live_rows "$list_id" "$live_response"; then
        chain_monitor_slack_list_state_from_live "$live_response" "$desired_rows" "$list_id" "$owner_home" "$owner_project" "$source_fingerprint" "$now_epoch" "$state_work" || {
          rm -rf "$tmpdir"
          return 1
        }
        chain_monitor_slack_list_summary_patch "$summary" '.bootstrapped_from_live = true' || {
          rm -rf "$tmpdir"
          return 1
        }
      else
        cat "$live_response" >&2
        rm -rf "$tmpdir"
        return 1
      fi
    fi
  else
    cp "$state_path" "$state_work"
    chain_monitor_slack_list_state_refresh_owner "$state_work" "$list_id" "$owner_home" "$owner_project" "$source_fingerprint" || {
      rm -rf "$tmpdir"
      return 1
    }
  fi

  if [ "$would_fetch" = "true" ]; then
    chain_monitor_slack_list_summary_patch "$summary" '.would_fetch_live = true' || {
      rm -rf "$tmpdir"
      return 1
    }
  fi

  while IFS= read -r row_json; do
    local row_file row_key row_status parent_row_key existing_json existing_row_id existing_hash existing_archived desired_hash history parent_row_id response error new_row_id old_row_id archive_response
    row_file="$tmpdir/row.json"
    response="$tmpdir/response.json"
    archive_response="$tmpdir/archive-response.json"
    printf '%s\n' "$row_json" > "$row_file"
    row_key=$(jq -r '.row_key' "$row_file")
    row_status=$(jq -r '.fields.status // "unknown"' "$row_file")
    parent_row_key=$(jq -r '.parent_row_key // ""' "$row_file")
    desired_hash=$(chain_monitor_slack_list_row_hash_file "$row_file") || {
      rc=1
      chain_monitor_slack_list_summary_add_operation "$summary" "hash" "$row_key" "" "failed" "hash_failed"
      continue
    }
    existing_json=$(chain_monitor_slack_list_state_get_row "$state_work" "$row_key")
    existing_row_id=""
    existing_hash=""
    existing_archived="false"
    if [ -n "$existing_json" ]; then
      existing_row_id=$(printf '%s\n' "$existing_json" | jq -r '.row_id // ""')
      existing_hash=$(printf '%s\n' "$existing_json" | jq -r '.last_synced_hash // ""')
      existing_archived=$(printf '%s\n' "$existing_json" | jq -r 'if ((.archived_at // null) != null or .status == "archived") then "true" else "false" end')
    fi

    if [ "$row_status" = "archived" ]; then
      if [ -n "$existing_row_id" ] && [ "$existing_archived" != "true" ]; then
        if [ "$dry_run" = "true" ]; then
          chain_monitor_slack_list_summary_add_operation "$summary" "would_archive" "$row_key" "$existing_row_id" "ok" "dry-run"
        elif chain_monitor_slack_list_archive_row "$list_id" "$existing_row_id" "$row_key" "$response"; then
          history=$(chain_monitor_slack_list_existing_history "$existing_json")
          chain_monitor_slack_list_state_upsert_desired_row "$state_work" "$row_file" "$existing_row_id" "$desired_hash" "$now_epoch" "$history" "$now_epoch"
          chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$row_key" "$existing_row_id" "ok" "desired-archived"
        else
          rc=1
          error=$(jq -r '.error // "archive_failed"' "$response")
          chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$row_key" "$existing_row_id" "failed" "$error"
        fi
      else
        chain_monitor_slack_list_summary_add_operation "$summary" "skip_archived" "$row_key" "$existing_row_id" "ok" "already-archived-or-missing"
      fi
      continue
    fi

    if [ -n "$existing_row_id" ] && [ "$existing_archived" != "true" ] && [ "$existing_hash" = "$desired_hash" ]; then
      chain_monitor_slack_list_summary_add_operation "$summary" "noop" "$row_key" "$existing_row_id" "ok" "hash-match"
      continue
    fi

    if [ -n "$parent_row_key" ]; then
      parent_row_id=$(chain_monitor_slack_list_state_parent_row_id "$state_work" "$parent_row_key")
      if [ -z "$parent_row_id" ]; then
        rc=1
        chain_monitor_slack_list_summary_add_operation "$summary" "skip_missing_parent" "$row_key" "" "failed" "$parent_row_key"
        continue
      fi
    else
      parent_row_id=""
    fi

    if [ -z "$existing_row_id" ] || [ "$existing_archived" = "true" ]; then
      history="[]"
      if [ "$existing_archived" = "true" ]; then
        history=$(chain_monitor_slack_list_row_history_with_current "$existing_json")
      fi
      if [ "$dry_run" = "true" ]; then
        chain_monitor_slack_list_summary_add_operation "$summary" "would_create" "$row_key" "" "ok" "dry-run"
      elif chain_monitor_slack_list_create_row "$list_id" "$row_file" "$parent_row_id" "$response"; then
        new_row_id=$(chain_monitor_slack_list_extract_created_row_id "$response")
        chain_monitor_slack_list_state_upsert_desired_row "$state_work" "$row_file" "$new_row_id" "$desired_hash" "$now_epoch" "$history"
        chain_monitor_slack_list_summary_add_operation "$summary" "create" "$row_key" "$new_row_id" "ok" "missing-or-revived"
      else
        rc=1
        error=$(jq -r '.error // "create_failed"' "$response")
        chain_monitor_slack_list_summary_add_operation "$summary" "create" "$row_key" "" "failed" "$error"
      fi
      continue
    fi

    if [ "$dry_run" = "true" ]; then
      chain_monitor_slack_list_summary_add_operation "$summary" "would_update" "$row_key" "$existing_row_id" "ok" "dry-run"
      continue
    fi

    if chain_monitor_slack_list_update_row "$list_id" "$existing_row_id" "$row_file" "$response"; then
      history=$(chain_monitor_slack_list_existing_history "$existing_json")
      chain_monitor_slack_list_state_upsert_desired_row "$state_work" "$row_file" "$existing_row_id" "$desired_hash" "$now_epoch" "$history"
      chain_monitor_slack_list_summary_add_operation "$summary" "update" "$row_key" "$existing_row_id" "ok" "hash-changed"
      continue
    fi

    if chain_monitor_slack_list_error_requires_recreate "$response"; then
      error=$(jq -r '.error // "recreate_required"' "$response")
      chain_monitor_slack_list_summary_add_operation "$summary" "update" "$row_key" "$existing_row_id" "recreate_required" "$error"
      history=$(chain_monitor_slack_list_row_history_with_current "$existing_json")
      old_row_id="$existing_row_id"
      if chain_monitor_slack_list_create_row "$list_id" "$row_file" "$parent_row_id" "$response"; then
        new_row_id=$(chain_monitor_slack_list_extract_created_row_id "$response")
        chain_monitor_slack_list_state_upsert_desired_row "$state_work" "$row_file" "$new_row_id" "$desired_hash" "$now_epoch" "$history"
        chain_monitor_slack_list_summary_add_operation "$summary" "create" "$row_key" "$new_row_id" "ok" "recreate"
        case "$error" in row_not_found|invalid_row_id) ;; *)
          if chain_monitor_slack_list_archive_row "$list_id" "$old_row_id" "$row_key" "$archive_response"; then
            chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$row_key" "$old_row_id" "ok" "recreate-old-row"
          else
            rc=1
            error=$(jq -r '.error // "archive_old_row_failed"' "$archive_response")
            chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$row_key" "$old_row_id" "failed" "$error"
          fi
          ;;
        esac
      else
        rc=1
        error=$(jq -r '.error // "recreate_failed"' "$response")
        chain_monitor_slack_list_summary_add_operation "$summary" "create" "$row_key" "" "failed" "$error"
      fi
    else
      rc=1
      error=$(jq -r '.error // "update_failed"' "$response")
      chain_monitor_slack_list_summary_add_operation "$summary" "update" "$row_key" "$existing_row_id" "failed" "$error"
    fi
  done < <(jq -c '.[]' "$desired_rows")

  while IFS= read -r orphan_json; do
    local orphan_file orphan_key orphan_id orphaned_at age response error
    orphan_file="$tmpdir/orphan.json"
    response="$tmpdir/orphan-response.json"
    printf '%s\n' "$orphan_json" > "$orphan_file"
    orphan_key=$(jq -r '.row_key' "$orphan_file")
    orphan_id=$(jq -r '.row_id // ""' "$orphan_file")
    orphaned_at=$(jq -r '.orphaned_at // empty' "$orphan_file")
    if [ -z "$orphaned_at" ]; then
      orphaned_at="$now_epoch"
    fi
    age=$((now_epoch - orphaned_at))
    if [ "$repair_orphans" = "true" ] || [ "$age" -ge "$archive_retention_s" ]; then
      if [ -n "$orphan_id" ] && [ "$dry_run" != "true" ]; then
        if chain_monitor_slack_list_archive_row "$list_id" "$orphan_id" "$orphan_key" "$response"; then
          chain_monitor_slack_list_state_mark_archived "$state_work" "$orphan_key" "$now_epoch"
          chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$orphan_key" "$orphan_id" "ok" "orphan-retention"
        else
          rc=1
          error=$(jq -r '.error // "orphan_archive_failed"' "$response")
          chain_monitor_slack_list_summary_add_operation "$summary" "archive" "$orphan_key" "$orphan_id" "failed" "$error"
        fi
      else
        chain_monitor_slack_list_summary_add_operation "$summary" "would_archive" "$orphan_key" "$orphan_id" "ok" "orphan-retention"
      fi
    else
      if [ "$dry_run" != "true" ]; then
        chain_monitor_slack_list_state_mark_stale "$state_work" "$orphan_key" "$now_epoch"
      fi
      chain_monitor_slack_list_summary_add_operation "$summary" "skip_orphan_stale" "$orphan_key" "$orphan_id" "ok" "retention-pending"
    fi
  done < <(jq -c --slurpfile desired "$desired_rows" '
    ($desired[0] | map(.row_key)) as $desired_keys
    | .rows[]? as $state_row
    | $state_row
    | select(($desired_keys | index($state_row.row_key)) == null)
    | select((.archived_at // null) == null and .status != "archived")
  ' "$state_work")

  if [ "$dry_run" != "true" ]; then
    mkdir -p "$(dirname "$state_path")" || {
      rm -rf "$tmpdir"
      return 1
    }
    cp "$state_work" "$state_path"
  fi

  failed_count=$(jq -r '.failed | length' "$summary")
  cat "$summary"
  rm -rf "$tmpdir"
  if [ "$failed_count" -gt 0 ]; then
    return 1
  fi
  return "$rc"
}
