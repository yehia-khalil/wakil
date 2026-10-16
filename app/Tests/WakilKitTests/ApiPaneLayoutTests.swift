import Foundation
import Testing
@testable import WakilKit

/// W10, W11: the pane splits, the request above at 55%, the response below.

private let reply = ApiResponseSnapshot.ok(ApiResponseOK(
    status: 200, url: "https://h/x", environment: "staging", headers: [:], body: "",
    durationMs: 5, byteCount: 0, truncated: false))

@Test("Once something came back, the request takes 55% and the response the rest")
func theSplitIsShared() {
    #expect(apiPaneSplit(total: 1000, response: reply) == .shared(request: 550, response: 450))
    #expect(apiPaneSplit(total: 381, response: reply) == .shared(request: 209, response: 172))
    #expect(apiRequestShare == 0.55)
}

@Test("A response that says one line shrinks to it", arguments: [
    ApiResponseSnapshot.none,
    .cleared(environment: "production"),
    .cancelled(ApiCancelled(waitedMs: 4200, environment: "staging")),
])
func aOneLineResponseShrinks(response: ApiResponseSnapshot) {
    #expect(apiResponseIsOneLine(response))
    #expect(apiPaneSplit(total: 1000, response: response) == .responseLine)
}

@Test("A refusal, a failure and a fate-unknown take their half: they say more than one line")
func theOtherStatesShare() {
    let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
        ApiSendFailure(region: .path, message: "m"),
    ]))
    let transport = ApiResponseSnapshot.transport(ApiTransportFailure(
        stage: "send", waitedMs: 3, reason: "r", environment: "staging"))
    let unknown = ApiResponseSnapshot.unknown(ApiFateUnknown(reason: "r", environment: "staging"))
    for response in [refusal, transport, unknown, reply] {
        #expect(!apiResponseIsOneLine(response))
        #expect(apiPaneSplit(total: 1000, response: response) == .shared(request: 550, response: 450))
    }
}

@Test("A pane with no height splits nothing")
func noHeight() {
    #expect(apiPaneSplit(total: 0, response: reply) == .shared(request: 0, response: 0))
    #expect(apiPaneSplit(total: -5, response: reply) == .shared(request: 0, response: 0))
}

/// Plan B preflight P17: the view never branches around the request half, so a first reply,
/// an environment switch or a cancel never rebuilds it. It reads its frames off the split.
@Test("A shared split fixes both halves' heights and the response body scrolls")
func sharedHeights() {
    let split = ApiPaneSplit.shared(request: 550, response: 450)
    #expect(split.requestHeight == 550)
    #expect(split.responseHeight == 450)
    #expect(split.responseScrolls)
}

@Test("A one-line response is drawn at its own height and the request takes the rest")
func lineHeights() {
    let split = ApiPaneSplit.responseLine
    #expect(split.requestHeight == nil)
    #expect(split.responseHeight == nil)
    #expect(!split.responseScrolls)
}

@Test("Recent is at most four rows tall, scrolling past that")
func recentIsAtMostFourRows() {
    #expect(apiRecentStripMaxRows == 4)
    #expect(apiRecentStripRows(count: 0) == 0)
    #expect(apiRecentStripRows(count: 3) == 3)
    #expect(apiRecentStripRows(count: 4) == 4)
    #expect(apiRecentStripRows(count: 9) == 4)
    #expect(apiRecentStripRows(count: -1) == 0)
}

@Test("W20: only a reply offers its headers")
func onlyAReplyOffersHeaders() {
    #expect(apiResponseOffersHeaders(reply))
    let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: []))
    let transport = ApiResponseSnapshot.transport(ApiTransportFailure(
        stage: "send", waitedMs: 3, reason: "r", environment: "staging"))
    for response in [ApiResponseSnapshot.none, refusal, transport,
                     .unknown(ApiFateUnknown(reason: "r", environment: "s")),
                     .cleared(environment: "s"),
                     .cancelled(ApiCancelled(waitedMs: 1, environment: "s"))] {
        #expect(!apiResponseOffersHeaders(response))
    }
}

@Test("W20: headers in byte order of the name — wakil-http's JSON map carries no wire order")
func headersInByteOrder() {
    let ok = ApiResponseOK(
        status: 200, url: "u", environment: "s",
        headers: ["x-b": "2", "date": "Fri", "Content-Type": "application/json"],
        body: "", durationMs: 1, byteCount: 0, truncated: false)
    #expect(apiResponseHeaderRows(ok) == [
        ApiResponseHeaderRow(name: "Content-Type", value: "application/json"),
        ApiResponseHeaderRow(name: "date", value: "Fri"),
        ApiResponseHeaderRow(name: "x-b", value: "2"),
    ])
}

@Test("W20: the choice reads Body · Headers, Body first, and keys its identifiers in lower case")
func theChoice() {
    #expect(ApiResponseShows.allCases.map(\.rawValue) == ["Body", "Headers"])
    #expect(ApiResponseShows.allCases.map(\.key) == ["body", "headers"])
}

@Test("T7 carry: a reply with no headers says so in one quiet line rather than an empty table")
func aReplyWithNoHeadersSaysSo() {
    let none = ApiResponseOK(
        status: 204, url: "https://h/x", environment: "staging", headers: [:], body: "",
        durationMs: 1, byteCount: 0, truncated: false)
    #expect(apiResponseHeadersEmptyLine(none) == "no headers")
    let some = ApiResponseOK(
        status: 200, url: "https://h/x", environment: "staging", headers: ["date": "Fri"],
        body: "", durationMs: 1, byteCount: 0, truncated: false)
    #expect(apiResponseHeadersEmptyLine(some) == nil)
}

// MARK: - Re-walk #1 (2026-10-04): the split's dividers, its edges, and the body's room

@Test("#1a: the split's two dividers are full-width hairlines a person can see")
func theDividersAreVisible() {
    #expect(ApiPaneDivider.weight >= 1)
    #expect(ApiPaneDivider.opacity >= 0.14 && ApiPaneDivider.opacity <= 0.2)
    #expect(ApiPaneDivider.spacing > 0)
}

@Test("#1b: a scroll region fades at its edges, inside padding of the same length")
func theScrollEdgesFade() {
    #expect(apiScrollEdgeFade > 0 && apiScrollEdgeFade <= 16)
}

@Test("#1c: Recent's rows wait until the body has its lines — six at most")
func theBodyKeepsSixLines() {
    let line = 15.0, row = 22.0
    func shown(_ count: Int, unfolded: Bool = true, room: Double?, body: Int = 40) -> Int {
        apiRecentShownRows(count: count, unfolded: unfolded, bodyRoom: room, bodyLines: body,
                           rowHeight: row, lineHeight: line)
    }
    // Room for six lines and all four rows: every row shows.
    #expect(shown(9, room: 6 * line + 4 * row) == 4)
    // Room for six lines and two rows: two rows, scrolling within.
    #expect(shown(9, room: 6 * line + 2 * row + 5) == 2)
    // A body of two lines reserves two, not six: the rest goes to Recent.
    #expect(shown(9, room: 2 * line + 3 * row, body: 2) == 3)
    // Folded shows none; a half drawn at its own height (nothing to scroll) shows them all.
    #expect(shown(3, unfolded: false, room: 1000) == 0)
    #expect(shown(3, room: nil) == 3)
    #expect(shown(0, room: 1000) == 0)
    #expect(apiResponseBodyMinLines == 6)
}

@Test("Review I1: the operator's unfold wins — Recent is reachable at the default pane size")
func theOperatorsUnfoldWinsAtTheDefaultSize() {
    let line = 15.0, row = 22.0
    // A 420pt pane after a transport failure: the response half is ~170pt and the head takes
    // most of it, leaving the body and Recent ~40pt — too little for six lines and a row.
    let room = 40.0
    #expect(apiRecentShownRows(count: 1, unfolded: true, bodyRoom: room, bodyLines: 1,
                               rowHeight: row, lineHeight: line) == 1)
    // Even a long body cedes a row to an explicit unfold: it scrolls, the row is there.
    #expect(apiRecentShownRows(count: 4, unfolded: true, bodyRoom: room, bodyLines: 40,
                               rowHeight: row, lineHeight: line) == 1)
    #expect(apiRecentShownRows(count: 4, unfolded: true, bodyRoom: 0, bodyLines: 40,
                               rowHeight: row, lineHeight: line) == 1)
}
