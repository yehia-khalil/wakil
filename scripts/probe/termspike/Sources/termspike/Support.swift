import Foundation
import SwiftTerm

// MARK: - timing and memory

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Peak resident size of this process, in bytes. `phys_footprint` is what
/// Activity Monitor calls Memory and is the number that matters for a pane
/// that may hold an unbounded stream.
func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
func mb(_ bytes: UInt64) -> String { mb(Int(bytes)) }
/// KB below a megabyte, so a case that produces 32 KB is not reported as 0.00 MB.
func sized(_ bytes: Int) -> String {
    bytes < 1_048_576 ? String(format: "%.1f KB", Double(bytes) / 1024) : mb(bytes)
}
func rate(_ bytes: Int, _ seconds: Double) -> String {
    String(format: "%.1f MB/s", Double(bytes) / 1_048_576 / seconds)
}

// MARK: - the headless terminal

/// A delegate that does nothing but count.
///
/// **`TerminalDelegate` has no content-change member.** There is no `refresh`,
/// no `contentChanged`, nothing that fires when cells are written — the first
/// version of this file implemented one and it compiled, because it satisfied
/// no requirement and was simply never called. SwiftTerm instead accumulates a
/// dirty range that the embedder **polls** with `getUpdateRange()` /
/// `clearUpdateRange()`. What the delegate does carry is out-of-band events:
/// the alternate-screen switch, the OSC 7 cwd, the title, and bytes the
/// terminal wants written back to the pty.
final class CountingDelegate: TerminalDelegate {
    var bufferActivations = 0
    var cwdUpdates = 0
    var linefeeds = 0

    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) { linefeeds += 1 }
    func bufferActivated(source: Terminal) { bufferActivations += 1 }
    func hostCurrentDirectoryUpdated(source: Terminal) { cwdUpdates += 1 }
}

func makeTerminal(cols: Int, rows: Int, delegate: TerminalDelegate) -> Terminal {
    var opts = TerminalOptions.default
    opts.cols = cols
    opts.rows = rows
    // The block cap lives in Wakil, not here, but scrollback has to be *some*
    // number for the parser to be measured under a realistic memory shape.
    opts.scrollback = 10_000
    return Terminal(delegate: delegate, options: opts)
}

// MARK: - synthetic payloads

/// Output shaped like a build: mostly short plain lines, one line in twelve
/// carrying SGR colour, a long path every so often. Not a substitute for the
/// real build the probe also runs — a control with a known byte count.
func buildLikeOutput(targetBytes: Int) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(targetBytes + 4096)
    var i = 0
    while out.count < targetBytes {
        let line: String
        switch i % 12 {
        case 0:
            line = "\u{1b}[1;32mCompiling\u{1b}[0m WakilKit Sources/WakilKit/PaneStore.swift\n"
        case 5:
            line = "\u{1b}[1;33mwarning:\u{1b}[0m variable 'x' was never mutated; consider changing to 'let'\n"
        case 9:
            line = "/Users/x/orca/workspaces/wakil/burbot/app/Sources/WakilKit/Actions/StandardActions.swift:\(i):12\n"
        default:
            line = "[\(i)/4821] compiling object file for target termspike, \(i % 97) remaining\n"
        }
        out.append(contentsOf: Array(line.utf8))
        i += 1
    }
    return out
}

/// `cat` of a large file: long-ish plain lines, no escapes at all. The ceiling
/// case for the parser, because nothing in it needs the escape state machine.
func plainTextOutput(targetBytes: Int) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(targetBytes + 4096)
    var i = 0
    while out.count < targetBytes {
        out.append(contentsOf: Array("line \(i): the quick brown fox jumps over the lazy dog, and then keeps going for a while longer\n".utf8))
        i += 1
    }
    return out
}
