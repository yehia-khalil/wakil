import Foundation
import Testing
@testable import WakilKit

/// The grid's half of colour: `TerminalSession.screenLines()` and
/// `styledScreenLines()`, both read from SwiftTerm's own headless
/// engine via `feedForTesting` — no pty, no display, the same shape
/// `TerminalStoreTests` already uses to drive `consume` directly.

@Test func cursorForwardLeavesInteriorGapsAsSpacesNotAsNothing() {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 20, rows: 2)
    // "abc" at columns 0-2, cursor forward 7 (skipping to column 10),
    // "def" at columns 10-12 — the coordinator's own repro shape: content
    // on both sides of a gap the program never wrote spaces into.
    session.feedForTesting(Array("abc\u{1B}[7Cdef".utf8))
    let lines = session.screenLines()
    #expect(lines[0] == "abc" + String(repeating: " ", count: 7) + "def")
}

@Test func trailingBlankCellsAreStillTrimmedNotPaddedWithSpaces() {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 20, rows: 2)
    session.feedForTesting(Array("hi".utf8))
    let lines = session.screenLines()
    #expect(lines[0] == "hi")
}

@Test func styledScreenLinesRowOfOneColourIsOneRun() {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 20, rows: 2)
    session.feedForTesting(Array("plain row".utf8))
    let styled = session.styledScreenLines()
    #expect(styled[0].count == 1)
    #expect(styled[0][0].text == "plain row")
    #expect(styled[0][0].style == .plain)
}

@Test func styledScreenLinesCoalescesSeveralSGRRunsInOneRow() {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 20, rows: 2)
    session.feedForTesting(Array("\u{1B}[31mred\u{1B}[0m plain".utf8))
    let styled = session.styledScreenLines()
    let runs = styled[0]
    #expect(runs.map(\.text) == ["red", " plain"])
    #expect(runs[0].style.foreground != nil)
    #expect(runs[1].style == .plain)
}

@Test func styledScreenLinesFillsInteriorGapsWithPlainSpaceRuns() {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 20, rows: 2)
    session.feedForTesting(Array("\u{1B}[31mabc\u{1B}[7Cdef".utf8))
    let runs = session.styledScreenLines()[0]
    // "abc" (red) + 7 interior spaces (never written, so — like any cell
    // the program never touched — carry the row's own untouched
    // attribute rather than whatever SGR happened to be active when the
    // cursor skipped past them) + "def" (written while red was still the
    // active SGR, so red again). The point under test is the TEXT: the
    // gap is seven literal spaces, not seven vanished columns.
    #expect(runs.map(\.text).joined() == "abc" + String(repeating: " ", count: 7) + "def")
    #expect(runs.first?.style.foreground != nil)
    #expect(runs.last?.style.foreground != nil)
}
