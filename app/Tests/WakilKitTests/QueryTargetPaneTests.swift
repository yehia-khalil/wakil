import Testing

@testable import WakilKit

private func snapshotWith(panes: [Pane], focused: String?) -> LayoutSnapshot {
    var snapshot = LayoutSnapshot()
    snapshot.panes = panes
    snapshot.focusedId = focused
    return snapshot
}

private func pane(_ id: String, kind: String = "db") -> Pane {
    Pane(id: id, kind: kind, title: id,
         frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
}

@Test func namingAPaneTargetsThatPane() {
    let layout = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: "db-1", layout: layout) == "db-1")
}

@Test func namingNoPaneTargetsNoPane() {
    // The inversion. Before 2c-ii this returned the focused db pane, so a
    // second question replaced the first one's rows AND its subject. Now
    // it returns nil and the caller opens a pane.
    let layout = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: nil, layout: layout) == nil)
}

@Test func anEmptyPaneStringIsTheSameAsNamingNone() {
    let layout = snapshotWith(panes: [pane("db-1")], focused: "db-1")
    #expect(queryTargetPane(explicit: "", layout: layout) == nil)
}

@Test func namingAPaneWorksWithNoLayoutAtAll() {
    // --dispatch and every test that predates a layout. An explicit id
    // does not depend on focus, so there is nothing to consult.
    #expect(queryTargetPane(explicit: "db-7", layout: nil) == "db-7")
    #expect(queryTargetPane(explicit: nil, layout: nil) == nil)
}

@Test func focusNoLongerDecidesAnything() {
    // Which dissolves 2c-i's acceptance check 11 rather than answering
    // it: a query with an explicit pane targets that pane whether or not
    // focus moved, and a query without one opens a pane that did not
    // exist when the query was sent. There is nothing left for a refocus
    // to race.
    let a = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-1")
    let b = snapshotWith(panes: [pane("db-1"), pane("db-2")], focused: "db-2")
    #expect(queryTargetPane(explicit: nil, layout: a) == queryTargetPane(explicit: nil, layout: b))
    #expect(queryTargetPane(explicit: "db-1", layout: a) == queryTargetPane(explicit: "db-1", layout: b))
}
