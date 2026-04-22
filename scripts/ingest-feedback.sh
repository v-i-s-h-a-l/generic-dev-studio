#!/usr/bin/env bash
# ingest-feedback.sh — idempotent studio-feedback ingestion.
#
# For each unprocessed record in ~/.dev-studio/generic-dev-studio/feedback-inbox/<src>/*.md:
#   1. Append verbatim to ~/.dev-studio/generic-dev-studio/analysis/<today>.md.
#   2. Dispatch by `scope:` frontmatter:
#        generic-dev-studio → sanitize + `gh issue create` + move to processed/
#        upstream           → stderr notice; leave in place
#        work-project       → move to processed/ (private analysis only)
#   3. Emit `feedback_ingested` event on success.
#
# Gate: silent no-op unless the current project slug is generic-dev-studio —
# safe to wire as a SessionStart hook in any repo's .claude/settings.json.
# Files already under processed/ are never touched (idempotent rerun).
#
# Triggered by: Chanakya Step 0F (delegation), SessionStart hook, manual run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

# Cross-project contamination guard: only generic-dev-studio ingests.
PROJECT=$(resolve_project 2>/dev/null) || exit 0
[ "$PROJECT" = "generic-dev-studio" ] || exit 0

INBOX_BASE="$HOME/.dev-studio/generic-dev-studio/feedback-inbox"
[ -d "$INBOX_BASE" ] || exit 0

ANALYSIS_DIR="$HOME/.dev-studio/generic-dev-studio/analysis"
ANALYSIS_FILE="$ANALYSIS_DIR/$(date -u +%Y-%m-%d).md"
mkdir -p "$ANALYSIS_DIR"

# Enumerate via find (not glob) so word-splitting doesn't bite when zsh sources
# this transitively. `-path '*/processed/*' -prune` keeps already-ingested
# records out of the result set — the idempotency guarantee.
FILES=$(find "$INBOX_BASE" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
          -not -path '*/processed/*' 2>/dev/null | sort)

[ -n "$FILES" ] || exit 0

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

# Map `kind:` to a GH issue label. Unknowns default to `enhancement`.
kind_to_label() {
  case "$1" in
    bug|rule-miss) printf 'bug\n' ;;
    idea|rule-gap|friction|recurring-issue|studio) printf 'enhancement\n' ;;
    *) printf 'enhancement\n' ;;
  esac
}

# Crude but conservative leak-check for sanitization. Matches patterns flagged
# in CLAUDE.md privacy rules. If any hit, we refuse to auto-file and leave the
# record in place — the user handles it manually next at-laptop session.
has_leaky_tokens() {
  local body="$1"
  # Task IDs like T217, TBUILD-3, TUNIT-12 — the studio's own prefix convention
  # applied to any project, so treat as project-identifying.
  printf '%s' "$body" | grep -qE 'T[0-9]{2,4}\b|TBUILD-|TUNIT-|TUI-' && return 0
  # Slack channel references.
  printf '%s' "$body" | grep -qE '#[a-z][a-z0-9_-]{2,}' && return 0
  # @-mentions.
  printf '%s' "$body" | grep -qE '@[A-Za-z][A-Za-z0-9._-]{2,}' && return 0
  # Build numbers (4-digit) mentioned alongside "build".
  printf '%s' "$body" | grep -qiE 'build[[:space:]]+[0-9]{3,5}' && return 0
  return 1
}

# Sanitized abstract body: strip the frontmatter, then prepend the privacy
# footer. For scope=generic-dev-studio records that already describe abstract
# patterns (the convention, per the studio-feedback mode), the body itself is
# usually safe — we only block when leaky tokens slip through.
build_issue_body() {
  local file="$1" ts="$2" kind="$3"
  local body
  body=$(awk '/^---[[:space:]]*$/ { n++; next } n>=2 { print }' "$file")
  printf '%s\n\n---\n\nOriginated from a studio-feedback record on %s (kind: %s). Sanitized per CLAUDE.md privacy rules.\n' \
    "$body" "$ts" "$kind"
}

processed_count=0
upstream_count=0
skipped_count=0

printf '%s\n' "$FILES" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  rel="${file#$HOME/.dev-studio/generic-dev-studio/}"
  src_dir=$(dirname "$file")
  src_proj=$(basename "$src_dir")
  fname=$(basename "$file")

  scope=$(get_field "$file" scope)
  kind=$(get_field "$file" kind)
  ts=$(get_field "$file" ts)

  if [ -z "$scope" ] || [ -z "$kind" ]; then
    printf 'ingest-feedback: skipping %s (missing scope or kind frontmatter)\n' "$rel" >&2
    skipped_count=$((skipped_count+1))
    continue
  fi

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
      body=$(build_issue_body "$file" "${ts:-unknown}" "$kind")
      if has_leaky_tokens "$body"; then
        printf 'ingest-feedback: %s has potentially leaky tokens; not auto-filing. Review manually.\n' "$rel" >&2
        skipped_count=$((skipped_count+1))
        continue
      fi
      issue_url=$(printf '%s' "$body" | gh issue create \
                    --title "$title" \
                    --label "$label" \
                    --label "theme/internal" \
                    --body-file - 2>/dev/null) || issue_url=""
      if [ -z "$issue_url" ]; then
        printf 'ingest-feedback: gh issue create failed for %s — leaving in place\n' "$rel" >&2
        skipped_count=$((skipped_count+1))
        continue
      fi
      mkdir -p "$src_dir/processed"
      mv "$file" "$src_dir/processed/$fname"
      printf 'ingested %s → %s\n' "$rel" "$issue_url"
      append_event chanakya feedback_ingested "" \
        "{\"scope\":\"$scope\",\"kind\":\"$kind\",\"source_project\":\"$src_proj\",\"issue_url\":\"$issue_url\"}" \
        2>/dev/null || true
      processed_count=$((processed_count+1))
      ;;
    upstream)
      printf '[upstream] %s — decide destination (Playwright MCP / claude-code / other) in next at-laptop session\n' "$rel" >&2
      upstream_count=$((upstream_count+1))
      append_event chanakya feedback_ingested "" \
        "{\"scope\":\"$scope\",\"kind\":\"$kind\",\"source_project\":\"$src_proj\"}" \
        2>/dev/null || true
      ;;
    work-project)
      mkdir -p "$src_dir/processed"
      mv "$file" "$src_dir/processed/$fname"
      printf 'ingested %s (work-project, private only)\n' "$rel"
      append_event chanakya feedback_ingested "" \
        "{\"scope\":\"$scope\",\"kind\":\"$kind\",\"source_project\":\"$src_proj\"}" \
        2>/dev/null || true
      processed_count=$((processed_count+1))
      ;;
    *)
      printf 'ingest-feedback: unknown scope "%s" in %s — leaving in place\n' "$scope" "$rel" >&2
      skipped_count=$((skipped_count+1))
      ;;
  esac
done

exit 0
