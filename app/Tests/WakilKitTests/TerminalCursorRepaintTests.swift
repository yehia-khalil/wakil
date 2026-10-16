import Foundation
import Testing
@testable import WakilKit

/// Walk-defects D4, widened: a block's own `heldTheGrid` used to key on a
/// single MECHANISM — the alternate screen (`vim`). The operator's own
/// decision (`redrew-in-place.md`) widens the rule to the BEHAVIOUR that
/// actually matters: did the program move the cursor UP to repaint a row
/// it had already left behind, rather than print a transcript. `vim`
/// happens to do both; Claude Code does the second without the first —
/// it renders a full interface on the ordinary screen and never switches
/// — so before this widening its block recorded the raw, unemulated
/// redraw byte-stream as if it were legitimate stdout.
///
/// These tests drive `TerminalSession.consume` directly through
/// `feedForTesting`, the same shape `TerminalStoreTests` and
/// `TerminalOpenBlockBufferTests` already use.
private func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
private func commandStartMark(_ command: String) -> String {
    osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
}
private func commandEndMark(_ exitCode: Int) -> String { osc("133;D;\(exitCode)") }

// MARK: - The two properties that must survive

@Test func anOrdinaryCommandWithAHundredPlainLinesIsUnaffected() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    let lines = (0..<100).map { "line\($0)" }
    let body = lines.map { $0 + "\n" }.joined()

    session.feedForTesting(Array((commandStartMark("seq 100") + body + commandEndMark(0)).utf8))

    let blocks = session.takeCompletedBlocks()
    let block = try #require(blocks.first)
    #expect(block.heldTheGrid == false)
    #expect(block.output == lines)
}

@Test func theExistingAlternateScreenMisattributionTestPathIsUntouched() throws {
    // Mirrors `anAlternateScreenSwitchIsCreditedToTheCommandThatMadeIt` in
    // `TerminalStoreTests.swift` — kept here too as a guard specific to
    // this file's own change: the alternate-screen scan is a SEPARATE
    // check from the new cursor scan, run alongside it, and this proves
    // the two do not interfere when only the original mechanism fires.
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    let chunk =
        commandStartMark("ls") + "file1\nfile2\n" + commandEndMark(0)
        + commandStartMark("vim -c q") + "\u{1B}[?1049h" + "editing" + "\u{1B}[?1049l"
        + commandEndMark(0)
    session.feedForTesting(Array(chunk.utf8))

    let blocks = session.takeCompletedBlocks()
    let ls = try #require(blocks.first { $0.command == "ls" })
    let vim = try #require(blocks.first { $0.command == "vim -c q" })
    #expect(ls.heldTheGrid == false)
    #expect(ls.output == ["file1", "file2"])
    #expect(vim.heldTheGrid == true)
    #expect(vim.output.isEmpty)
}

// MARK: - The widened rule itself

@Test func aProgramThatEmitsCursorUpRecordsNoOutput() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // `CSI A` (CUU) as the very first byte of this command's own output —
    // nothing legitimate precedes it, so the block's output ends up
    // empty, the same shape the existing alternate-screen test uses.
    let body = "\u{1B}[Aoverwrite\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output.isEmpty, "expected no output, got \(block.output)")
}

@Test func aBareCarriageReturnAloneNeverTriggersAndItsOutputSurvivesInFull() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // A progress bar's own shape: `\r` rewrites the CURRENT line, never
    // moves the cursor to an earlier one. `npm install` and `curl` do
    // exactly this, and their real output is exactly what an operator
    // wants kept.
    let body = "0%\r50%\r100%\r\n"
    session.feedForTesting(Array((commandStartMark("curl") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == false)
    #expect(block.output == ["0%", "50%", "100%"])
}

@Test func aProgramThatUsesCarriageReturnAndThenMovesTheCursorUpRecordsNoOutput() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // A progress bar INSIDE a TUI: `\r`-driven updates, but the redraw
    // that follows moves the cursor up first. `\r`'s own presence must
    // not rescue the block once the upward move has fired — the trigger
    // here is `CSI A`, placed first so nothing legitimate precedes it.
    let body = "\u{1B}[A" + "50%\r100%\r" + "done\n"
    session.feedForTesting(Array((commandStartMark("tui-progress") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output.isEmpty, "expected no output, got \(block.output)")
}

@Test func cursorPreviousLineAloneRecordsNoOutput() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // `CSI n F` (CPL) — cursor to the start of the line n rows up. Always
    // upward, the same as `CSI A`, regardless of `n`.
    let body = "\u{1B}[2Fmoved\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output.isEmpty)
}

@Test func reverseIndexAloneRecordsNoOutput() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // `ESC M` (RI) — "move up one line, scrolling if already at the top
    // margin." Treated the same as `CSI A`: unconditionally upward.
    let body = "\u{1B}Mmoved\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output.isEmpty)
}

// MARK: - `CSI row;colH` / `f`: only when the target row is ABOVE the current one

@Test func cursorPositionToTheRowAlreadyOnIsNotUpwardMovement() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // The very first thing this block's output does is address row 1 —
    // exactly where a fresh block's own row tracking already starts. This
    // is `CSI H`'s own equivalent of a bare `\r`: rewriting the row the
    // cursor is already on, not repainting an earlier one, and it must
    // not trigger.
    let body = "\u{1B}[1;1Hhello\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == false)
    #expect(block.output == ["hello"])
}

@Test func cursorPositionAboveTheCurrentRowIsUpwardMovementAndTruncatesFromThere() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // Two line feeds move this block's own tracked row to 2; addressing
    // row 1 next is addressing a row already left behind, so it triggers
    // — but only from that point on. `line1`/`line2`, printed forward
    // before the move, survive.
    let body = "line1\nline2\n" + "\u{1B}[1;1H" + "overwrite\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output == ["line1", "line2"], "expected the pre-move lines only, got \(block.output)")
}

@Test func cursorDownThenPositioningBackToTheOriginalRowTriggers() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // `CSI n B` (CUD) moves the tracked row DOWN, same as printing `n`
    // blank lines would — it must not itself trigger, but it must count,
    // so that addressing the row the cursor started on afterwards is
    // correctly seen as addressing a row already left behind.
    let body = "line1\n" + "\u{1B}[5B" + "\u{1B}[2;1H" + "overwrite\n"
    session.feedForTesting(Array((commandStartMark("tui") + body + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(block.output == ["line1"])
}

// MARK: - Split across two `read(2)`s

@Test func cursorUpSplitAcrossTwoReadsIsStillCaught() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    session.feedForTesting(Array((commandStartMark("tui") + "before\n").utf8))
    // The `CSI A` sequence, split across this chunk and the next — the
    // ordinary case for a 1,024-byte pty read, not an exotic one. Mirrors
    // `anAlternateScreenSwitchSplitAcrossTwoReadsIsStillCaught` in
    // `TerminalStoreTests.swift`, including that test's own weaker
    // assertion rather than exact equality: the escape's own two bytes
    // ("\x1B[") were already committed to `output` by the round that
    // first saw them — the same look-back trick the alternate-screen
    // scan uses depends on unresolved bytes staying in `output` rather
    // than being withheld — so they can survive `stripEscapeSequences`
    // as literal text once the trigger is found one event later. The
    // property that matters is that genuine POST-move content never
    // does.
    session.feedForTesting(Array("\u{1B}[".utf8))
    session.feedForTesting(Array(("A" + "after\n" + commandEndMark(0)).utf8))

    let block = try #require(session.takeCompletedBlocks().first)
    #expect(block.heldTheGrid == true)
    #expect(!block.output.joined(separator: "\n").contains("after"))
}
