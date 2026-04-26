---
name: Chanakya Urgent-Ingest
description: Hotfix fast-path — free-text intent in, minimal brief tagged urgent + immediate Achilles dispatch out. Skips brief-review; brief still flows through lib-ledger writers so #195's debrief gate fires.
type: mode-pack
schema_version: 1
budget_tokens: 2200
snapshots: [briefs.json]
reads:
  - plans/index.yaml                               # task index for next-task-id allocation
  - plans/tasks/*.yaml                             # in-flight overlap probe (writes path collision)
  - plans/briefs/*.yaml                            # in-flight brief overlap
writes:
  - plans/tasks/<task-id>.yaml                     # canonical (schema: _shared/schemas/task.md, task@1.1.0) — labels:[urgent]
  - plans/briefs/<brief-id>.yaml                   # canonical (schema: _shared/schemas/brief.md, brief@3.2.0)
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Urgent-Ingest (`/chanakya urgent <free-text intent>`)

Fast-path for hotfix work where the full intake → brief → brief-review loop is friction. Replaces the raw `/achilles <free-text>` escape hatch that skipped Chanakya and produced T301-class ledger gaps (#195) — keeps Chanakya as the entry point but strips the ceremony.

The free-text intent is the entire payload. Anything not derivable from it + repo state is omitted by design.

## Step 1 — Parse intent

Title = first sentence (or substring before first newline). Body = the rest (or same as title if single-line).

Type detection (case-insensitive): `crash`/`broken`/`regression`/`hotfix`/`fix`/`bug` → `bugfix`; anything else → `direct`.

Refuse with the dispatch hint when payload is empty — there is no sensible default.

## Step 2 — Allocate task and write artifact

Mint UUIDs, allocate the legacy `T<nnn>`, write the task with `labels: [urgent]`. The label is the structural signal — Argus / status / ship and any future urgent-aware reader checks `task.labels[] contains "urgent"`. Do not invent a new schema field.

```bash
source scripts/lib-paths.sh
source scripts/lib-ledger.sh

LEGACY_ID=$(scripts/next-task-id.sh)        # e.g. "T349"
TASK_UUID=$(mint_uuidv7)
BRIEF_UUID=$(mint_uuidv7)

write_task_artifact "$TASK_UUID" proposed "<title>" \
  legacy_task_id="$LEGACY_ID" \
  size=s \
  type=<bugfix|direct> \
  labels='["urgent"]' \
  priority=p0
```

Hard-code `size=s` and `priority=p0` — urgent is by contract narrowly-scoped top-of-queue. When intent describes broader scope (multiple modules, "refactor", "rewrite"), prepend `> ⚠ Intent looks broader than a hotfix; consider /chanakya intake if Achilles bounces` to the brief body and proceed. Never prompt — minimal-intervention (REVIEW R2) outweighs size-misclassification. Achilles surfaces the mismatch in its debrief.

## Step 3 — File overlap probe (fast variant)

Walk in-flight briefs (`scripts/query-plans.sh --kind=brief --state=dispatched`); on `writes:` overlap with the urgent intent's likely targets, prepend `> ⚠ In-flight overlap: T<other> is writing <file>. Coordinate or sequence.` to the body. Best-effort; never blocking. Skip the full brief-mode similarity probe and Figma fetch entirely — urgent-ingest trades dedupe for latency.

## Step 4 — Author the minimal brief

Body contains exactly three sections:

- `## Reproducer` — the intent payload verbatim (or "(see title)" when single-line).
- `## Acceptance` — single bullet: "fix verified locally; build green; debrief filed within 30 minutes of merge".
- `## Debrief Instructions` — pointer to `~/.claude/skills/_shared/contracts/debrief-format.md`.

Omit testability, PRD-delta, Figma, prior-context, similar-to. Write `testability: []`, `figma: null`.

```bash
PROJECT_ROOT=$(resolve_project_root)
mkdir -p "$PROJECT_ROOT/.runtime/tmp"
BODY_FILE="$PROJECT_ROOT/.runtime/tmp/brief-body-$LEGACY_ID.md"

# Use Write tool to author $BODY_FILE with the three sections above.

write_brief_artifact "$BRIEF_UUID" "$TASK_UUID" impl s \
  legacy_task_id="$LEGACY_ID" \
  slug="urgent-$(slugify "<title>")" \
  body_file="$BODY_FILE"

transition_brief_state "$BRIEF_UUID" ready chanakya "urgent-ingest fast-path"
set_task_link "$TASK_UUID" brief "$BRIEF_UUID"
transition_task_state "$TASK_UUID" briefed chanakya "urgent-ingest"
```

Brief header fields (per `_shared/rules/brief-model-effort.md`) default to `Sonnet / medium / s`. Override only when the intent explicitly names a model ("urgent: opus high — …").

## Step 5 — Dispatch Achilles immediately

```bash
scripts/write-event.sh chanakya task_dispatched "$TASK_UUID" \
  '{"mode":"urgent","brief":"'"$BRIEF_UUID"'","priority":"p0"}'
scripts/achilles-dispatch.sh "$LEGACY_ID" --urgent
```

`--urgent` is informational; the load-bearing signal is `task.labels[]`. The dispatcher's argv contract ignores unknown flags, so this is forward-compatible. Do not run brief-review.

## Step 6 — Report

> "Urgent T349 (`<title>`) briefed + dispatched in <elapsed>s. Brief: `plans/briefs/<short>.yaml`. Achilles is on it. Debrief is non-optional — #195 gate fires on merge."

Fire `scripts/chanakya-snap.sh briefs &` in the background.

## Failure modes

| Failure | Classification | Action |
|---|---|---|
| Empty payload | permanent | Surface dispatch hint, exit. Do not prompt. |
| `next-task-id.sh` lock contention | transient | Retry once after 1s, then exit. Single retry layer per R15. |
| `write_task_artifact` / `write_brief_artifact` fails | permanent | Helpers' trap rolls back partial writes; surface error; exit. |
| `achilles-dispatch.sh` exit non-zero | ambiguous | Brief is `state: ready` and survives — surface error + manual `/achilles <T-id>`. |
| In-flight overlap detected | transient | Warning prepended to body; proceed. Never block urgent on overlap. |

## Cross-links

- `_shared/schemas/task.md` — `labels[] urgent` is the authoritative urgent signal.
- `_shared/rules/brief-model-effort.md` — model/effort defaults for fast-path briefs.
- `modes/brief.md` — full-fat brief flow this mode strips.
- `modes/intake.md` — escape hatch when urgent-ingest is the wrong shape (multi-file, multi-task scope).
- `#195` — the debrief-missing structural gap; urgent briefs flow through the same writers so the gate still fires.
- `#205` — origin issue (spin-off of #197 Angle 1).
