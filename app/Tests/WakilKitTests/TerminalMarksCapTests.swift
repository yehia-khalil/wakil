import Foundation
import Testing
@testable import WakilKit

/// `TerminalSession.marks` was labelled TEST-ONLY yet accumulated every
/// non-`.output` event unconditionally in a shipped build, with no cap at
/// all — flagged, not fixed, by the agent that capped `OpenBlock.output`
/// (`open-block-cap.md`'s own "Other unbounded growth checked for"). Not
/// byte-rate-driven the way that defect was — a TUI redrawing at frame
/// rate emits none of these events after its own `commandStart` — but
/// still a session left open for hours, across many hundreds of
/// commands, growing this array without limit.
///
/// **Bounded, not made genuinely test-only**, so a build that never reads
/// it still stops it growing without silently emptying a field the tests
/// in this file — and `TerminalStoreTests` — read.
private func osc(_ body: String) -> String { "\u{1B}]\(body)\u{07}" }
private func commandStartMark(_ command: String) -> String {
    osc("133;C;wakil_cmd=\(Data(command.utf8).base64EncodedString())")
}
private func commandEndMark(_ exitCode: Int) -> String { osc("133;D;\(exitCode)") }

@Test func marksStayUnboundedUnderTheCapExactlyAsBefore() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    for index in 0..<10 {
        session.feedForTesting(Array((commandStartMark("cmd\(index)") + commandEndMark(0)).utf8))
    }
    let marks = session.marksForTesting()
    // Two marks per command (`commandStart`, `commandEnd`) — well under
    // the cap, so nothing here should have been trimmed.
    #expect(marks.count == 20)
    #expect(marks.contains {
        if case .commandStart(let c) = $0 { return c == "cmd0" } else { return false }
    })
}

@Test func marksAreBoundedInAProductionShapedSessionLeftOpenForHours() throws {
    let session = TerminalSession(paneId: "p", shellName: "test", cols: 80, rows: 24)
    // Two marks per command; comfortably over the 4,000-event cap so the
    // bound actually engages, well short of the "many hundreds" the
    // defect this closes was raised against.
    let commandCount = 3_000
    for index in 0..<commandCount {
        session.feedForTesting(Array((commandStartMark("cmd\(index)") + commandEndMark(0)).utf8))
    }
    let marks = session.marksForTesting()
    // Bounded — not 2 * 3,000 = 6,000.
    #expect(marks.count == 4_000)
    // Trimmed from the FRONT, keeping the tail — the oldest commands are
    // gone, the most recent one survives, the same rule
    // `TerminalBlock.capped` and `trimmedOpenBuffer` already use.
    #expect(!marks.contains {
        if case .commandStart(let c) = $0 { return c == "cmd0" } else { return false }
    })
    #expect(marks.contains {
        if case .commandStart(let c) = $0 { return c == "cmd\(commandCount - 1)" } else { return false }
    })
}
