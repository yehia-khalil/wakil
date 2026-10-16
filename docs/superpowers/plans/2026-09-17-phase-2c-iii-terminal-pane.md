# Phase 2c-iii — Terminal Pane, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real interactive shell runs on a PTY inside a Wakil pane, the agent may read it and propose into it but never run in it, `read_pane` returns both of the pane's surfaces as a union keyed by `kind`, and no shell outlives the pane that opened it.

**Architecture:** One new actor, `TerminalStore`, owns the live OS resources (the pty master fd, the child pid, the drain thread) and nothing else; it is modelled line-for-line on `MCPClient` — single-flight `stop()` guarded by a teardown task, never a blocking wait. Rendered state (blocks, grid, proposal) stays in `PaneStore`, whose `Contents` becomes an enum over pane kinds and whose `snapshot` becomes a **typed** discriminated union; JSON serialisation moves to the MCP boundary and the view stops re-parsing the agent's JSON. Block boundaries, exit codes and the live cwd come from OSC 133 / OSC 7 marks that **Wakil's own byte scanner** finds in the pty stream (SwiftTerm parses them but does not surrender the exit code, and discards them entirely under the alternate screen), emitted by a generated rc Wakil injects per shell. The four new actions are all `.control`; `term_run` is the seventh member of `operatorOnlyActions`.

**Tech Stack:** Swift 6.3 (`WakilKit` — testable; `WakilApp` — SwiftUI, no test target), SwiftTerm 1.20.0 (`WakilKit`'s first external dependency, headless engine only), Darwin `forkpty`/`TIOCSWINSZ`, Swift Testing (`#expect`), `make app-test` / `make test`.

**Spec:** https://github.com/yehia-khalil/rafiq/issues/72
**Measured by:** `docs/wakil/phase-2c-iii-probe.md` — where this and the issue disagree, the probe governs; its §7 lists the places they do, and each is restated below in this plan's own words.

---

## Global Constraints

Every task's requirements implicitly include this section.

### Where the probe overrules the issue (probe §7 — binding)

- **The block history is NOT derived from SwiftTerm's buffer.** OSC 133 marks survive *scrolling*, not *scrollback eviction* — at 200 marked commands 6 were already gone, at 400 it was 207 (probe §4.1). Each block is **captured at its `D` mark into Wakil's own storage** as it completes. The issue's phrase "marks that survive scrollback" is wrong and so is anything built on it.
- **The drain is bounded.** The issue says "a plain thread reading available data into an **unbounded** stream"; that shape queued **18.33 MB** during a 28 MB `cat` (probe §4.3). **This plan picks inline parse:** the drain thread parses as it reads and lets the pty block. 78.0 MB/s against the queue's 91.8 — 15% slower, and it cannot exhaust memory at any file size. No queue, no cap constant, no drop policy.
- **One `Text` per row, never one per cell.** A `Text` per cell draws **4 fps** at the pane's own 132×36 and is disqualified; a `Text` per row clears 120fps by 3.4× and keeps per-cell selection, hit-testing and accessibility. `Canvas` is disqualified too — it gives those up for headroom row-wise already has (probe §3, §6.1).
- **Redraw is driven by a polled `getUpdateRange()` at the display's frame rate, never from the feed.** `TerminalDelegate` has **no content-change member at all** — there is no push to drive it from (probe §4.2). Polling turns 28 MB of `cat` into 21 frames.
- **Do not coalesce bytes before the parser.** Chunk size does not move the rate (73–77 MB/s plain, 55–60 SGR, flat from 1 KB to 1 MB) and the pty caps reads at 1,024 bytes regardless of the buffer offered (probe §6.3).
- **The scrollback bound is a memory question with numbers:** ~112 bytes per held output row. **This plan picks 200 blocks × a 500-line cap ≈ 18 MB per pane** (probe §6.6 measured 18.39 MB for exactly that shape). 1,000 × 1,000 would be ~86 MB, which is affordable for one pane and not for a canvas of them.
- **`hostCurrentDirectory` returns a raw URL** (`file://localhost/Users/operator/orca`), not a path. Whatever draws the live cwd parses it.

### Three places this plan resolves an intent the spec states at the level of intent

Named here rather than buried in a task, because an executor reads this section and may never open the issue.

1. **`term_run` is dispatched once, at the `D` mark, not at `C`.** The issue says the action is "journalled from the shell's OSC 133 `C`" *and* that its journal entry records the exit code and the duration — which exist only at `D`. One dispatch at `D`, carrying every field the issue lists, beats two carrying half each. `C` is still what makes the run an action: it is where the block opens and where the command text is captured. **A block still open at teardown is journalled with a null exit code** rather than lost, so no submitted command escapes the journal.
2. **Accepting or discarding a proposal is input, not a fifth action.** #39 ruled keystrokes into the prompt are text-field editing; the four-action table in the issue is exactly four. `⏎` writes the proposal's bytes to the pty and clears the pending proposal; `⌫` clears it. The journal records which happened, at `D`, in `term_run`'s `accepted` field.
3. **What the PTY's environment actually contains.** `wakilcore.Environment` is `{databases, api}` — there is no environment-variable map anywhere in the capability layer, so "the active environment's variables" has no literal referent to copy. The shell inherits **Wakil's own process environment** plus `WAKIL_ORG`, `WAKIL_PROJECT`, `WAKIL_ENVIRONMENT`, `TERM=xterm-256color`, and the rc-injection variable for its shell.

   **Keychain secrets are deliberately NOT exported**, and the reason is that they would not help: the residue this pane exists for — `kubectl get pods`, `aws s3 ls`, `docker ps` — authenticates from `~/.kube`, `~/.aws` and the Docker socket, and not one of those has ever read `wakil:<org>:<ref>`, which holds DSNs and API credentials for `wakil-db` and `wakil-http`. Exporting them buys nothing for the commands this pane is for while widening a boundary Invariant 4 requires to be structurally uncrossable. There are also no stable names to export under, and only the active environment's own refs are enumerable, so it would be partial as well as useless. A *deliberate* per-credential fetch is the honest version of the idea and belongs in 2c-iv beside `wakil secrets set-api`.

   **The process environment is not the operator's login environment**, and the difference is a shipped-artefact defect rather than a nicety. In a bundled `Wakil.app` it is launchd's — no `/opt/homebrew/bin`, no `AWS_PROFILE`. What reconstructs the operator's environment is the **shell**: spawned `-il` (interactive **login**, which is what Terminal.app runs and what makes `/etc/zprofile` and therefore `path_helper` run), with the generated rc sourcing their own profile chain. Every test here inherits a terminal's environment, because `swift test` runs from one, so a `-i` shell passes the whole suite and ships unable to find `kubectl`. **Runbook check 3a exists for exactly this and must be walked in the bundle, not in a test.**

### Where the code below is elided

A handful of bodies in the tasks are written as `{ ... }` to keep a step
readable. **Every one of them is written out in full in Appendix A at the end
of this plan** — the publisher loop, the pane title, `PaneStore`'s terminal
writers, the mirror's decode, and `WindowModel`'s pumps and test seams.
Anything else shown as `{ ... }` is a memberwise initialiser that assigns each
parameter to the property of the same name. Nothing is left to invent.

### Rules this sub-phase inherits

- **`WakilApp` has no test target and cannot have one.** Anything that must be tested lives in `WakilKit`. Only the drawing is untested, exactly as for every other pane, and it is walked in the runbook rather than asserted.
- **Invariant 2 — actions are the only mutation path.** Every state change goes through `ActionRegistry.dispatch`. The shell owning the input line does not exempt it: OSC 133 is what keeps the run an action.
- **Invariant 4 — the org is a credential boundary.** No agent-reachable run ships, in any form. What a pane run would buy the agent is the org's credentials and the active environment, not reach — it already has a bare shell outside Wakil.
- **Invariant 6 — no write earns in here.** A shell command cannot be classified, so it cannot earn one.
- **Tests assert at the highest seam that can see the behaviour and drive the real chain.** 2b-viii's walk found two correctness bugs invisible to 794 passing tests *because* their tests called store methods the shipped path never called. Tests here dispatch through the registry and drive `WindowModel`'s real lifecycle methods.
- **Swift concurrency:** `WindowModel` is `@MainActor @Observable`; `PaneStore`, `LayoutStore`, `ActionRegistry` and `TerminalStore` are actors. A `Terminal` instance from SwiftTerm is *not* thread-safe and is owned by exactly one lock-guarded box.
- **Swift 6 language mode, macOS 14.4 deployment target — both unchanged.** Only `WakilKit` gains the dependency; `WakilApp` keeps only the drawing.
- **Commit after every task.** `make app-test` before every Swift commit; `make test` as well if Go is touched (it is not, in this sub-phase).
- **No `git stash`** — this repo is used from multiple worktrees sharing one stash stack. Use a WIP commit.

### The six doc comments — the sub-phase's sixth exit clause

The sub-phase does **not** close while any of these is still false. Each is assigned to the task that makes it false; none may be deferred to the end.

| Symbol | Task |
|---|---|
| `ActionKind.mutate` — "gated everywhere, blocked in production" | Task 1 |
| `writeGate`'s table — maps kind → answer, must map price → answer | Task 1 |
| `PaneStore`'s always-present-key rule — one shape, now a union | Task 3 |
| `read_pane`'s `tools/list` prose — describes only the tabular fields | Task 4 |
| The unknown-pane-id justification (`MCPServer.swift`) — rests on a falsified premise | Task 4 |
| `autoResumeAfterSwitch` — claims the collapse hides sessions, then refutes itself | Task 16 |

---

## File Structure

**New — `WakilKit`, the terminal itself**

- `app/Sources/WakilKit/Terminal/TerminalStore.swift` — the actor. Owns pty master fds, child pids, drain threads. Open, write, resize, close one, shut all down. Nothing rendered.
- `app/Sources/WakilKit/Terminal/TerminalSession.swift` — one shell's lock-guarded box: the `forkpty` spawn, the drain thread, the SwiftTerm `Terminal`, the mark scanner, the open block.
- `app/Sources/WakilKit/Terminal/ShellIntegration.swift` — the supported-shell set and the generated rc per shell. Pure string-building; no process.
- `app/Sources/WakilKit/Terminal/TerminalMarkScanner.swift` — Wakil's own OSC 133 / OSC 7 byte scanner. Pure; split-across-reads safe.
- `app/Sources/WakilKit/Terminal/TerminalBlock.swift` — the block model, its origin, the caps, and the partiality they produce.
- `app/Sources/WakilKit/Terminal/TerminalActions.swift` — `term_open`, `term_propose`, `term_run`, `term_scroll`.
- `app/Sources/WakilKit/Terminal/TerminalMirror.swift` — `HarnessEvent` → mirrored blocks. Pure.

**New — `WakilKit`, the snapshot union**

- `app/Sources/WakilKit/Panes/PaneSnapshot.swift` — the typed union: `PaneSnapshot`, `GridSnapshot`, `TerminalSnapshot`.
- `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift` — the union's wire form. The **only** place a snapshot becomes JSON.

**Modified — `WakilKit`**

- `Registry/Action.swift` — `price`; `ActionKind.mutate`'s doc comment.
- `Gate/WriteGate.swift` — the fifth parameter; the table.
- `Registry/ActionRegistry.swift` — pass `action.price` to the gate.
- `Panes/PaneStore.swift` — `Contents` becomes an enum over kinds; `snapshot(paneId:kind:)` returns `PaneSnapshot`; terminal writers.
- `Panes/PaneContentActions.swift` — the five grid actions refuse a non-grid pane by name.
- `Layout/Pane.swift` — `kinds` gains `"terminal"`.
- `Layout/LayoutActions.swift` — `pane_close` awaits the shell's teardown.
- `MCP/MCPServer.swift` — `readPane` takes the layout; both doc comments; the `tools/list` prose.
- `MCP/PermissionPrompt.swift` — `term_run` joins `operatorOnlyActions`; a fourth denial family.
- `App/WindowModel.swift` — `terminals`; `refreshPanes` typed; the run pump; the mirror pump; `invalidateForOrgChange`; `shutdown`; `autoResumeAfterSwitch`'s comment.
- `App/AppWiring.swift` — build the store, register the actions, tear it down.

**Modified — `WakilApp` (untested by construction)**

- `Sources/WakilApp/TerminalPane.swift` — **create**: header, block history, live grid, proposal, mirror, ⌘F.
- `Sources/WakilApp/Canvas.swift` — the second arm of `switch pane.kind`.

**Modified — package**

- `app/Package.swift` — the SwiftTerm dependency on `WakilKit`.

**Tests**

- `app/Tests/WakilKitTests/TerminalStoreTests.swift` — **create**: a real `bash`/`zsh` on a real pty.
- `app/Tests/WakilKitTests/TerminalMarkScannerTests.swift` — **create**.
- `app/Tests/WakilKitTests/TerminalActionsTests.swift` — **create**: registry dispatch.
- `app/Tests/WakilKitTests/TerminalMirrorTests.swift` — **create**.
- Modified: `PaneStoreTests`, `PaneContentsTests`, `PaneContentActionsTests`, `MCPServerTests`, `WriteGateTests`, `ActionRegistryTests`, `PermissionPromptTests`, `InvalidationContractTests`, `OrgSwitchTests`, `ShutdownContractTests`, `WindowModelTests`, `StandardActionsTests`.

**Docs**

- `docs/wakil/phase-2c-iii-acceptance.md` — **create**: the runbook.
- `docs/wakil/phase-log.md`, `docs/wakil/north-star.md` — the record.

---

## Task 1: The write price, and two doc comments that stop being false

Decision 25, built here rather than in 2c-iv, because it is what makes two of the six owed doc comments true rather than aspirational. Today's hardcoded rule *is* the default pair, so no existing action's gate decision changes — by construction, not by inspection.

**Files:**
- Modify: `app/Sources/WakilKit/Registry/Action.swift` (the `price` property; `ActionKind.mutate`'s doc comment)
- Modify: `app/Sources/WakilKit/Gate/WriteGate.swift` (the fifth parameter; the table)
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift:dispatch` (pass it)
- Test: `app/Tests/WakilKitTests/WriteGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Action.price: (production: GateDecision, otherwise: GateDecision)`, defaulting to `(.block, .gate)`; `writeGate(environment:kind:origin:targetEnvironment:price:)` with `price` defaulted to the same pair.

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/WriteGateTests.swift`:

```swift
@Test func theDefaultPriceIsTodaysHardcodedRuleSoNoExistingActionMoves() {
    // Every action shipped before Decision 25 declares no price, so the
    // pair below is what the gate reads for all of them. If this ever
    // fails, an existing action's gate decision has moved without anyone
    // saying so.
    let action = Action(
        name: "anything", description: "", kind: .mutate,
        schema: .object([:]), handler: { _ in .null })
    #expect(action.price == (production: .block, otherwise: .gate))
    #expect(writeGate(environment: "production", kind: .mutate, origin: .ui,
                      targetEnvironment: nil, price: action.price) == .block)
    #expect(writeGate(environment: "staging", kind: .mutate, origin: .ui,
                      targetEnvironment: nil, price: action.price) == .gate)
}

@Test func anActionMayDeclareAWriteThatCostsNothingOutsideProduction() {
    // The shape Invariant 7's 2026-09-17 amendment already requires and
    // that no mechanism existed for: a write that a spoken turn may
    // execute outside production.
    let price: (production: GateDecision, otherwise: GateDecision) = (.block, .allow)
    #expect(writeGate(environment: "staging", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, price: price) == .allow)
    #expect(writeGate(environment: "production", kind: .mutate, origin: .agent,
                      targetEnvironment: nil, price: price) == .block)
}

@Test func thePriceIsNeverConsultedForAReadOrAControlAction() {
    // A price that could make a read gate would be a second policy
    // engine. The gate short-circuits before it looks.
    let hostile: (production: GateDecision, otherwise: GateDecision) = (.block, .block)
    #expect(writeGate(environment: "production", kind: .read, origin: .agent,
                      targetEnvironment: nil, price: hostile) == .allow)
    #expect(writeGate(environment: "production", kind: .control, origin: .ui,
                      targetEnvironment: nil, price: hostile) == .allow)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter WriteGate`
Expected: FAIL — `Action` has no member `price`, `writeGate` has no `price:` parameter.

- [ ] **Step 3: Add `price` to `Action`**

In `app/Sources/WakilKit/Registry/Action.swift`, add the stored property and the init parameter:

```swift
    /// What this action's write costs, as a pair: the gate's answer in
    /// `production`, and its answer everywhere else.
    ///
    /// **The default pair is today's hardcoded rule**, so every action
    /// written before Decision 25 keeps exactly the gate decision it had —
    /// by construction rather than by inspection. `(.block, .gate)` is
    /// verbatim what `writeGate`'s `.mutate` branch used to compute for
    /// itself.
    ///
    /// **Read only for `.mutate`.** `.read` and `.control` are answered
    /// before the gate looks at a price; an action that declared a
    /// hostile pair and a harmless kind changes nothing, which is what
    /// keeps the price a per-adapter cost rather than a second policy
    /// engine (`WriteGateTests.thePriceIsNeverConsultedForAReadOrAControlAction`).
    ///
    /// **Why a pair on the action and not a fourth `ActionKind`.** Two of
    /// `ActionKind`'s three consumers compare by equality rather than
    /// switching, so a fourth case would have made `isMutation` silently
    /// false and the confirmation plane stop appearing — a safety
    /// chokepoint failing quietly, which is the one failure mode the gate
    /// exists to prevent.
    public var price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate)
```

and in `init`, after `targetEnvironmentParam`:

```swift
        price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate)
    ) {
        ...
        self.price = price
    }
```

- [ ] **Step 4: Rewrite `ActionKind.mutate`'s doc comment**

Replace the three lines on `case mutate` in the same file:

```swift
    /// Changes the world outside Wakil. What that costs is the **action's
    /// own** `price` (Decision 25), not this case: the gate reads the
    /// pair, and the default pair — `(.block, .gate)` — is what this
    /// comment used to state as a rule.
    ///
    /// **This comment used to say "gated everywhere, blocked in
    /// production", and it was false twice over by 2026-09-17.** Once
    /// because `.control` now covers an action that runs a shell command
    /// (`term_run`), so "changes the world outside Wakil" no longer
    /// separates the two cases cleanly — `.control` was redefined by
    /// 2c-iii as *"not gated by environment"* rather than *"doesn't touch
    /// the world"*, and the instrument protecting a shell run is
    /// `operatorOnlyActions` plus the operator's own Enter, never the
    /// gate. And once because the price moved the gating off the kind
    /// entirely.
    case mutate
```

Also amend `.control`'s comment in the same edit:

```swift
    /// Not gated by the environment. Usually because the world outside
    /// Wakil is untouched — pane geometry, the active context — and in
    /// exactly one case (`term_run`) because the environment is the wrong
    /// instrument: `.mutate` would gate every `ls` on a typed
    /// confirmation and block the pane outright in production, which is
    /// where an operator most wants a shell. What protects that one is
    /// `operatorOnlyActions` and the in-pane `⏎`.
    case control
```

- [ ] **Step 5: Add the parameter to `writeGate` and rewrite its table**

In `app/Sources/WakilKit/Gate/WriteGate.swift`, replace the table at the head of the doc comment:

```swift
/// | Kind | Origin | Decision |
/// |---|---|---|
/// | `.read` | any | `.allow` |
/// | `.control` | `.ui`, `.debug` | `.allow` |
/// | `.control` | `.agent`, names a target, production on either side | `.gate` |
/// | `.control` | `.agent`, otherwise | `.allow` |
/// | `.mutate` | any | `price.production` in production, `price.otherwise` elsewhere |
///
/// **The last row used to read "`.block` in production, `.gate`
/// elsewhere", and that pair is now the DEFAULT rather than the rule**
/// (Decision 25). An action declares its own price, so two adapters'
/// writes can cost different things without a fourth `ActionKind` and
/// without changing any SQL. Every action written before that decision
/// declares nothing and therefore gets `(.block, .gate)` — the old rule,
/// preserved by construction.
```

and the signature and `.mutate` branch:

```swift
public func writeGate(
    environment: String,
    kind: ActionKind,
    origin: ActionOrigin,
    targetEnvironment: String?,
    price: (production: GateDecision, otherwise: GateDecision) = (.block, .gate)
) -> GateDecision {
```

```swift
    case .mutate:
        return isProduction(environment) ? price.production : price.otherwise
```

The default value is what keeps the ~40 existing four-argument call sites and tests compiling untouched.

- [ ] **Step 6: Pass the price from the registry**

In `app/Sources/WakilKit/Registry/ActionRegistry.swift`, in `dispatch`:

```swift
        switch writeGate(
            environment: environment,
            kind: action.kind,
            origin: origin,
            targetEnvironment: targetEnvironment(of: action, in: params),
            price: action.price)
        {
```

- [ ] **Step 7: Run the whole suite**

Run: `cd app && ../scripts/swift-test.sh`
Expected: PASS, with no change to `MutationActionTests`, `ActionRegistryTests` or `StandardActionsTests` — the point of the default pair.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Registry/Action.swift app/Sources/WakilKit/Gate/WriteGate.swift app/Sources/WakilKit/Registry/ActionRegistry.swift app/Tests/WakilKitTests/WriteGateTests.swift
git commit -m "feat: an action declares its own write price, with today's rule as the default

Decision 25. Two of 2c-iii's six owed doc comments stop being false."
```

---

## Task 2: SwiftTerm, `WakilKit`'s first external dependency

**Files:**
- Modify: `app/Package.swift`
- Test: `app/Tests/WakilKitTests/TerminalStoreTests.swift` (create — one smoke test for now)

**Interfaces:**
- Consumes: nothing.
- Produces: `import SwiftTerm` usable inside `WakilKit`; `Terminal`, `TerminalDelegate`, `TerminalOptions` in scope.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/TerminalStoreTests.swift`:

```swift
import Testing
import SwiftTerm
@testable import WakilKit

/// The dependency is reachable from `WakilKit` and its engine behaves as
/// the probe measured, headlessly, with no view and no display.
///
/// **This asserts the dependency, not our code.** It exists because
/// SwiftTerm is this package's FIRST external dependency: a version bump
/// that changed `getUpdateRange`'s shape or dropped the headless
/// `Terminal` would otherwise surface as a compile error inside a pane
/// three tasks later, with nothing saying the dependency moved.
@Test func swiftTermsHeadlessEngineParsesAndReportsADirtyRange() {
    final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    var options = TerminalOptions.default
    options.cols = 80
    options.rows = 24
    let terminal = Terminal(delegate: Silent(), options: options)

    terminal.feed(text: "hello\r\n")

    #expect(terminal.getUpdateRange() != nil)
    let line = terminal.getLine(row: 0)
    #expect(line?.translateToString(trimRight: true) == "hello")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter swiftTermsHeadlessEngine`
Expected: FAIL — `no such module 'SwiftTerm'`.

- [ ] **Step 3: Add the dependency**

In `app/Package.swift`, add the `dependencies:` array and attach the product to `WakilKit` only:

```swift
let package = Package(
    name: "Wakil",
    platforms: [.macOS("14.4")],
    dependencies: [
        // WakilKit's FIRST external dependency, taken by Decision 23 and
        // pinned to the version `scripts/probe/termspike` measured
        // (1.20.0, Package.resolved there). Only the HEADLESS engine is
        // used: OSC 133 parsing, OSC 7 host-directory tracking, the
        // alternate-screen notification, the search engine and the
        // Unicode width tables. Its AppKit terminal view is deliberately
        // NOT used — its SwiftUI wrapper is iOS-only, and adopting the
        // AppKit one would put Terminal.app inside Wakil: no blocks, no
        // per-block affordances, nothing from design-language.md. The
        // grid is drawn in SwiftUI.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "WakilKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(
            name: "WakilApp",
            // NOT SwiftTerm. WakilApp keeps only the drawing, exactly as
            // for every other pane; the engine lives one target down,
            // where it can be tested.
            dependencies: ["WakilKit"],
            resources: [.copy("default.metallib")]),
        .testTarget(name: "WakilKitTests", dependencies: ["WakilKit"]),
    ]
)
```

- [ ] **Step 4: Run the test**

Run: `cd app && ../scripts/swift-test.sh --filter swiftTermsHeadlessEngine`
Expected: PASS. A `Package.resolved` appears at `app/Package.resolved` pinning 1.20.0.

- [ ] **Step 5: Run the whole suite, then commit**

Run: `make app-test`
Expected: PASS.

```bash
git add app/Package.swift app/Package.resolved app/Tests/WakilKitTests/TerminalStoreTests.swift
git commit -m "feat: take SwiftTerm's headless engine as WakilKit's first dependency

Decision 23. Engine only — the grid is drawn in SwiftUI."
```

---

## Task 3: The pane snapshot becomes a typed union, and the view stops re-parsing the agent's JSON

Decision 24, the storage half. `PaneStore.Contents` becomes an enum over kinds; `snapshot` gains a typed return and a `kind` parameter; JSON serialisation moves to the MCP boundary. The terminal case is **declared** here and filled in Task 8 — this task ships the grid case and the machinery, so the refactor lands green before a single PTY exists.

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneSnapshot.swift`
- Create: `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:154-266` (`paneTable(from:)` → `PaneTable(grid:)`), `:2647` (`refreshPanes`)
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift:716` (serialise at the boundary)
- Test: `app/Tests/WakilKitTests/PaneStoreTests.swift`, `MCPServerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 or 2.
- Produces:
  - `PaneSnapshot(kind: String?, failure: String?, contents: PaneSnapshotContents)`
  - `enum PaneSnapshotContents { case none, grid(GridSnapshot), terminal(TerminalSnapshot) }`
  - `struct GridSnapshot` — the fourteen tabular fields, typed.
  - `PaneStore.snapshot(paneId: String, kind: String?) -> PaneSnapshot`
  - `paneSnapshotJSON(_ snapshot: PaneSnapshot) -> JSONValue`
  - `PaneTable.init(grid: GridSnapshot)`

- [ ] **Step 1: Write the failing tests**

Replace `PaneStoreTests.swift`'s private helper (line 5) and add three tests:

```swift
/// Every existing assertion in this file reads the snapshot's WIRE form,
/// which is now produced at the MCP boundary rather than by the store. The
/// helper does the one hop so the ~60 assertions below are untouched.
private func object(_ snapshot: PaneSnapshot) -> [String: JSONValue] {
    guard case .object(let fields) = paneSnapshotJSON(snapshot) else { return [:] }
    return fields
}
```

```swift
@Test func aGridPanesSnapshotCarriesItsKindAndEveryKeyOfThatKind() async {
    let store = PaneStore()
    await store.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: ["int"], columnTypesInferred: false,
        rows: [[.integer(1)]], millis: 3, truncated: false, pageable: true, offset: 0,
        sort: [], listsTables: false, editable: nil)

    let snapshot = await store.snapshot(paneId: "db-1", kind: "db")

    #expect(snapshot.kind == "db")
    guard case .grid(let grid) = snapshot.contents else {
        Issue.record("expected a grid snapshot, got \(snapshot.contents)")
        return
    }
    #expect(grid.rowCount == 1)
    // The always-present rule, now scoped to the kind: every key of THIS
    // kind is present in the wire form, including when false or empty.
    let wire = object(snapshot)
    for key in ["columns", "columnTypes", "columnTypesInferred", "rows", "rowCount",
                "millis", "truncated", "pageable", "offset", "selection", "sort",
                "scrollTarget", "listsTables", "kind", "failure"] {
        #expect(wire[key] != nil, "missing \(key)")
    }
}

@Test func anUnknownPaneIdAnswersWithANullKindRatherThanAnError() async {
    let store = PaneStore()

    let snapshot = await store.snapshot(paneId: "no-such-pane", kind: nil)

    #expect(snapshot.kind == nil)
    #expect(snapshot.contents == .none)
    // `kind` is present and null, not absent — an absent key is a thing a
    // reader has to know how to interpret; an explicit null is an answer.
    #expect(object(snapshot)["kind"] == .null)
}

@Test func anOpenPaneNothingHasWrittenToStillReportsItsKind() async {
    // The freshly launched window: a `db` pane drawing "no rows" before
    // any query. `read_pane("db-1")` on it must say "db", not null — the
    // pane exists, the layout knows it, and only its contents are empty.
    let store = PaneStore()

    let snapshot = await store.snapshot(paneId: "db-1", kind: "db")

    #expect(snapshot.kind == "db")
    guard case .grid(let grid) = snapshot.contents else {
        Issue.record("expected an empty grid snapshot")
        return
    }
    #expect(grid.rowCount == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter PaneStore`
Expected: FAIL — `snapshot(paneId:kind:)` does not exist; `PaneSnapshot` is not a type.

- [ ] **Step 3: Write the typed union**

Create `app/Sources/WakilKit/Panes/PaneSnapshot.swift`:

```swift
import Foundation

/// What one pane is currently showing, as a **discriminated union keyed by
/// `kind`** (Decision 24).
///
/// **`kind` is the `Pane.kinds` string verbatim, and it is always
/// present** — `nil` only for a pane id nothing on the canvas holds, which
/// serialises as an explicit `null`. Every key *of that kind* is always
/// present too, including when false, empty or null: the rule
/// `PaneStore.snapshot` has carried since 2a, unchanged in purpose and
/// narrowed in scope. This object is read by an LLM, and an absent key is
/// something a reader has to know how to interpret while an explicit value
/// is an answer.
///
/// **`failure` is the one kind-independent key**, because any pane can
/// fail to produce what it was asked for.
///
/// **Why this is typed rather than the `JSONValue` it used to be.** The
/// view drew the screen by re-parsing the agent-facing JSON, for every
/// pane on every change. A flat superset was the alternative and it
/// compounds: a terminal pane under one key set would assert
/// `columnTypesInferred: false`, `pageable: false`, `listsTables: false`
/// and eleven more — thirteen tabular facts true only by accident — and
/// every kind added would widen every pane's snapshot for every reader,
/// permanently. A typed union lets the compiler check the arms, and keeps
/// what the round trip was really buying: one sort, applied once, so the
/// agent's rows and the screen's rows are one sequence.
public struct PaneSnapshot: Sendable, Equatable {
    public let kind: String?
    public let failure: String?
    public let contents: PaneSnapshotContents

    public init(kind: String?, failure: String?, contents: PaneSnapshotContents) {
        self.kind = kind
        self.failure = failure
        self.contents = contents
    }
}

/// One arm per pane kind, plus the arm for a pane id nothing holds.
///
/// **`.none` is not an error state.** A pane comes into existence in
/// `LayoutStore`, and a pane that exists but has never been written to is
/// `.grid` (or `.terminal`) with everything empty — see
/// `PaneStore.snapshot(paneId:kind:)`. `.none` is reserved for an id the
/// layout does not hold at all, which is the case a pane closing between
/// two of an agent's calls produces, and which must not turn a correct
/// sequence into a failure.
public enum PaneSnapshotContents: Sendable, Equatable {
    case none
    case grid(GridSnapshot)
    case terminal(TerminalSnapshot)
}

/// The tabular pane's readable state — exactly the fields `read_pane` has
/// served since 2c-i, with the same meanings and the same order.
///
/// Every row index here — in `selection`, in `scrollTarget`, and in `rows`
/// itself — is an index into the order currently DISPLAYED, and `sort` is
/// what changes that order.
public struct GridSnapshot: Sendable, Equatable {
    public let columns: [String]
    public let columnTypes: [String]
    public let columnTypesInferred: Bool
    public let rows: [[JSONValue]]
    public let rowCount: Int
    public let millis: Int64
    public let truncated: Bool
    public let pageable: Bool
    public let offset: Int
    public let selection: PaneSelection
    public let sort: [PaneSort]
    public let scrollTarget: Int?
    public let listsTables: Bool
    /// `table`, `keyColumns` and `columns` only — never `rowKeys`.
    /// `read_pane` feeds an LLM's context, and five hundred WHERE
    /// fragments buy nothing the key column does not already show.
    public let editable: PaneEditableSummary?

    public static let empty = GridSnapshot(
        columns: [], columnTypes: [], columnTypesInferred: false, rows: [], rowCount: 0,
        millis: 0, truncated: false, pageable: false, offset: 0, selection: .empty,
        sort: [], scrollTarget: nil, listsTables: false, editable: nil)

    public init(
        columns: [String], columnTypes: [String], columnTypesInferred: Bool,
        rows: [[JSONValue]], rowCount: Int, millis: Int64, truncated: Bool, pageable: Bool,
        offset: Int, selection: PaneSelection, sort: [PaneSort], scrollTarget: Int?,
        listsTables: Bool, editable: PaneEditableSummary?
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnTypesInferred = columnTypesInferred
        self.rows = rows
        self.rowCount = rowCount
        self.millis = millis
        self.truncated = truncated
        self.pageable = pageable
        self.offset = offset
        self.selection = selection
        self.sort = sort
        self.scrollTarget = scrollTarget
        self.listsTables = listsTables
        self.editable = editable
    }
}

/// What the agent is told about writing a pane back — the three facts
/// worth its context, without the per-row WHERE fragments.
public struct PaneEditableSummary: Sendable, Equatable {
    public let table: String
    public let keyColumns: [String]
    public let columns: [String]

    public init(table: String, keyColumns: [String], columns: [String]) {
        self.table = table
        self.keyColumns = keyColumns
        self.columns = columns
    }
}

/// Declared here and produced in Task 8 — a placeholder would be a lie, so
/// this type is written in full when the terminal's contents exist. See
/// `Terminal/TerminalBlock.swift`.
```

> The `TerminalSnapshot` type itself is added in **Task 8**. For this task, define it as an empty placeholder struct with `public init() {}` in `PaneSnapshot.swift` so `PaneSnapshotContents` compiles, and delete the placeholder in Task 8 when the real one lands. Mark it:
> ```swift
> /// PLACEHOLDER, replaced in Task 8. Nothing constructs it yet.
> public struct TerminalSnapshot: Sendable, Equatable { public init() {} }
> ```

- [ ] **Step 4: Write the wire form, at the MCP boundary**

Create `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift`:

```swift
import Foundation

/// The **only** place a `PaneSnapshot` becomes JSON.
///
/// **Why here and not on the store.** Until 2c-iii the store returned
/// `JSONValue` and the window re-parsed it to draw the screen —
/// `paneTable(from:)`, once per pane per change. What that round trip was
/// actually buying is that one sort is applied once, at the store, so the
/// agent's rows and the screen's rows are one sequence (2c-i final review,
/// Finding 1); a typed value satisfies that identically while letting the
/// compiler check the union. What it cost was a hand-written JSON parser
/// in the window whose failure mode is a silently empty pane — the symptom
/// this app is worst at surfacing.
///
/// Every key of the snapshot's own kind is emitted, including when false,
/// empty or null.
public func paneSnapshotJSON(_ snapshot: PaneSnapshot) -> JSONValue {
    var object: [String: JSONValue] = [
        "kind": snapshot.kind.map { .string($0) } ?? .null,
        "failure": snapshot.failure.map { .string($0) } ?? .null,
    ]
    switch snapshot.contents {
    case .none:
        break
    case .grid(let grid):
        object["columns"] = .array(grid.columns.map { .string($0) })
        object["columnTypes"] = .array(grid.columnTypes.map { .string($0) })
        object["columnTypesInferred"] = .bool(grid.columnTypesInferred)
        object["rows"] = .array(grid.rows.map { .array($0) })
        object["rowCount"] = .number(Double(grid.rowCount))
        object["millis"] = .number(Double(grid.millis))
        object["truncated"] = .bool(grid.truncated)
        object["pageable"] = .bool(grid.pageable)
        object["offset"] = .number(Double(grid.offset))
        object["selection"] = .object([
            "anchorRow": grid.selection.anchorRow.map { .number(Double($0)) } ?? .null,
            "anchorColumn": grid.selection.anchorColumn.map { .string($0) } ?? .null,
            "rows": .array(grid.selection.rows.sorted().map { .number(Double($0)) }),
        ])
        object["sort"] = .array(grid.sort.map {
            .object(["column": .string($0.column), "direction": .string($0.direction.rawValue)])
        })
        object["scrollTarget"] = grid.scrollTarget.map { .number(Double($0)) } ?? .null
        object["listsTables"] = .bool(grid.listsTables)
        if let editable = grid.editable {
            object["editable"] = .object([
                "table": .string(editable.table),
                "keyColumns": .array(editable.keyColumns.map { .string($0) }),
                "columns": .array(editable.columns.map { .string($0) }),
            ])
        }
    case .terminal:
        break  // Task 8.
    }
    return .object(object)
}
```

- [ ] **Step 5: Make `PaneStore.Contents` an enum and `snapshot` typed**

In `app/Sources/WakilKit/Panes/PaneStore.swift`:

1. Rename the existing `private struct Contents` to `private struct GridContents`, unchanged field for field, and introduce:

```swift
    /// What a pane holds, by kind.
    ///
    /// **One store, one enum, one `snapshot` that switches** (Decision
    /// 24). A second store for the terminal would re-implement everything
    /// this one earns its keep on and that a terminal needs identically:
    /// project-keyed contents (2c-i final review Finding 6, where one
    /// project's `db-1` answered with another project's rows),
    /// `switchProject`, and §13's requirement that a pane's state stays
    /// warm across a project switch — and a shell the operator left
    /// running is the most warm-state thing on the canvas.
    ///
    /// **Only the live OS resource is elsewhere.** The pty master fd, the
    /// child pid and the drain thread live in `TerminalStore`, because no
    /// `deinit` in `WakilKit` releases an OS resource and a cleared
    /// dictionary does not kill a shell — `close(2)` on a pty master
    /// blocks forever while a thread is parked in `read(2)`.
    private enum Contents {
        case grid(GridContents)
        case terminal(TerminalContents)
    }
```

2. `TerminalContents` is added in Task 8; for this task declare it as an empty struct beside `GridContents` with a `// Task 8` marker, so the enum compiles.

3. The private `panes` accessor is unchanged. Every existing mutator (`setRows`, `setSelection`, `reorder`, `setScrollTarget`, `setFailure`, …) gains one helper so its body is untouched:

```swift
    /// The grid contents for `paneId`, or a fresh empty set.
    ///
    /// **A pane that is not a grid answers with a fresh empty set and the
    /// write is discarded**, which is deliberately NOT how an agent
    /// reaches these: the five grid actions refuse a non-grid pane by name
    /// at the action layer (`registerPaneContentActions`), so the only way
    /// to arrive here with a terminal pane id is an internal caller that
    /// has already gone wrong. Silently corrupting a terminal pane's
    /// contents would be worse than dropping the write.
    private func grid(_ paneId: String) -> GridContents {
        guard case .grid(let contents)? = panes[paneId] else { return GridContents() }
        return contents
    }

    private func setGrid(_ paneId: String, _ contents: GridContents) {
        if case .terminal? = panes[paneId] { return }
        panes[paneId] = .grid(contents)
    }
```

so e.g. `setSelection` becomes:

```swift
    public func setSelection(paneId: String, _ selection: PaneSelection) {
        var contents = grid(paneId)
        contents.selection = selection
        setGrid(paneId, contents)
    }
```

4. Replace `snapshot(paneId:)` wholesale:

```swift
    /// What `read_pane` returns, and what the view draws from.
    ///
    /// **`kind` is supplied by the caller, because this store is not the
    /// registry of panes and `LayoutStore` is.** That correction is the
    /// whole of Decision 24's wiring: `MCPSurface` has held `layout`
    /// beside `panes` since 2b-i, and `readPane` was simply handed only
    /// one of the two. Pass `nil` for an id the layout does not hold and
    /// the answer is `kind: null` — not an error, because a pane can close
    /// between the `read_layout` that named it and the `read_pane` that
    /// asks, and an error there would turn a correct sequence of calls
    /// into a failure.
    ///
    /// **Every key of the answered kind is always present**, including
    /// when false, empty or null. That rule is unchanged in purpose since
    /// 2a and narrowed in scope: it used to describe ONE shape, and this
    /// is now a union, so it is scoped to the kind. `failure` is the one
    /// kind-independent key, because any pane can fail to produce what it
    /// was asked for.
    ///
    /// **A pane that exists and has never been written to is not
    /// `.none`.** It answers with its own kind and an empty payload — the
    /// freshly launched window, drawing "no rows" before any query, is the
    /// common case of it.
    public func snapshot(paneId: String, kind: String?) -> PaneSnapshot {
        guard let kind else {
            return PaneSnapshot(kind: nil, failure: nil, contents: .none)
        }
        switch panes[paneId] {
        case .terminal(let contents):
            return PaneSnapshot(kind: kind, failure: contents.failure,
                                contents: .terminal(contents.snapshot()))
        case .grid(let contents):
            return PaneSnapshot(kind: kind, failure: contents.failure,
                                contents: .grid(contents.snapshot()))
        case nil:
            // Task 8 fills the terminal arm; until then an unwritten
            // terminal pane answers with an empty terminal payload.
            return PaneSnapshot(kind: kind, failure: nil,
                                contents: kind == "terminal"
                                    ? .terminal(TerminalSnapshot())
                                    : .grid(.empty))
        }
    }
```

with `GridContents.snapshot()` a private method building `GridSnapshot` from the fields, moved verbatim out of the old `snapshot(paneId:)` body.

- [ ] **Step 6: Make the window consume the typed value**

In `app/Sources/WakilKit/App/WindowModel.swift`:

1. Delete `public func paneTable(from snapshot: JSONValue) -> PaneTable` (`:162`) and everything it needed to decode, and add an initialiser in its place:

```swift
extension PaneTable {
    /// Projects a `GridSnapshot` into a drawable table.
    ///
    /// **This replaced `paneTable(from: JSONValue)`**, which re-parsed the
    /// agent-facing JSON once per pane per change. The parse is gone, not
    /// moved: the store hands back a typed value, so there is no shape
    /// this can fail to recognise and no silently empty pane to produce.
    public init(grid: GridSnapshot) {
        self.init(
            columns: zip(grid.columns, grid.columnTypes + Array(
                repeating: "", count: max(0, grid.columns.count - grid.columnTypes.count)))
                .map { PaneColumn(name: $0.0, type: $0.1) },
            columnTypesInferred: grid.columnTypesInferred,
            rows: grid.rows.enumerated().map { PaneRow(id: $0.offset, cells: $0.element.map(PaneCell.init)) },
            millis: grid.millis,
            truncated: grid.truncated,
            selection: grid.selection,
            sort: grid.sort,
            scrollTarget: grid.scrollTarget,
            pageable: grid.pageable,
            offset: grid.offset,
            failure: nil,
            listsTables: grid.listsTables)
    }
}
```

> `failure` is passed separately by `refreshPanes` from `PaneSnapshot.failure`, since it is kind-independent.

2. Rewrite `refreshPanes` to iterate the layout rather than the pane store, so every pane's kind is in hand:

```swift
    /// Re-reads every pane on the canvas out of `PaneStore`.
    ///
    /// **It iterates the LAYOUT, not `panes.paneIds()`.** The snapshot is
    /// a union keyed by kind and `LayoutStore` is the registry that knows
    /// each pane's kind — the same correction Decision 24 made to
    /// `read_pane`. Iterating the contents store would answer `kind: nil`
    /// for every pane, which is the one answer reserved for a pane that is
    /// not on the canvas at all.
    ///
    /// **It does not sort.** `PaneStore` already hands back rows in
    /// displayed order, so the agent's `read_pane` and the operator's
    /// screen see one ordering produced once (2c-i final review Finding 1).
    public func refreshPanes() async {
        var next: [String: PaneTable] = [:]
        var nextEditables: [String: PaneEditable] = [:]
        var nextTerminals: [String: TerminalSnapshot] = [:]
        for pane in await layout.snapshot().panes {
            let snapshot = await panes.snapshot(paneId: pane.id, kind: pane.kind)
            switch snapshot.contents {
            case .grid(let grid):
                var table = PaneTable(grid: grid)
                table.failure = snapshot.failure
                next[pane.id] = table
                if let editable = await panes.editable(paneId: pane.id) {
                    nextEditables[pane.id] = editable
                }
            case .terminal(let terminal):
                nextTerminals[pane.id] = terminal
            case .none:
                break
            }
        }
        tables = next
        editables = nextEditables
        terminalSnapshots = nextTerminals
    }
```

> `PaneTable.failure` becomes a `var`; `terminalSnapshots: [String: TerminalSnapshot]` is a new stored property (classify it in Task 13's tripwire pass as **org-derived**, beside `tables`). It stays empty until Task 8.

3. `public func terminal(_ paneId: String) -> TerminalSnapshot?` beside `table(_:)`, for the view.

- [ ] **Step 7: Serialise at the MCP boundary**

In `app/Sources/WakilKit/MCP/MCPServer.swift`, `readPane` keeps its signature for now (the layout is wired in Task 4) and serialises the typed value:

```swift
    let snapshot = await panes.snapshot(paneId: paneId, kind: "db")   // Task 4 replaces "db"
    let payload = paneSnapshotJSON(snapshot)
```

with `payload` used where `snapshot` was, for both `content` and `structuredContent`.

- [ ] **Step 8: Run the suite**

Run: `make app-test`
Expected: PASS. `PaneStoreTests` compiles against the new helper; `MCPServerTests:95`'s `await panes.snapshot(paneId: "db")` needs `kind: "db"` and a `paneSnapshotJSON` hop; `MCPServerTests:192`'s empty-snapshot test asserts `kind: null` now.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/WakilKit/Panes/PaneSnapshot.swift app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift app/Sources/WakilKit/Panes/PaneStore.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/MCP/MCPServer.swift app/Tests/WakilKitTests
git commit -m "refactor: a pane's readable state is a typed union keyed by kind

Decision 24's storage half. JSON moves to the MCP boundary and the view
stops re-parsing the agent's JSON to draw the screen."
```

---

## Task 4: `read_pane` is handed the layout, and two doc comments stop being false

The one-line wiring change the whole of Decision 24 rests on, plus the two owed doc comments that live on this file.

**Files:**
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` (`readPane`'s signature and call site; `readPaneToolListEntry`'s description; the unknown-pane justification)
- Test: `app/Tests/WakilKitTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `PaneStore.snapshot(paneId:kind:)`, `paneSnapshotJSON(_:)` (Task 3).
- Produces: `readPane(id:arguments:panes:layout:)`; `read_pane` results carrying `kind`.

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/MCPServerTests.swift`:

```swift
@Test func readPaneReportsThePanesKindFromTheLayoutRatherThanGuessing() async {
    let registry = ActionRegistry(journalDirectory: scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let opened = await layout.open(kind: "db", title: "customers")
    let surface = MCPSurface(registry: registry, panes: panes, layout: layout,
                             confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
            "name": .string("read_pane"),
            "arguments": .object(["paneId": .string(opened.id)]),
        ])),
        surface: surface, environment: { "staging" })

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"] else {
        Issue.record("no structuredContent")
        return
    }
    #expect(structured["kind"] == .string("db"))
    #expect(structured["rowCount"] == .number(0))
    #expect(structured["failure"] == .null)
}

@Test func readPaneOnAnIdTheCanvasDoesNotHoldAnswersKindNullRatherThanErroring() async {
    // A pane can close between the read_layout that named it and the
    // read_pane that asks. An error there turns a correct sequence of
    // calls into a failure.
    let surface = MCPSurface(
        registry: ActionRegistry(journalDirectory: scratchDirectory(), sessionId: "t"),
        panes: PaneStore(), layout: LayoutStore(), confirmations: ConfirmationBroker())

    let reply = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/call", params: .object([
            "name": .string("read_pane"),
            "arguments": .object(["paneId": .string("db-404")]),
        ])),
        surface: surface, environment: { "staging" })

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"] else {
        Issue.record("no structuredContent")
        return
    }
    #expect(reply?.error == nil)
    #expect(structured["kind"] == .null)
    // Not a grid with nothing in it — nothing at all.
    #expect(structured["rows"] == nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter readPane`
Expected: FAIL — `kind` is `"db"` for every id, including `db-404`.

- [ ] **Step 3: Hand `readPane` the layout**

In `app/Sources/WakilKit/MCP/MCPServer.swift`:

```swift
    if name == readPaneToolName {
        return await readPane(id: id, arguments: arguments,
                              panes: surface.panes, layout: surface.layout)
    }
```

```swift
private func readPane(
    id: JSONRPCID, arguments: JSONValue, panes: PaneStore, layout: LayoutStore
) async -> JSONRPCMessage {
    guard case .object(let obj) = arguments, case .string(let paneId)? = obj["paneId"] else {
        return JSONRPCMessage(id: id, error: JSONRPCError(
            code: -32602, message: "Invalid params: \"read_pane\" requires a string \"paneId\""))
    }

    // The discriminator, read off the registry that actually holds one.
    let kind = await layout.snapshot().panes.first { $0.id == paneId }?.kind
    let payload = paneSnapshotJSON(await panes.snapshot(paneId: paneId, kind: kind))
    ...
}
```

with the rest of the body unchanged except that `payload` replaces `snapshot` in both halves of the envelope.

- [ ] **Step 4: Rewrite the unknown-pane justification**

Replace the paragraph at `MCPServer.swift` beginning **"An unknown `paneId` gets an empty snapshot, not an error."**:

```swift
/// **An unknown `paneId` answers `kind: null`, not an error, and the
/// argument for that is not the one that used to be here.** The old
/// reasoning was that `PaneStore` has no registry of ids, so "unknown" and
/// "written to, then empty" are genuinely the same state. That is true of
/// `PaneStore` and **false of the window**: `LayoutStore` is a registry of
/// open panes and has been since 2b-i, which is why this function now
/// takes it. What was actually missing was never an error but a
/// discriminator, and `kind: null` supplies it without making `read_pane`
/// fail on the honest case the original reasoning protected — a freshly
/// launched window whose `db` pane draws "no rows" before any query, which
/// answers `kind: "db"` with an empty payload.
///
/// **Erroring is now genuinely available and is still declined**, on two
/// grounds. An MCP `isError` costs the agent a turn and teaches it nothing
/// the field does not. And a pane can close between the `read_layout` that
/// named it and the `read_pane` that asks — a race that would turn a
/// correct sequence of calls into a failure.
```

- [ ] **Step 5: Rewrite `read_pane`'s `tools/list` prose**

Replace `readPaneToolListEntry`'s `description` so it describes **both** shapes. The current text enumerates exactly the tabular fields, which stops being the whole truth the moment a second kind exists:

```swift
    "description": .string(
        "Read what a Wakil UI pane is currently showing. The result is a UNION keyed by "
        + "kind: read kind first, then only the keys belonging to that kind. kind is always "
        + "present, and is null when no pane on the canvas holds that id — which is not an "
        + "error, because a pane can close between the read_layout that named it and this "
        + "call. failure is the one key present for every kind: the error from whatever the "
        + "pane last tried to do, or null.\n"
        + "\n"
        + "kind \"db\" — a data surface. columns and, when the driver could say, columnTypes "
        + "alongside them (columnTypesInferred is true when those types were worked out from "
        + "the values rather than declared, which only happens for Mongo); rows and rowCount; "
        + "millis, how long the query behind them took; truncated, true when more rows matched "
        + "than were returned — treat a truncated pane as a partial answer, never as the whole "
        + "one; pageable, whether this pane can be asked for another page at all; listsTables, "
        + "true when a row's first cell names a table in this pane's own database and can be "
        + "opened as one — declared by the driver, never guessed from the shape of the rows; "
        + "offset, how many rows were skipped to produce the page currently shown; selection, "
        + "the operator's anchor cell and selected rows; sort, an ORDERED LIST of "
        + "{column, direction} terms — never null, empty when unsorted — where index 0 is the "
        + "primary key and each later term only breaks ties among rows already equal on every "
        + "earlier one; and scrollTarget, the row the pane was last asked to scroll into view, "
        + "or null. Every row index — in selection, in scrollTarget, and in rows itself — is an "
        + "index into the order currently DISPLAYED, and sort is what changes that order.\n"
        + "\n"
        + "kind \"terminal\" — an interactive shell. BOTH of its surfaces are returned, always: "
        + "screen says which one the operator is actually looking at (\"blocks\" or \"grid\"), "
        + "and the other is still readable — a pager holding the screen is exactly when you are "
        + "most likely to be asked what went wrong in the build behind it. blocks is the "
        + "history of finished commands, each with id, command, origin, exitCode, durationMs, "
        + "output and heldTheGrid (true when a full-screen program owned the screen for its "
        + "duration). origin is \"operator\" for a command the operator submitted, \"agent\" for "
        + "one Wakil ran in its OWN bare-environment shell and is mirroring here, and "
        + "\"proposed\" for one you proposed that has not been accepted yet — which is how you "
        + "tell whether a proposal was taken, discarded, or is still sitting there. "
        + "blocksTruncated is true when the history has been trimmed to its cap: a short "
        + "history and a trimmed one must never be read alike. grid is the VISIBLE SCREEN ONLY, "
        + "never scrollback, bounded by cols and rows. cwd is the shell's live working "
        + "directory and shell is which shell is running.\n"
        + "\n"
        + "The grid-only actions (pane_select_cell, pane_select_rows, pane_set_column_width, "
        + "pane_scroll_to_row, pane_scroll_clear) refuse a terminal pane by name. Use "
        + "term_scroll for a terminal pane's history."),
```

- [ ] **Step 6: Run the suite, then commit**

Run: `make app-test`
Expected: PASS.

```bash
git add app/Sources/WakilKit/MCP/MCPServer.swift app/Tests/WakilKitTests/MCPServerTests.swift
git commit -m "feat: read_pane is handed the layout and reports each pane's kind

Decision 24's wiring. The unknown-pane justification is rewritten rather
than trimmed — its premise was falsified by LayoutStore being a registry."
```

---

## Task 5: The five grid actions refuse a pane that is not a grid, by name

Today they no-op into it: a selection and a scroll target are written into a store entry nothing draws, success comes back, and the agent believes it selected something. That is the `kind: "database"` incident's shape from a fourth cause.

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneContentActions.swift`
- Test: `app/Tests/WakilKitTests/PaneContentActionsTests.swift`

**Interfaces:**
- Consumes: `LayoutStore.snapshot()`; `Pane.kinds`.
- Produces: `PaneContentActionError.notAGridPane(action:pane:kind:)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func theFiveGridActionsRefuseATerminalPaneAndNameItsKind() async throws {
    let registry = ActionRegistry(journalDirectory: scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    let terminal = await layout.open(kind: "terminal", title: "~/orca")

    for (action, params) in [
        ("pane_select_cell", JSONValue.object(["pane": .string(terminal.id), "row": .number(0)])),
        ("pane_select_rows", .object(["pane": .string(terminal.id), "rows": .array([.number(0)])])),
        ("pane_set_column_width", .object(["pane": .string(terminal.id),
                                           "column": .string("id"), "width": .number(80)])),
        ("pane_scroll_to_row", .object(["pane": .string(terminal.id), "row": .number(0)])),
        ("pane_scroll_clear", .object(["pane": .string(terminal.id)])),
    ] {
        await #expect(throws: PaneContentActionError.self) {
            _ = try await registry.dispatch(
                name: action, params: params, origin: .agent,
                environment: "staging", confirmation: nil)
        }
        // The refusal names the KIND, so the agent learns which tool to
        // reach for rather than only that this one failed.
        do {
            _ = try await registry.dispatch(
                name: action, params: params, origin: .agent,
                environment: "staging", confirmation: nil)
        } catch let error as PaneContentActionError {
            #expect("\(error)".contains("terminal"))
            #expect("\(error)".contains(action))
        }
    }
}

@Test func aGridPaneIsUnaffectedAndAPaneTheLayoutDoesNotHoldStillWorks() async throws {
    // The second half is load-bearing: `--dispatch` and ~30 test call
    // sites register with a LayoutStore that holds nothing, and inventing
    // a refusal there would break every one of them.
    let registry = ActionRegistry(journalDirectory: scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    let db = await layout.open(kind: "db", title: "customers")

    _ = try await registry.dispatch(
        name: "pane_select_cell",
        params: .object(["pane": .string(db.id), "row": .number(2)]),
        origin: .agent, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "pane_select_cell",
        params: .object(["pane": .string("not-on-the-canvas"), "row": .number(2)]),
        origin: .agent, environment: "staging", confirmation: nil)

    #expect(await panes.snapshot(paneId: db.id, kind: "db").contents != .none)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter GridPane`
Expected: FAIL — every dispatch succeeds. (`"terminal"` must already be in `Pane.kinds` for `layout.open` to be reachable; if Task 9 has not landed, open with `kind: "terminal"` directly on the store, which does not validate.)

- [ ] **Step 3: Add the refusal**

At the head of `app/Sources/WakilKit/Panes/PaneContentActions.swift`:

```swift
/// The refusal these five actions owe a pane they cannot drive.
public enum PaneContentActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAGridPane(action: String, pane: String, kind: String)

    public var description: String {
        switch self {
        case .notAGridPane(let action, let pane, let kind):
            return "\(action): pane \"\(pane)\" is a \"\(kind)\" pane, and this action drives "
                + "a data surface — its row index is a position in a sorted order that a "
                + "\"\(kind)\" pane does not have. Read the pane to see what it is showing."
        }
    }
}

/// Refuses `paneId` when the canvas says it is not a grid.
///
/// **No-op'ing is what shipped before 2c-iii and it is a failure this
/// repository has already recorded from three causes.** An agent calling
/// `pane_select_cell` on a terminal id wrote a selection and a
/// `scrollTarget` into a `PaneStore` entry nothing draws and got a success
/// back.
///
/// **Reinterpreting the parameter was the interesting alternative and it
/// loses on one word.** `row` is documented three times over as a
/// zero-based index into a *displayed order that a sort changes*. A
/// terminal has no sort, so `row` would then mean a table row, a block, or
/// a terminal line depending on kind and current screen — three
/// incompatible meanings behind one name. `term_scroll` is the terminal's
/// own answer.
///
/// **A layout that does not hold the pane is not refused.** `--dispatch`
/// and the module's own tests register against a `LayoutStore` holding
/// nothing; inventing a failure there would break every one of them, and
/// `requireOpenPane` is what already refuses an id no pane holds where
/// that check belongs.
private func requireGridPane(_ paneId: String, action: String, layout: LayoutStore) async throws {
    guard let pane = await layout.snapshot().panes.first(where: { $0.id == paneId }),
          pane.kind != "db"
    else { return }
    throw PaneContentActionError.notAGridPane(action: action, pane: paneId, kind: pane.kind)
}
```

> Keyed on `!= "db"` rather than on a list of non-grid kinds: `"db"` is the only kind whose readable state is a grid, and a kind added later is refused by default rather than by remembering to add it here.

- [ ] **Step 4: Call it from all five handlers**

One line at the top of each handler, after the pane id is read:

```swift
            let pane = try requireString(params, "pane_select_cell" == ... )
            try await requireGridPane(pane, action: "pane_select_cell", layout: layout)
```

- [ ] **Step 5: Run the suite, then commit**

Run: `make app-test`
Expected: PASS.

```bash
git add app/Sources/WakilKit/Panes/PaneContentActions.swift app/Tests/WakilKitTests/PaneContentActionsTests.swift
git commit -m "feat: the five grid actions refuse a non-grid pane by name

Today's no-op writes a selection into a store nothing draws and returns
success — the shape of an incident this log has recorded three times."
```

---

## Task 6: `TerminalStore` — a real shell on a real PTY, opened and reaped

The one new seam in the sub-phase, and it is driven with a real shell from the first test. #38 measured the whole round trip at **0.073s** inside `swift test`, with 64 concurrent pty pairs opening without failure and no sandbox interference; the test process has no controlling terminal of its own and `openpty` still works.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalSession.swift`
- Create: `app/Sources/WakilKit/Terminal/TerminalStore.swift`
- Test: `app/Tests/WakilKitTests/TerminalStoreTests.swift`

**Interfaces:**
- Consumes: SwiftTerm's `Terminal`/`TerminalDelegate` (Task 2).
- Produces:
  - `actor TerminalStore` with `open(paneId:path:shell:) async throws -> TerminalOpened`, `write(paneId:bytes:)`, `resize(paneId:cols:rows:)`, `close(paneId:) async`, `shutdownAll() async`, `isRunning(paneId:) -> Bool`, `pidForTesting(paneId:) -> pid_t?`
  - `enum TerminalOpenError: Error, Equatable` — `.unsupportedShell(String)`, `.spawnFailed(String)`
  - `struct TerminalOpened { let shell: String; let cols: Int; let rows: Int; let cwd: String }`

- [ ] **Step 1: Write the failing tests**

Append to `app/Tests/WakilKitTests/TerminalStoreTests.swift`:

```swift
/// A real `bash` on a real pty: open, write, read the echo back, resize,
/// close, and assert the child is gone.
///
/// **Driven through the store rather than against a bare `forkpty`.** The
/// standing lesson is 2b-viii's walk: a test that calls a method the
/// shipped path does not call proves nothing about the shipped path.
@Test func aRealShellOpensEchoesResizesAndIsReapedOnClose() async throws {
    let store = TerminalStore()
    let opened = try await store.open(
        paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash")

    #expect(opened.shell == "bash")
    #expect(await store.isRunning(paneId: "terminal-1"))
    let pid = await store.pidForTesting(paneId: "terminal-1")
    #expect(pid != nil)

    await store.write(paneId: "terminal-1", bytes: Array("echo wakil-ok\n".utf8))
    try await waitUntil(seconds: 5) { await store.screenContains("terminal-1", "wakil-ok") }

    await store.resize(paneId: "terminal-1", cols: 100, rows: 40)
    #expect(await store.dimensions(paneId: "terminal-1")?.cols == 100)

    await store.close(paneId: "terminal-1")

    #expect(!(await store.isRunning(paneId: "terminal-1")))
    // The claim the sub-phase's fourth exit clause is: the child is
    // REAPED, not merely dereferenced. `kill(pid, 0)` answers ESRCH only
    // once the process is gone and waited for.
    #expect(kill(pid!, 0) == -1)
}

@Test func closingIsSingleFlightAndSafeToCallTwiceAndOnAPaneThatNeverOpened() async throws {
    let store = TerminalStore()
    _ = try await store.open(paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash")

    // Concurrently, and again afterwards. The shape MCPClient.stop()'s doc
    // comment records: two callers that both pass a `!= nil` check before
    // either has torn anything down left the first one's continuation
    // unresumed, hanging it permanently.
    async let first: Void = store.close(paneId: "terminal-1")
    async let second: Void = store.close(paneId: "terminal-1")
    _ = await (first, second)
    await store.close(paneId: "terminal-1")
    await store.close(paneId: "never-opened")

    #expect(!(await store.isRunning(paneId: "terminal-1")))
}

@Test func aShellStillProducingOutputIsKilledRatherThanWaitedFor() async throws {
    // The forgotten `tail -f`. Closing must not block on a child that has
    // no intention of stopping, and close(2) on the master must never
    // happen while the drain thread is parked in read(2) — measured
    // blocking forever, twice, process in state U (#38).
    let store = TerminalStore()
    _ = try await store.open(paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash")
    await store.write(paneId: "terminal-1", bytes: Array("yes wakil\n".utf8))
    try await waitUntil(seconds: 5) { await store.screenContains("terminal-1", "wakil") }

    let start = Date()
    await store.close(paneId: "terminal-1")

    #expect(Date().timeIntervalSince(start) < 3)
    #expect(!(await store.isRunning(paneId: "terminal-1")))
}

@Test func shutdownAllReapsEveryShellAndIsIdempotent() async throws {
    let store = TerminalStore()
    for id in ["terminal-1", "terminal-2", "terminal-3"] {
        _ = try await store.open(paneId: id, path: NSTemporaryDirectory(), shell: "/bin/bash")
    }

    await store.shutdownAll()
    await store.shutdownAll()

    for id in ["terminal-1", "terminal-2", "terminal-3"] {
        #expect(!(await store.isRunning(paneId: id)))
    }
}

@Test func anUnsupportedShellIsRefusedAtOpenRatherThanDegraded() async {
    // A degraded mode is a mode in which commands run outside the action
    // registry: without OSC 133 the shell owns the input line and nothing
    // journals a run. zsh and bash are named, the way Invariant 6 refuses
    // DDL by naming each verb.
    let store = TerminalStore()

    await #expect(throws: TerminalOpenError.unsupportedShell("/bin/fish")) {
        _ = try await store.open(
            paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/fish")
    }
}
```

plus a small helper in the same file:

```swift
/// Polls `condition` until it holds or `seconds` elapse. A shell's echo
/// arrives when it arrives; a fixed sleep either flakes or wastes the
/// 0.073s this whole round trip actually costs.
private func waitUntil(
    seconds: Double, _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("condition did not hold within \(seconds)s")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter TerminalStore`
Expected: FAIL — `TerminalStore` is not a type.

- [ ] **Step 3: Write `TerminalSession`**

Create `app/Sources/WakilKit/Terminal/TerminalSession.swift`:

```swift
import Foundation
import SwiftTerm
#if canImport(Darwin)
import Darwin
#endif

/// One shell: the pty master, the child, the drain thread, and the
/// SwiftTerm engine those bytes are fed into.
///
/// **A lock-guarded class, not an actor.** SwiftTerm's `Terminal` is not
/// thread-safe and the drain thread must feed it synchronously — an actor
/// would mean hopping the executor once per `read(2)`, which the pty caps
/// at 1,024 bytes regardless of the buffer offered (probe §6.3). One
/// `NSLock` around the engine, taken by the drain thread on `feed` and by
/// the poller on `getUpdateRange`, is the shape that keeps 78 MB/s.
///
/// **The drain thread parses inline and lets the pty block**, which is the
/// probe's correction to this spec's word "unbounded": the enqueue-and-
/// consume shape is 15% faster precisely *because* it cannot push back,
/// and it queued 18.33 MB during a 28 MB `cat` — a `cat` the operator does
/// by accident, scaling linearly with the file. Inline parsing cannot
/// exhaust memory at any size.
///
/// **A plain `Thread`, not a `readabilityHandler`** — measured at 1 useful
/// callback against 224,207 empty ones in the 300ms after EOF (#38). Same
/// shape as `ClaudeCodeCLIHarness.startStdoutDrainThread` and
/// `MCPClient`'s equivalent.
final class TerminalSession: @unchecked Sendable {
    let paneId: String
    let shellName: String
    private(set) var master: Int32 = -1
    private(set) var pid: pid_t = -1

    /// Guards `terminal`, `cols`, `rows` and (from Task 8) the blocks.
    let lock = NSLock()
    private let terminal: Terminal
    private let delegate: SessionDelegate
    private var drainThread: Thread?
    private(set) var cols: Int
    private(set) var rows: Int

    /// SwiftTerm's out-of-band events. It has **no content-change member
    /// at all** — the dirty range is polled, not pushed (probe §4.2) — so
    /// this carries only the alternate-screen switch, the OSC 7 cwd, the
    /// title, and bytes the engine wants written back to the pty.
    final class SessionDelegate: TerminalDelegate {
        var write: (@Sendable (ArraySlice<UInt8>) -> Void)?
        var onAlternateScreenChanged: (@Sendable (Bool) -> Void)?
        var onHostDirectory: (@Sendable (String) -> Void)?

        func send(source: Terminal, data: ArraySlice<UInt8>) { write?(data) }
        func bufferActivated(source: Terminal) {
            onAlternateScreenChanged?(source.isCurrentBufferAlternate)
        }
        func hostCurrentDirectoryUpdated(source: Terminal) {
            // `hostCurrentDirectory` hands back a raw URL —
            // `file://localhost/Users/…` — not a path (probe §4.4).
            guard let raw = source.hostCurrentDirectory,
                  let url = URL(string: raw) else { return }
            onHostDirectory?(url.path)
        }
    }

    init(paneId: String, shellName: String, cols: Int, rows: Int) {
        self.paneId = paneId
        self.shellName = shellName
        self.cols = cols
        self.rows = rows
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        // Wakil's own block cap is what bounds the history; this bounds
        // only what a full-screen program can scroll back through.
        options.scrollback = 2_000
        let delegate = SessionDelegate()
        self.delegate = delegate
        self.terminal = Terminal(delegate: delegate, options: options)
    }

    // MARK: - Spawning

    /// `forkpty` + `execv`, never `posix_spawn`.
    ///
    /// **Ctrl-C working for arbitrary programs depends on this choice.**
    /// `posix_spawn` with a new session leaves the tty's foreground process
    /// group at 0 and the parent cannot set it; `^C` to a `posix_spawn`'d
    /// `cat` did nothing in measurement, while `forkpty` sets the group for
    /// any child and the signal lands (#38).
    func spawn(
        argv: [String], environment: [String: String], cwd: String
    ) -> Bool {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { return false }
        if child == 0 {
            // **The mask, not only the dispositions.** libdispatch worker
            // threads block SIGINT, SIGWINCH, SIGTERM, SIGHUP and SIGCHLD;
            // the mask is inherited across exec, and this runs from an
            // actor method, so the app inherits exactly the mask a test
            // does. Resetting dispositions alone leaves ^C dead.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            for signalNumber in [SIGINT, SIGWINCH, SIGTERM, SIGHUP, SIGCHLD, SIGPIPE] {
                signal(signalNumber, SIG_DFL)
            }
            _ = chdir(cwd)
            for (key, value) in environment { setenv(key, value, 1) }
            var arguments = argv.map { strdup($0) }
            arguments.append(nil)
            _ = execv(argv[0], &arguments)
            _exit(127)
        }
        master = fd
        pid = child
        delegate.write = { [weak self] data in self?.writeToPty(Array(data)) }
        startDraining()
        return true
    }

    private func startDraining() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(self.master, $0.baseAddress, 65_536)
                }
                if count <= 0 { break }
                self.consume(buffer[0..<count])
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
        drainThread = thread
    }

    /// Everything the pty produced, fed to the engine under the lock.
    ///
    /// **Bytes are not coalesced before the parser.** Chunk size does not
    /// move the parse rate (73–77 MB/s plain, 55–60 SGR, flat from 1 KB to
    /// 1 MB) and the pty caps reads at 1,024 bytes regardless (probe §6.3).
    /// Coalescing before *drawing* is what the frame-rate poll does.
    ///
    /// Task 8 adds the mark scan here, alongside the feed.
    private func consume(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        terminal.feed(buffer: bytes)
        lock.unlock()
    }

    func writeToPty(_ bytes: [UInt8]) {
        guard master >= 0, !bytes.isEmpty else { return }
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard master >= 0, newCols > 0, newRows > 0 else { return }
        var size = winsize(
            ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        lock.lock()
        cols = newCols
        rows = newRows
        terminal.resize(cols: newCols, rows: newRows)
        lock.unlock()
        // The shell redraws its prompt for the new width when it is told.
        if pid > 0 { kill(pid, SIGWINCH) }
    }

    /// **kill → EOF → close, and never close while a read is parked.**
    /// That ordering is a rule, not a detail: `close(2)` on a pty master
    /// blocks forever while a thread sits in `read(2)` — reproduced twice,
    /// process in state `U` (#38). Killing first is what produces the EOF
    /// that ends the drain, which is why no self-pipe is needed: a child
    /// that is alive and silent is not a case this reaches, because the
    /// kill comes first.
    ///
    /// Synchronous by design: it is called from one place, inside
    /// `TerminalStore`'s single-flight teardown task, which is what keeps
    /// it off the cooperative pool.
    func teardown() {
        if pid > 0 { kill(pid, SIGKILL) }
        while let thread = drainThread, !thread.isFinished { usleep(200) }
        drainThread = nil
        if master >= 0 { close(master); master = -1 }
        if pid > 0 {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            pid = -1
        }
    }

    // MARK: - Reading, for the poller and for tests

    func screenLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<rows).map {
            terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? ""
        }
    }

    /// Whether anything has been written since the last call, and the rows
    /// it touched — SwiftTerm's dirty range, which is the ONLY way it
    /// reports a content change.
    func takeUpdateRange() -> (startY: Int, endY: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = terminal.getUpdateRange() else { return nil }
        terminal.clearUpdateRange()
        return (range.startY, range.endY)
    }
}
```

- [ ] **Step 4: Write `TerminalStore`**

Create `app/Sources/WakilKit/Terminal/TerminalStore.swift`:

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Why a shell could not be opened.
public enum TerminalOpenError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedShell(String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .unsupportedShell(let shell):
            return "term_open: \(shell) is not a shell Wakil can run. This pane needs shell "
                + "integration to know where one command ends and the next begins — without "
                + "it the shell owns the input line and nothing journals a run at all — and "
                + "Wakil generates that integration for zsh and bash. Not a degraded mode: a "
                + "degraded mode is one in which commands run outside the action registry."
        case .spawnFailed(let detail):
            return "term_open: could not start a shell (\(detail))"
        }
    }
}

/// What `open` reports back about the shell it started.
public struct TerminalOpened: Sendable, Equatable {
    public let shell: String
    public let cols: Int
    public let rows: Int
    public let cwd: String
}

/// Every live PTY, keyed by pane id — and **only** the live resource.
///
/// **Why this is not `PaneStore`.** Their lifetimes are genuinely
/// identical: born at pane open, warm across a project switch, dead at
/// `pane_close`, dead at an org switch. It loses on one fact that is not
/// about terminals at all — **there is no `deinit` in `WakilKit` that
/// releases an OS resource, not one.** Every process and every descriptor
/// in this application is released by an explicit awaited stop. Putting a
/// PTY inside `PaneStore.Contents` would make `byProject = [:]` and
/// `drop(paneId:)` its release path: the first resource here whose release
/// depends on ARC, and the one where that is least survivable, because
/// `close(2)` on a pty master blocks forever while a thread is parked in
/// `read(2)`. **A cleared dictionary does not kill a shell, and here it
/// cannot be made to.**
///
/// **Modelled directly on `MCPClient`.** Teardown is single-flight per
/// pane, guarded by a task, so two concurrent closers cannot both pass a
/// `!= nil` check and have the second overwrite the first's completion —
/// the measured failure `MCPClient.stop()`'s doc comment records, which
/// hung the first caller permanently.
public actor TerminalStore {
    /// The shells Wakil generates integration for. Named, the way
    /// Invariant 6 refuses DDL by naming each verb rather than by
    /// omission.
    public static let supportedShells: Set<String> = ["zsh", "bash"]

    /// The shell a `term_open` that names none gets: the operator's own,
    /// falling back to the platform default. `$SHELL` is read from Wakil's
    /// process environment, which is the operator's login environment.
    public static func defaultShell(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment["SHELL"] ?? "/bin/zsh"
    }

    private var sessions: [String: TerminalSession] = [:]
    /// One per pane, cleared as teardown's last step so a later `open` on
    /// the same pane starts a fresh cycle rather than replaying this one.
    private var teardownTasks: [String: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?

    public init() {}

    /// Opens a shell at `path` for `paneId`.
    ///
    /// **An already-open pane is torn down first.** A pane holds exactly
    /// one shell — there are no tabs, and a second shell is a second pane
    /// — so a second `term_open` on the same pane replaces rather than
    /// leaks.
    @discardableResult
    public func open(
        paneId: String, path: String, shell: String = TerminalStore.defaultShell(),
        cols: Int = 80, rows: Int = 24,
        environment: [String: String] = [:]
    ) async throws -> TerminalOpened {
        let name = (shell as NSString).lastPathComponent
        guard Self.supportedShells.contains(name) else {
            throw TerminalOpenError.unsupportedShell(shell)
        }
        await close(paneId: paneId)

        let session = TerminalSession(paneId: paneId, shellName: name, cols: cols, rows: rows)
        // Task 7 replaces this argv with the rc-injecting one.
        guard session.spawn(argv: [shell, "-i"], environment: environment, cwd: path) else {
            throw TerminalOpenError.spawnFailed(shell)
        }
        sessions[paneId] = session
        return TerminalOpened(shell: name, cols: cols, rows: rows, cwd: path)
    }

    public func write(paneId: String, bytes: [UInt8]) {
        sessions[paneId]?.writeToPty(bytes)
    }

    public func resize(paneId: String, cols: Int, rows: Int) {
        sessions[paneId]?.resize(cols: cols, rows: rows)
    }

    public func isRunning(paneId: String) -> Bool { sessions[paneId] != nil }

    public func dimensions(paneId: String) -> (cols: Int, rows: Int)? {
        sessions[paneId].map { ($0.cols, $0.rows) }
    }

    /// TEST-ONLY: the child's pid, so a test can assert it was **reaped**
    /// rather than merely dereferenced. The fourth clause of this
    /// sub-phase's exit criterion is its least-defended claim, and a
    /// classification test cannot prove it.
    func pidForTesting(paneId: String) -> pid_t? {
        sessions[paneId].map(\.pid)
    }

    /// TEST-ONLY: whether the live screen currently contains `needle`.
    func screenContains(_ paneId: String, _ needle: String) -> Bool {
        sessions[paneId]?.screenLines().contains { $0.contains(needle) } ?? false
    }

    /// Kills one pane's shell and waits for it. Safe concurrently, twice,
    /// and on a pane that never opened.
    public func close(paneId: String) async {
        if let existing = teardownTasks[paneId] {
            await existing.value
            return
        }
        guard let session = sessions[paneId] else { return }
        let task = Task { await self.performTeardown(paneId, session) }
        teardownTasks[paneId] = task
        await task.value
    }

    private func performTeardown(_ paneId: String, _ session: TerminalSession) async {
        // Off the cooperative pool: `teardown()` blocks in `waitpid`, and
        // the pool is small and shared by every actor-isolated task in the
        // process. `MCPClient.waitForProcessExit`'s doc comment records
        // what starving it costs — one permanent hang killed after 75
        // seconds, with the child already exited.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                session.teardown()
                continuation.resume()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
        sessions[paneId] = nil
        teardownTasks[paneId] = nil
    }

    /// Every shell, gone. The org switch's third awaited clear and app
    /// quit's fifth line both land here.
    public func shutdownAll() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task {
            for paneId in self.sessions.keys.sorted() {
                await self.close(paneId: paneId)
            }
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }
}
```

- [ ] **Step 5: Run the terminal tests**

Run: `cd app && ../scripts/swift-test.sh --filter TerminalStore`
Expected: PASS, in well under a second per test.

- [ ] **Step 6: Run the whole suite, then commit**

Run: `make app-test`
Expected: PASS.

```bash
git add app/Sources/WakilKit/Terminal app/Tests/WakilKitTests/TerminalStoreTests.swift
git commit -m "feat: TerminalStore — a real shell on a real PTY, killed before it is closed

forkpty rather than posix_spawn, because ^C depends on it. The child's
signal MASK is reset, not only its dispositions. kill -> EOF -> close."
```

---

## Task 7: The generated rc, and the environment the shell carries

SwiftTerm *consumes* OSC 133 and nothing *emits* it, so the rc is Wakil's. Shell integration is load-bearing for the charter, not a nicety: the moment the shell owns the input line, Wakil sees keystrokes and never a submitted command, so `term_run` has no trigger and Invariant 2 fails at the window. OSC 133 `C` is what rescues it.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/ShellIntegration.swift`
- Modify: `app/Sources/WakilKit/Terminal/TerminalStore.swift` (argv, rc directory, environment)
- Test: `app/Tests/WakilKitTests/TerminalStoreTests.swift`

**Interfaces:**
- Consumes: `TerminalStore.open`, `TerminalSession.spawn` (Task 6).
- Produces:
  - `generatedRC(forShell: String) -> String`
  - `shellLaunch(shell: String, rcDirectory: URL) throws -> (argv: [String], environment: [String: String])`
  - `terminalChildEnvironment(org:project:environment:base:) -> [String: String]`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aRealBashEmitsWakilsMarksAroundACommandItRuns() async throws {
    // Asserted through the store against a LIVE shell, not against byte
    // fixtures. The parser is SwiftTerm's; what is worth asserting is that
    // a real shell plus Wakil's rc produces the marks the pane draws
    // blocks from.
    let store = TerminalStore()
    _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash")

    await store.write(paneId: "t", bytes: Array("printf hello; exit 7\n".utf8))
    try await waitUntil(seconds: 8) { await store.marksForTesting("t").contains {
        if case .commandEnd = $0 { return true } else { return false } } }

    let marks = await store.marksForTesting("t")
    #expect(marks.contains { if case .promptStart = $0 { return true } else { return false } })
    #expect(marks.contains { if case .promptEnd = $0 { return true } else { return false } })
    #expect(marks.contains { if case .commandStart(let c) = $0 { return c == "printf hello; exit 7" } else { return false } })
    // The exit code rides D;<code> and SwiftTerm does not retain it, so
    // capturing it is Wakil's — measured by feeding D;42 and finding
    // nothing at any public seam (probe §4.4).
    #expect(marks.contains { if case .commandEnd(let code) = $0 { return code == 7 } else { return false } })
}

@Test func aRealZshEmitsTheSameMarks() async throws {
    let store = TerminalStore()
    _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/zsh")
    await store.write(paneId: "t", bytes: Array("printf hello; exit 3\n".utf8))
    try await waitUntil(seconds: 8) { await store.marksForTesting("t").contains {
        if case .commandEnd(let code) = $0 { return code == 3 } else { return false } } }
    #expect(await store.marksForTesting("t").contains {
        if case .commandStart(let c) = $0 { return c == "printf hello; exit 3" } else { return false } })
}

@Test func aCdIsReportedAsTheShellsLiveWorkingDirectory() async throws {
    // OSC 7. The header carries the LIVE cwd, so a `cd` never leaves it
    // lying about where the shell actually is.
    let store = TerminalStore()
    _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash")

    await store.write(paneId: "t", bytes: Array("cd /usr/lib\n".utf8))

    try await waitUntil(seconds: 8) { await store.cwd(paneId: "t") == "/usr/lib" }
}

@Test func theShellCarriesTheActiveContextAndNotTheKeychain() {
    let environment = terminalChildEnvironment(
        org: "initech", project: "booking", environment: "staging",
        base: ["HOME": "/Users/x", "PATH": "/usr/bin", "AWS_PROFILE": "work"])

    #expect(environment["WAKIL_ORG"] == "initech")
    #expect(environment["WAKIL_PROJECT"] == "booking")
    #expect(environment["WAKIL_ENVIRONMENT"] == "staging")
    #expect(environment["TERM"] == "xterm-256color")
    // The operator's own login environment comes through — this is what
    // makes `aws`, `kubectl` and `docker` behave here as they do in
    // Terminal.app, and it is the opposite of the harness's four-variable
    // dictionary that the mirror's blocks ran under.
    #expect(environment["AWS_PROFILE"] == "work")
}

@Test func theShellIsLaunchedAsAnInteractiveLoginShellAndSourcesTheProfileChain() throws {
    // The one half of the PATH problem a test CAN hold. The symptom —
    // `which kubectl` failing in the bundled app — is invisible here,
    // because `swift test` runs from a terminal whose environment is
    // already correct. So what is pinned is the CAUSE: the login flag, and
    // the rc reaching the profile chain. Runbook check 3a walks the
    // symptom, in the bundle.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wakil-rc-\(UUID().uuidString)")

    let zsh = try shellLaunch(shell: "/bin/zsh", rcDirectory: directory, base: ["HOME": "/Users/x"])
    #expect(zsh.argv == ["/bin/zsh", "-il"])
    let zshRC = try String(contentsOf: directory.appendingPathComponent(".zshrc"), encoding: .utf8)
    #expect(zshRC.contains(".zprofile"))
    #expect(zshRC.contains(".zshrc"))

    let bash = try shellLaunch(shell: "/bin/bash", rcDirectory: directory, base: ["HOME": "/Users/x"])
    // bash ignores --rcfile for a login shell, so it is interactive and
    // sources the profile chain from Wakil's rc instead.
    #expect(bash.argv.contains("--rcfile"))
    #expect(!bash.argv.contains("-l"))
    let bashRC = try String(
        contentsOf: directory.appendingPathComponent("wakil-bashrc"), encoding: .utf8)
    #expect(bashRC.contains("/etc/profile"))
    #expect(bashRC.contains(".bash_profile"))
}

@Test func anEmptyContextMemberIsAbsentRatherThanAnEmptyString() {
    // Same rule `childProcessEnvironment` already holds itself to: absent
    // means unset, never the empty string, so a script testing `-n
    // "$WAKIL_ENVIRONMENT"` is told the truth.
    let environment = terminalChildEnvironment(
        org: "initech", project: "", environment: "", base: ["HOME": "/Users/x"])
    #expect(environment["WAKIL_PROJECT"] == nil)
    #expect(environment["WAKIL_ENVIRONMENT"] == nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter "Wakil's marks" --filter terminalChildEnvironment`
Expected: FAIL — no marks are emitted; `terminalChildEnvironment` is not a function.

> `marksForTesting`, `cwd(paneId:)` and the `TerminalStreamEvent` enum arrive in Task 8's scanner. **Write Task 8's scanner first if the executor prefers**; the two tasks are ordered this way because the rc is what makes the scanner have anything to find. If taken in this order, stub `marksForTesting` on the store as `[]` and let these five tests fail until Task 8 lands, running only the two environment tests here.

- [ ] **Step 3: Write the generated rc**

Create `app/Sources/WakilKit/Terminal/ShellIntegration.swift`:

```swift
import Foundation

/// The shell integration Wakil injects into every shell it opens.
///
/// **Wakil writes it because nothing else does.** SwiftTerm *consumes* OSC
/// 133 — `SemanticPrompt.swift` parses and stores the marks — and nothing
/// *emits* them. The shell has to, and no shell does by default.
///
/// **It is load-bearing for the charter, not a nicety.** Invariant 2 stops
/// holding by itself the moment the shell owns the input line: Wakil then
/// sees keystrokes, never a submitted command, so `term_run` has no
/// trigger and *"actions are the only mutation path"* fails at the window.
/// OSC 133 `C` is the report that rescues it.
///
/// **What each mark does here:**
/// - `A` — prompt start. Opens the region the operator types into.
/// - `B` — prompt end / input start, emitted from `PS1` itself.
/// - `C;wakil_cmd=<base64>` — a command started, carrying **the command
///   line**. The base64 is not decoration: a command containing `;`, a
///   newline or a `BEL` would otherwise end the sequence early, and the
///   command line is the one field here that is arbitrary operator text.
///   SwiftTerm parses `C` and `D` together and reads the remaining fields
///   as `k=`/click options, so an unknown key passes through it harmlessly
///   while Wakil's own scanner reads it.
/// - `D;<code>` — the command finished, carrying its exit code. **The code
///   reaches no public API of SwiftTerm** — confirmed by feeding `D;42`
///   and finding nothing (probe §4.4) — which is why Wakil scans the byte
///   stream for these itself rather than asking the terminal about them.
/// - OSC 7 — the live cwd, so a `cd` never leaves the header lying.
///
/// **The operator's own rc is sourced first**, so this pane is their shell
/// and not a stripped one. Wakil's hooks are installed after it, so an rc
/// that sets `PS1` cannot delete the `B` mark by running later.
public func generatedRC(forShell shell: String) -> String {
    switch shell {
    case "zsh": return zshRC
    case "bash": return bashRC
    default: return ""
    }
}

private let zshRC = #"""
# Generated by Wakil for one terminal pane. Not edited by hand; not read
# by anything but the shell this pane opened.

# The operator's own configuration first, under their real ZDOTDIR, so
# this pane is their shell. Restored afterwards so subshells behave.
if [ -n "$WAKIL_USER_ZDOTDIR" ]; then
  ZDOTDIR="$WAKIL_USER_ZDOTDIR"
else
  ZDOTDIR="$HOME"
fi
# BOTH files, and .zprofile is the one that matters in the shipped app.
# zsh reads /etc/zprofile itself for a login shell — that is where
# path_helper runs — but $ZDOTDIR/.zprofile is read from WAKIL's
# directory, not the operator's, so their own is sourced here by hand.
# Without this, `which kubectl` fails in Wakil.app and succeeds in every
# test, because a test inherits a terminal's environment and the bundled
# app inherits launchd's.
[ -r "$ZDOTDIR/.zprofile" ] && source "$ZDOTDIR/.zprofile"
[ -r "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"

__wakil_osc() { printf '\033]%s\007' "$1" }

__wakil_precmd() {
  local code=$?
  # D closes whatever C opened. The FIRST precmd of a session emits one
  # with no C before it; Wakil's scanner drops a D with no open block.
  __wakil_osc "133;D;$code"
  __wakil_osc "7;file://${HOST}${PWD}"
  __wakil_osc "133;A"
}

__wakil_preexec() {
  __wakil_osc "133;C;wakil_cmd=$(printf '%s' "$1" | base64 | tr -d '\n')"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __wakil_precmd
add-zsh-hook preexec __wakil_preexec

# %{...%} tells zsh these bytes occupy no columns, so the prompt's own
# width arithmetic is unaffected.
PS1="${PS1}%{$(printf '\033]133;B\007')%}"
"""#

private let bashRC = #"""
# Generated by Wakil for one terminal pane. See ShellIntegration.swift.

# `--rcfile` is ignored for a login shell, so this pane's bash is
# interactive-but-not-login and the profile chain is sourced by hand.
# /etc/profile is where path_helper runs; without it PATH in the bundled
# app is launchd's and /opt/homebrew/bin is missing.
[ -r /etc/profile ] && . /etc/profile
for __wakil_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -r "$__wakil_profile" ]; then . "$__wakil_profile"; break; fi
done
unset __wakil_profile
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"

__wakil_osc() { printf '\033]%s\007' "$1"; }
__wakil_in_block=0

__wakil_precmd() {
  local code=$?
  __wakil_osc "133;D;$code"
  __wakil_in_block=0
  __wakil_osc "7;file://${HOSTNAME}${PWD}"
  __wakil_osc "133;A"
}

# The DEBUG trap fires for EVERY simple command, including each stage of a
# pipeline and the prompt command itself. The flag is what makes one
# submitted command one block: the first command after a prompt opens it,
# and precmd closes it.
__wakil_preexec() {
  [ -n "$COMP_LINE" ] && return
  [ "$__wakil_in_block" = "1" ] && return
  case "$BASH_COMMAND" in __wakil_*) return ;; esac
  __wakil_in_block=1
  __wakil_osc "133;C;wakil_cmd=$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
}

PROMPT_COMMAND='__wakil_precmd'
trap '__wakil_preexec' DEBUG

# \[...\] is bash's zero-width marker, the counterpart of zsh's %{...%}.
PS1="${PS1}\[$(printf '\033]133;B\007')\]"
"""#

/// The argv and the extra environment for one shell, given a directory
/// Wakil has already written the generated rc into.
///
/// **zsh and bash take the rc by different routes**, and neither is
/// optional. zsh reads `$ZDOTDIR/.zshrc` for an interactive shell, so the
/// rc is written as `.zshrc` in a Wakil-owned directory and the operator's
/// real `ZDOTDIR` is passed through for the rc itself to restore. bash has
/// `--rcfile`, which is simpler and does the same job.
public func shellLaunch(
    shell: String, rcDirectory: URL,
    base: [String: String] = ProcessInfo.processInfo.environment
) throws -> (argv: [String], environment: [String: String]) {
    let name = (shell as NSString).lastPathComponent
    try FileManager.default.createDirectory(at: rcDirectory, withIntermediateDirectories: true)
    switch name {
    case "zsh":
        let rc = rcDirectory.appendingPathComponent(".zshrc")
        try generatedRC(forShell: "zsh").write(to: rc, atomically: true, encoding: .utf8)
        var environment: [String: String] = ["ZDOTDIR": rcDirectory.path]
        environment["WAKIL_USER_ZDOTDIR"] = base["ZDOTDIR"] ?? base["HOME"]
        // `-il`, not `-i`: an interactive LOGIN shell, which is what
        // Terminal.app runs and what makes `/etc/zprofile` — and
        // therefore `path_helper` — run at all. See
        // `terminalChildEnvironment` for why the base environment cannot
        // be relied on to carry PATH in the shipped app.
        return ([shell, "-il"], environment)
    case "bash":
        let rc = rcDirectory.appendingPathComponent("wakil-bashrc")
        try generatedRC(forShell: "bash").write(to: rc, atomically: true, encoding: .utf8)
        return ([shell, "--rcfile", rc.path, "-i"], [:])
    default:
        throw TerminalOpenError.unsupportedShell(shell)
    }
}

/// The environment one terminal pane's shell carries.
///
/// **It is Wakil's own process environment, plus the active context — and
/// the process environment is NOT the operator's login environment.** In a
/// bundled `Wakil.app` it is launchd's: no `/opt/homebrew/bin`, no
/// `AWS_PROFILE`, no `KUBECONFIG`. What reconstructs the operator's
/// environment is the **shell**, which is spawned as an interactive login
/// shell and sources their own profile chain from the generated rc —
/// exactly how Terminal.app gets there, and the reason `shellLaunch`
/// passes `-il`.
///
/// **That distinction is a shipped-artefact defect waiting to happen.**
/// Every test here inherits a terminal's environment, because `swift test`
/// runs from one, so a `-i` shell passes every test and ships with a PATH
/// that cannot find `kubectl`. Measure the build that ships.
///
/// The glossary says this pane carries *"the active environment's
/// variables and the org's credentials"*, and there is no literal referent
/// to copy: `wakilcore.Environment` is `{databases, api}` and the
/// capability layer holds no environment-variable map at all. The three
/// `WAKIL_*` variables are what make the shell aware of the context the
/// rest of the window resolves against.
///
/// **Keychain secrets are deliberately not exported, and the reason is
/// that they would not help.** The residue this pane exists for is
/// `kubectl get pods`, `aws s3 ls` and `docker ps` — named by #39 — and
/// every one of them authenticates from `~/.kube/config`,
/// `~/.aws/credentials` or the Docker socket. **Not one of them has ever
/// read `wakil:<org>:<ref>`**: those entries are DSNs and API credentials
/// consumed by `wakil-db` and `wakil-http`. So exporting them buys nothing
/// for the commands this pane is for, while widening Invariant 4's
/// boundary — which that invariant requires to be structurally
/// impossible to cross, not merely uncrossed.
///
/// Two further facts close it. There are **no names to export under**:
/// secrets are keyed by ref (`booking-staging-mysql`), no
/// variable-name convention exists anywhere, and inventing
/// `WAKIL_SECRET_<REF>` in Swift is the second implementation of a Go rule
/// that `resolve.go`'s own doc comment refuses. And it would be
/// **partial**: only the refs the active environment's `Databases` name
/// are enumerable at all, and a half-populated secret environment reads as
/// a complete one.
///
/// A *deliberate* way to fetch one credential in this pane — rather than
/// an ambient one — is the honest version of the idea, and it belongs
/// beside `wakil secrets set-api` in 2c-iv rather than here.
///
/// **This is still the opposite of the agent's shell**, which is the whole
/// reason no agent-reachable run ships: the harness builds its child
/// environment from nothing but `CLAUDE_CONFIG_DIR`,
/// `CLAUDE_CODE_OAUTH_TOKEN`, `HOME` and `PATH`.
public func terminalChildEnvironment(
    org: String, project: String, environment: String,
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var result = base
    // Absent means unset, never the empty string — the rule
    // `WakilWiring.childProcessEnvironment` already holds itself to.
    if !org.isEmpty { result["WAKIL_ORG"] = org }
    if !project.isEmpty { result["WAKIL_PROJECT"] = project }
    if !environment.isEmpty { result["WAKIL_ENVIRONMENT"] = environment }
    result["TERM"] = "xterm-256color"
    // COLUMNS/LINES are deliberately NOT set: the winsize on the pty is
    // the authority, and a stale pair in the environment is exactly how a
    // resized pane starts drawing at the wrong width.
    result.removeValue(forKey: "COLUMNS")
    result.removeValue(forKey: "LINES")
    return result
}
```

- [ ] **Step 4: Launch through it**

In `TerminalStore.open`, replace the placeholder argv:

```swift
        let rcDirectory = Self.rcDirectory(for: paneId)
        let launch: (argv: [String], environment: [String: String])
        do {
            launch = try shellLaunch(shell: shell, rcDirectory: rcDirectory)
        } catch {
            throw TerminalOpenError.spawnFailed("\(error)")
        }
        var childEnvironment = environment
        for (key, value) in launch.environment { childEnvironment[key] = value }

        let session = TerminalSession(paneId: paneId, shellName: name, cols: cols, rows: rows)
        guard session.spawn(argv: launch.argv, environment: childEnvironment, cwd: path) else {
            throw TerminalOpenError.spawnFailed(shell)
        }
```

with

```swift
    /// A per-pane directory under the process's temporary directory,
    /// removed at teardown. Per pane rather than per app because zsh takes
    /// its rc by `ZDOTDIR`, which is a directory, and two panes sharing
    /// one would make a future per-pane rc impossible to add.
    private static func rcDirectory(for paneId: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wakil-terminal-\(paneId)")
    }
```

and, in `performTeardown`, after the session is torn down:

```swift
        try? FileManager.default.removeItem(at: Self.rcDirectory(for: paneId))
```

- [ ] **Step 5: Run the tests**

Run: `cd app && ../scripts/swift-test.sh --filter Terminal`
Expected: the two environment tests PASS. The four live-shell mark tests pass once Task 8's scanner lands.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Terminal app/Tests/WakilKitTests/TerminalStoreTests.swift
git commit -m "feat: a generated rc per shell, and the environment the pane's PTY carries

zsh and bash by name. An unsupported shell is refused at open, because a
degraded mode is one in which commands run outside the action registry."
```

---

## Task 8: Wakil's own mark scanner, over the raw byte stream

Wakil scans for the marks itself rather than asking the terminal about them, for three separate reasons, each measured: the exit code riding `D;<code>` reaches no public API; `C` and `D` are indistinguishable at every public seam; and **OSC 133 is discarded entirely under the alternate screen** (`oscSemanticPrompt` opens with `guard !isCurrentBufferAlternate`). The third is the one that earns the whole approach — scanning the raw stream is what makes User Story 16's *"four minutes in `vim` still leaves a block"* hold rather than rest on a mark landing outside the switch.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalMarkScanner.swift`
- Modify: `app/Sources/WakilKit/Terminal/TerminalSession.swift` (`consume`)
- Test: `app/Tests/WakilKitTests/TerminalMarkScannerTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum TerminalStreamEvent: Sendable, Equatable` — `.output([UInt8])`, `.promptStart`, `.promptEnd`, `.commandStart(command: String)`, `.commandEnd(exitCode: Int?)`, `.hostDirectory(String)`
  - `final class TerminalMarkScanner { func consume(_ bytes: ArraySlice<UInt8>) -> [TerminalStreamEvent] }`

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/WakilKitTests/TerminalMarkScannerTests.swift`:

```swift
import Testing
@testable import WakilKit

private func bytes(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }
private func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

@Test func theScannerFindsEachMarkAndKeepsTheOutputBetweenThem() {
    let scanner = TerminalMarkScanner()

    let events = scanner.consume(bytes(
        "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}"
        + "\u{1b}]133;C;wakil_cmd=\(base64("ls -la"))\u{07}"
        + "total 8\r\n"
        + "\u{1b}]133;D;0\u{07}"))

    #expect(events == [
        .promptStart,
        .output(Array("$ ".utf8)),
        .promptEnd,
        .commandStart(command: "ls -la"),
        .output(Array("total 8\r\n".utf8)),
        .commandEnd(exitCode: 0),
    ])
}

@Test func aMarkSplitAcrossTwoReadsIsStillFound() {
    // The pty caps reads at 1,024 bytes regardless of the buffer offered
    // (probe §6.3), so a mark landing on a boundary is the ordinary case,
    // not an exotic one. A scanner that could only see whole sequences
    // would lose blocks at random under load.
    let scanner = TerminalMarkScanner()

    var events = scanner.consume(bytes("out\u{1b}]133;D"))
    events += scanner.consume(bytes(";42\u{07}more"))

    #expect(events == [
        .output(Array("out".utf8)),
        .commandEnd(exitCode: 42),
        .output(Array("more".utf8)),
    ])
}

@Test func theExitCodeIsCapturedBecauseNothingElseCapturesIt() {
    // Fed D;42, SwiftTerm surfaces nothing at any public seam — it
    // switches on "C","D" together and reads the rest as k=/click options
    // (probe §4.4). This is the only place the code exists.
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;D;42\u{07}")) == [.commandEnd(exitCode: 42)])
    // A D with no code at all is a shell that did not say, not a zero.
    #expect(scanner.consume(bytes("\u{1b}]133;D\u{07}")) == [.commandEnd(exitCode: nil)])
}

@Test func anStTerminatorIsAcceptedAsWellAsABel() {
    // ESC \ is the other OSC terminator, and a shell or a program may use
    // either. Accepting only BEL would drop marks from anything that does.
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;A\u{1b}\\")) == [.promptStart])
}

@Test func osc7IsReportedAsAPathRatherThanAUrl() {
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]7;file://localhost/usr/lib\u{07}"))
            == [.hostDirectory("/usr/lib")])
}

@Test func anUnrelatedOscPassesThroughAsOutput() {
    // A title change is not this scanner's business, and swallowing it
    // would take bytes away from the engine that draws the screen.
    let scanner = TerminalMarkScanner()
    let title = "\u{1b}]0;a title\u{07}"
    #expect(scanner.consume(bytes(title)) == [.output(Array(title.utf8))])
}

@Test func aCommandLineContainingTheTerminatorSurvivesTheRoundTrip() {
    // Why the command line is base64 in the rc: a command holding a BEL, a
    // newline or a `;` would otherwise end the sequence early and Wakil
    // would draw half a command as the whole of one.
    let command = "printf 'a;b\\n' && echo \u{07}done"
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;C;wakil_cmd=\(base64(command))\u{07}"))
            == [.commandStart(command: command)])
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter TerminalMarkScanner`
Expected: FAIL — `TerminalMarkScanner` is not a type.

- [ ] **Step 3: Write the scanner**

Create `app/Sources/WakilKit/Terminal/TerminalMarkScanner.swift`:

```swift
import Foundation

/// What one chunk off the pty contained, in wire order.
///
/// `.output` is every byte that is not one of Wakil's own marks — which is
/// what a block's output is made of. The marks themselves are excluded
/// from it, because a block whose output began with the escape sequence
/// that opened it would draw its own plumbing.
///
/// **The whole raw chunk still reaches SwiftTerm regardless.** Feeding the
/// marks to the engine is harmless — it parses and discards them — and
/// stripping them would be a second, divergent view of the same bytes.
public enum TerminalStreamEvent: Sendable, Equatable {
    case output([UInt8])
    case promptStart
    case promptEnd
    case commandStart(command: String)
    case commandEnd(exitCode: Int?)
    case hostDirectory(String)
}

/// Finds Wakil's own OSC 133 and OSC 7 marks in the pty's byte stream.
///
/// **Wakil scans rather than asking the terminal, for three measured
/// reasons.** The exit code riding `D;<code>` reaches no public API of
/// SwiftTerm — confirmed by feeding `D;42` and finding nothing. `C` and
/// `D` are handled by one `switch` case there, so they are
/// indistinguishable at every public seam. And **OSC 133 is discarded
/// entirely under the alternate screen** (`oscSemanticPrompt` opens with
/// `guard !isCurrentBufferAlternate`), which is exactly the case User
/// Story 16 is about: four minutes in `vim` must still leave a block
/// carrying its command, duration and exit code. Scanning the raw stream
/// is what makes that true rather than dependent on where the mark lands.
///
/// **It is split-safe.** The pty caps reads at 1,024 bytes regardless of
/// the buffer offered (probe §6.3), so a mark straddling two reads is the
/// ordinary case. A partial sequence is carried into the next `consume`.
///
/// **A sequence that is not one of Wakil's passes through as output.** A
/// title change, a colour-palette query, anything else: swallowing it
/// would take bytes away from the engine that draws the screen.
public final class TerminalMarkScanner {
    /// Bytes held back because a sequence began and has not terminated.
    /// Bounded: an escape that never terminates must not become an
    /// unbounded buffer, and 4 KB is far past any real OSC.
    private var pending: [UInt8] = []
    private static let pendingCap = 4096

    public init() {}

    public func consume(_ bytes: ArraySlice<UInt8>) -> [TerminalStreamEvent] {
        var events: [TerminalStreamEvent] = []
        var output: [UInt8] = []
        var buffer = pending
        pending = []
        buffer.append(contentsOf: bytes)

        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x1B, index + 1 < buffer.count, buffer[index + 1] == 0x5D else {
                output.append(buffer[index])
                index += 1
                continue
            }
            // An OSC opened. Find its terminator: BEL, or ESC \.
            guard let terminator = terminatorIndex(in: buffer, from: index + 2) else {
                // Incomplete. Hold it — unless it has outgrown any real
                // sequence, in which case it was never one.
                let remainder = Array(buffer[index...])
                if remainder.count > Self.pendingCap {
                    output.append(contentsOf: remainder)
                } else {
                    pending = remainder
                }
                index = buffer.count
                break
            }
            let body = Array(buffer[(index + 2)..<terminator.start])
            if let event = event(from: body) {
                if !output.isEmpty { events.append(.output(output)); output = [] }
                events.append(event)
            } else {
                // Not ours. Pass the whole sequence through untouched.
                output.append(contentsOf: buffer[index..<terminator.end])
            }
            index = terminator.end
        }
        if !output.isEmpty { events.append(.output(output)) }
        return events
    }

    /// The terminator's start (where the body ends) and end (where the
    /// next byte after the sequence begins).
    private func terminatorIndex(
        in buffer: [UInt8], from start: Int
    ) -> (start: Int, end: Int)? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x07 { return (index, index + 1) }
            if buffer[index] == 0x1B, index + 1 < buffer.count, buffer[index + 1] == 0x5C {
                return (index, index + 2)
            }
            index += 1
        }
        return nil
    }

    private func event(from body: [UInt8]) -> TerminalStreamEvent? {
        let text = String(decoding: body, as: UTF8.self)
        if text == "133;A" { return .promptStart }
        if text == "133;B" { return .promptEnd }
        if text == "133;D" { return .commandEnd(exitCode: nil) }
        if text.hasPrefix("133;D;") {
            // The shell prints `$?`, so anything that is not an integer is
            // a shell that did not say rather than an exit code of zero.
            let field = text.dropFirst("133;D;".count).split(separator: ";").first ?? ""
            return .commandEnd(exitCode: Int(field))
        }
        if text.hasPrefix("133;C") {
            // `wakil_cmd=` may sit among other k=v fields SwiftTerm also
            // reads; find ours by name rather than by position.
            for field in text.dropFirst("133;C".count).split(separator: ";")
            where field.hasPrefix("wakil_cmd=") {
                let encoded = field.dropFirst("wakil_cmd=".count)
                if let data = Data(base64Encoded: String(encoded)) {
                    return .commandStart(command: String(decoding: data, as: UTF8.self))
                }
            }
            return .commandStart(command: "")
        }
        if text.hasPrefix("7;") {
            // `file://localhost/Users/…` — a URL, not a path (probe §4.4).
            let raw = String(text.dropFirst(2))
            guard let url = URL(string: raw), !url.path.isEmpty else { return nil }
            return .hostDirectory(url.path)
        }
        return nil
    }
}
```

- [ ] **Step 4: Wire it into the drain thread**

In `TerminalSession`, add the scanner and an event sink, and scan alongside the feed:

```swift
    private let scanner = TerminalMarkScanner()
    /// Called on the DRAIN THREAD, under no lock of the caller's. Task 9
    /// makes this the block recorder; until then it only feeds
    /// `marksForTesting` and the live cwd.
    var onStreamEvents: (@Sendable ([TerminalStreamEvent]) -> Void)?
    private(set) var cwd: String = ""

    private func consume(_ bytes: ArraySlice<UInt8>) {
        // The engine gets the WHOLE chunk, marks included — it parses and
        // discards them, and a second, divergent view of the same bytes is
        // the thing worth not having.
        lock.lock()
        terminal.feed(buffer: bytes)
        lock.unlock()

        let events = scanner.consume(bytes)
        guard !events.isEmpty else { return }
        for case .hostDirectory(let path) in events {
            lock.lock(); cwd = path; lock.unlock()
        }
        onStreamEvents?(events)
    }
```

and on `TerminalStore`, for the live-shell tests in Task 7:

```swift
    /// TEST-ONLY: every non-output event this pane's shell has emitted.
    func marksForTesting(_ paneId: String) -> [TerminalStreamEvent] {
        sessions[paneId]?.marksForTesting() ?? []
    }

    /// The shell's live working directory, from OSC 7 — empty until the
    /// first prompt.
    public func cwd(paneId: String) -> String { sessions[paneId]?.cwd ?? "" }
```

(with `TerminalSession.marksForTesting()` accumulating the non-`.output` events under the lock).

- [ ] **Step 5: Run the scanner tests and Task 7's live-shell tests**

Run: `cd app && ../scripts/swift-test.sh --filter Terminal`
Expected: PASS, including `aRealBashEmitsWakilsMarksAroundACommandItRuns`, `aRealZshEmitsTheSameMarks` and `aCdIsReportedAsTheShellsLiveWorkingDirectory` from Task 7.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Terminal app/Tests/WakilKitTests/TerminalMarkScannerTests.swift
git commit -m "feat: Wakil scans the pty stream for its own OSC 133 and OSC 7 marks

The exit code reaches no public API, C and D are one switch case, and OSC
133 is discarded outright under the alternate screen — which is exactly
the case a block must survive."
```

---

## Task 9: Blocks — captured at the `D` mark, capped, and published into `PaneStore`

The probe's sharpest correction lands here: **the block history cannot be derived from SwiftTerm's buffer**, because a mark dies with the row the scrollback cap evicts (6 gone at 200 commands, 207 at 400). Each block is captured as it completes, into Wakil's own storage, which is also the only place a per-block line cap can be applied.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalBlock.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneSnapshot.swift` (replace the placeholder `TerminalSnapshot`)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (`TerminalContents` and its writers)
- Modify: `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift` (the terminal arm)
- Modify: `app/Sources/WakilKit/Terminal/TerminalSession.swift`, `TerminalStore.swift` (recording and publishing)
- Test: `app/Tests/WakilKitTests/TerminalStoreTests.swift`, `PaneStoreTests.swift`

**Interfaces:**
- Consumes: `TerminalStreamEvent` (Task 8); `PaneSnapshot`/`paneSnapshotJSON` (Task 3).
- Produces:
  - `struct TerminalBlock { id, command, origin, exitCode, durationMs, output, heldTheGrid }`
  - `enum TerminalBlockOrigin: String { case operatorTyped = "operator", agent, proposed }`
  - `enum TerminalScreen: String { case blocks, grid }`
  - `struct TerminalSnapshot { screen, cwd, shell, cols, rows, blocks, blocksTruncated, grid }`
  - `PaneStore.recordTerminal(paneId:block:)`, `.setTerminalLiveState(paneId:cwd:shell:cols:rows:screen:grid:)`, `.terminalBlocks(paneId:)`
  - `TerminalStore.init(panes: PaneStore?)`

- [ ] **Step 1: Write the failing tests**

In `TerminalStoreTests.swift`:

```swift
@Test func aRealCommandBecomesABlockCarryingItsExitCodeAndDuration() async throws {
    let panes = PaneStore()
    let store = TerminalStore(panes: panes)
    _ = try await store.open(paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash")

    await store.write(paneId: "terminal-1", bytes: Array("printf 'a\\nb\\n'; exit 5\n".utf8))
    try await waitUntil(seconds: 8) { await panes.terminalBlocks(paneId: "terminal-1").count >= 1 }

    let block = await panes.terminalBlocks(paneId: "terminal-1")[0]
    #expect(block.command == "printf 'a\\nb\\n'; exit 5")
    #expect(block.origin == .operatorTyped)
    #expect(block.exitCode == 5)
    #expect(block.durationMs != nil)
    #expect(block.output.contains("a"))
    #expect(block.heldTheGrid == false)
}

@Test func aProgramThatTookTheScreenStillLeavesABlock() async throws {
    // User Story 16: four minutes in `vim` is not silently dropped from
    // the history. This works because Wakil scans the RAW stream — the
    // engine discards OSC 133 entirely under the alternate screen.
    let panes = PaneStore()
    let store = TerminalStore(panes: panes)
    _ = try await store.open(paneId: "terminal-1", path: NSTemporaryDirectory(), shell: "/bin/bash")

    // Enter the alternate screen, draw, leave — without needing vim.
    await store.write(paneId: "terminal-1",
                      bytes: Array("printf '\\033[?1049hhello\\033[?1049l'; exit 0\n".utf8))
    try await waitUntil(seconds: 8) { await panes.terminalBlocks(paneId: "terminal-1").count >= 1 }

    let block = await panes.terminalBlocks(paneId: "terminal-1")[0]
    #expect(block.heldTheGrid == true)
    #expect(block.exitCode == 0)
}

@Test func theHistoryIsBoundedInBlocksAndSaysSo() async {
    let panes = PaneStore()
    for index in 0..<(TerminalBlock.historyCap + 5) {
        await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
            id: "b\(index)", command: "echo \(index)", origin: .operatorTyped,
            exitCode: 0, durationMs: 1, output: ["\(index)"], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard case .terminal(let terminal) = snapshot.contents else {
        Issue.record("expected a terminal snapshot"); return
    }
    #expect(terminal.blocks.count == TerminalBlock.historyCap)
    // Partiality, carried beside the data rather than inferred from its
    // length: a short history and a trimmed one must never look alike.
    #expect(terminal.blocksTruncated)
    // The OLDEST go, not the newest.
    #expect(terminal.blocks.first?.command == "echo 5")
}

@Test func aBlocksOwnOutputIsCappedInLinesAndTheRestIsDropped() async {
    let long = (0..<(TerminalBlock.outputLineCap + 100)).map { "line \($0)" }
    let block = TerminalBlock.capped(
        id: "b1", command: "seq", origin: .operatorTyped, exitCode: 0, durationMs: 1,
        output: long, heldTheGrid: false, startedAt: Date())

    #expect(block.output.count == TerminalBlock.outputLineCap)
    // The TAIL is what is kept: the end of a build's output is where its
    // error is, and a head-truncated block would keep the part nobody is
    // asking about.
    #expect(block.output.last == "line \(TerminalBlock.outputLineCap + 99)")
}

@Test func theSnapshotReturnsBothSurfacesAndNamesTheOneOnScreen() async {
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/usr/lib", shell: "zsh", cols: 132, rows: 36,
        screen: .grid, grid: ["one", "two"])
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "b1", command: "make", origin: .operatorTyped, exitCode: 1, durationMs: 90,
        output: ["boom"], heldTheGrid: false, startedAt: Date()))

    let snapshot = await panes.snapshot(paneId: "terminal-1", kind: "terminal")
    guard case .terminal(let terminal) = snapshot.contents else {
        Issue.record("expected a terminal snapshot"); return
    }
    // Returning only the AUTHORITATIVE surface breaks the rule this
    // defends: an agent that read the blocks a moment ago would find them
    // gone because `vim` opened — exactly when it is most likely to be
    // asked what went wrong in the build behind the pager.
    #expect(terminal.screen == .grid)
    #expect(terminal.grid == ["one", "two"])
    #expect(terminal.blocks.count == 1)
    #expect(terminal.cwd == "/usr/lib")
    #expect(terminal.cols == 132)
}

@Test func theTerminalWireFormCarriesEveryKeyOfItsKind() async {
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "bash", cols: 80, rows: 24,
        screen: .blocks, grid: [])
    await panes.recordTerminal(paneId: "terminal-1", block: TerminalBlock(
        id: "b1", command: "ls", origin: .proposed, exitCode: nil, durationMs: nil,
        output: [], heldTheGrid: false, startedAt: Date()))

    guard case .object(let wire) = paneSnapshotJSON(
        await panes.snapshot(paneId: "terminal-1", kind: "terminal")),
          case .array(let blocks)? = wire["blocks"],
          case .object(let first) = blocks[0] else {
        Issue.record("bad wire form"); return
    }
    for key in ["kind", "failure", "screen", "cwd", "shell", "cols", "rows",
                "blocks", "blocksTruncated", "grid"] {
        #expect(wire[key] != nil, "missing \(key)")
    }
    for key in ["id", "command", "origin", "exitCode", "durationMs", "output", "heldTheGrid"] {
        #expect(first[key] != nil, "missing block key \(key)")
    }
    // `proposed` is what earns the field: without it the agent cannot tell
    // whether its own proposal was accepted, discarded, or still sitting
    // there — the single thing it most needs to read this pane for.
    #expect(first["origin"] == .string("proposed"))
    #expect(first["exitCode"] == .null)
    // And a terminal pane emits none of the thirteen tabular keys.
    #expect(wire["rows"] == nil)
    #expect(wire["columnTypesInferred"] == nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter Terminal`
Expected: FAIL — `TerminalBlock` is not a type.

- [ ] **Step 3: Write the block model**

Create `app/Sources/WakilKit/Terminal/TerminalBlock.swift`:

```swift
import Foundation

/// Who submitted the command a block records.
///
/// **`proposed` is what earns this field.** Without it in the snapshot the
/// agent cannot tell whether its own proposal was accepted, discarded, or
/// still sitting there — the single thing it most needs to read a terminal
/// pane for. `agent` is a command Wakil ran in its OWN bare-environment
/// shell and is mirroring here; it never ran in this pane's PTY.
public enum TerminalBlockOrigin: String, Sendable, Equatable, Codable {
    /// Spelled `operator` on the wire; `operator` is a Swift keyword.
    case operatorTyped = "operator"
    case agent
    case proposed
}

/// Which surface the operator is actually looking at.
public enum TerminalScreen: String, Sendable, Equatable, Codable {
    case blocks
    case grid
}

/// One submitted command and everything it produced — the terminal pane's
/// unit of state, and the granularity of one terminal action (§9).
///
/// **Captured at its `D` mark into Wakil's own storage, never
/// reconstructed from the emulator's buffer.** OSC 133 marks survive
/// *scrolling*; they do not survive *scrollback eviction*, and a block
/// whose opening mark has been trimmed cannot be recovered from the buffer
/// at all — 6 of 200 were already gone in measurement, 207 of 400 (probe
/// §4.1). Wakil had to scan for the marks itself anyway to recover the
/// exit code, so this is the same work rather than extra work.
public struct TerminalBlock: Sendable, Equatable, Identifiable {
    /// **200 blocks.** The bound is a memory question with numbers: ~112
    /// bytes per held output row measured, so 200 × a 500-line cap is
    /// ~18 MB per pane and 1,000 × 1,000 would be ~86 MB (probe §6.6).
    /// Neither is a drawing problem at any size measured — a `LazyVStack`'s
    /// scroll step is flat at ~5 ms from 2,050 rows to 500,500 — so the
    /// choice is made on memory, and a canvas holds several panes.
    /// Bounded in **blocks, not lines**, because *"the last 200 commands"*
    /// means something to an operator where *"10,000 lines"* does not.
    public static let historyCap = 200
    /// **500 lines inside each block.** The pane reports both bounds on
    /// screen; a trimmed history must never be mistaken for a short one.
    public static let outputLineCap = 500

    public let id: String
    public let command: String
    public let origin: TerminalBlockOrigin
    /// `nil` for a block still running, for a proposal that has not run,
    /// and for one closed by teardown before its shell reported.
    public let exitCode: Int?
    public let durationMs: Int?
    public let output: [String]
    /// True when a full-screen program owned the screen for this command's
    /// duration. The block still exists, carrying its command, duration
    /// and exit code — four minutes in `vim` is not silently dropped.
    public let heldTheGrid: Bool
    /// **Not published.** Ordering only: the mirror interleaves the
    /// agent's blocks with the operator's, and both arrive from different
    /// producers.
    public let startedAt: Date

    public init(
        id: String, command: String, origin: TerminalBlockOrigin, exitCode: Int?,
        durationMs: Int?, output: [String], heldTheGrid: Bool, startedAt: Date
    ) { ... }

    /// The same block with its output trimmed to `outputLineCap`.
    ///
    /// **The tail is kept, not the head.** The end of a build's output is
    /// where its error is; a head-truncated block keeps the part nobody is
    /// asking about.
    public static func capped(
        id: String, command: String, origin: TerminalBlockOrigin, exitCode: Int?,
        durationMs: Int?, output: [String], heldTheGrid: Bool, startedAt: Date
    ) -> TerminalBlock {
        TerminalBlock(
            id: id, command: command, origin: origin, exitCode: exitCode,
            durationMs: durationMs, output: Array(output.suffix(outputLineCap)),
            heldTheGrid: heldTheGrid, startedAt: startedAt)
    }
}
```

- [ ] **Step 4: Replace the placeholder `TerminalSnapshot`**

In `PaneSnapshot.swift`, delete the placeholder and write:

```swift
/// The terminal pane's readable state — **both** surfaces, always.
///
/// **`screen` names the one the operator is actually looking at**, and the
/// other is still returned. Returning only the authoritative surface
/// breaks the rule this exists to defend: an agent that read `blocks` a
/// moment ago would find them gone because `vim` opened — exactly the
/// moment it is most likely to be asked *"what went wrong in that
/// build"*, a question about history asked while a pager holds the screen.
///
/// **`grid` is the visible screen only, never scrollback**, bounded by
/// `cols` and `rows`. `snapshot` is not `read_pane`'s path alone — the
/// window refreshes every pane on every change — so an unbounded grid here
/// would be paid for on every keystroke. History lives in `blocks`, where
/// the block cap already bounds it.
///
/// **`blocksTruncated` carries the partiality** the way `Rows.Truncated`
/// does for rows: a short history and a trimmed one must never look alike,
/// and the surface that shows the blocks owes the operator that fact with
/// them.
public struct TerminalSnapshot: Sendable, Equatable {
    public let screen: TerminalScreen
    public let cwd: String
    public let shell: String
    public let cols: Int
    public let rows: Int
    public let blocks: [TerminalBlock]
    public let blocksTruncated: Bool
    public let grid: [String]

    public static let empty = TerminalSnapshot(
        screen: .blocks, cwd: "", shell: "", cols: 0, rows: 0,
        blocks: [], blocksTruncated: false, grid: [])

    public init(...) { ... }
}
```

- [ ] **Step 5: Add `TerminalContents` to `PaneStore`**

Replace Task 3's placeholder with the real thing:

```swift
    /// What a terminal pane holds. **The rendered value only** — the pty
    /// master, the child pid and the drain thread are `TerminalStore`'s.
    private struct TerminalContents {
        var screen: TerminalScreen = .blocks
        var cwd = ""
        var shell = ""
        var cols = 0
        var rows = 0
        var blocks: [TerminalBlock] = []
        var blocksTruncated = false
        var grid: [String] = []
        var failure: String?
        /// The one pending proposal, or `nil`. Kept out of `blocks` until
        /// the snapshot is built so that "at most one" is a property of
        /// the storage rather than a rule someone has to remember.
        var proposal: TerminalBlock?
        /// Mirrored blocks that arrived while a full-screen program held
        /// the screen. Foreign rows cannot be spliced into a live emulator
        /// buffer without lying to the shell about its cursor, so the
        /// mirror pauses and catches up when the program exits. Task 15.
        var pausedMirror: [TerminalBlock] = []

        func snapshot() -> TerminalSnapshot {
            var all = blocks
            if let proposal { all.append(proposal) }
            return TerminalSnapshot(
                screen: screen, cwd: cwd, shell: shell, cols: cols, rows: rows,
                blocks: all, blocksTruncated: blocksTruncated, grid: grid)
        }
    }
```

with writers:

```swift
    /// Appends a finished block, trimming the oldest past the cap and
    /// recording that it did.
    ///
    /// **Ordered by `startedAt`, not by arrival.** The operator's blocks
    /// come off the drain thread and the mirror's come off the harness
    /// stream; two producers that both append would interleave by
    /// scheduling accident.
    public func recordTerminal(paneId: String, block: TerminalBlock) {
        var contents = terminal(paneId)
        if let index = contents.blocks.firstIndex(where: { $0.id == block.id }) {
            contents.blocks[index] = block          // a running block filling in
        } else {
            contents.blocks.append(block)
            contents.blocks.sort { $0.startedAt < $1.startedAt }
        }
        if contents.blocks.count > TerminalBlock.historyCap {
            contents.blocks.removeFirst(contents.blocks.count - TerminalBlock.historyCap)
            contents.blocksTruncated = true
        }
        setTerminal(paneId, contents)
    }

    public func setTerminalLiveState(
        paneId: String, cwd: String, shell: String, cols: Int, rows: Int,
        screen: TerminalScreen, grid: [String]
    ) { ... }

    /// At most one pending proposal per pane — a property of the storage,
    /// not a rule a handler has to remember. A replacement is journalled
    /// by the action, so an agent cannot silently swap the command under a
    /// hand already moving to Enter.
    public func setTerminalProposal(paneId: String, _ proposal: TerminalBlock?) { ... }
    public func terminalProposal(paneId: String) -> TerminalBlock? { ... }

    /// The finished blocks only, for the window and for tests.
    public func terminalBlocks(paneId: String) -> [TerminalBlock] { terminal(paneId).blocks }

    /// Clears everything a terminal pane holds without closing the pane.
    /// `term_open` on a pane that already had a shell starts a new
    /// history, because the old one belonged to a process that is gone.
    public func clearTerminal(paneId: String) { ... }
```

- [ ] **Step 6: Add the terminal arm to the wire form**

In `PaneSnapshotJSON.swift`:

```swift
    case .terminal(let terminal):
        object["screen"] = .string(terminal.screen.rawValue)
        object["cwd"] = .string(terminal.cwd)
        object["shell"] = .string(terminal.shell)
        object["cols"] = .number(Double(terminal.cols))
        object["rows"] = .number(Double(terminal.rows))
        object["blocksTruncated"] = .bool(terminal.blocksTruncated)
        object["grid"] = .array(terminal.grid.map { .string($0) })
        object["blocks"] = .array(terminal.blocks.map { block in
            .object([
                "id": .string(block.id),
                "command": .string(block.command),
                "origin": .string(block.origin.rawValue),
                "exitCode": block.exitCode.map { .number(Double($0)) } ?? .null,
                "durationMs": block.durationMs.map { .number(Double($0)) } ?? .null,
                "output": .array(block.output.map { .string($0) }),
                "heldTheGrid": .bool(block.heldTheGrid),
            ])
        })
```

- [ ] **Step 7: Record blocks on the drain thread, publish at frame rate**

In `TerminalSession`, add an open-block recorder driven by `onStreamEvents`, holding: the command, `startedAt`, the accumulated output lines, and whether the alternate screen was entered at any point during it. On `.commandEnd`, seal it with `TerminalBlock.capped` and push it to a `completed` array under the lock. On `.commandStart`, open one. **A `D` with no open block is dropped** — the first `precmd` of every session emits one.

In `TerminalStore`, take the pane store and run one publisher:

```swift
    private let panes: PaneStore?
    private var publisher: Task<Void, Never>?

    public init(panes: PaneStore? = nil) { self.panes = panes }

    /// **Redraw is driven by a polled `getUpdateRange()` at the display's
    /// frame rate, never from the feed.** There is no push to drive it
    /// from — `TerminalDelegate` has no content-change member at all — and
    /// polling *is* the coalescing: it turns 28 MB of `cat` into 21 frames
    /// and 144–792 repainted rows, against 1,179,666 rows if every 1 KB
    /// chunk drew (probe §4.2). The pane's redraw cost is a function of
    /// this interval and nothing else, not of how hard the shell is trying.
    private func startPublishing() {
        guard publisher == nil, panes != nil else { return }
        publisher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.publishOnce() else { return }
                try? await Task.sleep(nanoseconds: 16_666_666)  // 60 Hz
            }
        }
    }

    /// Returns false when nothing is left to publish, which stops the loop.
    private func publishOnce() async -> Bool { ... }
```

`publishOnce` drains each session's completed blocks into `panes.recordTerminal`, and when `takeUpdateRange()` reports a dirty range writes `setTerminalLiveState` with the live cwd, shell, dimensions, current screen and — only when the alternate screen is active — the visible rows.

- [ ] **Step 8: Run the tests, then the suite**

Run: `cd app && ../scripts/swift-test.sh --filter Terminal` then `make app-test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "feat: blocks captured at the D mark, capped in blocks and in lines

Not derived from the emulator's buffer: a mark dies with the row the
scrollback cap evicts. blocksTruncated carries the partiality."
```

---

## Task 10: `term_open(path:)` — the pane, its title, and any path at all

A database pane's first action carries everything it needs; a shell has to **exist** before anything runs in it, and the shell owns the input line, so the operator's first typed command never passes through an action at all. Without this there is no tool by which an agent can do the thing the operator described.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalActions.swift`
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`kinds`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (build the store, register)
- Test: `app/Tests/WakilKitTests/TerminalActionsTests.swift` (create)

**Interfaces:**
- Consumes: `TerminalStore.open`, `resolvePane`, `LayoutStore.open`/`retitle`.
- Produces: `registerTerminalActions(into:terminals:panes:layout:context:)`; the action `term_open`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func termOpenOpensAndTitlesAPaneWhenTheCallNamesNone() async throws {
    let registry = ActionRegistry(journalDirectory: scratchDirectory(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let terminals = TerminalStore(panes: panes)
    await registerTerminalActions(into: registry, terminals: terminals, panes: panes, layout: layout)

    let result = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string(NSTemporaryDirectory())]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        Issue.record("no pane id returned"); return
    }
    let opened = await layout.snapshot().panes.first { $0.id == paneId }
    #expect(opened?.kind == "terminal")
    // Titled from the path, through the same helper by which a query
    // titles a pane by its database.
    #expect(opened?.title.isEmpty == false)
    #expect(await terminals.isRunning(paneId: paneId))

    await terminals.shutdownAll()
}

@Test func termOpenIsAControlActionAllowedEverywhereIncludingProduction() async throws {
    // `.mutate` breaks twice: it gates EVERYWHERE outside production, so
    // every `ls` would cost a typed confirmation, and it blocks IN
    // production regardless of origin, so the pane would die exactly where
    // an operator most wants a shell.
    let (registry, terminals, layout, _) = try await terminalFixture()

    let result = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string(NSTemporaryDirectory())]),
        origin: .agent, environment: "production", confirmation: nil)

    #expect(result != .null)
    let descriptor = await registry.all().first { $0.name == "term_open" }
    #expect(descriptor?.kind == .control)
    await terminals.shutdownAll()
}

@Test func aPathOutsideEveryProjectRootIsAcceptedSilently() async throws {
    // Refusing one would be theatre: it is a real PTY and `cd` walks out
    // of any fence. Deliberately more permissive than session reads, which
    // refuse a cwd outside the active project's roots — a shell is not an
    // agent session, and the real boundary for a shell is the write gate
    // and the injected environment.
    let (registry, terminals, _, _) = try await terminalFixture()

    _ = try await registry.dispatch(
        name: "term_open", params: .object(["path": .string("/usr/lib")]),
        origin: .agent, environment: "staging", confirmation: nil)

    await terminals.shutdownAll()
}

@Test func termOpenOnAPaneThatAlreadyHasAShellReplacesItRatherThanLeaking() async throws {
    let (registry, terminals, layout, _) = try await terminalFixture()
    let first = try await open(registry, path: NSTemporaryDirectory())
    let pidBefore = await terminals.pidForTesting(paneId: first)

    _ = try await registry.dispatch(
        name: "term_open",
        params: .object(["pane": .string(first), "path": .string("/usr/lib")]),
        origin: .agent, environment: "staging", confirmation: nil)

    #expect(await terminals.pidForTesting(paneId: first) != pidBefore)
    #expect(kill(pidBefore!, 0) == -1)
    #expect(await layout.snapshot().panes.count == 1)
    await terminals.shutdownAll()
}

@Test func anUnsupportedShellIsRefusedWithAReasonRatherThanOpeningDegraded() async throws {
    let (registry, terminals, _, _) = try await terminalFixture()

    await #expect(throws: TerminalOpenError.self) {
        _ = try await registry.dispatch(
            name: "term_open",
            params: .object(["path": .string("/tmp"), "shell": .string("/bin/fish")]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    await terminals.shutdownAll()
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter termOpen`
Expected: FAIL — `registerTerminalActions` is not a function.

- [ ] **Step 3: Add `"terminal"` to `Pane.kinds`**

In `app/Sources/WakilKit/Layout/Pane.swift`, amend the set and its comment:

```swift
    /// **2c-iii adds the second kind**, beside the view that can draw it
    /// (`WakilApp/TerminalPane.swift`) — which is the rule this set has
    /// always stated and could not demonstrate with one member. `"api"`
    /// and `"board"` arrive with 2c-iv and 2c-vi the same way; listing
    /// them now would be the decision-before-requirements this type's
    /// `kind`-is-a-String comment already refuses.
    public static let kinds: Set<String> = ["db", "terminal"]
```

- [ ] **Step 4: Write `term_open`**

Create `app/Sources/WakilKit/Terminal/TerminalActions.swift`:

```swift
import Foundation

/// The terminal pane's four actions, all `.control`.
///
/// **Why `.control` and not `.mutate`, which is the harder half.**
/// `.mutate` breaks twice. The gate `.gate`s it everywhere except
/// production, so every `ls` would cost a typed confirmation; and it
/// `.block`s in production regardless of origin, so the pane would die
/// exactly where an operator most wants a shell. Neither is survivable,
/// and the pane is not worth building under either.
///
/// **What that costs, stated rather than buried.** `.control` used to mean
/// *"the world outside Wakil is untouched"*, and for a shell run that is
/// false. It is redefined here as **"not gated by environment"**, and the
/// instrument protecting `term_run` is `operatorOnlyActions` plus the
/// in-pane `⏎`, **not** the write gate: a command typed by the operator
/// and submitted by hand is neither an unreviewed agent mutation nor an
/// unclassified statement, which is what the gate was built for. A fourth
/// `ActionKind` was the honest alternative and was rejected against the
/// code — two of `ActionKind`'s three consumers compare by equality rather
/// than switching, so `isMutation` would have gone silently false and the
/// confirmation plane would have stopped appearing.
///
/// `ActionKind`'s own doc comment was amended in Task 1 to say so.
public func registerTerminalActions(
    into registry: ActionRegistry,
    terminals: TerminalStore,
    panes: PaneStore,
    layout: LayoutStore?,
    activeContext: @escaping @Sendable () async -> (org: String, project: String, environment: String)
        = { ("", "", "") }
) async {
    await registry.register(Action(
        name: "term_open",
        description: "Open an interactive shell in a terminal pane, at a path. Names no pane "
            + "and one is opened and titled from the path — the same way a query opens a pane "
            + "and titles it by its database. ANY path is accepted, including one outside every "
            + "project root: this is a real PTY and `cd` walks out of any fence, so refusing "
            + "one would be theatre. The shell carries the active organisation, project and "
            + "environment, which is what makes a credentialed command work here without "
            + "exporting anything by hand — and is exactly why you may not run in it. Only zsh "
            + "and bash are supported; anything else is refused here rather than opened in a "
            + "degraded mode. Opening on a pane that already has a shell kills that shell and "
            + "starts a new history. You can read this pane and propose into it; you cannot run.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "pane": .object(["type": .string("string")]),
                "shell": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path")]),
        ]),
        handler: { params in
            let path = try requireString(params, "path", action: "term_open")
            let explicit = optionalString(params, "pane")
            try await requireOpenPane(explicit, action: "term_open", layout: layout)

            // The same helper `db_run_query` uses: name a pane and it is
            // retitled, name none and one is opened. The terminal titles
            // by the path rather than by a database.
            let title = terminalPaneTitle(forPath: path)
            let resolved = await resolveTerminalPane(
                explicit: explicit, title: title, layout: layout)

            let context = await activeContext()
            let opened = try await terminals.open(
                paneId: resolved,
                path: path,
                shell: optionalString(params, "shell") ?? TerminalStore.defaultShell(),
                environment: terminalChildEnvironment(
                    org: context.org, project: context.project,
                    environment: context.environment))
            // A new shell is a new history: the old one belonged to a
            // process that no longer exists.
            await panes.clearTerminal(paneId: resolved)
            await panes.setTerminalLiveState(
                paneId: resolved, cwd: opened.cwd, shell: opened.shell,
                cols: opened.cols, rows: opened.rows, screen: .blocks, grid: [])
            return .object([
                "pane": .string(resolved),
                "shell": .string(opened.shell),
                "cwd": .string(opened.cwd),
            ])
        }
    ))
}

/// The last path component, or the path itself at the root. `~` for home,
/// because that is what the operator calls it.
///
/// **A name, not an inference.** Wakil never guesses what a pane is
/// showing from its contents — the rule `queryTargetPane` states in the
/// operator's own words about SQL — and a path is a name the caller
/// already supplied.
func terminalPaneTitle(forPath path: String) -> String { ... }
```

- [ ] **Step 5: Wire it into the assembly**

In `AppWiring.swift`: a `public let terminals: TerminalStore` on `WakilWiring`, built with `panes`, registered in `build`, and torn down in `shutdown()`:

```swift
        let terminals = TerminalStore(panes: panes)
        await registerTerminalActions(
            into: registry, terminals: terminals, panes: panes, layout: layout)
```

```swift
    public func shutdown() async {
        await contextClient?.stop()
        await databaseClient?.stop()
        // No shell outlives the app. `--dispatch` can open one too.
        await terminals.shutdownAll()
    }
```

- [ ] **Step 6: Run the suite, then commit**

Run: `make app-test`
Expected: PASS. `LayoutPersistenceTests` and any test asserting `Pane.kinds == ["db"]` needs updating — a saved layout holding a `terminal` pane now loads rather than being dropped with a note.

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "feat: term_open(path:) — a shell must exist before anything runs in it

Any path, silently: a real PTY and cd walks out of any fence."
```

---

## Task 11: `term_propose`, and `term_run` journalled from the shell's own report

Two Enters, deliberately: one to accept, one to run. That is Invariant 7's shape generalised from voice to the agent.

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalActions.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (the run pump; accept/discard)
- Test: `app/Tests/WakilKitTests/TerminalActionsTests.swift`

**Interfaces:**
- Consumes: `PaneStore.setTerminalProposal`, `TerminalStore.write`, the completed-block stream.
- Produces: actions `term_propose`, `term_run`; `WindowModel.acceptProposal(pane:)`, `.discardProposal(pane:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aProposalIsABlockThatHasNotRunAtTheTailOfTheHistory() async throws {
    let (registry, terminals, layout, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())

    _ = try await registry.dispatch(
        name: "term_propose",
        params: .object(["pane": .string(pane), "command": .string("kubectl get pods")]),
        origin: .agent, environment: "staging", confirmation: nil)

    guard case .terminal(let snapshot) = (await panes.snapshot(paneId: pane, kind: "terminal")).contents
    else { Issue.record("no terminal snapshot"); return }
    // A band or a card would give one thing two homes: the agent reads a
    // block where the operator sees a banner.
    #expect(snapshot.blocks.last?.origin == .proposed)
    #expect(snapshot.blocks.last?.command == "kubectl get pods")
    #expect(snapshot.blocks.last?.exitCode == nil)
    await terminals.shutdownAll()
}

@Test func atMostOneProposalIsPendingAndTheReplacementIsItselfJournalled() async throws {
    let (registry, terminals, _, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())

    for command in ["aws s3 ls", "aws s3 ls s3://other"] {
        _ = try await registry.dispatch(
            name: "term_propose",
            params: .object(["pane": .string(pane), "command": .string(command)]),
            origin: .agent, environment: "staging", confirmation: nil)
    }

    let proposals = (await panes.terminalBlocks(paneId: pane)).filter { $0.origin == .proposed }
    #expect(proposals.count <= 1)
    #expect(await panes.terminalProposal(paneId: pane)?.command == "aws s3 ls s3://other")
    // An agent must not be able to silently swap the command under a hand
    // already moving to Enter — so the replacement leaves its own line.
    let entries = try await registry.journalEntries().filter { $0.action == "term_propose" }
    #expect(entries.count == 2)
    await terminals.shutdownAll()
}

@Test func acceptingAProposalPutsItInThePromptUnrunAndClearsTheBlock() async throws {
    let (registry, terminals, layout, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())
    _ = try await registry.dispatch(
        name: "term_propose",
        params: .object(["pane": .string(pane), "command": .string("echo accepted")]),
        origin: .agent, environment: "staging", confirmation: nil)

    // What the operator's ⏎ does: the bytes go to the shell's line WITHOUT
    // a newline, so it sits there unrun, and the dashed block is gone
    // before the prompt fills — or the operator sees the same command
    // twice.
    await terminals.write(paneId: pane, bytes: Array("echo accepted".utf8))
    await panes.setTerminalProposal(paneId: pane, nil)

    #expect(await panes.terminalProposal(paneId: pane) == nil)
    try await waitUntil(seconds: 5) { await terminals.screenContains(pane, "echo accepted") }
    // Not run: no block exists for it yet.
    #expect((await panes.terminalBlocks(paneId: pane)).isEmpty)
    await terminals.shutdownAll()
}

@Test func aRunIsJournalledWithItsCommandContextExitCodeAndHowItWasAccepted() async throws {
    let model = WindowModel.forTesting(organization: "initech")
    // Drives the REAL pump, not a store method the shipped path may not
    // call — 2b-viii's standing lesson.
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "printf hi; exit 4\n")

    try await waitUntil(seconds: 8) { await model.journalledRuns().count == 1 }
    let entry = await model.journalledRuns()[0]

    guard case .object(let params) = entry.params else { Issue.record("no params"); return }
    #expect(params["command"] == .string("printf hi; exit 4"))
    #expect(params["exitCode"] == .number(4))
    #expect(params["accepted"] == .string("typed"))
    #expect(params["cwd"] != nil)
    #expect(entry.environment == "")      // whatever the model's is
    #expect(entry.origin == .ui)
    // NOT the output. It is unbounded, and this pane's own worked example
    // is a `keychain` grep, so the journal would become where secrets
    // accumulate. Output is read through read_pane.
    #expect(params["output"] == nil)
    await model.shutdown()
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter Propose --filter journalledRuns`
Expected: FAIL — `term_propose` is not registered.

- [ ] **Step 3: Write `term_propose` and `term_run`**

Appended to `registerTerminalActions`:

```swift
    await registry.register(Action(
        name: "term_propose",
        description: "Propose a command into a terminal pane. It is drawn as a block that has "
            + "NOT run, at the tail of the history directly above the operator's prompt — where "
            + "its output would appear. The operator's Enter puts it in their own prompt UNRUN, "
            + "and a second Enter runs it: two keystrokes, deliberately. At most one proposal "
            + "is pending per pane; proposing again replaces it, and the replacement is "
            + "journalled, so you cannot silently swap the command under a hand already moving "
            + "to Enter. Read the pane to find out what happened to it: a block with origin "
            + "\"proposed\" is still waiting, one with origin \"operator\" carrying your command "
            + "was accepted and run, and neither means it was discarded.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("command")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "term_propose")
            let command = try requireString(params, "command", action: "term_propose")
            try await requireOpenPane(pane, action: "term_propose", layout: layout)
            await panes.setTerminalProposal(paneId: pane, TerminalBlock(
                id: "\(pane)-proposal", command: command, origin: .proposed,
                exitCode: nil, durationMs: nil, output: [], heldTheGrid: false,
                startedAt: Date()))
            return .object(["pane": .string(pane), "command": .string(command)])
        }
    ))

    await registry.register(Action(
        name: "term_run",
        description: "OPERATOR ONLY. Records that a command was submitted in a terminal pane "
            + "and how it ended. You cannot call this: the shell in that pane carries the "
            + "organisation's credentials and the active environment, and what running there "
            + "would buy you is those, not reach — you already have a shell of your own outside "
            + "Wakil. Use term_propose and the operator's Enter.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "command": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string")]),
                // "proposed" (by the agent, accepted by the operator) or
                // "typed". Materially different events, and after the fact
                // the journal is the only place the difference survives.
                "accepted": .object(["type": .string("string")]),
                "exitCode": .object(["type": .string("number")]),
                "durationMs": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("pane"), .string("command")]),
        ]),
        handler: { params in
            // The journal entry IS the work: `dispatch` writes it, and the
            // shell has already run the command. This handler exists so
            // that the run passes through the one chokepoint Invariant 2
            // names, and so ⌘K lists it as a thing that happened.
            let pane = try requireString(params, "pane", action: "term_run")
            return .object(["pane": .string(pane)])
        }
    ))
```

- [ ] **Step 4: Pump completed blocks into `term_run`**

In `WindowModel`: a `terminalRunPump` subscribing to `terminals.completedRuns()` (an `AsyncStream<TerminalRun>` the store yields from `publishOnce` as each block seals), dispatching:

```swift
    /// **`term_run` is dispatched once, at the block's `D` mark.** The
    /// spec says it is journalled *from* the shell's OSC 133 `C`, and `C`
    /// is indeed what makes the run an action — it is where the block
    /// opens and where the command text is captured. But the entry the
    /// spec specifies carries the exit code and the duration, which exist
    /// only at `D`. One dispatch carrying every field beats two carrying
    /// half each.
    ///
    /// **A block still open at teardown is journalled with a null exit
    /// code**, so no submitted command escapes the journal because its
    /// shell was killed.
    ///
    /// **`origin: .ui`, always.** It was the operator: the agent cannot
    /// reach this action, and a command it proposed was still submitted by
    /// a human hand. `accepted` is what records the difference.
    private func startTerminalRunPump() { ... }
```

- [ ] **Step 5: Accept and discard, in the window**

```swift
    /// The operator's `⏎` on a proposal.
    ///
    /// **Not an action, and that is consistent rather than convenient.**
    /// Keystrokes into the prompt are text-field editing, not actions —
    /// the precedent is the DB pane, which has no action for typing in the
    /// query editor. This writes the same bytes a hand would, **without a
    /// newline**, so the command sits in the operator's own prompt unrun;
    /// from that instant injected bytes are indistinguishable from typed
    /// ones, and it is theirs in every sense. The run that follows is the
    /// action, and it records that this command was proposed.
    ///
    /// **The proposed block is cleared BEFORE the prompt fills**, or the
    /// operator sees the same command twice.
    public func acceptProposal(pane: String) async { ... }

    /// `⌫`. The proposal is discarded and nothing is written to the shell.
    public func discardProposal(pane: String) async { ... }
```

- [ ] **Step 6: Run the suite, then commit**

Run: `make app-test`

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "feat: term_propose writes a block that has not run; term_run journals one that did

Two Enters, deliberately — Invariant 7's shape generalised from voice to
the agent. The journal records the command, never the output."
```

---

## Task 12: `term_run` is denied to the agent in words that name *this* refusal

The seventh member of `operatorOnlyActions`, and a **fourth** denial family — not a reuse. T13-R1 (2b-viii's acceptance ruling) found a draft test asserting only `reason.contains("operator")`, which the provider wording already satisfies: a true sentence about the wrong family, answering a question the agent never asked.

**Files:**
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift`
- Test: `app/Tests/WakilKitTests/PermissionPromptTests.swift`

**Interfaces:**
- Consumes: `term_run` (Task 11).
- Produces: `operatorOnlyActions` containing `"term_run"`; a fourth branch in `operatorOnlyDenialMessage`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func termRunIsDeniedToTheAgentInItsOwnWordsAndNotAnotherFamilys() {
    let decision = permissionDecision(
        toolName: "mcp__wakil__term_run",
        knownActions: ["term_run", "term_open", "term_propose", "term_scroll"])

    guard case .deny(let reason) = decision else {
        Issue.record("term_run must be denied"); return
    }
    // Asserted on THIS refusal's own words. A substring three other
    // families already satisfy is the exact trap 2b-viii's acceptance
    // found in a draft test.
    #expect(reason.contains("term_propose"))
    #expect(reason.contains("credentials"))
    // And not the provider family's sentence, nor the org ones.
    #expect(!reason.contains("which account a session runs under"))
    #expect(!reason.contains("Enumerating every organisation"))
}

@Test func theOtherThreeTerminalActionsAreAllowed() {
    // An agent that could not open or propose could not use this pane at
    // all, and the refusal is about the RUN, not about the pane.
    for name in ["term_open", "term_propose", "term_scroll"] {
        #expect(permissionDecision(
            toolName: "mcp__wakil__\(name)",
            knownActions: [name]) == .allow)
    }
}

@Test func termRunIsAlsoOffTheAgentsPreApprovalList() {
    // Two places, and both matter: §6 of the permission probe measured
    // that an ALLOW-LISTED tool never reaches approve_tool_use at all, so
    // an action left on --allowedTools could never be refused above no
    // matter what that function said.
    let allowed = agentAllowedTools(actions: [
        ActionDescriptor(name: "term_run", description: "", kind: .control, schema: .object([:])),
        ActionDescriptor(name: "term_open", description: "", kind: .control, schema: .object([:])),
    ])
    #expect(!allowed.contains { $0.hasSuffix("term_run") })
    #expect(allowed.contains { $0.hasSuffix("term_open") })
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter termRun`
Expected: FAIL — `term_run` is allowed.

- [ ] **Step 3: Add the member and the fourth family**

```swift
public let operatorOnlyActions: Set<String> = [
    "session_set_provider", "ctx_set_provider",
    "ctx_list_orgs", "ctx_create_org",
    "ctx_list_machine_providers", "ctx_adopt_provider",
    // 2c-iii. The seventh member, and the one whose reason is NOT that the
    // agent could move a boundary by calling it — it is that the shell in
    // a terminal pane carries the organisation's credentials and the
    // active environment. The agent already has a bare shell outside
    // Wakil that Wakil cannot stop, so what a pane run would buy it is
    // those, not reach; the refusal defends Invariant 4, and the residue
    // of credentialed commands Wakil has no capability for (`kubectl get
    // pods`, `aws s3 ls`, `docker ps`) is rare rather than daily, so it is
    // worth exactly one Enter.
    //
    // Invariant 6's other half is why no shape of this ships: it admits no
    // write that cannot be classified, and a shell command cannot be.
    // `classify_statement` works on SQL because SQL has a bounded grammar
    // and enumerated verbs; a shell has neither — `ls > file` writes,
    // `find -delete` deletes, and `;`, `&&`, `|` and `$()` compose
    // anything out of anything.
    "term_run",
]
```

and a fourth branch in `operatorOnlyDenialMessage`, with the switch's doc comment updated from "Three families, three sentences" to four:

```swift
    case "term_run":
        return "\(toolName): only the operator runs a command in a terminal pane. That "
            + "shell carries the organisation's credentials and the active environment, "
            + "which is the whole of what running there would add — you already have a "
            + "shell of your own, outside Wakil. Use term_propose to put the exact command "
            + "in front of the operator; their Enter puts it in their prompt, and a second "
            + "one runs it. Nothing you can pass to this tool will change that answer, so "
            + "do not retry it."
```

- [ ] **Step 4: Run the suite, then commit**

```bash
git add app/Sources/WakilKit/MCP/PermissionPrompt.swift app/Tests/WakilKitTests/PermissionPromptTests.swift
git commit -m "feat: term_run is operator-only, denied in words that name this refusal

A fourth denial family, not a reuse: a true sentence about the wrong
family answers a question the agent never asked."
```

---

## Task 13: `term_scroll` — the fourth action, so the pane is driven both ways

#40 left a terminal pane with no scroll and no selection action, and said so: an agent cannot bring a block into view the way it can a row, and Invariant 2 wants a pane driven both ways.

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalActions.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (the scroll target)
- Test: `app/Tests/WakilKitTests/TerminalActionsTests.swift`

**Interfaces:**
- Consumes: `TerminalBlock.id`.
- Produces: the action `term_scroll`; `PaneStore.setTerminalScrollTarget(paneId:blockId:)`, `.terminalScrollTarget(paneId:)`; `TerminalSnapshot.scrollTarget: String?`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func termScrollBringsABlockIntoViewByIdRatherThanByPosition() async throws {
    let (registry, terminals, _, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())
    for index in 0..<3 {
        await panes.recordTerminal(paneId: pane, block: TerminalBlock(
            id: "b\(index)", command: "echo \(index)", origin: .operatorTyped, exitCode: 0,
            durationMs: 1, output: [], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    _ = try await registry.dispatch(
        name: "term_scroll", params: .object(["pane": .string(pane), "block": .string("b1")]),
        origin: .agent, environment: "staging", confirmation: nil)

    #expect(await panes.terminalScrollTarget(paneId: pane) == "b1")
    await terminals.shutdownAll()
}

@Test func termScrollDoesNotTakeARowBecauseThatWordAlreadyMeansSomethingElse() async throws {
    // `row` is documented three times over as a zero-based index into a
    // displayed order that a SORT changes. A terminal has no sort, and
    // reusing the parameter would give it three incompatible meanings
    // behind one name — a table row, a block, or a terminal line,
    // depending on kind and current screen.
    let (registry, terminals, _, _) = try await terminalFixture()
    let descriptor = await registry.all().first { $0.name == "term_scroll" }

    guard case .object(let schema)? = descriptor?.schema,
          case .object(let properties)? = schema["properties"] else {
        Issue.record("no schema"); return
    }
    #expect(properties["row"] == nil)
    #expect(properties["block"] != nil)
    await terminals.shutdownAll()
}

@Test func termScrollWithNoBlockClearsThePendingTarget() async throws {
    // The surface dispatches this itself once it has scrolled, so the same
    // block can be asked for again — the shape pane_scroll_clear already
    // has, folded into one action because a terminal has one of them.
    let (registry, terminals, _, panes) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())
    await panes.setTerminalScrollTarget(paneId: pane, blockId: "b1")

    _ = try await registry.dispatch(
        name: "term_scroll", params: .object(["pane": .string(pane)]),
        origin: .ui, environment: "staging", confirmation: nil)

    #expect(await panes.terminalScrollTarget(paneId: pane) == nil)
    await terminals.shutdownAll()
}

@Test func termScrollRefusesABlockThePaneDoesNotHold() async throws {
    // An id that names nothing would write a scroll target the view can
    // never satisfy and return success — the no-op shape the five grid
    // actions were just cured of.
    let (registry, terminals, _, _) = try await terminalFixture()
    let pane = try await open(registry, path: NSTemporaryDirectory())

    await #expect(throws: LayoutActionError.self) {
        _ = try await registry.dispatch(
            name: "term_scroll",
            params: .object(["pane": .string(pane), "block": .string("b-nope")]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    await terminals.shutdownAll()
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter termScroll`
Expected: FAIL — `term_scroll` is not registered.

- [ ] **Step 3: Write it**

```swift
    await registry.register(Action(
        name: "term_scroll",
        description: "Bring one block of a terminal pane's history into view, by its id as "
            + "read_pane reports it. It takes a BLOCK ID and not a row index, deliberately: "
            + "`row` means a zero-based position in a displayed order that a sort changes, a "
            + "terminal has no sort, and a block id is stable while a position is not — the "
            + "block cap shifts every position each time it trims. Omit `block` to clear a "
            + "pending target; the pane does that itself once it has scrolled, so the same "
            + "block can be asked for again. This scrolls the block history; while a "
            + "full-screen program holds the screen the history is parked, and the target "
            + "waits for it.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "block": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "term_scroll")
            try await requireOpenPane(pane, action: "term_scroll", layout: layout)
            guard let block = optionalString(params, "block") else {
                await panes.setTerminalScrollTarget(paneId: pane, blockId: nil)
                return .object(["pane": .string(pane), "block": .null])
            }
            guard await panes.terminalBlocks(paneId: pane).contains(where: { $0.id == block })
            else {
                throw LayoutActionError.badParam(
                    action: "term_scroll", param: "block", value: block)
            }
            await panes.setTerminalScrollTarget(paneId: pane, blockId: block)
            return .object(["pane": .string(pane), "block": .string(block)])
        }
    ))
```

with `scrollTarget: String?` added to `TerminalContents`, `TerminalSnapshot` and the wire form (always present, `null` when none), and named in `read_pane`'s prose alongside the other terminal keys.

- [ ] **Step 4: Run the suite, then commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "feat: term_scroll takes a block id, so the terminal is driven both ways

Not `row` — that word already means a position in a sorted order, and a
terminal has no sort."
```

---

## Task 14: Three kill points, a third tripwire bucket, and a test that actually kills a shell

*No shell outlives the pane that opened it* is this sub-phase's least-defended claim, because there is no `deinit` in `WakilKit` that releases an OS resource. The tripwire can only prove someone **thought about** the resource — it says so about itself — so the behavioural half is what holds the promise.

**Files:**
- Modify: `app/Sources/WakilKit/Layout/LayoutActions.swift` (`pane_close`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`terminals`; `invalidateForOrgChange`; `shutdown`)
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift` (the third bucket)
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`, `WindowModelTests.swift`, `ShutdownContractTests.swift`

**Interfaces:**
- Consumes: `TerminalStore.close(paneId:)`, `.shutdownAll()`.
- Produces: `WindowModel.terminals`; `registerLayoutActions(into:layout:panes:terminals:)`.

- [ ] **Step 1: Write the failing tests**

In `InvalidationContractTests.swift`, add the third bucket and move the two properties filed wrongly today:

```swift
/// **A stable reference whose CONTENTS are org-scoped and must be torn
/// down.** The tripwire's two buckets were never enough, and the proof is
/// that they already lie: `panes` and `layout` were filed under
/// `orgIndependent`, while `invalidateForOrgChange()` clears **both**,
/// explicitly and awaited, as its last two lines. So `orgIndependent` did
/// not mean *"holds no org state"* — it meant *"this reference is not
/// reassigned"*, and the two stores carrying the most org state in the
/// window were filed under it.
///
/// That misreading is not an accident of this test; it is how the app
/// tears down. `WakilWiring.switchOrg(to:)` stops and restarts the SAME
/// `MCPClient` instances in place, never replacing them, because
/// `registerStandardActions` closed over those instances. A live child
/// process dying while its owning reference never changes is the shape
/// this app uses everywhere, and the tripwire had no vocabulary for it.
///
/// **`terminals` is why it needed one.** A `TerminalStore` inherits
/// exactly that reading — the reference genuinely is stable — so an author
/// doing precisely what the failure message asks would file it under
/// `orgIndependent`, and org A's shell would survive the switch with this
/// test green and the classification defensible.
///
/// **Widening the skip rule is still the wrong fix**, which is what the
/// message below has always said. A third bucket is the right one, and its
/// NAME is the instruction the next author needs.
private let orgDerivedBehindAReference: Set<String> = [
    "panes", "layout", "terminals",
]
```

```swift
@Test func theOrgSwitchKillsEveryShellItLeavesBehind() async throws {
    // The BEHAVIOURAL half. The tripwire proves a resource was classified;
    // it cannot prove the shell dies, and a dropped reference leaks a live
    // process holding org A's working directory open.
    let model = WindowModel.forTesting(organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = await model.terminals.pidForTesting(paneId: pane)
    #expect(pid != nil)

    await model.invalidateForOrgChange()

    #expect(kill(pid!, 0) == -1)
    #expect(!(await model.terminals.isRunning(paneId: pane)))
    await model.shutdown()
}

@Test func anOrgSwitchIsNotBlockedByAShellThatIsStillRunning() async throws {
    // A forgotten `tail -f` dies silently, with no warning and no prompt.
    // Making a shell a parked mutation would let it block a switch
    // indefinitely, which is the worse failure. Guard 2 refuses to start
    // while a MUTATION is parked; a shell is not one.
    let model = WindowModel.forTesting(organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    await model.sendToTerminalForTesting(pane: pane, text: "yes wakil\n")

    let start = Date()
    await model.invalidateForOrgChange()

    #expect(Date().timeIntervalSince(start) < 3)
    await model.shutdown()
}

@Test func closingAPaneKillsItsShell() async throws {
    // pane_close ends in a dictionary removal today. A cleared dictionary
    // does not kill a shell.
    let model = WindowModel.forTesting(organization: "alpha")
    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let pid = await model.terminals.pidForTesting(paneId: pane)

    await model.closePane(id: pane)

    #expect(kill(pid!, 0) == -1)
    await model.shutdown()
}

@Test func quittingKillsEveryShell() async throws {
    let model = WindowModel.forTesting(organization: "alpha")
    var pids: [pid_t] = []
    for _ in 0..<2 {
        let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())
        pids.append(await model.terminals.pidForTesting(paneId: pane)!)
    }

    await model.shutdown()

    for pid in pids { #expect(kill(pid, 0) == -1) }
}

@Test func aRestoredTerminalPaneComesBackEmptyAndAwaitsAShell() async throws {
    // Respawning at the saved path would spawn processes as a side effect
    // of reading a file, which no other pane kind does and no operator
    // asked for. The pane persists; the shell and the block history do not.
    let layout = LayoutStore()
    _ = await layout.open(kind: "terminal", title: "~/orca")
    let saved = await layout.snapshot()

    let restored = LayoutStore()
    await restored.load(saved)

    let pane = await restored.snapshot().panes.first
    #expect(pane?.kind == "terminal")
    // Nothing spawned, because loading a layout dispatches nothing.
    let terminals = TerminalStore()
    #expect(!(await terminals.isRunning(paneId: pane!.id)))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter Shell --filter orgDerivedBehindAReference`
Expected: FAIL — `WindowModel` has no `terminals`.

- [ ] **Step 3: Give `WindowModel` the store**

A `let terminals: TerminalStore` beside `panes` and `layout`, taken by `init` and by `forTesting`, and supplied by `WakilWiring` in the app. Plus the two test seams the behavioural tests drive:

```swift
    /// TEST-ONLY: opens a terminal pane the way the operator does —
    /// through the registry, so the real handler runs.
    func openTerminalForTesting(path: String) async -> String { ... }
    func sendToTerminalForTesting(pane: String, text: String) async { ... }
```

- [ ] **Step 4: The three kill points**

1. `pane_close` — `registerLayoutActions` takes `terminals: TerminalStore?`, and the handler awaits it:

```swift
            try await layout.close(id: id)
            // Contents go with the pane, and so does the shell. This used
            // to end at the dictionary removal below — which releases
            // rows and cannot release a file descriptor. A closed pane
            // must leave nothing running.
            await terminals?.close(paneId: id)
            await panes?.drop(paneId: id)
```

2. `invalidateForOrgChange()` — a third awaited clear beside the two it has:

```swift
        // All three stores, wholesale. Awaited, not fired into a detached
        // `Task`: see this method's own doc comment.
        //
        // **The third is not like the other two.** They clear
        // dictionaries; this one kills processes and closes file
        // descriptors, and it is the reason the tripwire needed a third
        // bucket. The switch is deliberately NOT gated on a running shell
        // — a `tail -f` the operator forgot about dies silently, because
        // making a shell a parked mutation would let it block a switch
        // indefinitely, which is the worse failure.
        await layout.clearAllProjects()
        await panes.clearAllProjects()
        await terminals.shutdownAll()
```

3. `shutdown()` — the fifth line in a method whose whole purpose is that:

```swift
        await harness?.stop()
        await terminals.shutdownAll()
```

- [ ] **Step 5: Classify, and teach the tripwire the third bucket**

Move `panes` and `layout` out of `orgIndependent` into `orgDerivedBehindAReference`, add `terminals`, add `terminalSnapshots` (Task 3) to `orgDerived`, and widen the loop and the failure message:

```swift
        if orgDerived.contains(label) || orgIndependent.contains(label)
            || orgDerivedBehindAReference.contains(label) { continue }
```

```
        Add each name to orgDerived (and reset it in invalidateForOrgChange), \
        to orgDerivedBehindAReference (and TEAR ITS CONTENTS DOWN there — a \
        cleared dictionary does not kill a shell), or to orgIndependent. Do \
        not widen the skip rule instead — this test exists to make you choose.
```

- [ ] **Step 6: Run the suite, then commit**

Run: `make app-test`
Expected: PASS, including `ShutdownContractTests` (unchanged — `terminals` is not a `…Pump`).

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "feat: no shell outlives the pane — pane close, org switch, app quit

The tripwire gains a third bucket, because its two already lied: panes and
layout were filed org-independent while invalidateForOrgChange clears both."
```

---

## Task 15: The mirror — the agent's own shell, rendered into every open terminal pane

*"When a terminal is open, I want to see the commands the agent is running."* The plumbing already exists: every tool call arrives on the harness stream with its input and output, including the `Bash` calls the CLI auto-allows and never asks Wakil about. **This is a rendering, not an action** — nothing is dispatched and nothing is journalled, so Invariant 2 is not engaged.

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalMirror.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`append`, the mirror pump, backfill)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (pause and catch up)
- Test: `app/Tests/WakilKitTests/TerminalMirrorTests.swift` (create), `WindowModelTests.swift`

**Interfaces:**
- Consumes: `HarnessEvent.toolUse`/`.toolResult`; `TerminalBlock`.
- Produces: `mirroredBlocks(from:harnessCwd:cap:) -> [TerminalBlock]`; `PaneStore.appendMirrored(paneId:block:)`; `WindowModel.mirrorEvents`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aBashToolCallBecomesAMirroredBlockAndItsResultFillsItIn() {
    let events: [HarnessEvent] = [
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("rg TODO")])),
        .toolResult(id: "t1", content: .string("src/a.swift:4:TODO\n"), isError: false),
    ]

    let blocks = mirroredBlocks(from: events, cap: TerminalBlock.historyCap)

    #expect(blocks.count == 1)
    #expect(blocks[0].command == "rg TODO")
    #expect(blocks[0].origin == .agent)
    #expect(blocks[0].output == ["src/a.swift:4:TODO"])
    #expect(blocks[0].exitCode == 0)
}

@Test func aToolCallWhoseResultHasNotArrivedIsARunningBlockWithNoExitCode() {
    // toolUse arrives the instant the agent issues the call, BEFORE the
    // command runs; toolResult arrives whole when it finishes. So the
    // block appears immediately and fills in on completion — and
    // characters never scroll as they are produced, and cannot, because
    // those Bash calls never reach Wakil while they run. Realtime is true
    // of WHAT it is running, not of watching it scroll. Hence an elapsed
    // counter and no progress bar: Wakil has no idea how far along it is.
    let blocks = mirroredBlocks(
        from: [.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("make")]))],
        cap: TerminalBlock.historyCap)

    #expect(blocks.count == 1)
    #expect(blocks[0].exitCode == nil)
    #expect(blocks[0].durationMs == nil)
}

@Test func aFailedToolResultIsANonZeroExitRatherThanASuccess() {
    let blocks = mirroredBlocks(from: [
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("false")])),
        .toolResult(id: "t1", content: .string("exit 1"), isError: true),
    ], cap: TerminalBlock.historyCap)
    #expect(blocks[0].exitCode == 1)
}

@Test func onlyBashIsMirrored() {
    // A terminal is a shell surface. File reads and edits belong to the
    // thought thread now and the editor pane in Phase 3; mirroring every
    // tool turns the terminal into a second, worse thought thread.
    let blocks = mirroredBlocks(from: [
        .toolUse(id: "t1", name: "Read", input: .object(["file_path": .string("/tmp/x")])),
        .toolUse(id: "t2", name: "mcp__wakil__read_pane", input: .object([:])),
        .toolUse(id: "t3", name: "Bash", input: .object(["command": .string("ls")])),
    ], cap: TerminalBlock.historyCap)

    #expect(blocks.map(\.command) == ["ls"])
}

@Test func theMirrorIsBackfilledWhenThePaneOpensRatherThanStartingEmpty() async {
    // "Not always open a terminal, but when it is open I would like to see
    // it" — a pane opened BECAUSE you want to see what Wakil is doing must
    // not be empty until its next command. The record predates the pane:
    // it is reconstructed from the transcript Wakil already holds.
    let model = WindowModel.forTesting(organization: "alpha")
    await model.receiveForTesting(
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("git status")])))
    await model.receiveForTesting(.toolResult(id: "t1", content: .string("clean"), isError: false))

    let pane = await model.openTerminalForTesting(path: NSTemporaryDirectory())

    let blocks = await model.panesForTesting.terminalBlocks(paneId: pane)
    #expect(blocks.contains { $0.command == "git status" && $0.origin == .agent })
    await model.shutdown()
}

@Test func everyOpenTerminalPaneCarriesTheMirror() async {
    // The alternative was a nearest-cwd heuristic: a rule the operator has
    // to learn and cannot predict with two panes open. The mirror is a
    // VIEW on one record, and a view that appears in one pane and not
    // another is the worse failure. Duplication is what a view is for.
    let model = WindowModel.forTesting(organization: "alpha")
    let first = await model.openTerminalForTesting(path: NSTemporaryDirectory())
    let second = await model.openTerminalForTesting(path: NSTemporaryDirectory())

    await model.receiveForTesting(
        .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("docker ps")])))

    for pane in [first, second] {
        #expect(await model.panesForTesting.terminalBlocks(paneId: pane)
            .contains { $0.command == "docker ps" })
    }
    await model.shutdown()
}

@Test func theMirrorPausesUnderAFullScreenProgramAndCatchesUpWhenItExits() async {
    // Foreign rows cannot be spliced into a live emulator buffer without
    // lying to the shell about where its cursor is.
    let panes = PaneStore()
    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .grid, grid: ["vim"])

    await panes.appendMirrored(paneId: "terminal-1", block: TerminalBlock(
        id: "m1", command: "rg TODO", origin: .agent, exitCode: 0, durationMs: 4,
        output: [], heldTheGrid: false, startedAt: Date()))

    #expect(await panes.terminalBlocks(paneId: "terminal-1").isEmpty)

    await panes.setTerminalLiveState(
        paneId: "terminal-1", cwd: "/tmp", shell: "zsh", cols: 80, rows: 24,
        screen: .blocks, grid: [])

    #expect(await panes.terminalBlocks(paneId: "terminal-1").count == 1)
}

@Test func groupingIsARenderingAndTheSnapshotStillReturnsEveryBlock() async {
    // Consecutive agent blocks collapse into one expandable group on
    // screen, so a turn of six greps does not bury the operator's history
    // in someone else's. The group is a RENDERING, not state.
    let panes = PaneStore()
    for index in 0..<6 {
        await panes.appendMirrored(paneId: "terminal-1", block: TerminalBlock(
            id: "m\(index)", command: "rg \(index)", origin: .agent, exitCode: 0,
            durationMs: 1, output: [], heldTheGrid: false,
            startedAt: Date(timeIntervalSince1970: Double(index))))
    }

    guard case .terminal(let snapshot) = (await panes.snapshot(paneId: "terminal-1", kind: "terminal")).contents
    else { Issue.record("no snapshot"); return }
    #expect(snapshot.blocks.count == 6)
    #expect(snapshot.blocks.allSatisfy { $0.origin == .agent })
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter Mirror`
Expected: FAIL — `mirroredBlocks` is not a function.

- [ ] **Step 3: Write the decode**

Create `app/Sources/WakilKit/Terminal/TerminalMirror.swift` with `mirroredBlocks(from:cap:)` pairing `.toolUse(name: "Bash")` with its `.toolResult` by id; `command` from `input["command"]`; `output` from the result content (a JSON *string* from an MCP server, an array from `ToolSearch` — per the probe, it must not be assumed to be an object); `exitCode` 0 or 1 from `isError`; unmatched calls left running. The doc comment carries the three constraints — `Bash` only, visibly distinct and saying where it ran, and `Rerun` becoming *Propose rerun*.

- [ ] **Step 4: Retain the events and pump them**

In `WindowModel`:

- a bounded `mirrorEvents: [HarnessEvent]` ring, appended in `append(_:)` for `Bash` tool use and results only, capped at `TerminalBlock.historyCap * 2` — **org-derived** in the tripwire (the agent's own commands belong to the org's session).
- on each retained event, `appendMirrored` into **every** open terminal pane.
- `term_open`'s handler already clears the pane; the window backfills immediately afterwards from `mirroredBlocks(from: mirrorEvents, …)`, and the pane says on screen that it is backfilled (Task 16).

- [ ] **Step 5: Pause and catch up in the store**

`appendMirrored` appends to `pausedMirror` when `screen == .grid`, and `setTerminalLiveState` flushes `pausedMirror` into `blocks` on the transition back to `.blocks`.

- [ ] **Step 6: Run the suite, then commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/TerminalMirrorTests.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "feat: the mirror — the agent's own Bash calls, drawn in every terminal pane

A rendering of the harness stream, not an action: nothing is dispatched
and nothing is journalled."
```

---

## Task 16: The pane itself — two surfaces, a proposal, a recessed mirror

The only part of this sub-phase that is not unit-tested, exactly as for every other pane, and the reason the runbook exists. Every construction here is the one the probe measured.

**Files:**
- Create: `app/Sources/WakilApp/TerminalPane.swift`
- Modify: `app/Sources/WakilApp/Canvas.swift` (the second arm)

**Interfaces:**
- Consumes: `WindowModel.terminal(_:)` → `TerminalSnapshot`; `acceptProposal`/`discardProposal`; `dispatchFromSurface`.
- Produces: nothing other code depends on.

- [ ] **Step 1: Draw the live grid as one `Text` per row**

```swift
/// The live grid: the screen a foreground program draws on.
///
/// **One `Text` per row, never one per cell.** The literal reading of "a
/// custom grid renderer" — one addressable view per cell — was measured
/// and **disqualified**: at this pane's own 132×36 it draws 240.5 ms per
/// frame, 4 fps, thirty times slower than the 120fps the spec had in mind,
/// and it is the only construction measured that fails. A `Text` per row
/// is 4.82 ms, 207 fps — 3.4× the budget — and keeps the per-cell
/// selection, hit-testing and accessibility `design-language.md` wants.
///
/// **`Canvas` clears the budget by more and is still declined.** It draws
/// its own text and gives up exactly those three things, for headroom
/// row-wise already has; and its worst frame is 16–18 ms against a ~1 ms
/// median, a spike the other constructions do not have. Reserve it for the
/// case where rows stop holding under real per-cell SGR density — the
/// worse case §5 of the probe says was not measured.
private struct LiveGrid: View {
    let rows: [AttributedString]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                Text(rows[index])
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 15, alignment: .leading)
            }
        }
    }
}
```

- [ ] **Step 2: Draw the block history as a `LazyVStack`**

Measured genuinely lazy: the scroll step is flat at ~5 ms from 2,050 rows to 500,500, and the first layout never approaches 2c-i's 5.3-second cliff. Each block carries its command, its exit code, its duration, and Copy / Rerun / Send to thread. The footer states **both** bounds — *"the last 200 commands · 500 lines each"* — and says so louder when `blocksTruncated`, because a trimmed history must never be mistaken for a short one.

- [ ] **Step 3: Draw the proposal, and the hand-off**

Dashed, in the same lane, at the tail of the history directly above the live prompt, which is where its output will appear. `⏎ to run · ⌫ to discard`. Violet — the pane's only luminous treatment, because **light in this pane tracks exactly one thing: whether a block is asking for the operator's Enter.** Accepting calls `acceptProposal(pane:)`, and the dashed block must be gone before the prompt fills.

- [ ] **Step 4: Draw the mirror, recessed and never lit**

A darker inset with a hatched edge, and its own line: `Wakil's shell · <cwd> · bare environment`. **No third hue** — §5 would refuse one, and it is not needed because emphasis here means one thing. A running mirrored block carries an amber `running` chip, an elapsed counter that ticks because time passes, and the line *"Wakil was told this started. Its output arrives whole when it finishes — nothing scrolls here."* **No bar.** Consecutive agent blocks collapse into one expandable group, and the pane says when the mirror was backfilled. **`Rerun` reads `Propose rerun`** and dispatches `term_propose` — running it here would execute an agent-chosen command with the operator's credentials in the operator's environment, which is the propose path wearing a disguise. `Copy` and `Send to thread` are unaffected.

- [ ] **Step 5: Header, dimensions, resize, `^C`, and ⌘F**

The header carries the **live** cwd — `TerminalSnapshot.cwd`, which OSC 7 keeps current, so a `cd` never leaves it lying — and the shell and dimensions, so the operator can tell what a program thinks its screen is. A pane resize recomputes cols/rows from the monospaced cell metrics and calls `resize`, which sets `TIOCSWINSZ` and signals the child. Keystrokes go to the pty unaltered, so `^C` reaches the foreground process group — which works **because** the shell was spawned with `forkpty`. ⌘F lives **in** the pane rather than floating over it and counts in **blocks**: *"3 blocks · 1 block hidden · no match"*.

- [ ] **Step 6: Structured output, as a per-command allowlist**

Only where the shape is recognised, degrading to plain text the instant it is not. A character grid cannot draw an *Open* button beside a file, and guessing at arbitrary output is how a terminal starts lying about what a program printed. Ship the allowlist with one entry (`ls`) or none; it is the mechanism that matters.

- [ ] **Step 7: Under the grid, park the history and keep Wakil's voice**

While a full-screen program holds the screen the pane **is** that program, and the parked-history strip above the grid carries anything pending — so Wakil does not go silent for as long as `vim` is open, and nothing it draws occupies a cell the program believes it owns.

- [ ] **Step 8: Add the arm in `Canvas.swift`**

```swift
            case "terminal":
                TerminalPane(
                    snapshot: model.terminal(pane.id) ?? .empty,
                    pane: pane,
                    send: { bytes in Task { await model.sendToTerminal(pane: pane.id, bytes: bytes) } },
                    accept: { Task { await model.acceptProposal(pane: pane.id) } },
                    discard: { Task { await model.discardProposal(pane: pane.id) } },
                    dispatch: { name, params in
                        Task { await model.dispatchFromSurface(name, params) }
                    })
```

- [ ] **Step 9: Build, run, look at it**

Run: `make app-build && make app-test`
Then run the app and open a terminal pane by hand. This is the first time any of this is on screen; the runbook is what walks it properly.

- [ ] **Step 10: Commit**

```bash
git add app/Sources/WakilApp
git commit -m "feat: the terminal pane — block history, live grid, proposal, mirror

One Text per row (a Text per cell draws 4fps at 132x36 and is
disqualified); redraw polled at frame rate, never driven from the feed."
```

---

## Task 17: The last doc comment, the runbook, and the record

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`autoResumeAfterSwitch`'s doc comment)
- Create: `docs/wakil/phase-2c-iii-acceptance.md`
- Modify: `docs/wakil/phase-log.md`, `docs/wakil/north-star.md`

**Interfaces:**
- Consumes: everything.
- Produces: the sub-phase's exit evidence.

- [ ] **Step 1: Fix the sixth doc comment**

`autoResumeAfterSwitch`'s **"The RAW `session_list` rows"** paragraph claims the collapse hides what the method wants, then refutes itself in the same sentence by saying the newest member of a chain — which is exactly what the collapse keeps — is what a return visit should continue. Replace it:

```swift
    /// **The RAW `session_list` rows, not `sessionPaletteItems()`, and the
    /// reason is the fields rather than the collapse.** `PaletteItem`
    /// (⌘P's row type) carries only `id`/`kind`/`title`/`subtitle`/
    /// `payload` — no `provider`, no `cwd` — so there is nothing on it to
    /// filter by, and both filters below are load-bearing.
    ///
    /// **`sessionItems(from:)`'s collapse is not the objection**, which is
    /// what this comment used to say before refuting itself one clause
    /// later. It reduces a resume chain to its newest member, which is
    /// right for ⌘P (one row per conversation) and is *also* exactly what
    /// this method wants, since the newest member of a chain is the one a
    /// return visit should continue. The collapse and this method agree;
    /// the missing fields are why the raw rows are read.
    ///
    /// `session_list` itself guarantees newest-first, so the first row
    /// that matches is the newest one — no sorting needed here.
```

- [ ] **Step 2: Write the acceptance runbook**

Create `docs/wakil/phase-2c-iii-acceptance.md`, written **against this plan's checks and against the exit criterion**, following the shape of `phase-2c-ii-acceptance.md`. Each check states what to do, what a pass looks like, and what it leaves unestablished. At minimum:

1. **A real shell runs in the pane.** ⌘K → `term_open` at a path; the prompt appears, `ls` produces a block with an exit code and a duration.
2. **The header carries the live cwd.** `cd /usr/lib`; the header follows.
3. **The shell carries the context.** `echo $WAKIL_ORG $WAKIL_PROJECT $WAKIL_ENVIRONMENT`; all three are the window's.
   **3a. And it carries a usable PATH — walked in the BUNDLE (`make app-bundle`), never from a `swift test` run.** `echo $PATH`, `which kubectl`, `which brew`. A bundled app inherits launchd's environment, so this is the check that catches a shell spawned `-i` instead of `-il`, or an rc that skipped the profile chain. Every unit test in this sub-phase passes either way, which is precisely why this check is walked rather than asserted.
4. **A path outside every project root is accepted silently.** `term_open` at `/usr/lib`; no refusal, no chip, no banner.
5. **An unsupported shell is refused with a reason.** `term_open` naming `/bin/fish`; the message names the shell and the reason.
6. **readline, tab completion and `⌃R` work.** Type a partial path and press Tab; press `⌃R` and search.
7. **A full-screen program takes the whole pane.** `vim`, then `:q`; and the block it left carries its command, its duration and its exit code.
8. **`^C` reaches the foreground program.** `cat` with no argument, then `⌃C`.
9. **Resizing the pane resizes the shell.** Drag the pane wider with `vim` open; it redraws at the new width, and the header's dimensions follow.
10. **`⌘F` counts in blocks.** Search; the count reads in blocks, not lines.
11. **The agent proposes and only your Enter runs it.** Ask the agent for a command; a dashed block appears above the prompt; `⏎` puts it in the prompt **unrun**; the dashed block is gone; `⏎` runs it.
12. **A replacement proposal cannot swap under your hand.** Ask for a second command while the first is pending; one proposal is visible, and the journal has two `term_propose` lines.
13. **`⌫` discards.** The block goes; nothing is written to the shell.
14. **The agent cannot run.** Ask it to run something in the pane; the denial names *this* refusal and points at `term_propose`.
15. **`read_pane` returns both surfaces.** With `vim` open, ask the agent what the last build printed; it answers from `blocks` while `screen` says `grid`.
16. **The mirror.** Give the agent a task that runs `Bash`; the commands appear recessed in every open terminal pane, labelled with where they ran and *bare environment*, never lit. A running one shows a chip and an elapsed counter and no bar.
17. **The mirror is backfilled.** Let the agent work, then open a terminal pane; its commands are already there, marked backfilled.
18. **The mirror pauses under a full-screen program.** Open `vim` while the agent works; no foreign rows appear in the grid, and they are all there on exit.
19. **`Propose rerun`.** A mirrored block's rerun affordance proposes; it does not run.
20. **The bound is stated.** The footer names the block cap and the line cap, and says when the history has been trimmed.
21. **Teardown — pane close.** Start `tail -f`, close the pane; `ps` shows no orphan.
22. **Teardown — org switch.** Start `tail -f`, switch org; the pane vanishes with every other pane, the switch is not blocked, and `ps` shows no orphan.
23. **Teardown — quit.** Two panes with shells; quit; `ps` shows no orphans.
24. **A restored pane comes back empty.** Relaunch; the pane is there, with no shell and no history, awaiting `term_open`.
25. **The six doc comments.** Read each of the six symbols and confirm the comment describes what the code does.
26. **Re-run the probe's measurements 5 and 6 against the real pane**, which is what `scripts/probe/termspike` was kept in the tree for — rather than taking that document's word for it.

- [ ] **Step 3: Record it**

- `docs/wakil/phase-log.md`: a dated entry for the build — what the walk found, what it left unestablished, and **the shape of any mistake it caught**, not only the repair. Note in passing that line 1332's *"marks survive scrollback"* was already corrected by the probe.
- `docs/wakil/north-star.md` §8: 2c-iii's `Met` cell, *walked* or *accepted*, and its runbook named. **Check the word count** (`wc -w docs/wakil/north-star.md`) — it stood at 3,939 against the 4,000 limit, and this sub-phase adds **no new §9 vocabulary**: `PTY`, `terminal pane`, `block`, `block history`, `live grid`, `write gate`, `write price` and `partiality` are all already there, and `TerminalStore` is a type name, not domain language.
- Decision 25's entry in `decisions.md` names the write price as built here rather than as planned.

- [ ] **Step 4: Run everything, then commit**

Run: `make app-test && make test && make app-build`
Expected: PASS.

```bash
git add docs app/Sources/WakilKit/App/WindowModel.swift
git commit -m "docs: the 2c-iii runbook, the last owed doc comment, and the record"
```

---

## Self-Review

Run after the plan is written and before the first task, and again at the end.

**Spec coverage.** Every section of [#72](https://github.com/yehia-khalil/rafiq/issues/72) maps to a task:

| Spec section | Tasks |
|---|---|
| The dependency | 2, 8, 9 |
| `TerminalStore` | 6, 7, 14 |
| Shell integration | 7, 8 |
| Four actions, all `.control` | 10, 11, 12, 13 |
| The write price | 1 |
| `read_pane` as a union | 3, 4, 5, 9 |
| Teardown — three kill points | 14 |
| The mirror | 15 |
| The proposal and the hand-off | 11, 16 |
| Chrome and drawing | 16 |
| The six doc comments | 1 (×2), 3, 4 (×2), 17 |
| Testing decisions | every task's own tests |
| The runbook | 17 |

**The 56 user stories.** 1–9 → Tasks 6, 7, 10, 16. 10–19 → Tasks 7, 8, 9, 16. 20–28 → Tasks 10, 11, 12. 29–36 → Tasks 3, 4, 5, 9, 13. 37–46 → Task 15. 47–53 → Task 14. 54–56 → Tasks 1, 3, 4, 17.

**Type consistency.** `TerminalBlock`, `TerminalBlockOrigin`, `TerminalScreen`, `TerminalSnapshot`, `TerminalStreamEvent`, `TerminalMarkScanner`, `TerminalStore`, `TerminalSession`, `PaneSnapshot`, `GridSnapshot`, `PaneSnapshotContents`, `paneSnapshotJSON` — one spelling each, introduced in one task and consumed by name in later ones. `snapshot(paneId:kind:)` has no default for `kind`, so a terminal pane can never be read as a grid by omission.

**Two placeholders are deliberate and both are named at the point of use:** `TerminalSnapshot` is an empty struct between Tasks 3 and 9, and `TerminalContents` is an empty struct between Tasks 3 and 9. Each is marked in the source with the task that fills it, and neither is ever constructed by shipped code in the interval.

**What the plan does not cover, because the spec puts it out of scope:** an agent-reachable run in any form; `term_rerun` of an enumerated block; an operator-marked rerunnable block (deferred, not refused, until the friction can be measured against a pane that exists); tabs, a session selector, per-pane shell multiplexing; roots in any form; cross-pane value binding; persisting the block history across a relaunch; shells other than zsh and bash; window-close teardown ([#56](https://github.com/yehia-khalil/rafiq/issues/56)); signing and notarisation of a hardened app spawning a PTY (2b-vii, externally blocked).

---

## Appendix A: The bodies elided above

Every `{ ... }` in the tasks above is one of these, or a memberwise initialiser that assigns each parameter to the property of the same name. Nothing else is left to invent.

### A.1 `TerminalStore.publishOnce()` — Task 9, Step 7

```swift
    /// One frame's worth of publishing: every sealed block, and the live
    /// screen when it is dirty. Returns false when there is nothing left
    /// to publish, which is what stops the loop.
    private func publishOnce() async -> Bool {
        guard let panes, !sessions.isEmpty else {
            publisher = nil
            return false
        }
        for (paneId, session) in sessions {
            for block in session.takeCompletedBlocks() {
                await panes.recordTerminal(paneId: paneId, block: block)
                runContinuation?.yield(TerminalRun(
                    paneId: paneId, command: block.command, cwd: session.cwd,
                    exitCode: block.exitCode, durationMs: block.durationMs,
                    wasProposed: session.takeProposedFlag(for: block.id)))
            }
            // The dirty range is the ONLY signal SwiftTerm gives that
            // anything changed, and polling it IS the coalescing: 28 MB of
            // `cat` costs 21 frames and 144–792 repainted rows, against
            // 1,179,666 rows if every 1 KB chunk drew.
            guard session.takeUpdateRange() != nil else { continue }
            await panes.setTerminalLiveState(
                paneId: paneId,
                cwd: session.cwd,
                shell: session.shellName,
                cols: session.cols,
                rows: session.rows,
                screen: session.isAlternateScreen ? .grid : .blocks,
                // Only while a program holds the screen. Otherwise the
                // grid is the shell's own prompt, which the block history
                // already draws — publishing it twice would put the same
                // bytes on screen in two shapes.
                grid: session.isAlternateScreen ? session.screenLines() : [])
        }
        return true
    }
```

### A.2 `terminalPaneTitle(forPath:)` — Task 10, Step 4

```swift
/// The last path component, `~` for home, and the path itself at the root.
///
/// **A name the caller supplied, never an inference.** Wakil does not
/// parse SQL to guess a table, and it does not guess here either; a path
/// is already a name.
func terminalPaneTitle(forPath path: String) -> String {
    let standardised = (path as NSString).standardizingPath
    if standardised == NSHomeDirectory() { return "~" }
    let last = (standardised as NSString).lastPathComponent
    return last.isEmpty ? standardised : last
}
```

### A.3 `PaneStore`'s terminal writers — Task 9, Step 5

```swift
    private func terminal(_ paneId: String) -> TerminalContents {
        guard case .terminal(let contents)? = panes[paneId] else { return TerminalContents() }
        return contents
    }

    private func setTerminal(_ paneId: String, _ contents: TerminalContents) {
        if case .grid? = panes[paneId] { return }
        panes[paneId] = .terminal(contents)
    }

    public func setTerminalLiveState(
        paneId: String, cwd: String, shell: String, cols: Int, rows: Int,
        screen: TerminalScreen, grid: [String]
    ) {
        var contents = terminal(paneId)
        let wasUnderAProgram = contents.screen == .grid
        contents.cwd = cwd
        contents.shell = shell
        contents.cols = cols
        contents.rows = rows
        contents.screen = screen
        contents.grid = grid
        setTerminal(paneId, contents)
        // The mirror catches up the moment the program lets go of the
        // screen. Doing it here rather than in a caller is what makes
        // "pauses and catches up" a property of the storage.
        if wasUnderAProgram, screen == .blocks { flushPausedMirror(paneId) }
    }

    public func setTerminalProposal(paneId: String, _ proposal: TerminalBlock?) {
        var contents = terminal(paneId)
        contents.proposal = proposal
        setTerminal(paneId, contents)
    }

    public func terminalProposal(paneId: String) -> TerminalBlock? { terminal(paneId).proposal }

    public func setTerminalScrollTarget(paneId: String, blockId: String?) {
        var contents = terminal(paneId)
        contents.scrollTarget = blockId
        setTerminal(paneId, contents)
    }

    public func terminalScrollTarget(paneId: String) -> String? { terminal(paneId).scrollTarget }

    /// A new shell is a new history: the old one belonged to a process
    /// that no longer exists. The pane's dimensions are kept, because the
    /// pane did not change size.
    public func clearTerminal(paneId: String) {
        var contents = terminal(paneId)
        contents.blocks = []
        contents.blocksTruncated = false
        contents.grid = []
        contents.screen = .blocks
        contents.proposal = nil
        contents.pausedMirror = []
        contents.scrollTarget = nil
        contents.failure = nil
        setTerminal(paneId, contents)
    }

    /// The mirror's own append, which is the one that can be paused.
    public func appendMirrored(paneId: String, block: TerminalBlock) {
        var contents = terminal(paneId)
        if contents.screen == .grid {
            // Foreign rows cannot be spliced into a live emulator buffer
            // without lying to the shell about where its cursor is.
            if let index = contents.pausedMirror.firstIndex(where: { $0.id == block.id }) {
                contents.pausedMirror[index] = block
            } else {
                contents.pausedMirror.append(block)
            }
            setTerminal(paneId, contents)
            return
        }
        setTerminal(paneId, contents)
        recordTerminal(paneId: paneId, block: block)
    }

    private func flushPausedMirror(_ paneId: String) {
        var contents = terminal(paneId)
        let pending = contents.pausedMirror
        contents.pausedMirror = []
        setTerminal(paneId, contents)
        for block in pending { recordTerminal(paneId: paneId, block: block) }
    }
```

### A.4 `mirroredBlocks(from:cap:)` — Task 15, Step 3

```swift
import Foundation

/// The agent's own `Bash` calls, as blocks for a terminal pane's history.
///
/// **A rendering of the harness stream, not an action.** Nothing is
/// dispatched and nothing is journalled, so Invariant 2 is not engaged.
/// Wakil already receives every command the agent runs, including the
/// `Bash` calls the CLI auto-allows and never asks Wakil about; today it
/// renders them only in the thought thread.
///
/// **`Bash` only.** A terminal is a shell surface; file reads and edits
/// belong to the thought thread now and the editor pane in Phase 3.
/// Mirroring every tool turns the terminal into a second, worse thought
/// thread.
///
/// **An unmatched `toolUse` is a RUNNING block, not a dropped one.**
/// `toolUse` arrives the instant the agent issues the call, *before* the
/// command runs, and `toolResult` arrives whole when it finishes — so the
/// block appears immediately and fills in on completion. Characters never
/// scroll as they are produced and cannot, which is why the pane draws an
/// elapsed counter and never a bar: realtime is true of *what* it is
/// running, not of watching it scroll.
public func mirroredBlocks(
    from events: [HarnessEvent], cap: Int = TerminalBlock.historyCap
) -> [TerminalBlock] {
    var order: [String] = []
    var commands: [String: String] = [:]
    var started: [String: Date] = [:]
    var results: [String: (output: [String], isError: Bool)] = [:]

    for event in events {
        switch event {
        case .toolUse(let id, let name, let input):
            guard name == "Bash", case .object(let fields) = input,
                  case .string(let command)? = fields["command"] else { continue }
            order.append(id)
            commands[id] = command
            started[id] = Date()
        case .toolResult(let id, let content, let isError):
            guard commands[id] != nil else { continue }
            results[id] = (outputLines(of: content), isError)
        default:
            continue
        }
    }

    return order.suffix(cap).map { id in
        let result = results[id]
        return TerminalBlock.capped(
            id: "mirror-\(id)",
            command: commands[id] ?? "",
            origin: .agent,
            // There is no exit code on the wire — only whether the call
            // failed — so this is the honest translation of the one bit
            // Wakil actually has, and `nil` genuinely means still running.
            exitCode: result.map { $0.isError ? 1 : 0 },
            durationMs: result == nil ? nil : 0,
            output: result?.output ?? [],
            heldTheGrid: false,
            startedAt: started[id] ?? Date())
    }
}

/// A tool result's content as lines.
///
/// **It must not be assumed to be an object.** The probe saw it arrive as
/// a JSON *string* from an MCP server and as an array of `tool_reference`
/// objects from `ToolSearch`, so every shape is handled and an unexpected
/// one degrades to its own description rather than to nothing.
private func outputLines(of content: JSONValue) -> [String] {
    switch content {
    case .string(let text):
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
    case .array(let items):
        return items.flatMap { outputLines(of: $0) }
    case .object(let fields):
        if case .string(let text)? = fields["text"] { return outputLines(of: .string(text)) }
        return []
    default:
        return []
    }
}
```

### A.5 `WindowModel`'s pumps and seams — Tasks 11, 14, 15

```swift
    /// Dispatches `term_run` for every block a pane's shell finishes.
    ///
    /// **A pump rather than a call from the store**, for the reason every
    /// other pump here is one: `TerminalStore` is an actor in `WakilKit`
    /// that knows nothing about a registry, and giving it one would be a
    /// second dispatch path — which is exactly what Invariant 2 denies.
    private func startTerminalRunPump() {
        terminalRunPump?.cancel()
        let runs = terminals.completedRuns()
        terminalRunPump = Task { [weak self] in
            for await run in runs {
                guard let self else { return }
                await self.journalTerminalRun(run)
            }
        }
    }

    private func journalTerminalRun(_ run: TerminalRun) async {
        var params: [String: JSONValue] = [
            "pane": .string(run.paneId),
            "command": .string(run.command),
            "cwd": .string(run.cwd),
            // Materially different events, and after the fact the journal
            // is the only place the difference survives.
            "accepted": .string(run.wasProposed ? "proposed" : "typed"),
        ]
        if let code = run.exitCode { params["exitCode"] = .number(Double(code)) }
        if let ms = run.durationMs { params["durationMs"] = .number(Double(ms)) }
        // `origin: .ui` — it was the operator. The agent cannot reach this
        // action, and a command it proposed was still submitted by a human
        // hand; `accepted` is what records that it was proposed.
        //
        // Deliberately NOT `dispatch(_:_:)`: that helper sets `busy`,
        // refreshes panes and writes `status`, none of which belongs on a
        // journal line for something the shell has already done.
        _ = try? await registry.dispatch(
            name: "term_run", params: .object(params), origin: .ui,
            environment: environment, confirmation: nil)
        await refreshPanes()
    }

    /// The operator's `⏎` on a proposal.
    public func acceptProposal(pane: String) async {
        guard let proposal = await panes.terminalProposal(paneId: pane) else { return }
        // Cleared BEFORE the bytes land, or the operator sees the same
        // command twice — once dashed above the prompt, once in it.
        await panes.setTerminalProposal(paneId: pane, nil)
        await terminals.markNextRunProposed(paneId: pane, command: proposal.command)
        // No newline. The command sits in the operator's own prompt,
        // unrun; the second Enter is theirs.
        await terminals.write(paneId: pane, bytes: Array(proposal.command.utf8))
        await refreshPanes()
    }

    /// `⌫`. Nothing is written to the shell.
    public func discardProposal(pane: String) async {
        await panes.setTerminalProposal(paneId: pane, nil)
        await refreshPanes()
    }

    /// Every keystroke the pane receives, straight to the pty — which is
    /// what makes `^C` reach the foreground process group.
    public func sendToTerminal(pane: String, bytes: [UInt8]) async {
        await terminals.write(paneId: pane, bytes: bytes)
    }

    /// TEST-ONLY: opens a terminal pane the way the operator does —
    /// through the registry, so the shipped handler runs. A test that
    /// called `terminals.open` directly would prove nothing about the
    /// path that ships, which is 2b-viii's standing lesson.
    func openTerminalForTesting(path: String) async -> String {
        let result = try? await registry.dispatch(
            name: "term_open", params: .object(["path": .string(path)]),
            origin: .ui, environment: environment, confirmation: nil)
        guard case .object(let fields)? = result, case .string(let pane)? = fields["pane"]
        else { return "" }
        await refreshPanes()
        return pane
    }

    func sendToTerminalForTesting(pane: String, text: String) async {
        await sendToTerminal(pane: pane, bytes: Array(text.utf8))
    }

    /// TEST-ONLY: the `term_run` lines this window has journalled.
    func journalledRuns() async -> [JournalEntry] {
        ((try? await registry.journalEntries()) ?? []).filter { $0.action == "term_run" }
    }

    /// TEST-ONLY: hands one harness event to the same path the pump uses.
    func receiveForTesting(_ event: HarnessEvent) async {
        append(event)
        await mirrorIntoOpenTerminals()
    }
```

`registerTerminalActions` is given `activeContext:` by `WakilWiring.build` as a closure reading the window's own `(organization, project, environment)`, so a shell opened after a context switch carries the context that is active *then* rather than the one that was active when the actions were registered — the same reason `MCPServer.handle` takes `environment` as a closure and not a string.

### A.6 `TerminalStore`'s run stream — Tasks 9 and 11

```swift
/// One finished command, as the window needs it to journal `term_run`.
public struct TerminalRun: Sendable, Equatable {
    public let paneId: String
    public let command: String
    public let cwd: String
    public let exitCode: Int?
    public let durationMs: Int?
    public let wasProposed: Bool
}
```

`completedRuns()` is an `AsyncStream<TerminalRun>` with `bufferingPolicy: .unbounded` — unlike `ActionRegistry.dispatches()`, whose `bufferingNewest(1)` is right for a wake-up and wrong here: a dropped run is a command that ran and was never journalled, which is the one thing this stream exists to prevent. `markNextRunProposed(paneId:command:)` records that the very next block whose command matches was accepted rather than typed, and is cleared once consumed.

**A block still open when a shell is torn down is sealed with a null exit code and yielded before the stream finishes**, so a `tail -f` killed by `pane_close` still leaves a journal line. That is the one place `exitCode: nil` reaches the journal, and it means *the shell was killed before it reported*, not *it succeeded*.
