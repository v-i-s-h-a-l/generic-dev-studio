# GitHub PM Surface

The primary PM surface for any studio-managed project is a GitHub Projects v2
board owned by that project. Each project keeps its own board; studio scripts
locate the right one through the per-project board portability contract below.

`generic-dev-studio` itself is the seed instance of this pattern. Its board is:

https://github.com/users/v-i-s-h-a-l/projects/1

Project title: `Studio v2 transition`. It is linked to
`v-i-s-h-a-l/generic-dev-studio` and is the canonical place to read studio v2
transition issue state when GitHub fields are needed. Runtime state still
lives under `~/.dev-studio/**`; the Projects board is planning state only.

Backlog-facing docs should point at the current project's board first for
current planning state. Use repo issues for the durable issue body,
discussion, labels, and CLI fallback.

## Agent Backlog Reader Contract

Agents that need backlog state MUST read the Project board through:

```bash
scripts/studio-project-state.sh [--json] [--search "<keywords>"] [--status "<Status>"]
scripts/studio-project-state.sh --by-track
scripts/studio-project-state.sh --by-phase
scripts/studio-project-state.sh --needs-review
```

This reader returns issue identity plus the Project fields that decide backlog
flow: `Status`, `Track`, `Phase`, `Size`, and `Sibling host reviewed`. Raw
`scripts/studio-gh.sh issue list` remains acceptable for narrow issue lookups,
but it is not sufficient for backlog planning because it cannot see Project
fields.

## Project Pulse Reader

For periodic "what changed on the board since last time" reporting, use the
pulse reader:

```bash
scripts/studio-project-pulse.sh                      # human pulse to stdout, snapshot advances
scripts/studio-project-pulse.sh --format md --out ~/.dev-studio/<project>/analysis/<date>-project-pulse.md
scripts/studio-project-pulse.sh --since none         # baseline snapshot only, no diff
scripts/studio-project-pulse.sh --quiet              # silent exit when nothing changed (cron-friendly)
```

Cadence is **manual-only**. The script snapshots the current Project state to
`~/.dev-studio/<project>/.runtime/state/project-board/<utc>.json` (with a
`latest.json` symlink) and diffs against the previous snapshot, surfacing
items added, started, closed, removed-while-open, needing sibling-host
review, and status changes. It calls `scripts/studio-project-state.sh --json`
under the hood, so it follows the same board portability contract; no
Project writes happen during a pulse run.

Wiring the pulse to `/loop`, a LaunchAgent, or a per-chain hook is
intentionally deferred until manual runs have established the right cadence
and signal-to-noise ratio (#896 non-goal: no noisy notifications without an
explicit cadence decision).

## Project Writer Contract

Studio issue filing should use the Project-aware helper:

```bash
scripts/studio-gh-issue-new.sh --title "..." --body-file issue.md --label enhancement
```

The helper wraps `scripts/studio-gh.sh issue create`, then calls
`scripts/studio-project-add.sh` so the issue lands on the Studio v2 transition
board. `scripts/studio-project-add.sh <issue-number|issue-url>` is also the
reusable primitive for adding existing issues to the board and setting
`Status`, `Track`, `Phase`, `Size`, and `Sibling host reviewed`.

Defaults are conservative: `Status=Todo` and
`Sibling host reviewed=Not required`. `Track` is inferred only from labels with
an unambiguous Project mapping, such as `track:pm-surface`, `track:apollo`, and
`track:forge-safety`; otherwise pass `--track` explicitly. Missing Project
write permission is a hard error, not a silent fallback.

Mode expectations:

| Flow | Project-state use |
|---|---|
| `studio/guard` | G3 duplicate/backlog hits come from `scripts/studio-project-state.sh --search`, not raw issue search. |
| `studio/audit` | A4 verifies the current v2 parent arcs are present on the board with required Project fields populated. |
| Chanakya triage/backlog flows | Before shaping studio backlog work, read this Project state and preserve the Project fields in any surfaced candidate list. |
| Studio issue creation | Use `scripts/studio-gh-issue-new.sh` so agreed work lands on the board at creation time. |

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

## Per-Project Project Board Portability Contract

Studio scripts target a single Project board per project. The portability
contract below lets `generic-dev-studio`, `turnip-ios`, and any future
studio-managed project each own a board with project-specific Track and Phase
values while sharing the cross-project planning vocabulary studio agents
depend on.

### Board ownership

| Decision | Rule |
|---|---|
| One board per project | Each studio-managed project owns its own Projects v2 board. The studio's own board does not host other projects' work. |
| Owner scope | A project board may live under any GitHub owner the project repo links to: a user account (`/users/<user>/projects/<n>`) or an organization (`/orgs/<org>/projects/<n>`). Studio scripts MUST NOT assume the user-owner case. |
| Repository link | A project board MUST be linked to the project's primary GitHub repository so issues from that repo appear on the board without manual addition. Additional linked repos are allowed. |
| Studio board scope | The `Studio v2 transition` board is the `generic-dev-studio` project's board. It MUST NOT be used to track another project's work. |

### Portable field contract

Project boards share a core vocabulary; project-specific value sets are
allowed only on `Track` and `Phase`.

| Field | Cross-project rule |
|---|---|
| `Status` | Required. Values fixed to `Todo`, `In Progress`, `Done`. Studio readers compare lanes by these exact strings. |
| `Size` | Required. Values fixed to `XS`, `S`, `M`, `L`, `XL`. |
| `Sibling host reviewed` | Required. Values fixed to `Not required`, `Plan clean`, `Outcome clean`, `Needs review`. The phase-review wrappers depend on these exact strings. |
| `Track` | Required. Each project supplies its own option set. The studio board's track values (`A substrate`, `B PM surface`, …) are one such set; a turnip board may use Turnip-specific tracks. Project scripts MUST NOT assume studio-specific track names. |
| `Phase` | Required. Each project supplies its own option set. Cross-project tooling treats `Phase` as an opaque string scoped by `Track`. |

Additional project-specific fields are allowed and must be additive. They
MUST NOT redefine the meaning of the required fields above.

Built-in fields (`Parent issue`, `Sub-issues progress`, `Repository`,
`Labels`, `Milestone`) remain available on every project board.

### Project board configuration

Each project's board location and field metadata are recorded in a single
`project-board` config block, owned by the project profile:

| Surface | Location | Visibility |
|---|---|---|
| Durable, repo-checked board config | `profiles/<slug>/project-board.yaml` | Public repo |
| Per-machine override or ad-hoc board | `<studio_home>/<project_slug>/config/project-board.yaml` | Private runtime |

The runtime override exists for in-flight migrations and machine-local
experiments. When both surfaces exist, the runtime override wins and studio
readers MUST surface that the override is active.

Required fields in `project-board.yaml`:

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | int | `1` for this contract version. |
| `owner_kind` | enum | `user` or `org`. |
| `owner_login` | string | GitHub login of the project board owner. |
| `project_number` | int | Numeric Projects v2 id (the `<n>` in the URL). |
| `project_title` | string | Human-readable Project title; used only for diagnostics, not for lookup. |
| `linked_repo` | string | `<owner>/<repo>` of the primary repo linked to the board. |
| `tracks` | list[string] | Project-specific allowed values for the `Track` field. |
| `phases` | list[string] | Project-specific allowed values for the `Phase` field. |

`Status`, `Size`, and `Sibling host reviewed` are not configurable; their
values are fixed by this contract.

### Discovery

Studio scripts MUST resolve the project board in this order:

1. Explicit CLI flag, e.g. `--project-board <owner>/<n>`.
2. Environment override `STUDIO_PROJECT_BOARD_OVERRIDE=<owner_kind>:<owner_login>:<n>`.
3. Runtime override at `<studio_home>/<project_slug>/config/project-board.yaml`.
4. Durable config at `profiles/<slug>/project-board.yaml` inside the current `repo_root`.
5. Loud failure: no board configured for this project.

Steps 1 and 2 are user-controlled overrides per the studio bypass policy and
MUST NOT be set silently by an assistant. Step 5 MUST name the missing
config path and the project slug; it MUST NOT silently fall back to the
studio's own board.

`project_slug` resolution follows the
[Studio Context Contract](_shared/contracts/studio-context.md) — usually the
repo toplevel basename, with explicit override permitted.

### Non-goals

- This contract does not migrate any existing project to a new board.
- This contract does not centralize project boards under a single GitHub
  owner. Each project's board owner is recorded per project.
- This contract does not change the cross-project `Status`, `Size`, or
  `Sibling host reviewed` value sets; only `Track` and `Phase` are
  project-defined.

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

## macOS Actions Runner Policy

This policy satisfies `#443` B13 for Studio-internal CI. It applies to
`generic-dev-studio` workflows only; Turnip-iOS build and simulator routing
remain outside this PM-surface policy.

Default to GitHub-hosted runners. Studio workflows should use
`ubuntu-latest` unless the job genuinely needs macOS APIs, Xcode, Keychain,
or Apple tooling. When macOS is required, use standard GitHub-hosted macOS
labels such as `macos-latest` or a pinned supported macOS image; do not add a
self-hosted macOS runner just to conserve minutes.

Keep paid Actions exposure at zero by default. GitHub-hosted runners for
private repositories consume the account's included monthly Actions minutes,
and GitHub documents `2,000` included minutes for GitHub Free plus paid
overage once configured budgets allow it. The studio policy is: do not raise
the Actions budget above `0 USD`, do not enable paid overage, and let
non-urgent Studio CI stop once included minutes are exhausted. Any budget
increase must be explicit, human-approved work.

Self-hosted macOS runners are opt-in infrastructure, not the baseline. Add
one only when a concrete Studio workflow cannot run correctly on
GitHub-hosted macOS, or when repeated monthly exhaustion blocks accepted
Studio work after the workflows have already been trimmed. A self-hosted
runner decision must document owner, machine, labels, secret scope, update
cadence, failure mode when the machine sleeps or disappears, and teardown
steps before registration.

Cost controls for new Studio Actions:

| Rule | Policy |
|---|---|
| Runner choice | Prefer `ubuntu-latest`; use macOS only for macOS-only capability. |
| Budget | Keep Actions budget at `0 USD` unless the user explicitly approves overage. |
| Cron frequency | Use weekly or manual triggers by default; justify anything more frequent. |
| Timeouts | Set job-level timeouts for any non-trivial workflow. |
| Self-hosted macOS | Require a documented decision record before registration. |

References:
[GitHub Actions billing and usage](https://docs.github.com/actions/learn-github-actions/usage-limits-billing-and-administration),
[Actions limits](https://docs.github.com/en/actions/reference/usage-limits-for-self-hosted-runners),
and
[GitHub-hosted runners](https://docs.github.com/en/actions/reference/github-hosted-runners-reference).

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
