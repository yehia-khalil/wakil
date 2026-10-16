import Foundation
import SwiftTerm
#if canImport(Darwin)
import Darwin
#endif

/// The shipping chain's shape, reproduced: `forkpty` (not `posix_spawn`), a
/// plain thread reading available data into an unbounded stream, and the
/// parser on the consuming side.
///
/// What is being measured is not whether it works — #38 established that — but
/// whether the *whole* chain keeps up with a shell that is trying as hard as
/// it can to produce output, and what the unbounded stream costs while it does.
final class PtyRun {
    var master: Int32 = -1
    var pid: pid_t = -1

    func spawn(_ argv: [String], cols: UInt16, rows: UInt16, cwd: String) -> Bool {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { return false }
        if child == 0 {
            // The child. Reset the signal mask as well as the dispositions:
            // libdispatch worker threads block SIGINT/SIGWINCH/SIGTERM/SIGHUP/
            // SIGCHLD, and the mask is inherited across exec.
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            for s in [SIGINT, SIGWINCH, SIGTERM, SIGHUP, SIGCHLD, SIGPIPE] { signal(s, SIG_DFL) }
            _ = chdir(cwd)
            var args = argv.map { strdup($0) }
            args.append(nil)
            _ = execv(argv[0], &args)
            _exit(127)
        }
        master = fd
        pid = child
        return true
    }

    /// kill -> EOF -> close, never close-while-parked. The ordering is the
    /// rule #38 measured into existence.
    func teardown(drainThreadDone: () -> Void) {
        if pid > 0 { kill(pid, SIGKILL) }
        drainThreadDone()
        if master >= 0 { close(master); master = -1 }
        if pid > 0 { var st: Int32 = 0; waitpid(pid, &st, 0); pid = -1 }
    }
}

struct PtyResult {
    var bytes = 0
    var reads = 0
    var largestRead = 0
    var wallToEOF = 0.0
    var parseTime = 0.0
    var peakQueued = 0
    var peakFootprint: UInt64 = 0
    /// Frames a 60 Hz poll of `getUpdateRange()` would have drawn.
    var frames60 = 0
    /// Rows those frames would have repainted in total.
    var frameRows = 0
}

/// Runs `command` under a real shell on a real pty and drives the full chain.
///
/// `consumeInline` picks which of the two shapes is measured:
///   true  — the drain thread parses as it reads (no queue, back-pressure onto
///           the pty, which is what a terminal emulator classically does)
///   false — the drain thread only enqueues, a consumer parses (the "unbounded
///           stream" the spec commits to, which cannot back-pressure)
func runPtyCommand(_ command: String, cwd: String, consumeInline: Bool,
                   cols: UInt16 = 132, rows: UInt16 = 36) -> PtyResult? {
    let run = PtyRun()
    guard run.spawn(["/bin/bash", "--noprofile", "--norc", "-i"], cols: cols, rows: rows, cwd: cwd) else { return nil }

    let del = CountingDelegate()
    let term = makeTerminal(cols: Int(cols), rows: Int(rows), delegate: del)

    var result = PtyResult()
    let lock = NSLock()
    var queue = [[UInt8]]()
    var queuedBytes = 0
    var eof = false
    var parseAccum = 0.0
    let baseline = footprintBytes()
    var peak: UInt64 = baseline

    let t0 = now()
    var lastFrame = t0
    let drain = Thread {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(run.master, $0.baseAddress, 65536) }
            if n <= 0 { break }
            lock.lock()
            result.bytes += n
            result.reads += 1
            result.largestRead = max(result.largestRead, n)
            lock.unlock()
            if consumeInline {
                let t = now()
                term.feed(buffer: buf[0..<n])
                lock.lock(); parseAccum += now() - t; lock.unlock()
            } else {
                let chunk = Array(buf[0..<n])
                lock.lock()
                queue.append(chunk)
                queuedBytes += n
                result.peakQueued = max(result.peakQueued, queuedBytes)
                lock.unlock()
            }
        }
        lock.lock(); eof = true; lock.unlock()
    }
    drain.stackSize = 1 << 20
    drain.start()

    // Ask the shell to do the work, then leave.
    let script = "\(command)\nexit\n"
    _ = script.withCString { write(run.master, $0, strlen($0)) }

    // The consumer, on this thread, for the queued shape.
    while true {
        lock.lock()
        let pending = queue
        queue.removeAll(keepingCapacity: true)
        let done = eof && pending.isEmpty
        lock.unlock()
        peak = max(peak, footprintBytes())
        // A 60 Hz poll of the dirty range, which is the only way SwiftTerm
        // reports a content change. This is the coalescing the pane gets for
        // free, and the ratio between it and `reads` is the finding.
        let tick = now()
        if tick - lastFrame >= 1.0 / 60.0 {
            lastFrame = tick
            if let rg = term.getUpdateRange() {
                result.frames60 += 1
                result.frameRows += max(0, rg.endY - rg.startY + 1)
                term.clearUpdateRange()
            }
        }
        if !consumeInline {
            for chunk in pending {
                let t = now()
                term.feed(byteArray: chunk)
                parseAccum += now() - t
                lock.lock(); queuedBytes -= chunk.count; lock.unlock()
            }
        }
        if done { break }
        if pending.isEmpty { usleep(200) }
    }
    while !drain.isFinished { usleep(200) }

    result.wallToEOF = now() - t0
    result.parseTime = parseAccum
    result.peakFootprint = peak > baseline ? peak - baseline : 0
    _ = del
    run.teardown(drainThreadDone: {})
    return result
}

func runPty(cwd: String, bigFile: String) {
    print("## Measurement 4 — the whole chain, on a real pty\n")
    print("`forkpty` + `/bin/bash --noprofile --norc -i`, 132x36, release build.\n")
    print("**Peak footprint is only meaningful from an isolated `termspike pty` run.** Under")
    print("`all` the allocator is already warm from measurement 1 and the delta collapses to")
    print("noise — it read 40.72 MB isolated and 0.14 MB in sequence, for the same work.\n")
    print("| case | shape | bytes | wall | end-to-end | parse only | reads | 60 Hz frames | peak queued | peak footprint |")
    print("|---|---|---|---|---|---|---|---|---|---|")

    let cases: [(String, String)] = [
        ("`cat` of a large file", "cat '\(bigFile)'"),
        // A scratch build path, so this is always a real build rather than an
        // up-to-date no-op — the first draft of this probe measured the no-op
        // and reported 0.00 MB. `WakilKit`, not the whole package: `WakilApp`
        // carries a `default.metallib` that only `make` generates, so a
        // scratch-path build of it fails in four lines and measures nothing.
        ("a build's output (quiet)", "rm -rf /tmp/termspike-bp && swift build -c debug --target WakilKit --build-path /tmp/termspike-bp 2>&1 || true"),
        ("a build's output (-v)", "rm -rf /tmp/termspike-bpv && swift build -c debug --target WakilKit -v --build-path /tmp/termspike-bpv 2>&1 || true"),
    ]
    for (label, cmd) in cases {
        for inline in [true, false] {
            guard let r = runPtyCommand(cmd, cwd: cwd, consumeInline: inline) else {
                print("| \(label) | \(inline ? "inline" : "queued") | spawn failed | | | | | | | |")
                continue
            }
            print("| \(label) | \(inline ? "inline parse" : "unbounded queue") | \(sized(r.bytes)) | \(String(format: "%.3f s", r.wallToEOF)) | \(rate(r.bytes, r.wallToEOF)) | \(String(format: "%.3f s", r.parseTime)) | \(r.reads) (max \(r.largestRead) B) | \(r.frames60) (\(r.frameRows) rows) | \(mb(r.peakQueued)) | \(mb(r.peakFootprint)) |")
        }
    }
    print("")
}
