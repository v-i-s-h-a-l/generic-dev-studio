---
name: Achilles Debrief
description: Direct-to-Claude debrief for bug-fix or quick-change work that bypassed the brief → worktree → Argus pipeline. Scans conversation transcript + working-tree/staged diff, asks inline whether tests are needed, emits a YAML debrief under plans/debriefs/. No brief, no worktree, no Argus, no git action. Conversational invocation only.
type: mode-pack
snapshots: []
budget_tokens: 2000
reads:
  - <conversation-transcript>                        # session state; the mode scans recent turns for intent signals
  - <git-diff-HEAD>                                  # working-tree + staged changes summarized into diff_summary
  - _shared/schemas/debrief.md                       # canonical YAML shape (debrief@2.0.0, mode: direct-debrief)
writes:
  - plans/debriefs/<debrief-id>.yaml                 # canonical YAML debrief (schema: debrief@2.0.0, mode: direct-debrief, task_id: null, brief_id: null)
  - events/<date>.jsonl                              # debrief_emitted event via scripts/write-event.sh
---

# Mode: Debrief (`/achilles debrief`)

Direct-debrief mode. Produces a structured YAML debrief from a conversational Claude session that did the work directly — no brief, no worktree, no Argus. The debrief is the sole artifact; the mode performs zero code changes, stages nothing, commits nothing.

Use when the user has just hand-fixed a bug, tweaked a file inline, or iterated against the chat transcript and wants the work captured in the ledger so the knowledge layer (Phase 2.7) and future sessions can find it.

## Preconditions

- Active Claude session with prior turns (the mode reads the transcript).
- Some pending change in the working tree or staged index — i.e. `git diff HEAD` is non-empty. If the tree is clean, surface: *"Nothing to debrief — working tree is clean. If the work has already been committed, run `/chanakya` and mention the task directly."* and exit.
- Agent-boot hook fires on first write per `_shared/contracts/agent-boot.md` (session-id = worker slot + wall-clock since there is no task-id).

## Steps

### D1 — Scan transcript

Read the last N turns of the current session (where N is the full scrollback available). Extract:

- **Intent signals** — what was the user trying to do? Surface the phrasing that framed the change.
- **Files mentioned** — names surfaced in user messages, tool calls, or assistant replies.
- **Error signatures** — any crash, stack trace, failing test output that motivated the fix.
- **Decisions taken** — places where the assistant chose path A over B and gave a reason.

Keep the extraction terse. The debrief is not a transcript — it is a structured summary of what the session produced.

### D2 — Scan diff

```bash
git diff HEAD --stat         # files + line counts
git diff HEAD                # actual changes (summarize key hunks)
```

From the diff summary derive:

- `diff_summary: {files, added_lines, removed_lines}` — integers ≥ 0.
- Primary files touched (top 3–5 by churn).
- Inferred touched areas (modules, subsystems) from the file paths.
- **Staged vs unstaged** — note in `key_learnings` if the user staged a subset deliberately; otherwise treat both as one diff.

### D3 — Infer decisions

Cross-reference D1 and D2. For each non-trivial choice visible in the diff, pair it with the WHY extracted from the transcript. Emit as `decisions: [{what, why}, …]`. If no WHY is visible, do NOT invent one — omit the entry rather than fabricate reasoning.

### D4 — Ask inline about tests

Single conversational question. Name the touched files:

> *"Changes in `<file1>, <file2>, <file3>` — do these need tests? Reply with: `y` (file follow-up test task), `n` (skip — explain why in one line), or `describe` (you'll write a short note and I'll record it)."*

Capture the answer into the `tests` block:

- `y` → `tests: {added: [], modified: [], skipped_because: null}` plus append to `follow_ups: ["Add test coverage for <files>"]`.
- `n <reason>` → `tests: {added: [], modified: [], skipped_because: "<reason>"}`.
- `describe <text>` → `tests: {added: [], modified: [], skipped_because: "<text>"}`.

If the user does not answer within the current turn, record `skipped_because: "not answered at debrief time"` and move on. The mode does not loop or re-prompt.

### D5 — Compose the YAML debrief

Write to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` where `<debrief-id>` is a fresh UUIDv7. Shape per `_shared/schemas/debrief.md` with these direct-debrief specifics:

```yaml
schema_version: {name: debrief, version: 2.0.1, min_reader: 2.0.0, deprecated_at: null}
id: <uuidv7>
task_id: null
brief_id: null
mode: direct-debrief
state: emitted
completed_at: <rfc3339-utc>
branch:
  worked_on: <current-branch>       # from `git rev-parse --abbrev-ref HEAD`
  merged_into: null
  merge_sha: null
commits: []
diff_summary: {files: N, added_lines: M, removed_lines: K}
decisions: [...]                     # from D3
tests: {...}                         # from D4
testability: null                    # direct-debrief skips the formal testability object
build_gate: lsp-only                 # no build verification in this mode
build_debt_override: false
debt: {build: false, test_unit: false, test_ui: false, notes: null}
performance: []
key_learnings: [...]                 # terse; direct-debrief often has 0–2 entries
known_issues: [...]
follow_ups: [...]                    # test follow-ups from D4 + anything the user flagged
open_questions: [...]                # any clarifying questions the user asked that went unanswered
argus_review: {status: not-invoked, review_id: null, notes: null}
```

### D6 — Emit event

Via `scripts/write-event.sh`. The `task` field carries a synthetic id of the form `direct:<debrief-id>` — same slug that appears in the debrief filename, prefixed with `direct:` to disambiguate from real task UUIDs. This keeps `debrief_emitted` joinable by `task` across task-mode and direct-debrief-mode uniformly; consumers don't need a mode-specific branch.

```json
{"ts": "…", "agent": "achilles", "event": "debrief_emitted", "task": "direct:<debrief-id>", "data": {"debrief_id": "<uuidv7>", "mode": "direct-debrief", "files_touched": <N>}}
```

### D7 — Report

One sentence plus the debrief path:

> *"Debrief captured at `plans/debriefs/<debrief-id>.yaml`. No test follow-up queued (user said skip — reason: '<reason>'). Next Chanakya sweep will ingest it."*

Then sit idle. Do not stage, commit, or push. Do not trigger Argus. Do not self-select the next task.

## Non-goals

- **Not a review.** No verdict, no Argus invocation, no `review_*` events.
- **Not an autoformatter.** Zero code changes. The diff is captured as-is.
- **Not a git action.** Does not stage, commit, or push. The user owns the git state.
- **Not a task opener.** Emits follow-up hints into the debrief; Chanakya's debrief-ingest mode decides whether to mint tasks from them.
- **Not a transcript dump.** The YAML is a structured summary, not a log.

## Integration with Chanakya

Chanakya's debrief-ingest path (Commit G3 rewrite) reads both `mode: task` and `mode: direct-debrief` uniformly — same schema, different interpretation. Direct-debriefs do not mutate task state (there is no task_id) but they contribute to the knowledge layer, feed follow-up-task minting, and surface in `/chanakya status` under a "Recent direct-debriefs" banner (added in G3 status rewrite).

## Agent-boot

First write of the session fires `scripts/emit-agent-boot.sh achilles <session-id> <skill-version>`. Idempotent per session.
