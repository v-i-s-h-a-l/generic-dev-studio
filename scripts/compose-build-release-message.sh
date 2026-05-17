#!/usr/bin/env python3
"""Compose release/TestFlight bullets from git log-style commit blocks."""

from __future__ import annotations

import argparse
import json
import re
import sys


SECTION_ORDER = ["New", "Fixed", "Crash fixes", "Technical notes"]
TRAILER_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(.*)$")
URL_RE = re.compile(r"https?://[^\s)>]+")

TAXONOMY = {
    "feature": {"bucket": "new", "section": "New", "tf": True, "appstore": True},
    "bugfix-shipped": {"bucket": "fix", "section": "Fixed", "tf": True, "appstore": True},
    "bugfix-wip": {"bucket": "wip", "section": "Technical notes", "tf": True, "appstore": False},
    "regression-fix": {"bucket": "regression", "section": "Fixed", "tf": True, "appstore": True},
    "refactor": {"bucket": "technical", "section": "Technical notes", "tf": True, "appstore": False},
    "docs": {"bucket": "technical", "section": "Technical notes", "tf": True, "appstore": False},
    "test": {"bucket": "technical", "section": "Technical notes", "tf": True, "appstore": False},
    "chore": {"bucket": "technical", "section": "Technical notes", "tf": True, "appstore": False},
    "release": {"bucket": "technical", "section": "Technical notes", "tf": True, "appstore": False},
}


def trim(value: str, max_len: int | None = None) -> str:
    value = re.sub(r"\s+", " ", (value or "").strip())
    if value.endswith("."):
        value = value[:-1]
    if max_len and len(value) > max_len:
        return value[: max_len - 3].rstrip() + "..."
    return value


def sentence(value: str) -> str:
    value = trim(value)
    value = TRAILER_RE.sub("", value).strip()
    return value


def note_sentence(value: str) -> str:
    value = sentence(value)
    return "" if value.lower() == "none" else value


def crash_link(text: str) -> str:
    for link in URL_RE.findall(text or ""):
        if "crash" in link.lower() or "firebase" in link.lower():
            return link
    return URL_RE.findall(text or "")[0] if URL_RE.findall(text or "") else ""


def is_crash(text: str) -> bool:
    return bool(re.search(r"\b(crash|crashlytics|fatal|exception|exc_)\b", text or "", re.I))


def parse_block(block: str) -> dict[str, object]:
    block = block.strip()
    lines = [ln.rstrip() for ln in block.splitlines()]
    if not lines:
        return {}

    header = lines[0].strip()
    commit_id = ""
    subject = ""
    if "|" in header:
        left, right = header.split("|", 1)
        commit_id = left.strip()
        subject = right.strip()
    else:
        subject = header.strip()

    body_lines = lines[1:]
    body = "\n".join(body_lines).strip()

    trailers: dict[str, str] = {}
    for line in body_lines:
        match = TRAILER_RE.match(line.strip())
        if not match:
            continue
        key = match.group(1).strip().lower().replace("_", "-")
        value = match.group(2).strip()
        trailers[key] = value

    return {
        "id": commit_id or "unknown",
        "subject": subject,
        "body": body,
        "trailers": trailers,
        "change_type": trailers.get("change-type", "").lower(),
        "affected_areas": trailers.get("areas", "") or trailers.get("affected-areas", ""),
        "impact": trailers.get("impact", ""),
        "problem": trailers.get("problem", ""),
        "release_note": trailers.get("release-note", ""),
        "risk": trailers.get("risk", ""),
        "solution": trailers.get("solution", ""),
        "caveat": trailers.get("caveat", "") or trailers.get("caveats", ""),
        "changelog": trailers.get("changelog", ""),
    }


def inferred_metadata(commit: dict[str, object]) -> dict[str, object]:
    change_type = str(commit.get("change_type") or "")
    subject = str(commit.get("subject") or "")
    body = str(commit.get("body") or "")
    haystack = f"{subject}\n{body}"

    if change_type in TAXONOMY:
        meta = dict(TAXONOMY[change_type])
    else:
        lower = haystack.lower()
        if is_crash(lower) and crash_link(haystack):
            meta = {"bucket": "crash", "section": "Crash fixes", "tf": True, "appstore": True}
        elif re.search(r"\b(regression|revert|rolled back)\b", lower):
            meta = {"bucket": "regression", "section": "Fixed", "tf": True, "appstore": True}
        elif re.search(r"\b(wip|draft|temporary|partial)\b", lower):
            meta = {"bucket": "wip", "section": "Technical notes", "tf": True, "appstore": False}
        elif re.search(r"\b(feature|new|add|adds|added|launch|support)\b", lower):
            meta = {"bucket": "new", "section": "New", "tf": True, "appstore": True}
        else:
            meta = {"bucket": "fix", "section": "Fixed", "tf": True, "appstore": True}

    if is_crash(haystack) and crash_link(haystack):
        meta = {"bucket": "crash", "section": "Crash fixes", "tf": True, "appstore": True}
    return meta


def plain_bullet(commit: dict[str, object]) -> str:
    release_note = note_sentence(str(commit.get("release_note") or ""))
    changelog = note_sentence(str(commit.get("changelog") or ""))
    impact = note_sentence(str(commit.get("impact") or ""))
    problem = sentence(str(commit.get("problem") or ""))
    solution = sentence(str(commit.get("solution") or ""))
    subject = sentence(str(commit.get("subject") or ""))
    caveat = sentence(str(commit.get("caveat") or ""))

    if release_note:
        bullet = release_note
    elif changelog:
        bullet = changelog
    elif impact:
        bullet = impact
    elif problem and solution and solution.lower() not in problem.lower():
        bullet = f"{problem} - {solution}"
    else:
        bullet = problem or solution or subject
    if caveat:
        bullet = f"{bullet} (note: {caveat})"
    return trim(bullet, 260)


def classify(commit: dict[str, object], channel: str) -> dict[str, object]:
    meta = inferred_metadata(commit)
    bucket = str(meta["bucket"])
    include = bool(meta["tf"] if channel == "testflight" else meta["appstore"])
    bullet = plain_bullet(commit)
    haystack = f"{commit.get('subject')}\n{commit.get('body')}"

    if bucket == "crash":
        link = crash_link(haystack)
        if not link:
            return {}
        if channel == "appstore":
            confidence = "Possible fix for" if re.search(r"\b(possible|likely|could|may)\b", haystack, re.I) else "Fixed"
            bullet = f"{confidence} crash {link}"
        else:
            bullet = link
    elif bucket == "regression":
        bullet = f"regression bug fix: {bullet}"
    elif bucket == "wip":
        bullet = f"Work-in-progress fix: {bullet}"
    elif bucket == "technical" and not bullet.lower().startswith("technical:"):
        bullet = f"technical: {bullet}"

    if not bullet:
        return {}

    return {
        "commit_id": commit.get("id", "unknown"),
        "subject": commit.get("subject", ""),
        "change_type": commit.get("change_type") or "missing",
        "bucket": bucket,
        "section": meta["section"],
        "bullet": bullet,
        "included": include,
        "include_testflight": bool(meta["tf"]),
        "include_appstore": bool(meta["appstore"]),
    }


def format_blocks(raw: str, channel: str) -> tuple[list[dict[str, object]], dict[str, list[dict[str, object]]]]:
    commits = [parse_block(block) for block in re.split(r"(?m)^\s*---\s*$", raw) if block.strip()]
    sections: dict[str, list[dict[str, object]]] = {name: [] for name in SECTION_ORDER}
    detail: list[dict[str, object]] = []

    for commit in commits:
        if not commit:
            continue
        entry = classify(commit, channel)
        if not entry or not entry["included"]:
            continue
        sections[str(entry["section"])].append(entry)
        detail.append(entry)

    return detail, sections


def render_markdown(sections: dict[str, list[dict[str, object]]]) -> str:
    out: list[str] = []
    for section in SECTION_ORDER:
        entries = sections.get(section, [])
        if not entries:
            continue
        out.append(f"*{section}*")
        for entry in entries:
            bullet = str(entry.get("bullet", "")).strip()
            if bullet:
                out.append(f"- {bullet}")
        out.append("")

    if not out:
        return "(no user-facing bullets)\n"

    rendered = "\n".join(out).rstrip("\n")
    return f"{rendered}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=["testflight", "appstore"], required=True)
    parser.add_argument("--input", default="-")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.input == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(args.input, "r", encoding="utf-8") as handle:
                raw = handle.read()
        except FileNotFoundError:
            print(f"compose-build-release-message: input not readable: {args.input}", file=sys.stderr)
            return 2

    commits, sections = format_blocks(raw, args.channel)
    if args.json:
        payload = {
            "channel": args.channel,
            "commits": commits,
            "sections": sections,
            "included": sum(len(items) for items in sections.values()),
        }
        print(json.dumps(payload))
        return 0

    print(render_markdown(sections), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
