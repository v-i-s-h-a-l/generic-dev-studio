#!/usr/bin/env bash
# feedback-retroactive-sweep.sh — scan past Claude Code transcripts for
# missed `(studio-feedback)` / `(studio feedback)` prompts and materialize
# them as backdated records in the studio feedback inbox.
#
# Context: users have been tagging prompts with a bare parenthesized
# `(studio-feedback)` prefix/suffix as a lightweight "capture this" signal.
# The router only learned to recognize that form going forward; this script
# handles retroactive recovery so nothing gets lost.
#
# Usage:
#   scripts/feedback-retroactive-sweep.sh --project <slug> [--since YYYY-MM-DD]
#                                         [--apply] [--transcripts-dir <path>]
#
# Flags:
#   --project <slug>         (required) source-project slug; resolves
#                            transcript dirs under ~/.claude-personal/projects
#                            and the destination inbox via resolve_feedback_inbox_for.
#   --since <YYYY-MM-DD>     ignore messages older than this date
#                            (default: 30 days before today, UTC).
#   --apply                  actually write files. Without --apply the script
#                            runs in dry-run mode and only prints a summary.
#   --transcripts-dir <path> override transcript root (default:
#                            ~/.claude-personal/projects). Mostly for tests.
#   -h | --help              usage.
#
# Idempotency: before writing, every candidate is checked against the active
# inbox (resolve_feedback_inbox_for/<project>/) and its processed/
# subdirectory. A match is declared when a file there has the exact same
# session id AND the same user-message content (compared against the
# verbatim-quoted block in the existing file). Re-runs produce no duplicates.

set -euo pipefail

# shellcheck source=./lib-paths.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
SINCE=""
APPLY=0
TRANSCRIPTS_DIR="${HOME}/.claude-personal/projects"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)          PROJECT="${2:?--project requires a slug}"; shift 2 ;;
    --since)            SINCE="${2:?--since requires YYYY-MM-DD}";  shift 2 ;;
    --apply)            APPLY=1; shift ;;
    --dry-run)          APPLY=0; shift ;;
    --transcripts-dir)  TRANSCRIPTS_DIR="${2:?--transcripts-dir requires a path}"; shift 2 ;;
    -h|--help)          usage 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage 1 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "error: --project <slug> required" >&2; usage 1; }

# Default --since to 30 days ago (UTC).
if [ -z "$SINCE" ]; then
  SINCE=$(date -u -v-30d +%Y-%m-%d 2>/dev/null \
       || date -u -d '30 days ago' +%Y-%m-%d)
fi

# Validate SINCE shape cheaply (YYYY-MM-DD).
case "$SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "error: --since must be YYYY-MM-DD (got: $SINCE)" >&2; exit 1 ;;
esac

INBOX_DIR=$(resolve_feedback_inbox_for "$PROJECT")
PROCESSED_DIR="$INBOX_DIR/processed"

# Build the list of transcript dirs for this project. Claude Code names
# project dirs `-<path-with-slashes-as-dashes>`, and worktrees get suffixed
# with `--claude-worktrees-<name>`. We want every dir whose trailing segment
# matches the project slug OR whose dir has `--claude-worktrees-` after it.
#
# Match pattern: dir basename either equals *-<slug> or contains
# *-<slug>--claude-worktrees-*. Slug-boundary is guarded by the leading `-`.
candidate_dirs=()
if [ -d "$TRANSCRIPTS_DIR" ]; then
  while IFS= read -r d; do
    candidate_dirs+=("$d")
  done < <(
    find -L "$TRANSCRIPTS_DIR" -mindepth 1 -maxdepth 1 -type d \
      \( -name "*-${PROJECT}" -o -name "*-${PROJECT}--claude-worktrees-*" \) \
      2>/dev/null
  )
fi

if [ ${#candidate_dirs[@]} -eq 0 ]; then
  echo "warning: no transcript dirs found for project '$PROJECT' under $TRANSCRIPTS_DIR" >&2
  echo "  (no candidates to sweep; exiting cleanly)"
  exit 0
fi

# Pattern we scan for. Kept in one place so the list can grow.
PATTERN='\(studio-feedback\)\|\(studio feedback\)'

# Emit matching user records as NUL-delimited JSON blobs (one per line from
# jq, then assembled by the shell). Each record becomes a python dict with
# ts, session, content. We do the actual parsing in python for robustness
# against embedded newlines / escapes in message content.
SINCE_EPOCH=$(date -u -j -f '%Y-%m-%d' "$SINCE" +%s 2>/dev/null \
           || date -u -d "$SINCE" +%s)

# Collect all matching jsonl files first (cheap grep pre-filter).
match_files=()
# Bash 3.2 + `set -u` treats `${arr[@]}` as unbound when the array is empty;
# we already exited above if candidate_dirs was empty, so expansion is safe.
for d in "${candidate_dirs[@]}"; do
  while IFS= read -r f; do
    [ -n "$f" ] && match_files+=("$f")
  done < <(grep -l -- "(studio-feedback)\|(studio feedback)" "$d"/*.jsonl 2>/dev/null || true)
done

if [ ${#match_files[@]} -eq 0 ]; then
  echo "No transcripts contain the trigger pattern."
  echo "  project:         $PROJECT"
  echo "  since:           $SINCE"
  echo "  mode:            $([ $APPLY -eq 1 ] && echo apply || echo dry-run)"
  echo "  inbox:           $INBOX_DIR"
  echo "  transcript dirs: ${#candidate_dirs[@]}"
  exit 0
fi

# Hand off to python for JSONL parsing + idempotency check + write. Passing
# inputs via env to keep the shell quoting simple.
export FRS_PROJECT="$PROJECT"
export FRS_SINCE_EPOCH="$SINCE_EPOCH"
export FRS_APPLY="$APPLY"
export FRS_INBOX_DIR="$INBOX_DIR"
export FRS_PROCESSED_DIR="$PROCESSED_DIR"
export FRS_PATTERN='(studio-feedback)|(studio feedback)'

# Hand the file list via a temp file so python's stdin stays free for the
# heredoc'd program.  (Embedding the file list in argv would also work, but
# this keeps python3 - <<PY simple.)
FRS_FILELIST=$(mktemp -t feedback-retroactive-sweep.XXXXXX)
trap 'rm -f "$FRS_FILELIST"' EXIT
printf '%s\n' "${match_files[@]}" > "$FRS_FILELIST"
export FRS_FILELIST

python3 - <<'PY'
import os, sys, json, re, hashlib, datetime, pathlib, unicodedata

project        = os.environ["FRS_PROJECT"]
since_epoch    = int(os.environ["FRS_SINCE_EPOCH"])
apply_mode     = os.environ["FRS_APPLY"] == "1"
inbox_dir      = pathlib.Path(os.environ["FRS_INBOX_DIR"])
processed_dir  = pathlib.Path(os.environ["FRS_PROCESSED_DIR"])
pattern        = re.compile(re.escape("(studio-feedback)") + "|" + re.escape("(studio feedback)"))

with open(os.environ["FRS_FILELIST"], "r", encoding="utf-8") as fh:
    files = [ln.strip() for ln in fh if ln.strip()]

# -------------- helpers --------------

def msg_text(msg):
    """Flatten a Claude Code user-message content field into plain text."""
    if isinstance(msg, str):
        return msg
    if isinstance(msg, dict):
        content = msg.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            out = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    out.append(part.get("text", ""))
            return "\n".join(out)
    return ""

def parse_ts(ts_str):
    # ISO-8601 with optional fractional seconds and Z suffix.
    if not ts_str:
        return None
    s = ts_str.replace("Z", "+00:00")
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)

def slugify(text, max_len=48):
    # ASCII-lower-dash slug from the first meaningful words.
    norm = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    norm = pattern.sub(" ", norm)  # strip the tag itself
    norm = re.sub(r"[^A-Za-z0-9]+", "-", norm).strip("-").lower()
    if not norm:
        norm = "studio-feedback"
    return norm[:max_len].strip("-") or "studio-feedback"

# -------------- collect candidates --------------

# Dedupe on (session_id, content) — user record may appear twice across
# duplicate queue-operation/attachment rows.
seen = set()
candidates = []

for f in files:
    try:
        fh = open(f, "r", encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            line = line.strip()
            if not line or "studio-feedback" not in line and "studio feedback" not in line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rtype = rec.get("type")
            # Accept first-class user messages (canonical path) and queued
            # prompts that never reached submission (queue-operation enqueue).
            # Skip duplicates emitted as `attachment` / `last-prompt` — the
            # dedupe set below collapses same-session same-content anyway.
            if rtype == "user":
                if rec.get("isMeta") or rec.get("isSidechain"):
                    continue
                text = msg_text(rec.get("message"))
            elif rtype == "queue-operation" and rec.get("operation") == "enqueue":
                text = rec.get("content", "") or ""
            else:
                continue
            if not pattern.search(text):
                continue
            ts = parse_ts(rec.get("timestamp"))
            if ts is None or ts.timestamp() < since_epoch:
                continue
            session = rec.get("sessionId") or ""
            key = (session, text.strip())
            if key in seen:
                continue
            seen.add(key)
            candidates.append({
                "ts":       ts,
                "session":  session,
                "content":  text,
                "cwd":      rec.get("cwd", ""),
                "file":     f,
            })

candidates.sort(key=lambda c: c["ts"])

# -------------- idempotency: index existing inbox files --------------

def index_existing(*dirs):
    idx = []
    for d in dirs:
        if not d.exists():
            continue
        for p in d.iterdir():
            if not p.is_file() or p.suffix != ".md":
                continue
            try:
                body = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            # Pull session id from frontmatter if present.
            m = re.search(r"^session:\s*(\S+)\s*$", body, re.MULTILINE)
            sess = m.group(1) if m else ""
            # Collect all `> ` quoted lines as the verbatim body for fuzzy
            # content match — captures every retroactive-format file.
            quoted = "\n".join(
                re.sub(r"^>\s?", "", ln)
                for ln in body.splitlines()
                if ln.startswith(">")
            ).strip()
            idx.append({"path": p, "session": sess, "quoted": quoted, "body": body})
    return idx

existing = index_existing(inbox_dir, processed_dir)

def already_captured(cand):
    c = cand["content"].strip()
    for e in existing:
        # Primary signal: session id match + content substring either way.
        if e["session"] and e["session"] == cand["session"]:
            if c and (c in e["body"] or (e["quoted"] and e["quoted"] in c)):
                return e["path"]
        # Secondary: exact content appears somewhere in the file body.
        if c and c in e["body"]:
            return e["path"]
    return None

# -------------- emit / write --------------

sweep_run_ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

new_count = 0
skip_count = 0
for cand in candidates:
    existing_path = already_captured(cand)
    ts_iso = cand["ts"].strftime("%Y-%m-%dT%H:%M:%SZ")
    stamp  = cand["ts"].strftime("%Y%m%d-%H%M%S")
    first_line = cand["content"].splitlines()[0] if cand["content"] else ""
    preview = first_line[:80]
    sess_short = (cand["session"] or "?")[:8]

    if existing_path:
        skip_count += 1
        print(f"  SKIP  {ts_iso}  {sess_short}  already-in-inbox:{existing_path.name}")
        print(f"        {preview}")
        continue

    new_count += 1
    slug = slugify(cand["content"])
    out_name = f"{stamp}-retro-{slug}.md"
    out_path = inbox_dir / out_name

    # Build body. Indent-safe verbatim quote.
    quoted = "\n".join(f"> {ln}" if ln else ">" for ln in cand["content"].splitlines())
    body = (
        "---\n"
        f"ts: {ts_iso}\n"
        f"session: {cand['session']}\n"
        f"source_project: {project}\n"
        "kind: retroactive\n"
        "captured_retroactively: true\n"
        f"sweep_run_ts: {sweep_run_ts}\n"
        f"source_transcript: {cand['file']}\n"
        "---\n"
        "\n"
        "## User's original words (verbatim)\n"
        "\n"
        f"{quoted}\n"
        "\n"
        "## Notes\n"
        "\n"
        f"Captured by `scripts/feedback-retroactive-sweep.sh` on {sweep_run_ts}.\n"
        "The user tagged this prompt with `(studio-feedback)` / `(studio feedback)`\n"
        "but the router did not ingest it at the time. Triage and process as a\n"
        "regular inbox record.\n"
    )

    if apply_mode:
        inbox_dir.mkdir(parents=True, exist_ok=True)
        # Re-check: filename collision under --apply idempotency.
        if out_path.exists():
            print(f"  SKIP  {ts_iso}  {sess_short}  file-exists:{out_name}")
            skip_count += 1
            new_count -= 1
            continue
        out_path.write_text(body, encoding="utf-8")
        print(f"  WRITE {ts_iso}  {sess_short}  -> {out_path}")
        print(f"        {preview}")
    else:
        print(f"  NEW   {ts_iso}  {sess_short}  {preview}")

# -------------- summary --------------

print("")
print(f"project:         {project}")
print(f"mode:            {'apply' if apply_mode else 'dry-run (pass --apply to write)'}")
print(f"transcripts:     {len(files)} file(s) scanned")
print(f"candidates:      {len(candidates)}")
print(f"  already-captured: {skip_count}")
print(f"  new:              {new_count}")
print(f"inbox:           {inbox_dir}")
PY
