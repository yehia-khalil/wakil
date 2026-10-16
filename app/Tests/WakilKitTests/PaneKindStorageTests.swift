import Foundation
import Testing
@testable import WakilKit

/// What the slot storage must keep doing exactly as the per-kind enum did (pluggable pane kinds, PR 2).

@Test func aPaneHoldingOneKindRefusesAnother() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.setGit(paneId: "p", .empty)
    await store.setTerminalProposal(paneId: "p", nil)
    await store.setRows(
        paneId: "p", columns: ["a"], columnTypes: ["text"], columnTypesInferred: false,
        rows: [[.string("x")]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    #expect(await store.snapshot(paneId: "p", kind: "git").git == .empty)
    #expect(await store.snapshot(paneId: "p", kind: "git").dataSurface == nil)
}

@Test func aNeverWrittenPaneAnswersItsKindsEmptySnapshot() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let git = await store.snapshot(paneId: "g", kind: "git")
    #expect(git.git == .empty && git.failure == nil)
    let settings = await store.snapshot(paneId: "s", kind: Pane.settingsKind)
    #expect(settings.contents == nil && settings.failure == nil)
    let unknown = await store.snapshot(paneId: "u", kind: "nope")
    #expect(unknown.contents == nil)
    #expect(unknown.failure == "this build has no contents for a pane of kind \"nope\"")
    let none = await store.snapshot(paneId: "n", kind: nil)
    #expect(none.kind == nil && none.contents == nil && none.failure == nil)
}

@Test func switchingScopeBumpsTheResolutionMarkBeforeAnyWrite() async {
    let store = PaneStore()
    let before = await store.apiResolutionMark()
    await store.switchScope(to: LayoutScope(organization: "acme", project: "widgets"))
    #expect(await store.apiResolutionMark() != before)
}

@Test func clearingAllScopesBumpsTheMarkAndKeepsFlightSubscribers() async {
    let store = PaneStore()
    let flights = await store.apiFlights()
    _ = flights
    let before = await store.apiResolutionMark()
    await store.clearAllScopes()
    #expect(await store.apiResolutionMark() != before)
    #expect(await store.apiFlightSubscriberCount == 1)
}

@Test func adoptingAScopeCarriesItsPanesWithoutBumpingTheMark() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let seed = LayoutScope(organization: "acme", project: "widgets")
    let conversation = LayoutScope(organization: "acme", project: "widgets", lineageRoot: "r")
    await store.switchScope(to: seed)
    await store.setGit(paneId: "g", .empty)
    let mark = await store.apiResolutionMark()
    await store.switchScope(to: conversation, adoptingFrom: seed)
    #expect(await store.holdsContents(paneId: "g"))
    #expect(await store.apiResolutionMark() == mark)
}
