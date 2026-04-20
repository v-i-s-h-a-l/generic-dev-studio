---
name: Achilles Studio-Feedback
description: Studio-feedback capture (`/achilles studio-feedback` or conversational "capture this as feedback"). Mirrors `/chanakya studio-feedback` exactly — writes a feedback file to the canonical inbox path. Subagents emit feedback directly to the filesystem during task execution when they notice studio-level issues.
type: mode-pack
snapshots: []
budget_tokens: 800
---

# Mode: Studio-Feedback (`/achilles studio-feedback` or conversational "capture this as feedback")

Same contract as `/chanakya studio-feedback`: write a feedback file to the canonical inbox path. Single source of truth for path/format/ingestion rules lives in `chanakya/SKILL.md` → Mode: Studio-Feedback — identical here.

**Canonical path (restated for reference):** `~/.dev-studio/generic-dev-studio/feedback-inbox/<source-project>/<ts>-<kind>-<slug>.md`. `<source-project>` = `resolve_project()`. Create parents with `mkdir -p`. No paste required.

## Interactive invocation

User runs `/achilles studio-feedback` or says "capture this as feedback". Fill the file format from context, write to the canonical path, print one line confirming the write path.

## Subagent emission discipline (one-shot `claude -p "/achilles <task-id>"`)

When executing a task, if the subagent notices a **studio-level issue** (wrapper bug, brief-template defect, unreachable step, silent failure mode, misleading error, rule gap), write the feedback file directly to the canonical path — the one-shot subprocess has write access and the filesystem is the ingestion channel. Do **not** also emit a fenced block in the debrief; double-ingestion would duplicate records.

Scope boundary: studio-level issues only. Questions about the task's implementation go to the debrief's `status: blocked_awaiting_input` field, not here. If unsure, lean toward writing — ingestion is idempotent and cheap.
