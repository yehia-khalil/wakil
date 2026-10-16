import Foundation
import Testing
@testable import WakilKit

private func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
private let prompt = osc("133;A") + osc("1337;WakilEdit=1") + "% " + osc("133;B")

private func session(cols: Int = 20, rows: Int = 4) -> TerminalSession {
    TerminalSession(paneId: "p", shellName: "test", cols: cols, rows: rows)
}

@Test func inputLineAtAPromptHoldsThePromptAndTypedText() throws {
    let s = session()
    s.feedForTesting(Array((prompt + "echo hi").utf8))
    let line = try #require(s.inputLine())
    #expect(String(line.cells.prefix(9).map(\.character)) == "% echo hi")
    #expect(line.cursor == TerminalGridPoint(row: 0, col: 9))
    #expect(line.cells.count == 20, "every cell of the row, blanks included")
}

@Test func inputLineIsNilWithoutTheSignal() {
    // A foreign prompt: A and B, no WakilEdit (Review Focus 5).
    let s = session()
    s.feedForTesting(Array((osc("133;A") + "% " + osc("133;B") + "ls").utf8))
    #expect(s.inputLine() == nil)
}

@Test func theSignalOnlyCountsForThePromptItFollowed() {
    let s = session()
    s.feedForTesting(Array((prompt + "x").utf8))
    s.feedForTesting(Array((osc("133;C;wakil_cmd=eA==") + "\r\n" + osc("133;D;0")).utf8))
    s.feedForTesting(Array((osc("133;A") + "% " + osc("133;B")).utf8))
    #expect(s.inputLine() == nil)
}

@Test func inputLineIsNilWhileACommandRuns() {
    let s = session()
    s.feedForTesting(Array((prompt + "sleep 9" + osc("133;C;wakil_cmd=c2xlZXAgOQ==")).utf8))
    #expect(s.inputLine() == nil)
}

@Test func inputLineIsNilOnTheAlternateScreen() {
    let s = session()
    s.feedForTesting(Array((prompt + "\u{1B}[?1049h").utf8))
    #expect(s.inputLine() == nil)
}

@Test func inputLineFollowsASoftWrapOntoTheNextRow() throws {
    let s = session(cols: 10)
    s.feedForTesting(Array((prompt + "abcdefghijkl").utf8))  // 2 + 12 = 14 cells
    let line = try #require(s.inputLine())
    #expect(line.cursor == TerminalGridPoint(row: 1, col: 4))
    #expect(String(line.cells.prefix(14).map(\.character)) == "% abcdefghijkl")
    #expect(line.cells[10].point == TerminalGridPoint(row: 1, col: 0))
}

@Test func inputLineSkipsTheTrailingHalfOfAWideCharacter() throws {
    let s = session()
    s.feedForTesting(Array((prompt + "日本").utf8))
    let line = try #require(s.inputLine())
    #expect(line.cells[2] == TerminalInputCell(point: TerminalGridPoint(row: 0, col: 2), character: "日", width: 2))
    #expect(line.cells[3] == TerminalInputCell(point: TerminalGridPoint(row: 0, col: 4), character: "本", width: 2))
    #expect(line.cursor == TerminalGridPoint(row: 0, col: 6))
}

@Test func bracketedPasteModeFollowsDECSET2004() {
    let s = session()
    #expect(!s.bracketedPasteMode)
    s.feedForTesting(Array("\u{1B}[?2004h".utf8))
    #expect(s.bracketedPasteMode)
    s.feedForTesting(Array("\u{1B}[?2004l".utf8))
    #expect(!s.bracketedPasteMode)
}
