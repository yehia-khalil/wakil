import Testing
@testable import WakilKit

/// The two rulings the API pane's restyle (direction C) draws from: the amber
/// unfilled-holes line under Send, and the hue the response's status chip takes.

private func request(
    path: [ApiPart] = [], query: [ApiQueryRow] = [],
    headers: [ApiHeaderRegionRow] = [], body: [ApiPart] = []
) -> ApiRequestSnapshot {
    ApiRequestSnapshot(
        method: "POST", origin: "https://billing.example.com",
        path: path, query: query, headers: headers, body: body)
}

@Test("B1/B2: a read's body is not sent, and a content type beside nothing is not sent")
func whatTheSendCarries() {
    let get = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [], query: [], headers: ApiRequestSnapshot.empty.headers,
        body: [.slot("id")])
    #expect(!apiBodyIsSent(get))
    #expect(!apiContentTypeIsSent(get))
    #expect(apiUnfilledHolesLine(get) == nil)  // B1: no line for a body that is not sent
    let post = ApiRequestSnapshot(
        method: "POST", origin: nil, path: [], query: [], headers: ApiRequestSnapshot.empty.headers,
        body: [])
    #expect(apiBodyIsSent(post))
    #expect(!apiContentTypeIsSent(post))
}

@Test("B1: a read's unfilled hole in its path still counts")
func aReadsPathHoleStillCounts() {
    let get = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.slot("a")], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [.slot("b")])
    #expect(apiUnfilledHolesLine(get) == "1 hole unfilled — drop a row on the pane to fill it")
}

// MARK: - The unfilled-holes line

@Test("No unfilled hole draws no line")
func noUnfilledHoleDrawsNoLine() {
    #expect(apiUnfilledHolesLine(request()) == nil)
    #expect(apiUnfilledHolesLine(request(
        path: [.literal("/bookings/41")],
        query: [ApiQueryRow(name: "expand", value: [.literal("lines")])],
        body: [.literal("{}")])) == nil)
}

@Test("One unfilled hole is counted in the singular")
func oneUnfilledHoleIsSingular() {
    let line = apiUnfilledHolesLine(request(path: [.literal("/bookings/"), .slot("id")]))
    #expect(line == "1 hole unfilled — drop a row on the pane to fill it")
}

@Test("Holes are counted across the path, query values, header values and the body")
func holesAreCountedAcrossEveryRegion() {
    let line = apiUnfilledHolesLine(request(
        path: [.literal("/customers/"), .slot("customer_id")],
        query: [ApiQueryRow(name: "notify", value: [.slot("channel")])],
        headers: [.operatorRow(name: "x-key", value: [.literal("k-"), .slot("booking_id")])],
        body: [.literal("{\"c\": "), .slot("customer_id"), .literal("}")]))
    // Counted by NAME, as a drop fills them: `customer_id` in the path and the body is one.
    #expect(line == "3 holes unfilled — drop a row on the pane to fill them")
}

@Test("One name in two regions is one hole")
func oneNameInTwoRegionsIsOneHole() {
    let line = apiUnfilledHolesLine(request(
        path: [.literal("/bookings/"), .slot("booking_id")],
        headers: [.operatorRow(name: "x-key", value: [.slot("booking_id")])]))
    #expect(line == "1 hole unfilled — drop a row on the pane to fill it")
}

@Test("A bound value is not an unfilled hole")
func aBoundValueIsNotCounted() {
    let bound = ApiPart.bound(liveBinding(name: "org_id"))
    #expect(apiUnfilledHolesLine(request(path: [.literal("/orgs/"), bound])) == nil)
    let line = apiUnfilledHolesLine(request(
        path: [.literal("/orgs/"), bound, .literal("/c/"), .slot("customer_id")],
        body: [bound]))
    #expect(line == "1 hole unfilled — drop a row on the pane to fill it")
}

// MARK: - The status chip's tone

@Test("A 2xx is healthy, and the band's edges hold")
func twoHundredsAreHealthy() {
    #expect(apiStatusTone(status: 200) == .healthy)
    #expect(apiStatusTone(status: 204) == .healthy)
    #expect(apiStatusTone(status: 299) == .healthy)
}

@Test("A 3xx or 4xx is caution, and so is anything below 200")
func threeAndFourHundredsAreCaution() {
    #expect(apiStatusTone(status: 199) == .caution)
    #expect(apiStatusTone(status: 300) == .caution)
    #expect(apiStatusTone(status: 404) == .caution)
    #expect(apiStatusTone(status: 499) == .caution)
}

@Test("A 5xx is failed")
func fiveHundredsAreFailed() {
    #expect(apiStatusTone(status: 500) == .failed)
    #expect(apiStatusTone(status: 503) == .failed)
    #expect(apiStatusTone(status: 599) == .failed)
}

@Test("A response's tone: a reply by its status, a transport failure failed, fate unknown caution")
func aResponsesTone() {
    func ok(_ status: Int) -> ApiResponseSnapshot {
        .ok(ApiResponseOK(
            status: status, url: "https://x.example.com/", environment: "staging",
            headers: [:], body: "", durationMs: 1, byteCount: 0, truncated: false))
    }
    #expect(apiStatusTone(ok(200)) == .healthy)
    #expect(apiStatusTone(ok(404)) == .caution)
    #expect(apiStatusTone(ok(500)) == .failed)
    #expect(apiStatusTone(.transport(ApiTransportFailure(
        stage: "connect", waitedMs: 30, reason: "refused", environment: "staging"))) == .failed)
    // It may have arrived: nothing has been shown to fail.
    #expect(apiStatusTone(.unknown(ApiFateUnknown(reason: "lost", environment: "staging")))
        == .caution)
}

@Test("Nothing sent is not a status: none, a refusal and a cleared reply take no tone")
func nothingSentHasNoTone() {
    #expect(apiStatusTone(.none) == nil)
    #expect(apiStatusTone(.refusal(ApiSendRefusal(failures: []))) == nil)
    #expect(apiStatusTone(.cleared(environment: "production")) == nil)
}

// MARK: - A single-line box's text

@Test("A single-line box commits its text with every line break taken out")
func singleLineTextDropsLineBreaks() {
    #expect(apiSingleLineText("/bookings/41") == "/bookings/41")
    #expect(apiSingleLineText("/bookings/\n41") == "/bookings/41")
    #expect(apiSingleLineText("a\r\nb\rc\n") == "abc")
    // Every other character is bytes on the wire, and kept exactly.
    #expect(apiSingleLineText("  x\ty  ") == "  x\ty  ")
}

// MARK: - The body heading and the content type's placeholder (W2, W19)

@Test("W2: the body heading says JSON from the content type, and TEXT otherwise", arguments: [
    ("", "BODY · JSON"),
    ("application/json", "BODY · JSON"),
    ("Application/JSON; charset=utf-8", "BODY · JSON"),
    ("application/merge-patch+json", "BODY · JSON"),
    ("text/plain", "BODY · TEXT"),
    ("application/x-www-form-urlencoded", "BODY · TEXT"),
])
func theBodyHeading(contentType: String, expected: String) {
    let rows = apiWakilHeaderRows(entry: "", contentType: contentType, credentialed: false)
    let request = ApiRequestSnapshot(method: "POST", origin: nil, path: [], query: [],
                                     headers: rows, body: [])
    #expect(apiBodyHeading(request) == expected)
}

@Test("W19: the content type's placeholder is the default it stands for")
func theContentTypePlaceholder() {
    #expect(apiContentTypePlaceholder == "application/json")
}
