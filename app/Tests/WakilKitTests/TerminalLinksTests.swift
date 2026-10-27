import Foundation
import Testing
@testable import WakilKit

/// `TerminalLinks` (3c-iii ruling 14): which text in a terminal line is a link, and how a row's
/// style runs are cut at a link's edges so the view can draw the link with its run's own style.

private let red = TerminalCellStyle(foreground: RGB(0.9, 0.36, 0.36))
private let boldPlain = TerminalCellStyle(bold: true)

/// The linked text of each link `find` reports, in order.
private func linkedTexts(_ line: String) -> [String] {
    TerminalLinks.find(in: line).map { link in
        let start = line.index(line.startIndex, offsetBy: link.range.lowerBound)
        let end = line.index(line.startIndex, offsetBy: link.range.upperBound)
        return String(line[start..<end])
    }
}

@Test(arguments: [
    ("See https://example.com/a.", ["https://example.com/a"]),
    ("(https://example.com/x)", ["https://example.com/x"]),
    ("main.go", []),
    ("v1.2.3", []),
    ("git@github.com:o/r.git", []),
    ("example.com", []),
    ("ftp://example.com", []),
    ("http://localhost:3000/api?x=1#y", ["http://localhost:3000/api?x=1#y"]),
    ("a https://example.com/one b http://example.com/two c", ["https://example.com/one", "http://example.com/two"]),
])
func onlySchemedHttpUrlsAreLinks(line: String, expected: [String]) {
    #expect(linkedTexts(line) == expected)
    #expect(TerminalLinks.find(in: line).map(\.url.absoluteString) == expected)
}

@Test func aLinkRangeCountsCharactersNotUtf16() {
    // Before the URL: an emoji (two UTF-16 units), a ZWJ family (eight), a flag (four) and a
    // decomposed é (two), each one Character. Inside it: another decomposed é and an emoji. In
    // Characters the URL is 8..<36; in UTF-16 units it would start at 20.
    let url = "https://example.com/cafe\u{301}?q=\u{1F600}"
    let line = "\u{1F600} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1EF}\u{1F1F5} e\u{301} \(url) x"
    #expect(TerminalLinks.find(in: line).map(\.range) == [8..<36])
    #expect(linkedTexts(line) == [url])
}

@Test func splitCutsRunsAtLinkEdges() {
    let pieces = TerminalLinks.split([TerminalStyleRun(text: "open https://example.com/a now", style: red)])
    #expect(pieces.map(\.run) == [
        TerminalStyleRun(text: "open ", style: red),
        TerminalStyleRun(text: "https://example.com/a", style: red),
        TerminalStyleRun(text: " now", style: red),
    ])
    #expect(pieces.map(\.link) == [nil, URL(string: "https://example.com/a"), nil])
}

@Test func aLinkAcrossTwoRunsLinksBothPieces() {
    let pieces = TerminalLinks.split([
        TerminalStyleRun(text: "go https://exa", style: boldPlain),
        TerminalStyleRun(text: "mple.com/b ok", style: red),
    ])
    let url = URL(string: "https://example.com/b")
    #expect(pieces.map(\.run) == [
        TerminalStyleRun(text: "go ", style: boldPlain),
        TerminalStyleRun(text: "https://exa", style: boldPlain),
        TerminalStyleRun(text: "mple.com/b", style: red),
        TerminalStyleRun(text: " ok", style: red),
    ])
    #expect(pieces.map(\.link) == [nil, url, url, nil])
}

@Test func aRowWithNoLinkComesBackAsItsOwnRuns() {
    let runs = [TerminalStyleRun(text: "main.go", style: red), TerminalStyleRun(text: " ok", style: .plain)]
    let pieces = TerminalLinks.split(runs)
    #expect(pieces.map(\.run) == runs)
    #expect(pieces.allSatisfy { $0.link == nil })
}

/// A grapheme whose scalars a style change splits across two runs is one Character in the row but
/// would count as two if each run were counted alone, shifting every cut after it.
@Test(arguments: [
    ("e", "\u{301} see "),  // a base and its combining mark
    ("\u{1F1EF}", "\u{1F1F5} see "),  // the two regional indicators of one flag
    ("\u{1F468}\u{200D}", "\u{1F469} see "),  // a ZWJ sequence
])
func aGraphemeAcrossARunBoundaryDoesNotShiftTheLink(head: String, tail: String) {
    let pieces = TerminalLinks.split([
        TerminalStyleRun(text: head, style: red),
        TerminalStyleRun(text: tail + "https://example.com/z ok", style: .plain),
    ])
    #expect(pieces.map(\.run) == [
        TerminalStyleRun(text: head, style: red),
        TerminalStyleRun(text: tail, style: .plain),
        TerminalStyleRun(text: "https://example.com/z", style: .plain),
        TerminalStyleRun(text: " ok", style: .plain),
    ])
    #expect(pieces.map(\.link) == [nil, nil, URL(string: "https://example.com/z"), nil])
}
