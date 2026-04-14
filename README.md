# Generic Dev Studio

A two-agent project management system for Claude Code. Chanakya plans the work, Achilles executes it.

Built for iOS/SwiftUI development but adaptable to any codebase.

## What's Inside

```
chanakya/          # Manager agent skill
  SKILL.md         # Skill definition — task intake, briefing, status, PRD review
  README.md        # Full documentation with 7 examples
  docs.html        # Interactive docs page (open in browser)

achilles/          # Worker agent skill
  SKILL.md         # Skill definition — brief execution, direct mode, self-selection

commands/
  chanakya-help.md # /chanakya-help command — opens docs in browser
```

## Install

### Option 1: Symlink into Claude Code (recommended)

```bash
# Skills
ln -s /path/to/generic-dev-studio/chanakya ~/.claude/skills/chanakya
ln -s /path/to/generic-dev-studio/achilles ~/.claude/skills/achilles

# Help command
ln -s /path/to/generic-dev-studio/commands/chanakya-help.md ~/.claude/commands/chanakya-help.md
```

### Option 2: Copy files

```bash
cp -r chanakya/ ~/.claude/skills/chanakya/
cp -r achilles/ ~/.claude/skills/achilles/
cp commands/chanakya-help.md ~/.claude/commands/
```

### Setup directories

The system needs these directories (created on first use, or manually):

```bash
mkdir -p ~/.claude/plans/chanakya-tasks
mkdir -p ~/.claude/plans/chanakya-inbox/processed
```

## Quick Start

```
/chanakya              # Start planning — describe your tasks
/chanakya status       # See task status and what's next
/chanakya brief T001   # Generate a self-contained worker brief
/chanakya review       # Diff updated PRD against tasks

/achilles T001         # Execute a briefed task
/achilles              # Direct mode — describe any task
```

## How It Works

1. **You describe work** to Chanakya (features, bugs, PRDs, Figma links)
2. **Chanakya organizes** tasks with priorities, assigns skills, writes a master plan
3. **Chanakya generates briefs** with pre-fetched Figma context, codebase references, and acceptance criteria
4. **Achilles picks up briefs** and implements them, asking for feedback along the way
5. **Achilles writes debriefs** with key learnings, commits, and follow-up tasks
6. **Chanakya processes debriefs** and updates the master plan — knowledge compounds

Both agents are proactive — they suggest next steps. You just say "yes", "no", or redirect.

## When to Use What

| Situation | Use |
|-----------|-----|
| New feature with Figma | `/chanakya` to plan, `/achilles` to implement |
| Multi-file refactor | `/chanakya` to plan |
| Bug fix / crash | `/achilles` directly |
| One-file UI tweak | `/achilles` directly |
| PRD changed mid-feature | `/chanakya review` |

## Adapting to Other Projects

The skills reference iOS/SwiftUI-specific tools (Figma MCP, IMGLY engine, etc.). To adapt:

1. **Edit the skill registry** in `chanakya/SKILL.md` — replace the skill table with your project's available skills
2. **Update file paths** — the memory and plans directories point to `~/.claude/` by default
3. **Update Figma references** — if your project doesn't use Figma, remove the MCP calls from brief generation

The core workflow (intake, brief, execute, debrief) is project-agnostic.

## Docs

Open the interactive documentation page:

```
/chanakya-help
```

Or directly: `open chanakya/docs.html`

## License

MIT
