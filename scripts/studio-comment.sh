#!/usr/bin/env bash
# Emit or post public-safe structured GitHub issue/PR comments.
set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/studio-comment.sh --dry-run --target issue:<n>|pr:<n> --kind <kind> --idempotency-key <key> --summary <text> [--planning-signal <text>] [--links <text>] [--evidence <text>] [--next <text>]
  scripts/studio-comment.sh --post    --target issue:<n>|pr:<n> --kind <kind> --idempotency-key <key> --summary <text> [--planning-signal <text>] [--links <text>] [--evidence <text>] [--next <text>] [--repo owner/repo]

Supported kinds:
  chain-progress, chain-issue-started, chain-issue-completed,
  chain-issue-blocked, chain-review, chain-final-summary,
  feedback-ingest, staleness-triage

The first body line is the studio-comment:v1 marker. Dry-run prints the
structured JSON payload and never calls GitHub. Posting routes through
scripts/studio-gh.sh and updates an existing matching idempotency marker when
one is already present; do not call GitHub comment commands directly.
USAGE
}

mode=""
repo=""
target=""
kind=""
idempotency_key=""
summary=""
planning_signal=""
links=""
evidence=""
next_step=""
source="studio-comment"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --post)
      mode="post"
      shift
      ;;
    --target)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --target requires a value\n' >&2; exit 2; }
      target="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --repo requires a value\n' >&2; exit 2; }
      repo="$2"
      shift 2
      ;;
    --kind)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --kind requires a value\n' >&2; exit 2; }
      kind="$2"
      shift 2
      ;;
    --idempotency-key)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --idempotency-key requires a value\n' >&2; exit 2; }
      idempotency_key="$2"
      shift 2
      ;;
    --summary)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --summary requires a value\n' >&2; exit 2; }
      summary="$2"
      shift 2
      ;;
    --planning-signal)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --planning-signal requires a value\n' >&2; exit 2; }
      planning_signal="$2"
      shift 2
      ;;
    --links)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --links requires a value\n' >&2; exit 2; }
      links="$2"
      shift 2
      ;;
    --evidence)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --evidence requires a value\n' >&2; exit 2; }
      evidence="$2"
      shift 2
      ;;
    --next)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --next requires a value\n' >&2; exit 2; }
      next_step="$2"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || { printf 'studio-comment: --source requires a value\n' >&2; exit 2; }
      source="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'studio-comment: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$mode" ] || { printf 'studio-comment: choose --dry-run or --post\n' >&2; usage; exit 2; }
[ -n "$target" ] || { printf 'studio-comment: --target is required\n' >&2; exit 2; }
[ -n "$kind" ] || { printf 'studio-comment: --kind is required\n' >&2; exit 2; }
[ -n "$idempotency_key" ] || { printf 'studio-comment: --idempotency-key is required\n' >&2; exit 2; }
[ -n "$summary" ] || { printf 'studio-comment: --summary is required\n' >&2; exit 2; }

case "$kind" in
  chain-progress|chain-issue-started|chain-issue-completed|chain-issue-blocked|chain-review|chain-final-summary|feedback-ingest|staleness-triage) ;;
  *)
    printf 'studio-comment: unsupported kind: %s\n' "$kind" >&2
    exit 2
    ;;
esac

case "$target" in
  issue:[0-9]*|pr:[0-9]*)
    target_number="${target#*:}"
    case "$target_number" in
      *[!0-9]*|"") printf 'studio-comment: target must be issue:<number> or pr:<number>\n' >&2; exit 2 ;;
    esac
    ;;
  *)
    printf 'studio-comment: target must be issue:<number> or pr:<number>\n' >&2
    exit 2
    ;;
esac

if [ -n "$repo" ]; then
  case "$repo" in
    *[!A-Za-z0-9._/-]*|*/*/*|/*|*/|"")
      printf 'studio-comment: --repo must be owner/repo\n' >&2
      exit 2
      ;;
    */*) ;;
    *)
      printf 'studio-comment: --repo must be owner/repo\n' >&2
      exit 2
      ;;
  esac
fi

case "$idempotency_key" in
  *[!A-Za-z0-9._:/-]*|"")
    printf 'studio-comment: idempotency key contains unsupported characters\n' >&2
    exit 2
    ;;
esac

case "$source" in
  *[!A-Za-z0-9._:/-]*|"")
    printf 'studio-comment: source contains unsupported characters\n' >&2
    exit 2
    ;;
esac

payload_blob=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$target" "$kind" "$idempotency_key" "$summary" "$planning_signal" "$links" "$evidence" "$next_step")
# shellcheck disable=SC2016 # Literal private-path patterns include shell syntax.
if printf '%s' "$payload_blob" | grep -Eq '(^|[[:space:]])(/Users/|/private/|/var/folders/|/tmp/|~[A-Za-z0-9._-]*/|~/?\.dev-studio|\$HOME/\.dev-studio|\$\{HOME\}/\.dev-studio)'; then
  printf 'studio-comment: public comment content appears to contain a local/private path\n' >&2
  exit 2
fi
if printf '%s' "$payload_blob" | grep -Eiq '(secret|token|password|api[_-]?key)[[:space:]]*[:=]'; then
  printf 'studio-comment: public comment content appears to contain secret-shaped material\n' >&2
  exit 2
fi

marker="<!-- studio-comment:v1 kind=$kind idempotency_key=$idempotency_key target=$target source=$source -->"
body="$marker
### Summary
$summary"

if [ -n "$planning_signal" ]; then
  body="$body

### Planning Signal
$planning_signal"
fi

if [ -n "$links" ]; then
  body="$body

### Links
$links"
fi

if [ -n "$evidence" ]; then
  body="$body

### Evidence
$evidence"
fi

if [ -n "$next_step" ]; then
  body="$body

### Next
$next_step"
fi

emit_json() {
  BODY="$body" MARKER="$marker" KIND="$kind" IDEMPOTENCY_KEY="$idempotency_key" TARGET="$target" SOURCE="$source" REPO="$repo" DRY_RUN="$1" \
    python3 - <<'PY'
import hashlib
import json
import os

body = os.environ["BODY"]
payload = {
    "schema_version": 1,
    "marker": os.environ["MARKER"],
    "kind": os.environ["KIND"],
    "idempotency_key": os.environ["IDEMPOTENCY_KEY"],
    "target": os.environ["TARGET"],
    "source": os.environ["SOURCE"],
    "repo": os.environ["REPO"] or None,
    "body": body,
    "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    "dry_run": os.environ["DRY_RUN"] == "1",
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

if [ "$mode" = "dry-run" ]; then
  emit_json 1
  exit 0
fi

case "$target" in
  issue:*) comment_subcommand="issue" ;;
  pr:*) comment_subcommand="pr" ;;
esac

if [ -z "$repo" ]; then
  repo=$("$SCRIPT_DIR/studio-gh.sh" repo view --json nameWithOwner --jq .nameWithOwner)
fi

existing_comment_id=$(
  MARKER="$marker" "$SCRIPT_DIR/studio-gh.sh" api "repos/$repo/issues/$target_number/comments" --paginate \
    --jq '.[] | select((.body // "") | startswith(env.MARKER)) | .id' 2>/dev/null | tail -n 1
)

if [ -n "$existing_comment_id" ]; then
  "$SCRIPT_DIR/studio-gh.sh" api --method PATCH "repos/$repo/issues/comments/$existing_comment_id" -f body="$body" >/dev/null
else
  printf '%s\n' "$body" | "$SCRIPT_DIR/studio-gh.sh" "$comment_subcommand" comment "$target_number" --repo "$repo" --body-file -
fi
emit_json 0
