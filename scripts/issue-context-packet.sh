#!/usr/bin/env bash
# Build a public-safe planning packet from an issue body and its comments.
set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/issue-context-packet.sh --repo <owner/repo> --issue <n> --out-dir <dir>
  scripts/issue-context-packet.sh --issue-json <file> --comments-json <file> --out-dir <dir>

Options:
  --repo <owner/repo>       Repository for live GitHub reads.
  --issue <n>               Issue number for live GitHub reads.
  --issue-json <file>       Fixture or pre-fetched issue JSON.
  --comments-json <file>    Fixture or pre-fetched comments JSON.
  --out-dir <dir>           Directory for packet.md, packet.json, and raw/.
  --now <iso8601>           Stable timestamp for fixtures.
  --help                    Show this help.

Raw issue/comment JSON is archived under <out-dir>/raw for private inspection.
The planner-facing packet is packet.md plus packet.json; raw comments are not
used as the direct planner prompt.
USAGE
}

repo=""
issue_number=""
issue_json=""
comments_json=""
out_dir=""
now=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --repo requires a value\n' >&2; exit 2; }
      repo="$2"
      shift 2
      ;;
    --issue)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --issue requires a value\n' >&2; exit 2; }
      issue_number="$2"
      shift 2
      ;;
    --issue-json)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --issue-json requires a value\n' >&2; exit 2; }
      issue_json="$2"
      shift 2
      ;;
    --comments-json)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --comments-json requires a value\n' >&2; exit 2; }
      comments_json="$2"
      shift 2
      ;;
    --out-dir)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --out-dir requires a value\n' >&2; exit 2; }
      out_dir="$2"
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || { printf 'issue-context-packet: --now requires a value\n' >&2; exit 2; }
      now="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'issue-context-packet: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$out_dir" ] || { printf 'issue-context-packet: --out-dir is required\n' >&2; exit 2; }

if [ -n "$issue_json" ] || [ -n "$comments_json" ]; then
  [ -n "$issue_json" ] && [ -n "$comments_json" ] || {
    printf 'issue-context-packet: --issue-json and --comments-json must be provided together\n' >&2
    exit 2
  }
else
  [ -n "$repo" ] || { printf 'issue-context-packet: --repo is required for live reads\n' >&2; exit 2; }
  [ -n "$issue_number" ] || { printf 'issue-context-packet: --issue is required for live reads\n' >&2; exit 2; }
fi

mkdir -p "$out_dir/raw"

if [ -z "$issue_json" ]; then
  case "$repo" in
    */*) ;;
    *) printf 'issue-context-packet: --repo must be owner/repo\n' >&2; exit 2 ;;
  esac
  case "$issue_number" in
    *[!0-9]*|"") printf 'issue-context-packet: --issue must be numeric\n' >&2; exit 2 ;;
  esac
  issue_json="$out_dir/raw/issue.json"
  comments_json="$out_dir/raw/comments.json"
  "$SCRIPT_DIR/studio-gh.sh" api "repos/$repo/issues/$issue_number" >"$issue_json"
  "$SCRIPT_DIR/studio-gh.sh" api --paginate --slurp "repos/$repo/issues/$issue_number/comments?per_page=100" >"$comments_json"
else
  cp "$issue_json" "$out_dir/raw/issue.json"
  cp "$comments_json" "$out_dir/raw/comments.json"
  issue_json="$out_dir/raw/issue.json"
  comments_json="$out_dir/raw/comments.json"
fi

if [ -z "$now" ]; then
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi

ISSUE_JSON="$issue_json" COMMENTS_JSON="$comments_json" PACKET_MD="$out_dir/packet.md" PACKET_JSON="$out_dir/packet.json" NOW="$now" \
  python3 - <<'PY'
import hashlib
import json
import os
import re
from datetime import datetime, timezone

MARKER_RE = re.compile(
    r"^<!-- studio-comment:v1 kind=(?P<kind>[A-Za-z0-9._:/-]+) "
    r"idempotency_key=(?P<idempotency_key>[A-Za-z0-9._:/-]+) "
    r"target=(?P<target>(?:issue|pr):[0-9]+) "
    r"source=(?P<source>[A-Za-z0-9._:/-]+) -->$"
)

CATEGORY_PATTERNS = {
    "decisions": re.compile(r"\b(decision|decided|approved|we will|ship|land)\b", re.I),
    "constraints": re.compile(r"\b(constraint|must|must not|do not|cannot|non-goal|stop condition|private|public-safe)\b", re.I),
    "failures": re.compile(r"\b(fail|failed|failure|blocked|blocker|error|regression|broken)\b", re.I),
    "acceptance_changes": re.compile(r"\b(acceptance|acceptance criteria|scope change|change request|requirement)\b", re.I),
    "conflicts": re.compile(r"\b(conflict|contradict|disagree|instead|but not|however)\b", re.I),
    "open_questions": re.compile(r"(\?|open question|should we|do we need|unclear|tbd)", re.I),
}

PRIVATE_RE = re.compile(
    r"(^|[\s`])(/Users/|/private/|/var/folders/|/tmp/|~[A-Za-z0-9._-]*/|~/?\.dev-studio|\$HOME/\.dev-studio|\$\{HOME\}/\.dev-studio)"
)
SECRET_RE = re.compile(r"(secret|token|password|api[_-]?key)\s*[:=]", re.I)


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def as_list(raw):
    if isinstance(raw, list):
        if all(isinstance(item, list) for item in raw):
            flattened = []
            for page in raw:
                flattened.extend(page)
            return flattened
        return raw
    if isinstance(raw, dict):
        if isinstance(raw.get("comments"), list):
            return raw["comments"]
        if isinstance(raw.get("nodes"), list):
            return raw["nodes"]
        if isinstance(raw.get("data"), list):
            return raw["data"]
        if isinstance(raw.get("data"), dict):
            return as_list(raw["data"])
    raise SystemExit("issue-context-packet: comments JSON must be an array or contain comments/nodes/data")


def val(obj, *names, default=None):
    for name in names:
        if isinstance(obj, dict) and obj.get(name) is not None:
            return obj[name]
    return default


def author_login(raw):
    author = val(raw, "author", "user", default={})
    if isinstance(author, dict):
        return val(author, "login", "name", default="unknown")
    if isinstance(author, str):
        return author
    return "unknown"


def author_type(raw):
    author = val(raw, "author", "user", default={})
    if isinstance(author, dict):
        return val(author, "type", default="unknown")
    return "unknown"


def parse_time(text):
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def iso_sort_key(text):
    parsed = parse_time(text)
    if parsed is None:
        return datetime.min.replace(tzinfo=timezone.utc)
    return parsed


def short(text, limit=220):
    clean = re.sub(r"\s+", " ", text or "").strip()
    if len(clean) <= limit:
        return clean
    return clean[: limit - 1].rstrip() + "..."


def public_safe(text):
    if PRIVATE_RE.search(text or ""):
        return False
    if SECRET_RE.search(text or ""):
        return False
    return True


def first_signal_line(body, pattern):
    for line in (body or "").splitlines():
        stripped = line.strip(" -*\t")
        if stripped and pattern.search(stripped):
            return short(stripped)
    return short(body)


def normalize_issue(raw):
    issue = {
        "number": val(raw, "number", default=0),
        "title": val(raw, "title", default=""),
        "state": val(raw, "state", default="unknown"),
        "url": val(raw, "html_url", "url", default=""),
        "created_at": val(raw, "created_at", "createdAt", default=None),
        "updated_at": val(raw, "updated_at", "updatedAt", default=None),
        "closed_at": val(raw, "closed_at", "closedAt", default=None),
        "author": author_login(raw),
        "body_sha256": hashlib.sha256((val(raw, "body", default="") or "").encode("utf-8")).hexdigest(),
    }
    if not issue["number"]:
        raise SystemExit("issue-context-packet: issue JSON missing number")
    return issue


def normalize_comment(raw, ordinal):
    body = val(raw, "body", default="") or ""
    first = body.splitlines()[0].strip() if body.splitlines() else ""
    marker_match = MARKER_RE.match(first)
    marker = marker_match.groupdict() if marker_match else None
    login = author_login(raw)
    a_type = author_type(raw)
    if marker:
        classification = "marked_agent"
    elif a_type == "Bot" or login.endswith("[bot]") or login in {"github-actions", "studio-bot", "claude", "codex"}:
        classification = "legacy_unmarked_agent"
    else:
        classification = "human"
    return {
        "ordinal": ordinal,
        "id": str(val(raw, "id", "databaseId", default=f"ordinal-{ordinal}")),
        "url": val(raw, "html_url", "url", default=None),
        "created_at": val(raw, "created_at", "createdAt", default=None),
        "updated_at": val(raw, "updated_at", "updatedAt", default=None),
        "author": {"login": login, "type": a_type, "classification": classification},
        "marker": marker,
        "body": body,
        "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
        "public_safe": public_safe(body),
        "duplicate_of": None,
        "stale_reasons": [],
        "signals": {name: [] for name in CATEGORY_PATTERNS},
    }


issue_raw = load_json(os.environ["ISSUE_JSON"])
comments_raw = as_list(load_json(os.environ["COMMENTS_JSON"]))
issue = normalize_issue(issue_raw)
comments = [normalize_comment(raw, idx + 1) for idx, raw in enumerate(comments_raw)]
comments.sort(key=lambda c: (iso_sort_key(c["created_at"]), c["ordinal"]))
for idx, comment in enumerate(comments, start=1):
    comment["ordinal"] = idx

latest_by_key = {}
for comment in comments:
    marker = comment["marker"]
    if marker and marker.get("idempotency_key"):
        latest_by_key[marker["idempotency_key"]] = comment["id"]
for comment in comments:
    marker = comment["marker"]
    if marker and marker.get("idempotency_key") and latest_by_key.get(marker["idempotency_key"]) != comment["id"]:
        comment["duplicate_of"] = latest_by_key[marker["idempotency_key"]]
        comment["stale_reasons"].append("superseded_duplicate_idempotency_key")
    if issue["closed_at"] and comment["created_at"] and parse_time(comment["created_at"]) and parse_time(issue["closed_at"]):
        if parse_time(comment["created_at"]) > parse_time(issue["closed_at"]):
            comment["stale_reasons"].append("after_issue_closed")
    if not comment["public_safe"]:
        comment["stale_reasons"].append("private_or_secret_shaped_content_redacted")

for comment in comments:
    if not comment["public_safe"]:
        continue
    body = comment["body"]
    for name, pattern in CATEGORY_PATTERNS.items():
        if pattern.search(body):
            comment["signals"][name].append(first_signal_line(body, pattern))

summary_categories = {name: [] for name in CATEGORY_PATTERNS}
for comment in comments:
    if comment["stale_reasons"] and not comment["signals"]["conflicts"]:
        continue
    for name, entries in comment["signals"].items():
        for entry in entries:
            summary_categories[name].append(
                {
                    "comment_id": comment["id"],
                    "comment_ordinal": comment["ordinal"],
                    "url": comment["url"],
                    "text": entry,
                }
            )

included = [c for c in comments if c["public_safe"]]
included_range = {
    "first_comment_ordinal": included[0]["ordinal"] if included else None,
    "last_comment_ordinal": included[-1]["ordinal"] if included else None,
    "first_comment_created_at": included[0]["created_at"] if included else None,
    "last_comment_created_at": included[-1]["created_at"] if included else None,
    "included_count": len(included),
    "total_count": len(comments),
}

packet = {
    "schema_version": 1,
    "kind": "issue-context-packet",
    "generated_at": os.environ["NOW"],
    "source_issue": issue,
    "included_comment_range": included_range,
    "raw_archive": {
        "local_private": True,
        "issue_json": "raw/issue.json",
        "comments_json": "raw/comments.json",
        "planner_prompt_uses_raw_comments": False,
    },
    "comments": [
        {
            key: c[key]
            for key in [
                "ordinal",
                "id",
                "url",
                "created_at",
                "updated_at",
                "author",
                "marker",
                "body_sha256",
                "public_safe",
                "duplicate_of",
                "stale_reasons",
                "signals",
            ]
        }
        for c in comments
    ],
    "signals": summary_categories,
    "provenance": [
        {
            "ref": f"C{c['ordinal']}",
            "comment_id": c["id"],
            "url": c["url"],
            "created_at": c["created_at"],
            "author": c["author"],
            "marker": c["marker"],
            "stale_reasons": c["stale_reasons"],
        }
        for c in comments
    ],
}

required_sections = [
    "decisions",
    "constraints",
    "failures",
    "acceptance_changes",
    "conflicts",
    "open_questions",
]

def md_category(title, name):
    lines = [f"## {title}"]
    entries = summary_categories[name]
    if not entries:
        lines.append("- None extracted.")
    else:
        for entry in entries:
            lines.append(f"- {entry['text']} [C{entry['comment_ordinal']}]")
    return "\n".join(lines)


md = [
    "# Issue Context Packet",
    "",
    "## Source Issues",
    f"- Issue #{issue['number']}: {issue['title']} ({issue['state']})",
    f"- URL: {issue['url'] or 'not provided'}",
    f"- Issue body sha256: `{issue['body_sha256']}`",
    "",
    "## Included Comment Range",
    f"- Included comments: {included_range['included_count']} of {included_range['total_count']}",
    f"- Ordinal range: {included_range['first_comment_ordinal']} to {included_range['last_comment_ordinal']}",
    f"- Timestamp range: {included_range['first_comment_created_at']} to {included_range['last_comment_created_at']}",
    "- Raw archive: `raw/issue.json`, `raw/comments.json` (private/local; not a planner prompt)",
    "",
    md_category("Decisions", "decisions"),
    "",
    md_category("Constraints", "constraints"),
    "",
    md_category("Failures", "failures"),
    "",
    md_category("Acceptance Changes", "acceptance_changes"),
    "",
    md_category("Conflicts", "conflicts"),
    "",
    md_category("Open Questions", "open_questions"),
    "",
    "## Provenance",
    "| Ref | Comment ID | Created | Author | Classification | Marker Kind | Stale Reasons | URL |",
    "|---|---:|---|---|---|---|---|---|",
]

for c in comments:
    marker_kind = c["marker"]["kind"] if c["marker"] else ""
    stale = ", ".join(c["stale_reasons"]) if c["stale_reasons"] else ""
    md.append(
        f"| C{c['ordinal']} | {c['id']} | {c['created_at'] or ''} | "
        f"{c['author']['login']} | {c['author']['classification']} | {marker_kind} | {stale} | {c['url'] or ''} |"
    )

with open(os.environ["PACKET_JSON"], "w", encoding="utf-8") as fh:
    json.dump(packet, fh, indent=2, sort_keys=True)
    fh.write("\n")

with open(os.environ["PACKET_MD"], "w", encoding="utf-8") as fh:
    fh.write("\n".join(md))
    fh.write("\n")

missing = [name for name in required_sections if name not in summary_categories]
if missing:
    raise SystemExit(f"issue-context-packet: missing categories: {', '.join(missing)}")
PY

printf 'issue-context-packet: wrote %s and %s\n' "$out_dir/packet.md" "$out_dir/packet.json"
