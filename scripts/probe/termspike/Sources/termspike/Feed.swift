import Foundation
import SwiftTerm

/// Measurement 1 — how fast can SwiftTerm's parser eat, and does chunk size
/// change the answer? The drain thread hands over whatever `read(2)` returned,
/// so chunk size is not a tuning knob the pane gets to pick; it is a property
/// of the pty. Knowing whether it matters decides whether the pane must
/// coalesce before feeding.
func runParse(megabytes: Int) {
    print("## Measurement 1 — SwiftTerm parser feed rate\n")
    print("cols=132 rows=36 scrollback=10000, release build\n")

    for (name, payload) in [("plain (`cat`)", plainTextOutput(targetBytes: megabytes * 1_048_576)),
                            ("build-like (SGR)", buildLikeOutput(targetBytes: megabytes * 1_048_576))] {
        print("### \(name) — \(mb(payload.count))\n")
        print("| chunk | wall | rate | linefeeds | dirty rows if polled per chunk |")
        print("|---|---|---|---|---|")
        for chunk in [1024, 4096, 16384, 65536, 1_048_576] {
            let del = CountingDelegate()
            let term = makeTerminal(cols: 132, rows: 36, delegate: del)
            var dirtyRows = 0
            let t0 = now()
            var i = 0
            while i < payload.count {
                let end = min(i + chunk, payload.count)
                term.feed(buffer: payload[i..<end])
                // What a per-chunk redraw would have had to repaint. The pane
                // does not have to poll this often — measurement 4 shows what
                // polling at a frame rate collapses it to — but this is the
                // ceiling it is collapsing from.
                if let r = term.getUpdateRange() {
                    dirtyRows += max(0, r.endY - r.startY + 1)
                    term.clearUpdateRange()
                }
                i = end
            }
            let dt = now() - t0
            print("| \(chunk) B | \(String(format: "%.3f s", dt)) | \(rate(payload.count, dt)) | \(del.linefeeds) | \(dirtyRows) |")
        }
        print("")
    }
}


/// Feeds `commands` OSC 133-marked commands and reports how many marks the
/// public API can still find afterwards.
func feedAndCountMarks(commands: Int, linesEach: Int) -> (rows: Int, found: Int) {
    let del = CountingDelegate()
    let term = makeTerminal(cols: 132, rows: 36, delegate: del)
    for c in 0..<commands {
        term.feed(text: "\u{1b}]133;A\u{07}burbot ~/wakil % \u{1b}]133;B\u{07}swift build -c release\n\u{1b}]133;C\u{07}")
        for l in 0..<linesEach { term.feed(text: "[\(l)/\(linesEach)] compiling object file \(c)\n") }
        term.feed(text: "\u{1b}]133;D;\(c % 2)\u{07}")
    }
    let linesTop = term.buffer.totalLinesTrimmed
    var rows = 0
    while term.getScrollInvariantLine(row: linesTop + rows) != nil { rows += 1 }
    var found = 0
    for row in 0..<rows where !term.semanticPromptMarks(at: row).isEmpty { found += 1 }
    return (rows, found)
}

/// Measurement 2 — what does it cost to reconstruct blocks from the OSC 133
/// marks the generated rc emits, over a history the pane would actually hold?
///
/// This is Wakil's cost, not SwiftTerm's: SwiftTerm stores the marks and
/// offers `semanticPromptMarks(at:)` per row, and raises no delegate callback
/// on `C` or `D`. Walking the buffer is therefore the only route from marks to
/// blocks, and the walk is what gets timed.
func runBlocks(commands: Int, linesEach: Int) {
    print("## Measurement 2 — block reconstruction from OSC 133 marks\n")
    // Sweep first: how many of the marks fed are still findable, as the
    // history grows past the scrollback cap. Decision 23 took SwiftTerm for
    // "marks that survive scrollback", and this is the check of that clause.
    print("### 2a — do the marks survive?\n")
    print("| commands fed | lines each | buffer rows | marks found | lost |")
    print("|---|---|---|---|---|")
    for n in [20, 50, 100, 200, 400] {
        let (rows, found) = feedAndCountMarks(commands: n, linesEach: linesEach)
        print("| \(n) | \(linesEach) | \(rows) | \(found) | \(n - found) |")
    }
    print("")
    print("### 2b — the cost of the walk\n")

    var payload = [UInt8]()
    for c in 0..<commands {
        payload.append(contentsOf: Array("\u{1b}]133;A\u{07}".utf8))
        payload.append(contentsOf: Array("burbot ~/wakil % ".utf8))
        payload.append(contentsOf: Array("\u{1b}]133;B\u{07}".utf8))
        payload.append(contentsOf: Array("swift build -c release\n".utf8))
        payload.append(contentsOf: Array("\u{1b}]133;C\u{07}".utf8))
        for l in 0..<linesEach {
            payload.append(contentsOf: Array("[\(l)/\(linesEach)] compiling object file \(c)\n".utf8))
        }
        payload.append(contentsOf: Array("\u{1b}]133;D;\(c % 2)\u{07}".utf8))
    }

    let del = CountingDelegate()
    let term = makeTerminal(cols: 132, rows: 36, delegate: del)
    let t0 = now()
    var i = 0
    while i < payload.count {
        let end = min(i + 65536, payload.count)
        term.feed(buffer: payload[i..<end])
        i = end
    }
    let feedTime = now() - t0

    // The walk: every row still in the buffer, asking for its marks. This is
    // the shape the pane is forced into, because nothing tells it when a
    // block ended.
    let t1 = now()
    var marksFound = 0
    var promptRows = 0
    // `Buffer.lines` is internal, so the extent is established the only way
    // the public API allows: walk scroll-invariant rows until one is nil.
    // `semanticPromptMarks(at:)` indexes `lines` directly, so the two differ
    // by `totalLinesTrimmed`.
    let linesTop = term.buffer.totalLinesTrimmed
    var total = 0
    while term.getScrollInvariantLine(row: linesTop + total) != nil { total += 1 }
    for row in 0..<total {
        let marks = term.semanticPromptMarks(at: row)
        if !marks.isEmpty { marksFound += marks.count; promptRows += 1 }
    }
    let walkTime = now() - t1

    print("\(commands) commands x \(linesEach) lines = \(mb(payload.count)), \(total) buffer rows\n")
    print("| step | wall |")
    print("|---|---|")
    print("| feed | \(String(format: "%.3f s", feedTime)) — \(rate(payload.count, feedTime)) |")
    print("| full-buffer mark walk | \(String(format: "%.4f s", walkTime)) |")
    print("")
    print("- prompt rows found by the walk: **\(promptRows)** (commands fed: \(commands))")
    print("- marks found: \(marksFound)")
    print("- `bufferActivated`: \(del.bufferActivations), `hostCurrentDirectoryUpdated`: \(del.cwdUpdates)")
    print("")
}

/// Measurement 3 — the two things the spec says Wakil must supply itself.
/// Cheap to check and expensive to get wrong, because the whole block model
/// rests on them.
func runIntegrationGaps() {
    print("## Measurement 3 — what SwiftTerm does *not* give back\n")

    let del = CountingDelegate()
    let term = makeTerminal(cols: 132, rows: 36, delegate: del)

    // An exit code riding D;<code>.
    term.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}false\n\u{1b}]133;C\u{07}\u{1b}]133;D;42\u{07}")
    print("- fed `OSC 133;D;42`. Public API carrying an exit code: **none found**.")
    print("  `oscSemanticPrompt` switches on `\"C\", \"D\"` together and reads only the")
    print("  `k=`/click options; the `42` is parsed as an option field and dropped.")

    // OSC 7 cwd.
    term.feed(text: "\u{1b}]7;file://localhost/Users/operator/orca\u{07}")
    print("- fed `OSC 7`. `hostCurrentDirectory` = **\(term.hostCurrentDirectory ?? "nil")**, delegate fired \(del.cwdUpdates)x.")

    // The alternate screen, and what it does to OSC 133.
    let beforeAlt = term.isCurrentBufferAlternate
    term.feed(text: "\u{1b}[?1049h")
    let duringAlt = term.isCurrentBufferAlternate
    let activationsAtAlt = del.bufferActivations
    term.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}vim\n\u{1b}]133;C\u{07}")
    term.feed(text: "\u{1b}[?1049l")
    print("- alternate screen: before=\(beforeAlt) during=\(duringAlt) after=\(term.isCurrentBufferAlternate), `bufferActivated` fired \(del.bufferActivations)x (\(activationsAtAlt) by the switch in).")
    print("- OSC 133 fed *while* the alternate screen was up: `oscSemanticPrompt` opens with")
    print("  `guard !isCurrentBufferAlternate`, so every mark was **discarded**.")
    print("")
}
