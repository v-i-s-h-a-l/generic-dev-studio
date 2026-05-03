# Themes

Long-running tracks the studio is invested in. **Themes don't go away — they pause.** Pick 1–2 to actively focus on per season (3 months); others stay backlog. Themes are tagged on issues via `theme/*` labels.

Each theme below has: vision (what it's trying to achieve), current status, and a couple of seed signals (real observations or open questions). Detailed planning happens inside each theme's issues, not here.

## Why these specific themes

Informed by observing how the studio is actually used today — not aspirational categories. Photo-editor iOS project, ~170 tasks completed across modules (Enhance, Filter/Texture, Crop, Text/Sticker, Slider, Infrastructure), heavy parallel-worker use, frequent TestFlight cadence (3000s build numbers), formal external-input blocker tracking, build/test debt counters in active use.

---

## theme/internal — Studio's own quality

**Vision.** The studio gets faster, leaner, smarter every release. Time per task ↓, tokens per task ↓, redundant handshakes ↓.

**Status.** Active focus. Drives the analysis loop (issues #10, #11). Auto-apply tier in CLAUDE.md operates here.

**Seed signals.** Argus rule false-positive rate, brief-template defect patterns, build-debt threshold accuracy, agent session token counts.

## theme/ios-craft

**Vision.** Be the best assistant for Swift/SwiftUI/UIKit work — first-class knowledge of Apple APIs, conventions, idioms, gotchas. Eventually the iOS module other stacks learn from.

**Status.** Implicit today (Swift/SwiftUI routing in `AGENTS.md` / `CLAUDE.md`, xcodebuild gates in worker scripts). Explicit when issue #2 (stack modules) lands.

**Seed signals.** Most active modules (Enhance, Filter/Texture, Crop) → image processing patterns matter; localization activity; accessibility coverage; Apple deprecation signals.

## theme/release

**Vision.** Release pipeline that disappears. From "merged on main" to "available in TestFlight" with no manual steps; from TestFlight to App Store with one command. Symbol uploads, version bumps, branching, hotfix cherry-picks all automated.

**Status.** Partial — `pushTFBuild`, `fullSendToAppStore`, postSlackTesting exist. Gaps around dSYM, hotfix branching, App Store Connect metadata.

**Seed signals.** TF build numbers in 3000s = high cadence; debriefs reference TF often; tf-3136 / tf-3137 exist as ingest sources for feedback.

## theme/integrations

**Vision.** Studio plays well with the tools devs already use: Slack (we have some), Linear/Jira, Crashlytics/Firebase, Sentry, App Store Connect, GitHub Issues, Notion. Each integration is opt-in and self-contained.

**Status.** Slack list-sync + slack-thread feedback ingest are live. Everything else backlog.

**Seed signals.** Feedback pipeline already ingests Slack threads → integration patterns are real and tested. Crashlytics is a likely next step (no current crash-triage workflow visible).

## theme/design

**Vision.** Design → code with high fidelity. Figma assets flow into SwiftUI/UIKit with specs preserved (color tokens, spacing, typography, motion). Manual Figma → code translation goes away.

**Status.** Brief generation pulls Figma context. No design-token sync. No automated asset extraction.

**Seed signals.** "Pranjali waiting on assets" is a recurring blocker (master plan); design-team reporting belongs in the v2 manager role. Designer is an active stakeholder.

## theme/discovery

**Vision.** New MCPs, skills, tools, and Apple announcements get evaluated in context — not on a schedule, but when the studio hits friction that a new tool might solve.

**Status.** Implicit today. Make explicit only when tool-discovery becomes recurring.

**Seed signals.** None tracked yet — first opportunity will likely surface during analysis.

---

## Retained active theme labels

These labels predate the current six-theme taxonomy and still appear on active issues. Retain them until their open issues are intentionally reclassified; do not add them to new issues by default. The GitHub issue templates offer the six canonical themes above plus `needs-triage` for this reason.

| Label | Status | Use on existing issues |
|---|---|---|
| `theme/input` | Retained | PRD, Figma, conversation, and requirements intake work from the older input-pipeline taxonomy. |
| `theme/implement` | Retained | Modularization, flags, and implementation-structure work from the older delivery taxonomy. |
| `theme/observe` | Retained | Crash, telemetry, review, and post-release signal work from the older observability taxonomy. |
| `theme/ship` | Retained | Release-health and rollout-manifest work from the older shipping taxonomy. |
| `theme/meta` | Retained | Process, checklist, and changelog-convention work from the older process taxonomy. |

---

## How themes interact with issues

- Every open issue gets one dominant `theme/*` label.
- One issue can address multiple themes, but that is rare; keep the first label in issue prose and comments as the dominant theme when humans need to disambiguate.
- Theme labels describe long-running investment areas. Work-type labels such as `enhancement`, `bug`, `documentation`, `polish`, `roadmap`, and `phase-2` describe the shape or timing of the work.
- Track labels (`track:*`) identify parallel work lanes or active arcs. They are documented in `TRACKS.md`.
- Chain labels (`chain/*`) identify automated runner chains and are operational, not thematic.
- Status labels such as `urgent`, `blocked`, `parking-lot`, `pilot`, `duplicate`, `question`, and `wontfix` describe workflow state or handling.

## How themes evolve

- New theme: only when ≥3 issues fit into a category that doesn't exist. Don't pre-create themes.
- Retire theme: when status is "complete" or it stopped being a real track. Move issues to closest active theme.
- Rename theme: free, but keep the label name stable to avoid issue churn.

## Active focus this season

**theme/internal** is the active focus. Drives the analysis loop. Other themes stay open but don't get pushed forward until internal craft work shakes out enough patterns to inform them.
