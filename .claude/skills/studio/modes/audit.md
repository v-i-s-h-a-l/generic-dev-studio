---
name: Studio Audit
description: Arc-coherence audit — three probes (A1 decision-ledger, A2 claim-evidence, A3 arc-exit) against ROADMAP.md + memory + git history. Silent when clean; emits drift findings when a phase/arc has fallen out of sync. Auto-invoked by SessionStart.
type: mode-pack
schema_version: 1
budget_tokens: 400
snapshots: []
reads:
  - ROADMAP.md
  - ~/.claude-personal/projects/<project-hash>/memory/*.md
  - studio-consolidation/parking-lot.md (if present)
  - git tags + git log (read-only)
writes:
  - ~/.dev-studio/<project>/audit/<date>.md (only in --report mode, private)
---

# Mode: Audit (Studio)

Planning-quality probes that enforce the R10 Iron Law (no claim without evidence) at the **plan layer**, not just the task-debrief layer. Three cheap grep-based checks:

| Probe | Catches |
|---|---|
| A1 Decision-ledger consistency | Phases marked ✓ in ROADMAP that no memory entry references, or memory declaring an arc CLOSED that ROADMAP shows as Planned. |
| A2 Claim-evidence audit | Phases marked ✓ without a citeable artifact (commit SHA, tag, issue, file path, or quantitative metric) in their ROADMAP entry. |
| A3 Arc-exit checklist | Arcs marked CLOSED with `studio-consolidation/parking-lot.md` still holding open items, or `project_*_pending.md` memory files still unanswered. |

All probes run in `scripts/studio-audit.sh`. Grep + YAML + git-log only — no LLM calls, sub-second.

## Step 1 — Run the probes

Default human-readable run:

```bash
scripts/studio-audit.sh
```

For SessionStart (silent-when-clean):

```bash
scripts/studio-audit.sh --silent
```

For machine-readable summary (hooks / pipelines):

```bash
scripts/studio-audit.sh --json
```

For a persisted findings report (private, never committed):

```bash
scripts/studio-audit.sh --report
# writes to ~/.dev-studio/<project>/audit/<ISO-date>.md; prints the path
```

Exit codes: `0` clean, `1` drift detected.

## Step 2 — Report to the user

Silent mode is the default for auto-pilot. Only speak when drift exists:

- **Clean:** no user-facing output. Exit 0.
- **Drift:** one summary line — "studio-audit: N drift items (see <report-path>)" — plus each finding with its severity and probe label. Do not attempt auto-fix unless the finding is clearly mechanical (e.g., regenerate capability-manifest); otherwise surface to the user as ask-tier.

## Step 3 — Recommended follow-up (per probe)

- A1 warn → either add a memory pointer for the orphan phase, or mark it Planned in ROADMAP if it was accidentally listed as Completed.
- A2 warn → edit the ROADMAP entry to cite evidence (commit range, tag, issue, file path, or metric). This is the R10 Iron Law applied to plans.
- A3 warn → either process remaining parking-lot items + resolve pending questions, or flip the memory claim from CLOSED to ACTIVE.

## Relationship to REVIEW R10

REVIEW R10 targets debrief-level claims; this mode targets plan-level claims. Both instantiate the same Iron Law: "no completion claim without fresh evidence." A plan that reads "Phase X ✓" with nothing structural to back it up is the same failure mode as a debrief that reads "tests passed" without a `tests_output` field.

## Intent detection

This mode is chosen by the studio router for:
- `/studio audit` (explicit invocation)
- Conversational phrasings: "audit the arc", "check plan drift", "is ROADMAP still accurate?"
- **Auto-invoked by `hooks/session-start` with `--silent`** — that is the primary invocation path; silence means nothing to say.

## Never

- Do not auto-edit ROADMAP.md, memory files, or parking-lot.md from this mode. Probes are read-only; fixes require user consent.
- Do not load entire source files into context for auditing. The probes already ran; their findings are authoritative.
- Do not run the probes twice per session. SessionStart already invoked them; on-demand invocation is for drift follow-up.

## Fixture

`tests/mode-packs/studio/audit.yaml` — subagent must correctly distinguish clean vs drift output, refuse to auto-edit ROADMAP, and cite the specific probe (A1/A2/A3) that fired.
