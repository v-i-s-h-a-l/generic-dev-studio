# Ideas

Capture file for ideas that surface in conversation. `/capture` appends here retrospectively by scanning the recent session transcript. Promoted to GitHub issues when scoped; archived when shipped or rejected.

**Lifecycle:** `Captured` → `In design` → `Planned (#N)` → `Shipped` or `Archived`.

**Promotion rules:**
- Duplicates are merged into existing entries (see "Dedup" below).
- Items already tracked in `ROADMAP.md` §Phase sequence or open GitHub issues are *not* captured here — they're already preserved.
- Rejected-alternatives already listed in `ARCHITECTURE.md` §Design Vision are *not* captured here.

**Dedup:** `/capture` checks existing entries by keyword + theme overlap before appending. Matches update existing entries with a new date stamp; non-matches create new entries.

---

## Captured

- 2026-04-20 14:23 — Add a short "debrief-only" mode to Achilles (e.g., `/achilles debrief`) — for when the user fixes a bug directly in chat (no Chanakya brief, no worktree, no Argus). After the fix lands, invoke this mode and Achilles generates a Chanakya-format debrief from the conversation/diff. Most such bugs are tiny and skip unit/UI tests; if tests are needed, user tells Achilles explicitly and the debrief reflects that. Purpose: keep the ledger consistent even for ad-hoc direct-to-Claude fixes that bypass the normal brief → worktree → Argus pipeline. [theme/internal]

---

## In design

*(Empty — promoted when an idea becomes an active discussion thread.)*

---

## Planned

*(Empty — each entry links to the GitHub issue that tracks it.)*

---

## Archived

*(Empty — rejected or superseded ideas, one-line reason per entry.)*
