---
name: Release Attempt Lifecycle State Machine
description: States and transitions for a resumable multi-system release operation.
type: reference
---

# Release Attempt Lifecycle

A release attempt models an operation that can touch App Store Connect, git,
GitHub Releases, messaging, release YAML, and release notes. It complements the
build-level release lifecycle by making replacement and resubmission workflows
resumable from an append-only transaction log.

The artifact is `plans/release-attempts/<attempt-id>.yaml`; see
`schemas/release-attempt.md`.

## States

| State | Meaning | Who can enter |
|---|---|---|
| `submitted` | Intent is recorded and at least one submission-side effect may run. | Nabu or release-manager after operator approval. |
| `withdrawn` | The prior build was intentionally withdrawn and all withdrawal side effects are complete or skipped. | Nabu after ASC/git/GitHub/messaging updates land. |
| `resubmitted` | Replacement build submission side effects are complete or skipped. | Nabu after new build metadata and release notes are recorded. |
| `released` | The attempt reached the live terminal outcome. | Nabu or watcher after the replacement or original release is live. |
| `error` | A side effect failed and requires operator action before resume. | Any adapter through the release-attempt ledger helper. |

## Transitions

```
submitted   → withdrawn   : prior build withdrawn before release.
withdrawn   → resubmitted : replacement build submitted.
submitted   → resubmitted : new build submitted when no ASC withdrawal was needed.
submitted   → released    : original submission goes live without replacement.
resubmitted → released    : replacement goes live.
any state   → error       : side effect failed and needs operator action.
error       → submitted   : operator resumes before withdrawal completed.
error       → withdrawn   : operator resumes after withdrawal completed.
error       → resubmitted : operator resumes after replacement submission completed.
```

## Side Effects Per Transition

`submitted → withdrawn` owns withdrawal side effects:

- App Store Connect: withdraw or reject the submitted build when supported.
- Git: preserve an audit anchor, such as a `-WITHDRAWN` tag.
- GitHub Release: keep the release draft, rename it with a withdrawn marker, and
  avoid promoting it to Latest.
- Messaging: update the existing release announcement thread instead of opening
  an unrelated parent announcement.
- Release YAML: set the withdrawn release's lineage fields.

`withdrawn → resubmitted` owns replacement side effects:

- Release YAML: create the replacement release artifact and set `replaces`.
- App Store Connect: record the new ASC build id.
- Git/GitHub Release: create or update the replacement tag and draft release.
- Messaging: post into the existing thread when one exists.
- Release notes: write a new versioned release-copy artifact only when the
  content hash changes; otherwise append `side_effect_skipped`.

`resubmitted → released` owns live-finalization side effects:

- GitHub Release: publish the release and latest pointer according to channel
  policy.
- Release YAML: mark the active release `released`; mark prior live artifacts
  `superseded` only after the replacement is live.
- Messaging: update the thread with the final release URL/state.

## Resume Algorithm

1. Load the attempt artifact by id.
2. If `state: error`, read the last failed transaction and require operator
   acknowledgement before retrying the named side effect.
3. Otherwise, scan `side_effects` in order. The first entry not `complete` or
   `skipped` is the resume point.
4. Before retrying it, append a `resume` transaction with the side-effect key.
5. Re-run only that side effect and later side effects. Completed and skipped
   entries are never replayed unless the operator creates a new attempt.

## Events

Transitions emit `release_attempt_state_changed`. Transaction appends emit
`release_attempt_transaction_appended`. The event `task` field carries the
attempt id.

## Related

- `schemas/release-attempt.md` — persisted attempt shape.
- `state-machines/release-lifecycle.md` — build/channel release artifact
  lifecycle.
- `contracts/release-tf-push.md` — current TestFlight/App Store push contract.
