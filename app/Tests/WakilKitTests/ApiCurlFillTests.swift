import Testing
@testable import WakilKit

private func parsed(
    method: String = "GET", url: String = "https://billing.example.com/v1/x",
    headers: [(String, String)] = [], body: String = "", hasBody: Bool = false, dropped: [String] = []
) -> ApiCurlParsed {
    ApiCurlParsed(method: method, url: url, headers: headers.map { (name: $0.0, value: $0.1) },
                  body: body, hasBody: hasBody, dropped: dropped)
}

private func here(entry: String = "billing", path: String = "/v1/x") -> ApiCurlLocation {
    ApiCurlLocation(found: true, active: true, environment: "staging", entry: entry, path: path,
                    host: "billing.example.com", entries: ["billing", "catalog"])
}

@Test("A fill replaces the whole draft: method, path, query, headers, body")
func aFillReplacesTheWholeDraft() {
    var current = ApiDraft.empty
    current.entry = "billing"
    current.headers = [ApiHeaderRow(name: "x-old", value: [.literal("1")])]
    current.body = [.literal("old")]
    let fill = apiCurlFill(
        parsed(method: "POST", headers: [("X-Trace", "7")], body: "{\"a\":1}", hasBody: true),
        here(path: "/v1/x?paid=true&page=2"), current: current)
    guard case .fill(let draft, let switches, let dropped) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.entry == "billing")
    #expect(!switches)
    #expect(dropped.isEmpty)
    #expect(draft.method == "POST")
    #expect(draft.path == [.literal("/v1/x")])
    #expect(draft.query == [ApiQueryRow(name: "paid", value: [.literal("true")]),
                            ApiQueryRow(name: "page", value: [.literal("2")])])
    #expect(draft.headers == [ApiHeaderRow(name: "X-Trace", value: [.literal("7")])])
    #expect(draft.body == [.literal("{\"a\":1}")])
}

@Test("content-type goes to Wakil's own row, whatever its case")
func contentTypeGoesToItsOwnRow() {
    let fill = apiCurlFill(parsed(method: "POST", headers: [("Content-Type", "application/json")],
                                  body: "{}", hasBody: true), here(), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.contentType == "application/json")
    #expect(draft.headers.isEmpty)
}

@Test("Another entry in this environment switches the pane to it")
func anotherEntrySwitches() {
    var current = ApiDraft.empty
    current.entry = "catalog"
    let fill = apiCurlFill(parsed(), here(entry: "billing"), current: current)
    guard case .fill(let draft, let switches, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.entry == "billing")
    #expect(switches)
}

@Test("An entry only in another environment is refused, naming it")
func anotherEnvironmentIsRefused() {
    var loc = here(entry: "catalog")
    loc.active = false
    loc.environment = "qa"
    #expect(apiCurlFill(parsed(), loc, current: .empty)
        == .refused("this cURL is for catalog in qa; switch environment first"))
}

@Test("No entry has the host: refused, naming the host and the entries")
func noEntryIsRefused() {
    let loc = ApiCurlLocation(found: false, active: false, environment: "staging", entry: "",
                              path: "", host: "api.other.com", entries: ["billing", "catalog"])
    #expect(apiCurlFill(parsed(url: "https://api.other.com/x"), loc, current: .empty)
        == .refused("this cURL is for api.other.com; no entry in staging has that host (entries: billing, catalog)"))
}

@Test("A URL with no host is refused in those words, not as a host no entry has")
func noHostIsRefused() throws {
    let loc = try ApiCurlLocation(json: .object([
        "found": .bool(false), "noHost": .bool(true), "environment": .string("staging"),
        "host": .string(""), "entries": .array([.string("billing")])]))
    #expect(loc.noHost)
    #expect(apiCurlFill(parsed(url: "api.x/v1/a"), loc, current: .empty)
        == .refused("the URL names no host Wakil can read"))
}

@Test("parse_curl's dropped names pass through to the line")
func droppedPassThrough() {
    let fill = apiCurlFill(parsed(dropped: ["Authorization", "-k"]), here(), current: .empty)
    guard case .fill(_, _, let dropped) = fill else { Issue.record("\(fill)"); return }
    #expect(dropped == ["Authorization", "-k"])
}

@Test("The line names the entry, and what was dropped")
func theLine() {
    #expect(apiCurlFillLine(entry: "billing", pastedHost: "", entryHost: "", dropped: [])
        == ApiBindLine(text: "Filled from cURL · billing", caution: false))
    #expect(apiCurlFillLine(entry: "billing", pastedHost: "", entryHost: "", dropped: ["Authorization", "-k"])
        == ApiBindLine(text: "Filled from cURL · billing · dropped: Authorization, -k", caution: false))
}

@Test("A www. host taken as the entry's is named on the line, before what was dropped")
func theLineNamesTheHostChange() {
    #expect(apiCurlFillLine(entry: "httpbin", pastedHost: "www.httpbin.org", entryHost: "httpbin.org", dropped: [])
        == ApiBindLine(text: "Filled from cURL · httpbin · host www.httpbin.org taken as httpbin.org", caution: false))
    #expect(apiCurlFillLine(entry: "httpbin", pastedHost: "www.httpbin.org", entryHost: "httpbin.org", dropped: ["-k"])
        == ApiBindLine(text: "Filled from cURL · httpbin · host www.httpbin.org taken as httpbin.org · dropped: -k",
                       caution: false))
}

@Test("ApiCurlLocation reads pastedHost and entryHost; missing is empty")
func locationReadsTheHostPair() throws {
    let with = try ApiCurlLocation(json: .object([
        "found": .bool(true), "pastedHost": .string("www.a.com"), "entryHost": .string("a.com")]))
    #expect(with.pastedHost == "www.a.com" && with.entryHost == "a.com")
    let without = try ApiCurlLocation(json: .object(["found": .bool(true)]))
    #expect(without.pastedHost == "" && without.entryHost == "")
}

@Test("Only text starting with curl, after leading whitespace, is a cURL paste")
func pasteIsCurl() {
    #expect(apiPasteIsCurl("curl https://a"))
    #expect(apiPasteIsCurl("  \n\tcurl 'https://a'"))
    #expect(apiPasteIsCurl("curl\\\n  https://a"))
    #expect(!apiPasteIsCurl("curly"))
    #expect(!apiPasteIsCurl("/v1/curl"))
    #expect(!apiPasteIsCurl("curl"))
}

@Test("ApiCurlParsed reads parse_curl's result, names only for dropped")
func parsedReadsTheTool() throws {
    let json: JSONValue = .object([
        "method": .string("POST"), "url": .string("https://a.example/x"),
        "headers": .array([.object(["name": .string("X"), "value": .string("1")])]),
        "body": .string("b"), "hasBody": .bool(true),
        "dropped": .array([.object(["name": .string("-u"), "reason": .string("a credential …")])]),
        "ignored": .array([.string("-s")]),
    ])
    let p = try ApiCurlParsed(json: json)
    #expect(p.method == "POST" && p.body == "b" && p.hasBody && p.dropped == ["-u"])
    #expect(p.headers.count == 1 && p.headers[0].name == "X" && p.headers[0].value == "1")
}

@Test("A pasted query is decoded; the path stays as pasted")
func aPastedQueryIsDecoded() {
    let fill = apiCurlFill(parsed(), here(path: "/a%2Fb/x?q=two%20words&n=%C3%A9"), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.path == [.literal("/a%2Fb/x")])
    #expect(draft.query == [ApiQueryRow(name: "q", value: [.literal("two words")]),
                            ApiQueryRow(name: "n", value: [.literal("é")])])
}

@Test("A query row with no = keeps its name and has no value")
func aQueryRowWithoutEquals() {
    let fill = apiCurlFill(parsed(), here(path: "/x?flag"), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.path == [.literal("/x")])
    #expect(draft.query == [ApiQueryRow(name: "flag", value: [])])
}

@Test("A refused split refuses the fill in the split's words")
func aRefusedSplitRefuses() {
    #expect(apiCurlFill(parsed(), here(path: "/x?=1"), current: .empty)
        == .refused("a query row needs a name"))
}

@Test("ApiCurlLocation reads null or missing entries as none")
func locationReadsNullEntries() throws {
    let loc = try ApiCurlLocation(json: .object(["found": .bool(false), "entries": .null]))
    #expect(loc.entries.isEmpty)
}

@Test("A cURL paste is read across CRLF, BOM and Unicode whitespace")
func pasteIsCurlUnicodeWhitespace() {
    #expect(apiPasteIsCurl("curl\r\n-X POST https://a"))
    #expect(apiPasteIsCurl("\r\ncurl https://a"))
    #expect(apiPasteIsCurl("\u{FEFF}curl https://a"))
    #expect(apiPasteIsCurl("\u{A0}curl https://a"))
    #expect(apiPasteIsCurl("curl\u{A0}https://a"))
    #expect(!apiPasteIsCurl("CURL https://a"))
    #expect(!apiPasteIsCurl("curl"))
}

// The same list is in curl_test.go (curlBlankScalars): Go's parser and this trigger must read
// exactly these scalars as a separator, and no other.
@Test("The trigger's blank set is exactly the shared list")
func pasteBlankSetIsTheSharedList() {
    let shared: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    var blank: Set<UInt32> = []
    for v in UInt32(0)...0x10FFFF {
        guard let u = Unicode.Scalar(v), v != 0x5C else { continue }  // "\\" also follows "curl"
        if apiPasteIsCurl("curl" + String(Character(u)) + "x") { blank.insert(v) }
    }
    #expect(blank == shared)
}

@Test("In a pasted query + is a space, %2B is a plus; the path keeps +")
func aPlusInAQueryIsASpace() {
    let fill = apiCurlFill(parsed(), here(path: "/a+b?q=a+b&p=1%2B1"), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.path == [.literal("/a+b")])
    #expect(draft.query == [ApiQueryRow(name: "q", value: [.literal("a b")]),
                            ApiQueryRow(name: "p", value: [.literal("1+1")])])
}

@Test("A decoded & locks the path box rather than corrupting it")
func aDecodedAmpersandLocksTheBox() {
    let fill = apiCurlFill(parsed(), here(path: "/x?q=a%26b"), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.query == [ApiQueryRow(name: "q", value: [.literal("a&b")])])
    #expect(!apiPathQueryRoundTrips(draft.query))
}

@Test("A fill's outcome is its line; a refusal is amber")
func aFillsOutcomeIsItsLine() {
    #expect(apiCurlFillSummary(.result(.object(["line": .string("Filled from cURL · billing")])))
        == ApiBindLine(text: "Filled from cURL · billing", caution: false))
    #expect(apiCurlFillSummary(.refused("nothing to undo"))
        == ApiBindLine(text: "nothing to undo", caution: true))
    #expect(apiCurlFillSummary(.result(.object([:]))) == ApiBindLine(text: "", caution: false))
}

@Test("A paste fills from cURL only when it is outside text reading as a curl command")
func aPasteFillsFromCurlOnlyAsOutsideCurlText() {
    #expect(apiPasteFillsFromCurl(hasClip: false, plain: "curl https://x.example.com/a"))
    #expect(apiPasteFillsFromCurl(hasClip: false, plain: "  \r\ncurl\\\n -X POST u"))
    // Wakil's own clip is tokens, never a command, whatever its plain text says.
    #expect(!apiPasteFillsFromCurl(hasClip: true, plain: "curl https://x.example.com/a"))
    #expect(!apiPasteFillsFromCurl(hasClip: false, plain: "/v1/curl"))
    #expect(!apiPasteFillsFromCurl(hasClip: false, plain: "curly"))
    #expect(!apiPasteFillsFromCurl(hasClip: false, plain: nil))
}

@Test("A refusal under a fill line draws under it; the fill keeps its line and Undo")
func aRefusalUnderAFillLineDrawsBoth() {
    let refused = ApiBindLine(text: "nothing to undo", caution: true)
    let both = apiPaneResultLines(fill: "Filled from cURL · billing", undoable: true, bind: refused)
    #expect(both == ApiPaneResultLines(
        fill: "Filled from cURL · billing", undo: true, below: refused))
    // A fill whose kept draft is gone draws its line with no Undo.
    #expect(apiPaneResultLines(fill: "Filled from cURL · billing", undoable: false, bind: nil)
        == ApiPaneResultLines(fill: "Filled from cURL · billing", undo: false, below: nil))
    // No fill: the drop's or a refused paste's line alone, and never an Undo.
    #expect(apiPaneResultLines(fill: nil, undoable: true, bind: refused)
        == ApiPaneResultLines(fill: nil, undo: false, below: refused))
    #expect(apiPaneResultLines(fill: nil, undoable: false, bind: nil)
        == ApiPaneResultLines(fill: nil, undo: false, below: nil))
}

@Test("A new fill line forgets the line before it; a fill going away keeps it")
func aNewFillForgetsTheLineBeforeIt() {
    let drop = ApiBindLine(text: "Filled 1", caution: false)
    // An agent's fill lands over a drop's line: that line is about a draft no longer there.
    #expect(apiBindLineAfterFill(drop, from: nil, to: "Filled from cURL · billing") == nil)
    #expect(apiBindLineAfterFill(drop, from: "Filled from cURL · a", to: "Filled from cURL · b")
        == nil)
    // A refusal drawn under a fill stays while that fill does, and when it goes.
    let refused = ApiBindLine(text: "nothing to undo", caution: true)
    #expect(apiBindLineAfterFill(refused, from: "Filled from cURL · a", to: "Filled from cURL · a")
        == refused)
    #expect(apiBindLineAfterFill(refused, from: "Filled from cURL · a", to: nil) == refused)
}

@Test("After a fill the caret goes to the path's end only while the path has the cursor")
func afterAFillTheCaretGoesToThePathsEnd() {
    #expect(apiFillCaret(owed: true, focused: true, length: 12) == 12..<12)
    // Rule 6: a cursor the operator put elsewhere during the fill is left there.
    #expect(apiFillCaret(owed: true, focused: false, length: 12) == nil)
    #expect(apiFillCaret(owed: false, focused: true, length: 12) == nil)
    #expect(apiFillCaret(owed: true, focused: true, length: 0) == 0..<0)
}
