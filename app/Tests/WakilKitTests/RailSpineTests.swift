import Foundation
import Testing
@testable import WakilKit

// §10's collapsible rail: the spine's marks, the action that puts the rail away, and what the
// window remembers. The drawing is `WakilApp`'s, which has no test target; every decision it draws is here.

private func pane(_ id: String, _ kind: String = "terminal", busy: Bool = false) -> Pane {
    var pane = Pane(id: id, kind: kind, title: id, frame: PaneFrame(x: 0, y: 0, width: 300, height: 200))
    pane.busy = busy
    return pane
}

// MARK: - The spine's marks

@Test func theSpineHasOneMarkPerPaneInTheRailsOrder() {
    let panes = [pane("b"), pane("a"), pane("c")]
    let marks = RailSpine.marks(panes: panes, focusedId: nil)
    #expect(marks.map(\.id) == ["b", "a", "c"])
    #expect(marks.allSatisfy { $0.tone == .quiet && $0.length == RailSpine.restLength })
}

@Test func theActivePanesMarkIsLongerAndViolet() {
    let marks = RailSpine.marks(panes: [pane("a"), pane("b")], focusedId: "b")
    #expect(marks[0].tone == .quiet)
    #expect(marks[1].tone == .active)
    #expect(marks[1].length > marks[0].length)
}

@Test func aWorkingPanesMarkIsGreenAndWinsOverActive() {
    let marks = RailSpine.marks(
        panes: [pane("a", busy: true), pane("b", busy: true)], focusedId: "b")
    #expect(marks[0].tone == .working)
    // Working and active: the hue of working, the length of active.
    #expect(marks[1].tone == .working)
    #expect(marks[1].length == RailSpine.activeLength)
}

@Test func theMarksFollowThePanesAsTheyOpenAndClose() {
    var panes = [pane("a"), pane("b")]
    #expect(RailSpine.marks(panes: panes, focusedId: "a").count == 2)
    panes.removeLast()
    #expect(RailSpine.marks(panes: panes, focusedId: "a").map(\.id) == ["a"])
    #expect(RailSpine.marks(panes: [], focusedId: nil).isEmpty)
}

@Test func theSpineIsOneElementThatSaysWhatIsOpen() {
    let panes = [pane("t", "terminal"), pane("e", "editor"), pane("d", "db"), pane("a", "api")]
    #expect(RailSpine.label == "Open panes")
    #expect(RailSpine.value(panes: panes, focusedId: "e") == "4 panes, editor active")
    #expect(RailSpine.value(panes: panes, focusedId: nil) == "4 panes")
    #expect(RailSpine.value(panes: [pane("t")], focusedId: "t") == "1 pane, terminal active")
    #expect(RailSpine.value(panes: [], focusedId: nil) == "No panes")
    let working = [pane("t", busy: true), pane("e", "editor")]
    #expect(RailSpine.value(panes: working, focusedId: "e") == "2 panes, editor active, 1 working")
}

@Test func thePeekTimesAreTheApprovedOnes() {
    #expect(RailSpine.peekDelay == .milliseconds(150))
    #expect(RailSpine.leaveDelay == .milliseconds(300))
    #expect(RailSpine.edgeZone == 6)
}

// MARK: - The action

private func makeRegistry(_ layout: LayoutStore) async -> (ActionRegistry, URL) {
    let directory = testScratchRoot.appendingPathComponent("rail-\(UUID().uuidString)", isDirectory: true)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerLayoutActions(into: registry, layout: layout)
    return (registry, directory)
}

@Test func railSetPutsTheRailAwayAndBringsItBack() async throws {
    let layout = LayoutStore()
    let (registry, directory) = await makeRegistry(layout)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await layout.reading().railCollapsed == false)  // starts shown

    for (value, changed) in [(true, true), (true, false), (false, true)] {
        let result = try await registry.dispatch(
            name: "rail_set", params: .object(["collapsed": .bool(value)]),
            origin: .agent, caller: .test("dev"), confirmation: nil)
        #expect(await layout.reading().railCollapsed == value)
        #expect(result == .object(["collapsed": .bool(value), "changed": .bool(changed)]))
    }
}

@Test func railSetIsAControlTheAgentMayCallAndNeedsItsParam() async throws {
    let layout = LayoutStore()
    let (registry, directory) = await makeRegistry(layout)
    defer { try? FileManager.default.removeItem(at: directory) }
    let action = try #require(await registry.all().first { $0.name == "rail_set" })
    #expect(action.kind == .control)
    #expect(action.audience == .agentReachable)
    await #expect(throws: LayoutActionError.self) {
        _ = try await registry.dispatch(
            name: "rail_set", params: .object([:]), origin: .agent, caller: .test("dev"),
            confirmation: nil)
    }
}

// MARK: - The window

@Test @MainActor func toggleRailFlipsItThroughTheRegistryAndRemembersIt() async throws {
    let directory = testScratchRoot.appendingPathComponent("rail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = LayoutPersistence(directory: directory)
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, persistence: persistence)
    #expect(model.railCollapsed == false)

    await model.toggleRail()
    #expect(model.railCollapsed == true)
    try await eventually { [persistence] in persistence.loadWindowState().railCollapsed }

    await model.toggleRail()
    #expect(model.railCollapsed == false)
    try await eventually { [persistence] in !persistence.loadWindowState().railCollapsed }
}

@Test @MainActor func aWindowOpensOnWhatTheLastOneLeft() throws {
    let directory = testScratchRoot.appendingPathComponent("rail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = LayoutPersistence(directory: directory)
    #expect(persistence.loadWindowState() == WindowState(railCollapsed: false))  // nothing written yet
    try persistence.saveWindowState(WindowState(railCollapsed: true))
    #expect(persistence.loadWindowState().railCollapsed == true)
    #expect(WindowModel.forTesting(scratchRoot: testScratchRoot, persistence: persistence).railCollapsed == true)
}

@Test func anUnreadableWindowFileIsTheDefault() throws {
    let directory = testScratchRoot.appendingPathComponent("rail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("window.json"))
    #expect(LayoutPersistence(directory: directory).loadWindowState().railCollapsed == false)
}

/// Polls for a write that lands off the main actor.
private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition())
}

// MARK: - The spine's treatment

@Test func theSpinesQuietMarksAreBrighterThanTheFarPlaneAndItsHuedMarksBrighterStill() {
    let rest = RailTreatment.spineOpacity(working: false, active: false, isMaximized: false)
    #expect(rest == 0.6)
    #expect(rest > Plane.far.opacity)
    #expect(RailTreatment.spineOpacity(working: false, active: true, isMaximized: false) > rest)
    #expect(RailTreatment.spineOpacity(working: true, active: true, isMaximized: false) == 1)
}

@Test func theSpineFollowsTheRailsMaximizeFade() {
    for (working, active) in [(false, false), (false, true), (true, false), (true, true)] {
        #expect(
            RailTreatment.spineOpacity(working: working, active: active, isMaximized: true)
                == RailTreatment.deferredOpacity)
    }
}
