import Foundation

/// What one chunk off the pty contained, in wire order.
///
/// `.output` is every byte that is not one of Wakil's own marks — which is
/// what a block's output is made of. The marks themselves are excluded
/// from it, because a block whose output began with the escape sequence
/// that opened it would draw its own plumbing.
///
/// **The whole raw chunk still reaches SwiftTerm regardless.** Feeding the
/// marks to the engine is harmless — it parses and discards them — and
/// stripping them would be a second, divergent view of the same bytes.
public enum TerminalStreamEvent: Sendable, Equatable {
    case output([UInt8])
    case promptStart
    case promptEnd
    case commandStart(command: String)
    case commandEnd(exitCode: Int?)
    case hostDirectory(String)
    /// `OSC 1337;WakilEdit=1`: the generated rc installed `__wakil_replace`
    /// in this shell (#365). Sent every prompt, right after `133;A`.
    case editSupported
}

/// Finds Wakil's own OSC 133 and OSC 7 marks in the pty's byte stream.
///
/// **Wakil scans rather than asking the terminal, for three measured
/// reasons.** The exit code riding `D;<code>` reaches no public API of
/// SwiftTerm — confirmed by feeding `D;42` and finding nothing. `C` and
/// `D` are handled by one `switch` case there, so they are
/// indistinguishable at every public seam. And **OSC 133 is discarded
/// entirely under the alternate screen** (`oscSemanticPrompt` opens with
/// `guard !isCurrentBufferAlternate`), which is exactly the case User
/// Story 16 is about: four minutes in `vim` must still leave a block
/// carrying its command, duration and exit code. Scanning the raw stream
/// is what makes that true rather than dependent on where the mark lands.
///
/// **It is split-safe.** The pty caps reads at 1,024 bytes regardless of
/// the buffer offered (probe §6.3), so a mark straddling two reads is the
/// ordinary case, not an exotic one. A partial sequence is carried into
/// the next `consume` call — and "partial" includes the narrowest case,
/// a lone trailing `ESC` with no byte after it yet to say whether it
/// opens one of Wakil's sequences at all. Only holding back an
/// already-recognised OSC opener would let that lone byte fall through
/// as ordinary output, and the `]133;A…` that completes it next call
/// would then read as plain text with no escape in front of it — the
/// mark lost, not delayed.
///
/// **A sequence that is not one of Wakil's passes through as output.** A
/// title change, a colour-palette query, anything else: swallowing it
/// would take bytes away from the engine that draws the screen.
public final class TerminalMarkScanner {
    /// Bytes held back because a sequence began and has not terminated.
    /// Bounded: an escape that never terminates must not become an
    /// unbounded buffer, and 4 KB is far past any real OSC.
    private var pending: [UInt8] = []
    private static let pendingCap = 4096

    public init() {}

    public func consume(_ bytes: ArraySlice<UInt8>) -> [TerminalStreamEvent] {
        var events: [TerminalStreamEvent] = []
        var output: [UInt8] = []
        var buffer = pending
        pending = []
        buffer.append(contentsOf: bytes)

        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x1B else {
                output.append(buffer[index])
                index += 1
                continue
            }
            guard index + 1 < buffer.count else {
                // A lone ESC at the very end of the chunk. It might be the
                // first byte of "ESC ]" — hold it rather than guess, so a
                // split landing here is no different from one landing
                // anywhere else in the sequence.
                pending = [buffer[index]]
                index = buffer.count
                break
            }
            guard buffer[index + 1] == 0x5D else {
                // ESC not followed by "]" is not an OSC opener at all —
                // not ours, pass the ESC through and keep scanning
                // normally from the next byte.
                output.append(buffer[index])
                index += 1
                continue
            }
            // An OSC opened. Find its terminator: BEL, or ESC \.
            guard let terminator = terminatorIndex(in: buffer, from: index + 2) else {
                // Incomplete. Hold it — unless it has outgrown any real
                // sequence, in which case it was never one.
                let remainder = Array(buffer[index...])
                if remainder.count > Self.pendingCap {
                    output.append(contentsOf: remainder)
                } else {
                    pending = remainder
                }
                index = buffer.count
                break
            }
            let body = Array(buffer[(index + 2)..<terminator.start])
            if let event = event(from: body) {
                if !output.isEmpty { events.append(.output(output)); output = [] }
                events.append(event)
            } else {
                // Not ours. Pass the whole sequence through untouched.
                output.append(contentsOf: buffer[index..<terminator.end])
            }
            index = terminator.end
        }
        if !output.isEmpty { events.append(.output(output)) }
        return events
    }

    /// The terminator's start (where the body ends) and end (where the
    /// next byte after the sequence begins).
    private func terminatorIndex(
        in buffer: [UInt8], from start: Int
    ) -> (start: Int, end: Int)? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x07 { return (index, index + 1) }
            if buffer[index] == 0x1B, index + 1 < buffer.count, buffer[index + 1] == 0x5C {
                return (index, index + 2)
            }
            index += 1
        }
        return nil
    }

    private func event(from body: [UInt8]) -> TerminalStreamEvent? {
        let text = String(decoding: body, as: UTF8.self)
        if text == "133;A" { return .promptStart }
        if text == "133;B" { return .promptEnd }
        if text == "133;D" { return .commandEnd(exitCode: nil) }
        if text.hasPrefix("133;D;") {
            // The shell prints `$?`, so anything that is not an integer is
            // a shell that did not say rather than an exit code of zero.
            let field = text.dropFirst("133;D;".count).split(separator: ";").first ?? ""
            return .commandEnd(exitCode: Int(field))
        }
        if text.hasPrefix("133;C") {
            // `wakil_cmd=` may sit among other k=v fields SwiftTerm also
            // reads; find ours by name rather than by position.
            for field in text.dropFirst("133;C".count).split(separator: ";")
            where field.hasPrefix("wakil_cmd=") {
                let encoded = field.dropFirst("wakil_cmd=".count)
                if let data = Data(base64Encoded: String(encoded)) {
                    return .commandStart(command: String(decoding: data, as: UTF8.self))
                }
            }
            return .commandStart(command: "")
        }
        if text.hasPrefix("7;") {
            // `file://localhost/Users/…` — a URL, not a path (probe §4.4).
            let raw = String(text.dropFirst(2))
            guard let url = URL(string: raw), !url.path.isEmpty else { return nil }
            return .hostDirectory(url.path)
        }
        if text == "1337;WakilEdit=1" { return .editSupported }
        return nil
    }
}
