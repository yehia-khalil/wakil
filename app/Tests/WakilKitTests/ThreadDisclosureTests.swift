import Testing
@testable import WakilKit

private func rows(_ n: Int) -> [ThoughtRow] {
    (0..<n).map { ThoughtRow(id: $0, label: "tool", detail: "step \($0)", isError: false) }
}

@Test func showsTheLastFourAndCountsTheRest() {
    let d = ThreadDisclosure()
    let (shown, earlier) = d.visible(rows(7))
    #expect(shown.map(\.id) == [3, 4, 5, 6])
    #expect(earlier == 3)
}

@Test func fewerThanFourShowsThemAll() {
    let (shown, earlier) = ThreadDisclosure().visible(rows(2))
    #expect(shown.count == 2)
    #expect(earlier == 0)
}

@Test func showEarlierShowsEverythingAndPins() {
    var d = ThreadDisclosure()
    d.showEarlier()
    #expect(d.visible(rows(7)).rows.count == 7)
    #expect(d.pinned)
}

@Test func restsFadedAndHoverBringsItUp() {
    var d = ThreadDisclosure()
    #expect(d.opacity == 0.32)
    d.pointerEntered()
    #expect(d.opacity == 1)
}

@Test func anOpenRowKeepsItFullAfterThePointerLeaves() {
    var d = ThreadDisclosure()
    d.pointerEntered()
    d.toggle(5)
    d.pointerLeft(at: 10)
    #expect(d.opacity == 1)
    #expect(d.open == [5])
}

@Test func foldsAndFades1_2sAfterThePointerLeaves() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5); d.showEarlier()
    d.pointerLeft(at: 10)
    d.tick(at: 11.1, mouseHeld: false)
    #expect(d.pinned)
    d.tick(at: 11.2, mouseHeld: false)
    #expect(!d.pinned)
    #expect(d.opacity == 0.32)
}

@Test func comingBackInsideTheDebounceKeepsItOpen() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5)
    d.pointerLeft(at: 10)
    d.pointerEntered()
    d.tick(at: 20, mouseHeld: false)
    #expect(d.open == [5])
}

/// A drag-selection in progress is not a departure.
@Test func aHeldMouseButtonPostponesTheFold() {
    var d = ThreadDisclosure()
    d.pointerEntered(); d.toggle(5)
    d.pointerLeft(at: 10)
    d.tick(at: 12, mouseHeld: true)
    #expect(d.open == [5])
    d.tick(at: 12.1, mouseHeld: false)
    #expect(d.open.isEmpty)
}

@Test func escapeFoldsAtOnceAndReportsWhetherItDidAnything() {
    var d = ThreadDisclosure()
    let idle = d.escape()
    #expect(!idle)
    d.toggle(1)
    let folded = d.escape()
    #expect(folded)
    #expect(!d.pinned)
}

@Test func toggleClosesAnOpenRow() {
    var d = ThreadDisclosure()
    d.toggle(3); d.toggle(3)
    #expect(d.open.isEmpty)
}

@Test func foldPendingIsTrueOnlyBetweenDepartureAndFold() {
    var d = ThreadDisclosure()
    #expect(!d.foldPending)
    d.pointerEntered(); d.toggle(1)
    #expect(!d.foldPending)
    d.pointerLeft(at: 10)
    #expect(d.foldPending)
    d.pointerEntered()
    #expect(!d.foldPending)
    d.pointerLeft(at: 20)
    d.tick(at: 21.3, mouseHeld: false)
    #expect(!d.foldPending)
}
