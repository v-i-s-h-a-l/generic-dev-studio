---
name: studio
description: "Cross-agent studio router. Handles studio-level operations that span agents or concern the project's own conventions (not the user's iOS project). Tier 1 sub-commands: resume-plan, review, release, ingest. Do NOT use for task-level work — that goes to /chanakya, /achilles, /argus."
type: agent-router
---

# Studio — Router

Studio-level operations for `generic-dev-studio` itself (not the user's project). Invoked when the user wants to act on the *studio's* state: resume an in-flight architecture arc, walk this repo's review rules against a diff, draft release notes for the studio, or ingest something studio-flavored.

Pattern contract: `_shared/patterns/router-pattern.md`. Router <100 lines.

## Not in scope

Task-level work on the user's iOS project (`/chanakya`, `/achilles`, `/argus` own that). Skill-conventions routing for Swift code (`_shared/rules/swift-skill-routing.md` handles it). Per-task verification (Argus). If the user's intent is about *their* project's code, don't dispatch here — route to the agent routers.

## Dispatch table

| Sub-command / invocation | Mode pack |
|---|---|
| `resume-plan` / "where were we" / "pick up from where we left off" | `modes/resume-plan.md` |
| `review` / "review this diff" / "any issues?" / "check this" | `modes/review.md` |
| `release` / "draft release notes" / "what's new" / "should we tag?" | `modes/release.md` |
| `ingest` / "ingest this" / studio-flavored capture outside chanakya's inbox | `modes/ingest.md` |

Tier 2 modes (not shipped today; spawn on demand): `backlog` (gh issue triage), `audit` (architecture audit run), `scaffold` (new mode pack / primitive scaffold).

## Intent detection

Priority order:

1. **Explicit arg** — `/studio resume-plan` → `modes/resume-plan.md`. Always wins.
2. **Conversational switch** — mid-session, if the user pivots ("actually let me see the release notes"), re-dispatch inline.
3. **Default** — no arg, no clear intent → `modes/resume-plan.md`. "What's going on with the studio" is the most common implicit question.

Never prompt for clarification when a sensible default exists.

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
