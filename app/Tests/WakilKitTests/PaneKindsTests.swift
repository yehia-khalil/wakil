import Foundation
import Testing
@testable import WakilKit

/// The kinds list's rules (pluggable pane kinds): every kind is listed once, no two kinds serve the
/// same name, every layout kind has a kind and every kind's name is a layout kind, and every kind's
/// empty pane answers `read_pane`.

/// Written as loops: the Swift 6 compiler in use crashes in SILGen on `flatMap`/`map` over `[any PaneKind.Type]`.
private func servedNames() -> [String] {
    var names: [String] = []
    for kind in PaneKinds.standard { names.append(contentsOf: kind.names) }
    return names
}

@Test func everyKindIsListedOnceAndNamesAreUnique() {
    var ids: [ObjectIdentifier] = []
    for kind in PaneKinds.standard { ids.append(ObjectIdentifier(kind)) }
    #expect(Set(ids).count == ids.count)
    let names = servedNames()
    #expect(Set(names).count == names.count, "two kinds serve the same name: \(names)")
}

@Test func everyLayoutKindIsServed() {
    for kind in Pane.kinds { #expect(PaneKinds.kind(named: kind) != nil, "\(kind) has no PaneKind") }
}

@Test func everyKindsNamesAreLayoutKinds() {
    for name in servedNames() {
        #expect(Pane.kinds.contains(name), "\(name) is served by a PaneKind but unknown to Layout")
    }
}

@Test func everyKindsEmptyPaneAnswersReadPane() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    for kind in servedNames() {
        guard case .object(let fields) = await store.readPane(paneId: "empty-\(kind)", kind: kind) else {
            Issue.record("\(kind): read_pane is not an object"); continue
        }
        #expect(fields["kind"] == .string(kind))
        #expect(fields["failure"] == .null, "\(kind): \(String(describing: fields["failure"]))")
    }
}
