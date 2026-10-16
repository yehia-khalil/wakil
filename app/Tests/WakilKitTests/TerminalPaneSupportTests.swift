import Foundation
import Testing
@testable import WakilKit

/// Task 16's drawing code has no test target of its own — that is the
/// whole reason every calculation it needs was pushed down into
/// `TerminalPaneSupport.swift` rather than written inline in
/// `TerminalPane.swift`. This file is where that move actually pays off:
/// grid sizing, mirrored-block grouping, elapsed time, ⌘F's block-counted
/// search, the backfill marker, and the key→byte mapping that makes `^C`
/// reach the foreground process group, all asserted here rather than only
/// walked on screen.
private func block(
    id: String, command: String = "ls", origin: TerminalBlockOrigin = .operatorTyped,
    exitCode: Int? = 0, output: [String] = [], startedAt: Date = Date()
) -> TerminalBlock {
    TerminalBlock(
        id: id, command: command, origin: origin, exitCode: exitCode, durationMs: exitCode == nil ? nil : 1,
        output: output, heldTheGrid: false, startedAt: startedAt)
}

// MARK: - Grid sizing

@Test func gridSizeFloorsToWholeCells() {
    // 4 cells' worth of width plus a bit under a fifth: the fractional
    // remainder must not round up to a cell the pty does not actually have
    // room to draw.
    let (cols, rows) = terminalGridSize(width: 4.9 * 8, height: 3.9 * 15, cellWidth: 8, cellHeight: 15)
    #expect(cols == 4)
    #expect(rows == 3)
}

@Test func gridSizeNeverGoesBelowOneCell() {
    // A pane mid-resize, or one that has not laid out yet, can report a
    // width or height of zero for a frame or two. `TIOCSWINSZ` with a zero
    // dimension is not a size any program recovers from cleanly, so this
    // is floored rather than passed through.
    #expect(terminalGridSize(width: 0, height: 0, cellWidth: 8, cellHeight: 15) == (1, 1))
    #expect(terminalGridSize(width: 3, height: 3, cellWidth: 8, cellHeight: 15) == (1, 1))
}

@Test func gridSizeIsUnchangedWithinTheSameCellBoundary() {
    // A resize that does not cross a full cell's width must answer the
    // same cols/rows — this is the property the view's own de-dupe (never
    // re-issuing an identical `TIOCSWINSZ`) depends on being true of the
    // arithmetic, not just of the caller's guard.
    let a = terminalGridSize(width: 640, height: 450, cellWidth: 8, cellHeight: 15)
    let b = terminalGridSize(width: 645, height: 452, cellWidth: 8, cellHeight: 15)
    #expect(a == b)
    #expect(a == (80, 30))
}

@Test func gridSizeDegradesToOneCellRatherThanDividingByZero() {
    #expect(terminalGridSize(width: 640, height: 450, cellWidth: 0, cellHeight: 15) == (1, 1))
    #expect(terminalGridSize(width: 640, height: 450, cellWidth: 8, cellHeight: 0) == (1, 1))
}

// MARK: - Mirrored-block grouping

@Test func consecutiveMirroredBlocksCollapseIntoOneGroup() {
    let blocks = [
        block(id: "a1", origin: .agent), block(id: "a2", origin: .agent),
        block(id: "a3", origin: .agent),
    ]
    let items = groupedTerminalHistory(blocks)
    #expect(items.count == 1)
    guard case .mirroredGroup(let grouped) = items[0] else {
        Issue.record("expected a mirroredGroup")
        return
    }
    #expect(grouped.map(\.id) == ["a1", "a2", "a3"])
}

@Test func anOperatorBlockBetweenTwoAgentBlocksBreaksTheGroup() {
    // The property grouping exists for: an operator's own command in the
    // middle of the agent's run must not be swallowed into "the agent did
    // this", and the agent's two runs either side must not be silently
    // stitched into one turn they were not part of.
    let blocks = [
        block(id: "a1", origin: .agent),
        block(id: "op", origin: .operatorTyped),
        block(id: "a2", origin: .agent),
    ]
    let items = groupedTerminalHistory(blocks)
    #expect(items.count == 3)
    #expect(items[0] == .block(blocks[0]))
    #expect(items[1] == .block(blocks[1]))
    #expect(items[2] == .block(blocks[2]))
}

@Test func aLoneMirroredBlockStaysUngrouped() {
    // Folding a single agent command into a "group" the operator has to
    // expand to read is worse than just showing it — collapsing exists to
    // save space from several blocks, not to add a click to one.
    let blocks = [block(id: "a1", origin: .agent)]
    #expect(groupedTerminalHistory(blocks) == [.block(blocks[0])])
}

@Test func aProposalNeverJoinsAMirroredGroupEvenAdjacentToOne() {
    let blocks = [
        block(id: "a1", origin: .agent),
        block(id: "a2", origin: .agent),
        block(id: "proposal", origin: .proposed),
    ]
    let items = groupedTerminalHistory(blocks)
    #expect(items.count == 2)
    guard case .mirroredGroup(let grouped) = items[0] else {
        Issue.record("expected a mirroredGroup")
        return
    }
    #expect(grouped.map(\.id) == ["a1", "a2"])
    #expect(items[1] == .block(blocks[2]))
}

// MARK: - Elapsed time

@Test func elapsedSecondsIsComputedFromStartedAtNotFromDurationMs() {
    // `durationMs` is `nil` for a still-running mirrored block, by design
    // — HarnessEvent carries no wall-clock. A running chip that read that
    // `nil` as zero would show "0s" forever no matter how long the
    // command actually ran; this asserts the real computation is used
    // instead.
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_700_000_042)
    #expect(terminalElapsedSeconds(startedAt: startedAt, now: now) == 42)
}

@Test func elapsedSecondsNeverGoesNegative() {
    // A block whose `startedAt` is momentarily after `now` — a clock
    // adjustment, or the first tick before `now` has caught up — must
    // read 0, not a negative elapsed time.
    let startedAt = Date(timeIntervalSince1970: 1_700_000_010)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(terminalElapsedSeconds(startedAt: startedAt, now: now) == 0)
}

// MARK: - The backfill marker

@Test func blocksAtOrBeforeTheMarkerAreBackfilledBlocksAfterAreNot() {
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let marker = Date(timeIntervalSince1970: 1_700_000_500)
    let late = Date(timeIntervalSince1970: 1_700_001_000)

    let replayed = block(id: "replayed", origin: .agent, startedAt: early)
    let onTheMarker = block(id: "on-marker", origin: .agent, startedAt: marker)
    let streamed = block(id: "streamed", origin: .agent, startedAt: late)

    #expect(isBackfilledTerminalBlock(replayed, backfilledAt: marker))
    #expect(isBackfilledTerminalBlock(onTheMarker, backfilledAt: marker))
    #expect(!isBackfilledTerminalBlock(streamed, backfilledAt: marker))
}

@Test func aNilMarkerMeansNothingIsBackfilled() {
    // A pane whose mirror has never been backfilled (no agent activity
    // retained when it opened) must not have its first live block read
    // as history the instant one arrives.
    let live = block(id: "live", origin: .agent, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(!isBackfilledTerminalBlock(live, backfilledAt: nil))
}

@Test func theSnapshotCarriesTheMarkerAtTheSnapshotLevelNotPerBlock() {
    // `TerminalBlock`'s seven published keys are the spec's own fixed
    // shape for one command; the marker lives on `TerminalSnapshot`
    // instead, once per pane, which this asserts by round-tripping it
    // through the type rather than by reading source.
    let marker = Date(timeIntervalSince1970: 1_700_000_500)
    let snapshot = TerminalSnapshot(
        screen: .blocks, cwd: "/tmp", shell: "/bin/zsh", cols: 80, rows: 24,
        blocks: [], blocksTruncated: false, grid: [], scrollTarget: nil, backfilledAt: marker)
    #expect(snapshot.backfilledAt == marker)
    #expect(TerminalSnapshot.empty.backfilledAt == nil)
}

// MARK: - ⌘F, counted in blocks

@Test func aTermAppearingThreeTimesInOneBlockCountsAsOneBlock() {
    // The whole distinction ⌘F exists to draw: "which command", never
    // "which line" — three hits inside one block's output are one match,
    // not three.
    let noisy = block(id: "b1", command: "grep TODO", output: ["TODO: a", "TODO: b", "TODO: c"])
    let ids = matchingTerminalBlockIds([noisy], query: "TODO")
    #expect(ids == ["b1"])
}

@Test func searchMatchesTheCommandTextToo() {
    let match = block(id: "b1", command: "grep TODO src/")
    let miss = block(id: "b2", command: "ls")
    let ids = matchingTerminalBlockIds([match, miss], query: "TODO")
    #expect(ids == ["b1"])
}

@Test func searchSummaryCountsBlocksNotLines() {
    let text = terminalSearchSummary(totalBlocks: 4, matchingBlocks: 3, hasQuery: true)
    #expect(text == "3 blocks · 1 block hidden")
}

@Test func searchSummaryIsEmptyWithNoActiveQuery() {
    #expect(terminalSearchSummary(totalBlocks: 4, matchingBlocks: 0, hasQuery: false).isEmpty)
}

@Test func searchSummarySaysNoMatchRatherThanZeroBlocks() {
    #expect(terminalSearchSummary(totalBlocks: 4, matchingBlocks: 0, hasQuery: true) == "no match")
}

// MARK: - Structured output, the `ls` allowlist entry

@Test func aBareLsIsRecognisedAsAFileList() {
    let result = structuredOutput(command: "ls", output: ["a.txt", "b.txt"])
    #expect(result == .fileList(["a.txt", "b.txt"]))
}

@Test func anyOtherCommandDegradesToPlainTextNil() {
    #expect(structuredOutput(command: "ls -la", output: ["total 8", "a.txt"]) == nil)
    #expect(structuredOutput(command: "cat file.txt", output: ["hello"]) == nil)
}

/// **`ls -l` is refused deliberately** (walk defect D2's second half): the
/// allowlist keys on the command's first word and has one modelled shape,
/// bare `ls`'s. `ls -l` is a different shape this asserts stays `nil` —
/// plain text — rather than either crashing or, worse, silently reading
/// `-rw-r--r--  1 op  staff  12 Jan  1 00:00 a.txt` as though "a.txt" were
/// the only thing on the line.
@Test func lsWithFlagsIsRefusedDeliberatelyNotByAccident() {
    #expect(structuredOutput(
        command: "ls -l", output: ["-rw-r--r--  1 op  staff  12 Jan  1 00:00 a.txt"]) == nil)
}

/// Walk defect D2: `events.db src` — two real files — drew THREE `Open`
/// buttons. The captured output for that session was the two names plus a
/// trailing blank row the capture pads with; the old filter
/// (`!$0.isEmpty`) already dropped the blank one, so this pins that the
/// count is still exactly two names, not three or one.
@Test func aTrailingBlankRowIsNotCountedAsAFile() {
    let result = structuredOutput(command: "ls", output: ["events.db", "src", ""])
    #expect(result == .fileList(["events.db", "src"]))
}

/// The other suspect walk-defects.md names for the same miscount: zsh's
/// own `%` marker for a command whose output did not end in a newline.
/// `ls` never prints a bare `%`, so dropping a row that trims to exactly
/// that is safe and is what brings the count back to the real file count.
@Test func theShellsBareLoneMarkerIsNotCountedAsAFile() {
    let result = structuredOutput(command: "ls", output: ["events.db", "src", "%"])
    #expect(result == .fileList(["events.db", "src"]))
}

/// A row with incidental leading/trailing whitespace (the raw grid can
/// carry padding) still resolves to the plain file name — this is also
/// what keeps a drawn `Open` button anchored to the right name rather than
/// showing "  a.txt" as a mismatched label.
@Test func fileNamesAreTrimmedOfIncidentalWhitespace() {
    let result = structuredOutput(command: "ls", output: ["  a.txt  ", "b.txt"])
    #expect(result == .fileList(["a.txt", "b.txt"]))
}

/// A screen holding only the blank row and the shell's marker — no real
/// files at all — degrades to plain text (`nil`) exactly as genuinely
/// empty output already does, rather than drawing an empty structured
/// list.
@Test func onlyMarkerAndBlankRowsYieldsNilNotAnEmptyList() {
    #expect(structuredOutput(command: "ls", output: ["", "%"]) == nil)
}

// MARK: - Keystrokes: what makes `^C` reach the foreground process group

@Test func controlCIsTheStandardControlByteWhetherOrNotTheCallerPreTranslatedIt() {
    // The standard terminal convention: Control clears bits 6 and 7 of the
    // ASCII value, so `^C` is the single byte 0x03 — the signal `SIGINT`
    // is generated from at the tty driver. Asserted both ways: as if the
    // caller's framework had already translated 'c' to the control byte
    // (AppKit's own documented behaviour), and as if it handed back the
    // plain letter with the modifier flag set instead.
    let alreadyTranslated = terminalKeyBytes(
        characters: "\u{03}", special: nil, modifiers: [.control])
    let plainLetterWithModifier = terminalKeyBytes(
        characters: "c", special: nil, modifiers: [.control])
    #expect(alreadyTranslated == [0x03])
    #expect(plainLetterWithModifier == [0x03])
}

@Test func controlRAndControlDAreTheirOwnControlBytes() {
    #expect(terminalKeyBytes(characters: "r", special: nil, modifiers: [.control]) == [0x12])
    #expect(terminalKeyBytes(characters: "d", special: nil, modifiers: [.control]) == [0x04])
}

@Test func commandAnythingIsNeverForwardedToThePty() {
    // A ⌘-combination is this window's own shortcut table before it is
    // ever a keystroke a shell could want; letting one fall through on a
    // miss would run a stray control character in the operator's own
    // shell instead of doing nothing.
    #expect(terminalKeyBytes(characters: "k", special: nil, modifiers: [.command]) == nil)
    #expect(terminalKeyBytes(characters: "c", special: nil, modifiers: [.control, .command]) == nil)
}

@Test func plainCharactersPassThroughUnaltered() {
    #expect(terminalKeyBytes(characters: "a", special: nil, modifiers: []) == Array("a".utf8))
}

@Test func specialKeysTranslateToTheirAnsiSequenceRatherThanPassingThroughCharacters() {
    #expect(terminalKeyBytes(characters: nil, special: .up, modifiers: []) == Array("\u{1B}[A".utf8))
    #expect(terminalKeyBytes(characters: nil, special: .down, modifiers: []) == Array("\u{1B}[B".utf8))
    #expect(terminalKeyBytes(characters: nil, special: .left, modifiers: []) == Array("\u{1B}[D".utf8))
    #expect(terminalKeyBytes(characters: nil, special: .right, modifiers: []) == Array("\u{1B}[C".utf8))
}

@Test func noCharactersAndNoSpecialKeyForwardsNothing() {
    #expect(terminalKeyBytes(characters: nil, special: nil, modifiers: []) == nil)
    #expect(terminalKeyBytes(characters: "", special: nil, modifiers: []) == nil)
}

// MARK: - The live region (final review, Critical 2)

/// The blocks surface's live region: the prompt, what is being typed into
/// it, and a running command's output — trimmed out of a screen that is
/// mostly blank.
///
/// Until the final fix wave there was no live region at all: the block
/// history was drawn alone under a static grey "live prompt" label, so the
/// operator typed blind.
@Test func theLiveRegionIsTheScreensLiveTextWithoutItsBlankRemainder() {
    var screen = ["$ npm install", "added 412 packages", "$ "]
    screen.append(contentsOf: Array(repeating: "", count: 21))

    #expect(terminalLiveRegion(grid: screen) == ["$ npm install", "added 412 packages", "$ "])
}

/// A screen with nothing on it yields nothing — the caller draws its
/// "waiting for the shell" line rather than an empty box.
@Test func anEmptyScreenHasNoLiveRegion() {
    #expect(terminalLiveRegion(grid: Array(repeating: "", count: 24)).isEmpty)
    #expect(terminalLiveRegion(grid: []).isEmpty)
    #expect(terminalLiveRegion(grid: ["  ", "\t"]).isEmpty)
}

/// **Capped, and capped from the END.** A command mid-flight can fill the
/// whole visible screen, and the live region is a foot to the history, not
/// a second history — so what survives is the most recent rows, which is
/// where the prompt is.
@Test func theLiveRegionKeepsTheLastRowsNotTheFirst() {
    let screen = (1...20).map { "line \($0)" }

    let region = terminalLiveRegion(grid: screen, maxRows: 3)

    #expect(region == ["line 18", "line 19", "line 20"])
}

/// Blank rows BETWEEN live rows are kept: a command that printed a blank
/// line printed it, and the live region is a view of the screen rather
/// than a reflow of it.
@Test func theLiveRegionKeepsABlankLineThatTheOutputItselfPrinted() {
    let screen = ["$ printf 'a\\n\\nb\\n'", "a", "", "b", "$ ", "", ""]

    #expect(terminalLiveRegion(grid: screen) == ["$ printf 'a\\n\\nb\\n'", "a", "", "b", "$ "])
}

// MARK: - The live region's promptRow slice (walk defect C2)

/// Walk defect C2: taking the tail of the WHOLE screen still holds every
/// command that has not scrolled off, so the operator saw each one twice
/// — once as a structured block, once raw underneath. With `promptRow`
/// naming the row the current prompt actually started on, only the
/// current prompt (and whatever follows it) is drawn, never a finished
/// command's own rows sitting above that row.
@Test func withAPromptRowOnlyRowsAtOrAfterItAreLive() {
    let screen = ["$ npm install", "added 412 packages", "$ echo hi", "hi", "$ "]

    // The prompt now on screen started at row 2 ("$ echo hi"); rows 0-1
    // are a FINISHED command's own output, which the block history
    // already drew — the whole bug this closes.
    #expect(terminalLiveRegion(grid: screen, promptRow: 2) == ["$ echo hi", "hi", "$ "])
}

/// With no `promptRow` at all, behaviour is unchanged from before this
/// fix — the tail-of-the-whole-screen heuristic — so a snapshot published
/// before the seam is wired (or a build that predates it) draws SOMETHING
/// rather than nothing.
@Test func withNoPromptRowTheOldWholeScreenHeuristicStillApplies() {
    var screen = ["$ npm install", "added 412 packages", "$ "]
    screen.append(contentsOf: Array(repeating: "", count: 21))

    #expect(terminalLiveRegion(grid: screen, promptRow: nil)
        == ["$ npm install", "added 412 packages", "$ "])
}

/// An out-of-range `promptRow` — stale against a screen that has since
/// shrunk, or a bookkeeping bug on the other side of the seam — falls back
/// to the old heuristic rather than crashing or returning an empty region
/// for a screen that plainly has text on it.
@Test func anOutOfRangePromptRowFallsBackRatherThanCrashing() {
    let screen = ["$ echo hi", "hi", "$ "]
    #expect(terminalLiveRegion(grid: screen, promptRow: 99) == ["$ echo hi", "hi", "$ "])
    #expect(terminalLiveRegion(grid: screen, promptRow: -1) == ["$ echo hi", "hi", "$ "])
}

/// The cap and the blank-trimming still apply after the `promptRow` slice
/// — this is a narrower STARTING point for the same trim, not a second,
/// unrelated code path.
@Test func aPromptRowSliceIsStillCappedAndTrimmedTheSameWay() {
    var screen = ["$ finished command", "output"]
    screen.append(contentsOf: (1...20).map { "line \($0)" })

    let region = terminalLiveRegion(grid: screen, maxRows: 3, promptRow: 2)

    #expect(region == ["line 18", "line 19", "line 20"])
}

// MARK: - The styled live-region slice agrees with the plain one (colour defect)

/// `1fe96d1` wired colour into the block history and the full-screen grid
/// but never into the live region — `TerminalPane.liveRegionSlice` kept
/// slicing `snapshot.grid` (plain), so the surface a full-screen-free TUI
/// draws its whole interface on discarded every colour it emitted.
/// `terminalLiveRegionSlice(gridStyles:)` is now the real implementation
/// and `terminalLiveRegionSlice(grid:)` reads its result back out as
/// text, so the two cannot drift: row for row, and on `startRow`, which
/// is what `terminalCursorLocation` places the cursor against.
@Test func theStyledSliceAgreesWithThePlainSliceRowForRowAndOnStartRow() {
    let screen = ["$ npm install", "added 412 packages", "", "$ echo hi", "hi", "$ ", "", ""]
    let styled: [[TerminalStyleRun]] = screen.map { [TerminalStyleRun(text: $0, style: .plain)] }

    for promptRow: Int? in [nil, 0, 3, 99, -1] {
        let plainSlice = terminalLiveRegionSlice(grid: screen, promptRow: promptRow)
        let styledSlice = terminalLiveRegionSlice(gridStyles: styled, promptRow: promptRow)
        #expect(styledSlice.rows.map(terminalRowPlainText) == plainSlice.rows)
        #expect(styledSlice.startRow == plainSlice.startRow)
    }
}

/// A row whose text is coloured whitespace is still blank for trimming —
/// colouring a blank line does not make it text, so the check has to read
/// the row's CONCATENATED text, not any one run in isolation (a row split
/// across a coloured run and a plain one, neither alone equal to the
/// whole row's text, is exactly the case a per-run check could miss).
@Test func aStyledRowOfAllWhitespaceRunsCountsAsBlankForTrimming() {
    let red = TerminalCellStyle(foreground: RGB(1, 0, 0))
    let styled: [[TerminalStyleRun]] = [
        [TerminalStyleRun(text: "$ echo hi", style: .plain)],
        [TerminalStyleRun(text: "hi", style: .plain)],
        // Blank, but split across two runs — one coloured, one not —
        // rather than one plain run, so trimming that inspected only the
        // first or only the last run could wrongly keep or drop it.
        [TerminalStyleRun(text: "  ", style: red), TerminalStyleRun(text: "  ", style: .plain)],
    ]

    let slice = terminalLiveRegionSlice(gridStyles: styled)

    #expect(slice.rows.map(terminalRowPlainText) == ["$ echo hi", "hi"])
}

/// A row of one plain run — `terminalCoalesceStyleRuns`' own common case,
/// and what every caller with no colour to thread through
/// (`terminalLiveRegionSlice(grid:)`, and every test above it in this
/// file) already builds — draws exactly the text that row held before
/// this pair existed.
@Test func aRowOfOnePlainRunIsUnchangedFromToday() {
    let screen = ["$ echo hi", "hi", "$ "]

    let plain = terminalLiveRegionSlice(grid: screen)
    let styled = terminalLiveRegionSlice(
        gridStyles: screen.map { [TerminalStyleRun(text: $0, style: .plain)] })

    #expect(styled.rows.map(terminalRowPlainText) == plain.rows)
    #expect(styled.startRow == plain.startRow)
}

/// The cursor still lands where it did: fed the styled slice's own
/// `startRow`/row count instead of the plain slice's, `terminalCursorLocation`
/// answers the identical position — the two slices agree on `startRow`
/// (asserted above), so anything downstream that only reads `startRow`
/// and a row count, as the cursor placement does, cannot land differently
/// through one slice than through the other.
@Test func theCursorLandsInTheSameRowThroughTheStyledSliceAsThePlainOne() {
    let screen = ["$ ls", "events.db src", "$ pwd", "/Users/operator", "$ "]
    let styled: [[TerminalStyleRun]] = screen.map { [TerminalStyleRun(text: $0, style: .plain)] }

    let plainSlice = terminalLiveRegionSlice(grid: screen, promptRow: 4)
    let styledSlice = terminalLiveRegionSlice(gridStyles: styled, promptRow: 4)

    let plainCursor = terminalCursorLocation(
        cursorRow: 4, cursorCol: 2, liveRegionStartRow: plainSlice.startRow,
        liveRegionRowCount: plainSlice.rows.count)
    let styledCursor = terminalCursorLocation(
        cursorRow: 4, cursorCol: 2, liveRegionStartRow: styledSlice.startRow,
        liveRegionRowCount: styledSlice.rows.count)

    #expect(plainCursor.map { [$0.row, $0.col] } == [0, 2])
    #expect(styledCursor.map { [$0.row, $0.col] } == plainCursor.map { [$0.row, $0.col] })
}

// MARK: - The cursor overlay's geometry (walk defect D3)

/// The seam this closes half of: fed no cursor position at all (today's
/// state — nothing on `TerminalSnapshot` publishes one yet), this answers
/// `nil` and the view draws no cursor, which is today's behaviour and
/// therefore not a regression.
@Test func noCursorPositionMeansNoCursorDrawn() {
    #expect(terminalCursorLocation(
        cursorRow: nil, cursorCol: nil, liveRegionStartRow: 0, liveRegionRowCount: 3) == nil)
}

/// Once a real position exists, it maps into the live region's own
/// row-relative coordinates — row 5 in an absolute grid whose live region
/// starts at row 3 is row 2 of the rows actually being drawn.
@Test func aCursorInsideTheLiveRegionMapsToItsRelativeRow() {
    let location = terminalCursorLocation(
        cursorRow: 5, cursorCol: 4, liveRegionStartRow: 3, liveRegionRowCount: 4)
    #expect(location?.row == 2)
    #expect(location?.col == 4)
}

/// A cursor above the live region's own start row (already scrolled past
/// what is being drawn) or at/after its last row is not drawn rather than
/// drawn at a nonsense offset.
@Test func aCursorOutsideTheLiveRegionsRowsIsNotDrawn() {
    #expect(terminalCursorLocation(
        cursorRow: 1, cursorCol: 0, liveRegionStartRow: 3, liveRegionRowCount: 4) == nil)
    #expect(terminalCursorLocation(
        cursorRow: 7, cursorCol: 0, liveRegionStartRow: 3, liveRegionRowCount: 4) == nil)
}

// MARK: - Keyboard ownership (walk defects A1/A2/A3)

/// **A1.** With the pane holding the keyboard and search closed, ⌘F is
/// still claimed exactly as it always was — this fix must not cost the
/// pane its own shortcut.
@Test func commandFTogglesSearchWhenThePaneOwnsTheKeyboard() {
    let claim = terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: false, characters: "f",
        special: nil, modifiers: [.command])
    #expect(claim == .toggleSearch)
}

/// **A1, the actual leak.** With search open, an ordinary character (what
/// the operator types INTO the search field) and `⏎` (what submits it) are
/// both left unclaimed — the view returns `.ignored` for these, which is
/// what lets the search `TextField` receive them instead of the pty.
@Test func withSearchOpenOrdinaryCharactersAndEnterAreNotClaimed() {
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: false, characters: "a",
        special: nil, modifiers: []) == .notClaimed)
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: false, characters: "\r",
        special: nil, modifiers: []) == .notClaimed)
}

/// **Search wins over a pending proposal.** With both a proposal pending
/// and search open, `⏎` still goes to the search field — a proposal cannot
/// be sitting in front of an open search bar the operator is typing into.
@Test func searchOpenClaimsEnterOverAPendingProposal() {
    let claim = terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: true, characters: "\r",
        special: nil, modifiers: [])
    #expect(claim == .notClaimed)
}

/// ⌘F and Escape are still claimed while search is open — toggling search
/// off, and closing it, respectively — the two exceptions the spec carves
/// out of "search owns everything while it's open".
@Test func commandFAndEscapeAreStillClaimedWhileSearchIsOpen() {
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: false, characters: "f",
        special: nil, modifiers: [.command]) == .toggleSearch)
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: true, hasPendingProposal: false, characters: "\u{1B}",
        special: nil, modifiers: []) == .closeSearch)
}

/// **A2/A3, the regression itself.** With something else — an org plane, a
/// pending write confirmation — presented over the canvas, the pane claims
/// NOTHING: not Escape (so `OrgPlane`'s/`ConfirmationPlane`'s own
/// `.cancelAction` search finds it), not even ⌘F. `nil`, not
/// `.forwardToPty`, is the answer that lets the keystroke never reach the
/// pty at all in this state.
@Test func withAnOverlayPresentedNothingIsClaimedNotEvenEscapeOrCommandF() {
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: false, searchOpen: false, hasPendingProposal: false, characters: "\u{1B}",
        special: nil, modifiers: []) == nil)
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: false, searchOpen: false, hasPendingProposal: false, characters: "f",
        special: nil, modifiers: [.command]) == nil)
    // Even with search already open and a proposal pending — an overlay in
    // front overrides both.
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: false, searchOpen: true, hasPendingProposal: true, characters: "a",
        special: nil, modifiers: []) == nil)
}

/// **The ordinary case is unchanged.** With the pane owning the keyboard,
/// search closed and no proposal pending, Escape still reaches the pty as
/// a real keystroke — vim depends on it — and `^C` is untouched.
@Test func inTheOrdinaryCaseEscapeAndControlCStillReachThePty() {
    let escape = terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: false, characters: "\u{1B}",
        special: nil, modifiers: [])
    #expect(escape == .forwardToPty([0x1B]))

    let controlC = terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: false, characters: "c",
        special: nil, modifiers: [.control])
    #expect(controlC == .forwardToPty([0x03]))
}

/// A pending proposal's `⏎`/`⌫` are still claimed exactly as before this
/// fix, when the pane owns the keyboard and search is closed.
@Test func aPendingProposalsEnterAndBackspaceAreStillClaimedWhenThePaneOwnsTheKeyboard() {
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: true, characters: "\r",
        special: nil, modifiers: []) == .acceptProposal)
    #expect(terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: true, characters: "\u{7F}",
        special: nil, modifiers: []) == .discardProposal)
}

// MARK: - term_scroll's anchor (final review, Important 2)

@Test func theScrollAnchorForAPlainBlockIsTheBlockItself() {
    let items = groupedTerminalHistory([
        block(id: "b1", origin: .operatorTyped),
        block(id: "b2", origin: .operatorTyped),
    ])

    #expect(terminalScrollAnchor(items: items, blockId: "b2") == "b2")
}

/// **A block inside a collapsed mirrored group draws none of its own
/// ids**, so asking the scroll view for the block id would silently do
/// nothing. `term_scroll` accepts any id `read_pane` reported, including
/// those, so the row that IS on screen is what the anchor resolves to.
@Test func theScrollAnchorForABlockInsideAGroupIsTheGroupRow() {
    let items = groupedTerminalHistory([
        block(id: "a1", origin: .agent),
        block(id: "a2", origin: .agent),
        block(id: "a3", origin: .agent),
    ])

    #expect(items.count == 1)
    #expect(terminalScrollAnchor(items: items, blockId: "a2") == items[0].id)
}

/// A block trimmed away by the history cap between the agent's read and
/// its `term_scroll` has no row: "nothing to scroll to", not an error
/// raised at the operator.
@Test func theScrollAnchorIsNilForABlockNoLongerInTheHistory() {
    let items = groupedTerminalHistory([block(id: "b1", origin: .operatorTyped)])

    #expect(terminalScrollAnchor(items: items, blockId: "gone") == nil)
}

// MARK: - The two-Enter hand-off (two-axis review, Spec 1)

/// Story 23: *"I want `⏎` on a proposal to put the command in my prompt
/// unrun and `⌫` to discard it, so that accepting and running stay two
/// separate acts."* Until the two-axis review this had no keyboard path at
/// all — `TerminalPane.handleKeyPress` claimed `⌘F` and forwarded
/// everything else to the pty, so the only way to accept was a right-click
/// on the proposal row. These are the assertions that pin the decision now
/// that it is one.

@Test func enterAcceptsAndBackspaceDiscardsWhileAProposalIsPending() {
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\r", special: nil, modifiers: []) == .accept)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\u{7F}", special: nil, modifiers: []) == .discard)
}

@Test func withNoProposalPendingBothKeysStillReachThePty() {
    // The half of this that matters most: a shell whose `⏎` and `⌫` stopped
    // working because an agent once proposed something would be a far
    // larger defect than the one this closes. Asserted on BOTH functions —
    // the claim is `nil`, and the bytes the pane then forwards are the
    // unaltered ones.
    #expect(terminalProposalKeyAction(
        hasPendingProposal: false, characters: "\r", special: nil, modifiers: []) == nil)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: false, characters: "\u{7F}", special: nil, modifiers: []) == nil)
    #expect(terminalKeyBytes(characters: "\r", special: nil, modifiers: []) == Array("\r".utf8))
    #expect(terminalKeyBytes(characters: "\u{7F}", special: nil, modifiers: [])
        == Array("\u{7F}".utf8))
}

@Test func aPendingProposalClaimsOnlyThoseTwoKeysAndNothingElse() {
    // Everything else forwards unchanged, so readline is untouched while a
    // proposal sits on screen: `^C` still interrupts, an arrow still walks
    // history, and an ordinary letter still types.
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "a", special: nil, modifiers: []) == nil)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: nil, special: .up, modifiers: []) == nil)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\t", special: nil, modifiers: []) == nil)
}

@Test func aModifierHeldWithEitherKeyIsTheShellsNotTheProposals() {
    // `^D` is end-of-input and `^H` is readline's own backspace; a
    // modifier combination is a different keystroke, and claiming it here
    // would take the shell's editing keys away at exactly the moment a
    // proposal is on screen.
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\r", special: nil, modifiers: [.control]) == nil)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\u{7F}", special: nil, modifiers: [.control]) == nil)
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: "\r", special: nil, modifiers: [.command]) == nil)
}

@Test func forwardDeleteIsNotBackspaceEvenWithAProposalPending() {
    // fn-⌫ deletes ahead of the cursor in readline. The proposal's own
    // label says `⌫`, and quietly claiming the other one would discard a
    // proposal the operator was only editing their prompt around.
    #expect(terminalProposalKeyAction(
        hasPendingProposal: true, characters: nil, special: .deleteForward, modifiers: []) == nil)
}

// MARK: - A block's status, decided once (Standards 2)

@Test func aBlocksStatusIsDecidedOnceForGlyphAndColourAlike() {
    #expect(terminalBlockStatus(block(id: "b1", exitCode: 0)) == .succeeded)
    #expect(terminalBlockStatus(block(id: "b2", exitCode: 1)) == .failed)
    #expect(terminalBlockStatus(block(id: "b3", exitCode: nil)) == .running)
}

@Test func aProposalIsReadAsProposedBeforeItsMissingExitCodeIsRead() {
    // A proposal's `exitCode` is `nil` for the same reason a running
    // block's is, and the two are not the same state at all — `origin` is
    // what separates them, so it is read first.
    let proposal = block(id: "p1", command: "ls -la", origin: .proposed, exitCode: nil)
    #expect(terminalBlockStatus(proposal) == .proposed)
    #expect(terminalBlockStatus(proposal).glyph == "⏎")
}

@Test func eachStatusHasExactlyOneGlyph() {
    #expect(TerminalBlockStatus.succeeded.glyph == "✓")
    #expect(TerminalBlockStatus.failed.glyph == "✗")
    #expect(TerminalBlockStatus.running.glyph == "…")
    #expect(TerminalBlockStatus.proposed.glyph == "⏎")
}

// MARK: - The parked strip, and the mirror's drawing pause (Spec 6)

@Test func theParkedStripIsTheOperatorsOwnLastThreeBlocks() {
    let blocks = (0..<5).map { block(id: "b\($0)", command: "cmd\($0)") }
    #expect(parkedHistoryBlocks(blocks).map(\.command) == ["cmd2", "cmd3", "cmd4"])
}

@Test func aMirroredBlockIsWithheldFromTheParkedStripAndFromNothingElse() {
    // The mirror's pause, in the one place it now lives: the strip drawn
    // above a full-screen program's screen. `PaneStore.appendMirrored` no
    // longer defers the block itself, so `read_pane` sees it immediately —
    // see `TerminalMirrorTests`' own assertion of that half.
    let blocks = [
        block(id: "op1", command: "make"),
        block(id: "m1", command: "rg TODO", origin: .agent),
        block(id: "op2", command: "git status"),
    ]
    #expect(parkedHistoryBlocks(blocks).map(\.command) == ["make", "git status"])
}

@Test func aPendingProposalIsStillDrawnInTheParkedStrip() {
    // It is the one block asking for the operator's own `⏎`; hiding it
    // because a program took the screen would hide the thing they are
    // being asked about.
    let blocks = [block(id: "p1", command: "kubectl get pods", origin: .proposed, exitCode: nil)]
    #expect(parkedHistoryBlocks(blocks).map(\.id) == ["p1"])
}

@Test func aStripOfZeroBlocksIsEmptyRatherThanTheWholeHistory() {
    #expect(parkedHistoryBlocks([block(id: "b1")], limit: 0).isEmpty)
}

// MARK: - A mirrored group's backfill label

@Test func aGroupIsBackfilledOnlyWhenEveryBlockInItIs() {
    let marker = Date(timeIntervalSince1970: 100)
    let replayed = block(id: "m1", origin: .agent, startedAt: Date(timeIntervalSince1970: 50))
    let live = block(id: "m2", origin: .agent, startedAt: Date(timeIntervalSince1970: 150))
    #expect(allBackfilledTerminalBlocks([replayed], backfilledAt: marker))
    #expect(!allBackfilledTerminalBlocks([replayed, live], backfilledAt: marker))
}

@Test func anEmptyGroupIsNotBackfilled() {
    // `allSatisfy` on nothing is vacuously true; a `· backfilled` label on
    // a row with nothing in it is a bug, not a vacuous truth.
    #expect(!allBackfilledTerminalBlocks([], backfilledAt: Date()))
}

// MARK: - Copy, and Send to thread

@Test func aBlocksTextIsItsCommandThenItsOutput() {
    let ran = block(id: "b1", command: "ls", output: ["a.txt", "b.txt"])
    #expect(terminalBlockText(ran) == "ls\na.txt\nb.txt")
}

@Test func aBlockWithNoOutputIsJustItsCommandWithNoTrailingBlankLine() {
    #expect(terminalBlockText(block(id: "b1", command: "true")) == "true")
}

@Test func sendToThreadFencesTheSameTextCopyWouldPutOnThePasteboard() {
    // The difference between Copy and Send to thread is where the text
    // lands and the fence around it — never what it says.
    let ran = block(id: "b1", command: "ls", output: ["a.txt"])
    #expect(terminalBlockQuote(ran) == "```\nls\na.txt\n```")
}

// MARK: - Reopen (walk-defects B2)

@Test func reopenParamsNameTheRememberedPathWhenThereIsOne() {
    #expect(terminalReopenParams(path: "/Users/x/orca") == .object(["path": .string("/Users/x/orca")]))
}

/// `nil` — an older saved layout with no `terminalPath` — omits `path`
/// entirely, which is what lets `term_open`'s own default apply rather
/// than this call guessing a second one.
@Test func reopenParamsOmitPathWhenNoneIsRemembered() {
    #expect(terminalReopenParams(path: nil) == .object([:]))
}

// MARK: - The live region's own start row (walk defect C2/D3's join)

/// `startRow` is what `terminalCursorLocation` places the cursor against,
/// and it is NOT `promptRow` — the trimming below moves it. This is the
/// off-by-one that would put the cursor in the wrong row, and the reason
/// the slice is computed in `WakilKit` rather than in the view.
@Test func liveRegionSliceReportsTheRowItActuallyBeginsAt() {
    let screen = ["$ echo hi", "hi", "", "$ ", "", ""]

    // Sliced from the prompt, with the blank rows after it trimmed away:
    // begins exactly where it was sliced from.
    let atPrompt = terminalLiveRegionSlice(grid: screen, promptRow: 3)
    #expect(atPrompt.rows == ["$ "])
    #expect(atPrompt.startRow == 3)

    // A blank row between `promptRow` and the first drawn row is dropped,
    // and `startRow` moves past it — 2 is blank, so the region begins at 3.
    let pastABlank = terminalLiveRegionSlice(grid: screen, promptRow: 2)
    #expect(pastABlank.rows == ["$ "])
    #expect(pastABlank.startRow == 3)
}

/// Clamping to `maxRows` drops rows off the HEAD, so `startRow` advances
/// by exactly as many as were dropped.
@Test func liveRegionSliceAdvancesItsStartRowWhenClamped() {
    let screen = ["a", "b", "c", "d", "e"]
    let clamped = terminalLiveRegionSlice(grid: screen, maxRows: 2, promptRow: 0)
    #expect(clamped.rows == ["d", "e"])
    #expect(clamped.startRow == 3)
}

/// With no prompt row known the region is the whole screen, so it begins
/// at row 0 — and `terminalLiveRegion` stays exactly the rows half of it,
/// which is what every existing caller and test above depends on.
@Test func liveRegionSliceFallsBackToTheWholeScreenAndAgreesWithTheRowsOnlyCall() {
    let screen = ["", "$ echo hi", "hi", "$ ", ""]
    let slice = terminalLiveRegionSlice(grid: screen, promptRow: nil)
    #expect(slice.startRow == 1)
    #expect(slice.rows == terminalLiveRegion(grid: screen, promptRow: nil))
    #expect(terminalLiveRegionSlice(grid: screen, promptRow: 2).rows
        == terminalLiveRegion(grid: screen, promptRow: 2))
}

/// The join itself, stated as the walk would state it: a screen still
/// holding a FINISHED command's rows draws only the current prompt, so
/// nothing the block history already shows is drawn a second time.
@Test func liveRegionDrawsOnlyTheCurrentPromptWhenTheScreenStillHoldsFinishedCommands() {
    let screen = [
        "$ ls", "events.db src", "$ pwd", "/Users/operator", "$ ",
    ]
    #expect(terminalLiveRegion(grid: screen, promptRow: 4) == ["$ "])
    // And the cursor sits in that one row, not four rows below it.
    let slice = terminalLiveRegionSlice(grid: screen, promptRow: 4)
    #expect(terminalCursorLocation(
        cursorRow: 4, cursorCol: 2, liveRegionStartRow: slice.startRow,
        liveRegionRowCount: slice.rows.count).map { [$0.row, $0.col] } == [0, 2])
}

// MARK: - The live region while a command is running (live-region-running fix)

/// The defect itself: an operator running `claude` (or any TUI that never
/// switches to the alternate screen) inside the pane could see only an
/// 8-row, `promptRow`-anchored tail of its own screen — a program whose
/// interface is taller than that showed only its last few lines, redrawn
/// over and over. `isCommandRunning: true` is the fix: the whole visible
/// screen is drawn (trimmed of blank rows at either end, same as always),
/// never a `maxRows`-capped slice from a stale `promptRow`.
@Test func aRunningCommandsLiveRegionIsTheWholeScreenNotAnEightRowTail() {
    // Taller than `maxRows` (default 8), and `promptRow` is stuck at the
    // prompt that started the running command — long since scrolled past
    // by the command's own output, exactly as it would be for `claude`.
    let screen = (1...12).map { "line \($0)" }

    let idle = terminalLiveRegionSlice(grid: screen, promptRow: 0)
    #expect(idle.rows == ["line 5", "line 6", "line 7", "line 8",
                           "line 9", "line 10", "line 11", "line 12"])

    let running = terminalLiveRegionSlice(grid: screen, promptRow: 0, isCommandRunning: true)
    #expect(running.rows == screen)
    #expect(running.startRow == 0)
}

/// Idle mode is untouched: with `isCommandRunning` at its default
/// (`false`), every existing behaviour — the `promptRow` slice, the
/// `maxRows` cap, the blank-row trim — is unchanged row for row. This is
/// the same screen and `promptRow` as the defect test above, just without
/// the flag, so the two together pin the exact line the mode switch is
/// drawn on.
@Test func idleModeIsUnchangedRowForRowFromBeforeThisFieldExisted() {
    let screen = (1...12).map { "line \($0)" }

    #expect(terminalLiveRegionSlice(grid: screen, promptRow: 0)
        == terminalLiveRegionSlice(grid: screen, promptRow: 0, isCommandRunning: false))
}

/// `startRow` in running mode is `0` plus however many leading blank rows
/// were trimmed — never `promptRow`, which running mode does not consult
/// at all. This is what `terminalCursorLocation` places the cursor
/// against, so a mode that got this wrong would put the cursor in the
/// wrong row (the same class of bug the C2/D3 join defect already was).
@Test func startRowInRunningModeIgnoresPromptRowAndCountsOnlyLeadingBlanks() {
    let screen = ["", "", "$ claude", "Welcome", "", "some output", ""]

    // `promptRow` names row 2; running mode must not start there.
    let running = terminalLiveRegionSlice(grid: screen, promptRow: 2, isCommandRunning: true)

    #expect(running.rows == ["$ claude", "Welcome", "", "some output"])
    #expect(running.startRow == 2)
}

/// The cap becomes the pane, not `maxRows` — even a `maxRows` of `1`
/// (obviously too small for a real pane, but the smallest way to prove
/// the cap is not consulted at all in running mode) still draws every
/// non-blank row.
@Test func runningModeIgnoresMaxRowsEntirely() {
    let screen = (1...20).map { "line \($0)" }

    let running = terminalLiveRegionSlice(grid: screen, maxRows: 1, isCommandRunning: true)

    #expect(running.rows == screen)
}

/// A running command whose screen is mostly blank — a small program that
/// prints a short prompt of its own and nothing else — does not suddenly
/// claim the whole pane. Blank-row trimming is the same trim idle mode
/// already relies on, run unconditionally in both modes, so this is not a
/// second rule written for running mode alone.
@Test func aRunningCommandWithAMostlyBlankScreenTrimsDownToItsActualContent() {
    var screen = ["small tool > "]
    screen.append(contentsOf: Array(repeating: "", count: 30))

    let running = terminalLiveRegionSlice(grid: screen, isCommandRunning: true)

    #expect(running.rows == ["small tool > "])
}

/// The styled and plain slices still agree in running mode — the same
/// lockstep guarantee the colour fix established for idle mode, now
/// checked with `isCommandRunning: true` too, so a future change to
/// either overload cannot let the two modes drift apart from each other.
@Test func theStyledAndPlainSlicesAgreeInRunningModeToo() {
    let screen = ["$ claude", "Welcome to Claude Code", "", "> "]
    let styled: [[TerminalStyleRun]] = screen.map { [TerminalStyleRun(text: $0, style: .plain)] }

    let plainSlice = terminalLiveRegionSlice(grid: screen, promptRow: 0, isCommandRunning: true)
    let styledSlice = terminalLiveRegionSlice(
        gridStyles: styled, promptRow: 0, isCommandRunning: true)

    #expect(styledSlice.rows.map(terminalRowPlainText) == plainSlice.rows)
    #expect(styledSlice.startRow == plainSlice.startRow)
}

/// The cursor still lands correctly in running mode: fed the running
/// slice's own `startRow`, `terminalCursorLocation` places it in the row
/// the pty actually reports, not `cursorRow - promptRow` (which running
/// mode's `startRow` of `0` — or however many leading blanks were
/// trimmed — would silently get wrong if the join were ever re-broken).
@Test func theCursorLandsCorrectlyInRunningMode() {
    let screen = ["$ claude", "Welcome", "> typing here"]

    let slice = terminalLiveRegionSlice(grid: screen, promptRow: 0, isCommandRunning: true)

    #expect(terminalCursorLocation(
        cursorRow: 2, cursorCol: 13, liveRegionStartRow: slice.startRow,
        liveRegionRowCount: slice.rows.count).map { [$0.row, $0.col] } == [2, 13])
}

// MARK: - `ls` columnates (walk defect D2, second life)

/// The exact bytes `ls` emits on a tty: one row, a tab, two files. The
/// first D2 fix removed the phantom third `Open` and left ONE, standing
/// for both files and pointing at a path that does not exist.
@Test func lsSplitsOneColumnatedRowIntoItsFiles() {
    #expect(structuredOutput(command: "ls", output: ["events.db\tsrc", "%"])
        == .fileList(["events.db", "src"]))
}

/// Tabs expanded against tab stops before capture — the same row, drawn.
@Test func lsSplitsAColumnGapThatWasAlreadyExpanded() {
    #expect(terminalLsColumns(in: "events.db       src") == ["events.db", "src"])
    #expect(terminalLsColumns(in: "a\tb\tc") == ["a", "b", "c"])
}

/// Two spaces separate columns; one space does not. A file named
/// `Screen Shot.png` is one file, not two.
@Test func lsKeepsAFileNameWithASingleSpaceInIt() {
    #expect(terminalLsColumns(in: "Screen Shot.png") == ["Screen Shot.png"])
    #expect(terminalLsColumns(in: "Screen Shot.png  notes.txt")
        == ["Screen Shot.png", "notes.txt"])
}

/// The markers that are not files survive the new splitting — the
/// original D2 fix, re-asserted now that rows are split rather than taken
/// whole.
@Test func lsStillDropsBlankRowsAndTheShellsOwnMarker() {
    #expect(terminalLsColumns(in: "   ").isEmpty)
    #expect(terminalLsColumns(in: "%").isEmpty)
    #expect(structuredOutput(command: "ls", output: ["", "%"]) == nil)
}

/// One name on its own row — a single file, or a pane narrow enough that
/// `ls` gave up columnating — is unchanged.
@Test func lsLeavesASingleNameAlone() {
    #expect(structuredOutput(command: "ls", output: ["events.db", "src", "%"])
        == .fileList(["events.db", "src"]))
}

private func claim(
    _ characters: String?, special: TerminalSpecialKey? = nil, modifiers: TerminalKeyModifiers = [],
    selection: Bool = false, editable: Bool = true, proposal: Bool = false, maps: Bool = true
) -> TerminalPaneKeyClaim? {
    terminalPaneKeyClaim(
        isKeyboardOwner: true, searchOpen: false, hasPendingProposal: proposal, characters: characters,
        special: special, modifiers: modifiers, selectionActive: selection, lineEditEnabled: editable,
        selectionEditable: selection && editable && maps)
}

@Test func aSelectionThatMapsToNoEditableTextLetsTheKeyThrough() {
    // Review finding: a selection over a two-line prompt's first line, or a
    // stale one, used to swallow the key — nothing sent, selection cleared.
    #expect(claim("x", selection: true, maps: false) == .forwardToPty(Array("x".utf8)))
    #expect(claim("\u{7F}", selection: true, maps: false) == .forwardToPty([0x7F]))
    #expect(claim("c", modifiers: .command, selection: true, maps: false) == .copySelection)
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

// #365 walk: ⌥ was dropped, so ⌥← arrived as ← and ⌥⌫ as ⌫. These are the
// bytes Terminal.app ("Use Option as Meta") and iTerm send, which zsh and
// readline bind to backward-word, forward-word and backward-kill-word.
@Test func optionArrowsMoveByWordAndOptionBackspaceDeletesAWord() {
    #expect(terminalKeyBytes(characters: nil, special: .left, modifiers: .option) == Array("\u{1B}b".utf8))
    #expect(terminalKeyBytes(characters: nil, special: .right, modifiers: .option) == Array("\u{1B}f".utf8))
    #expect(terminalKeyBytes(characters: "\u{7F}", special: nil, modifiers: .option) == [0x1B, 0x7F])
}

@Test func optionWithACharacterStillTypesTheComposedCharacter() {
    // ⌥e then e is é; the UI framework hands over the composed character.
    #expect(terminalKeyBytes(characters: "é", special: nil, modifiers: .option) == Array("é".utf8))
}
