import Foundation
import Testing
@testable import WakilKit

/// The open-block-cap defect: `TerminalBlock.outputLineCap` only ever
/// applied when a block SEALS. While a command is still running,
/// `TerminalSession`'s `OpenBlock.output` used to grow without any limit
/// at all — fine for the seconds-long commands the pane was designed
/// around, not fine for a TUI left running for an hour. These tests drive
/// `TerminalSession.consume` directly through `feedForTesting`, the same
/// shape `TerminalStoreTests` and `TerminalSessionStyleTests` already use,
/// and read the buffer mid-run through the new `openBlockOutputForTesting`
/// seam rather than waiting for a `D` mark to seal it.
private func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
private func commandStartMark(_ command: String) -> String {
    osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
}
private func commandEndMark(_ exitCode: Int) -> String { osc("133;D;\(exitCode)") }

@Test func underTheBoundTheOpenAndClosedBufferAreByteIdenticalToBeforeThisFix() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    let lines = (0..<50).map { "line \($0)" }
    let body = lines.map { $0 + "\n" }.joined()

    session.feedForTesting(Array((commandStartMark("seq 50") + body).utf8))

    // Still running: nothing near `openBufferByteCap`, so the open buffer
    // must be untouched — the exact bytes fed, not a byte more or fewer.
    let open = try #require(session.openBlockOutputForTesting())
    #expect(open == Array(body.utf8))

    session.feedForTesting(Array(commandEndMark(0).utf8))
    let blocks = session.takeCompletedBlocks()
    #expect(blocks.count == 1)
    #expect(blocks.first?.output == lines)
}

@Test func overTheBoundTheOpenBufferKeepsTheTailAndCutsOnlyAtALineBoundary() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // 1,000-byte lines (999 'a's + '\n'), comfortably over
    // `openBufferByteCap` (500 * 2,048 = 1,024,000 bytes) so the running
    // buffer must trim mid-command, well before any `D` mark.
    let lineCount = 2_000
    func line(_ i: Int) -> String {
        "line-\(i)-" + String(repeating: "a", count: 1_000 - "line-\(i)-\n".count) + "\n"
    }
    let body = (0..<lineCount).map(line).joined()
    let fullBytes = Array(body.utf8)
    #expect(fullBytes.count > TerminalBlock.openBufferByteCap)

    session.feedForTesting(Array((commandStartMark("yes") + body).utf8))

    let trimmed = try #require(session.openBlockOutputForTesting())
    // Bounded.
    #expect(trimmed.count <= TerminalBlock.openBufferByteCap)
    // Trimming only ever drops from the FRONT: whatever remains is a
    // genuine suffix of the raw bytes fed, never a rewritten copy.
    #expect(Array(fullBytes.suffix(trimmed.count)) == trimmed)
    // The cut lands right after a line terminator — never mid-line.
    let cutIndex = fullBytes.count - trimmed.count
    if cutIndex > 0 {
        let boundaryByte = fullBytes[cutIndex - 1]
        #expect(boundaryByte == 0x0A || boundaryByte == 0x0D)
    }
    // The tail is what is kept: the most recently written line is still
    // there, intact, at the very end.
    #expect(String(decoding: trimmed, as: UTF8.self).hasSuffix(line(lineCount - 1)))
}

@Test func aMultiByteCharacterStraddlingTheNaiveCutPointSurvivesIntact() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    let cap = TerminalBlock.openBufferByteCap
    // A 1,000-byte filler line, repeated exactly enough times to land the
    // filler's own length exactly on `cap` — so the 4-byte emoji that
    // follows starts exactly where a NAIVE `buffer.suffix(cap)` would
    // begin its cut, putting the raw numeric boundary squarely inside the
    // emoji's own bytes (byte 1 of 4, a UTF-8 continuation byte).
    let fillerLine = String(repeating: "a", count: 999) + "\n"
    #expect(fillerLine.utf8.count == 1_000)
    let beforeLineCount = cap / 1_000
    #expect(beforeLineCount * 1_000 == cap)
    let before = String(repeating: fillerLine, count: beforeLineCount)

    let emoji = "\u{1F389}"  // 🎉 — 4 UTF-8 bytes.
    #expect(emoji.utf8.count == 4)

    // Enough trailing filler, plus a distinguishing marker line, to push
    // the buffer well past the cap so trimming actually runs, and to
    // confirm the tail this leaves is still valid, complete text.
    let trailingLines = (cap / 1_000) + 5
    let marker = "END-OF-OUTPUT\n"
    let after = String(repeating: fillerLine, count: trailingLines) + marker

    let body = before + emoji + after
    let fullBytes = Array(body.utf8)

    session.feedForTesting(Array((commandStartMark("printf") + body).utf8))

    let trimmed = try #require(session.openBlockOutputForTesting())
    #expect(trimmed.count <= cap)
    #expect(Array(fullBytes.suffix(trimmed.count)) == trimmed)

    let cutIndex = fullBytes.count - trimmed.count
    if cutIndex > 0 {
        let boundaryByte = fullBytes[cutIndex - 1]
        #expect(boundaryByte == 0x0A || boundaryByte == 0x0D)
    }

    // The whole point: decoding what survived never produces the
    // replacement character, which is what a mid-sequence split would
    // produce. Whatever happened to the emoji itself (kept whole or
    // dropped whole by the trim), nothing here is corrupted.
    let decoded = String(decoding: trimmed, as: UTF8.self)
    #expect(!decoded.contains("\u{FFFD}"))
    #expect(decoded.hasSuffix(marker))
}

@Test func aBlockTrimmedWhileRunningStillSealsToExactlyTheLast500Lines() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    let paddedWidth = 90
    func line(_ i: Int) -> String {
        let label = "line-\(i)-"
        return label + String(repeating: ".", count: paddedWidth - label.count)
    }
    // 15,000 ~91-byte lines is ~1.37 MB — well over `openBufferByteCap`
    // (~1 MB), so the open buffer trims mid-run, long before the `D`
    // mark applies `outputLineCap`. The two caps must compose correctly:
    // trimming the head early must never touch the last 500 lines this
    // block ends up sealing.
    let lineCount = 15_000
    let body = (0..<lineCount).map { line($0) + "\n" }.joined()
    #expect(Array(body.utf8).count > TerminalBlock.openBufferByteCap)

    session.feedForTesting(Array((commandStartMark("seq 15000") + body).utf8))
    // Sanity: the running buffer did in fact trim.
    let openCount = try #require(session.openBlockOutputForTesting()).count
    #expect(openCount <= TerminalBlock.openBufferByteCap)

    session.feedForTesting(Array(commandEndMark(0).utf8))
    let blocks = session.takeCompletedBlocks()
    #expect(blocks.count == 1)
    let sealed = try #require(blocks.first)

    #expect(sealed.output.count == TerminalBlock.outputLineCap)
    #expect(sealed.output.last == line(lineCount - 1))
    #expect(sealed.output.first == line(lineCount - TerminalBlock.outputLineCap))
}
