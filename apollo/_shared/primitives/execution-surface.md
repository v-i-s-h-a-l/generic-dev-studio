---
name: Execution surface primitive
description: Tools Apollo can autonomously invoke (XcodeBuildMCP, AXe, XCResultKit, xctrace, Meter, ASC client) vs human-required actions. Encodes auto-capture-before-refuse as a decision tree.
type: reference
schema_version: 1
---

# Execution surface (what Apollo can run unattended)

Apollo's evidence requirements (`apollo/_shared/primitives/evidence-gate.md`) demand artifacts. The execution surface is the inventory of pathways through which Apollo produces those artifacts without a human in the loop. Each entry names the tool, the capability it grants, the cost in real-world terms, and the failure modes Apollo must handle when the tool is unavailable.

A capability is autonomously executable only when (a) the tool is installed, (b) auth is configured, and (c) the action stays inside the session budget (default 15 min, settable per mode). Anything outside those bounds is either auto-capture-deferred (Apollo schedules it and refuses for now) or human-required (Apollo refuses and names the human action).

## Capability matrix

| Tool | Capability | Autonomy | Cost |
|---|---|---|---|
| **XcodeBuildMCP** | `xcodebuild` build / test / archive on simulator + device | full | seconds–minutes per build |
| **XcodeBuildMCP** | simulator boot / shutdown / state inspection | full | seconds |
| **XcodeBuildMCP** | XCTest execution with `xcresult` capture | full | minutes per suite |
| **AXe** (cameroncooke MCP) | UI automation on simulator (tap, swipe, scroll, type) | full | per-step seconds |
| **AXe** | UI automation on real device | full when paired | per-step seconds; flake-prone |
| **AXe** | screen recording for trace anchoring | full | per-window |
| **XCResultKit** (AvdLee) | parse `.xcresult` → metrics, attachments, logs | full | seconds |
| **xctrace** (shell) | Instruments trace recording on simulator + device | full | per `--time-limit` |
| **xctrace** | trace export to XML by schema | full | seconds |
| **ChimeHQ/Meter** | MetricKit payload parse + symbolication | full | seconds (assuming dSYM available) |
| **ASC API client** | Performance / Power Metrics fetch | full when key configured | seconds; rate-limited |
| **ASC API client** | Analytics Reports fetch | full when access provisioned | minutes |
| Configuration profile install for `os_signpost` streaming | — | human-required | manual |
| App Store Connect dSYM upload | — | human-required | manual |
| TestFlight build distribution | — | human-required | manual |
| Real-device thermal-controlled run | — | human-required | manual; no automation surface |

The matrix is intentionally narrow. Tools not listed are not in Apollo's autonomous set even if they exist — adding one requires a primitive update, not an inline opt-in.

## Tool detail

### XcodeBuildMCP

`xcodebuild`-backed MCP server (cameroncooke/xcodemake-mcp / xcodebuild-mcp). Provides:

- `build`, `test`, `archive` against an Xcode project or workspace
- simulator lifecycle: list, boot, shutdown, erase, install, launch
- destination resolution from a logical name (`iPhone 16 Pro / iOS 19.0`)
- `.xcresult` path returned per run

Apollo invokes for: cold-launch baseline runs, scenario-driven XCTest captures, Allocations / Time Profiler traces against a simulated build. Failure modes: simulator pool exhaustion (transient — wait and retry once); destination unavailable (permanent — refuse, name the missing simulator).

### AXe (UI automation MCP)

`cameroncooke/axe` MCP. Drives a simulator or paired device through accessibility identifiers. Provides:

- element queries by accessibility id, label, type
- gesture primitives: tap, double-tap, long-press, swipe, scroll, pinch
- text input with software keyboard
- screenshot + screen recording

Apollo invokes for: scripting the scenario that brackets a trace recording. The scenario MUST start and end with a signpost emit so the captured trace has stable anchors. Failure modes: accessibility id missing (permanent — refuse, name the missing id); element not hittable (transient — single retry then refuse).

### XCResultKit

AvdLee/XCResultKit Swift package. Parses the `.xcresult` bundle directly:

- `ActionTestSummaryGroup` traversal
- `performanceMetrics` extraction (matches `apollo/_shared/primitives/xctest-baselines.md` schema)
- attachment extraction (logs, screenshots, signpost data)
- diagnostic payload extraction when present

Apollo invokes after every XcodeBuildMCP test run. Failure modes: `.xcresult` schema drift on new Xcode majors (permanent until package update — refuse with named version mismatch).

### xctrace (shell)

Apple-shipped binary (`/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace`). The non-interactive Instruments surface:

- `xctrace record --template ... --output ...` — record a trace
- `xctrace export --input ... --xpath ...` — export by schema
- `xctrace list templates` — discover installed templates
- `xctrace list devices` — discover device UDIDs

Apollo invokes for every Instruments-template capture. Failure modes: device not paired (permanent — refuse, name pairing); template requires permission profile not installed (permanent — refuse, name the profile, route to human).

### ChimeHQ/Meter

ChimeHQ/Meter Swift package. MetricKit-side utilities:

- `MXCallStackTree` parser (the on-disk shape Apple ships)
- symbolication via local dSYM lookup
- payload comparison helpers for build-to-build diffing

Apollo invokes after every MetricKit payload persistence step. Failure modes: dSYM not found in the local cache (transient if the build is in Xcode Organizer, permanent otherwise — Apollo prompts the human to download dSYMs from ASC).

### ASC API client

Apollo-internal HTTP client. App Store Connect API key auth:

- JWT generation (ES256, ≤ 20 min expiry)
- Performance / Power Metrics endpoints
- Analytics Reports request + download
- rate-limit-aware backoff (50 req/hr per key for most endpoints)

Failure modes: key revoked (permanent — refuse, name re-issuance); rate limit hit (transient — single backoff, then defer); access not provisioned for Analytics Reports (permanent — refuse, route to human).

## Auto-capture-before-refuse decision tree

When a mode-pack step needs evidence that wasn't supplied, Apollo walks this tree before refusing:

```
1. Does an artifact already exist on disk that satisfies the citation?
   yes → cite it.
   no  → continue.

2. Is there a fully-autonomous capability (matrix row, autonomy=full) that produces it?
   yes → can it complete inside session budget?
         yes → run it, cite the captured artifact.
         no  → schedule deferred capture, refuse for now with capture path named.
   no  → continue.

3. Is there a human-required capability that produces it?
   yes → refuse with the explicit human-action block (refusal protocol in evidence-gate.md).
   no  → refuse with "no capture path exists for this evidence shape" — block the mode.
```

Step 2's session-budget check is the corollary that prevents Apollo from looping on a 10-minute trace inside a 2-minute session. Budgets per mode are declared in mode-pack frontmatter (`session_budget: 900s`).

## Codex host — degraded mode

On a Codex node none of the capture tools are available (no Xcode, no macOS MCP servers). Apollo detects this at boot by reading `host-capabilities.yaml` (below): if all of `xcodebuild_mcp`, `axe_mcp`, and `xctrace` are `installed: false`, Apollo enters **degraded mode**.

**What changes in degraded mode:**

1. The auto-capture-before-refuse decision tree step 2 is skipped entirely. Apollo never attempts to invoke a capture tool.
2. Pre-captured artifacts supplied by the caller via `--evidence <path>` are accepted as hard evidence and flow through the normal strict-9 gate.
3. Session start prints a one-line banner:

   ```
   [apollo] degraded mode — capture unavailable on this host.
   Supply a pre-captured artifact with --evidence <path> or re-dispatch to a claude-code node.
   ```

4. When no artifact is supplied, Apollo refuses immediately using the standard refusal block from `evidence-gate.md`, with `attempted-paths: [none — capture unavailable on Codex]` and an unblock recipe that names how to supply an artifact.

**What stays the same:** evidence interpretation, regression math, fix recommendations (when hard evidence is supplied), the advisory channel, and the strict-9 gate itself.

**Degraded decision tree (replaces step 2 when degraded=true):**

```
1. Does an artifact already exist on disk or was --evidence <path> supplied?
   yes → cite it; continue normally.
   no  → refuse immediately (refusal protocol in evidence-gate.md);
         attempted-paths: [capture unavailable on Codex];
         unblock: supply --evidence <path> or re-dispatch to claude-code node.
```

## Tool installation contract

Apollo's host node (Achilles fleet machine) declares installed tools in `~/.dev-studio/.runtime/host-capabilities.yaml`:

```yaml
host: <machine-id>
tools:
  xcodebuild_mcp:    { installed: true, version: "<x.y.z>" }
  axe_mcp:           { installed: true, version: "<x.y.z>" }
  xcresultkit_swift: { installed: true, version: "<x.y.z>" }
  xctrace:           { installed: true, version: "<xcode-version>" }
  chimehq_meter:     { installed: true, version: "<x.y.z>" }
  asc_api_key:       { installed: true, scopes: ["perfPower", "analyticsReports"] }
```

On a Codex node the file declares all capture tools as `installed: false`:

```yaml
host: <machine-id>
tools:
  xcodebuild_mcp:    { installed: false }
  axe_mcp:           { installed: false }
  xcresultkit_swift: { installed: false }
  xctrace:           { installed: false }
  chimehq_meter:     { installed: false }
  asc_api_key:       { installed: false }
```

Apollo reads this at boot. If `xcodebuild_mcp`, `axe_mcp`, and `xctrace` are all `installed: false`, Apollo enters degraded mode (see §Codex host above).

Apollo reads this file at boot and refuses to dispatch any mode that depends on an `installed: false` capability — refusing fast at boot is preferable to refusing mid-investigation with a partially-captured artifact set.

## Session budget and deferred capture

A mode declares its budget in frontmatter; the orchestrator enforces. When a step would exceed budget, Apollo writes a `capture-deferred.yaml` row at `~/.dev-studio/<project>/apollo/deferred/<id>.yaml`:

```yaml
id: <ulid>
mode: <mode-name>
artifact: <evidence-shape>
recipe: <full xctrace / xcodebuild command>
expected_duration: <seconds>
scheduled_at: <iso8601>
```

A scheduled sweep (Apollo's equivalent of Achilles's brief loop) drains the deferred queue when the host is idle. Mode packs cite the deferred id in their refusal block so the user can see what's pending.

## How Apollo references the execution surface

Mode packs cite the surface in two shapes:

| Shape | Form |
|---|---|
| Captured artifact | "captured `<artifact>` via `<tool>` under scenario `<name>`, cohort `<modelCode>/<osMajor>`" |
| Refused with deferred capture | "deferred capture `<deferred-id>` scheduled; resume with `apollo <mode> --deferred <id>`" |

Both forms preserve the audit trail: every artifact has a tool of origin, every refusal has a path forward.

## Why

The auto-capture-before-refuse corollary only works if Apollo has a bounded, declared set of tools it can call. Without that bound, "capture it yourself" becomes either an infinite shopping list or a silent shell-out — both of which break the strict-9 gate. The matrix in this file is the contract: Apollo captures from these surfaces, declines from those, and the human-required column is the explicit handoff. Every mode pack consults this file before declaring a step's autonomy level.

The `host-capabilities.yaml` declaration is what makes the surface portable across host machines: Apollo on an M2 laptop and Apollo on a Mac mini node may have different installed sets, and refusing fast at boot is the correctness rule that makes that portability safe.

## See also

- `apollo/_shared/primitives/evidence-gate.md` — refusal protocol the tree feeds into
- `apollo/_shared/primitives/instruments-index.md` — `xctrace` recipes by mode
- `apollo/_shared/primitives/xctest-baselines.md` — `.xcresult` extraction shape
- `apollo/_shared/primitives/metrickit.md` — symbolication path consuming dSYMs
- `apollo/_shared/primitives/organizer-asc.md` — ASC API surface this client wraps
- `apollo/_shared/primitives/regression-detection.md` — math run on captured artifacts
- ChimeHQ/Meter — MetricKit symbolication library
- cameroncooke/XcodeBuildMCP, cameroncooke/AXe — execution-surface MCPs
- AvdLee/XCResultKit — `.xcresult` parser
