---
name: Build Message Format
description: Authoritative composition rules for TestFlight and App Store submission Slack posts — three-section shape, crash-fix bare-link bullets, regression handling, TF-only cc and rollover
type: reference
schema_version: 1
---

# Build Message Format

**Status: authoritative** (promoted from informal under #287). `studio-tf-push.sh` Step 7 and the `/pushTFBuild` / `/fullSendToAppStore` wrappers compose against this contract; format-iteration work (Phase 4 of #217) updates this file as the single source of truth. Cross-referenced from `_shared/contracts/release-tf-push.md` Step 7 and Stage C's `slack_drafted` event.

Shared composition rules for the configured TestFlight and App Store release
channels. Both channels use the same three-section shape: `*New*` / `*Fixed*`
/ `*Crash fixes*`. **Skip any section with no bullets.** The goal is
skimmability — the channel is the changelog index; readers want to know what
changed without reading prose.

## Headline

- **TF:** `[iOS] build <NEW_BUILD_NUMBER> is available on TestFlight`. `<!here>` is opt-in via release config and is off by default.
- **Release:** `[iOS] v<VERSION> (build <BUILD>) has been submitted for App Store review` — no `<!here>` on release parent.

For TestFlight, the parent should stay brief: headline, blank line, one short
tester-facing summary of what is ready, then `Details in thread.` The detailed
sections move to the first thread reply when `STUDIO_TF_SLACK_DETAILS_MODE=thread`
(the default).

For App Store, blank line after headline, then sections.

## *New* section

Feature launches. **Collapse sub-improvements into one umbrella bullet** with em-dash-separated highlight phrases — do not itemize every sub-feature as its own bullet. Readers want the headline.

- Good: `• New photo editor tool — AI Enhance, Filters, Textures`
- Bad: three separate bullets for AI Enhance, Filters, Textures when they shipped as one feature.

If a single umbrella bullet needs internal structure (multi-surface launch), use bold sub-labels inline (Slack `*Tab bar*` markdown) — one line, not nested bullets.

## *Fixed* section

Behavioral bug fixes, one line each. Phrase specifically enough that a tester can verify in 10 seconds — exact surface, exact action, exact condition. No implementation detail.

- Good: `• Canvas no longer shrinks when opening photo picker from a collage cell`
- Too plain: `• Improved editor performance` (tester has nowhere to look)
- Too technical: `• Refactored CanvasSizingController during PHPicker presentation` (product can't parse)

**Consolidate co-related minor fixes** into one bullet. **Distinct minor fixes stay short** — when prose adds nothing, the bullet body can be just a `<Slack-thread-link>` / `<GitHub-issue-link>` / `<Crashlytics-link>`. The link carries the meaning.

Backticks for code/flag/param names: `` `useGalleryImage` ``.

## *Crash fixes* section

Bare Crashlytics link per bullet — no behavioral description. Crashes are often not user-reproducible; the link carries the context.

- **TF:** `• <Crashlytics URL>` (just the link)
- **Release:** `• Fixed crash <Crashlytics URL>` or `• Possible fix for crash <Crashlytics URL>` (prefix signals confidence)

Always at the bottom of the body (after *New* and *Fixed*). Detect crash-fix commits from commit-body keywords (`crash`, `Crashlytics`, `EXC_`, `fatal`) or an explicit Crashlytics URL in the commit body. If in doubt, drop into *Fixed*.

## cc-mentions (TF only)

Inline, end of line, parenthesized: `... (cc: <@USER_ID>)`. Scoped per-bullet to the specific person who reported or cares about that item. Do not roll up at top; do not credit for cookie points — the purpose is to let the reporter notice the fix, not signal attribution.

Release messages do **not** carry cc-mentions — audience is broader.

## Rollover line (TF only)

When the build stacks on an earlier TF that hasn't shipped to the App Store, add a trailing bullet outside sections:

```
• includes changes from <PREV_BUILD_NUMBER>
```

Last line of the body. Signals cumulative state without re-listing prior bullets.

## Regression handling

- **TF:** name regressions explicitly under *Fixed* as `• regression bug fix: <thing>`. Testers need to know the net delta from the prior TF build they tested.
- **Release:** **drop regressions resolved within the unreleased TF cycle.** If commit A introduced a bug and commit B fixed it, and both fall within `PREV_TAG..HEAD`, the net user-visible delta is zero — emit nothing for either. Only bullets representing changes users will actually see survive. This is the biggest tone shift from TF to release: release notes describe the delta from the last shipped version, not the dev-cycle churn.

## Section order

`*New*` → `*Fixed*` → `*Crash fixes*` → (TF only) rollover bullet.

## Grouping

When configured grouping is `module`, group the detailed TestFlight thread by
tester-visible product area or module before falling back to the standard
section labels. Use tester language: what changed in UX, UI behavior, flows,
or verification surfaces. Do not expose implementation structure unless it is
the only useful way to test the change.

## Thread replies

- **TF:** first thread reply carries the detailed tester checklist when threaded details are enabled. Group by module when it makes the build easier to test; put important technical notes at the end under `*Technical notes*`, and only when they affect QA/product expectations.
- **Release:** after the parent is sent, post two thread replies in this order:
  1. **App Store "What's New"** with a two-blank-line header `App Store "What's New" submitted with this build:\n\n\n<text>`. Highest-skim-value for product/leadership.
  2. **GitHub lifecycle URL** — while the GitHub release is a draft, post the App Store PR URL. When ASC reaches `READY_FOR_SALE`, replace that reply with the published GitHub release URL.

## Tone

Terse. Informal is fine (past posts use Hinglish); don't over-formalize. Emojis are not part of the bullet format — throwaway asides in threads are ok.
