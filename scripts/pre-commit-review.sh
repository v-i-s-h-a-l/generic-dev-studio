#!/usr/bin/env bash
# pre-commit-review.sh — run an eligible no-secret reviewer on the staged diff.
#
# Usage:
#   scripts/pre-commit-review.sh [--review-host <host>] [--bypass-review]
#
# The reviewer sees only a generated payload and the staged patch. The parent
# shell owns the commit and any audit event emission.

set -u
umask 022

usage() {
  printf 'usage: pre-commit-review.sh [--review-host <host>] [--bypass-review]\n' >&2
  exit 2
}

REVIEW_HOST="${STUDIO_REVIEW_HOST:-}"
BYPASS_REVIEW=0
CALLER_HOME="${HOME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --review-host) REVIEW_HOST="${2:?--review-host requires a value}"; shift 2 ;;
    --bypass-review) BYPASS_REVIEW=1; shift ;;
    *) printf 'pre-commit-review: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

yaml_field() {
  local file="$1" key="$2"
  grep -E "^${key}:[[:space:]]" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | tr -d '"'"'"
}

emit_gate_event() {
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local event="$1" verdict="$2" host="$3" patch_id="$4" bypass_source="${5:-}"
  local data
  if command -v jq >/dev/null 2>&1; then
    data=$(jq -cn \
      --arg verdict "$verdict" \
      --arg host "$host" \
      --arg branch "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" \
      --arg head "$(git rev-parse --short HEAD 2>/dev/null || true)" \
      --arg patch_id "$patch_id" \
      --arg bypass_source "$bypass_source" \
      '{verdict:$verdict,review_host:$host,branch:$branch,head:$head,patch_id:$patch_id,bypass_source:$bypass_source}')
  else
    data="{\"verdict\":\"$verdict\",\"review_host\":\"$host\",\"patch_id\":\"$patch_id\",\"bypass_source\":\"$bypass_source\"}"
  fi
  emit_event_keyed studio commit "$event" "" "$data" --idem-key "precommit:$event:$patch_id" >/dev/null 2>&1 || true
}

eligible_hosts() {
  local registry="$REPO_ROOT/hosts/registry.yaml" host manifest reviewer_profile
  [ -f "$registry" ] || return 1
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    manifest=$(resolve_capabilities_manifest "$host" "$REPO_ROOT" 2>/dev/null || true)
    [ -n "$manifest" ] && [ -f "$manifest" ] || continue
    reviewer_profile=$(yaml_field "$manifest" reviewer_profile)
    [ "$reviewer_profile" = "true" ] || continue
    if "$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$host" >/dev/null 2>&1; then
      printf '%s\n' "$host"
    fi
  done < <(yq -r 'keys | .[]' "$registry" 2>/dev/null)
}

if git diff --cached --quiet --exit-code; then
  printf 'pre-commit-review: no staged diff; skipping reviewer gate\n' >&2
  exit 0
fi

patch_id=$(git diff --cached --patch | git patch-id --stable 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$patch_id" ] || patch_id="unknown"

if [ "${STUDIO_BYPASS_REVIEW:-0}" = "1" ] || [ "$BYPASS_REVIEW" -eq 1 ]; then
  source="env"
  [ "$BYPASS_REVIEW" -eq 1 ] && source="flag"
  printf 'pre-commit-review: STUDIO REVIEW GATE BYPASSED by explicit user override (%s)\n' "$source" >&2
  emit_gate_event precommit_review_bypassed bypassed "${REVIEW_HOST:-none}" "$patch_id" "$source"
  exit 0
fi

command -v yq >/dev/null 2>&1 || { printf 'pre-commit-review: yq is required\n' >&2; exit 1; }

if [ -z "$REVIEW_HOST" ]; then
  hosts=()
  while IFS= read -r host; do
    [ -n "$host" ] && hosts+=("$host")
  done < <(eligible_hosts)
  [ "${#hosts[@]}" -gt 0 ] || {
    printf 'pre-commit-review: no eligible reviewer hosts found\n' >&2
    printf 'bypass (explicit user override only): STUDIO_BYPASS_REVIEW=1 git commit ...\n' >&2
    exit 1
  }
  REVIEW_HOST="${hosts[0]}"
fi

eligibility=$("$SCRIPT_DIR/pr-reviewer-eligibility.sh" "$REVIEW_HOST") || {
  printf '%s\n' "$eligibility" >&2
  printf 'pre-commit-review: reviewer host is not eligible: %s\n' "$REVIEW_HOST" >&2
  exit 1
}
manifest=$(printf '%s\n' "$eligibility" | sed -n 's/^MANIFEST=//p' | head -1)
spawn_command=$(printf '%s\n' "$eligibility" | sed -n 's/^SPAWN_COMMAND=//p' | head -1)
[ -n "$spawn_command" ] || { printf 'pre-commit-review: missing spawn command for %s\n' "$REVIEW_HOST" >&2; exit 1; }

tmpdir=$(mktemp -d -t pre-commit-review.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT
payload="$tmpdir/review-payload.md"
summary="$tmpdir/reviewer-summary.md"
reviewer_home="$tmpdir/reviewer-home"
mkdir -p "$reviewer_home"

reviewer_codex_home=""
case "$REVIEW_HOST" in
  codex*|*codex*)
    reviewer_codex_home="${CODEX_REVIEWER_HOME:-${CODEX_HOME:-${CALLER_HOME:+$CALLER_HOME/.codex}}}"
    [ -n "$reviewer_codex_home" ] && [ -d "$reviewer_codex_home" ] || {
      printf 'pre-commit-review: codex reviewer auth home not found; set CODEX_REVIEWER_HOME or CODEX_HOME\n' >&2
      exit 1
    }
    ;;
esac

{
  printf '# Studio Pre-Commit Review Payload\n\n'
  printf 'Metadata:\n\n'
  printf '%s\n' "- repository: $(basename "$REPO_ROOT")"
  printf '%s\n' "- branch: $(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf unknown)"
  printf '%s\n' "- head: $(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf '%s\n\n' "- patch_id: $patch_id"
  cat <<'PROMPT'
Review this staged studio diff against REVIEW.md and the repository-specific rules.

Return a concise report with exactly one machine-readable verdict line:

STUDIO_REVIEW_VERDICT=approved
STUDIO_REVIEW_VERDICT=approved_with_fixes
STUDIO_REVIEW_VERDICT=blocked

Use `blocked` only for critical blockers: data loss, broken routing, unsafe
runtime behavior, permission/auth changes, base-branch bypass, failing required
checks, merge conflicts, or repo-rule violations. This is a pre-commit review:
do not edit files, do not stage files, do not commit, and do not bypass this
gate.

PROMPT
  printf '\nStaged diff:\n\n```diff\n'
  git diff --cached --patch
  printf '\n```\n'
} > "$payload"

# shellcheck disable=SC2206
spawn_argv=( $spawn_command )
review_prompt="Read $payload, review the staged studio diff, and print STUDIO_REVIEW_VERDICT=<approved|approved_with_fixes|blocked>."

if ! env -i \
    PATH="$PATH" \
    HOME="$reviewer_home" \
    LANG="${LANG:-C.UTF-8}" \
    USER="${USER:-}" \
    ${reviewer_codex_home:+CODEX_HOME="$reviewer_codex_home"} \
    STUDIO_HOST="$REVIEW_HOST" \
    REVIEW_PAYLOAD="$payload" \
    STAGED_PATCH_ID="$patch_id" \
    "${spawn_argv[@]}" "$review_prompt" > "$summary" 2>"$summary.err"; then
  printf 'pre-commit-review: reviewer host failed: %s\n' "$REVIEW_HOST" >&2
  sed -n '1,80p' "$summary.err" >&2 || true
  exit 1
fi

verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary" | wc -l | tr -d ' ')
verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$summary")
if [ "$verdict_count" != "1" ]; then
  printf 'pre-commit-review: reviewer must emit exactly one STUDIO_REVIEW_VERDICT line (found %s)\n' "$verdict_count" >&2
  sed -n '1,120p' "$summary" >&2 || true
  exit 1
fi

case "$verdict" in
  approved|approved_with_fixes)
    printf 'PRECOMMIT_REVIEW_HOST=%s\n' "$REVIEW_HOST"
    printf 'PRECOMMIT_REVIEW_MANIFEST=%s\n' "$manifest"
    printf 'PRECOMMIT_REVIEW_VERDICT=%s\n' "$verdict"
    sed -n '1,120p' "$summary"
    emit_gate_event precommit_review_passed "$verdict" "$REVIEW_HOST" "$patch_id" ""
    ;;
  blocked)
    printf 'pre-commit-review: reviewer blocked commit\n' >&2
    sed -n '1,120p' "$summary" >&2 || true
    emit_gate_event precommit_review_blocked "$verdict" "$REVIEW_HOST" "$patch_id" ""
    exit 1
    ;;
  *)
    printf 'pre-commit-review: reviewer did not emit a valid STUDIO_REVIEW_VERDICT line\n' >&2
    sed -n '1,120p' "$summary" >&2 || true
    exit 1
    ;;
esac

exit 0
