# Pi adapter research — 05 Cross-host and reviewer independence

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Cross-host coordination and reviewer-profile independence under a Pi adapter |
| Task graph node | `T-R005` |
| Source issue | [#928](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/928) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b47-5e8c-701a-a9d1-7a6a95173fd0` |
| Chain | `pi-adapter-research` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/05-cross-host-review.md` |
| Classification | private-runtime (not committed) |

The private artifact inventories the reviewer-profile contract and the four
wrapper surfaces that own cross-host review — `pr-reviewer-eligibility.sh`,
`phase-review.sh`, `pr-headless-review.sh`, `dispatch-review.sh`, plus the
shared launch primitive `lib-review-host.sh` — and classifies each surface
against a hypothetical Pi adapter as verified-compatible,
verified-needs-bridge, verified-constraint, or defer-to-T-R008. It concludes
that Pi can coordinate independent workers and reviewers without replacing
any wrapper, conditioned on five additive case-arm extensions and one
adapter-boundary decision held back for T-R008. It is research only: no Pi
install, no credentials / env files / auth homes touched, and no adapter
architecture decision; constraints surfaced are forwarded to T-R007
(feasibility) and T-R008 (adapter boundary).

Downstream research outputs (`06-skill-package-distribution.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
