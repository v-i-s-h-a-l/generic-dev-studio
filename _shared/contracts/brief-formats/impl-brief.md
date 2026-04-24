# Shared: Implementation Brief Format

Write to `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md`:

```markdown
# Task Brief: <task-id> — <Title>

**Generated:** <YYYY-MM-DD HH:mm IST>
**Master plan:** ~/.dev-studio/<project>/plans/chanakya-master.md

---

## Objective

<Clear description of what to build/fix and why>

## Priority & Complexity

- **Priority:** P0
- **Complexity:** L
- **Size:** XS | S | M | L   <!-- drives Achilles' Step 6 gate: XS/S → lsp-only, M/L → full-green -->

## Churn Layer

- **`churn_layer`:** core | adapter | ui | exploratory   <!-- see `_shared/rules/test-strategy.md`; drives which test brief spawns and what Argus expects -->

## Branch

- **Base:** `<base-branch>`
- **Branch name:** `achilles/<task-id>`

## Skills to Invoke

Before starting, load these skills for guidance:
- `/figma-to-swiftui` — for translating Figma designs
- `/swiftui-pro` — for SwiftUI best practices

## Figma Context

### <Component Name> (node `<nodeId>`)

<Inlined design specs: dimensions, colors, fonts, spacing, layout structure>
<Screenshot path if captured>
<Design tokens if fetched>

## Codebase Context

### Files to Modify
- `path/to/file.swift` — <what to change>

### Files to Read (for context)
- `path/to/related.swift` — <why it's relevant>

### Patterns to Follow
- <Reference to similar existing feature with file path>

### Architectural Constraints
- <Inlined from project memory — e.g., "uses @Observable not ObservableObject", "image loading via Kingfisher">

## Testability Requirements

### Architecture & SOLID
- Follow the project's existing architecture pattern: <pattern name> (reference: `<path to exemplar file>`)
- Single responsibility: each new type should have one clear reason to change
- Depend on protocols for external dependencies (network, persistence, sensors) — inject via initializer
- <Specific architectural constraint for this task>

### Accessibility Identifiers
- Define identifiers in: `<path to identifier enum file, existing or new>`
- Use nested enums per screen/component: `enum AccessibilityID { enum <Screen> { static let <element> = "<module>.<screen>.<element>" } }`
- Apply identifiers in views via `.accessibilityIdentifier(AccessibilityID.<Screen>.<element>)`

### Localization
<!-- Only populate if the task introduces or modifies user-visible strings -->
- Use `"keyName".localized` for every user-visible string. No hardcoded string literals in views.
- Key naming: camelCase with a feature prefix — e.g., `filterPresetsEmpty`.
- New keys must be added to all three `.lproj` folders: `en.lproj`, `hi.lproj`, `uk.lproj`.
- Format strings: `{placeholder}` tokens + `.replacingOccurrences(of:with:)`.
- See `~/.claude/skills/_shared/rules/localization-rules.md` for full rules.

### Test Seams
- <Protocol/interface to expose for testing>
- <Dependency to make injectable via initializer>

### Related Test Tasks
- Unit tests: `<task-id-a>`
- Integration tests: `<task-id-b>` (if applicable)
- UI tests: `<task-id-c>`

## Acceptance Criteria

1. <Specific, testable criterion>
2. <Another criterion>
3. Accessibility identifiers defined for all interactive elements
4. Dependencies injected via protocols where specified in Test Seams
5. All user-visible strings use `"keyName".localized` — no hardcoded literals, new keys in all three `.lproj` files

## Out of Scope

- <Explicit boundaries>
- Writing tests (handled by sub-tasks <task-id-a>, <task-id-b>, <task-id-c>)

---

## Debrief Instructions

Write debrief to `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`.
Format: see `~/.claude/skills/_shared/contracts/debrief-format.md`.
Then update master plan: status → `done`, record commit hashes.
```
