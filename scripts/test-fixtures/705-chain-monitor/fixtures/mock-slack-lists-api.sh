#!/usr/bin/env bash
set -euo pipefail

method="${1:?usage: mock-slack-lists-api.sh <method> <payload-json>}"
payload_path="${2:?usage: mock-slack-lists-api.sh <method> <payload-json>}"
store_path="${CHAIN_MONITOR_SLACK_LIST_MOCK_STORE:?set CHAIN_MONITOR_SLACK_LIST_MOCK_STORE}"
log_path="${CHAIN_MONITOR_SLACK_LIST_MOCK_LOG:-}"

mkdir -p "$(dirname "$store_path")"
if [ ! -f "$store_path" ]; then
  jq -n '{schema_version:1,next_id:1,active:[],archived:[],failures:[]}' > "$store_path"
fi

payload=$(jq -c . "$payload_path")
row_key=$(printf '%s\n' "$payload" | jq -r '.row_key // .row.row_key // ""')
row_id=$(printf '%s\n' "$payload" | jq -r '.row_id // .id // .cells[0].row_id // ""')
list_id=$(printf '%s\n' "$payload" | jq -r '.list_id // ""')

if [ -n "$log_path" ]; then
  mkdir -p "$(dirname "$log_path")"
  jq -cn \
    --arg method "$method" \
    --argjson payload "$payload" \
    '{method:$method,payload:$payload}' >> "$log_path"
fi

failure=$(
  jq -r \
    --arg method "$method" \
    --arg row_key "$row_key" \
    --arg row_id "$row_id" \
    '
      .failures[]?
      | select((.method == $method or .method == "*")
        and ((.row_key // "") == "" or .row_key == $row_key)
        and ((.row_id // .id // "") == "" or (.row_id // .id) == $row_id))
      | .error
    ' "$store_path" | head -n 1
)

if [ -n "$failure" ]; then
  jq -cn --arg error "$failure" '{ok:false,error:$error}'
  exit 0
fi

case "$method" in
  slackLists.items.list)
    archived=$(printf '%s\n' "$payload" | jq -r 'if (.archived // false) then "true" else "false" end')
    if [ "$archived" = "true" ]; then
      jq -c --arg list_id "$list_id" '{ok:true,items:((.archived // []) | map(select(($list_id == "") or (.list_id == $list_id)))),next_cursor:""}' "$store_path"
    else
      jq -c --arg list_id "$list_id" '{ok:true,items:((.active // []) | map(select(($list_id == "") or (.list_id == $list_id)))),next_cursor:""}' "$store_path"
    fi
    ;;
  slackLists.items.create)
    tmp_path=$(mktemp -t mock-slack-list.XXXXXX)
    jq --argjson payload "$payload" '
      (.next_id // 1) as $next
      | ("Rec" + ($next | tostring | if length < 4 then ("0000"[0:(4 - length)] + .) else . end)) as $id
      | .next_id = ($next + 1)
      | .active += [{
          id: $id,
          list_id: $payload.list_id,
          row_key: ($payload.row_key // $payload.row.row_key // ""),
          parent_record_id: ($payload.parent_item_id // null),
          fields: ($payload.row.fields // {}),
          saved: {is_archived:false}
        }]
    ' "$store_path" > "$tmp_path"
    mv "$tmp_path" "$store_path"
    jq -c '{ok:true,item:(.active[-1])}' "$store_path"
    ;;
  slackLists.items.update)
    if ! jq -e --arg row_id "$row_id" 'any(.active[]?; .id == $row_id)' "$store_path" >/dev/null; then
      jq -cn '{ok:false,error:"row_not_found"}'
      exit 0
    fi
    tmp_path=$(mktemp -t mock-slack-list.XXXXXX)
    jq --arg row_id "$row_id" --argjson payload "$payload" '
      .active |= map(
        if .id == $row_id then
          . + {
            row_key: ($payload.row_key // .row_key),
            fields: ($payload.row.fields // .fields)
          }
        else . end
      )
    ' "$store_path" > "$tmp_path"
    mv "$tmp_path" "$store_path"
    jq -cn '{ok:true}'
    ;;
  slackLists.items.delete)
    if ! jq -e --arg row_id "$row_id" 'any(.active[]?; .id == $row_id)' "$store_path" >/dev/null; then
      jq -cn '{ok:false,error:"row_not_found"}'
      exit 0
    fi
    tmp_path=$(mktemp -t mock-slack-list.XXXXXX)
    jq --arg row_id "$row_id" '
      (.active | map(select(.id == $row_id)) | first) as $row
      | .active |= map(select(.id != $row_id))
      | .archived += [($row + {saved:{is_archived:true}})]
    ' "$store_path" > "$tmp_path"
    mv "$tmp_path" "$store_path"
    jq -cn '{ok:true}'
    ;;
  *)
    jq -cn --arg error "unsupported_method" --arg method "$method" '{ok:false,error:$error,method:$method}'
    ;;
esac
