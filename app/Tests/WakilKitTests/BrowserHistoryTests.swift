import Foundation
import Testing
@testable import WakilKit

private func scratchHistory() -> BrowserHistory {
    BrowserHistory(url: testScratchRoot.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("browser").appendingPathComponent("history.sqlite"))
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func aFinishedVisitIsRecordedAndCounted() throws {
    let h = scratchHistory()
    try h.record(url: "https://example.com/a", title: "A", at: now, newVisit: true)
    let later = now.addingTimeInterval(60)
    try h.record(url: "https://example.com/a", title: "A2", at: later, newVisit: true)
    let rows = try h.matching(["example"], limit: 10)
    #expect(rows == [BrowserHistoryEntry(url: "https://example.com/a", title: "A2", count: 2, last: later)])
}

@Test func aTitleChangeIsNotAVisit() throws {
    let h = scratchHistory()
    try h.record(url: "https://example.com/a", title: "", at: now, newVisit: false)
    #expect(try h.matching(["example"], limit: 10).isEmpty)
    try h.record(url: "https://example.com/a", title: "Old", at: now, newVisit: true)
    try h.record(url: "https://example.com/a", title: "New", at: now.addingTimeInterval(5), newVisit: false)
    #expect(try h.matching(["example"], limit: 10) == [
        BrowserHistoryEntry(url: "https://example.com/a", title: "New", count: 1, last: now)])
}

@Test func onlyWebPagesAreRecorded() throws {
    let h = scratchHistory()
    for url in ["file:///x", "about:blank", "data:text/html,example", "not a url"] {
        try h.record(url: url, title: "example", at: now, newVisit: true)
    }
    #expect(try h.matching(["x"], limit: 10).isEmpty)
    #expect(try h.matching(["example"], limit: 10).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.url.path))
}

@Test func rowsOlderThanNinetyDaysAreDroppedOnWrite() throws {
    let h = scratchHistory()
    try h.record(url: "https://example.com/old", title: "", at: now.addingTimeInterval(-91 * 86_400), newVisit: true)
    try h.record(url: "https://example.com/recent", title: "", at: now.addingTimeInterval(-89 * 86_400), newVisit: true)
    try h.record(url: "https://example.com/new", title: "", at: now, newVisit: true)
    let urls = try h.matching(["example"], limit: 10).map(\.url)
    #expect(Set(urls) == ["https://example.com/recent", "https://example.com/new"])
}

@Test func everyWordMustMatchUrlOrTitle() throws {
    let h = scratchHistory()
    try h.record(url: "https://docs.initech.dev", title: "", at: now, newVisit: true)
    try h.record(url: "https://initech.dev", title: "Home", at: now, newVisit: true)
    #expect(try h.matching(["initech", "docs"], limit: 10).map(\.url) == ["https://docs.initech.dev"])
    #expect(try h.matching(["INITECH", "home"], limit: 10).map(\.url) == ["https://initech.dev"])
    #expect(try h.matching([], limit: 10).isEmpty)
}

@Test func resultsAreMostVisitedThenMostRecent() throws {
    let h = scratchHistory()
    try h.record(url: "https://example.com/1", title: "", at: now, newVisit: true)
    try h.record(url: "https://example.com/2", title: "", at: now.addingTimeInterval(10), newVisit: true)
    try h.record(url: "https://example.com/3", title: "", at: now.addingTimeInterval(20), newVisit: true)
    try h.record(url: "https://example.com/1", title: "", at: now.addingTimeInterval(30), newVisit: true)
    #expect(try h.matching(["example"], limit: 10).map(\.url)
        == ["https://example.com/1", "https://example.com/3", "https://example.com/2"])
    #expect(try h.matching(["example"], limit: 2).count == 2)
}

@Test func likeWildcardsInTypedTextAreLiteral() throws {
    let h = scratchHistory()
    try h.record(url: "https://example.com/100%", title: "", at: now, newVisit: true)
    try h.record(url: "https://example.com/1000", title: "", at: now, newVisit: true)
    try h.record(url: "https://example.com/a_b", title: "", at: now, newVisit: true)
    try h.record(url: "https://example.com/axb", title: "", at: now, newVisit: true)
    try h.record(url: "https://example.com/c\\d", title: "", at: now, newVisit: true)
    #expect(try h.matching(["100%"], limit: 10).map(\.url) == ["https://example.com/100%"])
    #expect(try h.matching(["a_b"], limit: 10).map(\.url) == ["https://example.com/a_b"])
    #expect(try h.matching(["c\\d"], limit: 10).map(\.url) == ["https://example.com/c\\d"])
    #expect(try h.matching(["'; DROP TABLE visits; --"], limit: 10).isEmpty)
    #expect(try h.matching(["example"], limit: 10).count == 5)
}

@Test func aReadOfAMissingFileIsEmptyAndCreatesNothing() throws {
    let h = scratchHistory()
    #expect(try h.matching(["x"], limit: 5).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.url.deletingLastPathComponent().path))
}

@Test func aWriteAfterRemovalStartsAFreshFileWithOnlyThatVisit() throws {
    let files = try BrowserOrgFiles(home: testScratchRoot.appendingPathComponent(UUID().uuidString), org: "initech")
    try files.history.record(url: "https://example.com/before", title: "", at: now, newVisit: true)
    try files.removeEverythingButTheProfile()
    try files.history.record(url: "https://example.com/after", title: "", at: now, newVisit: true)
    #expect(try files.history.matching(["example"], limit: 10).map(\.url) == ["https://example.com/after"])
}
