---
name: imgly-engine-expert
description: Expert guidance for IMGLY CE.SDK engine work across Swift projects, including block management, selection, scopes, undo/redo, events, export, and editor patterns.
type: skill
schema_version: 1
version: 1.0.0
---

# imgly-engine-expert

Use this skill for work that touches IMG.LY Creative Editor SDK (CE.SDK), especially Swift or SwiftUI code that drives engine blocks, scenes, scopes, events, gestures, undo/redo, export, or collage/template editing.

## What this skill does

Guides implementation, debugging, and review of IMGLY CE.SDK engine integrations. It provides SDK-level invariants and a host-neutral workflow that any project can combine with its own private playbook.

## What this skill does not do

It does not replace current SDK documentation, project code inspection, or evidence from a running app. It does not publish project-private file maps, symbols, feature names, or architecture notes. It does not alter Apollo's performance evidence gate; Apollo measures and this skill owns IMGLY-specific recommendations.

## Inputs

- A user request involving IMGLY, CE.SDK, collage editing, template editing, stickers, frames, text blocks, image placeholders, selection, scopes, undo/redo, event observation, gestures, export, or performance handoff from Apollo.
- Project-local code paths, symbols, diffs, logs, traces, or recommendation envelopes when available.
- Optional SDK documentation from `imgly_docs.search` and `imgly_docs.fetch` when the current host exposes those MCP functions.

## Outputs

- Implementation guidance or code changes grounded in local project code and CE.SDK behavior.
- Review findings for IMGLY-related diffs, including block lifecycle, selection, scope, event, undo/redo, and export risks.
- Apollo handoff responses in the `expert_to_apollo` envelope when invoked from Apollo.
- A clear blocked state when SDK docs or local project context are required but unavailable.

## When to invoke

Invoke for reading, writing, reviewing, or debugging code that touches the IMGLY engine, CE.SDK scene graph, collage editor, template editor, stickers, frames, text blocks, image placeholders, undo/redo, block selection, bottom actions menu, export, or raw Metal work delegated through an IMGLY performance contract.

## Procedure

1. **READ** the user's request and any supplied code paths, diffs, logs, traces, or handoff envelope.
   Before: the invocation includes an IMGLY, CE.SDK, collage-editor, or Apollo-to-expert context.
   After: the requested outcome and available evidence are identified.

2. **CHECK** whether the host exposes `imgly_docs.search` and `imgly_docs.fetch`.
   Before: the requested outcome is identified.
   After: SDK documentation availability is known.

   Decision:
   | Case | Action |
   |---|---|
   | documentation functions are available | RUN targeted CE.SDK documentation lookups before making SDK-level claims |
   | documentation functions are unavailable | RECORD that live IMGLY documentation was unavailable and rely on local code, known contracts, and explicit uncertainty |

3. **READ** local project code for the touched files, symbols, and nearby engine wrapper boundaries.
   Before: project paths or symbols are available from the user request, diff, search results, or handoff envelope.
   After: local architecture, naming, ownership, and lifecycle patterns are known.

4. **CHECK** whether the local project provides a private IMGLY playbook or recognizable editor architecture.
   Before: local project code has been read.
   After: the applicability of local project-specific guidance is known.

   Decision:
   | Case | Action |
   |---|---|
   | private playbook or project-local skill is present | READ that local guidance, then PROCEED with CE.SDK invariants and local code |
   | private playbook is absent | PROCEED with CE.SDK invariants and local code; RECORD that project-specific guidance was unavailable |
   | local code is unavailable | BLOCK with `E_NO_LOCAL_IMGLY_CONTEXT` unless the user only requested general conceptual guidance |

5. **CHECK** block lifecycle and classification logic before changing UI state or behavior.
   Before: local engine wrapper code is loaded.
   After: block kinds, metadata, tracking arrays, parent/child relationships, and dynamic categorization paths are identified.

6. **CHECK** selection, scope, event, and undo/redo interactions for the proposed change.
   Before: block lifecycle logic is identified.
   After: side effects on selection state, scroll state, event subscriptions, frame caches, undo stacks, and scope flags are known.

7. **WRITE** the smallest implementation, review finding, or recommendation that preserves the local engine architecture.
   Before: SDK constraints and local lifecycle side effects are known.
   After: the user receives a project-grounded answer, patch, or handoff response.

8. **CHECK** verification coverage for the changed or recommended behavior.
   Before: the answer, patch, or handoff response exists.
   After: compile, unit, UI, trace, or manual verification requirements are explicit.

9. **STOP**.
   Before: verification requirements are explicit.
   After: no further IMGLY action runs without new user input.

## Failure modes

| Failure | Classification | Action |
|---|---|---|
| IMGLY documentation functions are unavailable | ambiguous | RECORD the gap; continue only from local code and known contracts |
| local IMGLY code is unavailable for a project-specific change | permanent | BLOCK with `E_NO_LOCAL_IMGLY_CONTEXT` and request the relevant files or paths |
| Apollo handoff envelope is missing required fields | permanent | BLOCK with `E_BAD_APOLLO_HANDOFF`; name the missing fields |
| CE.SDK behavior conflicts with local project assumptions | ambiguous | ESCALATE with both sources of evidence and the unresolved decision |
| verification cannot run in the current environment | ambiguous | RECORD the unrun verification and list the exact command, trace, or manual scenario required |

## CE.SDK lookup policy

When the current host exposes `imgly_docs.search` and `imgly_docs.fetch`, run focused searches for SDK APIs before asserting details about engine calls, block APIs, scene loading, export behavior, event observation, or platform-specific constraints. When those functions are unavailable, state that live IMGLY docs were not consulted and ground the answer in local code plus known contracts.

## Reference

Keep project-specific playbooks outside the public studio repo. A host or project can provide private local guidance with proprietary file maps, symbols, feature names, and app-specific engine contracts; this global skill consumes that guidance when available and otherwise stays generic.
