---
name: studio
description: Cross-agent studio router. Handles studio-level operations that span agents or concern the studio repo's own conventions (not the user's iOS project). See routing.yaml for the sub-command surface. Task-level work routes to /chanakya, /achilles, /argus.
type: agent-router
schema_version: 1
---

# Studio — Router

Studio-level operations for `generic-dev-studio` itself (not the user's project). This is a **project-scoped vendor skill** shipped at `.claude/skills/studio/`; it auto-loads when your cwd is in this repo and is silent everywhere else. Invoked when the user wants to act on the studio's state: resume an in-flight architecture arc, walk this repo's review rules against a diff, draft release notes for the studio, ingest something studio-flavored, audit plan-vs-memory drift, or guard against repeated work.

Pattern contract: `_shared/patterns/router-pattern.md`. Router <100 lines.

## Not in scope

Task-level work on the user's iOS project (`/chanakya`, `/achilles`, `/argus` own that). Skill-conventions routing for Swift code (`_shared/rules/swift-skill-routing.md` handles it). Per-task verification (Argus). If the user's intent is about *their* project's code, don't dispatch here — route to the agent routers.

## Dispatch table

| Sub-command / invocation | Mode pack |
|---|---|
| `resume-plan` / "where were we" / "pick up from where we left off" | `modes/resume-plan.md` |
| `review` / "review this diff" / "any issues?" / "check this" | `modes/review.md` |
| `release` / "draft release notes" / "what's new" / "should we tag?" | `modes/release.md` |
| `ingest` / "ingest this" / studio-flavored capture (single input) | `modes/ingest.md` |
| `analyze [<project>]` / "analyze logs and feedback" / "sweep the studio-feedback inbox" / "what patterns are showing up?" | `modes/analyze.md` |
| `help` / `/studio-help` / "show me the docs" / "how does this work?" | `modes/help.md` |
| `audit` / "audit the arc" / "check plan drift" / auto-invoked by SessionStart | `modes/audit.md` |
| `guard <keywords>` / "has this been done?" / "are we repeating work?" | `modes/guard.md` |
| `add <url>` / "add this skill" / "install this skill" / "vendor this" | `modes/add.md` |
| `sync` / "sync skills" / "fan out skills" / "refresh host skills" | `modes/sync.md` |
| `janitor [--yes]` / "clean up the studio" / "what's reclaimable across projects?" / "sweep all projects" | `modes/janitor.md` |
| `nodes` / `nodes status` / `nodes add\|remove\|enable\|disable` / `nodes health` / `nodes sync` / `nodes schedule` / "show the fleet" / "list workers" / "are the workers up?" / "register a worker" / "sync the workers" | `modes/nodes.md` |

| `work <track>` / `STUDIO_TRACK=<track>` auto-start | `modes/work.md` |

Tier 2 modes (not shipped today; spawn on demand): `backlog` (gh issue triage), `scaffold` (new mode pack / primitive scaffold).

**Onboarding a new machine** (manager / worker / dual) is **not** a `/studio` mode. Use `/studio-setup` (or `scripts/bootstrap.sh` directly). The `nodes` mode is day-2 ops only — it never bootstraps a fresh machine.

## Intent detection

Priority order:

1. **Explicit arg** — `/studio resume-plan` → `modes/resume-plan.md`. Always wins.
2. **Conversational switch** — mid-session, if the user pivots ("actually let me see the release notes"), re-dispatch inline.
3. **Default** — no arg, no clear intent → `modes/resume-plan.md`. "What's going on with the studio" is the most common implicit question.

Never prompt for clarification when a sensible default exists.

### Scope guard — feedback / logs / analyze stay studio-only

When the cwd is `generic-dev-studio`, the words **"feedback"**, **"logs"**, **"analyze"**, **"sweep"**, **"patterns"** route to studio modes (`analyze` for sweeps, `ingest` for single inputs). Never silently fall through to `/chanakya`-owned queues at `~/.dev-studio/<project>/feedback/`.

The two queues are disjoint:

| Queue | Path | Owner | Reached via |
|---|---|---|---|
| Studio feedback | `~/.dev-studio/generic-dev-studio/feedback-inbox/<source>/` | studio | `/studio analyze`, SessionStart hook, `scripts/ingest-feedback.sh` |
| Chanakya project feedback | `~/.dev-studio/<project>/feedback/` | chanakya | `/chanakya ingest-*`, `/chanakya feedback-*` (explicit prefix only) |

Chanakya / Achilles / Argus subcommands are **always** invoked with their explicit prefixes (`/chanakya …`, `/achilles …`, `/argus …`). The studio router never dispatches into them, never reads their queues, never resolves "feedback" through them. If a request is ambiguous, surface the disambiguation in one line and ask — do not guess across layers.

## Relationship to existing slash commands

`.claude/commands/resume-plan.md` is a thin slash-command wrapper that is functionally equivalent to `/studio resume-plan`. Both invoke `modes/resume-plan.md`'s procedure. Slash commands are the user-typed surface; the studio router is the programmatic / skill-invocable surface.

Do not duplicate procedure between the slash command and the mode pack. The mode pack is authoritative; the slash command can forward to it (see F5 CLAUDE.md conventions).

## Singleton

Not singleton. Studio operations are inherently single-session (user is driving), and the modes don't mutate any runtime state that would collide. No lock needed.

## No agent-boot hook

Studio modes are conversational aids, not fleet workers. They don't emit `agent_boot` or `agent_session_completed` events. If a mode needs telemetry (e.g. release mode wants to log what tags got drafted), it emits a scoped studio event through the normal `scripts/emit-event.sh` pathway.

## Forward-compat

Adding a Tier 2 mode: one file under `modes/`, one dispatch row, one fixture at `tests/mode-packs/studio/<mode>.yaml`. Same rule as every other router in this repo.

Removing / renaming a mode is a user-visible surface change — ask-tier per CLAUDE.md.
