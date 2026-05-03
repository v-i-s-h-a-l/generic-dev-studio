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
