import Testing
import Foundation
@testable import WakilKit

/// **The address field's suggestions** (3c-iii, rulings 7, 8, 10): ranking, inline completion and
/// the engines' suggestion endpoints. Pure.
@Suite struct BrowserSuggestionsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func tab(_ id: String, _ url: String, _ title: String = "") -> BrowserTab {
        BrowserTab(id: id, url: url, title: title)
    }
    private func mark(_ url: String, _ title: String = "", _ age: TimeInterval = 0) -> BrowserBookmark {
        BrowserBookmark(url: url, title: title, added: Date(timeIntervalSince1970: 1_000_000 + age))
    }
    private func hist(_ url: String, _ title: String = "", count: Int = 1, _ age: TimeInterval = 0) -> BrowserHistoryEntry {
        BrowserHistoryEntry(url: url, title: title, count: count, last: Date(timeIntervalSince1970: 1_000_000 + age))
    }
    private func rank(_ typed: String, tabs: [BrowserTab] = [],
                      bookmarks: [BrowserBookmark] = [], history: [BrowserHistoryEntry] = [],
                      search: [String] = []) -> [BrowserSuggestion] {
        BrowserSuggestions.rank(typed, tabs: tabs, bookmarks: bookmarks, history: history, search: search)
    }

    @Test func groupsComeTabsBookmarksHistorySearch() {
        let rows = rank("ex",
                        tabs: [tab("t1", "https://ex.com/t")],
                        bookmarks: [mark("https://ex.com/b")],
                        history: [hist("https://ex.com/h")],
                        search: ["example"])
        #expect(rows.map(\.kind) == [.tab, .bookmark, .history, .search])
        #expect(rows[0].tab == "t1")
        #expect(rows[0].id == "tab:https://ex.com/t")
        #expect(rows[3].url == "example")
        #expect(rows[3].tab == nil)
    }

    @Test func groupLimitsAreThreeThreeEightFour() {
        let tabs = (0..<5).map { tab("t\($0)", "https://ex.com/t\($0)") }
        let marks = (0..<5).map { mark("https://ex.com/b\($0)") }
        let history = (0..<20).map { hist("https://ex.com/h\($0)") }
        let rows = rank("ex", tabs: tabs, bookmarks: marks, history: history,
                        search: ["a1", "a2", "a3", "a4", "a5", "a6"])
        func n(_ k: BrowserSuggestion.Kind) -> Int { rows.filter { $0.kind == k }.count }
        #expect(n(.tab) == 3)
        #expect(n(.bookmark) == 3)
        #expect(n(.history) == 2)  // 8 rows in all
        #expect(n(.search) == 4)
        let onlyHistory = rank("ex", history: history)
        #expect(onlyHistory.count == 8)
    }

    @Test func aUrlInAnEarlierGroupIsDroppedLater() {
        let rows = rank("ex",
                        tabs: [tab("t1", "https://ex.com/a")],
                        bookmarks: [mark("https://ex.com/a"), mark("https://ex.com/b")],
                        history: [hist("https://ex.com/a"), hist("https://ex.com/b"), hist("https://ex.com/c")])
        #expect(rows.map(\.url) == ["https://ex.com/a", "https://ex.com/b", "https://ex.com/c"])
        #expect(rows.map(\.kind) == [.tab, .bookmark, .history])
    }

    @Test func aTabWithNoAddressIsNotSuggested() {
        let rows = rank("new", tabs: [tab("t1", "")])
        #expect(rows.isEmpty)
    }

    @Test func aPrefixOfTheBareUrlOutranksATitleWordOutranksContains() {
        let history = [
            hist("https://other.com/x", "Complex marks", count: 9),  // 1: contains in title only
            hist("https://docs.other.com/ex", "Notes", count: 5),    // 1: contains in URL
            hist("https://other.org/y", "An ex-libris", count: 4),   // 2: title word starts with "ex"
            hist("https://www.ex.com/z", "Zed", count: 1),           // 3: bare URL starts with it
        ]
        let rows = rank("ex", history: history)
        #expect(rows.map(\.url) == ["https://www.ex.com/z", "https://other.org/y",
                                    "https://other.com/x", "https://docs.other.com/ex"])
    }

    @Test func everyWordMustMatchAndMatchingIgnoresCase() {
        let history = [hist("https://example.com/Docs", "Reference"), hist("https://example.com/x", "Other")]
        #expect(rank("EXAMPLE docs", history: history).map(\.url) == ["https://example.com/Docs"])
        #expect(rank("example reference", history: history).count == 1)
        #expect(rank("example nothing", history: history).isEmpty)
    }

    @Test func historyTiesGoByCountThenLast() {
        let history = [
            hist("https://ex.com/old", count: 2, 0),
            hist("https://ex.com/new", count: 2, 100),
            hist("https://ex.com/many", count: 7, -50),
        ]
        #expect(rank("ex.com", history: history).map(\.url)
                == ["https://ex.com/many", "https://ex.com/new", "https://ex.com/old"])
    }

    @Test func bookmarksAndTabsBreakTiesNewestFirstAndStripOrder() {
        let marks = [mark("https://ex.com/old", "", 0), mark("https://ex.com/new", "", 100)]
        #expect(rank("ex", bookmarks: marks).map(\.url) == ["https://ex.com/new", "https://ex.com/old"])
        let tabs = [tab("a", "https://ex.com/1"), tab("b", "https://ex.com/2")]
        #expect(rank("ex", tabs: tabs).map(\.tab) == ["a", "b"])
    }

    @Test func emptyTextSuggestsNothing() {
        #expect(rank("", tabs: [tab("t", "https://ex.com")], history: [hist("https://ex.com")], search: ["a"]).isEmpty)
        #expect(rank("   ", history: [hist("https://ex.com")]).isEmpty)
    }

    @Test func bareURLDropsSchemeWwwAndTrailingSlash() {
        #expect(BrowserSuggestions.bareURL("https://www.github.com/") == "github.com")
        #expect(BrowserSuggestions.bareURL("http://localhost:3000/a/") == "localhost:3000/a")
        #expect(BrowserSuggestions.words("  a  b\tc ") == ["a", "b", "c"])
    }

    private func row(_ url: String, kind: BrowserSuggestion.Kind = .history) -> BrowserSuggestion {
        BrowserSuggestion(kind: kind, title: "", url: url, tab: nil)
    }

    @Test func completionRunsToTheEndOfTheHost() {
        #expect(BrowserSuggestions.completion("git", in: [row("https://github.com/x/y")]) == "hub.com")
    }

    @Test func completionRunsToTheWholeUrlOnceASlashIsTyped() {
        #expect(BrowserSuggestions.completion("github.com/x", in: [row("https://github.com/x/y")]) == "/y")
    }

    @Test func noCompletionWithWhitespace() {
        #expect(BrowserSuggestions.completion("git hub", in: [row("https://github.com")]) == nil)
        #expect(BrowserSuggestions.completion("git ", in: [row("https://github.com")]) == nil)
    }

    @Test func completionKeepsWhatWasTypedAndIgnoresCase() {
        #expect(BrowserSuggestions.completion("GIT", in: [row("https://www.github.com/x")]) == "hub.com")
    }

    @Test func completionTakesTheFirstRowThatStartsWithItAndSkipsSearchRows() {
        let rows = [row("gitignore tips", kind: .search), row("https://other.com/git"), row("https://github.com"),
                    row("https://gitlab.com")]
        #expect(BrowserSuggestions.completion("git", in: rows) == "hub.com")
        #expect(BrowserSuggestions.completion("github.com", in: rows) == nil)
        #expect(BrowserSuggestions.completion("", in: rows) == nil)
    }

    @Test func aTypedSchemeOrWwwStillMatches() {
        let entries = [hist("https://github.com", "GitHub")]
        for typed in ["https://git", "http://git", "www.git", "https://www.git", "HTTPS://GIT"] {
            #expect(rank(typed, history: entries).map(\.url) == ["https://github.com"], "\(typed)")
        }
    }

    @Test func completionAfterATypedSchemeOrWww() {
        let rows = [row("https://github.com/x/y")]
        #expect(BrowserSuggestions.completion("https://git", in: rows) == "hub.com")
        #expect(BrowserSuggestions.completion("www.git", in: rows) == "hub.com")
        #expect(BrowserSuggestions.completion("https://www.github.com/x", in: rows) == "/y")
        #expect(BrowserSuggestions.completion("https://", in: rows) == nil)
    }

    @Test func engineUrlsEncodeTheQuery() {
        func u(_ e: String) -> String? { BrowserEngineSuggest.url(engine: e, query: "a&b c")?.absoluteString }
        #expect(u("google") == "https://suggestqueries.google.com/complete/search?client=firefox&q=a%26b%20c")
        #expect(u("duckduckgo") == "https://duckduckgo.com/ac/?type=list&q=a%26b%20c")
        #expect(u("bing") == "https://api.bing.com/osjson.aspx?query=a%26b%20c")
        #expect(u("kagi") == nil)
        #expect(u("nonsense") == nil)
    }

    @Test func parseReadsOpenSearchAndIgnoresJunk() {
        #expect(BrowserEngineSuggest.parse(Data(#"["q",["a","b"]]"#.utf8)) == ["a", "b"])
        #expect(BrowserEngineSuggest.parse(Data("{}".utf8)).isEmpty)
        #expect(BrowserEngineSuggest.parse(Data("not json".utf8)).isEmpty)
        #expect(BrowserEngineSuggest.parse(Data(#"["q",[1,"b"]]"#.utf8)) == ["b"])
    }

    @Test func theSuggestionSessionCarriesNoCookies() {
        let c = BrowserEngineSuggest.session().configuration
        #expect(c.httpCookieStorage == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.urlCache == nil)
        #expect(c.timeoutIntervalForRequest == 2)
    }
}
