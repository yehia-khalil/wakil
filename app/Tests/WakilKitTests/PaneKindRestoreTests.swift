import Foundation
import Testing
@testable import WakilKit

@Test func aDbPaneRestoresByRefetchingOnlyWhenItHasAFetch() {
    let frame = PaneFrame(x: 0, y: 0, width: 1, height: 1)
    let bare = Pane(id: "d", kind: "db", title: "db", frame: frame)
    #expect(DataSurfacePaneKind.restoreStep(for: bare) == nil)
    let fetched = Pane(id: "d", kind: "db", title: "db", frame: frame,
                       fetch: PaneFetch(query: .sql(database: nil, raw: "select 1")))
    #expect(DataSurfacePaneKind.restoreStep(for: fetched)
        == PaneRestoreStep(action: "db_refetch", params: .object(["pane": .string("d")]), recordsFailure: true))
}

@Test func kindsWhoseSubjectIsNotARerunRestoreNothing() {
    #expect((TerminalPaneKind.self as Any.Type) as? PaneRestorable.Type == nil)
    #expect((ApiPaneKind.self as Any.Type) as? PaneRestorable.Type == nil)
}
