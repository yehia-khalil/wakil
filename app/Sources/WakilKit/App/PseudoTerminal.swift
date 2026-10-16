import Darwin
import Foundation

/// A pseudo-terminal pair, so a console program can be spawned the way a
/// terminal would spawn it.
///
/// # Why a login needs one
///
/// `claude auth login` and `claude setup-token` render through an
/// interactive console UI, and that UI writes **nothing at all** when its
/// output is not a terminal. Measured on 2026-09-23 against CLI 2.1.280:
/// with pipes, `setup-token` emitted zero bytes over twelve seconds while
/// completing a real OAuth exchange, and `auth login` showed its URL and
/// its `Paste code here if prompted` prompt only when the process was
/// killed and the buffer flushed.
///
/// The consequence was not cosmetic. The operator saw a band that never
/// advanced, while the browser half of the trip completed and — for the
/// mint — created a one-year credential at Anthropic that Wakil never
/// caught.
///
/// **This is not a workaround.** These are terminal programs, and the
/// terminal is an input they are entitled to. Go spawns the mint the same
/// way (`runOnPTY`); this is that, for the spawns Swift owns.
///
/// # Why the child's stdin is the terminal too
///
/// A console program handed a closed stdin can decide it has no operator
/// and take a different path. The slave is stdin as well as stdout, so a
/// read blocks rather than returning EOF at once.
final class PseudoTerminal {
    /// The parent's end. Everything the child renders arrives here.
    private var parent: Int32
    /// The child's end, handed to `Process` and closed once it has it.
    private var child: Int32

    /// The child's side as a `FileHandle`, for `Process`.
    ///
    /// `closeOnDealloc: false` — `closeChildSide()` owns the close, and a
    /// handle closing it as well would shut a descriptor the child holds.
    let childHandle: FileHandle

    init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PseudoTerminalError.couldNotOpen(errno) }
        guard grantpt(master) == 0 else {
            close(master)
            throw PseudoTerminalError.couldNotGrant(errno)
        }
        guard unlockpt(master) == 0 else {
            close(master)
            throw PseudoTerminalError.couldNotUnlock(errno)
        }
        guard let name = ptsname(master) else {
            close(master)
            throw PseudoTerminalError.couldNotName(errno)
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw PseudoTerminalError.couldNotOpenChildSide(errno)
        }

        // **Very wide, so nothing the CLI prints ever wraps.** A console
        // UI wraps to the width it is told, and a hard newline landing
        // inside a URL or a credential is indistinguishable from the end
        // of it. `SettingsForms.dc.html` already warns operators about
        // exactly this in the manual flow.
        var size = winsize(ws_row: 100, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        parent = master
        child = slave
        childHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    }

    /// Closes the parent's copy of the child's end.
    ///
    /// **After `Process.run()`, never before.** Held open here, the line
    /// never reports end-of-file and a read of the parent's end blocks
    /// forever after the child has gone.
    func closeChildSide() {
        guard child >= 0 else { return }
        close(child)
        child = -1
    }

    /// **Both ends are closed even when the spawn never happened** (#271).
    /// `readAllFromParent()` closes the parent's end and `closeChildSide()`
    /// the child's, but neither runs if `Process.run()` throws — and a
    /// throw is exactly the case where the executable was wrong, which is
    /// the failure this phase kept hitting. Two descriptors leaked per
    /// failed spawn. Go's twin has had `defer master.Close()` all along.
    deinit {
        if child >= 0 { close(child) }
        if parent >= 0 { close(parent) }
    }

    /// Everything the child rendered, with terminal control sequences
    /// replaced by spaces.
    ///
    /// **A space, not nothing and not a newline.** This UI positions with
    /// escapes rather than spaces, so deleting them glues neighbouring
    /// words — and a URL glued to the word after it is no longer a URL. A
    /// newline is no safer in the other direction: it is whitespace, and a
    /// sequence landing mid-token splits one value into two.
    /// Reads until the child's side closes, then releases the parent's.
    ///
    /// Sets `parent` to -1 so `deinit` does not close it a second time —
    /// a descriptor number is reused the moment it is free, and closing
    /// one twice closes somebody else's file.
    func readAllFromParent() -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(parent, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
                continue
            }
            // Darwin ends a PTY session with EIO rather than EOF once the
            // child's side is gone. Both mean "no more output".
            if n < 0 && errno == EINTR { continue }
            break
        }
        close(parent)
        parent = -1
        return PseudoTerminal.strippingControls(String(decoding: data, as: UTF8.self))
    }

    static func strippingControls(_ raw: String) -> String {
        let pattern = "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)"
            + "|\u{1b}[@-Z\\\\-_]"
            + "|\u{1b}\\[[0-?]*[ -/]*[@-~]"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = expression.stringByReplacingMatches(
            in: raw, range: range, withTemplate: " ")
        return stripped.replacingOccurrences(of: "\r", with: " ")
    }
}

enum PseudoTerminalError: Error, CustomStringConvertible {
    case couldNotOpen(Int32)
    case couldNotGrant(Int32)
    case couldNotUnlock(Int32)
    case couldNotName(Int32)
    case couldNotOpenChildSide(Int32)

    var description: String {
        switch self {
        case .couldNotOpen(let code): return "could not allocate a terminal (errno \(code))"
        case .couldNotGrant(let code): return "could not grant the terminal (errno \(code))"
        case .couldNotUnlock(let code): return "could not unlock the terminal (errno \(code))"
        case .couldNotName(let code): return "could not name the terminal (errno \(code))"
        case .couldNotOpenChildSide(let code):
            return "could not open the terminal's child side (errno \(code))"
        }
    }
}
