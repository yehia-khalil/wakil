import Foundation
import Testing
@testable import WakilKit

/// Builds a one-row input line from `text`, cells at columns 0..., cursor at `cursorCol`.
private func line(_ text: String, cursorCol: Int, row: Int = 0) -> TerminalInputLine {
    let cells = text.enumerated().map { index, character in
        TerminalInputCell(point: TerminalGridPoint(row: row, col: index), character: character, width: 1)
    }
    return TerminalInputLine(cells: cells, cursor: TerminalGridPoint(row: row, col: cursorCol))
}

private func range(_ a: (Int, Int), _ b: (Int, Int)) -> TerminalGridRange {
    TerminalGridRange(anchor: TerminalGridPoint(row: a.0, col: a.1), head: TerminalGridPoint(row: b.0, col: b.1))
}

@Test func lineEditBeforeTheCursorHasNegativeDeltas() {
    // "% git checkout main", cursor after "main" (col 19)
    let l = line("% git checkout main", cursorCol: 19)
    let edit = terminalLineEdit(selection: range((0, 6), (0, 13)), line: l)
    #expect(edit == TerminalLineEdit(startDelta: -13, endDelta: -5, expected: "checkout"))
}

@Test func lineEditIsTheSameWhicheverWayTheDragWent() {
    let l = line("% git checkout main", cursorCol: 19)
    #expect(terminalLineEdit(selection: range((0, 13), (0, 6)), line: l)
        == terminalLineEdit(selection: range((0, 6), (0, 13)), line: l))
}

@Test func lineEditAfterTheCursorHasPositiveDeltas() {
    let l = line("% git checkout main", cursorCol: 2)
    let edit = terminalLineEdit(selection: range((0, 6), (0, 13)), line: l)
    #expect(edit == TerminalLineEdit(startDelta: 4, endDelta: 12, expected: "checkout"))
}

@Test func lineEditCoveringPromptTextStartsBeforeTheBuffer() {
    // The widget trims the prompt part; the mapping just reports it.
    let l = line("% ls", cursorCol: 4)
    let edit = terminalLineEdit(selection: range((0, 0), (0, 3)), line: l)
    #expect(edit == TerminalLineEdit(startDelta: -4, endDelta: 0, expected: "% ls"))
}

@Test func lineEditAcrossAWrappedRowCountsBothRows() {
    // 5 columns: "% abc" on row 0, "def" on row 1, cursor after "f".
    var cells = "% abc".enumerated().map { TerminalInputCell(point: TerminalGridPoint(row: 0, col: $0), character: $1, width: 1) }
    cells += "def".enumerated().map { TerminalInputCell(point: TerminalGridPoint(row: 1, col: $0), character: $1, width: 1) }
    let l = TerminalInputLine(cells: cells, cursor: TerminalGridPoint(row: 1, col: 3))
    let edit = terminalLineEdit(selection: range((0, 3), (1, 1)), line: l)
    #expect(edit == TerminalLineEdit(startDelta: -5, endDelta: -1, expected: "bcde"))
}

@Test func lineEditCountsAWideCharacterOnce() {
    // "% 日本x": 日 at cols 2-3, 本 at 4-5, x at 6; cursor at 7.
    let cells = [
        TerminalInputCell(point: TerminalGridPoint(row: 0, col: 0), character: "%", width: 1),
        TerminalInputCell(point: TerminalGridPoint(row: 0, col: 1), character: " ", width: 1),
        TerminalInputCell(point: TerminalGridPoint(row: 0, col: 2), character: "日", width: 2),
        TerminalInputCell(point: TerminalGridPoint(row: 0, col: 4), character: "本", width: 2),
        TerminalInputCell(point: TerminalGridPoint(row: 0, col: 6), character: "x", width: 1),
    ]
    let l = TerminalInputLine(cells: cells, cursor: TerminalGridPoint(row: 0, col: 7))
    // Selecting the trailing half of 本 (col 5) still selects 本.
    let edit = terminalLineEdit(selection: range((0, 5), (0, 5)), line: l)
    #expect(edit == TerminalLineEdit(startDelta: -2, endDelta: -1, expected: "本"))
}

@Test func lineEditSelectingNoCellIsNil() {
    let l = line("% ls", cursorCol: 4)
    #expect(terminalLineEdit(selection: range((3, 0), (3, 4)), line: l) == nil)
}

@Test func wordSelectionIsTheNonBlankRunUnderThePoint() {
    let l = line("% git checkout main", cursorCol: 19)
    #expect(terminalWordSelection(at: TerminalGridPoint(row: 0, col: 9), line: l) == range((0, 6), (0, 13)))
    #expect(terminalWordSelection(at: TerminalGridPoint(row: 0, col: 5), line: l) == nil)
}

@Test func shiftLeftFromNoSelectionSelectsTheCellBeforeTheCursor() {
    let l = line("% ab", cursorCol: 4)
    #expect(terminalExtendSelection(nil, by: -1, line: l) == range((0, 3), (0, 3)))
}

@Test func shiftRightThenShiftLeftReturnsToNoSelection() {
    let l = line("% ab", cursorCol: 2)
    let one = terminalExtendSelection(nil, by: 1, line: l)
    #expect(one == range((0, 2), (0, 2)))
    #expect(terminalExtendSelection(one, by: -1, line: l) == nil)
}

@Test func shiftLeftTwiceGrowsLeftwardKeepingTheAnchor() {
    let l = line("% ab", cursorCol: 4)
    let once = terminalExtendSelection(nil, by: -1, line: l)
    #expect(terminalExtendSelection(once, by: -1, line: l) == range((0, 3), (0, 2)))
}

@Test func selectionColumnsPerRow() {
    let r = range((0, 3), (2, 1))
    #expect(terminalSelectionColumns(r, row: 0, columnCount: 10) == 3..<10)
    #expect(terminalSelectionColumns(r, row: 1, columnCount: 10) == 0..<10)
    #expect(terminalSelectionColumns(r, row: 2, columnCount: 10) == 0..<2)
    #expect(terminalSelectionColumns(r, row: 3, columnCount: 10) == nil)
}

@Test func selectedTextJoinsRowsWithNewlines() {
    // Rows are the live region's plain text, starting at screen row 4.
    let text = terminalSelectedText(range((4, 2), (5, 1)), rows: ["% abc", "de"], startRow: 4)
    #expect(text == "abc\nde")
}

@Test func pasteUnbracketedTurnsNewlinesIntoCarriageReturns() {
    #expect(terminalPasteBytes("a\nb\r\nc", bracketed: false) == Array("a\rb\rc".utf8))
}

@Test func pasteBracketedIsWrapped() {
    #expect(terminalPasteBytes("ls\npwd", bracketed: true) == Array("\u{1B}[200~ls\rpwd\u{1B}[201~".utf8))
}

@Test func pasteStripsAPlantedEndMarkerAndEditIntroducer() {
    let planted = "echo hi\u{1B}[201~rm -rf x\u{1B}[999~0;1;;\u{07}"
    #expect(terminalPasteBytes(planted, bracketed: true)
        == Array("\u{1B}[200~echo hirm -rf x0;1;;\u{07}\u{1B}[201~".utf8))
}

@Test func pasteStripsMarkersThatReappearAfterOnePass() {
    // Removing the inner marker must not leave an outer one behind.
    #expect(terminalPasteBytes("a\u{1B}[20\u{1B}[201~1~b", bracketed: false) == Array("ab".utf8))
}

@Test func replaceBytesCarryDeltasAndBase64Fields() {
    let edit = TerminalLineEdit(startDelta: -13, endDelta: -5, expected: "checkout")
    let bytes = terminalReplaceBytes(edit: edit, replacement: "switch")
    #expect(bytes == Array("\u{1B}[999~-13;-5;Y2hlY2tvdXQ=;c3dpdGNo\u{07}".utf8))
}

@Test func replaceBytesWithAnEmptyReplacementKeepTheEmptyField() {
    let edit = TerminalLineEdit(startDelta: -1, endDelta: 0, expected: "x")
    #expect(terminalReplaceBytes(edit: edit, replacement: "") == Array("\u{1B}[999~-1;0;eA==;\u{07}".utf8))
}
