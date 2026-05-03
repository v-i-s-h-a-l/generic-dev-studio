# GitHub PM Surface

The primary PM surface for `generic-dev-studio` v2 work is the GitHub
Projects v2 board:

https://github.com/users/v-i-s-h-a-l/projects/1

Project title: `Studio v2 transition`

The board is linked to `v-i-s-h-a-l/generic-dev-studio` and is the canonical
place to read v2 transition issue state when GitHub fields are needed. Runtime
state still lives under `~/.dev-studio/**`; the Projects board is planning
state only.

Backlog-facing docs should point here first for current planning state. Use
repo issues for the durable issue body, discussion, labels, and CLI fallback.

## Agent Backlog Reader Contract

Agents that need backlog state MUST read the Project board through:

```bash
scripts/studio-project-state.sh [--json] [--search "<keywords>"] [--status "<Status>"]
```

This reader returns issue identity plus the Project fields that decide backlog
flow: `Status`, `Track`, `Phase`, `Size`, and `Sibling host reviewed`. Raw
`scripts/studio-gh.sh issue list` remains acceptable for narrow issue lookups,
but it is not sufficient for backlog planning because it cannot see Project
fields.

Mode expectations:

| Flow | Project-state use |
|---|---|
| `studio/guard` | G3 duplicate/backlog hits come from `scripts/studio-project-state.sh --search`, not raw issue search. |
| `studio/audit` | A4 verifies the current v2 parent arcs are present on the board with required Project fields populated. |
| Chanakya triage/backlog flows | Before shaping studio backlog work, read this Project state and preserve the Project fields in any surfaced candidate list. |

## Field Contract

Required custom fields:

| Field | Type | Values |
|---|---|---|
| `Status` | single select | `Todo`, `In Progress`, `Done` |
| `Size` | single select | `XS`, `S`, `M`, `L`, `XL` |
| `Track` | single select | `A substrate`, `B PM surface`, `C agent topology`, `D chain mode`, `v1 forge-safety`, `v1 apollo`, `backlog` |
| `Phase` | single select | `B1`, `B2`, `B3`, `B4`, `A0`, `A0.5`, `A1`-`A11`, `C`, `D`, `v1` |
| `Sibling host reviewed` | single select | `Not required`, `Plan clean`, `Outcome clean`, `Needs review` |

Built-in fields such as `Parent issue`, `Sub-issues progress`, `Repository`,
`Labels`, and `Milestone` remain available for GitHub-native tracking.

## Source-Of-Truth Map

B11 contract: every planning datum has exactly one canonical GitHub home.
Agents may copy a short pointer elsewhere for readability, but they must update
the canonical home first and must not keep a second editable version in sync by
hand.

| Datum | Canonical home | Agent rule |
|---|---|---|
| Work title | Issue title | Keep concise and outcome-oriented. Do not duplicate in Project fields. |
| Goal, impact, acceptance criteria, non-goals | Issue body | The body is the durable spec. Comments may discuss changes, but accepted scope changes are edited back into the body. |
| Request type and taxonomy | Labels | Use labels for stable filtering and automation (`enhancement`, `bug`, `theme/*`, `track:*`). Do not encode these in titles or Project fields. |
| Active PM state | Project `Status` field | Read v2 execution state from the board. Issue open/closed state remains GitHub's archival state, not the kanban lane. |
| Track / workstream | Project `Track` field | Use `track:*` labels for issue-list filtering only; the board field owns PM grouping. |
| Phase / batch | Project `Phase` field | Use the field for phase ordering. Mention phase in the body only when it clarifies acceptance criteria or dependencies. |
| Size / planning estimate | Project `Size` field | Do not put estimates in labels or titles. |
| Sibling-host review gate | Project `Sibling host reviewed` field | The field owns the current gate state. Phase-review artifacts under `~/.dev-studio/**` remain private evidence, not public issue state. |
| Parent / child hierarchy | Native sub-issues / parent issue links | Prefer GitHub's hierarchy over body checklists. Body checklists are transitional notes only. |
| Blocking dependencies | Native issue dependencies | Use GitHub dependencies for machine-readable ordering. Body text may explain why a dependency exists. |
| Release target | Milestone | Milestones map to `RELEASES.md` cadence. Do not use labels or Project fields for release buckets. |
| Discussion, decisions, and handoff notes | Issue comments | Comments are the conversation log. If a comment changes scope, copy the accepted result into the issue body or the relevant field. |
| Runtime execution state | `~/.dev-studio/**` artifacts | GitHub is the PM surface only. Worker summaries, reviews, events, and private analysis stay in runtime storage. |

### Reader Precedence

When fields disagree, agents resolve in this order:

1. Runtime truth for execution details: `~/.dev-studio/**`.
2. GitHub native structure for planning state: Project fields, sub-issues,
   dependencies, milestones, labels.
3. Issue body for durable human-readable scope.
4. Issue comments for discussion history.
5. Derived docs such as `ROADMAP.md`, `TRACKS.md`, and README summaries.

For v2 PM automation, Project state is canonical only for issues present on the
`Studio v2 transition` board. Guards that search for duplicate or prior work
must still include repository-wide issues when the question is "has this been
done or discussed before?", because legacy and ad-hoc issues may not be on the
board.

## Automation Auth and Permissions

All assistant-initiated GitHub CLI calls in this repo go through
`scripts/studio-gh.sh ...` so `gh` sees the user's real login home instead of
the host's synthetic `HOME`. That wrapper is required for Project reads and
writes as well as normal issue, PR, and release operations.

Projects v2 automation requires explicit Project access in addition to normal
repository access:

- Local `gh` reads of Project fields, items, and views require GitHub CLI auth
  with repository access plus `read:project`.
- Local `gh` writes to Project fields or item membership require GitHub CLI
  auth with repository access plus `project`.
- GitHub Actions that edit both the repo and the Project board use
  `GITHUB_TOKEN` for repository operations and a separately provisioned
  Project-capable token or GitHub App installation token for Project
  mutations.

For interactive setup, refresh the CLI token through the studio wrapper:

```bash
scripts/studio-gh.sh auth refresh -s project
scripts/studio-gh.sh auth status
```

Use `read:project` only for readers that never mutate Project state. Any
automation that adds items, moves items, or edits custom fields is a Project
writer and must use `project` or an equivalent fine-grained Project write
permission. Do not store Project tokens in repo files, issue bodies, chain
manifests, or `.studio` handoff artifacts; keep them in GitHub Actions secrets,
the GitHub CLI credential store, or the installed app/token store for the host.

Agent-run boundaries:

- Agents may read Project fields for planning, duplicate checks, and status
  summaries when the task explicitly needs PM state.
- Agents may mutate Project fields only from a documented workflow step, such
  as a chain-runner integration phase or an issue/milestone maintenance script.
- Agents must not bypass `scripts/studio-gh.sh`, must not print token values,
  and must not request broader scopes as a workaround for a failing operation.
- Missing Project auth is a loud blocker: report the missing scope or
  permission and stop the mutation path instead of silently falling back to
  issue-body parsing.

## Current Arc Rows

The current open v2 arcs are present on the board:

| Issue | Track | Phase | Size |
|---|---|---|---|
| `#443` PM surface | `B PM surface` | `B1` | `M` |
| `#444` substrate v2 | `A substrate` | `A0.5` | `XL` |
| `#445` agent topology v2 | `C agent topology` | `C` | `L` |
| `#446` chain mode enhancements | `D chain mode` | `D` | `M` |

The B1 leaf `#498` is also on the board with `Track=B PM surface`,
`Phase=B1`, `Size=S`, and `Sibling host reviewed=Needs review`.

## Views

Expected human views:

| View | Purpose |
|---|---|
| Table | Canonical editable backlog table |
| Board | Kanban grouped by `Status` |
| Roadmap | Timeline/roadmap view, grouped by phase or milestone once B4 lands |

Programmatic verification can read existing views, fields, repository links,
and items. In this run, GitHub's exposed GraphQL mutation schema included
project, field, item, and repository-link mutations, but no view creation or
view update mutation. If the Board or Roadmap tabs are absent in the GitHub UI,
create them manually from the project page using the names above.

## Native Dependencies

Use `scripts/studio-dependency-export.sh --issue <number>` to render the
GitHub-native `blocked_by` graph for an epic as Mermaid. The exporter reads the
`/issues/<n>/dependencies/blocked_by` API and intentionally ignores issue-body
checkboxes or prose dependency lists.

## Weekly Digest

`scripts/studio-weekly.sh` fills the free-tier Projects insight gap with a
GitHub issue digest. It reports open/created/closed counts, net backlog change,
open-issue age buckets, top labels, aged open issues, recent closures, and a
four-week closed-issue trend.

Run it locally for markdown or JSON:

```sh
scripts/studio-weekly.sh
scripts/studio-weekly.sh --json
```

`.github/workflows/studio-weekly.yml` runs every Monday and invokes
`scripts/studio-weekly.sh --post`, which creates or reuses the
`Weekly Studio Digest` issue, pins it, and appends the weekly digest as a
comment.

## Automation

| Script / Workflow | Purpose |
|---|---|
| `scripts/studio-staleness-triage.sh` / `.github/workflows/staleness-triage.yml` | Weekly GitHub issue staleness triage. Labels inactive issues after configurable `stale`, `escalate`, and `archive-candidate` thresholds; live mutation requires `--apply` and runs with `permissions: issues: write`. |
