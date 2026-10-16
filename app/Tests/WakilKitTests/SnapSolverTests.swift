import Testing
@testable import WakilKit

private let void = PaneFrame(x: 0, y: 0, width: 1000, height: 800)

@Test func noNeighbourAndNoVoidEdgeInRangeMeansNoCandidate() {
    let proposed = PaneFrame(x: 400, y: 400, width: 100, height: 100)
    #expect(snapCandidate(for: proposed, neighbours: [], void: void) == nil)
}

@Test func aPanesRightEdgeSnapsToANeighboursLeftEdge() {
    // Neighbour's left edge is at x = 500. The dragged pane's right edge
    // lands at 496 — 4pt short, inside the 8pt threshold.
    let neighbour = PaneFrame(x: 500, y: 100, width: 200, height: 300)
    let proposed = PaneFrame(x: 296, y: 100, width: 200, height: 300)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.edge == .right)
    #expect(candidate?.toPaneId == "db-2")
    // Flush: the dragged pane's right edge now sits exactly on 500.
    #expect(candidate?.frame.maxX == 500)
    // And the extent along the shared edge is matched — a horizontal edge
    // matches height.
    #expect(candidate?.frame.minY == 100)
    #expect(candidate?.frame.height == 300)
}

@Test func aPanesBottomEdgeSnapsToANeighboursTopEdge() {
    let neighbour = PaneFrame(x: 100, y: 500, width: 300, height: 200)
    let proposed = PaneFrame(x: 100, y: 205, width: 300, height: 290)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.edge == .bottom)
    #expect(candidate?.toPaneId == "db-2")
    #expect(candidate?.frame.maxY == 500)
    // A vertical edge matches width.
    #expect(candidate?.frame.minX == 100)
    #expect(candidate?.frame.width == 300)
}

@Test func aPaneSnapsToTheVoidEdgeWhenNoNeighbourIsNearer() {
    // Left edge 5pt from the void's own left edge.
    let proposed = PaneFrame(x: 5, y: 300, width: 200, height: 100)
    let candidate = snapCandidate(for: proposed, neighbours: [], void: void)
    #expect(candidate?.edge == .left)
    #expect(candidate?.toPaneId == nil)
    #expect(candidate?.frame.minX == 0)
    // Snapping to the void does not resize: there is no neighbour whose
    // extent to match.
    #expect(candidate?.frame.width == 200)
    #expect(candidate?.frame.height == 100)
}

@Test func exactlyAtTheThresholdSnapsAndBeyondItDoesNot() {
    let atThreshold = PaneFrame(x: 8, y: 300, width: 200, height: 100)
    #expect(snapCandidate(for: atThreshold, neighbours: [], void: void)?.edge == .left)

    let beyond = PaneFrame(x: 8.01, y: 300, width: 200, height: 100)
    #expect(snapCandidate(for: beyond, neighbours: [], void: void) == nil)
}

@Test func theNearestCandidateWins() {
    // Void left edge is 7pt away; the neighbour's right edge is 2pt away.
    let neighbour = PaneFrame(x: 0, y: 300, width: 5, height: 100)
    let proposed = PaneFrame(x: 7, y: 300, width: 200, height: 100)
    let candidate = snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void)
    #expect(candidate?.toPaneId == "db-2")
    #expect(candidate?.edge == .left)
    #expect(candidate?.frame.minX == 5)
}

@Test func aNeighbourThatDoesNotOverlapAlongTheSharedEdgeIsNotACandidate() {
    // The neighbour's left edge is 4pt away in x, but it sits far below:
    // there is no shared edge to snap along, so this must not snap.
    let neighbour = PaneFrame(x: 500, y: 700, width: 200, height: 90)
    let proposed = PaneFrame(x: 296, y: 100, width: 200, height: 300)
    #expect(snapCandidate(for: proposed, neighbours: [("db-2", neighbour)], void: void) == nil)
}

@Test func aPaneNeverSnapsToItselfBecauseItIsNotInNeighbours() {
    // Documents the contract: the caller excludes the dragged pane. Given
    // an empty neighbour list, an otherwise perfect self-overlap yields
    // only the void answer, or none.
    let proposed = PaneFrame(x: 400, y: 400, width: 100, height: 100)
    #expect(snapCandidate(for: proposed, neighbours: [], void: void) == nil)
}
