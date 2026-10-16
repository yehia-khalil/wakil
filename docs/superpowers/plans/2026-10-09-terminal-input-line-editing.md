# Terminal input-line editing (#365) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘V pastes into the terminal pane, and a selection on the shell's input line can be replaced by typing, deleted with Backspace/Delete, or replaced by a paste.

**Architecture:** zsh (and bash ≥4) keeps owning the line. The pane tracks its own selection over the live region, maps it to character offsets *relative to the cursor*, and sends one private key sequence (`ESC[999~ … BEL`) that a widget in Wakil's generated rc turns into a `BUFFER`/`CURSOR` edit, guarded by an expected-text check. Paste is ordinary pty bytes, bracketed when SwiftTerm says the shell asked for it.

**Tech Stack:** Swift 6 / SwiftUI (`WakilKit` tested with Swift Testing, `WakilApp` untested), SwiftTerm (headless `Terminal`), zsh zle, bash readline.

**Spec:** `docs/superpowers/specs/2026-10-09-terminal-input-line-editing-design.md`

## Global Constraints

- Every byte to the pty goes through the existing `send` / `WindowModel.sendToTerminal` path — no new action, no change to `term_run` (Invariant 2: "a keystroke is text-field editing").
- The private sequence is exactly `ESC[999~` (`"\u{1B}[999~"`); the payload is `<startDelta>;<endDelta>;<base64 expected>;<base64 replacement>` then `BEL` (`0x07`).
- The support signal is exactly `OSC 1337;WakilEdit=1 BEL`, emitted every prompt right after `133;A`.
- Bracketed paste wraps in `ESC[200~` … `ESC[201~`; pasted text has `ESC[200~`, `ESC[201~` and `ESC[999~` stripped (repeatedly, until none remain).
- Output rows above the prompt keep SwiftUI `.textSelection(.enabled)`; only `liveRegion()` changes.
- No view per cell (`LiveGrid`'s measured rule): highlights are one overlay per row.
- No confirmation, no refusal message, no jump (PRODUCT.md interaction rules 1, 6, 7).
- Swift tests run from `app/`: `../scripts/swift-test.sh --filter <Suite-or-test>`. **Subagents run only filtered tests**; the controller runs the full `make app-test` (memory: subagents never run long gates).
- No `Co-Authored-By` trailer in commits.

## Review Focus

1. **The screen scrolls while typing a long line at the bottom row** — the cursor-relative mapping still holds because both sides count from the cursor; pinned by Task 3's wrapped-line session test and Task 4's real-zsh replace.
2. **A selection that starts in the prompt (`~/src % `) and ends in typed text** — only the typed part is replaced; pinned in Task 1 (`terminalLineEdit` negative deltas) and Task 4 (real zsh trims).
3. **Clipboard text containing `ESC[201~` or `ESC[999~`** — must not end the paste or forge an edit; pinned in Task 2.
4. **Keystrokes in flight when the edit lands (cursor moved since the selection was made)** — zsh ignores the request on expected-text mismatch rather than corrupting the line; pinned in Task 4's mismatch test.
5. **A foreign prompt (ssh to a host with its own OSC 133, or a nested shell)** — editing stays off because `WakilEdit` didn't follow that prompt's `A`; pinned in Task 3 (`A` + `B` without the signal → `inputLine() == nil`).

---

### Task 1: Selection model (pure)

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalLineEdit.swift`
- Test: `app/Tests/WakilKitTests/TerminalLineEditTests.swift`

**Interfaces:**
- Produces: `TerminalGridPoint(row:col:)` (Comparable), `TerminalGridRange(anchor:head:)` with `.lower`/`.upper`, `TerminalInputCell(point:character:width:)`, `TerminalInputLine(cells:cursor:)`, `TerminalLineEdit(startDelta:endDelta:expected:)`, and functions `terminalLineEdit(selection:line:) -> TerminalLineEdit?`, `terminalWordSelection(at:line:) -> TerminalGridRange?`, `terminalExtendSelection(_:by:line:) -> TerminalGridRange?`, `terminalSelectionColumns(_:row:columnCount:) -> Range<Int>?`, `terminalSelectedText(_:rows:startRow:) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run (from `app/`): `../scripts/swift-test.sh --filter TerminalLineEditTests`
Expected: compile failure — `TerminalGridPoint` not found.

- [ ] **Step 3: Implement**

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `../scripts/swift-test.sh --filter TerminalLineEditTests`
Expected: all 13 pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Terminal/TerminalLineEdit.swift app/Tests/WakilKitTests/TerminalLineEditTests.swift
git commit -m "Terminal: selection model for editing the input line (#365)"
```

---

### Task 2: Paste and replace bytes (pure)

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalLineEdit.swift` (append)
- Test: `app/Tests/WakilKitTests/TerminalLineEditTests.swift` (append)

**Interfaces:**
- Consumes: `TerminalLineEdit` (Task 1).
- Produces: `terminalLineEditIntroducer: [UInt8]`, `terminalPasteBytes(_ text: String, bracketed: Bool) -> [UInt8]`, `terminalReplaceBytes(edit: TerminalLineEdit, replacement: String) -> [UInt8]`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `../scripts/swift-test.sh --filter TerminalLineEditTests`
Expected: compile failure — `terminalPasteBytes` not found.

- [ ] **Step 3: Implement** (append to `TerminalLineEdit.swift`)

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `../scripts/swift-test.sh --filter TerminalLineEditTests`
Expected: all 19 pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Terminal/TerminalLineEdit.swift app/Tests/WakilKitTests/TerminalLineEditTests.swift
git commit -m "Terminal: paste and replace bytes, markers stripped from the clipboard (#365)"
```

---

### Task 3: The session knows when the line is editable

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalMarkScanner.swift` (enum + `event(from:)`)
- Modify: `app/Sources/WakilKit/Terminal/TerminalSession.swift` (state near `promptRow` ~line 202; event switch ~line 906–1040; new methods after `cursorPosition()` ~line 2001)
- Modify: `app/Sources/WakilKit/Panes/PaneSnapshot.swift` (`TerminalSnapshot` fields + init, ~lines 236–300)
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (`TerminalContents` ~line 197; `snapshot()` ~line 205; `setTerminalLiveState` ~line 1439)
- Modify: `app/Sources/WakilKit/Terminal/TerminalStore.swift` (the `setTerminalLiveState` call ~line 588; test accessors after `screenContains` ~line 432)
- Test: `app/Tests/WakilKitTests/TerminalMarkScannerTests.swift` (append), create `app/Tests/WakilKitTests/TerminalInputLineTests.swift`

**Interfaces:**
- Consumes: `TerminalInputLine`, `TerminalInputCell`, `TerminalGridPoint` (Task 1).
- Produces: `TerminalStreamEvent.editSupported`; `TerminalSession.inputLine() -> TerminalInputLine?`, `TerminalSession.bracketedPasteMode: Bool`; `TerminalSnapshot.inputLine: TerminalInputLine?`, `TerminalSnapshot.bracketedPaste: Bool`; test-only `TerminalStore.inputLine(_ paneId: String) -> TerminalInputLine?`, `TerminalStore.screenLines(_ paneId: String) -> [String]`, `TerminalStore.bracketedPaste(_ paneId: String) -> Bool`, `TerminalStore.marks(_ paneId: String) -> [TerminalStreamEvent]`, `TerminalStore.lineEditSupported(_ paneId: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `TerminalMarkScannerTests.swift`:

```swift
@Test func scannerRecognisesTheLineEditSignal() {
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]1337;WakilEdit=1\u{07}")) == [.editSupported])
}

@Test func scannerPassesOtherITermSequencesThrough() {
    let scanner = TerminalMarkScanner()
    let raw = "\u{1b}]1337;SetMark\u{07}"
    #expect(scanner.consume(bytes(raw)) == [.output(Array(raw.utf8))])
}
```

Create `TerminalInputLineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `../scripts/swift-test.sh --filter "TerminalMarkScannerTests|TerminalInputLineTests"`
Expected: compile failure — `.editSupported` / `inputLine()` not found.

- [ ] **Step 3: Implement**

`TerminalMarkScanner.swift` — add the case and its recognition:

```swift
    case hostDirectory(String)
    /// `OSC 1337;WakilEdit=1`: the generated rc installed `__wakil_replace`
    /// in this shell (#365). Sent every prompt, right after `133;A`.
    case editSupported
```

and in `event(from:)`, before `return nil` at the end:

```swift
        if text == "1337;WakilEdit=1" { return .editSupported }
```

`TerminalSession.swift` — state next to `promptRow`:

```swift
    /// Between a `133;B` and the next `A` or `C`: the operator is typing at
    /// a prompt (#365). Read and written under `lock`.
    private var atPrompt = false
    /// `.editSupported` arrived after the latest `A` — so this prompt is
    /// one Wakil's rc drew, not an ssh host's or a nested shell's.
    private var lineEditSupported = false
```

In the event switch: in `case .promptStart:` add `atPrompt = false` and `lineEditSupported = false` after `promptRow = terminal.buffer.y`; in `case .commandStart(let command):` add `atPrompt = false` after `appendMark(event)`; and add two cases before `default:`:

```swift
            case .promptEnd:
                appendMark(event)
                atPrompt = true
            case .editSupported:
                // Not a mark: `marks` records the shell's structure, and
                // this says only which rc drew the prompt.
                lineEditSupported = true
```

After `cursorPosition()`:

```swift
    /// The cursor's run of rows as cells, or `nil` when the line is not
    /// editable: not at a prompt, a prompt Wakil's rc did not draw, or the
    /// alternate screen. See `TerminalInputLine`.
    func inputLine() -> TerminalInputLine? {
        if isAlternateScreenActive { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard atPrompt, lineEditSupported else { return nil }
        let cursor = TerminalGridPoint(row: terminal.buffer.y, col: terminal.buffer.x)
        var first = cursor.row
        var last = cursor.row
        // `isWrapped` marks a row that CONTINUES the one above it.
        while first > 0, terminal.getLine(row: first)?.isWrapped == true { first -= 1 }
        while last + 1 < rows, terminal.getLine(row: last + 1)?.isWrapped == true { last += 1 }
        var cells: [TerminalInputCell] = []
        for row in first...last {
            guard let line = terminal.getLine(row: row) else { continue }
            for col in 0..<min(line.count, cols) {
                let cell = line[col]
                guard cell.width > 0 else { continue }  // a wide character's trailing half
                let decoded = cell.getCharacter()
                cells.append(TerminalInputCell(
                    point: TerminalGridPoint(row: row, col: col),
                    character: decoded == "\0" ? " " : decoded, width: Int(cell.width)))
            }
        }
        return TerminalInputLine(cells: cells, cursor: cursor)
    }

    /// Whether the shell asked for bracketed paste (DECSET 2004), as
    /// SwiftTerm tracks it.
    var bracketedPasteMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal.bracketedPasteMode
    }

    /// TEST-ONLY.
    func lineEditSupportedForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lineEditSupported
    }
```

`PaneSnapshot.swift` — in `TerminalSnapshot`, after `commandRunning`:

```swift
    /// The input line when it can be edited by selection, else `nil` —
    /// `TerminalSession.inputLine()` (#365). Not published to `read_pane`.
    public let inputLine: TerminalInputLine?
    /// Whether the shell asked for bracketed paste (#365).
    public let bracketedPaste: Bool
```

Add `inputLine: TerminalInputLine? = nil, bracketedPaste: Bool = false` to the init's parameter list after `gridStyles`, and assign `self.inputLine = inputLine` / `self.bracketedPaste = bracketedPaste` in its body. `static let empty` needs no change (defaults).

`PaneStore.swift` — in `TerminalContents` after `commandRunning`:

```swift
        var inputLine: TerminalInputLine?
        var bracketedPaste = false
```

pass `inputLine: inputLine, bracketedPaste: bracketedPaste` as the last arguments of `TerminalSnapshot(...)` in `snapshot()`; add `inputLine: TerminalInputLine? = nil, bracketedPaste: Bool = false` to `setTerminalLiveState`'s parameters after `commandRunning`, and `contents.inputLine = inputLine` / `contents.bracketedPaste = bracketedPaste` in its body.

`TerminalStore.swift` — append to the `setTerminalLiveState` call after `commandRunning: session.commandRunning`:

```swift
            commandRunning: session.commandRunning,
            inputLine: session.inputLine(),
            bracketedPaste: session.bracketedPasteMode)
```

and after `screenContains`:

```swift
    /// TEST-ONLY (#365).
    func inputLine(_ paneId: String) -> TerminalInputLine? { sessions[paneId]?.inputLine() }
    /// TEST-ONLY (#365).
    func screenLines(_ paneId: String) -> [String] { sessions[paneId]?.screenLines() ?? [] }
    /// TEST-ONLY (#365).
    func bracketedPaste(_ paneId: String) -> Bool { sessions[paneId]?.bracketedPasteMode ?? false }
    /// TEST-ONLY (#365).
    func marks(_ paneId: String) -> [TerminalStreamEvent] { sessions[paneId]?.marksForTesting() ?? [] }
    /// TEST-ONLY (#365).
    func lineEditSupported(_ paneId: String) -> Bool { sessions[paneId]?.lineEditSupportedForTesting() ?? false }
```

- [ ] **Step 4: Run to verify they pass**

Run: `../scripts/swift-test.sh --filter "TerminalMarkScannerTests|TerminalInputLineTests|TerminalMarksCapTests|TerminalStoreTests"`
Expected: all pass (the last two prove the marks list and the store are unchanged).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests/TerminalMarkScannerTests.swift app/Tests/WakilKitTests/TerminalInputLineTests.swift
git commit -m "Terminal: publish the editable input line and bracketed-paste mode (#365)"
```

---

### Task 4: The edit command in zsh and bash

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/ShellIntegration.swift` (`zshRC`: before `autoload -Uz add-zsh-hook`, and in `__wakil_precmd`; `bashRC`: before `PROMPT_COMMAND=`, and in `__wakil_after_precmd`; the doc comment's mark list)
- Modify: `app/Tests/WakilKitTests/TerminalStoreTests.swift` (make `waitUntil` and `scratchHome` internal: drop `private`)
- Test: create `app/Tests/WakilKitTests/TerminalLineEditShellTests.swift`

**Interfaces:**
- Consumes: `terminalLineEdit`, `terminalReplaceBytes`, `terminalPasteBytes`, `TerminalGridRange` (Tasks 1–2); `TerminalStore.inputLine/screenLines/bracketedPaste/marks/lineEditSupported` (Task 3); `withTerminalStore`, `waitUntil`, `scratchHome` (TerminalStoreTests).
- Produces: the shell side of the payload contract in Global Constraints.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WakilKit

/// Real shells on real ptys, through the store — the shipped path.

/// Opens `shell`, waits for an editable prompt, types `text`, waits for it.
private func typed(_ store: TerminalStore, shell: String, _ text: String) async throws {
    _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: shell,
                             environment: ["HOME": scratchHome()])
    try await waitUntil(seconds: 10) { await store.inputLine("t") != nil }
    await store.write(paneId: "t", bytes: Array(text.utf8))
    try await waitUntil(seconds: 5) { await store.screenContains("t", text) }
}

/// The selection over `word` on the current input line.
private func selection(of word: String, in line: TerminalInputLine) throws -> TerminalGridRange {
    let characters = line.cells.map(\.character)
    let target = Array(word)
    let start = try #require((0...(characters.count - target.count)).last {
        Array(characters[$0..<($0 + target.count)]) == target })
    return TerminalGridRange(anchor: line.cells[start].point, head: line.cells[start + target.count - 1].point)
}

private func runAndWaitForOutput(_ store: TerminalStore, _ output: String) async throws {
    await store.write(paneId: "t", bytes: Array("\r".utf8))
    try await waitUntil(seconds: 5) { await store.screenLines("t").contains(output) }
}

@Test func zshReplacesTheSelectedWord() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let edit = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "switch"))
        try await waitUntil(seconds: 5) { await store.screenContains("t", "echo git switch main") }
        try await runAndWaitForOutput(store, "git switch main")
    }
}

@Test func zshDeletesASelectionThatStartsInThePrompt() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo abc")
        let line = try #require(await store.inputLine("t"))
        // From the first cell on the row (prompt text) through "echo ".
        let echoEnd = try selection(of: "echo ", in: line).head
        let edit = try #require(terminalLineEdit(
            selection: TerminalGridRange(anchor: line.cells[0].point, head: echoEnd), line: line))
        #expect(edit.startDelta < -8, "the selection reaches back into the prompt")
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "print "))
        try await runAndWaitForOutput(store, "abc")
    }
}

@Test func zshIgnoresAnEditWhoseExpectedTextDoesNotMatch() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let real = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        let stale = TerminalLineEdit(startDelta: real.startDelta, endDelta: real.endDelta, expected: "chekcout")
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: stale, replacement: "switch"))
        try await runAndWaitForOutput(store, "git checkout main")
    }
}

@Test func zshBracketedPasteOfTwoLinesDoesNotRunBeforeEnter() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "")
        try await waitUntil(seconds: 5) { await store.bracketedPaste("t") }
        await store.write(paneId: "t", bytes: terminalPasteBytes("echo one\necho two", bracketed: true))
        try await waitUntil(seconds: 5) { await store.screenContains("t", "echo two") }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!(await store.screenLines("t").contains("one")), "nothing ran before Enter")
        try await runAndWaitForOutput(store, "two")
        #expect(await store.screenLines("t").contains("one"))
    }
}

@Test func macOSBash32NeverReportsLineEditSupport() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
                                 environment: ["HOME": scratchHome()])
        await store.write(paneId: "t", bytes: Array("echo wakil-ready\n".utf8))
        try await waitUntil(seconds: 10) {
            await store.marks("t").filter { $0 == .promptEnd }.count >= 2
        }
        #expect(!(await store.lineEditSupported("t")))
        #expect(await store.inputLine("t") == nil)
    }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/bash"),
               "needs Homebrew bash 4+"))
func homebrewBashReplacesTheSelectedWord() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/opt/homebrew/bin/bash", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let edit = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "switch"))
        try await runAndWaitForOutput(store, "git switch main")
    }
}
```

In `TerminalStoreTests.swift`, change `private func waitUntil(` to `func waitUntil(` and `private func scratchHome()` to `func scratchHome()`.

- [ ] **Step 2: Run to verify they fail**

Run: `../scripts/swift-test.sh --filter TerminalLineEditShellTests`
Expected: zsh tests FAIL with "condition did not hold within 10s" (no `WakilEdit` signal yet, so `inputLine` stays nil); the bash 3.2 test passes already (it's the guard against a future regression); the Homebrew test is skipped on a Mac without it.

- [ ] **Step 3: Implement**

In `zshRC`, in `__wakil_precmd`, right after `__wakil_osc "133;A"`:

```zsh
  # #365: tells the pane this prompt's shell has `__wakil_replace`.
  __wakil_osc "1337;WakilEdit=1"
```

and before `autoload -Uz add-zsh-hook`:

```zsh
# #365: editing a selection on the input line. The pane sends
#   ESC[999~ <startDelta>;<endDelta>;<b64 expected>;<b64 replacement> BEL
# with offsets relative to CURSOR (the screen cursor sits on BUFFER[CURSOR],
# so both sides agree on it). A selection that began in the prompt has a
# negative start: that many leading characters of `expected` are prompt and
# are dropped. Past the end of BUFFER (autosuggestion text is POSTDISPLAY,
# not BUFFER) is clamped off. Anything that then fails to match BUFFER is
# ignored, never guessed at.
__wakil_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; printf x }
__wakil_replace() {
  # The operator's rc may set KSH_ARRAYS, SH_WORD_SPLIT and friends.
  emulate -L zsh
  local payload= key
  while read -k 1 key; do
    [[ $key == $'\a' ]] && break
    payload+=$key
    (( ${#payload} > 1048576 )) && return 0
  done
  local -a f
  f=("${(@s:;:)payload}")
  (( ${#f} == 4 )) || return 0
  [[ $f[1] == (-|)<-> && $f[2] == (-|)<-> ]] || return 0
  local expected="$(__wakil_b64d "$f[3]")" repl="$(__wakil_b64d "$f[4]")"
  expected=${expected%x} repl=${repl%x}
  local start=$(( CURSOR + ${f[1]} )) end=$(( CURSOR + ${f[2]} ))
  if (( start < 0 )); then expected=${expected:$(( -start ))}; start=0; fi
  (( end > ${#BUFFER} )) && end=${#BUFFER}
  (( start < end )) || return 0
  expected=${expected:0:$(( end - start ))}
  [[ ${BUFFER:$start:$(( end - start ))} == "$expected" ]] || return 0
  BUFFER="${BUFFER:0:$start}${repl}${BUFFER:$end}"
  CURSOR=$(( start + ${#repl} ))
  zle -R
}
zle -N __wakil_replace
for __wakil_km in main emacs viins vicmd; do
  bindkey -M $__wakil_km '\e[999~' __wakil_replace
done
unset __wakil_km
```

In `bashRC`, before the `PROMPT_COMMAND=` line:

```bash
# #365: the same edit command as zsh's `__wakil_replace`, through
# READLINE_LINE / READLINE_POINT — bash 4 and later only. macOS's own
# /bin/bash is 3.2, has neither, gets no binding and never sends the signal.
__wakil_edit_supported=0
if (( ${BASH_VERSINFO[0]:-0} >= 4 )); then
  __wakil_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; printf x; }
  __wakil_replace() {
    local payload f1 f2 f3 f4 expected repl start end
    IFS= read -r -d $'\a' payload || return 0
    IFS=';' read -r f1 f2 f3 f4 <<< "$payload"
    [[ $f1 =~ ^-?[0-9]+$ && $f2 =~ ^-?[0-9]+$ ]] || return 0
    expected=$(__wakil_b64d "$f3"); expected=${expected%x}
    repl=$(__wakil_b64d "$f4"); repl=${repl%x}
    start=$(( READLINE_POINT + f1 )); end=$(( READLINE_POINT + f2 ))
    if (( start < 0 )); then expected=${expected:$(( -start ))}; start=0; fi
    (( end > ${#READLINE_LINE} )) && end=${#READLINE_LINE}
    (( start < end )) || return 0
    expected=${expected:0:$(( end - start ))}
    [[ "${READLINE_LINE:$start:$(( end - start ))}" == "$expected" ]] || return 0
    READLINE_LINE="${READLINE_LINE:0:$start}${repl}${READLINE_LINE:$end}"
    READLINE_POINT=$(( start + ${#repl} ))
  }
  bind -x '"\e[999~": __wakil_replace'
  __wakil_edit_supported=1
fi
```

and in `__wakil_after_precmd`, after `__wakil_osc "133;A"`:

```bash
  [ "$__wakil_edit_supported" = "1" ] && __wakil_osc "1337;WakilEdit=1"
```

In the Swift doc comment above `generatedRC` ("**What each mark does here:**"), add a bullet after OSC 7:

```swift
/// - OSC 1337 `WakilEdit=1` — this prompt's shell has `__wakil_replace`, the
///   edit command a selection on the input line is sent to (#365). Every
///   prompt, after `A`; bash 3.2 never sends it.
```

- [ ] **Step 4: Run to verify they pass**

Run: `../scripts/swift-test.sh --filter "TerminalLineEditShellTests|TerminalStoreTests"`
Expected: the four zsh tests and the bash 3.2 test pass; the Homebrew test is skipped unless `/opt/homebrew/bin/bash` exists; `TerminalStoreTests` unchanged. If `read -k` inside the widget does not see the payload (zsh test 1 times out with the line unchanged), report it as BLOCKED with the screen lines — do not switch mechanisms without the controller.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Terminal/ShellIntegration.swift app/Tests/WakilKitTests/TerminalStoreTests.swift app/Tests/WakilKitTests/TerminalLineEditShellTests.swift
git commit -m "Shell integration: __wakil_replace edits the input line on request (#365)"
```

---

### Task 5: What a key does

**Files:**
- Modify: `app/Sources/WakilKit/Terminal/TerminalPaneSupport.swift` (`TerminalKeyModifiers` ~line 535, `TerminalPaneKeyClaim` ~line 674, `terminalPaneKeyClaim` ~line 700)
- Test: `app/Tests/WakilKitTests/TerminalPaneSupportTests.swift` (append)

**Interfaces:**
- Produces: `TerminalKeyModifiers.shift`; `TerminalPaneKeyClaim.paste`, `.copySelection`, `.replaceSelection(String)`, `.extendSelection(Int)`; `terminalPaneKeyClaim(..., selectionActive: Bool = false, lineEditEnabled: Bool = false)`.

- [ ] **Step 1: Write the failing tests**

```swift
private func claim(
    _ characters: String?, special: TerminalSpecialKey? = nil, modifiers: TerminalKeyModifiers = [],
    selection: Bool = false, editable: Bool = true, proposal: Bool = false
) -> TerminalPaneKeyClaim? {
    terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: proposal, characters: characters,
        special: special, modifiers: modifiers, selectionActive: selection, lineEditEnabled: editable)
}

@Test func commandVPastesWithOrWithoutASelectionAndWhileAProgramRuns() {
    #expect(claim("v", modifiers: .command) == .paste)
    #expect(claim("v", modifiers: .command, selection: true) == .paste)
    #expect(claim("v", modifiers: .command, editable: false) == .paste)
}

@Test func commandVIsTheSearchFieldsWhileSearchIsOpen() {
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: false, characters: "v",
        special: nil, modifiers: .command, selectionActive: true, lineEditEnabled: true) == .notClaimed)
}

@Test func commandCCopiesOnlyAPaneSelection() {
    #expect(claim("c", modifiers: .command, selection: true) == .copySelection)
    #expect(claim("c", modifiers: .command) == .notClaimed, "output selection's ⌘C stays the menu's")
}

@Test func typingOverASelectionReplacesIt() {
    #expect(claim("x", selection: true) == .replaceSelection("x"))
    #expect(claim(" ", selection: true) == .replaceSelection(" "))
    #expect(claim("é", selection: true) == .replaceSelection("é"))
}

@Test func backspaceAndDeleteRemoveASelection() {
    #expect(claim("\u{7F}", selection: true) == .replaceSelection(""))
    #expect(claim(nil, special: .deleteForward, selection: true) == .replaceSelection(""))
}

@Test func withoutASelectionKeysReachThePtyAsBefore() {
    #expect(claim("x") == .forwardToPty(Array("x".utf8)))
    #expect(claim("\u{7F}") == .forwardToPty([0x7F]))
}

@Test func aSelectionIsInertWhenTheLineIsNotEditable() {
    #expect(claim("x", selection: true, editable: false) == .forwardToPty(Array("x".utf8)))
}

@Test func controlKeysReturnAndArrowsReachThePtyEvenWithASelection() {
    #expect(claim("c", modifiers: .control, selection: true) == .forwardToPty([0x03]))
    #expect(claim("\r", selection: true) == .forwardToPty([0x0D]))
    #expect(claim("\t", selection: true) == .forwardToPty([0x09]))
    #expect(claim(nil, special: .left, selection: true) == .forwardToPty(Array("\u{1B}[D".utf8)))
}

@Test func shiftArrowsExtendTheSelectionOnlyWhenEditable() {
    #expect(claim(nil, special: .left, modifiers: .shift) == .extendSelection(-1))
    #expect(claim(nil, special: .right, modifiers: .shift) == .extendSelection(1))
    #expect(claim(nil, special: .left, modifiers: .shift, editable: false) == .forwardToPty(Array("\u{1B}[D".utf8)))
}

@Test func aPendingProposalStillOwnsReturnAndBackspace() {
    #expect(claim("\r", selection: true, proposal: true) == .acceptProposal)
    #expect(claim("\u{7F}", selection: true, proposal: true) == .discardProposal)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `../scripts/swift-test.sh --filter TerminalPaneSupportTests`
Expected: compile failure — extra arguments `selectionActive`.

- [ ] **Step 3: Implement**

In `TerminalKeyModifiers`, after `command`:

```swift
    /// ⇧ — read only for ⇧← / ⇧→ on an editable input line (#365);
    /// `terminalKeyBytes` ignores it, so every other key is unchanged.
    public static let shift = TerminalKeyModifiers(rawValue: 1 << 2)
```

In `TerminalPaneKeyClaim`, after `forwardToPty`:

```swift
    /// ⌘V: read the pasteboard; replace the selection with it when the line
    /// is editable and one is active, else paste it (#365).
    case paste
    /// ⌘C over the pane's own input-line selection.
    case copySelection
    /// A printable character (the character), or Backspace / Delete (the
    /// empty string), typed over the selection.
    case replaceSelection(String)
    /// ⇧← (-1) / ⇧→ (+1).
    case extendSelection(Int)
```

Change the signature to:

```swift
public func terminalPaneKeyClaim(
    isKeyboardOwner: Bool, searchOpen: Bool, hasPendingProposal: Bool, characters: String?,
    special: TerminalSpecialKey?, modifiers: TerminalKeyModifiers,
    selectionActive: Bool = false, lineEditEnabled: Bool = false
) -> TerminalPaneKeyClaim? {
```

and insert between the proposal block and the final `guard let bytes = terminalKeyBytes(...)`:

```swift
    // #365. After the proposal, so ⏎ and ⌫ still accept and discard one.
    if modifiers.contains(.command) {
        switch characters?.lowercased() {
        case "v": return .paste
        case "c" where selectionActive: return .copySelection
        default: break
        }
    }
    let plain = !modifiers.contains(.command) && !modifiers.contains(.control)
    if lineEditEnabled, plain, modifiers.contains(.shift) {
        if special == .left { return .extendSelection(-1) }
        if special == .right { return .extendSelection(1) }
    }
    if lineEditEnabled, selectionActive, plain {
        if special == .deleteForward { return .replaceSelection("") }
        if special == nil, let characters {
            if characters == "\u{7F}" || characters == "\u{8}" { return .replaceSelection("") }
            // Printable only: ⏎, ⇥, ⎋ and every C0 byte are below 0x20 and
            // reach zsh, which clears the selection in the pane.
            if let scalar = characters.unicodeScalars.first, scalar.value >= 0x20 {
                return .replaceSelection(characters)
            }
        }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `../scripts/swift-test.sh --filter TerminalPaneSupportTests`
Expected: all pass, the pre-existing claim tests included.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Terminal/TerminalPaneSupport.swift app/Tests/WakilKitTests/TerminalPaneSupportTests.swift
git commit -m "Terminal: key claims for paste, copy and editing a selection (#365)"
```

---

### Task 6: The pane

`WakilApp` has no test target; this task is verified by building and, at the Cover rung, by the e2e auditor.

**Files:**
- Modify: `app/Sources/WakilApp/TerminalPane.swift` — `@State` block (~line 140), `handleKeyPress` (~line 630), the `BlockHistory(...)` call (~line 348), `BlockHistory`'s properties (~line 900), `liveRegion()` (~line 1020), a new `SelectionMark` beside `CursorMark` (~line 861).

**Interfaces:**
- Consumes: everything above; `snapshot.inputLine`, `snapshot.bracketedPaste`; `liveRegionSlice.startRow`.

- [ ] **Step 1: State and key handling in `TerminalPane`**

Add with the other `@State`s:

```swift
    /// The pane's own selection over the live region (#365) — SwiftUI's
    /// `.textSelection` cannot be read back, so a selection the shell must
    /// act on has to be the pane's.
    @State private var selection: TerminalGridRange?
```

In `handleKeyPress`, add `if press.modifiers.contains(.shift) { modifiers.insert(.shift) }` beside the other two modifier lines; pass `selectionActive: selection != nil, lineEditEnabled: snapshot.inputLine != nil` as the last two arguments of `terminalPaneKeyClaim(...)`; change `case .forwardToPty(let bytes): send(bytes)` to:

```swift
        case .forwardToPty(let bytes):
            selection = nil
            send(bytes)
        case .paste:
            paste()
        case .copySelection:
            copySelection()
        case .replaceSelection(let text):
            replaceSelection(with: text)
        case .extendSelection(let step):
            if let line = snapshot.inputLine {
                selection = terminalExtendSelection(selection, by: step, line: line)
            }
```

Add beside `sendAndFocus`:

```swift
    /// The edit the current selection asks for, when the line is editable.
    private var selectionEdit: TerminalLineEdit? {
        guard let selection, let line = snapshot.inputLine else { return nil }
        return terminalLineEdit(selection: selection, line: line)
    }

    private func replaceSelection(with text: String) {
        if let edit = selectionEdit { send(terminalReplaceBytes(edit: edit, replacement: text)) }
        selection = nil
    }

    /// ⌘V. An empty or non-text pasteboard does nothing.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if selectionEdit != nil {
            replaceSelection(with: text.replacingOccurrences(of: "\r\n", with: "\n"))
        } else {
            selection = nil
            send(terminalPasteBytes(text, bracketed: snapshot.bracketedPaste))
        }
    }

    private func copySelection() {
        guard let selection else { return }
        let rows = liveRegionRows.map(terminalRowPlainText)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            terminalSelectedText(selection, rows: rows, startRow: liveRegionSlice.startRow), forType: .string)
    }
```

Change `sendAndFocus` to clear the selection first (`selection = nil` before `send(bytes)`).

On the view that already carries `.onKeyPress(phases: .down, action: handleKeyPress)`, add:

```swift
        // New output that moves the prompt makes the selection's cells stale.
        .onChange(of: snapshot.promptRow) { _, _ in selection = nil }
```

- [ ] **Step 2: Pass the selection into `BlockHistory`**

Add to `BlockHistory`'s properties after `cursor`:

```swift
    let liveStartRow: Int
    let inputLine: TerminalInputLine?
    @Binding var selection: TerminalGridRange?
```

and to the `BlockHistory(...)` call after `cursor: liveRegionCursor,`:

```swift
                        liveStartRow: liveRegionSlice.startRow,
                        inputLine: snapshot.inputLine,
                        selection: $selection,
```

- [ ] **Step 3: The live region's own selection**

In `liveRegion()`, on each row's `Text` (beside the existing `CursorMark` overlay), add a second overlay:

```swift
                                .overlay(alignment: .leading) {
                                    if let selection, let columns = terminalSelectionColumns(
                                        selection, row: liveStartRow + index,
                                        columnCount: terminalRowPlainText(liveRows[index]).count) {
                                        SelectionMark(columns: columns)
                                    }
                                }
```

Replace the `VStack`'s `.textSelection(.enabled)` with:

```swift
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                selection = TerminalGridRange(
                                    anchor: gridPoint(drag.startLocation), head: gridPoint(drag.location))
                            })
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { tap in
                                selection = inputLine.flatMap {
                                    terminalWordSelection(at: gridPoint(tap.location), line: $0)
                                }
                            }
                            .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in selection = nil }))
```

and add to `BlockHistory`:

```swift
    /// A point in the live region's rows to a screen cell. Cells are
    /// monospaced, so this is division — `reportSize`'s own arithmetic.
    private func gridPoint(_ location: CGPoint) -> TerminalGridPoint {
        TerminalGridPoint(
            row: liveStartRow + max(0, Int(location.y / TerminalPane.cellSize.height)),
            col: max(0, Int(location.x / TerminalPane.cellSize.width)))
    }
```

Add beside `CursorMark`:

```swift
/// The input-line selection on one row (#365): one rectangle per row, like
/// `CursorMark` — never a view per cell.
private struct SelectionMark: View {
    let columns: Range<Int>

    var body: some View {
        Rectangle()
            .fill(TerminalPane.text.opacity(0.22))
            .frame(width: TerminalPane.cellSize.width * CGFloat(columns.count), height: 15)
            .offset(x: TerminalPane.cellSize.width * CGFloat(columns.lowerBound))
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 4: Build**

Run (repo root): `make app-build`
Expected: builds with no new warnings in `TerminalPane.swift`. Fix any compile error the build names in this file only (for example `terminalRowPlainText` visibility — it is `public` in `TerminalPaneSupport.swift`).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/TerminalPane.swift
git commit -m "Terminal pane: ⌘V, and a selection on the input line you can type over (#365)"
```

---

### Task 7: Whole-suite gate (controller only)

- [ ] **Step 1:** `make build` (memory: `make app-test` runs against whatever `bin/` holds).
- [ ] **Step 2:** `make app-test` in the background; read `.context/app-test.log` for the summary. Expected: green apart from the known flakes (#344-class load flakes — rerun a failure once alone before calling it a defect).
- [ ] **Step 3:** `make test` for `docs-check`.
- [ ] **Step 4:** Commit nothing new unless a step fixed something; then the Cover rung: the e2e auditor (`docs/agents/e2e.md`) on this branch — **ask the operator and peer sessions before any GUI run** (memory: shared GUI). Its checks: ⌘V at the prompt; a two-line paste that does not run; drag-select a word and type; select and Backspace; double-click a word and ⌘V; a selection over output stays copy-only.
