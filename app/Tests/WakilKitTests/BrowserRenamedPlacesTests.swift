import Testing
@testable import WakilKit

private let canvas = LayoutScope(organization: "initech", project: "p", environment: "e")
private let other = LayoutScope(organization: "initech", project: "q", environment: "e")
private let third = LayoutScope(organization: "initech", project: "r", environment: "e")

@Test func aPaneDrawnUnderTheOldNameIsIgnoredUntilTheNewNameIsDrawn() {
    let renamed = BrowserRenamedPlaces.rehome([:], from: canvas, to: other)
    #expect(BrowserRenamedPlaces.drawn(canvas, renamed: renamed).isOldName)
}

@Test func drawingTheNewNameEndsTheOldName() {
    let renamed = BrowserRenamedPlaces.rehome([:], from: canvas, to: other)
    let drawn = BrowserRenamedPlaces.drawn(other, renamed: renamed)
    #expect(!drawn.isOldName)
    #expect(drawn.renamed.isEmpty)
    // The conversation-less canvas drawn again later is a place on screen like any other.
    #expect(!BrowserRenamedPlaces.drawn(canvas, renamed: drawn.renamed).isOldName)
}

@Test func aNameRenamedBackIsNoOldName() {
    let once = BrowserRenamedPlaces.rehome([:], from: canvas, to: other)
    let back = BrowserRenamedPlaces.rehome(once, from: other, to: canvas)
    // Only the name it left is old now; the one it came back to is not.
    #expect(back == [other: canvas])
    #expect(!BrowserRenamedPlaces.drawn(canvas, renamed: back).isOldName)
}

@Test func aChainOfNamesLeadsToTheNewest() {
    let once = BrowserRenamedPlaces.rehome([:], from: canvas, to: other)
    let twice = BrowserRenamedPlaces.rehome(once, from: other, to: third)
    #expect(twice == [canvas: third, other: third])
    #expect(BrowserRenamedPlaces.drawn(third, renamed: twice).renamed.isEmpty)
}

@Test func anUnrelatedPlaceIsNeverAnOldName() {
    let renamed = BrowserRenamedPlaces.rehome([:], from: canvas, to: other)
    let drawn = BrowserRenamedPlaces.drawn(third, renamed: renamed)
    #expect(!drawn.isOldName)
    #expect(drawn.renamed == renamed)
}
