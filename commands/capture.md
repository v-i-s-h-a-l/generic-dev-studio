---
description: Retrospectively scan the current session for idea-worthy content and update IDEAS.md with dedup
allowed-tools: [Bash, Read, Edit, Agent]
---

# Capture

Extract idea-worthy content from the current session transcript, dedupe against `IDEAS.md`, and append or update entries. Runs in the background so the foreground conversation continues uninterrupted.

## Args

- `/capture` — default: scan the last ~30 turns.
- `/capture last N` — scan the last N turns.
- `/capture <any-other-text>` — treat as an explicit single-line idea; append verbatim under `## Captured` with an ISO timestamp.

## Steps

### 1. Determine transcript path

```bash
CWD_HASH=$(pwd | tr '/.' '-' | sed 's/^-//')
TRANSCRIPT=$(ls -t "$HOME/.claude/projects/${CWD_HASH}"/*.jsonl 2>/dev/null | head -1)
```

If `$TRANSCRIPT` is empty, tell the user the transcript directory is missing and stop.

### 2. Branch on args

- **Explicit text** (anything not matching `last N` or empty) → append directly:
  - Append under `## Captured` in `IDEAS.md`: `- YYYY-MM-DD HH:MM — <text>`
  - Commit: `Capture: <first-50-chars>`
  - Done. No agent launch.

- **Retrospective** (empty args or `last N`) → launch a background agent. Continue to step 3.

### 3. Launch background agent

Use the `Agent` tool with `run_in_background: true`. Pass the brief below (substitute placeholders). Tell the user: "Idea capture agent launched in background; continuing."

### 4. Don't wait

Return control to the foreground conversation immediately. The agent will report when it completes.

---

## Agent brief (template — substitute values)

> Your job: retrospectively extract idea-worthy content from a Claude Code session transcript, dedupe against an existing `IDEAS.md`, and append or update.
>
> **Transcript:** `$TRANSCRIPT`
> **Turn window:** last `$N` turns (default 30).
> **Target file:** `/Users/vishalsingh/Documents/v-i-s-h-a-l/github/generic-dev-studio/IDEAS.md`
>
> **Extraction criteria — capture:**
> - Architectural proposals or design decisions (especially ones I accepted, rejected, or deferred).
> - Agent names, capabilities, or role descriptions that surfaced in conversation.
> - Patterns, conventions, or primitives that might be extracted later.
> - Open questions, tradeoffs, or things we're unsure about.
> - Rebellious / unconventional ideas that might otherwise be forgotten.
> - Workflow observations — "the system is over-exploring", "this step is unnecessary", etc.
>
> **Extraction criteria — skip:**
> - Routine tool output, build failures, commit messages.
> - Anything already listed in `ROADMAP.md` (§Phase sequence) or `ARCHITECTURE.md` (§Design Vision).
> - Anything tracked by an existing open GitHub issue — `gh issue list --limit 60 --state open` first, skip matches.
> - Duplicate mentions of the same idea (merge, don't re-add).
>
> **Dedup logic:**
> 1. For each candidate idea, scan existing `IDEAS.md` entries.
> 2. Match if: 3+ significant content words overlap OR same primary noun phrase OR same theme tag.
> 3. On match: append `- Updated YYYY-MM-DD — <brief note on new context>` indented under the matched entry. Do not duplicate.
> 4. On no match: append under `## Captured` as `- YYYY-MM-DD HH:MM — <1–2 sentence gist> [theme/X]` where theme is inferred from context (e.g. `theme/internal`, `theme/ios-craft`).
>
> **Output quality:**
> - One sentence summary per idea, not a paragraph.
> - Preserve the user's phrasing where it's distinctive.
> - Group related ideas into one entry — don't fragment.
>
> **Commit:**
> - Stage only `IDEAS.md`.
> - Heredoc commit message: `Capture: <N> new, <M> updated, <K> merged` + Co-Authored-By trailer.
> - Pre-commit hook will run; fix failures inline without using `ARCH_LINT=0`.
>
> **Report (under 120 words):**
> - Count of new / updated / merged entries.
> - The top 3 ideas captured (one line each).
> - Any candidates you intentionally dropped + why.
>
> Stay on the current branch. No push, no PR.
