import Foundation
import Testing
@testable import WakilKit

private func makeRegistry() -> (ActionRegistry, URL) {
    let directory = testScratchRoot
        .appendingPathComponent("layout-actions-\(UUID().uuidString)", isDirectory: true)
    return (ActionRegistry(journalDirectory: directory, sessionId: "s"), directory)
}

@Test func everyLayoutActionIsRegisteredAsControl() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    let expected = [
        "pane_close", "pane_focus", "pane_maximize", "pane_move",
        "pane_open", "pane_resize", "pane_restore", "pane_set_density",
        "pane_snap",
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
        origin: .agent, caller: .test("production"), confirmation: nil)
    #expect(await layout.snapshot().panes.count == 1)
}

// MARK: - A kind this build cannot draw is refused
//
// `kind` was a free string that nothing validated, so `pane_open` would
// mint a pane of any kind at all — and a kind nothing recognises silently
// opts out of every route keyed on kind. `queryTargetPane` is the one that
// bit: it matches `kind == "db"` exactly, so an agent that opened three
// panes as `"database"` left it finding none, falling through to the `"db"`
// key no pane holds, and every query it ran without naming a pane went
// nowhere. Panes on the canvas, rows in the tool result, "no rows" on
// screen — the same symptom as DEFECT X and as the envelope defect, from a
// third cause.
//
// 2b-i's runbook set the trigger for this check ("the check must land in
// 2c, before 2c adds its second pane kind"). It arrived early, and from a
// live failure rather than from a stale saved layout.

@Test func paneOpenRefusesAKindThisBuildCannotDraw() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    do {
        _ = try await registry.dispatch(
            name: "pane_open",
            params: .object(["kind": .string("database"), "title": .string("events.events")]),
            origin: .agent, caller: .test("staging"), confirmation: nil)
        Issue.record("a kind no view can draw should not have opened a pane")
    } catch let error as LayoutActionError {
        #expect(error == .badParam(action: "pane_open", param: "kind", value: "database"))
        // The refusal has to say what a good kind looks like: the agent
        // that just guessed wrong is exactly who needs to know.
        #expect(error.description.contains("\"db\""))
    }

    #expect(await layout.snapshot().panes.isEmpty)
}

@Test func paneOpenStillAcceptsTheKindThisBuildDoesDraw() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    #expect(await layout.snapshot().panes.map(\.kind) == ["db"])
}

/// The schema an agent reads must carry the same list the handler enforces,
/// or the refusal above is a surprise rather than a rule.
@Test func paneOpensSchemaNamesTheKindsItWillAccept() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    let open = try #require(await registry.all().first { $0.name == "pane_open" })
    guard case .object(let schema) = open.schema,
          case .object(let properties)? = schema["properties"],
          case .object(let kind)? = properties["kind"],
          case .array(let allowed)? = kind["enum"] else {
        Issue.record("pane_open's schema does not constrain \"kind\": \(open.schema)")
        return
    }
    #expect(allowed == Pane.kinds.sorted().map { .string($0) })
}

@Test func paneOpenReturnsTheNewPanesId() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    let result = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db"), "title": .string("Rows")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

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
        origin: .ui, caller: .test("staging"), confirmation: nil)
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
        origin: .ui, caller: .test("staging"), confirmation: nil)
    _ = try await registry.dispatch(
        name: "pane_resize",
        params: .object(["id": .string(pane.id), "width": .number(300), "height": .number(200)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let frame = try #require(await layout.snapshot().panes.first).frame
    #expect(frame == PaneFrame(x: 12, y: 34, width: 300, height: 200))
}

@Test func paneCloseRemovesThePaneFromTheStore() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "A")

    _ = try await registry.dispatch(
        name: "pane_close", params: .object(["id": .string(pane.id)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    #expect(await layout.snapshot().panes.isEmpty)
}

@Test func paneFocusMovesFocusToTheNamedPane() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let first = await layout.open(kind: "db", title: "A")
    let second = await layout.open(kind: "db", title: "B")
    // Opening focuses the last-opened pane, so the starting point is
    // `second` and dispatching `pane_focus` must be what moves it back.
    #expect(await layout.snapshot().focusedId == second.id)

    _ = try await registry.dispatch(
        name: "pane_focus", params: .object(["id": .string(first.id)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    #expect(await layout.snapshot().focusedId == first.id)
}

@Test func paneCloseOnAnUnknownIdThrowsRatherThanSucceeding() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    await #expect(throws: LayoutError.unknownPane("nope")) {
        _ = try await registry.dispatch(
            name: "pane_close", params: .object(["id": .string("nope")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
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
        origin: .ui, caller: .test("staging"), confirmation: nil)

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
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
}

@Test func aMissingRequiredParamThrowsRatherThanDefaulting() async {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    await registerLayoutActions(into: registry, layout: LayoutStore())

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "pane_move", params: .object(["id": .string("db-1")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
}

@Test func layoutActionsJournalTheirOrigin() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)

    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .agent, caller: .test("staging"), confirmation: nil)

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
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await layout.snapshot().maximizedId == pane.id)

    _ = try await registry.dispatch(
        name: "pane_restore", params: .object([:]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await layout.snapshot().maximizedId == nil)
    #expect(await layout.snapshot().panes.first?.frame == before)
}

@Test func paneSetDensityIsAControlActionAndChangesOnePane() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let a = await layout.open(kind: "db", title: "a")
    let b = await layout.open(kind: "db", title: "b")

    let action = await registry.all().first { $0.name == "pane_set_density" }
    // .control, not .mutate: changing a row height changes Wakil and
    // nothing else, so the gate's production rule must not apply — being
    // pointed at a production database is no reason to be unable to make a
    // table denser. Spec §11.
    #expect(action?.kind == .control)

    _ = try await registry.dispatch(
        name: "pane_set_density",
        params: .object(["id": .string(a.id), "density": .string("dense")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let snapshot = await layout.snapshot()
    #expect(snapshot.panes.first { $0.id == a.id }?.density == .dense)
    #expect(snapshot.panes.first { $0.id == b.id }?.density == .airy)
}

@Test func paneSetDensityRejectsAnUnknownValue() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    let pane = await layout.open(kind: "db", title: "a")

    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "pane_set_density",
            params: .object(["id": .string(pane.id), "density": .string("compact")]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
}

/// A pane's contents go with it when it closes. Without this a closed
/// pane's rows stayed in memory for the life of the process, and a later
/// pane handed the same id would have drawn them (final review Finding 6).
@Test func closingAPaneDropsItsContents() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    let panes = PaneStore()
    await registerLayoutActions(into: registry, layout: layout, panes: panes)

    let opened = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    guard case .object(let result) = opened, case .string(let id)? = result["id"] else {
        Issue.record("pane_open returned \(opened), expected an object with a string id")
        return
    }
    await panes.setRows(
        paneId: id, columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)
    #expect(await panes.paneIds() == [id])

    _ = try await registry.dispatch(
        name: "pane_close", params: .object(["id": .string(id)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await panes.paneIds() == [])
}

/// A `pane_close` that fails leaves the contents alone: `layout.close`
/// throws on an unknown id, and dropping rows for a pane that did not close
/// would be a leak in the other direction.
@Test func aRefusedPaneCloseDoesNotDropAnyContents() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let panes = PaneStore()
    await registerLayoutActions(into: registry, layout: LayoutStore(), panes: panes)
    await panes.setRows(
        paneId: "db-1", columns: ["id"], columnTypes: [], columnTypesInferred: false,
        rows: [[.number(1)]], millis: 0, truncated: false,
        pageable: true, offset: 0, sort: [], listsTables: false, editable: nil)

    _ = try? await registry.dispatch(
        name: "pane_close", params: .object(["id": .string("db-1")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await panes.paneIds() == ["db-1"])
}

/// `pane_close` asks the injected probe (Layout does not know editors): a non-empty answer
/// refuses unless `discard` is true, and a refusal leaves the pane open.
@Test func paneCloseAsksTheUnsavedProbeAndRefusesUnlessDiscarded() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(
        into: registry, layout: layout, panes: PaneStore(),
        unsavedEditorTabs: { _ in ["a.go"] })
    let opened = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("db")]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    guard case .object(let result) = opened, case .string(let id)? = result["id"] else {
        Issue.record("pane_open returned \(opened)")
        return
    }
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "pane_close", params: .object(["id": .string(id)]),
            origin: .ui, caller: .test("staging"), confirmation: nil)
    }
    #expect(await layout.snapshot().panes.contains { $0.id == id })
    _ = try await registry.dispatch(
        name: "pane_close", params: .object(["id": .string(id), "discard": .bool(true)]),
        origin: .ui, caller: .test("staging"), confirmation: nil)
    #expect(await !layout.snapshot().panes.contains { $0.id == id })
}

@Test func paneOpenAcceptsBrowserAndTitlesItBrowser() async throws {
    let (registry, directory) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = LayoutStore()
    await registerLayoutActions(into: registry, layout: layout)
    _ = try await registry.dispatch(
        name: "pane_open", params: .object(["kind": .string("browser")]),
        origin: .agent, caller: .test("production"), confirmation: nil)
    let panes = await layout.snapshot().panes
    #expect(panes.count == 1 && panes[0].kind == "browser" && panes[0].title == "Browser")
}
