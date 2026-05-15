# Pi adapter research — 07 Current Studio-on-Pi feasibility

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Current Studio-on-Pi feasibility |
| Task graph node | `T-R007` |
| Source issue | [#930](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/930) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b8d-09dc-7a7a-a920-d15b3b173ae8` |
| Chain | `pi-adapter-research-codex-continuation` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/07-current-workflow-feasibility.md` |
| Classification | private-runtime (not committed) |

The private artifact defines the minimal future validation set for running
Studio on Pi: router/status, model-route envelope, checkpoint resume, and
`manager work-chain --dry-run`. It treats full unattended chain execution as
feasible only after Pi proves worker sandboxing, GitHub auth parity, private
runtime writes, worker summary generation, and telemetry-gap mapping. It is
research only: no Pi install, no credentials or Pi state touched, and no adapter
architecture decision.

Downstream research outputs (`08-adapter-boundary-options.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
