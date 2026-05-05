#!/usr/bin/env bash

review_budget_positive_int() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

review_budget_max_diff_lines() {
  review_budget_positive_int "${STUDIO_REVIEW_FAST_PATH_MAX_DIFF_LINES:-}" \
    && printf '%s\n' "$STUDIO_REVIEW_FAST_PATH_MAX_DIFF_LINES" \
    || printf '120\n'
}

review_budget_max_files() {
  review_budget_positive_int "${STUDIO_REVIEW_FAST_PATH_MAX_FILES:-}" \
    && printf '%s\n' "$STUDIO_REVIEW_FAST_PATH_MAX_FILES" \
    || printf '3\n'
}

review_budget_payload_token_budget() {
  review_budget_positive_int "${STUDIO_REVIEW_PAYLOAD_BUDGET_TOKENS:-}" \
    && printf '%s\n' "$STUDIO_REVIEW_PAYLOAD_BUDGET_TOKENS" \
    || printf '9000\n'
}

review_budget_payload_line_cap() {
  review_budget_positive_int "${STUDIO_REVIEW_PAYLOAD_MAX_DIFF_LINES:-}" \
    && printf '%s\n' "$STUDIO_REVIEW_PAYLOAD_MAX_DIFF_LINES" \
    || printf '800\n'
}

review_budget_estimated_tokens_for_file() {
  local file="$1" bytes
  bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' ' || printf '0')
  case "$bytes" in ""|*[!0-9]*) bytes=0 ;; esac
  printf '%s\n' $(((bytes + 2) / 3))
}

review_budget_diff_line_count() {
  local file="$1" lines
  lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || printf '0')
  case "$lines" in ""|*[!0-9]*) lines=0 ;; esac
  printf '%s\n' "$lines"
}

review_budget_changed_files() {
  local file="$1"
  sed -n 's/^diff --git a\/.* b\/\(.*\)$/\1/p' "$file" 2>/dev/null \
    | sed '/^$/d' \
    | sort -u
}

review_budget_changed_file_count() {
  local file="$1"
  review_budget_changed_files "$file" | wc -l | tr -d ' '
}

review_budget_risk_triggers() {
  local diff_file="$1" diff_lines="$2" changed_files="$3" max_lines="$4" max_files="$5"
  {
    [ "$diff_lines" -le "$max_lines" ] || printf 'diff_lines\n'
    [ "$changed_files" -le "$max_files" ] || printf 'file_count\n'
    review_budget_changed_files "$diff_file" | while IFS= read -r path; do
      case "$path" in
        scripts/*.sh|core/*|_shared/*|hosts/*|.github/*|REVIEW.md|AGENTS.md|CLAUDE.md|*_schema.json|*.schema.json|*.yaml|*.yml)
          printf 'path:%s\n' "$path"
          ;;
      esac
    done
  } | awk 'NF && !seen[$0]++'
}

review_budget_policy_json() {
  local kind="$1" diff_file="$2" requested_mode="${3:-auto}"
  local diff_lines changed_files max_lines max_files risk_file risk_count mode risk_level
  local payload_budget line_cap estimated_diff_tokens

  diff_lines=$(review_budget_diff_line_count "$diff_file")
  changed_files=$(review_budget_changed_file_count "$diff_file")
  max_lines=$(review_budget_max_diff_lines)
  max_files=$(review_budget_max_files)
  payload_budget=$(review_budget_payload_token_budget)
  line_cap=$(review_budget_payload_line_cap)
  estimated_diff_tokens=$(review_budget_estimated_tokens_for_file "$diff_file")
  risk_file=$(mktemp -t review-budget-risk.XXXXXX) || return 1
  review_budget_risk_triggers "$diff_file" "$diff_lines" "$changed_files" "$max_lines" "$max_files" > "$risk_file"
  risk_count=$(wc -l < "$risk_file" 2>/dev/null | tr -d ' ')
  case "$risk_count" in ""|*[!0-9]*) risk_count=0 ;; esac

  mode="diff-scoped"
  risk_level="low"
  if [ "$risk_count" -gt 0 ]; then
    mode="expanded"
    risk_level="triggered"
  fi
  case "$requested_mode" in
    diff-scoped|minimal|fast) mode="diff-scoped"; risk_level="low" ;;
    expanded|full) mode="expanded"; [ "$risk_count" -gt 0 ] || risk_level="manual" ;;
    summarized|summary) mode="summarized"; [ "$risk_count" -gt 0 ] || risk_level="budget" ;;
    auto|"") ;;
    *) mode="diff-scoped"; risk_level="low" ;;
  esac
  if [ "$diff_lines" -gt "$line_cap" ] && [ "$mode" != "expanded" ]; then
    mode="summarized"
    risk_level="budget"
  fi

  jq -n \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg requested_mode "$requested_mode" \
    --arg risk_level "$risk_level" \
    --argjson diff_lines "$diff_lines" \
    --argjson changed_files "$changed_files" \
    --argjson max_fast_path_diff_lines "$max_lines" \
    --argjson max_fast_path_files "$max_files" \
    --argjson payload_budget_tokens "$payload_budget" \
    --argjson payload_diff_line_cap "$line_cap" \
    --argjson estimated_diff_tokens "$estimated_diff_tokens" \
    --slurpfile risk_triggers <(jq -R . "$risk_file" | jq -s '.') \
    '{
      kind:$kind,
      mode:$mode,
      requested_mode:$requested_mode,
      risk_level:$risk_level,
      diff_lines:$diff_lines,
      changed_files:$changed_files,
      fast_path:{
        max_diff_lines:$max_fast_path_diff_lines,
        max_files:$max_fast_path_files,
        eligible:($risk_level == "low" and $mode == "diff-scoped")
      },
      risk_triggers:$risk_triggers[0],
      budget:{
        payload_budget_tokens:$payload_budget_tokens,
        payload_diff_line_cap:$payload_diff_line_cap,
        estimated_diff_tokens:$estimated_diff_tokens
      }
    }'
  rm -f "$risk_file"
}

review_budget_payload_stats_json() {
  local payload="$1" policy_json="$2" bytes lines estimated_tokens budget_tokens status
  bytes=$(wc -c < "$payload" 2>/dev/null | tr -d ' ' || printf '0')
  lines=$(wc -l < "$payload" 2>/dev/null | tr -d ' ' || printf '0')
  case "$bytes" in ""|*[!0-9]*) bytes=0 ;; esac
  case "$lines" in ""|*[!0-9]*) lines=0 ;; esac
  estimated_tokens=$(((bytes + 2) / 3))
  budget_tokens=$(printf '%s\n' "$policy_json" | jq -r '.budget.payload_budget_tokens // 9000')
  status="ok"
  [ "$estimated_tokens" -le "$budget_tokens" ] || status="over_budget"
  jq -n \
    --argjson policy "$policy_json" \
    --argjson bytes "$bytes" \
    --argjson lines "$lines" \
    --argjson estimated_tokens "$estimated_tokens" \
    --arg status "$status" \
    '$policy + {payload:{bytes:$bytes, lines:$lines, estimated_tokens:$estimated_tokens, status:$status}}'
}

review_budget_emit_context_event() {
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local producer="$1" subject="$2" event="$3" stats_json="$4" idem_key="${5:-}"
  if [ -n "$idem_key" ]; then
    emit_event_keyed "$producer" review "$event" "$subject" "$stats_json" --idem-key "$idem_key" >/dev/null 2>&1 || true
  else
    emit_event_keyed "$producer" review "$event" "$subject" "$stats_json" >/dev/null 2>&1 || true
  fi
}
