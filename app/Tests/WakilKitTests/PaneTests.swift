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

@Test func aNewPaneIsAiry() {
    let pane = Pane(
        id: "db-1", kind: "db", title: "t",
        frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    #expect(pane.density == .airy)
}

@Test func densityCarriesSection8sRowHeights() {
    #expect(PaneDensity.airy.rowHeight == 40)
    #expect(PaneDensity.dense.rowHeight == 23)
    #expect(PaneDensity.airy.toggled == .dense)
    #expect(PaneDensity.dense.toggled == .airy)
}

/// §8: "remembered per pane". Unlike `busy`, density is a setting rather
/// than runtime state, so it *is* in `CodingKeys` and does survive a quit.
@Test func densitySurvivesAJSONRoundTrip() throws {
    var pane = Pane(
        id: "db-1", kind: "db", title: "t",
        frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))
    pane.density = .dense
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data).density == .dense)
}

/// A layout written before this field existed must still open. Failing to
/// decode would take the whole arrangement down for a row height.
@Test func aPaneSavedBeforeDensityExistedDecodesAsAiry() throws {
    let json = Data("""
    {"id":"db-1","kind":"db","title":"t","frame":{"x":0,"y":0,"width":1,"height":1}}
    """.utf8)
    #expect(try JSONDecoder().decode(Pane.self, from: json).density == .airy)
}

@Test func columnWidthsSurviveAJSONRoundTrip() throws {
    var pane = Pane(
        id: "db-1", kind: "db", title: "Query results",
        frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))
    pane.columnWidths = ["id": 60, "name": 240]
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data).columnWidths == pane.columnWidths)
}

@Test func aLayoutWrittenBeforeColumnWidthsExistedStillDecodes() throws {
    // The same tolerance `density` needed: a field added after some layout
    // was last saved must decode with its default rather than taking the
    // whole file down. This is why Pane has a hand-written init(from:) at
    // all — a synthesized decoder treats a listed non-optional key as
    // required.
    let json = """
        {"id":"db-1","kind":"db","title":"T","frame":{"x":1,"y":2,"width":3,"height":4}}
        """
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.columnWidths.isEmpty)
    #expect(pane.density == .airy)
}

@Test func aPaneCarriesItsSubjectThroughAFileRoundTrip() throws {
    var pane = Pane(id: "db-1", kind: "db", title: "main",
                    frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    pane.fetch = PaneFetch(
        query: .sql(database: "main", raw: "SELECT * FROM events"),
        offset: 500, pageSize: 500,
        sort: [PaneSort(column: "id", direction: .descending)])
    let data = try JSONEncoder().encode(pane)
    let back = try JSONDecoder().decode(Pane.self, from: data)
    #expect(back.fetch == pane.fetch)
}

/// D5: a layout saved before the sort became a list holds one sort object
/// where an array now lives. Decoding it must not lose the pane's subject
/// — silently dropping to an unsorted, but otherwise intact, fetch is the
/// tolerant answer; the alternative is the whole pane failing to decode
/// and the operator losing it at the first relaunch after the upgrade.
@Test func aFetchWrittenBeforeSortWasAListStillDecodesItsSingleTerm() throws {
    let json = """
        {"query":{"table":{"database":"main","name":"events"}},"offset":0,\
        "pageSize":500,"sort":{"column":"id","direction":"desc"}}
        """
    let fetch = try JSONDecoder().decode(PaneFetch.self, from: Data(json.utf8))
    #expect(fetch.sort == [PaneSort(column: "id", direction: .descending)])
    #expect(fetch.query == .table(database: "main", name: "events"))
}

@Test func aLayoutWrittenBeforeSubjectsExistedStillDecodes() throws {
    // The same tolerance `density` and `columnWidths` each needed. A pane
    // saved by any build before 2c-ii has no "fetch" key at all.
    let json = #"""
    {"id":"db-1","kind":"db","title":"main",
     "frame":{"x":0,"y":0,"width":640,"height":420},"density":"dense"}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.fetch == nil)
    #expect(pane.density == .dense)
}

@Test func aSubjectThisBuildCannotReadCostsThePaneAndNotTheFile() throws {
    // A layout written by a later build, holding a subject case this one
    // does not have. The pane must come back subject-less and the file
    // must still load — a thrown error here takes down every pane in the
    // project over one pane's subject.
    let json = #"""
    {"id":"db-1","kind":"db","title":"main",
     "frame":{"x":0,"y":0,"width":640,"height":420},
     "fetch":{"query":{"graphql":{"document":"{ events }"}},"offset":0,"pageSize":500}}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.fetch == nil)
    #expect(pane.id == "db-1")
}

/// Walk-defects B2: `terminalPath` is a setting, like `density` and
/// `columnWidths`, not runtime state like `busy` — it must survive the
/// exact round trip a saved layout takes.
@Test func terminalPathSurvivesAJSONRoundTrip() throws {
    let pane = Pane(
        id: "terminal-1", kind: "terminal", title: "orca",
        frame: PaneFrame(x: 1, y: 2, width: 3, height: 4), terminalPath: "/Users/x/orca")
    let data = try JSONEncoder().encode(pane)
    #expect(try JSONDecoder().decode(Pane.self, from: data).terminalPath == "/Users/x/orca")
}

/// A layout written before this field existed has no `terminalPath` key
/// at all. The same tolerance `density`, `columnWidths` and `fetch` each
/// needed: decode to `nil` rather than take the pane, or the file, down.
@Test func aLayoutWrittenBeforeTerminalPathExistedStillDecodes() throws {
    let json = #"""
    {"id":"terminal-1","kind":"terminal","title":"orca",
     "frame":{"x":0,"y":0,"width":640,"height":420}}
    """#
    let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    #expect(pane.terminalPath == nil)
}

@Test func busyIsStillNotPersisted() throws {
    // Unchanged by this phase, and worth re-pinning beside the new field
    // so the distinction between a setting and runtime state stays live.
    var pane = Pane(id: "db-1", kind: "db", title: "main",
                    frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    pane.busy = true
    let data = try JSONEncoder().encode(pane)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("busy"))
}
