---
name: Skill Routing Instructions
description: Host-neutral routing rules injected into each AI provider's global instructions file by sync-host-skills.sh. Single source of truth for "when to use which skill".
type: reference
---

# Skill Conventions

When writing, reviewing, or refactoring **SwiftUI views** → use the `swiftui-pro` and `swiftui-view-refactor` skills
When auditing **SwiftUI performance** (scroll jank, hitches, excessive updates) → use the `swiftui-performance-audit` skill. For Instruments `.trace` file analysis, use `swiftui-pro` (bundles trace-recording + analysis)
When adopting **iOS 26+ Liquid Glass** → use the `swiftui-liquid-glass` skill
When writing or reviewing **Swift concurrency** (async/await, actors, Sendable) → use the `swift-concurrency-pro` skill
When writing or reviewing **Swift Testing** (`@Test`, `#expect`, test plans) → use the `swift-testing-pro` skill
When designing or reviewing **Swift APIs** (protocols, naming, argument labels) → use the `swift-api-design-guidelines-skill` skill
When planning module or package architecture → use the `swift-architecture-skill` skill
When reading, writing, reviewing, or debugging **IMGLY / CE.SDK engine** code (blocks, scenes, events, scopes, undo/redo, export, collage editor) → use the `imgly-engine-expert` skill
