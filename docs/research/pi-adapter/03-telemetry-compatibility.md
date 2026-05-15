# Pi adapter research — 03 Telemetry compatibility and optionalization

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Telemetry compatibility and optionalization under a Pi adapter |
| Task graph node | `T-R003` |
| Source issue | [#926](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/926) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b47-5e8c-701a-a9d1-7a6a95173fd0` |
| Chain | `pi-adapter-research` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/03-telemetry-compatibility.md` |
| Classification | private-runtime (not committed) |

The private artifact inventories Studio's layered telemetry surfaces
(chain-run private events, state projection, worker summary envelope, worker
telemetry sidecar, shared cross-agent event log, checkpoint telemetry,
startup diagnostics, aggregate digest, public-comment allowlist) and
classifies each surface plus the relevant Pi-side records as `core`,
`bridge`, `optional-under-pi`, `replaceable-after-parity`, `defer`, or
`unknown`. It is research only: no Pi install, no credentials touched, and
no adapter architecture decision; the only optionalizations recommended are
Pi-side outbound pings that Studio does not consume.

Downstream research outputs (`04-auth-home-env.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
