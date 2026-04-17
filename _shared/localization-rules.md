# Shared: Localization Rules

Apply whenever a task introduces or modifies user-visible strings.

## Implementation (Achilles)

- Use `"keyName".localized` for every user-visible string (`String+Localization.swift`). No hardcoded string literals in views.
- Key naming: camelCase with a feature prefix — e.g., `filterPresetsEmpty`, `filterPresetsSaveTitle`, `cropToolCancelButton`.
- Add every new key to `Localizable.strings` in **all three** `.lproj` folders: `en.lproj`, `hi.lproj`, `uk.lproj`. Use `"TODO: translate"` as placeholder for non-English if translations aren't available.
- Format strings: embed `{placeholder}` tokens in the `.strings` value; replace at call site with `.replacingOccurrences(of: "{placeholder}", with: value)`. Never concatenate localized strings directly.
- Plurals: use separate keyed strings selected by count. No inline ternary (`n == 1 ? … : …`) logic in views.
- All text containers must be flexible-width. Avoid fixed frames on labels — use `.lineLimit(nil)` or flexible layout to accommodate text expansion (~30–50% in some locales).
- Dates, numbers, currencies: use `DateFormatter` / `NumberFormatter`. Never build these manually.
- ⚠️ The `.localized` API has no compile-time safety — a key typo silently returns the key string. Double-check key spelling against `Localizable.strings`.
- If the brief notes the module is currently unlocalized: add strings with `.localized` anyway and file a follow-up localization task in the debrief.

## Self-Review Checklist (Achilles Step 5)

Grep the diff for hardcoded string literals — any `Text("…")` or `Label("…", …)` that doesn't end with `.localized` is a blocker. Verify:
- New keys exist in all three `Localizable.strings` files (`en.lproj`, `hi.lproj`, `uk.lproj`)
- Format strings use `{placeholder}` + `.replacingOccurrences` — no direct string concatenation

## Brief Generation (Chanakya Step 6A)

When the task introduces or modifies user-visible strings, include a `### Localization` section in the brief with:
- Reference to existing localization files or note if module is currently unlocalized
- Key namespace to use (e.g., `filter.presets.*`)
- Any known pluralization requirements
