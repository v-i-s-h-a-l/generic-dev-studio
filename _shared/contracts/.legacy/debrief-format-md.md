---
name: Legacy Debrief Markdown Format
description: Archived pre-Phase 2.6 markdown task-debrief template. Kept only for reading old plans/.legacy-archive artifacts; active writers use debrief.schema.json and schemas/debrief.md.
type: reference
---

# Legacy: Debrief Markdown Format

Archived template for debriefs that previously landed at
`~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`.

Active producers MUST write YAML debriefs to
`~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` per
`_shared/contracts/debrief.schema.json` and `_shared/schemas/debrief.md`.

```markdown
# Debrief: <task-id> - <Title>
Completed: <YYYY-MM-DD HH:mm IST>

## Summary
<2-3 sentences on what was done>

## Commits
- <hash> - <one-line description>

## Files Changed
- <file path> - <what changed>

## Branch
- Worked on: `achilles/<task-id>`
- Merged into: `<ORIG_BRANCH>` (local, --no-ff)
- Merge commit: `<hash>`

## Build Verification
build_gate: lsp-only | full-green
build_debt_override: false

## Testability Report
- **SOLID adherence:** <brief summary>
- **Accessibility IDs defined:** <path to identifier enum file, count of identifiers added>
- **Test seams exposed:** <list of protocols/interfaces created for testing>
- **Architecture pattern followed:** <pattern name, any deviations>
- **Localization:** <status>

## Decisions Made
- <any deviations from the brief and why>

## Test Cases
<copy of <task-id>-tests.md>

## Performance
- <operation>: <timing> on <device/simulator>

## Key Learnings
- <patterns, gotchas, things future sessions should know>

## Known Issues
- <unresolved issue>

## Follow-up Tasks
- <new tasks discovered during implementation>
```
