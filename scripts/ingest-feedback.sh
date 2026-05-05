#!/usr/bin/env bash
# ingest-feedback.sh — idempotent studio-feedback ingestion.
#
# For each unprocessed record in ~/.dev-studio/generic-dev-studio/feedback-inbox/<src>/*.md:
#   1. Append verbatim to ~/.dev-studio/generic-dev-studio/analysis/<today>.md.
#   2. Dispatch by `scope:` frontmatter:
#        generic-dev-studio → sanitize, search issues, then create/comment/defer
#        upstream           → stderr notice; leave in place
#        work-project       → move to processed/ (private analysis only)
#   3. Emit `feedback_ingested` events with a disposition.
#
# Gate: silent no-op unless the current project slug is generic-dev-studio —
# safe to wire as a SessionStart hook in any repo's .claude/settings.json.
# Files already under processed/ are never touched (idempotent rerun). Public
# filing is conservative: uncertain matches stay in the inbox for manager
# triage instead of creating duplicates.
#
# Triggered by: Chanakya Step 0F (delegation), SessionStart hook, manual run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

REPO="v-i-s-h-a-l/generic-dev-studio"
INBOX_BASE=""
ISSUES_FILE=""
ACTIONS_FILE=""
ANALYSIS_FILE=""
EMIT_EVENTS=1

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/ingest-feedback.sh [--quiet] [--inbox-root <dir>] [--issues-file <json>] [--repo owner/repo] [--actions-file <jsonl>] [--analysis-file <path>] [--no-event]

Automatically routes studio-feedback records. Fixture flags are for local tests:
--issues-file supplies the open issue list, and --actions-file records GitHub
mutations instead of performing them.
EOF
  exit 2
}

# --quiet: silence all output. Used by the SessionStart hook so feedback-inbox
# state never pulls the active agent's attention (#258). Real ingestion failures
# leave the record in the inbox — `/studio analyze` surfaces them on next run.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) exec >/dev/null 2>&1 ;;
    --inbox-root) INBOX_BASE="${2:?--inbox-root requires a value}"; shift 2; continue ;;
    --inbox-root=*) INBOX_BASE="${1#--inbox-root=}"; shift; continue ;;
    --issues-file) ISSUES_FILE="${2:?--issues-file requires a value}"; shift 2; continue ;;
    --issues-file=*) ISSUES_FILE="${1#--issues-file=}"; shift; continue ;;
    --repo) REPO="${2:?--repo requires a value}"; shift 2; continue ;;
    --repo=*) REPO="${1#--repo=}"; shift; continue ;;
    --actions-file) ACTIONS_FILE="${2:?--actions-file requires a value}"; shift 2; continue ;;
    --actions-file=*) ACTIONS_FILE="${1#--actions-file=}"; shift; continue ;;
    --analysis-file) ANALYSIS_FILE="${2:?--analysis-file requires a value}"; shift 2; continue ;;
    --analysis-file=*) ANALYSIS_FILE="${1#--analysis-file=}"; shift; continue ;;
    --no-event) EMIT_EVENTS=0; shift; continue ;;
    -h|--help) usage ;;
    *) printf 'ingest-feedback: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
  shift
done

# Cross-project contamination guard: only generic-dev-studio ingests.
PROJECT=$(resolve_project 2>/dev/null) || exit 0
[ "$PROJECT" = "generic-dev-studio" ] || exit 0

if [ -z "$INBOX_BASE" ]; then
  INBOX_BASE=$(resolve_feedback_inbox_root)
fi
[ -d "$INBOX_BASE" ] || exit 0

if [ -z "$ANALYSIS_FILE" ]; then
  ANALYSIS_DIR=$(resolve_analysis_root)
  ANALYSIS_FILE="$ANALYSIS_DIR/$(date -u +%Y-%m-%d).md"
else
  ANALYSIS_DIR=$(dirname "$ANALYSIS_FILE")
fi
mkdir -p "$ANALYSIS_DIR"

TMPDIR=$(mktemp -d -t ingest-feedback.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
ISSUES_JSON="$TMPDIR/issues.json"
CLUSTERS_TSV="$TMPDIR/clusters.tsv"
touch "$CLUSTERS_TSV"

if [ -n "$ACTIONS_FILE" ]; then
  : > "$ACTIONS_FILE"
fi

# Enumerate via find (not glob) so word-splitting doesn't bite when zsh sources
# this transitively. `-path '*/processed/*' -prune` keeps already-ingested
# records out of the result set — the idempotency guarantee.
FILES=$(find "$INBOX_BASE" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
          -not -path '*/processed/*' 2>/dev/null | sort)

[ -n "$FILES" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  printf 'ingest-feedback: jq required for feedback routing events\n' >&2
  exit 2
fi

ISSUES_AVAILABLE=0
if [ -n "$ISSUES_FILE" ]; then
  if cp "$ISSUES_FILE" "$ISSUES_JSON" 2>/dev/null && jq empty "$ISSUES_JSON" >/dev/null 2>&1; then
    ISSUES_AVAILABLE=1
  fi
elif "$SCRIPT_DIR/studio-gh.sh" issue list \
    --repo "$REPO" \
    --state open \
    --limit 200 \
    --json number,title,body,url,state > "$ISSUES_JSON" 2>/dev/null; then
  ISSUES_AVAILABLE=1
fi

# Parse one frontmatter field verbatim (first match wins). Tolerates leading
# whitespace and trailing comment. Empty output if missing.
get_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 {
      if (match($0, "^[[:space:]]*" k "[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RLENGTH+1)
        sub(/[[:space:]]*$/, "", val)
        print val
        exit
      }
    }
  ' "$file"
}

# First H1 heading in the body (post-frontmatter). Fall back to filename slug.
get_title() {
  local file="$1" title
  title=$(awk '
    /^---[[:space:]]*$/ { n++; next }
    n>=2 && /^# / { sub(/^# /, ""); print; exit }
  ' "$file")
  if [ -z "$title" ]; then
    title=$(basename "$file" .md)
  fi
  printf '%s\n' "$title"
}

body_without_frontmatter() {
  awk '/^---[[:space:]]*$/ { n++; next } n>=2 { print }' "$1"
}

# Map `kind:` to a GH issue label. Unknowns default to `enhancement`.
kind_to_label() {
  case "$1" in
    bug|rule-miss) printf 'bug\n' ;;
    idea|rule-gap|friction|recurring-issue|studio) printf 'enhancement\n' ;;
    *) printf 'enhancement\n' ;;
  esac
}

# Leak-check focused on actual credential shapes, not project-identifying
# tokens. Task IDs, file paths, and kebab/snake identifiers are intentionally
# NOT flagged — the studio-feedback convention already abstracts records, and
# illustrative IDs are common in pattern write-ups. We reserve the block for
# high-confidence secret shapes so a human review isn't wasted on false hits.
#
# What we DO flag:
#   - JWT-looking tokens                          eyJ[A-Za-z0-9_-]{10,}\.…
#   - AWS access keys                             AKIA[0-9A-Z]{16}
#   - GitHub tokens                               gh[pous]_[A-Za-z0-9]{20,}
#   - Slack tokens                                xox[abpsr]-[0-9A-Za-z-]{10,}
#   - Google API keys                             AIza[0-9A-Za-z_-]{35}
#   - Private-key PEM headers                     -----BEGIN [A-Z ]*PRIVATE KEY-----
#   - Long opaque hex (>=32)                      [0-9a-f]{32,}  (word-boundary)
#   - Long opaque base64 (>=40, no / or .)        token-like, not a path/URL
#
# What we deliberately DON'T flag (prior false-positive sources):
#   - Task IDs like T302, TBUILD-3, TUNIT-12, TUI-7
#   - File paths (contain '/' or '.md'/'.yaml'/'.sh'/'.swift' extensions)
#   - Slack channel refs and @mentions (now handled upstream by the author;
#     the studio-feedback mode rewrites these abstractly before landing a
#     record — false-positive rate on prose was near 100%)
#   - Build numbers ("build 4127") — shown not to leak anything useful
has_leaky_tokens() {
  local body="$1"

  # High-confidence vendor secret prefixes.
  printf '%s' "$body" | grep -qE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' && return 0
  printf '%s' "$body" | grep -qE '\bAKIA[0-9A-Z]{16}\b' && return 0
  printf '%s' "$body" | grep -qE '\bgh[pousr]_[A-Za-z0-9]{20,}\b' && return 0
  printf '%s' "$body" | grep -qE '\bxox[abpsr]-[0-9A-Za-z-]{10,}\b' && return 0
  printf '%s' "$body" | grep -qE '\bAIza[0-9A-Za-z_-]{35}\b' && return 0
  printf '%s' "$body" | grep -q -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' && return 0

  # Opaque hex (>=32 chars): looks like a bare secret. Word-boundary keeps it
  # from matching substrings of commit SHAs inside URLs (those have `/` or `-`
  # around them, so still triggers — but commit SHAs aren't secrets anyway;
  # the false-positive rate for 32+ char bare hex in prose is low enough).
  printf '%s' "$body" | grep -qE '\b[0-9a-f]{32,}\b' && return 0

  # Opaque base64-ish blobs (>=40 chars, no slash/dot/space inside the run).
  # Excluding '/' and '.' means we skip file paths ("dir/file.ext") and URLs.
  # Whitespace-delimited long runs of [A-Za-z0-9+=_-] are the remaining shape
  # — most are real credentials.
  printf '%s' "$body" | grep -qE '(^|[[:space:]`"'"'"'])[A-Za-z0-9+=_-]{40,}([[:space:]`"'"'"']|$)' && return 0

  return 1
}

# Infer scope when missing. Records in the studio-feedback inbox are
# studio-scoped by definition — the chanakya project-feedback queue is
# a separate path. See #188.
infer_scope() {
  local file="$1" kind="$2"
  local explicit
  explicit=$(get_field "$file" scope)
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return
  fi
  [ -n "$kind" ] || return
  printf 'generic-dev-studio\n'
}

normalize_text() {
  printf '%s\n' "$*" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/ /g' \
    | tr ' ' '\n' \
    | awk '
      length($0) >= 4 &&
      $0 !~ /^(about|after|also|from|have|into|only|should|that|this|when|with|work|workflow|issue|issues|manager|analyze|feedback|record|records|studio|generic|candidate|candidates|public|private|manual|triage|created|existing|source|destination)$/ {
        seen[$0]=1
      }
      END {
        for (w in seen) print w
      }
    ' \
    | sort \
    | paste -sd ' ' -
}

cluster_key_for() {
  local file="$1" title="$2" body="$3" explicit tokens
  explicit=$(get_field "$file" cluster)
  [ -n "$explicit" ] || explicit=$(get_field "$file" dedupe_key)
  if [ -n "$explicit" ]; then
    normalize_text "$explicit"
    return
  fi
  tokens=$(normalize_text "$title" "$body")
  printf '%s\n' "$tokens" | awk '{ for (i=1; i<=NF && i<=6; i++) printf "%s%s", (i==1 ? "" : " "), $i }'
}

issues_tsv() {
  jq -r '.[] | [.number, (.url // ""), (.title // ""), (.body // "")] | @tsv' "$ISSUES_JSON"
}

score_issue() {
  local tokens="$1" title="$2" body="$3" issue_tokens score token
  issue_tokens=" $(normalize_text "$title" "$body") "
  score=0
  for token in $tokens; do
    case "$issue_tokens" in
      *" $token "*) score=$((score + 1)) ;;
    esac
  done
  printf '%s\n' "$score"
}

find_issue_candidate() {
  local tokens="$1" record_title="$2"
  local best_score=0 best_number="" best_url="" best_title="" number url title body score
  while IFS=$'\t' read -r number url title body; do
    [ -n "$number" ] || continue
    score=$(score_issue "$tokens" "$title" "$body")
    if [ "$(normalize_text "$record_title")" = "$(normalize_text "$title")" ] && [ -n "$(normalize_text "$title")" ]; then
      score=$((score + 3))
    fi
    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_number="$number"
      best_url="$url"
      best_title="$title"
    fi
  done < <(issues_tsv)

  [ -n "$best_number" ] || return 1
  if [ -z "$best_url" ]; then
    best_url="https://github.com/$REPO/issues/$best_number"
  fi
  if [ "$best_score" -ge 2 ]; then
    printf 'strong\t%s\t%s\t%s\t%s\n' "$best_number" "$best_url" "$best_score" "$best_title"
  else
    printf 'uncertain\t%s\t%s\t%s\t%s\n' "$best_number" "$best_url" "$best_score" "$best_title"
  fi
}

# Sanitized abstract body: strip the frontmatter, then prepend the privacy
# footer. For scope=generic-dev-studio records that already describe abstract
# patterns (the convention, per the studio-feedback mode), the body itself is
# usually safe — we only block when leaky tokens slip through.
build_issue_body() {
  local file="$1" ts="$2" kind="$3"
  local body
  body=$(body_without_frontmatter "$file")
  printf '%s\n\n---\n\nOriginated from a studio-feedback record on %s (kind: %s). Sanitized per CLAUDE.md privacy rules.\n' \
    "$body" "$ts" "$kind"
}

build_comment_body() {
  local file="$1" ts="$2" disposition="$3" body
  body=$(body_without_frontmatter "$file")
  printf 'Additional studio-feedback signal (%s, %s):\n\n%s\n' "${ts:-unknown}" "$disposition" "$body"
}

issue_number_from_url() {
  sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p' <<<"$1"
}

record_action() {
  [ -n "$ACTIONS_FILE" ] || return 0
  printf '%s\n' "$1" >> "$ACTIONS_FILE"
}

next_fixture_issue=9100

create_issue() {
  local title="$1" label="$2" body="$3" number url action create_count
  if [ -n "$ACTIONS_FILE" ]; then
    create_count=$(grep -c '"action":"create_issue"' "$ACTIONS_FILE" 2>/dev/null || true)
    create_count=${create_count:-0}
    number=$((next_fixture_issue + create_count + 1))
    url="https://github.com/$REPO/issues/$number"
    action=$(jq -cn \
      --arg action create_issue \
      --arg title "$title" \
      --arg label "$label" \
      --arg url "$url" \
      --arg body "$body" \
      '{action:$action,title:$title,label:$label,url:$url,body:$body}')
    record_action "$action"
    printf '%s\t%s\n' "$number" "$url"
    return
  fi

  url=$(printf '%s' "$body" | "$SCRIPT_DIR/studio-gh.sh" issue create \
    --repo "$REPO" \
    --title "$title" \
    --label "$label" \
    --label "theme/internal" \
    --body-file - 2>/dev/null) || return 1
  number=$(issue_number_from_url "$url")
  [ -n "$number" ] || return 1
  printf '%s\t%s\n' "$number" "$url"
}

comment_issue() {
  local number="$1" body="$2" action
  if [ -n "$ACTIONS_FILE" ]; then
    action=$(jq -cn \
      --arg action comment_issue \
      --argjson issue_number "$number" \
      --arg body "$body" \
      '{action:$action,issue_number:$issue_number,body:$body}')
    record_action "$action"
    return
  fi
  printf '%s' "$body" | "$SCRIPT_DIR/studio-gh.sh" issue comment "$number" --repo "$REPO" --body-file - >/dev/null 2>&1
}

emit_feedback_event() {
  local scope="$1" kind="$2" src_proj="$3" rel="$4" disposition="$5" number="$6" url="$7" reason="$8"
  [ "$EMIT_EVENTS" -eq 1 ] || return 0
  local data
  data=$(jq -cn \
    --arg scope "$scope" \
    --arg kind "$kind" \
    --arg source_project "$src_proj" \
    --arg source_file "$rel" \
    --arg disposition "$disposition" \
    --arg issue_url "$url" \
    --arg reason "$reason" \
    --argjson destination_issue "${number:-null}" \
    '{
      scope: $scope,
      kind: $kind,
      source_project: $source_project,
      source_file: $source_file,
      disposition: $disposition,
      destination_issue: $destination_issue,
      issue_url: (if $issue_url == "" then null else $issue_url end),
      triage_reason: (if $reason == "" then null else $reason end)
    }')
  append_event chanakya feedback_ingested "" "$data" 2>/dev/null || true
}

find_cluster_destination() {
  local key="$1"
  awk -F '\t' -v k="$key" '$1 == k { print $2 "\t" $3; exit }' "$CLUSTERS_TSV"
}

remember_cluster_destination() {
  local key="$1" number="$2" url="$3"
  [ -n "$key" ] || return 0
  printf '%s\t%s\t%s\n' "$key" "$number" "$url" >> "$CLUSTERS_TSV"
}

processed_count=0
upstream_count=0
skipped_count=0

STUDIO_ROOT=$(resolve_project_root_for generic-dev-studio)
printf '%s\n' "$FILES" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  rel="${file#$STUDIO_ROOT/}"
  source_file_rel="${file#$INBOX_BASE/}"
  src_dir=$(dirname "$file")
  src_proj=$(basename "$src_dir")
  fname=$(basename "$file")

  kind=$(get_field "$file" kind)
  ts=$(get_field "$file" ts)

  if [ -z "$kind" ]; then
    printf 'ingest-feedback: skipping %s (missing kind frontmatter)\n' "$rel" >&2
    skipped_count=$((skipped_count+1))
    continue
  fi

  scope=$(infer_scope "$file" "$kind")

  {
    printf '\n---\n'
    printf '## Ingested: %s\n\n' "$rel"
    cat "$file"
    printf '\n'
  } >> "$ANALYSIS_FILE"

  case "$scope" in
    generic-dev-studio)
      title=$(get_title "$file")
      label=$(kind_to_label "$kind")
      raw_body=$(body_without_frontmatter "$file")
      body=$(build_issue_body "$file" "${ts:-unknown}" "$kind")
      if has_leaky_tokens "$body"; then
        printf 'ingest-feedback: %s has potentially leaky tokens; leaving for manual triage.\n' "$rel" >&2
        emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "deferred_manual_triage" "" "" "privacy_scrub_required"
        skipped_count=$((skipped_count+1))
        continue
      fi

      if [ "$ISSUES_AVAILABLE" -ne 1 ]; then
        printf 'ingest-feedback: could not list existing issues; leaving %s for manual triage.\n' "$rel" >&2
        emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "deferred_manual_triage" "" "" "issue_search_unavailable"
        skipped_count=$((skipped_count+1))
        continue
      fi

      tokens=$(normalize_text "$title" "$raw_body")
      cluster_key=$(cluster_key_for "$file" "$title" "$raw_body")
      clustered=$(find_cluster_destination "$cluster_key" || true)
      if [ -n "$clustered" ]; then
        issue_number=$(printf '%s\n' "$clustered" | awk -F '\t' '{print $1}')
        issue_url=$(printf '%s\n' "$clustered" | awk -F '\t' '{print $2}')
        comment=$(build_comment_body "$file" "${ts:-unknown}" "added to same-batch issue")
        if ! comment_issue "$issue_number" "$comment"; then
          printf 'ingest-feedback: issue comment failed for %s — leaving in place\n' "$rel" >&2
          skipped_count=$((skipped_count+1))
          continue
        fi
        mkdir -p "$src_dir/processed"
        mv "$file" "$src_dir/processed/$fname"
        printf 'ingested %s → same-batch issue %s\n' "$rel" "$issue_url"
        emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "added_to_existing_issue" "$issue_number" "$issue_url" ""
        processed_count=$((processed_count+1))
        continue
      fi

      candidate=$(find_issue_candidate "$tokens" "$title" || true)
      if [ -n "$candidate" ]; then
        match_state=$(printf '%s\n' "$candidate" | awk -F '\t' '{print $1}')
        issue_number=$(printf '%s\n' "$candidate" | awk -F '\t' '{print $2}')
        issue_url=$(printf '%s\n' "$candidate" | awk -F '\t' '{print $3}')
        if [ "$match_state" = "strong" ]; then
          comment=$(build_comment_body "$file" "${ts:-unknown}" "added to existing issue")
          if ! comment_issue "$issue_number" "$comment"; then
            printf 'ingest-feedback: issue comment failed for %s — leaving in place\n' "$rel" >&2
            skipped_count=$((skipped_count+1))
            continue
          fi
          mkdir -p "$src_dir/processed"
          mv "$file" "$src_dir/processed/$fname"
          printf 'ingested %s → existing issue %s\n' "$rel" "$issue_url"
          emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "added_to_existing_issue" "$issue_number" "$issue_url" ""
          remember_cluster_destination "$cluster_key" "$issue_number" "$issue_url"
          processed_count=$((processed_count+1))
          continue
        fi

        printf 'ingest-feedback: %s may relate to issue #%s; leaving for manual triage.\n' "$rel" "$issue_number" >&2
        emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "deferred_manual_triage" "$issue_number" "$issue_url" "uncertain_similarity"
        skipped_count=$((skipped_count+1))
        continue
      fi

      created=$(create_issue "$title" "$label" "$body" || true)
      issue_number=$(printf '%s\n' "$created" | awk -F '\t' '{print $1}')
      issue_url=$(printf '%s\n' "$created" | awk -F '\t' '{print $2}')
      if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
        printf 'ingest-feedback: issue create failed for %s — leaving in place\n' "$rel" >&2
        emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "deferred_manual_triage" "" "" "issue_create_failed"
        skipped_count=$((skipped_count+1))
        continue
      fi
      mkdir -p "$src_dir/processed"
      mv "$file" "$src_dir/processed/$fname"
      printf 'ingested %s → %s\n' "$rel" "$issue_url"
      emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "created_issue" "$issue_number" "$issue_url" ""
      remember_cluster_destination "$cluster_key" "$issue_number" "$issue_url"
      processed_count=$((processed_count+1))
      ;;
    upstream)
      printf '[upstream] %s — decide destination (Playwright MCP / claude-code / other) in next at-laptop session\n' "$rel" >&2
      upstream_count=$((upstream_count+1))
      emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "upstream" "" "" "external_destination_required"
      ;;
    work-project)
      mkdir -p "$src_dir/processed"
      mv "$file" "$src_dir/processed/$fname"
      printf 'ingested %s (work-project, private only)\n' "$rel"
      emit_feedback_event "$scope" "$kind" "$src_proj" "$source_file_rel" "private_only" "" "" ""
      processed_count=$((processed_count+1))
      ;;
    *)
      printf 'ingest-feedback: unknown scope "%s" in %s — leaving in place\n' "$scope" "$rel" >&2
      skipped_count=$((skipped_count+1))
      ;;
  esac
done

# Counters above live in the piped subshell; for the post-run summary, re-scan
# the inbox for anything still sitting outside processed/. A non-zero remainder
# means the next session should explicitly check (`/studio analyze`) — silent
# skips are how a queue rots.
remaining=$(find "$INBOX_BASE" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
              -not -path '*/processed/*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining" != "0" ]; then
  printf 'ingest-feedback: %s record(s) remain unprocessed in %s — run `/studio analyze` to triage\n' \
    "$remaining" "$INBOX_BASE" >&2
fi

exit 0
