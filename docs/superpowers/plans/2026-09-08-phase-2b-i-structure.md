# Wakil Phase 2b-i — Structure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Wakil a third action kind, several panes that float and snap against each
other, a rail, and ⌘P/⌘K — with the layout itself dual-driven, so the agent can rearrange
the workspace through the same registry the mouse uses.

**Architecture:** A new `LayoutStore` actor holds pane geometry and a snap graph,
separate from the existing `PaneStore` which keeps holding pane *contents*. A pure
`SnapSolver` free function does the geometry. Eight layout actions register into the
existing `ActionRegistry` at *commit* granularity — a drag updates SwiftUI state at frame
rate and dispatches exactly one action on release. `ActionKind` gains `.control` and
`writeGate` gains `origin` and `targetEnvironment`, so layout is never blocked by the
production rule while an agent-originated switch *into* production still costs a
keystroke.

**Tech Stack:** Swift 6, SwiftPM (`swift build`), Swift Testing (`import Testing`,
`@Test`, `#expect`), SwiftUI + AppKit, Go 1.x for the existing `wakil-ctx` binary this
talks to over MCP.

**Spec:** `docs/superpowers/specs/2026-09-08-phase-2b-i-structure-design.md`

## Global Constraints

- **No styling.** No colours, no motion, no custom fonts, no `design-language.md` in any
  form. That is 2b-ii. Views added here are plain SwiftUI, matching `WakilWindow.swift`'s
  existing deliberate ugliness.
- **Deployment target stays `macOS 14.4`** (`app/Package.swift`). Do not raise it.
- **No new package dependencies.** The fuzzy scorer is written by hand.
- **Action names match `^[a-zA-Z0-9_-]{1,128}$`** — `<area>_<verb>`, underscores, never
  dots. `StandardActionsTests.everyRegisteredActionNameSatisfiesTheAnthropicToolNameRule`
  enforces this; do not weaken it.
- **Zero `.mutate` actions still.** Nothing in this plan registers one.
- **Tests never touch the real `~/.wakil`, the Keychain, or a live `claude`
  subscription.** Use a scratch `HOME` and `WAKIL_BIN_DIR`, as the existing tests do.
- **`WakilKitTests` cannot import `WakilApp`** (a test target cannot import an executable
  target). Anything that must be tested lives in `WakilKit`.
- Build and test with `make app-build` and `make app-test`.

---

## File Structure

**Create, in `app/Sources/WakilKit/`:**

| File | Responsibility |
|---|---|
| `Layout/Pane.swift` | `PaneFrame`, `SnapEdge`, `Pane` — pure value types, no AppKit |
| `Layout/SnapSolver.swift` | Pure geometry: given a proposed frame and its neighbours, the best snap candidate or none |
| `Layout/SnapGraph.swift` | The stored adjacency: add, remove, neighbours-along-an-edge |
| `Layout/LayoutStore.swift` | The actor: per-project pane sets, focus, maximize, and the graph |
| `Layout/LayoutActions.swift` | Registers the eight `.control` layout actions |
| `Layout/LayoutPersistence.swift` | Codable snapshot, read and write under `~/.wakil/layouts/` |
| `Command/PaletteItem.swift` | `PaletteItem` and the fuzzy scorer |

**Modify:**

| File | Change |
|---|---|
| `Registry/Action.swift` | `ActionKind` gains `.control` |
| `Gate/WriteGate.swift` | `origin` and `targetEnvironment` parameters |
| `Registry/ActionRegistry.swift` | Pass `origin` and a resolved target to the gate |
| `Registry/StandardActions.swift` | `ctx_*` setters → `.control`; add `session_list` |
| `App/WindowModel.swift` | `agentAllowedTools` admits `.control`; pane `busy` tracking |
| `MCP/MCPServer.swift` | `read_layout`, alongside `read_pane` |
| `App/AppWiring.swift` | Build and wire `LayoutStore` |
| `WakilApp/WakilWindow.swift` | Canvas, drag/border gestures, rail, palettes |

**Task order rationale.** The gate change (Tasks 1–3) lands first because every later
action depends on `.control` existing. Geometry (4–6) is pure and testable with no
dependencies. The store (7) needs the geometry; the actions (8) need the store; the MCP
and agent surface (9–10) need the actions. Persistence (11) needs the store. UI (12–14)
needs everything. Task 15 is the runbook.

---

### Task 1: The third `ActionKind`

**Files:**
- Modify: `app/Sources/WakilKit/Registry/Action.swift:1-9`
- Test: `app/Tests/WakilKitTests/WriteGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ActionKind.control`, a third case on the existing
  `public enum ActionKind: String, Sendable`.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/WriteGateTests.swift`:

```swift
@Test func actionKindHasThreeCasesWithStableRawValues() {
    #expect(ActionKind.read.rawValue == "read")
    #expect(ActionKind.control.rawValue == "control")
    #expect(ActionKind.mutate.rawValue == "mutate")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter actionKindHasThreeCasesWithStableRawValues`
Expected: FAIL to **compile**, with "type 'ActionKind' has no member 'control'".

- [ ] **Step 3: Write minimal implementation**

In `app/Sources/WakilKit/Registry/Action.swift`, replace the enum:

```swift
/// Whether an action only reads state, changes Wakil's own state, or can
/// change the world outside Wakil. `ActionRegistry` consults this on every
/// `dispatch` call, before the handler runs, to decide what `writeGate`
/// does about it.
///
/// **Why there are three and not two.** The gate asks one question —
/// *could this damage the world outside Wakil?* — and some actions answer
/// "no" while still changing something. Moving a pane, switching the
/// active project: nothing outside the app is touched. Filed `.mutate`,
/// the gate blocks them in `production`, so a pane could not be dragged
/// while pointed at a production database. Filed `.read`, they run
/// unchecked from every origin, agent included — which is how 2a's
/// acceptance run found the agent re-pointing the active context unasked
/// (`docs/wakil/phase-2a-acceptance.md` §6). `.control` is the answer to
/// both: never blocked by environment, but distinguishable at the gate.
public enum ActionKind: String, Sendable {
    /// Observes state. Changes nothing. Never gated.
    case read
    /// Changes Wakil's own state — pane geometry, the active context.
    /// The world outside Wakil is untouched, so the environment never
    /// blocks it.
    case control
    /// Changes the world outside Wakil. Gated everywhere, blocked in
    /// production.
    case mutate
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter actionKindHasThreeCasesWithStableRawValues`
Expected: PASS.

Then run the whole suite: `make app-test`. Expected: PASS — nothing switches on
`ActionKind` exhaustively yet, so adding a case breaks nothing.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/Action.swift app/Tests/WakilKitTests/WriteGateTests.swift
git commit -m "feat(registry): add ActionKind.control for changes to Wakil's own state"
```

---

### Task 2: The origin-aware write gate

**Files:**
- Modify: `app/Sources/WakilKit/Gate/WriteGate.swift` (whole file)
- Test: `app/Tests/WakilKitTests/WriteGateTests.swift`

**Interfaces:**
- Consumes: `ActionKind.control` (Task 1), `ActionOrigin` (existing, in `Action.swift`).
- Produces:
  ```swift
  public func writeGate(
      environment: String,
      kind: ActionKind,
      origin: ActionOrigin,
      targetEnvironment: String?
  ) -> GateDecision
  ```
  `GateDecision` is unchanged: `.allow`, `.gate`, `.block`.

- [ ] **Step 1: Write the failing test**

Replace the entire body of `app/Tests/WakilKitTests/WriteGateTests.swift` (keeping the
`actionKindHasThreeCasesWithStableRawValues` test from Task 1) with:

```swift
import Testing
@testable import WakilKit

@Test func actionKindHasThreeCasesWithStableRawValues() {
    #expect(ActionKind.read.rawValue == "read")
    #expect(ActionKind.control.rawValue == "control")
    #expect(ActionKind.mutate.rawValue == "mutate")
}

// MARK: - Reads

@Test func readsAreAllowedInEveryEnvironmentFromEveryOrigin() {
    for env in ["local", "staging", "production", "anything-else"] {
        for origin in [ActionOrigin.ui, .agent, .debug] {
            #expect(
                writeGate(environment: env, kind: .read, origin: origin, targetEnvironment: nil)
                    == .allow)
        }
    }
}

// MARK: - Mutations (unchanged from 2a)

@Test func mutationsAreGatedOutsideProduction() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "staging", kind: .mutate, origin: origin, targetEnvironment: nil)
                == .gate)
        #expect(
            writeGate(environment: "local", kind: .mutate, origin: origin, targetEnvironment: nil)
                == .gate)
    }
}

@Test func mutationsAreBlockedOutrightInProduction() {
    for origin in [ActionOrigin.ui, .agent, .debug] {
        #expect(
            writeGate(environment: "production", kind: .mutate, origin: origin, targetEnvironment: nil)
                == .block)
    }
}

@Test func productionMatchIsExactAndCaseInsensitive() {
    #expect(
        writeGate(environment: "PRODUCTION", kind: .mutate, origin: .ui, targetEnvironment: nil)
            == .block)
    #expect(
        writeGate(environment: "Production", kind: .mutate, origin: .ui, targetEnvironment: nil)
            == .block)
    // An unknown environment is gated, not blocked — but never silently allowed.
    #expect(
        writeGate(environment: "prod", kind: .mutate, origin: .ui, targetEnvironment: nil)
            == .gate)
}

// MARK: - Control

@Test func controlIsAllowedFromTheUIAndDebugEverywhere() {
    for env in ["local", "staging", "production"] {
        for origin in [ActionOrigin.ui, .debug] {
            // Including when the target is production: an operator typing it
            // has already decided.
            #expect(
                writeGate(
                    environment: env, kind: .control, origin: origin,
                    targetEnvironment: "production") == .allow)
            #expect(
                writeGate(environment: env, kind: .control, origin: origin, targetEnvironment: nil)
                    == .allow)
        }
    }
}

@Test func controlIsAllowedFromTheAgentWhenNoProductionTargetIsNamed() {
    // The overwhelming majority: every layout action, and a context switch
    // that is not into production.
    for env in ["local", "staging", "production"] {
        #expect(
            writeGate(environment: env, kind: .control, origin: .agent, targetEnvironment: nil)
                == .allow)
        #expect(
            writeGate(environment: env, kind: .control, origin: .agent, targetEnvironment: "staging")
                == .allow)
    }
}

@Test func controlIsGatedWhenTheAgentTargetsProduction() {
    // The one row that exists because of the 2a acceptance finding: an agent
    // may propose entering production, never perform it unasked.
    #expect(
        writeGate(
            environment: "staging", kind: .control, origin: .agent,
            targetEnvironment: "production") == .gate)
    // Already being in production does not exempt it — the target is what counts.
    #expect(
        writeGate(
            environment: "production", kind: .control, origin: .agent,
            targetEnvironment: "production") == .gate)
}

@Test func theAgentsProductionTargetMatchIsCaseInsensitiveToo() {
    for target in ["PRODUCTION", "Production", "production"] {
        #expect(
            writeGate(
                environment: "staging", kind: .control, origin: .agent,
                targetEnvironment: target) == .gate)
    }
    // A near-miss is not production and is not gated: `.control` has no
    // "unknown environment" caution rule, because there is nothing outside
    // Wakil for an unrecognised name to endanger.
    #expect(
        writeGate(
            environment: "staging", kind: .control, origin: .agent, targetEnvironment: "prod")
            == .allow)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter WriteGate`
Expected: FAIL to compile — "extra arguments 'origin', 'targetEnvironment' in call".

- [ ] **Step 3: Write minimal implementation**

Replace `app/Sources/WakilKit/Gate/WriteGate.swift` in full:

```swift
import Foundation

/// What `writeGate` decided about a proposed action.
///
/// `.allow` runs unconditionally. `.gate` runs only if the caller supplied
/// the exact confirmation string `dispatch` requires. `.block` never runs,
/// regardless of confirmation — production mutation is not something a
/// caller can opt back into by passing the right string.
public enum GateDecision: Equatable, Sendable {
    case allow
    case gate
    case block
}

/// The single policy function standing between "an action was requested"
/// and "an action's handler ran". `ActionRegistry.dispatch` calls this
/// before running any handler, for every dispatch, regardless of origin.
///
/// | Kind | Origin | Decision |
/// |---|---|---|
/// | `.read` | any | `.allow` |
/// | `.control` | `.ui`, `.debug` | `.allow` |
/// | `.control` | `.agent`, target is production | `.gate` |
/// | `.control` | `.agent`, otherwise | `.allow` |
/// | `.mutate` | any | `.block` in production, `.gate` elsewhere |
///
/// **Reads** are always allowed: read-only actions cannot corrupt state, so
/// there is nothing for an environment check to protect against.
///
/// **Mutations** are blocked outright in production and gated everywhere
/// else, including an environment string this function doesn't recognize.
/// An unrecognized environment name is a sign of a misconfiguration, not a
/// request to skip caution — the default for "we don't know what this is"
/// must be the stricter of the two non-block outcomes, never `.allow`.
///
/// **Control** actions change Wakil and not the world, so `environment`
/// never blocks them: dragging a pane while pointed at a production
/// database must work, and gating a context switch in production would
/// block it exactly when an operator most needs to go *look* at something.
///
/// The one exception is `origin == .agent` with a `targetEnvironment` of
/// production, and it exists because of a specific incident rather than a
/// general worry. During the 2026-09-08 acceptance run the agent, asked
/// only to *list* projects, also set the active one
/// (`docs/wakil/phase-2a-acceptance.md` §6). Nothing stopped it, because
/// the setters were `.read`. The active `(org, project, environment)` is
/// what every later action resolves against, so an agent that moves it
/// unasked silently redirects everything after it. Gating only the
/// production target keeps the Phase 2 exit criterion — *"open the booking
/// project on staging, fetch the latest reservation…"*, spoken in one
/// breath — free of confirmations, while making entry into production cost
/// a human keystroke whoever asked for it.
///
/// **Note the asymmetry in unknown names.** `.mutate` treats an
/// unrecognised `environment` as cause for caution (`.gate`), because
/// something outside Wakil might be at stake. `.control` treats an
/// unrecognised `targetEnvironment` as simply not-production (`.allow`),
/// because nothing outside Wakil is. `"prod"` therefore gates a mutation
/// and allows a control action, and that is intended rather than an
/// inconsistency.
///
/// Both environment comparisons lowercase their input and compare to
/// exactly `"production"`, so `"PRODUCTION"`, `"Production"` and
/// `"production"` all match while `"prod"` does not.
public func writeGate(
    environment: String,
    kind: ActionKind,
    origin: ActionOrigin,
    targetEnvironment: String?
) -> GateDecision {
    switch kind {
    case .read:
        return .allow
    case .control:
        guard origin == .agent, isProduction(targetEnvironment) else { return .allow }
        return .gate
    case .mutate:
        return isProduction(environment) ? .block : .gate
    }
}

/// Whether `name` is the production environment. `nil` is not production:
/// an action that names no target cannot be entering one.
private func isProduction(_ name: String?) -> Bool {
    guard let name else { return false }
    return name.lowercased() == "production"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter WriteGate`
Expected: PASS, all nine tests.

`make app-test` will still FAIL to compile at this point, because
`ActionRegistry.dispatch` calls the old two-argument `writeGate`. Task 3 fixes that;
this is expected and is the reason the two tasks are adjacent.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Gate/WriteGate.swift app/Tests/WakilKitTests/WriteGateTests.swift
git commit -m "feat(gate): make writeGate origin-aware, gating agent entry into production"
```

---

### Task 3: `ActionRegistry` resolves the target and calls the new gate

**Files:**
- Modify: `app/Sources/WakilKit/Registry/ActionRegistry.swift` (the `dispatch` method and
  its doc comment)
- Test: `app/Tests/WakilKitTests/ActionRegistryTests.swift`

**Interfaces:**
- Consumes: `writeGate(environment:kind:origin:targetEnvironment:)` (Task 2).
- Produces: `Action` gains one field —
  ```swift
  public var targetEnvironmentParam: String?
  ```
  the name of the params key holding this action's target environment, or `nil` for
  actions that have none. `Action.init` takes it last, defaulted to `nil`, so every
  existing construction site compiles unchanged. `ActionDescriptor` does **not** gain it:
  it is a gate input, not part of the tool's advertised shape.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/ActionRegistryTests.swift`:

```swift
@Test func dispatchGatesAnAgentControlActionNamingProduction() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("registry-gate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "ctx_set_environment_stub",
        description: "stub",
        kind: .control,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) },
        targetEnvironmentParam: "name"
    ))

    // Agent, target production: gated, and the handler never runs.
    await #expect(throws: ActionError.needsConfirmation("ctx_set_environment_stub")) {
        _ = try await registry.dispatch(
            name: "ctx_set_environment_stub",
            params: .object(["name": .string("production")]),
            origin: .agent, environment: "staging", confirmation: nil)
    }
    #expect(await ran.count == 0)

    // Same call with the confirmation: runs.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("production")]),
        origin: .agent, environment: "staging", confirmation: "confirm")
    #expect(await ran.count == 1)

    // Same call from the UI: runs with no confirmation.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("production")]),
        origin: .ui, environment: "staging", confirmation: nil)
    #expect(await ran.count == 2)

    // Agent, target staging: runs with no confirmation.
    _ = try await registry.dispatch(
        name: "ctx_set_environment_stub",
        params: .object(["name": .string("staging")]),
        origin: .agent, environment: "staging", confirmation: nil)
    #expect(await ran.count == 3)

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["gated", "ok", "ok", "ok"])
}

@Test func aControlActionWithNoTargetParamIsNeverGated() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("registry-gate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")

    let ran = Ran()
    await registry.register(Action(
        name: "pane_move_stub",
        description: "stub",
        kind: .control,
        schema: .object([:]),
        handler: { _ in await ran.mark(); return .object([:]) }
    ))

    // A layout action carrying a params value that happens to read
    // "production" must still not be gated: it names no target
    // environment, so there is no key for the gate to read.
    _ = try await registry.dispatch(
        name: "pane_move_stub",
        params: .object(["name": .string("production")]),
        origin: .agent, environment: "production", confirmation: nil)
    #expect(await ran.count == 1)
}

/// A counter an escaping `@Sendable` handler can bump.
actor Ran {
    private(set) var count = 0
    func mark() { count += 1 }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter dispatchGatesAnAgentControlActionNamingProduction`
Expected: FAIL to compile — "extra argument 'targetEnvironmentParam' in call".

- [ ] **Step 3: Write minimal implementation**

**3a.** In `app/Sources/WakilKit/Registry/Action.swift`, add the field to `Action` (leave
`ActionDescriptor` alone):

```swift
    /// The name of the params key holding this action's *target*
    /// environment — the environment that will be active after it runs —
    /// or `nil` for the actions that have none, which is almost all of
    /// them.
    ///
    /// Only `ctx_set_environment` sets this. It is read by
    /// `ActionRegistry.dispatch` and handed to `writeGate`, which uses it
    /// for exactly one decision: whether an agent is entering production.
    ///
    /// **`ctx_set_project` deliberately does not set it.**
    /// `wakilcore.SetProjectChecked` keeps the current environment name if
    /// the incoming project defines one by that name and otherwise clears
    /// it to `""` — there is no per-project "last environment" on disk to
    /// restore. So switching project can only preserve the current
    /// environment or drop to none; it can never elevate staging into
    /// production, and there is nothing for the gate to catch.
    /// `StandardActionsTests` pins that Phase 1 behaviour so a change to it
    /// fails a test here rather than quietly widening this gate.
    public var targetEnvironmentParam: String?
```

Add it as the last `init` parameter, defaulted:

```swift
    public init(
        name: String,
        description: String,
        kind: ActionKind,
        schema: JSONValue,
        handler: @escaping @Sendable (JSONValue) async throws -> JSONValue,
        targetEnvironmentParam: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.schema = schema
        self.handler = handler
        self.targetEnvironmentParam = targetEnvironmentParam
    }
```

**3b.** In `app/Sources/WakilKit/Registry/ActionRegistry.swift`, replace the `switch
writeGate(...)` line and add the resolver. The `switch` becomes:

```swift
        switch writeGate(
            environment: environment,
            kind: action.kind,
            origin: origin,
            targetEnvironment: targetEnvironment(of: action, in: params))
        {
```

and add this private method to the actor:

```swift
    /// The environment `action` will make active, read out of its own
    /// `params` — or `nil` when the action names no target (the usual
    /// case) or when the key it names is absent or not a string.
    ///
    /// A missing or non-string value resolves to `nil`, which
    /// `writeGate` treats as "not production" and therefore allows. That
    /// is safe here and would not be for a mutation: a `.control` action
    /// changes nothing outside Wakil, so the worst a malformed target can
    /// do is skip a confirmation on a switch that the handler is itself
    /// about to reject for the same malformed value.
    private func targetEnvironment(of action: Action, in params: JSONValue) -> String? {
        guard let key = action.targetEnvironmentParam,
              case .object(let object) = params,
              case .string(let value)? = object[key]
        else { return nil }
        return value
    }
```

**3c.** Update `dispatch`'s doc comment, step 2, to read:

```
    /// 2. Consult `writeGate(environment:kind:origin:targetEnvironment:)`
    ///    before anything else runs, resolving the target environment out
    ///    of `params` first (see `targetEnvironment(of:in:)`).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make app-test`
Expected: PASS — the whole suite, including every 2a test, since `.read` and `.mutate`
behaviour is byte-for-byte what it was.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/Action.swift \
        app/Sources/WakilKit/Registry/ActionRegistry.swift \
        app/Tests/WakilKitTests/ActionRegistryTests.swift
git commit -m "feat(registry): resolve an action's target environment and pass origin to the gate"
```

---

### Task 4: Pane value types

**Files:**
- Create: `app/Sources/WakilKit/Layout/Pane.swift`
- Test: `app/Tests/WakilKitTests/PaneTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  public struct PaneFrame: Sendable, Equatable, Codable {
      public var x: Double, y: Double, width: Double, height: Double
      public init(x: Double, y: Double, width: Double, height: Double)
      public var minX: Double { x }
      public var maxX: Double { x + width }
      public var minY: Double { y }
      public var maxY: Double { y + height }
      public func intersects(_ other: PaneFrame) -> Bool
  }
  public enum SnapEdge: String, Sendable, Codable, CaseIterable {
      case left, right, top, bottom
      public var opposite: SnapEdge
      public var isHorizontal: Bool   // left/right
  }
  public struct Pane: Sendable, Equatable, Identifiable, Codable {
      public let id: String
      public let kind: String
      public var title: String
      public var frame: PaneFrame
      public var busy: Bool
      public init(id: String, kind: String, title: String, frame: PaneFrame, busy: Bool = false)
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaneTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func paneFrameEdgesAreDerivedFromOriginAndSize() {
    let f = PaneFrame(x: 10, y: 20, width: 100, height: 50)
    #expect(f.minX == 10)
    #expect(f.maxX == 110)
    #expect(f.minY == 20)
    #expect(f.maxY == 70)
}

@Test func framesIntersectOnlyWhenTheyOverlapInBothAxes() {
    let a = PaneFrame(x: 0, y: 0, width: 100, height: 100)
    #expect(a.intersects(PaneFrame(x: 50, y: 50, width: 100, height: 100)))
    // Touching edges is not intersecting — snapped panes sit flush and
    // must not report an overlap.
    #expect(!a.intersects(PaneFrame(x: 100, y: 0, width: 100, height: 100)))
    #expect(!a.intersects(PaneFrame(x: 0, y: 100, width: 100, height: 100)))
    // Overlapping in x alone is not an intersection.
    #expect(!a.intersects(PaneFrame(x: 50, y: 200, width: 100, height: 100)))
}

@Test func snapEdgeOppositesAndAxes() {
    #expect(SnapEdge.left.opposite == .right)
    #expect(SnapEdge.right.opposite == .left)
    #expect(SnapEdge.top.opposite == .bottom)
    #expect(SnapEdge.bottom.opposite == .top)
    #expect(SnapEdge.left.isHorizontal)
    #expect(SnapEdge.right.isHorizontal)
    #expect(!SnapEdge.top.isHorizontal)
    #expect(!SnapEdge.bottom.isHorizontal)
}

@Test func aPaneRoundTripsThroughJSON() throws {
    let pane = Pane(
        id: "db-1", kind: "db", title: "Query results",
        frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data) == pane)
}

@Test func aNewPaneIsNotBusy() {
    let pane = Pane(
        id: "db-1", kind: "db", title: "t",
        frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    #expect(!pane.busy)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter PaneTests`
Expected: FAIL to compile — "cannot find 'PaneFrame' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/Pane.swift`:

```swift
import Foundation

/// One pane's rectangle on the canvas, in canvas points.
///
/// A plain value type rather than `CGRect` so that `LayoutStore` and
/// `SnapSolver` — where all the geometry actually happens — stay free of
/// CoreGraphics and AppKit, and can therefore be exercised in
/// `WakilKitTests` without a display. The view layer converts to `CGRect`
/// at the boundary and nowhere else.
///
/// `y` grows **downward**, matching SwiftUI's coordinate space, so `minY`
/// is the top edge. Getting this backwards is the obvious way to write a
/// snap solver that works in tests and is upside down on screen.
public struct PaneFrame: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    /// The top edge — `y` grows downward.
    public var minY: Double { y }
    /// The bottom edge.
    public var maxY: Double { y + height }

    /// Whether the two rectangles overlap in **both** axes.
    ///
    /// Touching is deliberately not intersecting: two snapped panes sit
    /// exactly flush, so a `<=` here would report every snapped pair as
    /// overlapping and make "is this arrangement valid?" permanently
    /// false.
    public func intersects(_ other: PaneFrame) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

/// Which side of a pane a snap relates to.
public enum SnapEdge: String, Sendable, Codable, CaseIterable {
    case left, right, top, bottom

    /// The edge that meets this one when two panes snap: a pane's `right`
    /// sits against its neighbour's `left`.
    public var opposite: SnapEdge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// True for `left` and `right` — the edges that move along the x axis.
    /// A horizontal edge's snap matches *height*; a vertical one's matches
    /// *width*.
    public var isHorizontal: Bool { self == .left || self == .right }
}

/// One pane on the canvas: what it is, what it is called, and where it sits.
///
/// **Contents are not here.** What is *inside* a pane — columns, rows,
/// `truncated` — stays in `PaneStore`, which the agent reads through
/// `read_pane` and which 2c rewrites when the real data surface lands.
/// Geometry has a different writer, a different lifetime and different
/// persistence, so merging the two would put 2c's churn on top of this
/// phase's layout invariants.
///
/// `kind` is a string rather than an enum because 2b-i ships exactly one
/// kind (`"db"`) and 2c is where the real pane types arrive. An enum with
/// one case would be a decision made before its requirements exist.
public struct Pane: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let kind: String
    public var title: String
    public var frame: PaneFrame
    /// True while a dispatched action naming this pane is in flight. The
    /// rail reads it; nothing else does. Set and cleared by `WindowModel`
    /// around a dispatch, which is the whole of §9's "a working pane glows
    /// green in the periphery" — there is no spinner and none is wanted.
    public var busy: Bool

    public init(id: String, kind: String, title: String, frame: PaneFrame, busy: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.busy = busy
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter PaneTests`
Expected: PASS, all five tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/Pane.swift app/Tests/WakilKitTests/PaneTests.swift
git commit -m "feat(layout): add Pane, PaneFrame and SnapEdge value types"
```

---

### Task 5: The snap solver

**Files:**
- Create: `app/Sources/WakilKit/Layout/SnapSolver.swift`
- Test: `app/Tests/WakilKitTests/SnapSolverTests.swift`

**Interfaces:**
- Consumes: `PaneFrame`, `SnapEdge` (Task 4).
- Produces:
  ```swift
  public let snapThreshold: Double   // 8.0
  public struct SnapCandidate: Sendable, Equatable {
      public let edge: SnapEdge          // the dragged pane's edge that snaps
      public let toPaneId: String?       // nil means the void edge
      public let frame: PaneFrame        // where the dragged pane lands
  }
  public func snapCandidate(
      for proposed: PaneFrame,
      neighbours: [(id: String, frame: PaneFrame)],
      void: PaneFrame,
      threshold: Double = snapThreshold
  ) -> SnapCandidate?
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/SnapSolverTests.swift`:

```swift
import Testing
@testable import WakilKit

private let void = PaneFrame(x: 0, y: 0, width: 1000, height: 800)

@Test func noNeighbourAndNoVoidEdgeInRangeMeansNoCandidate() {
    let proposed = PaneFrame(x: 400, y: 400, width: 100, height: 100)
    #expect(snapCandidate(for: proposed, neighbours: [], void: void) == nil)
}

@Test func aPanesRightEdgeSnapsToANeighboursLeftEdge() {
    // Neighbour's left edge is at x = 500. The dragged pane's right edge
    // lands at 496 — 4pt short, inside the 8pt threshold.
    let neighbour = PaneFrame(x: 500, y: 100, width: 200, height: 300)
    let proposed = PaneFrame(x: 296, y: 100, width: 200, height: 300)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.edge == .right)
    #expect(candidate?.toPaneId == "db-2")
    // Flush: the dragged pane's right edge now sits exactly on 500.
    #expect(candidate?.frame.maxX == 500)
    // And the extent along the shared edge is matched — a horizontal edge
    // matches height.
    #expect(candidate?.frame.minY == 100)
    #expect(candidate?.frame.height == 300)
}

@Test func aPanesBottomEdgeSnapsToANeighboursTopEdge() {
    let neighbour = PaneFrame(x: 100, y: 500, width: 300, height: 200)
    let proposed = PaneFrame(x: 100, y: 205, width: 300, height: 290)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.edge == .bottom)
    #expect(candidate?.toPaneId == "db-2")
    #expect(candidate?.frame.maxY == 500)
    // A vertical edge matches width.
    #expect(candidate?.frame.minX == 100)
    #expect(candidate?.frame.width == 300)
}

@Test func aPaneSnapsToTheVoidEdgeWhenNoNeighbourIsNearer() {
    // Left edge 5pt from the void's own left edge.
    let proposed = PaneFrame(x: 5, y: 300, width: 200, height: 100)
    let candidate = snapCandidate(for: proposed, neighbours: [], void: void)
    #expect(candidate?.edge == .left)
    #expect(candidate?.toPaneId == nil)
    #expect(candidate?.frame.minX == 0)
    // Snapping to the void does not resize: there is no neighbour whose
    // extent to match.
    #expect(candidate?.frame.width == 200)
    #expect(candidate?.frame.height == 100)
}

@Test func exactlyAtTheThresholdSnapsAndBeyondItDoesNot() {
    let atThreshold = PaneFrame(x: 8, y: 300, width: 200, height: 100)
    #expect(snapCandidate(for: atThreshold, neighbours: [], void: void)?.edge == .left)

    let beyond = PaneFrame(x: 8.01, y: 300, width: 200, height: 100)
    #expect(snapCandidate(for: beyond, neighbours: [], void: void) == nil)
}

@Test func theNearestCandidateWins() {
    // Void left edge is 7pt away; the neighbour's right edge is 2pt away.
    let neighbour = PaneFrame(x: 0, y: 300, width: 5, height: 100)
    let proposed = PaneFrame(x: 7, y: 300, width: 200, height: 100)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.toPaneId == "db-2")
    #expect(candidate?.edge == .left)
    #expect(candidate?.frame.minX == 5)
}

@Test func aNeighbourThatDoesNotOverlapAlongTheSharedEdgeIsNotACandidate() {
    // The neighbour's left edge is 4pt away in x, but it sits far below:
    // there is no shared edge to snap along, so this must not snap.
    let neighbour = PaneFrame(x: 500, y: 700, width: 200, height: 90)
    let proposed = PaneFrame(x: 296, y: 100, width: 200, height: 300)
    #expect(snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void) == nil)
}

@Test func aPaneNeverSnapsToItselfBecauseItIsNotInNeighbours() {
    // Documents the contract: the caller excludes the dragged pane. Given
    // an empty neighbour list, an otherwise perfect self-overlap yields
    // only the void answer, or none.
    let proposed = PaneFrame(x: 400, y: 400, width: 100, height: 100)
    #expect(snapCandidate(for: proposed, neighbours: [], void: void) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter SnapSolverTests`
Expected: FAIL to compile — "cannot find 'snapCandidate' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/SnapSolver.swift`:

```swift
import Foundation

/// How close a dragged edge must come before it snaps, in canvas points.
///
/// One constant, in one place. §10 says "within a few pixels"; 8 is the
/// value that number became, and it is exported so the view can draw the
/// snap line using the same figure the solver decides with rather than a
/// second one that drifts.
public let snapThreshold: Double = 8.0

/// One way a dragged pane could snap: which of *its* edges is involved,
/// what it snaps to, and the frame it would take.
///
/// `toPaneId` is `nil` for the void's own edge, which is a snap target
/// like any other but has no pane behind it.
public struct SnapCandidate: Sendable, Equatable {
    public let edge: SnapEdge
    public let toPaneId: String?
    public let frame: PaneFrame

    public init(edge: SnapEdge, toPaneId: String?, frame: PaneFrame) {
        self.edge = edge
        self.toPaneId = toPaneId
        self.frame = frame
    }
}

/// The best snap for `proposed`, or `nil` if nothing is within `threshold`.
///
/// Pure: no state, no framework, no dependency on `LayoutStore`. This is
/// the one piece of 2b-i with real algorithmic content, and keeping it a
/// free function over plain values is what lets it be tested exhaustively
/// instead of through a view.
///
/// **The caller excludes the dragged pane from `neighbours`.** A pane
/// overlaps itself perfectly, so leaving it in would make every drag snap
/// to where it already was.
///
/// **Two rules decide a candidate.**
///
/// 1. *Proximity.* The dragged pane's edge must land within `threshold` of
///    the target edge. The comparison is `<=`, so a drag that lands
///    exactly on the threshold snaps — a boundary that excluded it would
///    make the last point of the range unreachable in practice.
/// 2. *Overlap along the shared edge.* Two panes only snap if they
///    actually face each other: a pane 4pt from another's left edge but
///    600pt below it shares no edge, and snapping them would teleport one
///    across the canvas. Checked on the perpendicular axis.
///
/// Among the candidates that pass both, the **nearest** wins, and a
/// neighbour beats the void at equal distance because it is the more
/// specific relationship.
///
/// **Snapping to a pane matches extent; snapping to the void does not.**
/// §10 says releasing against another pane "locks it flush and matches
/// height" — so a `left`/`right` snap takes the neighbour's `y` and
/// `height`, and a `top`/`bottom` snap takes its `x` and `width`. The void
/// has no extent worth matching (matching it would maximise the pane), so
/// a void snap only moves.
public func snapCandidate(
    for proposed: PaneFrame,
    neighbours: [(id: String, frame: PaneFrame)],
    void: PaneFrame,
    threshold: Double = snapThreshold
) -> SnapCandidate? {
    var best: (distance: Double, candidate: SnapCandidate)?

    func consider(_ distance: Double, _ candidate: SnapCandidate, neighbourWins: Bool) {
        guard distance <= threshold else { return }
        guard let current = best else {
            best = (distance, candidate)
            return
        }
        if distance < current.distance || (distance == current.distance && neighbourWins) {
            best = (distance, candidate)
        }
    }

    // Pane-to-pane.
    for neighbour in neighbours {
        for edge in SnapEdge.allCases {
            guard sharesAnEdge(proposed, neighbour.frame, along: edge) else { continue }
            let target = edgeValue(neighbour.frame, edge.opposite)
            let distance = abs(edgeValue(proposed, edge) - target)
            let frame = flush(proposed, edge: edge, to: target, matching: neighbour.frame)
            consider(distance, SnapCandidate(edge: edge, toPaneId: neighbour.id, frame: frame),
                     neighbourWins: true)
        }
    }

    // Pane-to-void. The void's `left` is the target for a pane's `left`,
    // not its `right`: the pane sits *inside* the void, so like edges meet
    // rather than opposite ones.
    for edge in SnapEdge.allCases {
        let target = edgeValue(void, edge)
        let distance = abs(edgeValue(proposed, edge) - target)
        let frame = flush(proposed, edge: edge, to: target, matching: nil)
        consider(distance, SnapCandidate(edge: edge, toPaneId: nil, frame: frame),
                 neighbourWins: false)
    }

    return best?.candidate
}

/// The coordinate of one edge of a frame.
private func edgeValue(_ frame: PaneFrame, _ edge: SnapEdge) -> Double {
    switch edge {
    case .left: return frame.minX
    case .right: return frame.maxX
    case .top: return frame.minY
    case .bottom: return frame.maxY
    }
}

/// Whether the two frames overlap on the axis *perpendicular* to `edge` —
/// i.e. whether they actually face each other across it.
///
/// Rule 2 of `snapCandidate`. Without it, any pane within 8pt of another's
/// x coordinate would snap to it regardless of how far apart they were
/// vertically.
private func sharesAnEdge(_ a: PaneFrame, _ b: PaneFrame, along edge: SnapEdge) -> Bool {
    if edge.isHorizontal {
        return a.minY < b.maxY && b.minY < a.maxY
    }
    return a.minX < b.maxX && b.minX < a.maxX
}

/// `frame` moved so that its `edge` sits exactly on `target`, and — when
/// `matching` is non-nil — resized to that neighbour's extent along the
/// shared edge.
private func flush(
    _ frame: PaneFrame, edge: SnapEdge, to target: Double, matching neighbour: PaneFrame?
) -> PaneFrame {
    var result = frame
    switch edge {
    case .left: result.x = target
    case .right: result.x = target - result.width
    case .top: result.y = target
    case .bottom: result.y = target - result.height
    }
    if let neighbour {
        if edge.isHorizontal {
            result.y = neighbour.minY
            result.height = neighbour.height
        } else {
            result.x = neighbour.minX
            result.width = neighbour.width
        }
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter SnapSolverTests`
Expected: PASS, all eight tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/SnapSolver.swift app/Tests/WakilKitTests/SnapSolverTests.swift
git commit -m "feat(layout): add the pure snap solver"
```

---

### Task 6: The snap graph

**Files:**
- Create: `app/Sources/WakilKit/Layout/SnapGraph.swift`
- Test: `app/Tests/WakilKitTests/SnapGraphTests.swift`

**Interfaces:**
- Consumes: `SnapEdge` (Task 4).
- Produces:
  ```swift
  public struct SnapLink: Sendable, Equatable, Hashable, Codable {
      public let paneId: String
      public let edge: SnapEdge        // paneId's edge
      public let otherPaneId: String
      public init(paneId: String, edge: SnapEdge, otherPaneId: String)
  }
  public struct SnapGraph: Sendable, Equatable, Codable {
      public init()
      public mutating func link(_ paneId: String, _ edge: SnapEdge, to otherPaneId: String)
      public mutating func unlink(_ paneId: String, _ edge: SnapEdge)
      public mutating func removeAll(for paneId: String)
      public func neighbours(of paneId: String, along edge: SnapEdge) -> [String]
      public var links: [SnapLink]     // deterministic order
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/SnapGraphTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func aLinkIsVisibleFromBothSides() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    #expect(graph.neighbours(of: "a", along: .right) == ["b"])
    // Undirected: b's left is linked to a, without a second call.
    #expect(graph.neighbours(of: "b", along: .left) == ["a"])
    // And not along any other edge.
    #expect(graph.neighbours(of: "a", along: .left).isEmpty)
    #expect(graph.neighbours(of: "b", along: .right).isEmpty)
}

@Test func onePaneCanHoldSeveralNeighboursOnOneEdge() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .right, to: "c")
    #expect(graph.neighbours(of: "a", along: .right).sorted() == ["b", "c"])
}

@Test func linkingTheSamePairTwiceDoesNotDuplicateIt() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .right, to: "b")
    #expect(graph.neighbours(of: "a", along: .right) == ["b"])
    #expect(graph.links.count == 1)
}

@Test func unlinkingOneEdgeLeavesTheOthersAlone() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    graph.unlink("a", .right)
    #expect(graph.neighbours(of: "a", along: .right).isEmpty)
    #expect(graph.neighbours(of: "b", along: .left).isEmpty)
    // The pane pulled away on one side keeps every other relationship.
    #expect(graph.neighbours(of: "a", along: .bottom) == ["c"])
}

@Test func removingAPaneRemovesEveryLinkItHeld() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    graph.link("b", .bottom, to: "c")
    graph.removeAll(for: "a")
    #expect(graph.neighbours(of: "b", along: .left).isEmpty)
    // Not empty: `b.bottom -> c` is an independent link that removing `a`
    // does not touch, and the graph is undirected, so `c.top` still holds `b`.
    #expect(graph.neighbours(of: "c", along: .top) == ["b"])
    // Links not involving the removed pane survive.
    #expect(graph.neighbours(of: "b", along: .bottom) == ["c"])
}

@Test func linksAreOrderedDeterministically() {
    var one = SnapGraph()
    one.link("a", .right, to: "b")
    one.link("a", .bottom, to: "c")
    var other = SnapGraph()
    other.link("a", .bottom, to: "c")
    other.link("a", .right, to: "b")
    // Same graph built in a different order encodes identically, so a
    // persisted layout does not churn on disk between launches.
    #expect(one.links == other.links)
    #expect(one == other)
}

@Test func aGraphRoundTripsThroughJSON() throws {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    let data = try JSONEncoder().encode(graph)
    #expect(try JSONDecoder().decode(SnapGraph.self, from: data) == graph)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter SnapGraphTests`
Expected: FAIL to compile — "cannot find 'SnapGraph' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/SnapGraph.swift`:

```swift
import Foundation

/// One coordinated edge: `paneId`'s `edge` is snapped against
/// `otherPaneId`.
///
/// Stored in a canonical direction so that a link added as
/// `("b", .left, "a")` and one added as `("a", .right, "b")` are the same
/// value and cannot both exist. See `SnapGraph.link`.
public struct SnapLink: Sendable, Equatable, Hashable, Codable {
    public let paneId: String
    public let edge: SnapEdge
    public let otherPaneId: String

    public init(paneId: String, edge: SnapEdge, otherPaneId: String) {
        self.paneId = paneId
        self.edge = edge
        self.otherPaneId = otherPaneId
    }
}

/// Which panes have coordinated edges with which others.
///
/// **Stored, not derived, and that is the point.** Two panes that happen
/// to be flush are not the same as two panes that were snapped: snapping
/// matches their extent once, and a later independent resize may leave
/// them flush-but-unrelated or related-but-not-flush. Re-deriving
/// adjacency from geometry every frame would silently re-couple panes the
/// user deliberately pulled apart, and the failure would read as "feels
/// wrong" rather than as a crash.
///
/// Undirected: linking a's right to b implies b's left is linked to a, and
/// `neighbours(of:along:)` answers from either side. Storage canonicalises
/// each link to one direction so the pair cannot be recorded twice.
public struct SnapGraph: Sendable, Equatable, Codable {
    /// Canonical form only: `edge` is always `.right` or `.bottom`, so
    /// every link is stored from the pane on the left or above.
    private var stored: Set<SnapLink>

    public init() {
        stored = []
    }

    /// Records that `paneId`'s `edge` is coordinated with `otherPaneId`.
    /// Idempotent, and order-independent — see `canonical`.
    public mutating func link(_ paneId: String, _ edge: SnapEdge, to otherPaneId: String) {
        stored.insert(Self.canonical(paneId, edge, otherPaneId))
    }

    /// Drops every link on `paneId`'s `edge` — what happens when a pane is
    /// dragged away from a side it was snapped on. Links on its *other*
    /// edges survive: pulling a pane out of a row to the right should not
    /// unstick it from the pane above.
    public mutating func unlink(_ paneId: String, _ edge: SnapEdge) {
        stored = stored.filter { link in
            !(link.paneId == paneId && link.edge == edge)
                && !(link.otherPaneId == paneId && link.edge == edge.opposite)
        }
    }

    /// Drops every link `paneId` holds, on every edge. Called when a pane
    /// closes — a link to a pane that no longer exists would make the
    /// border-drag code resize a ghost.
    public mutating func removeAll(for paneId: String) {
        stored = stored.filter { $0.paneId != paneId && $0.otherPaneId != paneId }
    }

    /// Every pane coordinated with `paneId` along `edge`, in sorted order.
    public func neighbours(of paneId: String, along edge: SnapEdge) -> [String] {
        var result: [String] = []
        for link in stored {
            if link.paneId == paneId, link.edge == edge {
                result.append(link.otherPaneId)
            } else if link.otherPaneId == paneId, link.edge == edge.opposite {
                result.append(link.paneId)
            }
        }
        return result.sorted()
    }

    /// Every link, in a deterministic order.
    ///
    /// Sorted rather than in `Set` order because this is what
    /// `LayoutPersistence` encodes: a set's iteration order varies between
    /// runs, and an unsorted encoding would rewrite the layout file with
    /// different bytes for an unchanged arrangement on every launch.
    public var links: [SnapLink] {
        stored.sorted {
            ($0.paneId, $0.edge.rawValue, $0.otherPaneId)
                < ($1.paneId, $1.edge.rawValue, $1.otherPaneId)
        }
    }

    /// Rewrites a link so that it is always stored from the left/upper
    /// pane's point of view. `("b", .left, "a")` becomes
    /// `("a", .right, "b")`, so the two spellings of one relationship
    /// cannot both be inserted.
    private static func canonical(
        _ paneId: String, _ edge: SnapEdge, _ otherPaneId: String
    ) -> SnapLink {
        switch edge {
        case .right, .bottom:
            return SnapLink(paneId: paneId, edge: edge, otherPaneId: otherPaneId)
        case .left, .top:
            return SnapLink(paneId: otherPaneId, edge: edge.opposite, otherPaneId: paneId)
        }
    }

    // Codable over the sorted array, not the set, for the reason `links`
    // gives.
    private enum CodingKeys: String, CodingKey { case links }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stored = Set(try container.decode([SnapLink].self, forKey: .links))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(links, forKey: .links)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter SnapGraphTests`
Expected: PASS, all seven tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/SnapGraph.swift app/Tests/WakilKitTests/SnapGraphTests.swift
git commit -m "feat(layout): add the stored snap graph"
```

---

### Task 7: `LayoutStore`

**Files:**
- Create: `app/Sources/WakilKit/Layout/LayoutStore.swift`
- Test: `app/Tests/WakilKitTests/LayoutStoreTests.swift`

**Interfaces:**
- Consumes: `Pane`, `PaneFrame`, `SnapEdge` (Task 4), `snapCandidate`, `SnapCandidate`
  (Task 5), `SnapGraph` (Task 6).
- Produces:
  ```swift
  public struct LayoutSnapshot: Sendable, Equatable, Codable {
      public var panes: [Pane]
      public var focusedId: String?
      public var maximizedId: String?
      public var graph: SnapGraph
  }
  public actor LayoutStore {
      public init(voidSize: PaneFrame = LayoutStore.defaultVoid)
      public static let defaultVoid: PaneFrame
      public func snapshot() -> LayoutSnapshot
      public func setVoid(_ frame: PaneFrame)
      @discardableResult public func open(kind: String, title: String) -> Pane
      public func close(id: String) throws
      public func focus(id: String) throws
      public func move(id: String, x: Double, y: Double) throws
      public func resize(id: String, width: Double, height: Double) throws
      public func snap(id: String, to otherPaneId: String?, edge: SnapEdge) throws
      public func maximize(id: String) throws
      public func restore()
      public func setBusy(_ busy: Bool, id: String)
      public func candidate(forDragging id: String, to origin: (x: Double, y: Double)) -> SnapCandidate?
      public func switchProject(to project: String)
      public func load(_ snapshot: LayoutSnapshot, for project: String)
  }
  public enum LayoutError: Error, Equatable, Sendable {
      case unknownPane(String)
      case notSnapped(String)
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/LayoutStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

@Test func openingPanesGivesEachAUniqueIdAndFocusesTheNewest() async {
    let store = LayoutStore()
    let first = await store.open(kind: "db", title: "One")
    let second = await store.open(kind: "db", title: "Two")
    #expect(first.id != second.id)
    #expect(first.kind == "db")
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.map(\.id) == [first.id, second.id])
    #expect(snapshot.focusedId == second.id)
}

@Test func openedPanesCascadeRatherThanStackingExactly() async {
    let store = LayoutStore()
    let first = await store.open(kind: "db", title: "One")
    let second = await store.open(kind: "db", title: "Two")
    #expect(second.frame.x > first.frame.x)
    #expect(second.frame.y > first.frame.y)
}

@Test func closingAPaneRemovesItAndItsLinksAndRefocuses() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    let b = await store.open(kind: "db", title: "B")
    try await store.snap(id: b.id, to: a.id, edge: .left)
    try await store.close(id: b.id)
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.map(\.id) == [a.id])
    #expect(snapshot.focusedId == a.id)
    #expect(snapshot.graph.neighbours(of: a.id, along: .right).isEmpty)
}

@Test func closingTheLastPaneLeavesNoFocus() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.close(id: a.id)
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.isEmpty)
    #expect(snapshot.focusedId == nil)
}

@Test func actingOnAnUnknownPaneThrows() async {
    let store = LayoutStore()
    await #expect(throws: LayoutError.unknownPane("nope")) { try await store.close(id: "nope") }
    await #expect(throws: LayoutError.unknownPane("nope")) { try await store.focus(id: "nope") }
    await #expect(throws: LayoutError.unknownPane("nope")) {
        try await store.move(id: "nope", x: 0, y: 0)
    }
    await #expect(throws: LayoutError.unknownPane("nope")) {
        try await store.resize(id: "nope", width: 1, height: 1)
    }
    await #expect(throws: LayoutError.unknownPane("nope")) { try await store.maximize(id: "nope") }
}

@Test func movingAPaneUnlinksEveryEdgeItHeld() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    let b = await store.open(kind: "db", title: "B")
    try await store.snap(id: b.id, to: a.id, edge: .left)
    #expect(await store.snapshot().graph.neighbours(of: b.id, along: .left) == [a.id])

    try await store.move(id: b.id, x: 600, y: 600)
    let snapshot = await store.snapshot()
    #expect(snapshot.graph.links.isEmpty)
    #expect(snapshot.panes.first { $0.id == b.id }?.frame.x == 600)
}

@Test func snappingMatchesExtentAndRecordsTheLink() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 100, y: 100)
    try await store.resize(id: a.id, width: 200, height: 300)
    let b = await store.open(kind: "db", title: "B")

    try await store.snap(id: b.id, to: a.id, edge: .left)

    let snapshot = await store.snapshot()
    let moved = try #require(snapshot.panes.first { $0.id == b.id })
    // b's left edge is flush against a's right edge...
    #expect(moved.frame.minX == 300)
    // ...and its height matches a's, per §10.
    #expect(moved.frame.minY == 100)
    #expect(moved.frame.height == 300)
    #expect(snapshot.graph.neighbours(of: b.id, along: .left) == [a.id])
}

@Test func snappingToTheVoidEdgeMovesWithoutResizing() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    let before = try #require(await store.snapshot().panes.first)
    try await store.snap(id: a.id, to: nil, edge: .left)
    let after = try #require(await store.snapshot().panes.first)
    #expect(after.frame.minX == 0)
    #expect(after.frame.width == before.frame.width)
    #expect(after.frame.height == before.frame.height)
    #expect(after.frame.minY == before.frame.minY)
}

@Test func resizingASnappedPaneResizesItsNeighbourToo() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 100, y: 100)
    try await store.resize(id: a.id, width: 200, height: 300)
    let b = await store.open(kind: "db", title: "B")
    try await store.snap(id: b.id, to: a.id, edge: .left)
    // b now sits at x = 300, width unchanged.
    let widthBefore = try #require(await store.snapshot().panes.first { $0.id == b.id }).frame.width

    // Widening a pushes the shared border right; b keeps its own right
    // edge and therefore narrows by the same amount.
    try await store.resize(id: a.id, width: 260, height: 300)

    let snapshot = await store.snapshot()
    let moved = try #require(snapshot.panes.first { $0.id == b.id })
    #expect(moved.frame.minX == 360)
    #expect(moved.frame.width == widthBefore - 60)
    // Still flush: no gap, no overlap.
    let anchor = try #require(snapshot.panes.first { $0.id == a.id })
    #expect(anchor.frame.maxX == moved.frame.minX)
}

@Test func maximizeAndRestoreReturnTheOriginalFrame() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 120, y: 140)
    let before = try #require(await store.snapshot().panes.first).frame

    try await store.maximize(id: a.id)
    var snapshot = await store.snapshot()
    #expect(snapshot.maximizedId == a.id)
    #expect(snapshot.panes[0].frame == LayoutStore.defaultVoid)

    await store.restore()
    snapshot = await store.snapshot()
    #expect(snapshot.maximizedId == nil)
    #expect(snapshot.panes[0].frame == before)
}

@Test func restoreWithNothingMaximizedIsANoOp() async {
    let store = LayoutStore()
    _ = await store.open(kind: "db", title: "A")
    let before = await store.snapshot()
    await store.restore()
    #expect(await store.snapshot() == before)
}

@Test func maximizingASecondPaneRestoresTheFirst() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    let b = await store.open(kind: "db", title: "B")
    let aFrame = try #require(await store.snapshot().panes.first { $0.id == a.id }).frame

    try await store.maximize(id: a.id)
    try await store.maximize(id: b.id)

    let snapshot = await store.snapshot()
    #expect(snapshot.maximizedId == b.id)
    #expect(snapshot.panes.first { $0.id == a.id }?.frame == aFrame)
}

@Test func switchingProjectPreservesTheOutgoingArrangement() async throws {
    let store = LayoutStore()
    await store.switchProject(to: "alpha")
    let a = await store.open(kind: "db", title: "Alpha pane")
    try await store.move(id: a.id, x: 321, y: 123)

    await store.switchProject(to: "beta")
    #expect(await store.snapshot().panes.isEmpty)
    let b = await store.open(kind: "db", title: "Beta pane")
    #expect(await store.snapshot().panes.map(\.id) == [b.id])

    await store.switchProject(to: "alpha")
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.map(\.title) == ["Alpha pane"])
    #expect(snapshot.panes[0].frame.x == 321)
    #expect(snapshot.panes[0].frame.y == 123)
}

@Test func busyIsSetAndClearedWithoutTouchingAnythingElse() async {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    await store.setBusy(true, id: a.id)
    #expect(await store.snapshot().panes[0].busy)
    await store.setBusy(false, id: a.id)
    #expect(!(await store.snapshot().panes[0].busy))
    // An unknown id is ignored rather than throwing: `busy` is a UI hint
    // set from a dispatch completion handler, and a pane closed mid-flight
    // is ordinary, not an error.
    await store.setBusy(true, id: "nope")
}

@Test func theDragCandidateExcludesTheDraggedPaneItself() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 400, y: 400)
    // Dragging a onto exactly where it already is must not snap it to
    // itself.
    let candidate = await store.candidate(forDragging: a.id, to: (x: 400, y: 400))
    #expect(candidate?.toPaneId != a.id)
}

@Test func loadReplacesOneProjectsArrangementWholesale() async throws {
    let store = LayoutStore()
    await store.switchProject(to: "alpha")
    _ = await store.open(kind: "db", title: "Discarded")

    var graph = SnapGraph()
    graph.link("x", .right, to: "y")
    let restored = LayoutSnapshot(
        panes: [
            Pane(id: "x", kind: "db", title: "X",
                 frame: PaneFrame(x: 0, y: 0, width: 10, height: 10)),
            Pane(id: "y", kind: "db", title: "Y",
                 frame: PaneFrame(x: 10, y: 0, width: 10, height: 10)),
        ],
        focusedId: "y", maximizedId: nil, graph: graph)
    await store.load(restored, for: "alpha")

    #expect(await store.snapshot() == restored)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter LayoutStoreTests`
Expected: FAIL to compile — "cannot find 'LayoutStore' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/LayoutStore.swift`:

```swift
import Foundation

/// What went wrong in a `LayoutStore` call.
public enum LayoutError: Error, Equatable, Sendable {
    /// No pane with that id exists in the active project's arrangement.
    case unknownPane(String)
    /// The pane exists but holds no link on the edge the caller named.
    case notSnapped(String)
}

/// One project's whole arrangement, as a value.
///
/// This is what `snapshot()` returns, what `read_layout` projects, and what
/// `LayoutPersistence` writes. Being `Codable` and `Equatable` is what lets
/// a test assert a round trip and a restore in one expression.
public struct LayoutSnapshot: Sendable, Equatable, Codable {
    public var panes: [Pane]
    public var focusedId: String?
    public var maximizedId: String?
    public var graph: SnapGraph

    public init(
        panes: [Pane] = [], focusedId: String? = nil, maximizedId: String? = nil,
        graph: SnapGraph = SnapGraph()
    ) {
        self.panes = panes
        self.focusedId = focusedId
        self.maximizedId = maximizedId
        self.graph = graph
    }
}

/// Where the panes are, per project.
///
/// An actor, for the reason `PaneStore` is one: a drag commit from the
/// window and a `pane_snap` from an in-flight agent turn arrive on
/// different tasks and must not race.
///
/// **It holds every visited project's arrangement, not just the active
/// one.** `design-language.md` §13 requires that panes are "never torn
/// down and rebuilt on switch" and that state is kept warm, so switching
/// project swaps which `LayoutSnapshot` is active and discards nothing.
/// Coming back to a project finds it as it was left.
///
/// **Contents are not here** — `PaneStore` holds those. See `Pane`'s doc
/// comment for why the two are separate.
public actor LayoutStore {
    /// The canvas a pane is placed and maximized into, until the window
    /// reports its real size via `setVoid`. A fixed default rather than an
    /// optional so that `LayoutStore()` in a test behaves exactly as it
    /// does in the app, with no display involved.
    public static let defaultVoid = PaneFrame(x: 0, y: 0, width: 1440, height: 900)

    private var void: PaneFrame
    private var project: String
    private var byProject: [String: LayoutSnapshot]
    /// Frames to put back on `restore()`, keyed by pane id.
    private var preMaximizeFrames: [String: PaneFrame]
    private var nextPaneNumber: Int

    public init(voidSize: PaneFrame = LayoutStore.defaultVoid) {
        void = voidSize
        project = ""
        byProject = ["": LayoutSnapshot()]
        preMaximizeFrames = [:]
        nextPaneNumber = 1
    }

    // MARK: - Reading

    public func snapshot() -> LayoutSnapshot {
        byProject[project] ?? LayoutSnapshot()
    }

    /// Tells the store how big the canvas is. Called by the window on
    /// resize; a maximized pane follows.
    public func setVoid(_ frame: PaneFrame) {
        void = frame
        guard var current = byProject[project], let maximizedId = current.maximizedId else { return }
        guard let index = current.panes.firstIndex(where: { $0.id == maximizedId }) else { return }
        current.panes[index].frame = frame
        byProject[project] = current
    }

    // MARK: - Panes

    /// Opens a new pane, focuses it, and returns it.
    ///
    /// Ids are `"<kind>-<n>"` with `n` counting up across the whole store,
    /// not per project — an id is a handle an agent may hold across a
    /// context switch, and reusing `db-1` in a second project would make
    /// two different panes answer to one name in one journal.
    @discardableResult
    public func open(kind: String, title: String) -> Pane {
        var current = snapshot()
        let id = "\(kind)-\(nextPaneNumber)"
        nextPaneNumber += 1

        // Cascade from the last pane rather than stacking exactly, so a
        // second pane is visible instead of hidden behind the first. §12's
        // open question 3 records that this is a placeholder for whatever
        // the full-working-day density test says.
        let offset = Double(current.panes.count % 8) * 28
        let pane = Pane(
            id: id, kind: kind, title: title,
            frame: PaneFrame(x: 60 + offset, y: 60 + offset, width: 640, height: 420))

        current.panes.append(pane)
        current.focusedId = id
        byProject[project] = current
        return pane
    }

    public func close(id: String) throws {
        var current = try requirePane(id)
        current.panes.removeAll { $0.id == id }
        current.graph.removeAll(for: id)
        if current.focusedId == id { current.focusedId = current.panes.last?.id }
        if current.maximizedId == id { current.maximizedId = nil }
        preMaximizeFrames[id] = nil
        byProject[project] = current
    }

    public func focus(id: String) throws {
        var current = try requirePane(id)
        current.focusedId = id
        byProject[project] = current
    }

    public func setBusy(_ busy: Bool, id: String) {
        guard var current = byProject[project],
              let index = current.panes.firstIndex(where: { $0.id == id })
        else { return }  // See the test: a pane closed mid-flight is ordinary.
        current.panes[index].busy = busy
        byProject[project] = current
    }

    // MARK: - Geometry

    /// Moves a pane to an absolute origin, and **unlinks every edge it
    /// held**.
    ///
    /// Absolute rather than a delta because §8's `--dispatch` scripts must
    /// be able to state an outcome, and because a drag dispatches once on
    /// release (spec §4.1) with the final position rather than a stream of
    /// increments.
    ///
    /// The unlink is what makes "pulling a pane away returns it to
    /// free-floating" true. A move that kept its links would leave a pane
    /// coordinating a border it is no longer touching.
    public func move(id: String, x: Double, y: Double) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }
        current.panes[index].frame.x = x
        current.panes[index].frame.y = y
        current.graph.removeAll(for: id)
        byProject[project] = current
    }

    /// Resizes a pane, dragging any coordinated neighbour's shared border
    /// with it so that snapped panes never gap or overlap.
    public func resize(id: String, width: Double, height: Double) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }

        let before = current.panes[index].frame
        current.panes[index].frame.width = width
        current.panes[index].frame.height = height
        let after = current.panes[index].frame

        // A neighbour on the right rides the moved border: its left edge
        // follows, and it absorbs the difference so its own far edge stays
        // put. Same below, vertically.
        for neighbourId in current.graph.neighbours(of: id, along: .right) {
            guard let n = current.panes.firstIndex(where: { $0.id == neighbourId }) else { continue }
            let delta = after.maxX - before.maxX
            current.panes[n].frame.x += delta
            current.panes[n].frame.width -= delta
        }
        for neighbourId in current.graph.neighbours(of: id, along: .bottom) {
            guard let n = current.panes.firstIndex(where: { $0.id == neighbourId }) else { continue }
            let delta = after.maxY - before.maxY
            current.panes[n].frame.y += delta
            current.panes[n].frame.height -= delta
        }

        byProject[project] = current
    }

    /// Snaps `id` flush against `otherPaneId`'s opposite edge — or against
    /// the void's own `edge` when `otherPaneId` is `nil` — and records the
    /// link.
    ///
    /// `edge` names the *dragged* pane's edge. Snapping b's `.left` to a
    /// puts b to the right of a.
    public func snap(id: String, to otherPaneId: String?, edge: SnapEdge) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }

        var neighbourFrame: PaneFrame?
        if let otherPaneId {
            guard let other = current.panes.first(where: { $0.id == otherPaneId }) else {
                throw LayoutError.unknownPane(otherPaneId)
            }
            neighbourFrame = other.frame
        }

        let target = neighbourFrame.map { edgeValue($0, edge.opposite) } ?? edgeValue(void, edge)
        current.panes[index].frame = flushFrame(
            current.panes[index].frame, edge: edge, to: target, matching: neighbourFrame)

        current.graph.unlink(id, edge)
        if let otherPaneId { current.graph.link(id, edge, to: otherPaneId) }
        byProject[project] = current
    }

    public func maximize(id: String) throws {
        var current = try requirePane(id)
        guard let index = current.panes.firstIndex(where: { $0.id == id }) else { return }

        // Maximizing while something else is maximized restores that one
        // first, so only ever one frame is being held back.
        if let previous = current.maximizedId, previous != id,
           let previousIndex = current.panes.firstIndex(where: { $0.id == previous }),
           let frame = preMaximizeFrames[previous] {
            current.panes[previousIndex].frame = frame
            preMaximizeFrames[previous] = nil
        }

        preMaximizeFrames[id] = current.panes[index].frame
        current.panes[index].frame = void
        current.maximizedId = id
        current.focusedId = id
        byProject[project] = current
    }

    public func restore() {
        guard var current = byProject[project], let id = current.maximizedId else { return }
        if let index = current.panes.firstIndex(where: { $0.id == id }), let frame = preMaximizeFrames[id] {
            current.panes[index].frame = frame
        }
        preMaximizeFrames[id] = nil
        current.maximizedId = nil
        byProject[project] = current
    }

    /// The snap the view should preview while `id` is being dragged to
    /// `origin`, or `nil` for none.
    ///
    /// Read-only: previewing must not commit. The dragged pane is excluded
    /// from its own neighbour list, or every drag would snap to where the
    /// pane already was.
    public func candidate(
        forDragging id: String, to origin: (x: Double, y: Double)
    ) -> SnapCandidate? {
        let current = snapshot()
        guard let pane = current.panes.first(where: { $0.id == id }) else { return nil }
        var proposed = pane.frame
        proposed.x = origin.x
        proposed.y = origin.y
        let neighbours = current.panes
            .filter { $0.id != id }
            .map { (id: $0.id, frame: $0.frame) }
        return snapCandidate(for: proposed, neighbours: neighbours, void: void)
    }

    // MARK: - Projects

    /// Makes `project` the active arrangement, keeping the outgoing one.
    public func switchProject(to project: String) {
        self.project = project
        if byProject[project] == nil { byProject[project] = LayoutSnapshot() }
    }

    /// Replaces `project`'s arrangement wholesale — what
    /// `LayoutPersistence` calls after reading one off disk.
    public func load(_ snapshot: LayoutSnapshot, for project: String) {
        byProject[project] = snapshot
        // Keep ids unique against whatever was restored: a persisted
        // `db-7` must not be handed out again this session.
        for pane in snapshot.panes {
            guard let suffix = pane.id.split(separator: "-").last, let n = Int(suffix) else { continue }
            nextPaneNumber = max(nextPaneNumber, n + 1)
        }
    }

    // MARK: - Private

    private func requirePane(_ id: String) throws -> LayoutSnapshot {
        let current = snapshot()
        guard current.panes.contains(where: { $0.id == id }) else {
            throw LayoutError.unknownPane(id)
        }
        return current
    }
}

/// The coordinate of one edge of a frame. A copy of `SnapSolver`'s private
/// helper, kept private there too: the solver is a pure function over
/// caller-supplied values and this actor is stateful, and giving them a
/// shared internal helper would make the solver's isolation from store
/// state a matter of discipline rather than of visibility.
private func edgeValue(_ frame: PaneFrame, _ edge: SnapEdge) -> Double {
    switch edge {
    case .left: return frame.minX
    case .right: return frame.maxX
    case .top: return frame.minY
    case .bottom: return frame.maxY
    }
}

private func flushFrame(
    _ frame: PaneFrame, edge: SnapEdge, to target: Double, matching neighbour: PaneFrame?
) -> PaneFrame {
    var result = frame
    switch edge {
    case .left: result.x = target
    case .right: result.x = target - result.width
    case .top: result.y = target
    case .bottom: result.y = target - result.height
    }
    if let neighbour {
        if edge.isHorizontal {
            result.y = neighbour.minY
            result.height = neighbour.height
        } else {
            result.x = neighbour.minX
            result.width = neighbour.width
        }
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter LayoutStoreTests`
Expected: PASS, all sixteen tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/LayoutStore.swift app/Tests/WakilKitTests/LayoutStoreTests.swift
git commit -m "feat(layout): add LayoutStore with per-project arrangements"
```

---

### Task 8: The eight layout actions

**Files:**
- Create: `app/Sources/WakilKit/Layout/LayoutActions.swift`
- Test: `app/Tests/WakilKitTests/LayoutActionsTests.swift`

**Interfaces:**
- Consumes: `LayoutStore` (Task 7), `ActionRegistry`, `Action`, `ActionKind.control`.
- Produces:
  ```swift
  public func registerLayoutActions(into registry: ActionRegistry, layout: LayoutStore) async
  ```
  Registering `pane_open`, `pane_close`, `pane_focus`, `pane_move`, `pane_resize`,
  `pane_snap`, `pane_maximize`, `pane_restore` — all `.control`, none with a
  `targetEnvironmentParam`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/LayoutActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func makeRegistry() -> (ActionRegistry, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("layout-actions-\(UUID().uuidString)", isDirectory: true)
    return (ActionRegistry(journalDirectory: directory, sessionId: "s"), directory)
}

@Test func everyLayoutActionIsRegisteredAsControl() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    let expected = [
        "pane_close", "pane_focus", "pane_maximize", "pane_move",
        "pane_open", "pane_resize", "pane_restore", "pane_snap",
    ]
    let registered = await registry.all().filter { $0.name.hasPrefix("pane_") }
    #expect(registered.map(\.name).sorted() == expected)
    #expect(registered.allSatisfy { $0.kind == .control })
}

@Test func noLayoutActionNamesATargetEnvironment() async {
    // Layout changes nothing about which world Wakil is pointed at, so the
    // agent-into-production gate must never fire for one.
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    _ = try? await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, environment: "production", confirmation: nil)
    #expect(await layout.snapshot().panes.count == 1)
}

@Test func paneOpenReturnsTheNewPanesId() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    let result = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db"), "title": .string("Rows")]),
        origin: .ui, environment: "staging", confirmation: nil)

    guard case .object(let object) = result, case .string(let id)? = object["id"] else {
        Issue.record("pane_open returned \(result), expected an object with a string id")
        return
    }
    #expect(id == "db-1")
    #expect(await layout.snapshot().panes.first?.title == "Rows")
}

@Test func paneOpenDefaultsItsTitleToTheKind() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .ui, environment: "staging", confirmation: nil)
    #expect(await layout.snapshot().panes.first?.title == "db")
}

@Test func paneMoveAndResizeChangeTheStore() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "A")

    _ = try await registry.dispatch(
        name: "pane_move",
        params: .object(["id": .string(pane.id), "x": .number(12), "y": .number(34)]),
        origin: .ui, environment: "staging", confirmation: nil)
    _ = try await registry.dispatch(
        name: "pane_resize",
        params: .object(["id": .string(pane.id), "width": .number(300), "height": .number(200)]),
        origin: .ui, environment: "staging", confirmation: nil)

    let frame = try #require(await layout.snapshot().panes.first).frame
    #expect(frame == PaneFrame(x: 12, y: 34, width: 300, height: 200))
}

@Test func paneSnapAcceptsAnAbsentToPaneIdAsTheVoidEdge() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "A")

    _ = try await registry.dispatch(
        name: "pane_snap",
        params: .object(["id": .string(pane.id), "edge": .string("left")]),
        origin: .ui, environment: "staging", confirmation: nil)

    #expect(await layout.snapshot().panes.first?.frame.minX == 0)
}

@Test func paneSnapRejectsAnUnknownEdge() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "A")

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "pane_snap",
            params: .object(["id": .string(pane.id), "edge": .string("sideways")]),
            origin: .ui, environment: "staging", confirmation: nil)
    }
}

@Test func aMissingRequiredParamThrowsRatherThanDefaulting() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "pane_move", params: .object(["id": .string("db-1")]),
            origin: .ui, environment: "staging", confirmation: nil)
    }
}

@Test func layoutActionsJournalTheirOrigin() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, environment: "staging", confirmation: nil)

    let entries = try await registry.journalEntries()
    #expect(entries.count == 1)
    #expect(entries[0].action == "pane_open")
    #expect(entries[0].origin == .agent)
    #expect(entries[0].outcome == "ok")
}

@Test func paneMaximizeAndRestoreRoundTripThroughTheRegistry() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "A")
    let before = try #require(await layout.snapshot().panes.first).frame

    _ = try await registry.dispatch(
        name: "pane_maximize", params: .object(["id": .string(pane.id)]),
        origin: .ui, environment: "staging", confirmation: nil)
    #expect(await layout.snapshot().maximizedId == pane.id)

    _ = try await registry.dispatch(
        name: "pane_restore", params: .object([:]),
        origin: .ui, environment: "staging", confirmation: nil)
    #expect(await layout.snapshot().maximizedId == nil)
    #expect(await layout.snapshot().panes.first?.frame == before)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter LayoutActionsTests`
Expected: FAIL to compile — "cannot find 'registerLayoutActions' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/LayoutActions.swift`:

```swift
import Foundation

/// Errors a layout action's handler throws for reasons of its own.
public enum LayoutActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingParam(action: String, param: String)
    case badParam(action: String, param: String, value: String)

    public var description: String {
        switch self {
        case .missingParam(let action, let param):
            return "\(action): missing required param \"\(param)\""
        case .badParam(let action, let param, let value):
            return "\(action): param \"\(param)\" cannot be \"\(value)\""
        }
    }
}

/// Registers the eight layout actions into `registry`, all `.control`.
///
/// **Why these are actions at all.** Invariant 2 says every pane is
/// dual-driven, and arranging panes is part of driving them: "put the
/// query results next to the terminal" is a thing to say out loud, and an
/// agent that cannot see or change geometry can only answer half of
/// "what's on screen?". Registering them is also what puts them in ⌘K for
/// free, since the palette is `registry.all()`.
///
/// **Why they are `.control` and carry no `targetEnvironmentParam`.**
/// Moving a pane changes Wakil and nothing else, so the write gate's
/// production rule must not apply — being pointed at a production database
/// is no reason to be unable to drag a window. And since no layout action
/// changes which environment is active, none of them can be an agent
/// walking into production, so none names a target for the gate to read.
///
/// **Commit granularity.** These take absolute positions and sizes, not
/// deltas, because a drag dispatches exactly once — on release, with the
/// final rect — while the pointer-down path updates SwiftUI state at frame
/// rate and dispatches nothing. A 400-frame drag therefore journals one
/// entry saying where the pane ended up, not four hundred saying it moved
/// a point. Without that rule either the journal is unreadable or there is
/// an `await` on the frame path, and §7's 8.33ms budget does not survive
/// the latter.
public func registerLayoutActions(into registry: ActionRegistry, layout: LayoutStore) async {
    await registry.register(Action(
        name: "pane_open",
        description: "Open a new pane of the given kind and focus it. Returns the new pane's id.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("kind")]),
        ]),
        handler: { params in
            let kind = try requireString(params, "kind", action: "pane_open")
            let title = optionalString(params, "title") ?? kind
            let pane = await layout.open(kind: kind, title: title)
            return .object(["id": .string(pane.id)])
        }
    ))

    await registry.register(Action(
        name: "pane_close",
        description: "Close a pane, releasing any snapped edges it held.",
        kind: .control,
        schema: idOnlySchema,
        handler: { params in
            try await layout.close(id: try requireString(params, "id", action: "pane_close"))
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_focus",
        description: "Make a pane the focused one.",
        kind: .control,
        schema: idOnlySchema,
        handler: { params in
            try await layout.focus(id: try requireString(params, "id", action: "pane_focus"))
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_move",
        description: "Move a pane to an absolute position on the canvas, unsnapping every edge it held.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "x": .object(["type": .string("number")]),
                "y": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("id"), .string("x"), .string("y")]),
        ]),
        handler: { params in
            try await layout.move(
                id: try requireString(params, "id", action: "pane_move"),
                x: try requireNumber(params, "x", action: "pane_move"),
                y: try requireNumber(params, "y", action: "pane_move"))
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_resize",
        description: "Resize a pane, dragging any coordinated shared border with it.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "width": .object(["type": .string("number")]),
                "height": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("id"), .string("width"), .string("height")]),
        ]),
        handler: { params in
            try await layout.resize(
                id: try requireString(params, "id", action: "pane_resize"),
                width: try requireNumber(params, "width", action: "pane_resize"),
                height: try requireNumber(params, "height", action: "pane_resize"))
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_snap",
        description:
            "Snap one of a pane's edges flush against another pane's opposite edge, matching its "
            + "extent, and coordinate the shared border. Omit toPaneId to snap to the canvas edge.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "toPaneId": .object(["type": .string("string")]),
                "edge": .object([
                    "type": .string("string"),
                    "enum": .array(SnapEdge.allCases.map { .string($0.rawValue) }),
                ]),
            ]),
            "required": .array([.string("id"), .string("edge")]),
        ]),
        handler: { params in
            let raw = try requireString(params, "edge", action: "pane_snap")
            guard let edge = SnapEdge(rawValue: raw) else {
                throw LayoutActionError.badParam(action: "pane_snap", param: "edge", value: raw)
            }
            try await layout.snap(
                id: try requireString(params, "id", action: "pane_snap"),
                to: optionalString(params, "toPaneId"),
                edge: edge)
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_maximize",
        description: "Fill the canvas with one pane. pane_restore puts it back.",
        kind: .control,
        schema: idOnlySchema,
        handler: { params in
            try await layout.maximize(id: try requireString(params, "id", action: "pane_maximize"))
            return .object([:])
        }
    ))

    await registry.register(Action(
        name: "pane_restore",
        description: "Un-maximize whichever pane is filling the canvas. Does nothing if none is.",
        kind: .control,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            await layout.restore()
            return .object([:])
        }
    ))
}

private let idOnlySchema = JSONValue.object([
    "type": .string("object"),
    "properties": .object(["id": .object(["type": .string("string")])]),
    "required": .array([.string("id")]),
])

/// Reads a required string param, throwing rather than defaulting.
///
/// A default would turn a caller's typo into a silent no-op against some
/// other pane, which is precisely the class of bug the journal exists to
/// make visible.
private func requireString(_ params: JSONValue, _ key: String, action: String) throws -> String {
    guard case .object(let object) = params, case .string(let value)? = object[key] else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    return value
}

private func requireNumber(_ params: JSONValue, _ key: String, action: String) throws -> Double {
    guard case .object(let object) = params, case .number(let value)? = object[key] else {
        throw LayoutActionError.missingParam(action: action, param: key)
    }
    return value
}

private func optionalString(_ params: JSONValue, _ key: String) -> String? {
    guard case .object(let object) = params, case .string(let value)? = object[key] else {
        return nil
    }
    return value
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter LayoutActionsTests`
Expected: PASS, all ten tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/LayoutActions.swift app/Tests/WakilKitTests/LayoutActionsTests.swift
git commit -m "feat(layout): register the eight layout actions as .control"
```

---

### Task 9: `ctx_*` reclassification, `session_list`, and the Phase 1 guarantee

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:104-131` (the two setters),
  and append `session_list`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `ActionKind.control` (Task 1), `Action.targetEnvironmentParam` (Task 3).
- Produces: `ctx_set_project` and `ctx_set_environment` as `.control`, the latter with
  `targetEnvironmentParam: "name"`; a new `session_list` action of kind `.read`.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/StandardActionsTests.swift`:

```swift
@Test func contextSettersAreControlAndOnlyTheEnvironmentOneNamesATarget() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("std-kinds-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    #expect(byName["ctx_set_project"]?.kind == .control)
    #expect(byName["ctx_set_environment"]?.kind == .control)
    // Reads stay reads.
    #expect(byName["ctx_list_projects"]?.kind == .read)
    #expect(byName["db_run_query"]?.kind == .read)
    #expect(byName["session_resume"]?.kind == .read)
    #expect(byName["session_list"]?.kind == .read)
    // And nothing here is ever a mutation.
    #expect(await registry.all().allSatisfy { $0.kind != .mutate })
}

@Test func sessionListIsRegisteredAndFailsLoudlyWithoutAClient() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("std-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)

    await #expect(
        throws: StandardActionError.missingClient(action: "session_list", role: "context")
    ) {
        _ = try await registry.dispatch(
            name: "session_list", params: .object([:]),
            origin: .ui, environment: "staging", confirmation: nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter contextSettersAreControlAndOnlyTheEnvironmentOneNamesATarget`
Expected: FAIL — `ctx_set_project`'s kind is `.read`, and `session_list` is absent.

- [ ] **Step 3: Write minimal implementation**

**3a.** In `StandardActions.swift`, change `ctx_set_project`'s `kind: .read` to
`kind: .control` and replace the comment above the registration's `kind` line with a
pointer to the new reasoning:

```swift
        kind: .control,
```

**3b.** Change `ctx_set_environment` to `.control` and give it the target param. Its
registration's closing paren becomes:

```swift
        kind: .control,
        schema: nameParamSchema,
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_set_environment", role: "context")
            }
            let name = try requireStringParam(params, "name", action: "ctx_set_environment")
            return try await callChecked(
                context, tool: "set_environment", arguments: .object(["name": .string(name)]), action: "ctx_set_environment")
        },
        // The only action in Wakil that names a target environment. See
        // `writeGate`: this is what gates an agent switching *into*
        // production while leaving an operator's own switch free.
        targetEnvironmentParam: "name"
    ))
```

**3c.** Replace the doc comment paragraph on `registerStandardActions` that begins "All
six are `ActionKind.read`" with:

```swift
/// Seven of the nine are `ActionKind.read`. The two `ctx_` setters are
/// `.control`: they change Wakil's own selection of what is active, not
/// the outside world the gate exists to protect, so the environment must
/// never block them — gating a context switch in `production` would block
/// it in exactly the case where an operator most needs to go *look* at
/// something.
///
/// `ctx_set_environment` additionally declares
/// `targetEnvironmentParam: "name"`, which is what lets `writeGate` refuse
/// an *agent* switching into production without a typed confirmation. 2a
/// classified both setters `.read` and the 2026-09-08 acceptance run found
/// the consequence: asked only to list projects, the agent also set the
/// active one, and nothing stopped it
/// (`docs/wakil/phase-2a-acceptance.md` §6).
///
/// **`ctx_set_project` deliberately declares no target.**
/// `wakilcore.SetProjectChecked` keeps the current environment name when
/// the incoming project defines one by that name and otherwise clears it
/// to `""` — there is no per-project "last environment" stored anywhere to
/// restore. So a project switch can only preserve the current environment
/// or drop to none; it cannot elevate staging into production, and there
/// is nothing for the gate to catch. `ctxSetProjectCannotElevateInto
/// Production` below pins that Phase 1 behaviour, so a change to it fails
/// here rather than quietly widening the gate.
///
/// Wakil still ships zero `.mutate` actions.
```

**3d.** Append `session_list` after `session_resume`:

```swift
    // ⌘P's session source. `wakil-ctx` has served `list_sessions` since
    // Phase 1, but 2a wrapped only `get_session` — so `session_resume`
    // required an id that nothing in Wakil could produce. This is that
    // missing half.
    await registry.register(Action(
        name: "session_list",
        description:
            "List Claude Code sessions for the active project's roots across every provider the "
            + "active org holds, newest first. Reports how many transcript stores could not be "
            + "read, so an empty list with a non-zero skipped count means \"could not look\", not "
            + "\"none exist\".",
        kind: .read,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_list", role: "context")
            }
            return try await callChecked(
                context, tool: "list_sessions", arguments: .object([:]), action: "session_list")
        }
    ))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make app-test`
Expected: PASS. If `StandardActionsTests` has a test asserting an exact action *count*,
update it from six to nine and note the change in the commit message.

- [ ] **Step 5: Add a two-project fixture**

The existing `makeFixture(org:projectOrg:environments:)` in
`app/Tests/WakilKitTests/ContextStoreTests.swift:25` builds exactly one project, always
named `widgets`. The guarantee test needs two projects with *different* environment sets,
so add a second builder beside it — in the same file, since that is where `makeFixture`
and `startedClient` already live and both are `internal` free functions shared across the
test target:

```swift
/// A scratch `HOME` holding one org and **two** projects with different
/// environment sets, for testing what `set_project` does to the active
/// environment.
///
/// Distinct from `makeFixture` above rather than a parameter on it:
/// `makeFixture`'s single `widgets` project is depended on by name in
/// several tests, and widening it would churn all of them for one caller.
func makeTwoProjectFixture(
    org: String, projects: [(name: String, environments: [String])]
) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)

    var registryEntries: [String] = []
    for project in projects {
        let projectDir = home.appendingPathComponent("proj-\(project.name)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let projectPath = projectDir.appendingPathComponent("project.json")
        let envsJSON = project.environments
            .map { "\"\($0)\":{\"databases\":[]}" }
            .joined(separator: ",")
        let projectJSON = """
        {"name":"\(project.name)","org":"\(org)","roots":[{"path":"/tmp/\(project.name)"}],\
        "scopes":{},"environments":{\(envsJSON)}}
        """
        try projectJSON.write(to: projectPath, atomically: true, encoding: .utf8)
        registryEntries.append("\"\(project.name)\":{\"path\":\"\(projectPath.path)\"}")
    }

    let registryJSON = "{\(registryEntries.joined(separator: ","))}"
    try registryJSON.write(
        to: orgDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
    return home
}
```

- [ ] **Step 6: Write the Phase 1 guarantee test**

Append to `StandardActionsTests.swift`, following the shape of
`ctxSetProjectRefusesAProjectFiledUnderAnotherOrg` at line 357 — the same `repoRoot()`,
`#require` on the binary, and `startedClient`:

```swift
/// Pins the Phase 1 behaviour `writeGate` leans on: switching project
/// preserves the environment name when the incoming project defines it and
/// clears it otherwise. It never substitutes a *different* environment, and
/// in particular never selects `production`.
///
/// This is why `ctx_set_project` declares no `targetEnvironmentParam` while
/// `ctx_set_environment` does. If this test fails, the setter needs one and
/// `writeGate`'s agent rule needs to cover it — do not simply update the
/// expectation.
@Test func ctxSetProjectCannotElevateIntoProduction() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")
    let home = try makeTwoProjectFixture(org: "acme", projects: [
        (name: "alpha", environments: ["staging", "production"]),
        (name: "beta", environments: ["production"]),
    ])
    let client = try await startedClient(bin: bin, home: home, org: "acme")
    let registry = ActionRegistry(journalDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString), sessionId: "s1")
    await registerStandardActions(into: registry, context: client, panes: PaneStore(), db: nil)

    func dispatch(_ name: String, _ value: String) async throws {
        _ = try await registry.dispatch(
            name: name, params: .object(["name": .string(value)]),
            origin: .ui, environment: "staging", confirmation: nil)
    }

    try await dispatch("ctx_set_project", "alpha")
    try await dispatch("ctx_set_environment", "staging")
    #expect(try await ContextStore(client: client).current().environment == "staging")

    // beta does not define `staging`, so the environment clears. It does
    // NOT become beta's only environment, `production`.
    try await dispatch("ctx_set_project", "beta")
    #expect(try await ContextStore(client: client).current().environment == "")

    await client.stop()
}
```

- [ ] **Step 7: Run it**

Run: `make build && cd app && swift test --filter ctxSetProjectCannotElevateIntoProduction`
Expected: PASS. `make build` first — this test spawns the real `bin/wakil-ctx`.

If `current()` throws `ContextStoreError.serverError` on the cleared environment rather
than returning `""`, catch it and assert the message does not contain `production`; the
point of the test is that production is never *selected*, not the exact spelling of
"none".

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift \
        app/Tests/WakilKitTests/StandardActionsTests.swift \
        app/Tests/WakilKitTests/ContextStoreTests.swift
git commit -m "feat(actions): reclassify ctx setters as .control and add session_list"
```

---

### Task 10: `read_layout` and the agent's allow list

**Files:**
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift` (`MCPSurface`, `handle`,
  `handleToolsCall`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:356-367` (`agentAllowedTools`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (`WakilWiring`, `build`, `mcpSurface`)
- Test: `app/Tests/WakilKitTests/MCPServerTests.swift`,
  `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `LayoutStore` (Task 7), `LayoutSnapshot`.
- Produces:
  - `public let readLayoutToolName = "read_layout"`
  - `MCPSurface` gains `public let layout: LayoutStore`; its `init` takes it third.
  - `WakilWiring` gains `public let layout: LayoutStore`.
  - `agentAllowedTools` admits `.read` **and** `.control`, plus `read_pane` and
    `read_layout`.

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/MCPServerTests.swift`:

```swift
@Test func readLayoutReportsPanesFramesFocusAndSnaps() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("read-layout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let layout = LayoutStore()
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: layout)

    let a = await layout.open(kind: "db", title: "A")
    let b = await layout.open(kind: "db", title: "B")
    try await layout.snap(id: b.id, to: a.id, edge: .left)

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, environment: "staging")

    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"],
          case .array(let panes)? = structured["panes"]
    else {
        Issue.record("read_layout returned \(String(describing: reply?.result))")
        return
    }
    #expect(panes.count == 2)
    #expect(structured["focusedId"] == .string(b.id))
    #expect(structured["maximizedId"] == .null)
    guard case .array(let links)? = structured["snaps"] else {
        Issue.record("no snaps array")
        return
    }
    #expect(links.count == 1)
}

@Test func readLayoutIsAdvertisedAndJournalsNothing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("read-layout-list-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    let surface = MCPSurface(registry: registry, panes: PaneStore(), layout: LayoutStore())

    let listed = await handle(
        JSONRPCMessage(id: .number(1), method: "tools/list", params: nil),
        surface: surface, environment: "staging")
    guard case .object(let result)? = listed?.result, case .array(let tools)? = result["tools"] else {
        Issue.record("tools/list returned no tools")
        return
    }
    let names = tools.compactMap { tool -> String? in
        guard case .object(let object) = tool, case .string(let name)? = object["name"] else { return nil }
        return name
    }
    #expect(names.contains("read_layout"))
    #expect(names.contains("read_pane"))

    _ = await handle(
        JSONRPCMessage(
            id: .number(2), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, environment: "staging")
    // Hand-written like read_pane: a pure read of UI state, so it reaches
    // neither the gate nor the journal.
    #expect(try await registry.journalEntries().isEmpty)
}

@Test func readLayoutOnAnEmptyCanvasIsAnEmptyAnswerNotAnError() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("read-layout-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let surface = MCPSurface(
        registry: ActionRegistry(journalDirectory: directory, sessionId: "s"),
        panes: PaneStore(), layout: LayoutStore())

    let reply = await handle(
        JSONRPCMessage(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("read_layout"), "arguments": .object([:])])),
        surface: surface, environment: "staging")

    #expect(reply?.error == nil)
    guard case .object(let result)? = reply?.result,
          case .object(let structured)? = result["structuredContent"]
    else {
        Issue.record("no structuredContent")
        return
    }
    #expect(structured["panes"] == .array([]))
    #expect(structured["focusedId"] == .null)
}
```

Append to `app/Tests/WakilKitTests/WindowModelTests.swift`:

```swift
@Test func theAllowListAdmitsControlActionsAndBothReadTools() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("allow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerStandardActions(into: registry, context: nil, panes: PaneStore(), db: nil)
    await registerLayoutActions(into: registry, layout: LayoutStore())

    let allowed = agentAllowedTools(actions: await registry.all())

    // Layout is reachable — that is the whole point of making it .control.
    #expect(allowed.contains("mcp__wakil__pane_move"))
    #expect(allowed.contains("mcp__wakil__pane_snap"))
    // Context switching stays reachable: the Phase 2 exit criterion needs
    // it. The gate, not the allow list, is what governs production.
    #expect(allowed.contains("mcp__wakil__ctx_set_environment"))
    #expect(allowed.contains("mcp__wakil__read_pane"))
    #expect(allowed.contains("mcp__wakil__read_layout"))
    // Still never a mutation.
    let mutating = await registry.all().filter { $0.kind == .mutate }.map(\.name)
    #expect(mutating.isEmpty)
    for name in mutating { #expect(!allowed.contains("mcp__wakil__\(name)")) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter readLayout`
Expected: FAIL to compile — "extra argument 'layout' in call".

- [ ] **Step 3: Write minimal implementation**

**3a.** In `MCPServer.swift`, add `layout` to `MCPSurface`:

```swift
public struct MCPSurface: Sendable {
    public let registry: ActionRegistry
    public let panes: PaneStore
    public let layout: LayoutStore

    init(registry: ActionRegistry, panes: PaneStore, layout: LayoutStore) {
        self.registry = registry
        self.panes = panes
        self.layout = layout
    }
}
```

**3b.** Add the tool name, its `tools/list` entry, and its handler:

```swift
/// The second of the two hand-written tools on Wakil's MCP surface.
///
/// Hand-written for the same reason `read_pane` is: it is a pure read of
/// UI state, so it changes nothing for the gate to refuse and records
/// nothing for the journal to hold. Registering it as an action would put
/// a no-op entry in the journal every time an agent looked at the screen.
///
/// **It is the other half of Invariant 3.** `read_pane` answers *what is
/// in that pane*; `read_layout` answers *what is on screen, and where*.
/// Neither alone lets an agent resolve a phrase like "the pane next to the
/// terminal".
public let readLayoutToolName = "read_layout"

private let readLayoutToolListEntry = JSONValue.object([
    "name": .string(readLayoutToolName),
    "description": .string(
        "Read the arrangement of Wakil's panes: each pane's id, kind, title, position and size, "
        + "whether it is busy, which pane is focused, which (if any) fills the canvas, and which "
        + "pane edges are snapped together. Use it with read_pane to resolve references like "
        + "\"the pane next to the results\"."),
    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
])

/// Projects a `LayoutSnapshot` into `read_layout`'s wire shape.
///
/// `focusedId` and `maximizedId` are always present, `.null` when unset,
/// for the reason `PaneStore.snapshot` always emits `truncated`: this
/// object is read by an LLM, and an absent key is something a reader must
/// know to interpret while an explicit null is an answer.
private func layoutPayload(_ snapshot: LayoutSnapshot) -> JSONValue {
    .object([
        "panes": .array(snapshot.panes.map { pane in
            .object([
                "id": .string(pane.id),
                "kind": .string(pane.kind),
                "title": .string(pane.title),
                "x": .number(pane.frame.x),
                "y": .number(pane.frame.y),
                "width": .number(pane.frame.width),
                "height": .number(pane.frame.height),
                "busy": .bool(pane.busy),
            ])
        }),
        "focusedId": snapshot.focusedId.map { JSONValue.string($0) } ?? .null,
        "maximizedId": snapshot.maximizedId.map { JSONValue.string($0) } ?? .null,
        "snaps": .array(snapshot.graph.links.map { link in
            .object([
                "paneId": .string(link.paneId),
                "edge": .string(link.edge.rawValue),
                "otherPaneId": .string(link.otherPaneId),
            ])
        }),
    ])
}

private func readLayout(id: JSONRPCID, layout: LayoutStore) async -> JSONRPCMessage {
    let payload = layoutPayload(await layout.snapshot())
    let text = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return JSONRPCMessage(id: id, result: .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": payload,
    ]))
}
```

**3c.** In `handle`'s `tools/list` case, append the entry:

```swift
    case "tools/list":
        var tools = await surface.registry.all().map(toolListEntry)
        tools.append(readPaneToolListEntry)
        tools.append(readLayoutToolListEntry)
        return JSONRPCMessage(id: id, result: .object(["tools": .array(tools)]))
```

**3d.** In `handleToolsCall`, alongside the `read_pane` branch:

```swift
    if name == readLayoutToolName {
        return await readLayout(id: id, layout: surface.layout)
    }
```

**3e.** In `AppWiring.swift`, add `layout` to `WakilWiring`, build one in `build`, pass it
to `registerLayoutActions`, and include it in `mcpSurface`:

```swift
    public let layout: LayoutStore
```
```swift
        let panes = PaneStore()
        let layout = LayoutStore()
        let registry = ActionRegistry(journalDirectory: journalDirectory, sessionId: sessionId)
        await registerStandardActions(into: registry, context: contextClient, panes: panes, db: databaseClient)
        await registerLayoutActions(into: registry, layout: layout)

        return WakilWiring(
            registry: registry,
            panes: panes,
            layout: layout,
            contextClient: contextClient,
            databaseClient: databaseClient,
            diagnostics: diagnostics
        )
```
```swift
    public var mcpSurface: MCPSurface {
        MCPSurface(registry: registry, panes: panes, layout: layout)
    }
```

**3f.** In `WindowModel.swift`, widen `agentAllowedTools`:

```swift
public func agentAllowedTools(actions: [ActionDescriptor]) -> [String] {
    // `.read` and `.control`, never `.mutate`.
    //
    // `.control` joined this list in 2b-i and is what makes "put the
    // results next to the terminal" reachable at all — layout actions are
    // `.control`, and a filter on `.read` alone would publish a tool
    // surface the agent could see in `tools/list` and never be permitted
    // to call. The context setters are `.control` too and stay reachable
    // deliberately: the Phase 2 exit criterion is a spoken "open the
    // booking project on staging…", so removing them here would make the
    // criterion unsatisfiable. What governs production is `writeGate`,
    // which refuses an agent-originated switch *into* production without a
    // typed confirmation — a gate, not an absence from this list.
    //
    // Sorted because `ActionRegistry.all()` walks a dictionary and so has
    // no order of its own: an argv that changed between launches would
    // make two otherwise identical sessions diff differently in a log.
    var tools = actions
        .filter { $0.kind == .read || $0.kind == .control }
        .map { "mcp__\(wakilShimServerName)__\($0.name)" }
        .sorted()
    tools.append("mcp__\(wakilShimServerName)__\(readPaneToolName)")
    tools.append("mcp__\(wakilShimServerName)__\(readLayoutToolName)")
    tools.append(contentsOf: agentFacingServers.map { "mcp__\($0)" })
    return tools
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make app-test`
Expected: PASS. Existing `MCPServerTests` and `ShimTests` construct `MCPSurface`
directly; add `layout: LayoutStore()` to each such call site. Any existing test asserting
the exact `tools/list` count grows by one.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/MCPServer.swift app/Sources/WakilKit/App/AppWiring.swift \
        app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/
git commit -m "feat(mcp): add read_layout and admit .control actions to the agent's allow list"
```

---

### Task 11: Layout persistence

**Files:**
- Create: `app/Sources/WakilKit/Layout/LayoutPersistence.swift`
- Test: `app/Tests/WakilKitTests/LayoutPersistenceTests.swift`

**Interfaces:**
- Consumes: `LayoutSnapshot`, `LayoutStore` (Task 7).
- Produces:
  ```swift
  public struct LayoutPersistence: Sendable {
      public init(directory: URL)
      public func save(_ snapshot: LayoutSnapshot, org: String, project: String) throws
      public func load(org: String, project: String) -> (snapshot: LayoutSnapshot?, note: String?)
      public static func defaultDirectory(home: String) -> URL
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/LayoutPersistenceTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

private func scratch() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("layouts-\(UUID().uuidString)", isDirectory: true)
}

@Test func aSavedLayoutLoadsBackIdentically() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    var graph = SnapGraph()
    graph.link("db-1", .right, to: "db-2")
    let snapshot = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "One",
                 frame: PaneFrame(x: 10, y: 20, width: 300, height: 200)),
            Pane(id: "db-2", kind: "db", title: "Two",
                 frame: PaneFrame(x: 310, y: 20, width: 300, height: 200)),
        ],
        focusedId: "db-2", maximizedId: nil, graph: graph)

    try store.save(snapshot, org: "personal", project: "booking")
    #expect(store.load(org: "personal", project: "booking").snapshot == snapshot)
}

@Test func loadingSomethingNeverSavedIsNilWithNoNote() {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = LayoutPersistence(directory: directory).load(org: "personal", project: "nope")
    // Absence is not degradation: a project simply has no saved layout
    // yet, and a note here would put a warning in the window on every
    // first run.
    #expect(result.snapshot == nil)
    #expect(result.note == nil)
}

@Test func aCorruptLayoutDegradesToNilWithANote() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    try store.save(LayoutSnapshot(), org: "personal", project: "booking")

    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking.json")
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)

    let result = store.load(org: "personal", project: "booking")
    #expect(result.snapshot == nil)
    let note = try #require(result.note)
    #expect(note.contains("booking"))
}

@Test func twoProjectsInOneOrgDoNotOverwriteEachOther() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let one = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "One", frame: PaneFrame(x: 1, y: 1, width: 1, height: 1))
    ])
    let two = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "Two", frame: PaneFrame(x: 2, y: 2, width: 2, height: 2))
    ])
    try store.save(one, org: "personal", project: "alpha")
    try store.save(two, org: "personal", project: "beta")

    #expect(store.load(org: "personal", project: "alpha").snapshot == one)
    #expect(store.load(org: "personal", project: "beta").snapshot == two)
}

@Test func projectNamesWithPathSeparatorsCannotEscapeTheDirectory() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    try store.save(LayoutSnapshot(), org: "personal", project: "../../escaped")
    // Whatever it wrote, it wrote inside `directory`.
    let escaped = directory.deletingLastPathComponent().appendingPathComponent("escaped.json")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(store.load(org: "personal", project: "../../escaped").snapshot == LayoutSnapshot())
}

@Test func theDefaultDirectoryHangsOffTheGivenHome() {
    let url = LayoutPersistence.defaultDirectory(home: "/tmp/somewhere")
    #expect(url.path == "/tmp/somewhere/.wakil/layouts")
}

@Test func savingTwiceIsStableOnDisk() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    var graph = SnapGraph()
    graph.link("db-2", .left, to: "db-1")
    graph.link("db-1", .bottom, to: "db-3")
    let snapshot = LayoutSnapshot(panes: [], focusedId: nil, maximizedId: nil, graph: graph)

    try store.save(snapshot, org: "personal", project: "booking")
    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking.json")
    let first = try Data(contentsOf: file)
    try store.save(snapshot, org: "personal", project: "booking")
    // Byte-identical: an unchanged arrangement must not churn the file,
    // which is what `SnapGraph.links`' sort is for.
    #expect(try Data(contentsOf: file) == first)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter LayoutPersistenceTests`
Expected: FAIL to compile — "cannot find 'LayoutPersistence' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Layout/LayoutPersistence.swift`:

```swift
import Foundation

/// Reads and writes one project's pane arrangement under
/// `~/.wakil/layouts/<org>/<project>.json`.
///
/// **Machine-local, and deliberately nowhere near `project.json`.** Where
/// someone likes their panes is not a property of the project that other
/// people check out, and `project.json` is committable. Nothing written
/// here is secret: pane ids, kinds, titles and rectangles.
///
/// **A bad file must never stop the app opening.** `load` returns `nil`
/// plus a human-readable note rather than throwing, and the window shows
/// that note in the same list that reports a missing Go binary or a socket
/// that would not bind — visible degradation over silent failure, which is
/// the convention 2a set.
public struct LayoutPersistence: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<home>/.wakil/layouts`. Takes `home` rather than reading it, for
    /// the same reason `WakilWiring.build` takes its journal directory: a
    /// test must be able to point this somewhere scratch without setting a
    /// process-wide variable.
    public static func defaultDirectory(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("layouts", isDirectory: true)
    }

    public func save(_ snapshot: LayoutSnapshot, org: String, project: String) throws {
        let file = fileURL(org: org, project: project)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged arrangement encodes to identical
        // bytes run after run; `SnapGraph` sorts its own links for the
        // same reason. A file that churns on every launch is a file whose
        // modification time means nothing.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    /// The saved arrangement, or `nil` with a note explaining why not.
    ///
    /// A file that was never written is `(nil, nil)` — absence is not
    /// degradation, and a note on every first run would train the operator
    /// to ignore the notes list.
    public func load(org: String, project: String) -> (snapshot: LayoutSnapshot?, note: String?) {
        let file = fileURL(org: org, project: project)
        guard let data = try? Data(contentsOf: file) else { return (nil, nil) }
        do {
            return (try JSONDecoder().decode(LayoutSnapshot.self, from: data), nil)
        } catch {
            return (nil, "layout for \(org)/\(project) could not be read (\(error)); starting from an empty canvas")
        }
    }

    /// One file per project, under one directory per org.
    ///
    /// Org and project names are flattened before use: they come from a
    /// user-authored registry, and one containing `/` or `..` would
    /// otherwise write outside `directory`. Replacing rather than
    /// rejecting keeps a legal-but-awkward project name working; the
    /// mapping need not be reversible, because nothing ever reads these
    /// names back off the filesystem.
    private func fileURL(org: String, project: String) -> URL {
        directory
            .appendingPathComponent(flatten(org), isDirectory: true)
            .appendingPathComponent("\(flatten(project)).json")
    }

    private func flatten(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character == "/" || character == ":" || character == "\\" ? "_" : character
        }
        let result = String(cleaned).replacingOccurrences(of: "..", with: "__")
        return result.isEmpty ? "_" : result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter LayoutPersistenceTests`
Expected: PASS, all seven tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Layout/LayoutPersistence.swift \
        app/Tests/WakilKitTests/LayoutPersistenceTests.swift
git commit -m "feat(layout): persist each project's arrangement under ~/.wakil/layouts"
```

---

### Task 12: The palette model and fuzzy scorer

**Files:**
- Create: `app/Sources/WakilKit/Command/PaletteItem.swift`
- Test: `app/Tests/WakilKitTests/PaletteTests.swift`

**Interfaces:**
- Consumes: `ActionDescriptor` (existing), `Pane` (Task 4).
- Produces:
  ```swift
  public struct PaletteItem: Sendable, Equatable, Identifiable {
      public enum Kind: String, Sendable, Equatable { case action, pane, project, session }
      public let id: String
      public let kind: Kind
      public let title: String
      public let subtitle: String
      public let payload: String     // action name, pane id, project name, session id
      public init(id: String, kind: Kind, title: String, subtitle: String, payload: String)
  }
  public func fuzzyScore(_ query: String, against candidate: String) -> Int?
  public func rank(_ items: [PaletteItem], query: String) -> [PaletteItem]
  public func actionPaletteItems(_ actions: [ActionDescriptor]) -> [PaletteItem]
  public func panePaletteItems(_ panes: [Pane]) -> [PaletteItem]
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/PaletteTests.swift`:

```swift
import Testing
@testable import WakilKit

@Test func anEmptyQueryMatchesEverythingWithEqualScore() {
    #expect(fuzzyScore("", against: "pane_move") != nil)
    #expect(fuzzyScore("", against: "anything") == fuzzyScore("", against: "other"))
}

@Test func aNonSubsequenceDoesNotMatch() {
    #expect(fuzzyScore("zzz", against: "pane_move") == nil)
    // Right letters, wrong order.
    #expect(fuzzyScore("evom", against: "pane_move") == nil)
}

@Test func aSubsequenceMatchesEvenWhenScattered() {
    #expect(fuzzyScore("pm", against: "pane_move") != nil)
    #expect(fuzzyScore("pnmv", against: "pane_move") != nil)
}

@Test func matchingIsCaseInsensitive() {
    #expect(fuzzyScore("PM", against: "pane_move") != nil)
    #expect(fuzzyScore("pm", against: "PANE_MOVE") != nil)
}

@Test func aPrefixScoresHigherThanAScatteredMatch() {
    let prefix = try! #require(fuzzyScore("pane", against: "pane_move"))
    let scattered = try! #require(fuzzyScore("pane", against: "propagate_and_negate"))
    #expect(prefix > scattered)
}

@Test func aWordBoundaryScoresHigherThanMidWord() {
    // "pm" hits the start of both words in pane_move.
    let boundary = try! #require(fuzzyScore("pm", against: "pane_move"))
    // "pm" in "compamy" is mid-word twice.
    let midWord = try! #require(fuzzyScore("pm", against: "compamy"))
    #expect(boundary > midWord)
}

@Test func rankingDropsNonMatchesAndOrdersByScore() {
    let items = [
        PaletteItem(id: "1", kind: .action, title: "db_run_query", subtitle: "", payload: "db_run_query"),
        PaletteItem(id: "2", kind: .action, title: "pane_move", subtitle: "", payload: "pane_move"),
        PaletteItem(id: "3", kind: .action, title: "ctx_set_project", subtitle: "", payload: "ctx_set_project"),
    ]
    let ranked = rank(items, query: "pane")
    #expect(ranked.map(\.payload) == ["pane_move"])
}

@Test func rankingSearchesTheSubtitleToo() {
    let items = [
        PaletteItem(id: "1", kind: .action, title: "pane_snap",
                    subtitle: "Snap one pane flush against another", payload: "pane_snap")
    ]
    #expect(rank(items, query: "flush").count == 1)
}

@Test func rankingIsStableForEqualScores() {
    let items = [
        PaletteItem(id: "1", kind: .pane, title: "alpha", subtitle: "", payload: "a"),
        PaletteItem(id: "2", kind: .pane, title: "alpha", subtitle: "", payload: "b"),
    ]
    #expect(rank(items, query: "alpha").map(\.payload) == ["a", "b"])
}

@Test func actionsBecomePaletteItemsCarryingTheirName() {
    let descriptor = ActionDescriptor(
        name: "pane_move", description: "Move a pane.", kind: .control, schema: .object([:]))
    let items = actionPaletteItems([descriptor])
    #expect(items.count == 1)
    #expect(items[0].kind == .action)
    #expect(items[0].title == "pane_move")
    #expect(items[0].subtitle == "Move a pane.")
    #expect(items[0].payload == "pane_move")
}

@Test func panesBecomePaletteItemsCarryingTheirId() {
    let pane = Pane(
        id: "db-1", kind: "db", title: "Results",
        frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    let items = panePaletteItems([pane])
    #expect(items[0].kind == .pane)
    #expect(items[0].title == "Results")
    #expect(items[0].subtitle == "db")
    #expect(items[0].payload == "db-1")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter PaletteTests`
Expected: FAIL to compile — "cannot find 'fuzzyScore' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/Command/PaletteItem.swift`:

```swift
import Foundation

/// One row in ⌘P or ⌘K.
///
/// Both palettes are the same view over `[PaletteItem]` and differ only in
/// what fills the array: ⌘K is `registry.all()` and nothing else, ⌘P is
/// open panes plus projects plus sessions. `kind` is what the selection
/// handler switches on to decide what to dispatch, and `payload` is the
/// one string it needs — an action name, a pane id, a project name, a
/// session id.
public struct PaletteItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case action, pane, project, session
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let payload: String

    public init(id: String, kind: Kind, title: String, subtitle: String, payload: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.payload = payload
    }
}

/// How well `query` matches `candidate`, or `nil` if it does not match at
/// all. Higher is better.
///
/// A subsequence matcher: every character of `query` must appear in
/// `candidate`, in order, but not necessarily adjacently — so `pm` finds
/// `pane_move`. Written by hand rather than pulled in, because it is
/// twenty lines and a dependency here would be the only one in the
/// package.
///
/// Scoring rewards the two things that make a fuzzy match feel right:
///
/// - **Word boundaries.** A character matched at the start of the string
///   or just after `_`, `-`, `.` or a space is worth much more than one
///   matched mid-word. This is what makes `pm` rank `pane_move` above
///   `compamy`.
/// - **Adjacency.** Consecutive matched characters are worth more than
///   scattered ones, so an exact prefix beats a match spread across the
///   whole string.
///
/// An empty query matches everything with the same score, so an untyped
/// palette shows its source list in its own order rather than a shuffled
/// one.
public func fuzzyScore(_ query: String, against candidate: String) -> Int? {
    let needle = Array(query.lowercased())
    guard !needle.isEmpty else { return 0 }
    let haystack = Array(candidate.lowercased())

    var score = 0
    var needleIndex = 0
    var previousMatch: Int?

    for (index, character) in haystack.enumerated() {
        guard needleIndex < needle.count, character == needle[needleIndex] else { continue }

        var points = 1
        let isBoundary = index == 0 || "_-. ".contains(haystack[index - 1])
        if isBoundary { points += 8 }
        if let previous = previousMatch, previous == index - 1 { points += 4 }

        score += points
        previousMatch = index
        needleIndex += 1
    }

    return needleIndex == needle.count ? score : nil
}

/// `items` filtered to those matching `query` and ordered best-first.
///
/// An item matches on its title *or* its subtitle, and takes the better of
/// the two scores — so ⌘K finds `pane_snap` by typing "flush", which
/// appears only in its description. Ties keep their input order, which is
/// what makes an empty query show a stable list.
public func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
    items
        .enumerated()
        .compactMap { position, item -> (Int, Int, PaletteItem)? in
            let title = fuzzyScore(query, against: item.title)
            let subtitle = fuzzyScore(query, against: item.subtitle)
            guard let best = [title, subtitle].compactMap({ $0 }).max() else { return nil }
            return (best, position, item)
        }
        .sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }
        .map(\.2)
}

/// Every registered action as a ⌘K row.
///
/// This is the dual-drive bet made literally visible: the command palette
/// is not a hand-maintained menu that happens to resemble the agent's tool
/// list, it *is* that list, because both read `ActionRegistry.all()`. An
/// action registered anywhere appears in ⌘K without a view being edited,
/// and one that does not appear is one that is not registered.
public func actionPaletteItems(_ actions: [ActionDescriptor]) -> [PaletteItem] {
    actions
        .sorted { $0.name < $1.name }
        .map {
            PaletteItem(
                id: "action:\($0.name)", kind: .action, title: $0.name,
                subtitle: $0.description, payload: $0.name)
        }
}

/// Open panes as ⌘P rows.
public func panePaletteItems(_ panes: [Pane]) -> [PaletteItem] {
    panes.map {
        PaletteItem(
            id: "pane:\($0.id)", kind: .pane, title: $0.title,
            subtitle: $0.kind, payload: $0.id)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter PaletteTests`
Expected: PASS, all eleven tests.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Command/PaletteItem.swift app/Tests/WakilKitTests/PaletteTests.swift
git commit -m "feat(command): add the palette item model and fuzzy scorer"
```

---

### Task 13: Wire the window's model to layout

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 7–12.
- Produces, on `WindowModel`:
  ```swift
  public private(set) var layoutSnapshot: LayoutSnapshot
  public private(set) var dragCandidate: SnapCandidate?
  public func refreshLayout() async
  public func openPane(kind: String) async
  public func closePane(id: String) async
  public func focusPane(id: String) async
  public func commitDrag(id: String, x: Double, y: Double) async
  public func commitResize(id: String, width: Double, height: Double) async
  public func previewDrag(id: String, x: Double, y: Double) async
  public func endDrag(id: String) async
  public func toggleMaximize(id: String) async
  public func commandItems() async -> [PaletteItem]
  public func openItems() async -> [PaletteItem]
  public func runPaletteItem(_ item: PaletteItem) async
  ```

- [ ] **Step 1: Write the failing test**

Append to `app/Tests/WakilKitTests/WindowModelTests.swift`. That file builds models with
its own `makeRegistry() throws -> (ActionRegistry, PaneStore)` helper (line 68) and calls
`WindowModel(registry:panes:context:harness:)` directly; both grow a `layout` parameter
here. First widen the existing helper in place:

```swift
private func makeRegistry() throws -> (ActionRegistry, PaneStore, LayoutStore) {
    let dir = try windowScratchDirectory()
    return (
        ActionRegistry(journalDirectory: dir, sessionId: "window-test"),
        PaneStore(),
        LayoutStore()
    )
}
```

and update its six existing call sites to destructure three values and pass
`layout: layout` to `WindowModel(...)`. Then append:

```swift
/// Builds a model whose registry has both the standard and the layout
/// actions in it — what the window actually gets from `WakilWiring.build`.
@MainActor
private func makeLayoutModel() async throws -> (WindowModel, ActionRegistry, LayoutStore) {
    let (registry, panes, layout) = try makeRegistry()
    await registerStandardActions(into: registry, context: nil, panes: panes, db: nil)
    await registerLayoutActions(into: registry, layout: layout)
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil, harness: nil)
    return (model, registry, layout)
}

@Test @MainActor func openingAPaneThroughTheModelGoesThroughTheRegistry() async throws {
    let (model, registry, _) = try await makeLayoutModel()

    await model.openPane(kind: "db")

    #expect(model.layoutSnapshot.panes.count == 1)
    let entries = try await registry.journalEntries()
    #expect(entries.map(\.action) == ["pane_open"])
    // Every UI control dispatches; none writes layout state directly.
    #expect(entries.map(\.origin) == [.ui])
}

@Test @MainActor func endingADragCommitsExactlyOneAction() async throws {
    let (model, registry, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let id = try #require(model.layoutSnapshot.panes.first).id

    // A drag is a gesture: previewing dispatches nothing, however many
    // frames it runs for. This is spec §4.1 as an assertion.
    for step in 0..<40 {
        await model.previewDrag(id: id, x: Double(step) * 5, y: 700)
    }
    let duringDrag = try await registry.journalEntries().count

    await model.commitDrag(id: id, x: 195, y: 700)

    let after = try await registry.journalEntries()
    #expect(after.count == duringDrag + 1)
    #expect(after.last?.action == "pane_move")
}

@Test @MainActor func aPreviewNearAnotherPaneSurfacesASnapCandidate() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let anchor = try #require(model.layoutSnapshot.panes.first)
    await model.commitDrag(id: anchor.id, x: 400, y: 100)

    await model.openPane(kind: "db")
    let dragged = try #require(model.layoutSnapshot.panes.last)

    // Land the dragged pane's right edge 4pt short of the anchor's left
    // edge, which is now at x = 400.
    await model.previewDrag(id: dragged.id, x: 400 - dragged.frame.width - 4, y: 100)
    #expect(model.dragCandidate != nil)
    #expect(model.dragCandidate?.toPaneId == anchor.id)

    await model.endDrag(id: dragged.id)
    #expect(model.dragCandidate == nil)
}

@Test @MainActor func commitingADragThatWasPreviewingASnapDispatchesPaneSnap() async throws {
    let (model, registry, layout) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    let anchor = try #require(model.layoutSnapshot.panes.first)
    await model.commitDrag(id: anchor.id, x: 400, y: 100)
    await model.openPane(kind: "db")
    let dragged = try #require(model.layoutSnapshot.panes.last)

    let x = 400 - dragged.frame.width - 4
    await model.previewDrag(id: dragged.id, x: x, y: 100)
    await model.commitDrag(id: dragged.id, x: x, y: 100)

    // The snap is what the user was aiming at, so that is what is
    // journalled and what coordinates the edge — not the position they
    // happened to release on.
    let entries = try await registry.journalEntries()
    #expect(entries.last?.action == "pane_snap")
    #expect(await layout.snapshot().graph.neighbours(of: dragged.id, along: .right) == [anchor.id])
}

@Test @MainActor func commandItemsAreExactlyTheRegisteredActions() async throws {
    let (model, registry, _) = try await makeLayoutModel()

    let items = await model.commandItems()
    let registered = await registry.all().map(\.name).sorted()
    #expect(items.map(\.payload) == registered)
    #expect(items.allSatisfy { $0.kind == .action })
}

@Test @MainActor func runningAPaletteActionDispatchesIt() async throws {
    let (model, registry, _) = try await makeLayoutModel()

    let items = await model.commandItems()
    let restore = try #require(items.first { $0.payload == "pane_restore" })
    await model.runPaletteItem(restore)

    let entries = try await registry.journalEntries()
    #expect(entries.last?.action == "pane_restore")
    #expect(entries.last?.origin == .ui)
}

@Test @MainActor func openItemsIncludeEveryOpenPane() async throws {
    let (model, _, _) = try await makeLayoutModel()
    await model.openPane(kind: "db")
    await model.openPane(kind: "db")

    let items = await model.openItems()
    let panes = items.filter { $0.kind == .pane }
    #expect(panes.count == 2)
    #expect(panes.map(\.payload) == model.layoutSnapshot.panes.map(\.id))
    // With no context client, the project and session sources contribute
    // nothing rather than failing the whole palette.
    #expect(items.allSatisfy { $0.kind == .pane })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter openingAPaneThroughTheModelGoesThroughTheRegistry`
Expected: FAIL to compile — `WindowModel` has no `openPane` and its initialiser takes no
`layout`.

- [ ] **Step 3: Write minimal implementation**

Add to `WindowModel` (it is already `@MainActor` and `@Observable` or equivalent — follow
whatever the existing class uses):

```swift
    /// The arrangement the canvas draws. A cached copy of
    /// `LayoutStore.snapshot()`, refreshed after every dispatch that could
    /// have changed it — the store is an actor and SwiftUI cannot await one
    /// while rendering.
    public private(set) var layoutSnapshot = LayoutSnapshot()

    /// The snap the canvas should preview, or `nil`. Set by
    /// `previewDrag`, cleared by `endDrag` and by `commitDrag`.
    public private(set) var dragCandidate: SnapCandidate?

    public func refreshLayout() async {
        layoutSnapshot = await layout.snapshot()
    }

    public func openPane(kind: String) async {
        await dispatchLayout("pane_open", .object(["kind": .string(kind)]))
    }

    public func closePane(id: String) async {
        await dispatchLayout("pane_close", .object(["id": .string(id)]))
    }

    public func focusPane(id: String) async {
        await dispatchLayout("pane_focus", .object(["id": .string(id)]))
    }

    /// The end of a drag: one action, carrying where the pane actually
    /// landed.
    ///
    /// If a snap was being previewed, this commits `pane_snap` instead of
    /// `pane_move` — the snap is what the user was aiming at, and
    /// recording the move they happened to release on would journal the
    /// wrong intent and leave the edges uncoordinated.
    public func commitDrag(id: String, x: Double, y: Double) async {
        if let candidate = dragCandidate {
            dragCandidate = nil
            await dispatchLayout("pane_snap", .object([
                "id": .string(id),
                "edge": .string(candidate.edge.rawValue),
            ].merging(
                candidate.toPaneId.map { ["toPaneId": JSONValue.string($0)] } ?? [:],
                uniquingKeysWith: { a, _ in a })))
            return
        }
        await dispatchLayout("pane_move", .object([
            "id": .string(id), "x": .number(x), "y": .number(y),
        ]))
    }

    public func commitResize(id: String, width: Double, height: Double) async {
        await dispatchLayout("pane_resize", .object([
            "id": .string(id), "width": .number(width), "height": .number(height),
        ]))
    }

    /// Mid-drag. **Dispatches nothing** — it only asks the store what would
    /// happen, so the canvas can draw a snap line. Spec §4.1: the gesture
    /// is not the action; its commit is.
    public func previewDrag(id: String, x: Double, y: Double) async {
        dragCandidate = await layout.candidate(forDragging: id, to: (x: x, y: y))
    }

    public func endDrag(id: String) async {
        dragCandidate = nil
    }

    public func toggleMaximize(id: String) async {
        if layoutSnapshot.maximizedId == id {
            await dispatchLayout("pane_restore", .object([:]))
        } else {
            await dispatchLayout("pane_maximize", .object(["id": .string(id)]))
        }
    }

    // MARK: - Palettes

    /// ⌘K: every registered action, and nothing else.
    public func commandItems() async -> [PaletteItem] {
        actionPaletteItems(await registry.all())
    }

    /// ⌘P: open panes, then projects, then sessions.
    ///
    /// Projects and sessions are read through the registry like anything
    /// else — `ctx_list_projects` and `session_list` — so an org with no
    /// context client contributes an empty list rather than failing the
    /// whole palette.
    public func openItems() async -> [PaletteItem] {
        var items = panePaletteItems(layoutSnapshot.panes)
        items.append(contentsOf: await paletteItems(
            from: "ctx_list_projects", key: "projects", kind: .project))
        items.append(contentsOf: await paletteItems(
            from: "session_list", key: "sessions", kind: .session))
        return items
    }

    public func runPaletteItem(_ item: PaletteItem) async {
        switch item.kind {
        case .action:
            await dispatchLayout(item.payload, .object([:]))
        case .pane:
            await focusPane(id: item.payload)
        case .project:
            await dispatchLayout("ctx_set_project", .object(["name": .string(item.payload)]))
            await refreshContext()
        case .session:
            await dispatchLayout("session_resume", .object(["id": .string(item.payload)]))
        }
    }

    /// Dispatches through the registry with `origin: .ui`, marks the named
    /// pane busy while it runs, records any error in `status`, and
    /// refreshes the cached snapshot.
    ///
    /// Every layout control in the window goes through here. Nothing in
    /// the view layer touches `LayoutStore` directly — that is Invariant 2
    /// for layout, and it is what makes the `--dispatch` scripts in the
    /// runbook equivalent to clicking.
    private func dispatchLayout(_ name: String, _ params: JSONValue) async {
        var paneId: String?
        if case .object(let object) = params, case .string(let id)? = object["id"] {
            paneId = id
            await layout.setBusy(true, id: id)
        }
        defer { Task { if let paneId { await layout.setBusy(false, id: paneId) } } }

        do {
            _ = try await registry.dispatch(
                name: name, params: params, origin: .ui,
                environment: context?.environment ?? "development", confirmation: nil)
        } catch {
            status = "\(name): \(error)"
        }
        if let paneId { await layout.setBusy(false, id: paneId) }
        await refreshLayout()
    }

    /// Turns one list-returning action's result into palette items.
    /// Silently yields nothing if the action is unavailable or its result
    /// is not the expected shape — a palette that refuses to open because
    /// one of its three sources is missing is worse than one showing the
    /// other two.
    private func paletteItems(
        from action: String, key: String, kind: PaletteItem.Kind
    ) async -> [PaletteItem] {
        guard let result = try? await registry.dispatch(
                name: action, params: .object([:]), origin: .ui,
                environment: context?.environment ?? "development", confirmation: nil),
              case .object(let object) = result,
              case .object(let structured)? = object["structuredContent"],
              case .array(let rows)? = structured[key]
        else { return [] }

        return rows.compactMap { row in
            guard case .object(let fields) = row else { return nil }
            guard case .string(let name)? = fields["name"] ?? fields["id"] else { return nil }
            var subtitle = ""
            if case .string(let summary)? = fields["summary"] ?? fields["provider"] {
                subtitle = summary
            }
            return PaletteItem(
                id: "\(kind.rawValue):\(name)", kind: kind, title: name,
                subtitle: subtitle, payload: name)
        }
    }
```

`WindowModel` needs a `layout: LayoutStore` stored property. Add it to the initialiser
between `panes` and `context` — so the signature becomes
`WindowModel(registry:panes:layout:context:harness:)` — and update the one production
call site (`WakilWindow.swift:134`, which passes `wiring.layout`) and the six in
`WindowModelTests.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "feat(window): drive layout, drag commits and both palettes through the registry"
```

---

### Task 14: The canvas, the rail, and the palettes on screen

**Files:**
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: `WindowModel`'s layout API (Task 13), `rank` (Task 12).
- Produces: no new public API. This is the view layer, covered by the operator runbook and
  by nothing else, which is why it comes last and stays thin.

- [ ] **Step 1: Add the canvas**

Replace the single hard-coded pane with a `ZStack` over `model.layoutSnapshot.panes`.
Each pane is a plain `VStack` — title text, the pane's body, no styling — positioned with
`.offset` and sized with `.frame`, wrapped in a `DragGesture`:

```swift
ZStack(alignment: .topLeading) {
    ForEach(model.layoutSnapshot.panes) { pane in
        paneView(pane)
            .frame(width: pane.frame.width, height: pane.frame.height)
            .offset(x: pane.frame.x + (dragOffsets[pane.id]?.width ?? 0),
                    y: pane.frame.y + (dragOffsets[pane.id]?.height ?? 0))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Local state only — no await, no dispatch. This
                        // runs every frame and must stay off the actor.
                        dragOffsets[pane.id] = value.translation
                        Task {
                            await model.previewDrag(
                                id: pane.id,
                                x: pane.frame.x + value.translation.width,
                                y: pane.frame.y + value.translation.height)
                        }
                    }
                    .onEnded { value in
                        dragOffsets[pane.id] = nil
                        Task {
                            await model.commitDrag(
                                id: pane.id,
                                x: pane.frame.x + value.translation.width,
                                y: pane.frame.y + value.translation.height)
                        }
                    })
    }
    if let candidate = model.dragCandidate {
        snapLine(for: candidate)
    }
}
```

`dragOffsets` is `@State private var dragOffsets: [String: CGSize] = [:]`. The offset
lives in view state so the pane follows the pointer at frame rate; the store is only told
on release.

- [ ] **Step 2: Add the rail**

A plain `List` beside the canvas, one row per pane — `Text(pane.title)`, `Text(pane.kind)`,
and `Text(pane.busy ? "working" : "")`, with the focused row marked by a leading `Text("|")`.
Tapping a row calls `model.focusPane(id:)`. No state of its own: every value read comes
from `model.layoutSnapshot`.

- [ ] **Step 3: Add the palettes**

One `PaletteView` used twice, differing only in its items and its placeholder:

```swift
struct PaletteView: View {
    let items: [PaletteItem]
    let onSelect: (PaletteItem) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField("", text: $query)
            List(rank(items, query: query)) { item in
                Button { onSelect(item) } label: {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text(item.subtitle)
                    }
                }
            }
        }
    }
}
```

Present it from two `.sheet` modifiers driven by `@State private var showingOpen = false`
and `showingCommands = false`, with keyboard shortcuts:

```swift
.keyboardShortcut("p", modifiers: .command)   // open / switch
.keyboardShortcut("k", modifiers: .command)   // actions
```

Load the items in `.task` on presentation — `model.openItems()` and
`model.commandItems()` are both `async`.

- [ ] **Step 4: Add the pane commands**

In the `Scene`'s `.commands`, add ⌘⏎ for maximize-toggle on the focused pane, ⌘W for
close, and ⌘N **still absent** — see the spec's §9. Wire each to the corresponding
`WindowModel` method.

- [ ] **Step 5: Build and look at it**

Run: `make app-build && make app-bundle`
Expected: builds clean.

Then launch it with the command from `docs/wakil/phase-2a-acceptance.md` §1 and confirm by
eye: two panes open, one drags, two snap, the rail lists both, ⌘K lists every action, ⌘P
lists the panes. This is a smoke check, not the runbook — Task 15 writes that.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/WakilWindow.swift
git commit -m "feat(window): draw the canvas, the rail and both palettes, unstyled"
```

---

### Task 15: The `--dispatch` proof and the operator runbook

**Files:**
- Create: `docs/wakil/phase-2b-i-acceptance.md`
- Create: `scripts/checks/layout-dual-drive.jsonl`

**Interfaces:**
- Consumes: everything.
- Produces: the runbook 2b-ii and 2b-iii extend.

- [ ] **Step 1: Write the dispatch script**

Create `scripts/checks/layout-dual-drive.jsonl`:

```json
{"action":"pane_open","params":{"kind":"db","title":"Left"}}
{"action":"pane_open","params":{"kind":"db","title":"Right"}}
{"action":"pane_open","params":{"kind":"db","title":"Below"}}
{"action":"pane_move","params":{"id":"db-1","x":100,"y":100}}
{"action":"pane_resize","params":{"id":"db-1","width":300,"height":400}}
{"action":"pane_snap","params":{"id":"db-2","toPaneId":"db-1","edge":"left"}}
{"action":"pane_focus","params":{"id":"db-3"}}
{"action":"pane_maximize","params":{"id":"db-3"}}
{"action":"pane_restore","params":{}}
```

- [ ] **Step 2: Run it**

Run:
```bash
make app-bundle
app/Wakil.app/Contents/MacOS/Wakil --dispatch scripts/checks/layout-dual-drive.jsonl \
  --environment staging
```
Expected: exit 0, nine output lines, none carrying an `"error"` key. The first two carry
`{"id":"db-1"}` and `{"id":"db-2"}`.

- [ ] **Step 3: Verify the journal**

Run:
```bash
grep -c '"origin":"debug"' ~/.wakil/journal/*.jsonl | tail -1
```
Expected: nine entries from that run, every one `"outcome":"ok"`. This is the headless
proof that layout is dual-driven — the same actions the mouse dispatches, driven from a
file.

- [ ] **Step 4: Write the runbook**

Create `docs/wakil/phase-2b-i-acceptance.md`, following
`docs/wakil/phase-2a-acceptance.md`'s shape: what the automated suite covers, what only a
display session can, and what remains unverifiable. It must state:

- The three standing checks: panes drag and snap by hand; the rail reflects what is open;
  ⌘K lists every registered action and running one from it journals `origin: .ui`.
- The `--dispatch` proof above, as the headless equivalent.
- **That 120fps was not observed**, because both displays on this machine report 60Hz,
  and that the recorded figure is GPU and CPU cost against the 8.33ms budget instead
  (`docs/wakil/phase-2b-probe.md` §4).
- **That acceptance checks 5 and 6 from `phase-2a-acceptance.md` remain unrun**, because
  2b-i registers no `.mutate` action, and that they belong to 2b-iii.
- **That the agent-into-production gate has not been exercised live** — `writeGate`'s new
  row is unit-tested, but no `claude` turn has tried to switch environment, and doing so
  spends the operator's subscription.

- [ ] **Step 5: Commit**

```bash
git add docs/wakil/phase-2b-i-acceptance.md scripts/checks/layout-dual-drive.jsonl
git commit -m "docs: add the 2b-i acceptance runbook and its dual-drive dispatch script"
```

---

## Self-Review

**Spec coverage.**

| Spec section | Task |
|---|---|
| §2.2 third kind and gate table | 1, 2, 3 |
| §2.2 `ctx_set_project` Phase 1 guarantee | 9 (step 5) |
| §2.4 agent's reach | 10 |
| §2.5 reclassification | 9 |
| §3.1 two stores | 4, 7 (`PaneStore` untouched) |
| §3.2 `Pane` | 4 |
| §3.3 `LayoutStore`, per-project warmth | 7 |
| §3.4 snap graph, stored not derived | 6 |
| §3.5 snap solver | 5 |
| §4.1 eight actions, commit granularity | 8, 13 |
| §4.2 `read_layout` | 10 |
| §4.3 persistence and degradation | 11 |
| §5 the rail | 13 (busy), 14 (view) |
| §6.1 ⌘K over the registry | 12, 13, 14 |
| §6.2 ⌘P three sources, `session_list` | 9, 13, 14 |
| §6.3 one component | 12, 14 |
| §7 no await on the drag path | 13, 14 |
| §8 verification | every task's tests, plus 15 |
| §9 one window, ⌘N absent | 14 (step 4) |

**Known deviation, recorded rather than hidden.** The spec's §7 also asks for a
project-switch measurement under 400ms. No task measures it, because `LayoutStore`'s swap
is an in-memory dictionary lookup and the latency that criterion is about is
`wakil-ctx`'s reconnect plus 2b-ii's covering animation — neither of which exists here.
The runbook (Task 15) records it as deferred to 2b-ii rather than claiming a number that
would measure nothing.

**Type consistency.** `LayoutSnapshot`, `SnapCandidate`, `SnapGraph`, `SnapLink`,
`PaneFrame`, `SnapEdge`, `PaletteItem` are each defined in exactly one task and used
under the same names afterwards. `LayoutStore.candidate(forDragging:to:)` is spelled
identically in Tasks 7 and 13. `agentAllowedTools` keeps its existing signature.

**Fixture helpers, verified against the source.** The first draft of this plan invented
two helpers that do not exist. The names below were checked and are what the executor
should use:

| Helper | Where | Note |
|---|---|---|
| `makeFixture(org:projectOrg:environments:)` | `ContextStoreTests.swift:25` | One project, always named `widgets`. Not enough for Task 9 — hence the new builder. |
| `makeTwoProjectFixture(org:projects:)` | **new**, Task 9 step 5 | Two projects, different environment sets. |
| `startedClient(bin:home:org:)` | `ContextStoreTests.swift:46` | Reused unchanged. |
| `repoRoot()` | `WakilKitTests` | Reused unchanged. |
| `makeRegistry()` | `WindowModelTests.swift:68` | **Widened** in Task 13 to return a `LayoutStore` too. |
| `windowScratchDirectory()` | `WindowModelTests.swift` | Reused unchanged. |

**One thing the executor must still check.** Task 10 says existing `MCPServerTests` and
`ShimTests` construct `MCPSurface` directly and need a `layout:` argument added. The
exact number of such call sites is not written down here on purpose — a count in a plan
is stale the moment a test is added. Let the compiler find them.
