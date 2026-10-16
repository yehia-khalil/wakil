# Wakil Phase 2a — The Spine

**Status:** draft for review · **Created:** 2026-09-07 · Conforms to
`docs/wakil/north-star.md`

Phase 2 as chartered is seven independent subsystems. This spec covers **2a only** —
the load-bearing architecture, with none of the design language. It produces a grey
window with a text box and a table, and an architecture that 2b, 2c and 2d re-skin and
extend rather than replace.

## 0. Where 2a sits

| Sub-phase | Delivers | Exit |
|---|---|---|
| **2a (this spec)** | Harness, action registry, agent bridge, write gate, context switcher, one crude pane | Typed command runs through the registry; clicking does the same thing and journals identically |
| 2b | The void, the Core (Metal), planes, magnetism, the rail, ⌘P/⌘K, motion | `design-language.md` §1–13 realised; 120fps; project switch < 400ms |
| 2c | DB pane in full (§8), API client pane, terminal pane, session browser | Each fully dual-driven |
| 2d | Push-to-talk, pluggable STT, live transcription | The charter's Phase 2 exit criterion |

**Why this order.** Decision 9 records that dual-drive costs 1.5–2× a plain pane and
*cannot be retrofitted*. Every pane built before the action registry exists is a pane
that gets rebuilt. The Core and the magnetic layout are the reason Swift was chosen,
but they are hard work rather than open questions — they carry effort, not risk.

**Toolchain note.** Xcode is not installed on the build machine; Command Line Tools
provide Swift 6.3.2 and an SDK carrying SwiftUI, AppKit, Metal and Speech. That is
sufficient for 2a, which builds as a SwiftPM executable in a hand-assembled `.app`.
`xcrun metal` is absent, so offline shader compilation, code signing, entitlements and
Instruments profiling are unavailable — all of which 2b needs. **Install Xcode before
2b, not before 2a.**

---

## 1. Scope

**In:**
- A SwiftPM package producing `Wakil.app` (hand-assembled bundle, unsigned, local)
- `AgentHarness` protocol and `ClaudeCodeCLIHarness`, its first implementation
- The action registry and the action journal
- The agent-facing MCP surface, served by Wakil itself
- Pane-state reads for the agent (Invariant 3)
- The write gate (Invariant 7), enforced at two layers
- The org / project / environment switcher, over the Phase 1 context model
- One crude database pane returning real rows through `wakil-db`
- A crude thought thread
- The debug dispatch hook

**Out:** every element of `design-language.md` — the void, the Core, depth planes,
parallax, magnetism, the rail, ⌘P/⌘K, the motion budget, the density toggle. Also
voice, the terminal pane, the editor, git, browser, the session browser, and undo.

2a is deliberately ugly. Styling it is 2b's entire job, and doing any of it here is
what would stop the two from staying separable.

**Exit criterion:** a typed *"fetch the latest reservation from staging"* runs through
the harness, dispatches a registry action, and rows appear in the pane — and performing
the same operation by clicking produces a journal entry differing only in `origin`.

---

## 2. Architecture

### 2.1 The decision this phase turns on

The agent must not call `wakil-db` directly. If it did, the pane would be updated by an
observer watching the transcript — a *reconstruction* of state rather than the state
itself. That is two code paths to pane state, which Invariant 2 forbids outright, and
it leaves deictic reference ("re-run this query") with nothing authoritative to resolve
against.

So **Wakil.app serves its own MCP surface**, and pane-affecting capabilities are
reachable by the agent only through it.

```
Wakil.app
├─ ClaudeCodeCLIHarness ─ spawns one `claude` process per session
│    │
│    └─ --mcp-config names:
│         wakil        → stdio: <app>/Contents/MacOS/Wakil --mcp-shim --socket <path>
│         wakil-pm     → stdio: bundled Phase 1 binary
│         wakil-recall → stdio: bundled Phase 1 binary
│       ...with WAKIL_ORG and WAKIL_PROVIDER set per launch, plus --strict-mcp-config
│
├─ ActionRegistry ── handlers ── MCP client (stdio) ── wakil-ctx · wakil-db · wakil-http
│                                   (bundled Phase 1 binaries; the registry is
│                                    their only caller — the agent never sees them)
└─ Panes — state owned by the registry, written by nothing else
```

`wakil-pm` and `wakil-recall` stay directly available to the agent because they produce
*answers*, not pane state. `wakil-ctx`, `wakil-db` and `wakil-http` are removed from the
agent's configuration entirely.

### 2.2 How Wakil serves MCP: the shim

MCP transports are stdio (the CLI spawns the server) or HTTP/SSE (the CLI connects to
one). Wakil.app is already running, so it cannot be spawned.

An in-app HTTP listener was considered and rejected. It requires hand-rolled HTTP/1.1
in `NWListener`, a TCP port that every local process can reach, and therefore a
per-session bearer token to generate and compare — and it means writing JSON-RPC twice,
over two transports, because the app needs a stdio JSON-RPC *client* regardless in order
to call `wakil-db`.

Instead, **Wakil's own executable runs as a stdio shim**:

- `--mcp-config` names `<app>/Contents/MacOS/Wakil --mcp-shim --socket <path>`.
- That mode is detected from `CommandLine.arguments` **before AppKit initialises**, so
  the shim never opens a window or touches the display server.
- The shim is a dumb pipe. It parses nothing; it copies newline-delimited JSON-RPC
  frames between its stdio and a unix domain socket.
- The socket lives in the app's container at mode `0700`. Filesystem permissions replace
  the bearer token entirely — there is no secret to generate, pass, or compare.
- Each session unlinks its own socket path — before binding, and again when it stops.
  Nothing sweeps `$TMPDIR` for sockets left by *other* runs, and nothing should: the
  path carries a fresh session UUID, so the pre-bind unlink is a formality, and a sweep
  would have to guess which of the paths it found belong to a session that is still
  alive. While 2a runs one session at a time that is more risk than value. The
  consequence, which the acceptance runbook's orphan check is written around, is that a
  socket left by a crash survives until someone deletes it.

One JSON-RPC framing implementation serves both directions, with one set of tests. The
cost is one small extra process per session.

### 2.3 The agent-facing tool surface

The registry **projects directly into the MCP tool list.** Each action becomes its own
tool, carrying its own name and JSON schema; the agent calls `db_run_query` rather than
`dispatch_action("db_run_query", …)`. `tools/list` and `tools/call` already do the work
that a hand-written `list_actions`/`dispatch_action` pair would duplicate.

That leaves exactly **one hand-written tool: `read_pane`**, satisfying Invariant 3.

The registry therefore has one definition and two projections — one to SwiftUI controls,
one to MCP tools. Adding an action does both at once, which is the property Decision 9
is paying for.

### 2.4 A limitation this removes

Because `--mcp-config` sets `WAKIL_ORG` and `WAKIL_PROVIDER` per session launch, the
config dir stops determining the org. This delivers Invariant 4's unfulfilled second
half — one provider serving several organisations — without the per-org server-name
namespacing deferred on 2026-09-07. `wakil provider add`'s config-dir collision guard
remains correct and stays in place; it governs the CLI registration path, which is
unchanged.

---

## 3. The harness

### 3.1 Protocol

`AgentHarness` covers start, send, events, interrupt, and stop. Invariant 1 requires
it: nothing outside this adapter may know Claude exists. `ClaudeCodeCLIHarness` is its
only implementation in 2a; a Node/TypeScript Agent SDK sidecar remains available later
as a second implementation rather than a rewrite.

Decision 16 also names resume, list-sessions and capabilities. **None of the three is
in the 2a protocol**, and resume is not implemented anywhere in 2a: `--resume` is
passed nowhere, and the `session_resume` action Task 9 adds only *reads* a session's
metadata and first prompt. Decision 16 stands as the shape the harness grows into;
this list is what it shipped.

**Amendment, 2026-09-07.** `HarnessEvent.toolResult` gains a third field, `isError:
Bool`, decoded from the `tool_result` block's own `is_error` (absent → `false`). The
probe found the flag on the wire (`docs/wakil/phase-2a-probe.md` §4) and found the
event that proves the write gate's second layer fires at the harness arriving as
exactly that case — §6's `is_error=True | Permission for this tool use was denied`.
Without the field, a refused or failed tool call is indistinguishable from a successful
one at the event level, which §7's thought thread — *"a plain list of harness events
with their status"* — cannot be built on. Done here rather than in 2b so that 2b's
design of the thought thread's failure treatment does not also have to change the enum.
(This section carries no case list to edit; the enumerated cases live in the plan's
Task 6 interfaces block, amended in place alongside this note.)

### 3.2 Invocation

Verified present in `claude` 2.1.263 by inspecting `--help`:

```
claude -p
  --input-format stream-json --output-format stream-json   bidirectional, multi-turn
  --verbose                                                 required by the above under -p
  --include-partial-messages                                token-level streaming
  --session-id <uuid>                                       Wakil assigns the id
  --mcp-config <json> --strict-mcp-config                   per-session servers only
  --permission-prompt-tool <tool>                           permission decisions to host
```

`--verbose` is not optional: the live probe (`docs/wakil/phase-2a-probe.md` §1) found
`claude` 2.1.263 rejecting the invocation without it — `Error: When using --print,
--output-format=stream-json requires --verbose`.

The environment is **constructed explicitly**, never inherited: `CLAUDE_CONFIG_DIR` and
`CLAUDE_CODE_OAUTH_TOKEN` for the session's provider, and `ANTHROPIC_API_KEY` simply
never included. Decision 4 records that the SDK's `env` replaces rather than merges;
building the environment explicitly gives the same guarantee through the CLI. The binary
is pinned by absolute path rather than resolved through `PATH`.

### 3.3 Session lifecycle — charter open question 5, now closed

**Start fresh by default, with resume as a visible action.** Every launch assigns a new
`--session-id` UUID. Resuming is an explicit, enumerated action the user chooses, never
a default.

Decision 12 is the reason: long-lived sessions drift in ways that cannot be debugged.
Because Wakil assigns the session id, it knows the transcript path before the session
writes anything — so the resume list is authoritative rather than reconstructed by
scanning directories, and Decision 13's warning about the lossy `/`→`-` path encoding
stops applying to sessions Wakil starts.

*This closes charter open question 5. Fold it into `north-star.md` when this spec is
accepted.*

### 3.4 What is not yet verified

The stream-json **event shapes are unverified.** They have not been observed, only
inferred from flag documentation. The parser must be built against recorded fixtures
from a real session, not against assumption — this is the plan's first task, and it is
gated on the OAuth token rotation in `operator-todo.md` §4.

The same probe must answer a second question. `claude auth status --json` shows the
`initech` account on a `team` plan and `umbrella` on `enterprise` (checked 2026-09-07).
**Managed settings on those plans can constrain MCP servers and permission modes** —
precisely the mechanisms §2 and §5 depend on. If managed policy overrides
`--strict-mcp-config` or `--permission-prompt-tool`, this architecture must know before
it is built. The `personal` account is `max` and is the safe default for development.

---

## 4. The action registry and journal

An action is `{name, schema, kind: .read | .mutate, handler}`.

Three consumers exist from day one, all entering at
`Registry.dispatch(name:params:origin:)`:

1. a SwiftUI control,
2. an MCP `tools/call` from the agent,
3. the debug dispatch hook.

The third is not test scaffolding. A scriptable dispatch entry point is the same
mechanism the agent uses, so having a second real consumer from the start is what keeps
Invariant 2 honest rather than aspirational — and it is what shrinks the operator's
manual checklist from eight items to three.

Every dispatch appends one line to `~/.wakil/journal/<sessionId>.jsonl`:

```jsonc
{ "id": "...", "ts": "...", "action": "db_run_query", "params": { },
  "origin": "ui" | "agent" | "debug", "paneId": "...", "environment": "staging",
  "outcome": "ok" | "gated" | "blocked" | "error" }
```

`environment` was added 2026-09-10 (issue #15) and is the value `dispatch` handed
`writeGate` — the environment at the moment of the decision, which is not always the one
the action was proposed in, since a parked mutation is re-judged when the operator
confirms. It is optional in the type because every line written before that date omits it.

Journal equality across origins — identical but for `origin` — is the headless test that
keeps the invariant true as actions are added. Undo is deferred to a later sub-phase:
nothing in 2a mutates local state.

---

## 5. The write gate

**Correction, 2026-09-07.** An earlier draft of this section claimed `wakil-http` could
issue a non-idempotent request and so gave 2a a real mutation to gate. It cannot: its
`request` tool is GET/HEAD only and refuses every other method. Phase 1's capability
layer has **zero** mutating operations — `wakil-db` is behind the read-only gate,
`wakil-pm` and `wakil-recall` only read, and the only state anything writes is
`active.json` via `set_project` / `set_environment`.

So 2a has nothing real to gate, and the honest response is to build the mechanism
without inventing a mutation for it to guard:

- The gate ships as a pure function and a check in `Registry.dispatch`, both fully
  tested.
- **2a registers zero `.mutate` actions.** The exhaustive gate tests use a test-only
  action registered in the test target, so no fake mutating capability enters production
  code.
- Context switches (`ctx_set_project`, `ctx_set_environment`) are `.read`. They do write
  `active.json`, but demanding a typed `confirm` to change environment would be absurd,
  and Invariant 7 is about mutations to *the world*, not to Wakil's own selection state.
- The first real `.mutate` action arrives when `wakil-http` gains write methods. The
  charter's Phase 2 exit criterion requires that (*"call the confirmation endpoint"*),
  but Invariant 6 says write paths are added per adapter with deliberate justification —
  so it gets its own decision and its own sub-phase, not a quiet addition here.

The gate itself is a pure function:

```
(environment, actionKind) -> .allow | .gate(typedToken) | .block
```

- **staging** + `.mutate` → `.gate` — proceeds only on a typed `confirm`
- **production** + `.mutate` → `.block` — refused outright, no override (§12 of
  `design-language.md`)
- any environment + `.read` → `.allow`

It is enforced in `Registry.dispatch`, before the handler runs. That is the layer this
spec commits to, and it is sufficient for every mutation reachable through the registry.

A **second layer at the harness** via `--permission-prompt-tool` is intended, because the
agent must not reach a mutation by any route bypassing the registry and a chokepoint
inside the registry cannot prove that about a subprocess. Whether it is available is
open question 3: `--permission-prompt-tool` may see only built-in tools, not MCP tool
calls. Plan task 1 probes it. **If it does not cover MCP calls, the fallback is
`--strict-mcp-config` plus `--permission-prompts none`** — the agent's entire tool
surface is then Wakil-served, and anything that would prompt is denied rather than
escalated. That fallback is weaker in principle but closes the same hole, so the gate
does not depend on the probe's outcome.

**Amendment, 2026-09-08 — what 2a actually passes.** Probe §6 answered open question 3
in favour of the intended design: the permission layer *does* cover MCP tool calls. That
answer turned out to cut the other way first. A `-p` session has no approval surface, so
the CLI denies anything not explicitly allowed — including reads — and `buildLaunch`
passed no permission flags at all, which would have left the agent unable to call
`read_pane`, let alone anything else. 2a therefore passes an **`--allowedTools` allow
list** (`agentAllowedTools`, derived from `ActionRegistry.all()` and filtered to `.read`)
and **no `--permission-prompt-tool`**. The prompt tool is an interactive refusal surface
and 2a registers zero `.mutate` actions, so there is nothing for it to refuse; building
it now would mean building and testing a gate with no live subject. It becomes
load-bearing in 2b with the first `.mutate` action, and the `.read` filter is the seam it
plugs into — a mutating action is structurally absent from the allow list rather than
pre-approved by it. No `--permission-mode` is passed either: the default mode plus the
allow list is what keeps everything unlisted failing closed. The enforcement point in 2a
remains `Registry.dispatch` plus `writeGate`; the allow list is not a security boundary,
it is what stops the CLI auto-denying a read the registry already decided was safe. This
is asserted at the argv level only — no test in the repo runs `claude` — and confirmed
live by standing check 2 of `docs/wakil/phase-2a-acceptance.md`.

Invariant 7's voice clause has nothing to constrain in 2a — voice arrives in 2d — but the
gate is built now so that 2d adds a transport rather than a safety mechanism.

---

## 6. Context switching

The org / project / environment triple stays exactly as Phase 1 defines it, read and
written through `wakil-ctx` by registry handlers. The switcher is two enumerated
actions (`ctx_set_project`, `ctx_set_environment`), so it is voice-addressable in 2d
for free.

There is no `ctx_set_org`. The organisation is fixed for the life of the process by
`WAKIL_ORG`, read at launch and forwarded to every spawned Go binary by
`WakilWiring.childProcessEnvironment`; `wakil-ctx` resolves the active context inside
that org and `Resolve()` re-checks it on every call, which is what makes Invariant 4's
cross-org isolation structural. Switching org would mean re-pointing already-running
children at a different one mid-session, so in 2a you change org by relaunching with a
different `WAKIL_ORG`. An in-session org switch is a later phase's, and it is a
lifecycle question before it is a registry one.

`ctx_set_project` must surface `Resolve()`'s existing refusal of a project filed under
another org as a first-class error in the UI, not as a silent no-op. Cross-org isolation
was proven at the CLI in the Phase 1 acceptance run; 2a must prove it again through this
new path.

The active environment is displayed at all times (Invariant 8). In 2a that is a plain
text label, not the alarming production treatment 2b will give it.

---

## 7. Panes in 2a

One pane type: **database**. A plain SwiftUI table, no virtualization, no density
toggle, no chips, no type annotations — 2c builds the real §8 data surface. Its job here
is solely to prove that registry-owned state renders, and that `read_pane` can serialise
it back to the agent.

The **thought thread** is a plain list of harness events with their status. §9's
rising-from-the-Core treatment is 2b's.

---

## 8. Verification

Split by layer, per the decision recorded on 2026-09-07.

**Headless Swift tests** (`swift-testing`), which are mine to run and keep green:

- stream-json parsing, against fixtures recorded from a real session
- registry completeness: every action enumerated, every schema valid, dispatch idempotent
- journal equality across `ui`, `agent` and `debug` origins
- the write gate as a pure function, across the full environment × kind matrix
- context resolution, including refusal of a foreign project
- pane-state serialisation for `read_pane`
- JSON-RPC framing, both client and shim directions

**Operator runbook**, yours, written up as `docs/wakil/phase-2a-acceptance.md`:

1. a window appears and stays
2. a real turn against a real subscription returns an answer
3. the thought thread renders progressively rather than all at once

Items 4–8 — dual-drive equivalence, the write gate, production blocked, context
re-pointing, cross-org isolation through the UI — need your eyes once, then become
headless assertions via the debug hook.

The reason the operator list is three items rather than eight is the debug dispatch
hook. Build it early.

---

## 9. File structure

Same repository. The five Go binaries are bundled into the `.app`, so one repo and one
version is the honest arrangement.

| Path | Responsibility |
|---|---|
| `app/Package.swift` | SwiftPM manifest; two targets plus tests |
| `app/Sources/WakilKit/Harness/` | `AgentHarness`, `ClaudeCodeCLIHarness`, stream-json decoding |
| `app/Sources/WakilKit/Registry/` | action definitions, `dispatch`, journal |
| `app/Sources/WakilKit/MCP/` | JSON-RPC framing; stdio client; shim server |
| `app/Sources/WakilKit/Context/` | org/project/environment over `wakil-ctx` |
| `app/Sources/WakilKit/Gate/` | the write gate, pure |
| `app/Sources/WakilApp/` | window, DB pane, thought thread, `--mcp-shim` entry check |
| `app/Tests/WakilKitTests/` | everything in §8's headless list |
| `app/Fixtures/stream-json/` | recorded session events |
| `scripts/make-app-bundle.sh` | assembles `Wakil.app` from the SwiftPM product |

`Makefile` gains `app-build`, `app-test` and `app-bundle`. `CGO_ENABLED=0` stays pinned
for the Go side; the Swift side does not touch it.

---

## 10. Risks

| Risk | Handling |
|---|---|
| stream-json shapes differ from assumption | Plan task 1: record fixtures from a live session before writing the parser |
| Managed settings on `team`/`enterprise` override `--strict-mcp-config` or `--permission-prompt-tool` | Same probe; develop against `personal` (`max`), which is unmanaged |
| stream-json is a less stable contract than the SDK's types | Defensive parsing, pinned binary path, fixtures that fail loudly on drift |
| The shim's headless mode accidentally initialises AppKit | Argument check before `NSApplication`; a test asserts the shim runs with no display server |
| Stale unix sockets accumulate | Socket path carries the session UUID, so sessions cannot collide; each session unlinks its own path on stop. A socket outliving a *crashed* session is not swept up — see §2.2 — and is cleared by hand |

---

## 11. Open questions

| # | Question | Blocks |
|---|---|---|
| 1 | Does a Swift MCP SDK worth adopting exist, or is hand-rolled JSON-RPC the right call? Hand-rolled is assumed — the surface is `initialize`, `tools/list`, `tools/call`. | Plan task 2 |
| 2 | Where does `Wakil.app` live during development, given it is unsigned and hand-assembled? Build directory assumed. | Plan task 1 |
| 3 | Does `--permission-prompt-tool` see MCP tool calls, or only built-in tools? If only built-in, the gate's second layer needs another mechanism. | Plan task 1 probe |

Charter open question 10 (default STT engine) is untouched here — it blocks 2d, not 2a.
