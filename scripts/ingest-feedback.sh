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

# --quiet: silence all output. Used by the SessionStart hook so feedback-inbox
# state never pulls the active agent's attention (#258). Real ingestion failures
# leave the record in the inbox — `/studio analyze` surfaces them on next run.
for arg in "$@"; do
  case "$arg" in
    --quiet) exec >/dev/null 2>&1 ;;
  esac
done

# Cross-project contamination guard: only generic-dev-studio ingests.
PROJECT=$(resolve_project 2>/dev/null) || exit 0
[ "$PROJECT" = "generic-dev-studio" ] || exit 0

INBOX_BASE=$(resolve_feedback_inbox_root)
[ -d "$INBOX_BASE" ] || exit 0

ANALYSIS_DIR=$(resolve_analysis_root)
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

STUDIO_ROOT=$(resolve_project_root_for generic-dev-studio)
printf '%s\n' "$FILES" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  rel="${file#$STUDIO_ROOT/}"
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
