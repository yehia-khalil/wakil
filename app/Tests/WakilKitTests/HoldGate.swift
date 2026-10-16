import Foundation

/// **A one-shot hold a test double parks inside, which a release can never
/// miss.**
///
/// The harness doubles (`StubHarness`, `FakeHarnessForQueueTests`) hold
/// `start`/`send`/`stop` open so a test can act at an exact point in
/// `WindowModel`. Each used to park on a bare `CheckedContinuation` stored in
/// a `var`, with a `release…()` that resumed it "if anything is held". The
/// test decides when to release from a signal the model gives — a log line,
/// `turnInFlight` — and that signal is raised BEFORE the double stores its
/// continuation, on another executor: the double's `async` methods are
/// nonisolated, so they run on the cooperative pool while the test runs on
/// the main actor. On a loaded pool the release could run first, find
/// nothing held, do nothing, and the double then parked forever. The test
/// awaited its `send` task, the run never ended, and the process sat idle at
/// 0% CPU with every thread parked (2026-10-09, `hang-report.md`).
///
/// This gate latches: a release that lands before the waiter arrives is kept,
/// and the waiter passes straight through. It only latches while armed, so a
/// release with no hold asked for still changes nothing later — the old
/// "a no-op if nothing is held" stays true of a gate nobody armed. The lock
/// is never held across a suspension.
final class HoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Asks for the next `wait()` to park until `release()`.
    func arm() {
        lock.lock()
        armed = true
        released = false
        lock.unlock()
    }

    /// Whether the next `wait()` would park — read by a double to decide, and
    /// cleared by `wait()` itself, so each `arm()` holds exactly once.
    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    /// Parks until `release()`, or returns at once if it already came or the
    /// gate was never armed.
    func wait() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !armed || released {
                armed = false
                released = false
                lock.unlock()
                k.resume()
                return
            }
            waiter = k
            lock.unlock()
        }
    }

    /// Lets the parked (or next) `wait()` through. Does nothing to a gate
    /// that is not armed.
    func release() {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        let parked = waiter
        waiter = nil
        if parked != nil {
            armed = false
        } else {
            released = true
        }
        lock.unlock()
        parked?.resume()
    }
}
