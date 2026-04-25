---
name: Studio Help
description: Open the studio documentation page in the default browser. Tier-1 mode. Triggers when the user asks "how does this work?", "show me the docs", or runs `/studio help` / `/studio-help`.
type: mode-pack
schema_version: 1
budget_tokens: 300
snapshots: []
reads:
  - .claude/skills/studio/docs.html (existence check only; content not loaded into context)
writes: []
---

# Mode: Help (Studio)

Opens `.claude/skills/studio/docs.html` in the user's default browser and reports the path. Context-cheap: the HTML is rendered in the browser, not loaded into the session.

## Step 1 — Resolve the docs path

Studio is project-scoped — resolve via git repo-toplevel. No global symlink fallback (studio never lives under `~/.claude/skills/`).

```bash
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)"
DOCS_PATH="$REPO_ROOT/.claude/skills/studio/docs.html"
[ -f "$DOCS_PATH" ] || DOCS_PATH=""
```

If neither exists, tell the user the docs page is missing — do not guess a path.

## Step 2 — Open

```bash
open "$DOCS_PATH"
```

macOS-only (`open`). Linux / WSL is not a supported host today — if that changes, branch on `$(uname -s)` and use `xdg-open` / `wslview` respectively.

## Step 3 — Report

One line to the user:

> Docs opened. Path in the repo: `.claude/skills/studio/docs.html`.

If the user had a more specific question ("how do I dispatch a task?" / "what's REVIEW R11?"), answer it directly from the loaded SKILL.md / mode context *after* opening the page — don't make them hunt the HTML for something you can already answer.

## Intent detection

This mode is chosen by the studio router for explicit `help` / `/studio help` / `/studio-help` invocations, and for conversational phrasings like "show me the docs", "how does this work?", "what can the studio do?". Never dispatch here for task-level questions ("how do I fix this build error?") — those are implementation help, not studio-level docs.

## Never

- Do not read `docs.html` content into context. It is for the browser, not the session.
- Do not open anything other than the studio's own docs page in this mode. Use the Chanakya `help` path (`/chanakya-help`) for agent-level docs.
- Do not auto-open on every session start. This mode fires on explicit help intent only.

## Fixture

`tests/mode-packs/studio/help.yaml` — subagent must open `.claude/skills/studio/docs.html` via `open` and refer to the studio docs path, not generic "Claude help" output.
