import Foundation

// MARK: - Editing a selection on the shell's input line (#365)

/// A cell on the visible screen. `row` is SwiftTerm's `buffer.y` space —
/// the same as `TerminalSnapshot.cursorRow` — and `col` is the cell column.
public struct TerminalGridPoint: Sendable, Hashable, Comparable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
    public static func < (a: Self, b: Self) -> Bool { (a.row, a.col) < (b.row, b.col) }
}

/// A selection: both ends inclusive cells, `anchor` where it began.
public struct TerminalGridRange: Sendable, Equatable {
    public var anchor: TerminalGridPoint
    public var head: TerminalGridPoint
    public init(anchor: TerminalGridPoint, head: TerminalGridPoint) {
        self.anchor = anchor
        self.head = head
    }
    public var lower: TerminalGridPoint { min(anchor, head) }
    public var upper: TerminalGridPoint { max(anchor, head) }
}

/// One character on the input line. A wide character is one cell of
/// `width` 2; its trailing half is not a cell of its own.
public struct TerminalInputCell: Sendable, Equatable {
    public let point: TerminalGridPoint
    public let character: Character
    public let width: Int
    public init(point: TerminalGridPoint, character: Character, width: Int) {
        self.point = point
        self.character = character
        self.width = width
    }
}

/// The cursor's run of rows (its own row plus the soft-wrapped rows around
/// it), every cell in reading order, prompt and trailing blanks included.
/// `TerminalSession.inputLine()` builds it; `nil` there means editing is off.
public struct TerminalInputLine: Sendable, Equatable {
    public let cells: [TerminalInputCell]
    public let cursor: TerminalGridPoint
    public init(cells: [TerminalInputCell], cursor: TerminalGridPoint) {
        self.cells = cells
        self.cursor = cursor
    }

    /// The index of the cell the cursor sits on — or `cells.count` when it
    /// sits past the last one.
    var cursorIndex: Int { cells.firstIndex { $0.point >= cursor } ?? cells.count }

    func index(of point: TerminalGridPoint) -> Int? {
        cells.firstIndex { $0.point.row == point.row && $0.point.col <= point.col
            && point.col < $0.point.col + $0.width }
    }
}

/// What the shell is asked to replace: characters `[CURSOR + startDelta,
/// CURSOR + endDelta)`, which should currently read `expected`.
///
/// **Relative to the cursor, not to the prompt's end.** `TerminalSession`
/// feeds a whole chunk to SwiftTerm before it reads that chunk's marks, so
/// where `133;B` landed is not known exactly; where the cursor is, both
/// the screen and zsh's `CURSOR` agree on. Prompt text and blank cells past
/// the end of the line may be included — the widget trims them, and a
/// mapping that is wrong anyway is rejected by its `expected` check.
public struct TerminalLineEdit: Sendable, Equatable {
    public let startDelta: Int
    public let endDelta: Int
    public let expected: String
    public init(startDelta: Int, endDelta: Int, expected: String) {
        self.startDelta = startDelta
        self.endDelta = endDelta
        self.expected = expected
    }
}

/// The edit `selection` asks for, or `nil` when it covers no cell of `line`.
public func terminalLineEdit(selection: TerminalGridRange, line: TerminalInputLine) -> TerminalLineEdit? {
    let lower = selection.lower
    let upper = selection.upper
    var first: Int?
    var last = 0
    var expected = ""
    for (index, cell) in line.cells.enumerated() {
        let cellEnd = TerminalGridPoint(row: cell.point.row, col: cell.point.col + cell.width - 1)
        guard cellEnd >= lower, cell.point <= upper else { continue }
        if first == nil { first = index }
        last = index
        expected.append(cell.character)
    }
    guard let first else { return nil }
    let cursor = line.cursorIndex
    return TerminalLineEdit(startDelta: first - cursor, endDelta: last + 1 - cursor, expected: expected)
}

/// Double-click: the run of non-blank cells under `point`, or `nil` on a blank.
public func terminalWordSelection(at point: TerminalGridPoint, line: TerminalInputLine) -> TerminalGridRange? {
    guard let index = line.index(of: point), !line.cells[index].character.isWhitespace else { return nil }
    var lo = index
    var hi = index
    while lo > 0, !line.cells[lo - 1].character.isWhitespace { lo -= 1 }
    while hi + 1 < line.cells.count, !line.cells[hi + 1].character.isWhitespace { hi += 1 }
    return TerminalGridRange(anchor: line.cells[lo].point, head: line.cells[hi].point)
}

/// ⇧← (`step` -1) / ⇧→ (+1). Works in carets — the gaps between cells —
/// the way a text field does, so ⇧→ then ⇧← comes back to no selection.
public func terminalExtendSelection(
    _ selection: TerminalGridRange?, by step: Int, line: TerminalInputLine
) -> TerminalGridRange? {
    var anchorCaret: Int
    var headCaret: Int
    if let selection, let a = line.index(of: selection.anchor), let h = line.index(of: selection.head) {
        // One selected cell has no direction of its own; the cursor, which
        // a keyboard selection never moves, says which side it grew from.
        let rightward = a < h || (a == h && line.cursorIndex <= a)
        if rightward { anchorCaret = a; headCaret = h + 1 } else { anchorCaret = a + 1; headCaret = h }
    } else {
        anchorCaret = line.cursorIndex
        headCaret = anchorCaret
    }
    headCaret = min(max(headCaret + step, 0), line.cells.count)
    guard headCaret != anchorCaret else { return nil }
    if headCaret > anchorCaret {
        return TerminalGridRange(anchor: line.cells[anchorCaret].point, head: line.cells[headCaret - 1].point)
    }
    return TerminalGridRange(anchor: line.cells[anchorCaret - 1].point, head: line.cells[headCaret].point)
}

/// The columns `selection` covers on screen row `row`, for the highlight.
public func terminalSelectionColumns(_ selection: TerminalGridRange, row: Int, columnCount: Int) -> Range<Int>? {
    let lower = selection.lower
    let upper = selection.upper
    guard row >= lower.row, row <= upper.row else { return nil }
    let start = row == lower.row ? lower.col : 0
    let end = row == upper.row ? upper.col + 1 : columnCount
    guard start < end else { return nil }
    return start..<end
}

/// ⌘C: the selected text, read off the live region's plain rows. A grid row
/// holds one `Character` per cell (`TerminalSession.rowCells`), so a column
/// is a character index.
public func terminalSelectedText(_ selection: TerminalGridRange, rows: [String], startRow: Int) -> String {
    var parts: [String] = []
    for (offset, text) in rows.enumerated() {
        let characters = Array(text)
        guard let columns = terminalSelectionColumns(selection, row: startRow + offset, columnCount: characters.count)
        else { continue }
        let lo = min(columns.lowerBound, characters.count)
        let hi = min(columns.upperBound, characters.count)
        parts.append(String(characters[lo..<hi]))
    }
    return parts.joined(separator: "\n")
}

// MARK: - The bytes

/// The private key sequence the generated rc binds to `__wakil_replace`
/// (`ShellIntegration.swift`). Nothing a keyboard sends starts with it.
public let terminalLineEditIntroducer: [UInt8] = Array("\u{1B}[999~".utf8)

/// ⌘V's bytes. Newlines become `\r`, what a keyboard's Return sends.
/// **The paste markers and the edit introducer are stripped from the text,
/// repeatedly**, so a clipboard can neither end a bracketed paste early and
/// run what follows, nor forge an edit request.
public func terminalPasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
    var cleaned = text
    let forbidden = ["\u{1B}[200~", "\u{1B}[201~", "\u{1B}[999~"]
    while let marker = forbidden.first(where: { cleaned.contains($0) }) {
        cleaned = cleaned.replacingOccurrences(of: marker, with: "")
    }
    cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    return Array((bracketed ? "\u{1B}[200~\(cleaned)\u{1B}[201~" : cleaned).utf8)
}

/// The request `__wakil_replace` reads: `ESC[999~` then
/// `startDelta;endDelta;base64(expected);base64(replacement)` then `BEL`.
/// base64 keeps `;`, newlines and `BEL` in operator text from ending it.
public func terminalReplaceBytes(edit: TerminalLineEdit, replacement: String) -> [UInt8] {
    let expected = Data(edit.expected.utf8).base64EncodedString()
    let replaced = Data(replacement.utf8).base64EncodedString()
    return terminalLineEditIntroducer
        + Array("\(edit.startDelta);\(edit.endDelta);\(expected);\(replaced)\u{07}".utf8)
}
