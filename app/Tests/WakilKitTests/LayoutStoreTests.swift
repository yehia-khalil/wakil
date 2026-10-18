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

@Test func resizingPastASnappedNeighbourFloorsItRatherThanGoingToZero() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 100, y: 100)
    try await store.resize(id: a.id, width: 200, height: 300)
    let b = await store.open(kind: "db", title: "B")
    try await store.snap(id: b.id, to: a.id, edge: .left)
    // b now sits at x = 300, width 640 (its opened default).

    // Widening a by far more than b's own width would, unclamped, push
    // b's width negative — the defect this test guards against: a
    // resize dragging a snapped neighbour to zero or below, which the
    // view's own clamp (on the pane under the pointer) cannot prevent
    // because it never touches the neighbour at all.
    try await store.resize(id: a.id, width: 1000, height: 300)

    let snapshot = await store.snapshot()
    let neighbour = try #require(snapshot.panes.first { $0.id == b.id })
    #expect(neighbour.frame.width == Pane.minimumWidth)
    #expect(neighbour.frame.width > 0)

    // The named pane itself is never clamped — it took exactly the
    // rectangle the caller asked for.
    let named = try #require(snapshot.panes.first { $0.id == a.id })
    #expect(named.frame.width == 1000)
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

@Test func maximizingAnAlreadyMaximizedPaneIsANoOp() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "A")
    try await store.move(id: a.id, x: 120, y: 140)
    let before = try #require(await store.snapshot().panes.first).frame

    try await store.maximize(id: a.id)
    // A second maximize of the same, already-maximized pane must not
    // overwrite the held-back frame with the void it is currently showing.
    try await store.maximize(id: a.id)

    await store.restore()
    let snapshot = await store.snapshot()
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
    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))
    let a = await store.open(kind: "db", title: "Alpha pane")
    try await store.move(id: a.id, x: 321, y: 123)

    await store.switchScope(to: LayoutScope(organization: "acme", project: "beta", environment: "dev"))
    #expect(await store.snapshot().panes.isEmpty)
    let b = await store.open(kind: "db", title: "Beta pane")
    #expect(await store.snapshot().panes.map(\.id) == [b.id])

    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))
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
    await store.switchScope(to: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))
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
    await store.load(restored, for: LayoutScope(organization: "acme", project: "alpha", environment: "dev"))

    #expect(await store.snapshot() == restored)
}

/// Maximizing replaces a pane's frame with the whole canvas, so the frame
/// it had before is the only record of where it actually lives. That record
/// has to be *in the snapshot* — a saved layout carrying `maximizedId`
/// without it reopens with the pane filling the canvas and `restore()`
/// unable to put it anywhere, which flattens the operator's whole
/// arrangement to one pane's worth with nothing to say so.
@Test func aReloadedMaximizedLayoutStillRestoresToItsOriginalFrame() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("layout-maximize-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = LayoutPersistence(directory: directory)

    let store = LayoutStore()
    await store.switchScope(to: LayoutScope(organization: "acme", project: "widgets", environment: "dev"))
    let pane = await store.open(kind: "db", title: "Results")
    try await store.move(id: pane.id, x: 120, y: 90)
    let original = try #require(await store.snapshot().panes.first).frame
    try await store.maximize(id: pane.id)
    try persistence.save(await store.snapshot(), for: LayoutScope(organization: "acme", project: "widgets", environment: "dev"))

    // A fresh session: a new store, told nothing but what was on disk.
    let relaunched = LayoutStore()
    await relaunched.switchScope(to: LayoutScope(organization: "acme", project: "widgets", environment: "dev"))
    let saved = try #require(persistence.load(for: LayoutScope(organization: "acme", project: "widgets", environment: "dev")).snapshot)
    await relaunched.load(saved, for: LayoutScope(organization: "acme", project: "widgets", environment: "dev"))
    #expect(await relaunched.snapshot().maximizedId == pane.id)

    await relaunched.restore()

    #expect(await relaunched.snapshot().maximizedId == nil)
    #expect(await relaunched.snapshot().panes.first?.frame == original)
}

/// `busy` is set and cleared around every dispatch, so two snapshots
/// differing only in it describe the same canvas. `WindowModel` gates its
/// layout write on this rather than on `==`; without it, one pane's
/// dispatch observing another mid-flight would count as an arrangement
/// change and rewrite the file.
@Test func snapshotsDifferingOnlyInBusyAreTheSameArrangement() async {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "Results")
    let idle = await store.snapshot()
    await store.setBusy(true, id: pane.id)
    let working = await store.snapshot()

    #expect(idle != working)
    #expect(idle.withoutTransientState == working.withoutTransientState)
}

/// The bug the first hands-on run found: the snap line previewed one
/// landing and the release produced another.
///
/// `candidate(forDragging:to:)` builds its proposed frame from the origin
/// the pointer is at, so the preview is drawn for the *dragged* position.
/// `snap` flushed from `panes[index].frame` — the pane's *stored* frame,
/// which a drag never touches, because the offset lives in the view's
/// `@State` until release. The two therefore disagreed by exactly the drag
/// translation, and a pane released against the left edge snapped to that
/// edge while jumping back to the vertical position it started from.
///
/// The invariant this pins is the one a user actually experiences: **where
/// the preview says the pane will land is where it lands.**
@Test func snappingLandsThePaneWhereThePreviewSaidItWould() async throws {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "one")

    // Drag it against the void's left edge, well away from where it opened.
    let released = (x: 3.0, y: 300.0)
    let candidate = try #require(await store.candidate(forDragging: pane.id, to: released))
    #expect(candidate.toPaneId == nil)
    #expect(candidate.edge == .left)

    try await store.snap(id: pane.id, to: candidate.toPaneId, edge: candidate.edge, from: released)

    let landed = try #require(await store.snapshot().panes.first { $0.id == pane.id })
    #expect(landed.frame == candidate.frame)
}

/// The same invariant for a pane-to-pane snap, where `flush` also matches
/// the neighbour's extent — so only the along-edge axis can drift, and it
/// drifted by the drag distance.
@Test func snappingToANeighbourAlsoLandsWhereThePreviewSaid() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "db", title: "a")
    try await store.move(id: a.id, x: 0, y: 0)
    let b = await store.open(kind: "db", title: "b")

    // Release b's left edge just past a's right edge (a is 640 wide at x 0).
    let released = (x: 643.0, y: 200.0)
    let candidate = try #require(await store.candidate(forDragging: b.id, to: released))
    #expect(candidate.toPaneId == a.id)

    try await store.snap(id: b.id, to: candidate.toPaneId, edge: candidate.edge, from: released)

    let landed = try #require(await store.snapshot().panes.first { $0.id == b.id })
    #expect(landed.frame == candidate.frame)
}

/// The void the solver measures against must be the canvas the operator
/// can actually see.
///
/// `setVoid` shipped in 2b-i with no caller: the window never told the
/// store how big it was, so every canvas-edge snap was computed against a
/// fixed 1440×900 while the real canvas was a fraction of that. The right
/// and bottom edges therefore sat outside the window — a pane could be
/// snapped to them by a `--dispatch` script and by nothing a pointer could
/// do. This pins that a reported size actually reaches the solver.
@Test func theVoidTheSolverUsesFollowsTheReportedCanvasSize() async throws {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "one")
    try await store.resize(id: pane.id, width: 200, height: 100)

    // The default void is 1440×900, so a pane released with its right edge
    // near x=700 is nowhere near the default right edge.
    let released = (x: 500.0, y: 300.0)
    #expect(await store.candidate(forDragging: pane.id, to: released) == nil)

    // Tell the store the canvas is 700×400 and the same release is flush
    // against its right edge.
    await store.setVoid(PaneFrame(x: 0, y: 0, width: 700, height: 400))
    let candidate = try #require(await store.candidate(forDragging: pane.id, to: released))
    #expect(candidate.edge == .right)
    #expect(candidate.toPaneId == nil)
    #expect(candidate.frame.maxX == 700)
}

/// A pane cannot be moved so far that nothing of it is left to grab.
///
/// The canvas clips, so a pane pushed past an edge vanishes; and a pane
/// with nothing on screen has nothing to press, so the pointer can never
/// bring it back. The first hands-on run of 2b-i lost two panes exactly
/// this way — the rail still listed them, and clicking a row only raised
/// the z-order of something invisible.
@Test func aPaneCannotBeMovedEntirelyOutsideTheCanvas() async throws {
    let store = LayoutStore()
    await store.setVoid(PaneFrame(x: 0, y: 0, width: 700, height: 400))
    let pane = await store.open(kind: "db", title: "one")
    try await store.resize(id: pane.id, width: 200, height: 100)

    // Far past the right and bottom edges.
    try await store.move(id: pane.id, x: 5000, y: 5000)
    var frame = try #require(await store.snapshot().panes.first).frame
    #expect(frame.x == 700 - Pane.minimumWidth)
    #expect(frame.y == 400 - Pane.minimumHeight)

    // Far past the left and top edges: the pane may hang off, but a
    // grabbable slice stays on.
    try await store.move(id: pane.id, x: -5000, y: -5000)
    frame = try #require(await store.snapshot().panes.first).frame
    #expect(frame.maxX == Pane.minimumWidth)
    #expect(frame.maxY == Pane.minimumHeight)

    // An ordinary move well inside is untouched.
    try await store.move(id: pane.id, x: 100, y: 50)
    frame = try #require(await store.snapshot().panes.first).frame
    #expect(frame.x == 100)
    #expect(frame.y == 50)
}

/// Focusing recovers a pane that is outside the canvas without `move`
/// having put it there — a layout saved on a large canvas and restored on
/// a small one. This is what makes the rail's documented job of finding an
/// off-edge pane actually true.
@Test func focusingAnOffCanvasPaneBringsItBackIntoView() async throws {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "one")
    try await store.move(id: pane.id, x: 1000, y: 600)

    // The window shrinks under it — nothing moved the pane, the canvas
    // moved out from under it.
    await store.setVoid(PaneFrame(x: 0, y: 0, width: 700, height: 400))
    #expect(try #require(await store.snapshot().panes.first).frame.x == 1000)

    try await store.focus(id: pane.id)

    let frame = try #require(await store.snapshot().panes.first).frame
    #expect(frame.x == 700 - Pane.minimumWidth)
    #expect(frame.y == 400 - Pane.minimumHeight)
    #expect(await store.snapshot().focusedId == pane.id)
}

@Test func aPanesSubjectIsRecordedAndReadBack() async {
    let store = LayoutStore()
    let pane = await store.open(kind: "db", title: "main")
    let fetch = PaneFetch(query: .table(database: "main", name: "events"), offset: 500)
    await store.setFetch(fetch, id: pane.id)
    #expect(await store.fetch(id: pane.id) == fetch)
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.first?.fetch == fetch)
}

@Test func recordingASubjectOnAPaneThatIsGoneIsSilent() async {
    let store = LayoutStore()
    await store.setFetch(PaneFetch(query: .tables(database: nil)), id: "db-99")
    #expect(await store.fetch(id: "db-99") == nil)
}

/// A restored terminal pane has no shell, and that is a coherent state
/// (Task 14). The pane persists across a save/load cycle; the shell and
/// its block history do not, because respawning at the saved path would
/// spawn a process as a side effect of reading a file — which no other
/// pane kind does and no operator asked for. There is deliberately no
/// action that reaches this path: loading a layout dispatches nothing.
@Test func aRestoredTerminalPaneComesBackEmptyAndAwaitsAShell() async {
    let layout = LayoutStore()
    _ = await layout.open(kind: "terminal", title: "~/orca")
    let saved = await layout.snapshot()

    let restored = LayoutStore()
    await restored.load(saved, for: .initial)

    let pane = await restored.snapshot().panes.first
    #expect(pane?.kind == "terminal")
    // Nothing spawned, because loading a layout dispatches nothing.
    let terminals = TerminalStore(scratchRoot: testScratchRoot)
    #expect(!(await terminals.isRunning(paneId: pane!.id)))
}

/// Walk-defects B2: `open`'s `terminalPath` is `Pane.terminalPath`
/// verbatim, and it survives the exact save/load cycle the pane above
/// does — the fact a dead pane's Reopen control (`TerminalPane.swift`)
/// needs, restored the same way `title` already was even though `title`
/// alone is a NAME, not the path itself.
@Test func aTerminalPanesPathIsRecordedAndSurvivesASaveLoadCycle() async {
    let layout = LayoutStore()
    let pane = await layout.open(kind: "terminal", title: "orca", terminalPath: "/Users/x/orca")
    #expect(pane.terminalPath == "/Users/x/orca")
    let saved = await layout.snapshot()

    let restored = LayoutStore()
    await restored.load(saved, for: .initial)
    #expect(await restored.snapshot().panes.first?.terminalPath == "/Users/x/orca")
}

/// `setTerminalPath` is `retitle`'s own analogue: `term_open` naming an
/// existing pane at a new path must update what the pane remembers, not
/// just what it is called.
@Test func setTerminalPathUpdatesAnExistingPanesRememberedPath() async {
    let store = LayoutStore()
    let pane = await store.open(kind: "terminal", title: "orca", terminalPath: "/Users/x/orca")
    await store.setTerminalPath(id: pane.id, to: "/Users/x/elsewhere")
    #expect(await store.snapshot().panes.first?.terminalPath == "/Users/x/elsewhere")
}

@Test func settingATerminalPathOnAPaneThatIsGoneIsSilent() async {
    let store = LayoutStore()
    await store.setTerminalPath(id: "terminal-99", to: "/tmp")
    #expect(await store.snapshot().panes.isEmpty)
}

/// The hazard `clearAllScopes` used to exist to paper over: both stores
/// keyed on a project NAME alone while `LayoutPersistence` keyed on
/// `(org, project)`, so two organisations each holding a project called
/// `core` — unremarkable — collided in memory and drew the first org's
/// arrangement under the second org's name, with nothing failing. The
/// scope carries the organisation, so the collision is impossible rather
/// than merely cleared up after.
@Test func twoOrganisationsHoldingASameNamedProjectKeepSeparateArrangements() async throws {
    let store = LayoutStore()
    await store.switchScope(to: LayoutScope(organization: "acme", project: "core", environment: "dev"))
    let acme = await store.open(kind: "db", title: "Acme's pane")
    try await store.move(id: acme.id, x: 321, y: 123)

    await store.switchScope(to: LayoutScope(organization: "globex", project: "core", environment: "dev"))
    #expect(await store.snapshot().panes.isEmpty)
    _ = await store.open(kind: "db", title: "Globex's pane")

    await store.switchScope(to: LayoutScope(organization: "acme", project: "core", environment: "dev"))
    let snapshot = await store.snapshot()
    #expect(snapshot.panes.map(\.title) == ["Acme's pane"])
    #expect(snapshot.panes[0].frame.x == 321)
}

// MARK: - Re-walk finding #4: a conversation minted over the canvas adopts it

@Test("#4: only the project's own canvas moves into a conversation minted over it")
func onlyTheProjectsCanvasIsAdopted() {
    let seed = LayoutScope(organization: "acme", project: "widgets", environment: "dev")
    let minted = LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "new")
    #expect(conversationAdoptsCanvas(from: seed, to: minted))
    #expect(!conversationAdoptsCanvas(
        from: LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "old"), to: minted))
    #expect(!conversationAdoptsCanvas(from: LayoutScope(organization: "acme", project: "gadgets", environment: "dev"), to: minted))
    #expect(!conversationAdoptsCanvas(from: LayoutScope(organization: "other", project: "widgets", environment: "dev"), to: minted))
    #expect(!conversationAdoptsCanvas(from: seed, to: seed))
}

@Test("#4: adopting moves the arrangement and the contents, and leaves the old scope empty")
func adoptingMovesBothStores() async {
    let seed = LayoutScope(organization: "acme", project: "widgets", environment: "dev")
    let minted = LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "new")
    let layout = LayoutStore()
    let panes = PaneStore()
    await layout.switchScope(to: seed)
    await panes.switchScope(to: seed)
    let id = await layout.open(kind: "api", title: "catalog").id
    await panes.openApi(paneId: id, entry: "catalog", environment: "staging",
                        origin: "https://c.example", credentialed: false, entries: ["catalog"])

    let mark = await panes.apiResolutionMark()
    await layout.switchScope(to: minted, adoptingFrom: seed)
    await panes.switchScope(to: minted, adoptingFrom: seed)
    // The same panes under a new key: a list_apis in flight still describes them.
    #expect(await panes.apiResolutionMark() == mark)
    #expect(await layout.snapshot().panes.map(\.id) == [id])
    #expect(await panes.apiSnapshot(paneId: id).entry == "catalog")

    await layout.switchScope(to: seed)
    await panes.switchScope(to: seed)
    #expect(await layout.snapshot().panes.isEmpty)
    #expect(await panes.apiSnapshot(paneId: id).entry == "")
}

@Test func anEditorColumnIsSavedPerPaneAndBecomesTheDefaultWithoutItsOpenFolders() async throws {
    let store = LayoutStore()
    let a = await store.open(kind: "editor", title: "Editor").id
    let b = await store.open(kind: "editor", title: "Editor").id
    #expect(await store.editorColumnDefault() == .initial)
    let col = EditorColumnState(shown: true, view: .search, width: 300, open: ["/p/api"])
    await store.setEditorColumn(id: a, to: col)
    #expect(await store.editorColumn(id: a) == col)
    #expect(await store.editorColumn(id: b) == nil)
    #expect(await store.editorColumnDefault() == EditorColumnState(shown: true, view: .search, width: 300, open: []))
    let data = try JSONEncoder().encode(await store.snapshot())
    let back = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
    #expect(back.panes.first { $0.id == a }?.editorColumn == col)
    #expect(back.editorColumnDefault?.width == 300)
}
