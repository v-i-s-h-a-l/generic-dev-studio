# Pi adapter research — 02 Dynamic model-role execution

Repo-tracked pointer to a private Studio analysis artifact. The full research
content lives outside this repo by design (`CLAUDE.md` §"Analysis sessions and
privacy"); this file exists so the arc is discoverable from the working tree
and so future readers can trace which run produced the artifact.

| Field | Value |
|---|---|
| Title | Dynamic model-role execution under a Pi adapter |
| Task graph node | `T-R002` |
| Source issue | [#925](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/925) |
| Parent research charter | [#923](https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/923) |
| Date (UTC) | 2026-05-15 |
| Run UUID | `019e2b47-5e8c-701a-a9d1-7a6a95173fd0` |
| Chain | `pi-adapter-research` |
| Private artifact path | `~/.dev-studio/generic-dev-studio/analysis/pi-adapter-research/02-model-routing.md` |
| Classification | private-runtime (not committed) |

The private artifact evaluates how Studio's model-role policy
(`ARCHITECTURE.md` §"Model-role policy") could be executed by Pi as one
host adapter — covering provider/model/thinking-level translation, fallback
shapes, concurrency hazards under `~/.pi/agent/`, and three candidate
adapter shapes — without implementing a resolver or choosing final model
names. It is research only: no Pi install, no credentials touched, and no
adapter architecture decision.

Downstream research outputs (`03-telemetry-compatibility.md` through
`10-final-synthesis.md`) follow the same private-artifact + repo-pointer
pattern when they ship.
