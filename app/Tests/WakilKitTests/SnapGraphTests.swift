import Foundation
import Testing
@testable import WakilKit

@Test func aLinkIsVisibleFromBothSides() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    #expect(graph.neighbours(of: "a", along: .right) == ["b"])
    // Undirected: b's left is linked to a, without a second call.
    #expect(graph.neighbours(of: "b", along: .left) == ["a"])
    // And not along any other edge.
    #expect(graph.neighbours(of: "a", along: .left).isEmpty)
    #expect(graph.neighbours(of: "b", along: .right).isEmpty)
}

@Test func onePaneCanHoldSeveralNeighboursOnOneEdge() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .right, to: "c")
    #expect(graph.neighbours(of: "a", along: .right).sorted() == ["b", "c"])
}

@Test func linkingTheSamePairTwiceDoesNotDuplicateIt() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .right, to: "b")
    #expect(graph.neighbours(of: "a", along: .right) == ["b"])
    #expect(graph.links.count == 1)
}

@Test func unlinkingOneEdgeLeavesTheOthersAlone() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    graph.unlink("a", .right)
    #expect(graph.neighbours(of: "a", along: .right).isEmpty)
    #expect(graph.neighbours(of: "b", along: .left).isEmpty)
    // The pane pulled away on one side keeps every other relationship.
    #expect(graph.neighbours(of: "a", along: .bottom) == ["c"])
}

@Test func removingAPaneRemovesEveryLinkItHeld() {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    graph.link("b", .bottom, to: "c")
    graph.removeAll(for: "a")
    #expect(graph.neighbours(of: "b", along: .left).isEmpty)
    // "a" is gone, but "b" is also snapped above "c" (b.bottom -> c.top),
    // and that link does not involve "a" — so "c"'s top neighbour is "b",
    // not empty. (The brief's literal assertion here was `.isEmpty`, which
    // contradicts the undirected symmetry the first test in this file
    // establishes: b.bottom -> c implies c.top -> b regardless of "a".
    // Corrected to assert the behaviour the documented model actually
    // produces — see task-4-6-report.md.)
    #expect(graph.neighbours(of: "c", along: .top) == ["b"])
    // Links not involving the removed pane survive.
    #expect(graph.neighbours(of: "b", along: .bottom) == ["c"])
}

@Test func linksAreOrderedDeterministically() {
    var one = SnapGraph()
    one.link("a", .right, to: "b")
    one.link("a", .bottom, to: "c")
    var other = SnapGraph()
    other.link("a", .bottom, to: "c")
    other.link("a", .right, to: "b")
    // Same graph built in a different order encodes identically, so a
    // persisted layout does not churn on disk between launches.
    #expect(one.links == other.links)
    #expect(one == other)
}

@Test func aGraphRoundTripsThroughJSON() throws {
    var graph = SnapGraph()
    graph.link("a", .right, to: "b")
    graph.link("a", .bottom, to: "c")
    let data = try JSONEncoder().encode(graph)
    #expect(try JSONDecoder().decode(SnapGraph.self, from: data) == graph)
}
