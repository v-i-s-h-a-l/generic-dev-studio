# Pi adapter research — 04 Auth, HOME, and environment isolation

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Auth, HOME, and environment isolation under a Pi adapter |
| Task graph node | `T-R004` |
| Source issue | [#927](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/927) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b47-5e8c-701a-a9d1-7a6a95173fd0` |
| Chain | `pi-adapter-research` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/04-auth-home-env.md` |
| Classification | private-runtime (not committed) |

The private artifact verifies how a hypothetical Pi adapter would interact
with Studio's existing auth and isolation contracts — login-HOME
identification, parent-home flip for GitHub, host auth home routing,
provider credentials, reviewer-profile env-scrub, GitHub auth preflight,
subprocess HOME, and the three repo-level lints that defend the boundary.
Each surface is classified as verified-compatible, verified-needs-bridge,
verified-constraint, or defer-to-T-R008. It is research only: no Pi
install, no credentials / env files / auth homes touched, and no adapter
architecture decision; constraints surfaced are forwarded to T-R008.

Downstream research outputs (`05-cross-host-review.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
