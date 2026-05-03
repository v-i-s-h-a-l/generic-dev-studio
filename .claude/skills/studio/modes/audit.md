---
name: Studio Audit
description: Arc-coherence audit across ROADMAP, memory, git history, and GitHub Projects v2. Silent when clean; emits A1-A4 drift findings.
type: mode-pack
schema_version: 1
budget_tokens: 400
snapshots: []
reads:
  - ROADMAP.md
  - ~/.claude-personal/projects/<project-hash>/memory/*.md
  - studio-consolidation/parking-lot.md (if present)
  - git tags + git log (read-only)
  - scripts/studio-project-state.sh (GitHub Projects v2 PM fields, if authenticated)
writes:
  - ~/.dev-studio/<project>/audit/<date>.md (only in --report mode, private)
---

# Mode: Audit (Studio)

Planning-quality probes that enforce the R10 Iron Law (no claim without evidence) at the **plan layer**, not just the task-debrief layer. Four cheap checks:

| Probe | Catches |
|---|---|
| A1 Decision-ledger consistency | Phases marked ✓ in ROADMAP that no memory entry references, or memory declaring an arc CLOSED that ROADMAP shows as Planned. |
| A2 Claim-evidence audit | Phases marked ✓ without a citeable artifact (commit SHA, tag, issue, file path, or quantitative metric) in their ROADMAP entry. |
| A3 Arc-exit checklist | Arcs marked CLOSED with `studio-consolidation/parking-lot.md` still holding open items, or `project_*_pending.md` memory files still unanswered. |
| A4 PM-surface Project state | Current v2 parent arcs missing from the Studio v2 transition Project, or missing Project fields agents need for backlog reads: `Status`, `Track`, `Phase`, `Size`, `Sibling host reviewed`. |

All probes run in `scripts/studio-audit.sh`. Grep + YAML + git-log locally, plus a Projects v2 read through `scripts/studio-project-state.sh` for PM-surface fields — no LLM calls.

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
- A4 warn → update the Studio v2 transition Project item or auth/scopes so agents can read canonical backlog fields before planning from that item.

## Relationship to REVIEW R10

REVIEW R10 targets debrief-level claims; this mode targets plan-level claims. Both instantiate the same Iron Law: "no completion claim without fresh evidence." A plan that reads "Phase X ✓" with nothing structural to back it up is the same failure mode as a debrief that reads "tests passed" without a `tests_output` field.

## Intent detection

This mode is chosen by the studio router for:
- `/studio audit` (explicit invocation)
- Conversational phrasings: "audit the arc", "check plan drift", "is ROADMAP still accurate?"
- **Auto-invoked by `hooks/session-start` with `--silent`** — that is the primary invocation path; silence means nothing to say.

## Never

- Do not auto-edit ROADMAP.md, memory files, parking-lot.md, or GitHub Project fields from this mode. Probes are read-only; fixes require user consent.
- Do not load entire source files into context for auditing. The probes already ran; their findings are authoritative.
- Do not run the probes twice per session. SessionStart already invoked them; on-demand invocation is for drift follow-up.

## Fixture

`tests/mode-packs/studio/audit.yaml` — subagent must correctly distinguish clean vs drift output, refuse to auto-edit ROADMAP/Project fields, and cite the specific probe (A1/A2/A3/A4) that fired.
