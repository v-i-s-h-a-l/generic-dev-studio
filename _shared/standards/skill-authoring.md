---
name: Skill Authoring Standard
description: Canonical grammar for SKILL.md files. Treats SKILL.md as a programming language with a defined grammar so models read it the same way across hosts. Authoritative for owned and adapted skills; vendored verbatim skills are exempt by declaration.
type: standard
schema_version: 1
---

# Skill Authoring Standard v1

A SKILL.md file is **not freeform prose**. It is a program loaded into a model's context to govern behavior. Different models read prose differently; soft modals get interpreted as license to skip; "consider" reads as "do," and a missing pre-condition sometimes hides a real fork. This document defines the grammar that closes those gaps.

## What this standard does

Defines the grammar all owned skills MUST conform to, and the linter that enforces it (`scripts/lint-skill-prose.sh`). Provides a scaffold (`scripts/scaffold-skill.sh`) that emits conformant skeletons. Defines a routing-data shape (`routing.yaml`) so invocation rules become data, not host-specific prose.

## What this standard does not do

It does not rewrite vendored skills. Skills sourced verbatim from upstream authors keep their author's voice; declare them `authoring_standard: exempt` in `vendor.yaml`. It does not govern doc-only files (`README.md`, `INSTALL.md`).

## Inputs

A SKILL.md author. The linter and scaffold consume this standard as data.

## Outputs

Conformant `SKILL.md` files; a `routing.yaml` per skill; an optional `portability.yaml` per skill. Linter exit codes drive CI gates.

## When to invoke

Every time a new skill is authored, every time an existing owned skill is edited, every CI run. Vendored skills validate `vendor.yaml` only; their SKILL.md is not linted against this grammar.

---

## Skill kinds

The frontmatter `type` field discriminates four shapes. Each has different conformance requirements.

| Type | Examples | Body shape |
|---|---|---|
| `agent-router` | `core/v2/skills/dev-studio/SKILL.md`, owned router skills | Dispatch table + intent-detection rules. No procedures. |
| `mode-pack` | Historical fixtures under `tests/mode-packs/`; active role procedures live under `core/v2/roles/` | Numbered procedures with sentinel verbs, pre/post, failure-modes. |
| `skill` | Owned standalone skills (e.g. `skills/owned/<name>/SKILL.md`) | Same as mode-pack, plus the affordance header. |
| `primitive` / `reference` / `standard` | `_shared/primitives/*.md`, `_shared/standards/*.md` | Reference content. Looser; only frontmatter is enforced. |

Vendored skills declare `type: skill` AND `authoring_standard: exempt` so the linter validates frontmatter only.

---

## Required frontmatter

Every skill (`type ∈ {agent-router, mode-pack, skill}`) MUST declare:

```yaml
---
name: <kebab-case-identifier>           # required; matches dir name
description: <one sentence ≤ 280 chars> # required; surfaces in routing
type: <agent-router|mode-pack|skill>    # required
schema_version: 1                       # required; integer; bumps on breaking grammar change
---
```

Optional:

```yaml
version: <semver>            # skill version; independent of schema_version
budget_tokens: <int>         # advisory model budget for sessions invoking this skill
authoring_standard: exempt   # vendored only; bypasses body lints
transition_notes: <path>     # link to migration notes during transitions
```

Frontmatter validates against `_shared/standards/skill-frontmatter.json`.

---

## Required body sections (for `type: skill`)

Every owned standalone skill MUST include these H2 sections in this order:

```
## What this skill does
## What this skill does not do
## Inputs
## Outputs
## When to invoke
## Procedure
## Failure modes
```

`agent-router` and `mode-pack` follow their own conventions (router-pattern.md and the mode-pack template) and need only the affordance header keys *if* they are user-facing standalone skills.

---

## Procedure grammar

Every action step in `## Procedure` blocks MUST follow:

1. **Imperative verb first.** "READ the brief at `<path>`", "EMIT `task_dispatched` with task-id". Never "We should read…", "It may be useful to…", "Consider emitting…".
2. **Sentinel-vocabulary verb at the start of the step.** Sentinel set: `READ`, `WRITE`, `RUN`, `CHECK`, `EMIT`, `RECORD`, `STOP`, `PROCEED`, `RETRY`, `SKIP`, `ESCALATE`, `BLOCK`. No synonyms (`output`, `dump`, `note`, `bail`). See `_shared/standards/sentinel-vocabulary.md`.
3. **Pre/post conditions** declared inline:
   - `Before:` — what must hold to enter the step.
   - `After:` — what is true on exit.
4. **No nested if/then prose.** Branching uses **decision tables**, not paragraphs.
5. **No implicit context.** Every noun is explicit. Write "the brief at `<plans/briefs/T347.yaml>`", not "the brief".
6. **No soft modals** (`should`, `may`, `might`, `consider`, `perhaps`, `try to`, `if possible`) inside numbered steps. Soft modals are linter blocks.

### Step shape

```
1. **READ** `<path>`.
   Before: <invariant>
   After:  <invariant>

2. **CHECK** <condition>.
   Decision:
   | Case | Action |
   |---|---|
   | <case-A> | PROCEED to step 3 |
   | <case-B> | SKIP to step 7 |
   | <case-C> | ESCALATE to <agent> |

3. ...
```

### Failure modes

Every `## Procedure` ends with a `## Failure modes` block:

```
| Failure | Classification | Action |
|---|---|---|
| <observable error>     | transient   | RETRY once after <backoff> |
| <observable error>     | permanent   | BLOCK with <message>; emit <event> |
| <observable error>     | ambiguous   | ESCALATE to user; capture context in <path> |
```

`Classification ∈ {transient, permanent, ambiguous}`. No "handle gracefully," no "fail safely." If the failure mode is not classified, the step MUST NOT ship.

---

## Routing as data

Skill invocation rules (slash commands, trigger phrases, domain tags) live in `routing.yaml` next to `SKILL.md`, NOT in CLAUDE.md prose:

```yaml
schema_version: 1
name: <skill-name>
invocation:
  slash_command: "/<name>"          # optional
  triggers:                         # natural-language phrases that fire it
    - "writing or reviewing SwiftUI views"
    - "/swiftui-expert"
domains: [swift, swiftui]           # tag-based loading; matched against project .skill-domains
```

`scripts/generate-routing.sh <host>` reads every `routing.yaml` in the skill graph plus `hosts/registry.yaml` and emits the host-native routing block (CLAUDE.md fragment, AGENTS.md fragment, GEMINI.md fragment). One source of truth → N host outputs.

`routing.yaml` validates against `_shared/standards/routing.json`.

---

## Portability declaration

A skill declares which hosts it runs on via `portability.yaml`:

```yaml
schema_version: 1
hosts: [claude-code, codex]         # required; non-empty; use [all] for every registered host
incompatible:                       # optional; rationale per host explicitly excluded
  gemini: "uses Claude-Agent-tool spawn primitive"
```

Default for unmigrated skills (no `portability.yaml`): `hosts: [claude-code]`. New-host fan-out won't silently include a skill that hasn't been verified portable.

`portability.yaml` validates against `_shared/standards/portability.json`. Hosts must match `hosts/registry.yaml` rows, except the literal `all` wildcard that targets every registered host.

---

## Tool-dialect neutrality

Skill bodies use neutral verbs (`READ`, `WRITE`, `RUN`). Host-specific tool names (`Read tool`, `Edit tool`, `Bash tool`, `Agent tool`) live in `_shared/tool-dialect/<host>.md` maps and never appear in skill prose. The existing `scripts/lint-host-agnostic.sh` already greps for these in `achilles/`, `argus/`, `_shared/`; this standard extends the discipline to all owned skills.

---

## Linter codes

`scripts/lint-skill-prose.sh` emits findings as `<CODE>:<file>[:<line>]:<detail>`. Codes:

| Code | Meaning | Severity |
|---|---|---|
| `E_MISSING_FRONTMATTER` | No frontmatter found | block |
| `E_MISSING_REQUIRED_KEY` | name / description / type / schema_version missing | block |
| `E_BAD_TYPE` | type not in allowed set | block |
| `E_DESCRIPTION_TOO_LONG` | description > 280 chars | block |
| `E_MISSING_AFFORDANCE_HEADER` | type=skill missing one of the required H2s | block |
| `E_SOFT_MODAL_IN_PROCEDURE` | soft modal inside a numbered step | block |
| `E_MISSING_SENTINEL` | step does not start with a sentinel verb | block |
| `E_MISSING_PRE_POST` | step missing Before:/After: lines | block |
| `E_MISSING_FAILURE_MODES` | procedure has no Failure modes block | block |
| `E_BAD_FAILURE_CLASSIFICATION` | Classification column not in {transient,permanent,ambiguous} | block |
| `E_IMPLICIT_NOUN` | bare "the brief", "the task", "the file" with no path | block |
| `E_INVALID_ROUTING` | routing.yaml fails schema | block |
| `E_INVALID_PORTABILITY` | portability.yaml fails schema or unknown host | block |
| `W_LONG_DESCRIPTION` | description 200–280 chars | warn |
| `W_LONG_PROCEDURE` | procedure > 30 numbered steps | warn |
| `W_NO_PORTABILITY_YAML` | owned skill missing portability.yaml | warn |

`E_*` exits non-zero (CI block). `W_*` prints to stderr.

---

## Migration semantics

- Existing v1 owned skills were deleted by A10; active owned routers live under `core/v2/skills/`.
- New owned skills MUST conform from day one — `scripts/scaffold-skill.sh` emits a conformant skeleton.
- Vendored skills declare `authoring_standard: exempt` in their `vendor.yaml`; the linter validates frontmatter only and skips the body grammar checks.

## Schema versioning

`schema_version: 1` is the current grammar. Breaking changes (e.g. new required H2 section, new mandatory frontmatter key) bump to `schema_version: 2`; the linter accepts both for one transition window, then drops support for the older version after every owned skill has been migrated.

## See also

- `_shared/standards/sentinel-vocabulary.md` — authoritative sentinel set.
- `_shared/standards/skill-frontmatter.json` — JSON Schema for frontmatter.
- `_shared/standards/routing.json` — JSON Schema for routing.yaml.
- `_shared/standards/portability.json` — JSON Schema for portability.yaml.
- `_shared/patterns/router-pattern.md` — router-skill conventions.
- `scripts/scaffold-skill.sh` — generator.
- `scripts/lint-skill-prose.sh` — linter.
- `scripts/generate-routing.sh` — per-host routing fragment generator.
- `REVIEW.md` R18 — CI rule that runs the linter on every SKILL.md change.
