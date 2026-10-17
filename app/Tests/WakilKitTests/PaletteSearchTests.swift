import Testing
@testable import WakilKit

private func e(_ t: String, _ s: String, _ k: String, _ g: PaletteGroup = .resources) -> PaletteEntry {
    PaletteEntry(id: "\(k):\(t):\(s)", group: g, title: t, subtitle: s, kindLabel: k, verb: "open",
                 action: .focusPane(id: t))
}
private let table = e("catalog", "core db · staging", "table")
private let api = e("catalog", "staging", "api")
private let other = e("bookings", "core db · staging", "table")

@Test func singleWordMatchesTitleSubtitleOrKind() {
    #expect(PaletteSearch.score(table, words: ["catalog"]) != nil)
    #expect(PaletteSearch.score(table, words: ["core"]) != nil)
    #expect(PaletteSearch.score(table, words: ["table"]) != nil)
    #expect(PaletteSearch.score(table, words: ["zzz"]) == nil)
}

@Test func everyWordMustMatchInAnyOrder() {
    let all = [table, api, other]
    #expect(PaletteSearch.rank(all, query: "catalog api").map(\.id) == [api.id])
    #expect(PaletteSearch.rank(all, query: "api catalog").map(\.id) == [api.id])
    for w in ["db", "table", "database"] {
        #expect(PaletteSearch.rank(all, query: "catalog \(w)").map(\.id) == [table.id], "\(w)")
    }
    #expect(Set(PaletteSearch.rank(all, query: "catalog catalog").map(\.id)) == [table.id, api.id])
    #expect(Set(PaletteSearch.rank(all, query: "catalog staging").map(\.id)) == [table.id, api.id])
}

@Test func everyAliasResolves() {
    let cases: [(String, String)] = [("db", "table"), ("database", "table"), ("table", "table"), ("api", "api"),
        ("term", "terminal"), ("terminal", "terminal"), ("pane", "pane"),
        ("project", "project"), ("session", "session"), ("provider", "provider")]
    for (word, kind) in cases {
        #expect(PaletteSearch.score(e("x", "", kind), words: [word]) != nil, "\(word) → \(kind)")
    }
}

@Test func caseSpacingAndEmptyQueries() {
    #expect(PaletteSearch.words("  Catalog   API ") == ["catalog", "api"])
    #expect(PaletteSearch.words("    ").isEmpty)
    // An empty query keeps input order (group order is the caller's).
    #expect(PaletteSearch.rank([other, table, api], query: "   ").map(\.id) == [other.id, table.id, api.id])
}

@Test func foldingFollows2dI() {
    // identifierFold keeps a–z, 0–9 and "."; é is dropped, not mapped.
    #expect(PaletteSearch.score(e("café", "", "table"), words: ["caf"]) != nil)
}

@Test func titleBeatsSubtitleBeatsKind() {
    let t = e("staging", "x", "table")
    let s = e("x", "staging", "table")
    let k = e("x", "y", "staging")   // a kind label that happens to read "staging"
    #expect(PaletteSearch.rank([k, s, t], query: "staging").map(\.title) == ["staging", "x", "x"])
    #expect(PaletteSearch.rank([k, s, t], query: "staging").first == t)
    #expect(PaletteSearch.rank([k, s, t], query: "staging")[1] == s)
}

@Test func prefixBeatsScattered() {
    let prefix = e("bookings", "", "table")
    let scattered = e("abo_okings", "", "table")
    #expect(PaletteSearch.rank([scattered, prefix], query: "book").first == prefix)
}

@Test func tiesAreStableByInputOrder() {
    let a = e("same", "1", "table"), b = e("same", "2", "table")
    #expect(PaletteSearch.rank([a, b], query: "same").map(\.id) == [a.id, b.id])
    #expect(PaletteSearch.rank([b, a], query: "same").map(\.id) == [b.id, a.id])
}

@Test func pathologicalQueries() {
    let all = [table, api, other]
    #expect(PaletteSearch.rank(all, query: String(repeating: "x", count: 500)).isEmpty)
    #expect(PaletteSearch.rank(all, query: "🙂").isEmpty)
    #expect(PaletteSearch.rank(all, query: "catalogcatalogcatalog").isEmpty)
}

@Test func errorRowsNeverMatchASearchButShowWhenEmpty() {
    var err = e("core db", "connection refused", "table"); err.isError = true
    #expect(PaletteSearch.rank([err], query: "").count == 1)
    #expect(PaletteSearch.rank([err], query: "core").count == 1)   // still visible while searching its source
}

@Test(.timeLimit(.minutes(1))) func tenThousandRowsRankQuickly() {
    let rows = (0..<10_000).map { e("table_\($0)", "db_\($0 % 50) · staging", "table") }
    let start = ContinuousClock.now
    _ = PaletteSearch.rank(rows, query: "table 99 staging")
    // Measured 0.11 s in a debug build alone and 0.12 s beside one `yes` per core; the old
    // ranking took 0.19 s alone. Inside the full suite the whole test still took 1.95 s (the
    // old one 2.0 s), so the bound is ~45x the alone figure: a loaded machine does not flake,
    // and a quadratic regression — minutes at 10 000 rows — still fails.
    #expect(ContinuousClock.now - start < .seconds(5))
}

// MARK: - Highlights: the title's matched letters, drawn bright

private func lit(_ title: String, _ words: [String], subtitle: String = "") -> [String] {
    let entry = e(title, subtitle, "command")
    return PaletteSearch.highlights(entry, words: words).map { String(title[$0]) }
}

@Test func aFoldedPrefixLightsTheLettersItUsedAndNotTheSpace() {
    #expect(lit("New pane…", ["newpane"]) == ["New", "pane"])
    #expect(lit("New pane…", ["new"]) == ["New"])
}

@Test func aTokenPrefixLightsThatToken() {
    #expect(lit("Switch environment…", ["env"]) == ["env"])
    #expect(lit("booking-controller.ts", ["cont"]) == ["cont"])
}

@Test func aScatteredMatchLightsEachLetter() {
    #expect(lit("pane_move", ["pm"]) == ["p", "m"])
}

@Test func everyWordLightsAndAdjacentRunsJoin() {
    #expect(lit("bookings", ["book", "ings"]) == ["bookings"])
    #expect(lit("Next page", ["page", "next"]) == ["Next", "page"])
}

@Test func aWordMatchedElsewhereLightsNothingInTheTitle() {
    #expect(lit("catalog", ["staging"], subtitle: "staging").isEmpty)
    #expect(lit("catalog", []).isEmpty)
    #expect(lit("catalog", ["zzz"]).isEmpty)
}

@Test func highlightsAreTheRangesOfTheTitleItself() {
    let entry = e("café pane", "", "command")
    let ranges = PaletteSearch.highlights(entry, words: ["caf"])
    #expect(ranges.map { String(entry.title[$0]) } == ["caf"])
    #expect(ranges.allSatisfy { $0.lowerBound >= entry.title.startIndex && $0.upperBound <= entry.title.endIndex })
}

/// 2d-i's fold, on a catalog command: the joined shape of a spaced title ranks it above a row
/// that matches only as scattered letters.
@Test func aJoinedQueryFindsTheSpacedCommandFirst() {
    let scattered = e("new_open_pane", "", "command")
    let command = e("New pane…", "", "command")
    #expect(PaletteSearch.rank([scattered, command], query: "newpane").map(\.title) == ["New pane…", "new_open_pane"])
}

/// Final fix wave, item 7: the aliases reach the rows the sources really produce. The kind
/// labels come from `newPaneEntries` and `OpenPanesSource` — `db`, `terminal`, `api` —
/// not from labels a test made up, and every open or new pane row answers `pane`.
@Test func kindAliasesReachTheSourcesRealRows() async {
    let new = newPaneEntries(kinds: ["db", "terminal", "api"])
    let open = await OpenPanesSource(panes: {
        [PaneSummary(id: "d1", kind: "db", title: "core", holds: "bookings"),
         PaneSummary(id: "t1", kind: "terminal", title: "zsh", holds: "/tmp"),
         PaneSummary(id: "a1", kind: "api", title: "catalog", holds: "staging")]
    }).entries()
    #expect(Set((new + open).map(\.kindLabel)) == ["db", "terminal", "api"], "the real labels")
    func hits(_ query: String) -> Set<String> { Set(PaletteSearch.rank(new + open, query: query).map(\.id)) }

    for word in ["db", "database"] {
        #expect(hits(word).isSuperset(of: ["newpane:db", "pane:d1"]), "\(word)")
    }
    for word in ["term", "terminal"] {
        #expect(hits(word).isSuperset(of: ["newpane:terminal", "pane:t1"]), "\(word)")
    }
    #expect(hits("api").isSuperset(of: ["newpane:api", "pane:a1"]))
    #expect(hits("pane") == Set((new + open).map(\.id)), "every open and new pane row answers pane")
}

@Test func aDimmedRowRanksBelowEveryUndimmedMatchHoweverWellItScores() {
    let dimmed = PaletteEntry(id: "editorfile:/p/api/env.php", group: .resources, title: "env.php", subtitle: "api",
                              kindLabel: "file", verb: "open", action: .focusPane(id: "x"), isDimmed: true)
    let plain = PaletteEntry(id: "editorfile:/p/api/xenv.txt", group: .resources, title: "xenv.txt", subtitle: "api",
                             kindLabel: "file", verb: "open", action: .focusPane(id: "y"))
    #expect(PaletteSearch.rank([dimmed, plain], query: "env").map(\.title) == ["xenv.txt", "env.php"])
}
