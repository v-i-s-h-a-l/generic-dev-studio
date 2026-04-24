---
name: Studio Guard
description: Pre-work guard — before starting new work, greps git log, memory, and the GitHub backlog for prior mentions. Catches the "I forgot we shipped this" / "I forgot we tried this and it didn't work" / "I forgot there's an issue open" classes of errors. On-demand only; not auto-invoked.
type: mode-pack
budget_tokens: 400
snapshots: []
reads:
  - git log --all (read-only)
  - git tag (read-only, with subjects)
  - ~/.claude-personal/projects/<project-hash>/memory/*.md
  - gh issue list (if gh authenticated; remote call)
writes: []
---

# Mode: Guard (Studio)

The prevention half of the planning-quality layer. Before proposing a piece of work ("let's build X", "let's add a probe for Y"), run Guard to detect three ways the work might already be covered or tried:

| Probe | Catches |
|---|---|
| G1 Already shipped | `git log` subject + `git tag` annotations mentioning the keyword — shipped or in-progress work. |
| G2 Already tried | Memory files (`~/.claude-personal/projects/<hash>/memory/*.md`) mentioning the keyword — prior decisions, failed approaches, or context the user previously gave. |
| G3 Already in backlog | `gh issue list --state all --search` — any open or closed issue mentioning the keyword. |

Grep-only, no LLM. Remote call only for G3 (gh issue list); skipped silently if `gh` isn't authenticated.

## Step 1 — Run the guard

```bash
scripts/studio-guard.sh "<keywords>"
```

Keywords are OR'd (passed straight to grep/gh). Be specific enough to avoid noise — "host-agnostic workers" is better than "workers".

Exit codes: `0` no prior mention anywhere, `1` one or more channels matched.

## Step 2 — Report to the user

Two cases:

- **No hits:** say "no prior mention found — proceeding is safe." Continue with the proposed work.
- **Hits:** stop and surface findings before continuing. Format each channel separately (G1 / G2 / G3). Ask whether the new work should:
  - continue (distinct from prior mentions),
  - merge with the existing issue / commit,
  - or be dropped (already done / already tried).

This is an **ask-tier decision** — Guard surfaces; the user decides. Do not silently proceed past hits.

## Step 3 — When to invoke this mode

Invoke Guard **before** proposing new work, not after. Specifically:

- User says "let's build / add / implement X" — run Guard on X first.
- Planning a new phase or deliverable — run Guard on the phase's core keyword.
- Drafting a new GitHub issue — run Guard first to surface dupes.
- Before spawning a new Agent task or brief — run Guard so the brief isn't redundant.

Do NOT run Guard:

- For user-project code work (Argus owns those regressions, not studio).
- Inside a task-level debrief (that's R10 / 4-state report territory).
- As a scheduled cron — it's a pre-work gate, not an ongoing monitor.

## Intent detection

This mode is chosen by the studio router for:
- `/studio guard <topic>` (explicit invocation)
- Conversational phrasings: "has this been done?", "are we repeating work?", "is this a dup?"
- Implicit trigger: when the user proposes substantive new work and keywords suggest prior touch, invoke silently and surface only if hits exist.

## Never

- Do not invoke Guard with vague single-word queries ("fix", "add", "refactor"). Noise will swamp signal. If the topic is unclear, ask the user to clarify.
- Do not auto-merge or auto-close based on hits. Guard is an informer; the user decides.
- Do not run Guard without at least one keyword (the script exits 2).

## Fixture

`tests/mode-packs/studio/guard.yaml` — subagent must surface all three channels separately, never auto-proceed when hits are present, and distinguish open vs closed issue state.
