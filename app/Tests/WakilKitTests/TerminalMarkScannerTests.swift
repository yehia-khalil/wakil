import Foundation
import Testing
@testable import WakilKit

private func bytes(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }
private func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

@Test func theScannerFindsEachMarkAndKeepsTheOutputBetweenThem() {
    let scanner = TerminalMarkScanner()

    let events = scanner.consume(bytes(
        "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}"
        + "\u{1b}]133;C;wakil_cmd=\(base64("ls -la"))\u{07}"
        + "total 8\r\n"
        + "\u{1b}]133;D;0\u{07}"))

    #expect(events == [
        .promptStart,
        .output(Array("$ ".utf8)),
        .promptEnd,
        .commandStart(command: "ls -la"),
        .output(Array("total 8\r\n".utf8)),
        .commandEnd(exitCode: 0),
    ])
}

@Test func aMarkSplitAcrossTwoReadsIsStillFound() {
    // The pty caps reads at 1,024 bytes regardless of the buffer offered
    // (probe §6.3), so a mark landing on a boundary is the ordinary case,
    // not an exotic one. A scanner that could only see whole sequences
    // would lose blocks at random under load.
    let scanner = TerminalMarkScanner()

    var events = scanner.consume(bytes("out\u{1b}]133;D"))
    events += scanner.consume(bytes(";42\u{07}more"))

    #expect(events == [
        .output(Array("out".utf8)),
        .commandEnd(exitCode: 42),
        .output(Array("more".utf8)),
    ])
}

@Test func aSplitRightAfterTheLoneEscapeByteIsStillFound() {
    // The split above lands mid-body. This one lands on the narrowest
    // possible boundary: right after the ESC that opens the sequence,
    // before the scanner has even seen the `]` that says it is an OSC.
    // A scanner that only holds back an already-recognised OSC opener
    // would treat this lone trailing ESC as an ordinary output byte and
    // lose the mark permanently — the following `]133;A` arrives as text
    // that no longer looks like a continuation of anything.
    let scanner = TerminalMarkScanner()

    var events = scanner.consume(bytes("out\u{1b}"))
    events += scanner.consume(bytes("]133;A\u{07}more"))

    #expect(events == [
        .output(Array("out".utf8)),
        .promptStart,
        .output(Array("more".utf8)),
    ])
}

@Test func theExitCodeIsCapturedBecauseNothingElseCapturesIt() {
    // Fed D;42, SwiftTerm surfaces nothing at any public seam — it
    // switches on "C","D" together and reads the rest as k=/click options
    // (probe §4.4). This is the only place the code exists.
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;D;42\u{07}")) == [.commandEnd(exitCode: 42)])
    // A D with no code at all is a shell that did not say, not a zero.
    #expect(scanner.consume(bytes("\u{1b}]133;D\u{07}")) == [.commandEnd(exitCode: nil)])
}

@Test func anStTerminatorIsAcceptedAsWellAsABel() {
    // ESC \ is the other OSC terminator, and a shell or a program may use
    // either. Accepting only BEL would drop marks from anything that does.
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;A\u{1b}\\")) == [.promptStart])
}

@Test func osc7IsReportedAsAPathRatherThanAUrl() {
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]7;file://localhost/usr/lib\u{07}"))
            == [.hostDirectory("/usr/lib")])
}

@Test func anUnrelatedOscPassesThroughAsOutput() {
    // A title change is not this scanner's business, and swallowing it
    // would take bytes away from the engine that draws the screen.
    let scanner = TerminalMarkScanner()
    let title = "\u{1b}]0;a title\u{07}"
    #expect(scanner.consume(bytes(title)) == [.output(Array(title.utf8))])
}

@Test func aCommandLineContainingTheTerminatorSurvivesTheRoundTrip() {
    // Why the command line is base64 in the rc: a command holding a BEL, a
    // newline or a `;` would otherwise end the sequence early and Wakil
    // would draw half a command as the whole of one.
    let command = "printf 'a;b\\n' && echo \u{07}done"
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]133;C;wakil_cmd=\(base64(command))\u{07}"))
            == [.commandStart(command: command)])
}

@Test func anEscapeThatNeverTerminatesDoesNotGrowWithoutBound() {
    // An escape opener with no terminator anywhere must not become an
    // unbounded buffer — the held-back partial sequence is capped, and
    // past the cap it is released as ordinary output instead of retained
    // forever.
    let scanner = TerminalMarkScanner()
    let opener = "\u{1b}]" + String(repeating: "9", count: 5_000)
    let events = scanner.consume(bytes(opener))
    let totalOutputBytes = events.reduce(0) { count, event in
        if case .output(let bytes) = event { return count + bytes.count }
        return count
    }
    #expect(totalOutputBytes == opener.utf8.count)
}

@Test func scannerRecognisesTheLineEditSignal() {
    let scanner = TerminalMarkScanner()
    #expect(scanner.consume(bytes("\u{1b}]1337;WakilEdit=1\u{07}")) == [.editSupported])
}

@Test func scannerPassesOtherITermSequencesThrough() {
    let scanner = TerminalMarkScanner()
    let raw = "\u{1b}]1337;SetMark\u{07}"
    #expect(scanner.consume(bytes(raw)) == [.output(Array(raw.utf8))])
}
