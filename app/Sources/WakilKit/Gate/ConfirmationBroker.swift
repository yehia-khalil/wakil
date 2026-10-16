import Foundation

/// Holds at most one refused mutation while a human decides about it.
///
/// This is the whole of the answer to a problem
/// `phase-2b-i-acceptance.md` recorded on 2026-09-08 and left open:
/// `MCPServer` reads `confirmation` as a sibling of `name`/`arguments` in
/// `tools/call` params, *"a field no conforming MCP client sends, so a real
/// agent hitting this row gets a hard refusal rather than a confirmable
/// gate."*
///
/// **The fix is not to let the agent send it.** Invariant 7 — "voice may
/// propose a mutation; only typed confirmation may execute one" — is a
/// statement about *who* confirms, and an agent emitting the string
/// "confirm" is not a human typing it. So `confirmation` stays a sibling
/// no client can reach, and the refusal stops being a dead end instead:
/// the proposal parks here, a human decides, and the same call is
/// re-dispatched.
///
/// `ActionRegistry.dispatch` knows nothing about any of this and is
/// unchanged. Parking happens strictly above it.
///
/// **Single-flight.** One proposal at a time; a second is refused `.busy`.
/// A queue would need an ordering rule, a UI that can show more than one,
/// and an answer for what happens when two confirmations contradict each
/// other — none of it worth building before anyone has confirmed one
/// mutation.
public actor ConfirmationBroker {
    private var pending: PendingMutation?
    private var waiter: CheckedContinuation<ConfirmationDecision, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PendingMutation?>.Continuation] = [:]
    private let timeout: Duration

    /// 120 seconds. Long enough to read a statement and decide; short
    /// enough that an agent whose operator walked away is eventually told
    /// so rather than blocking forever. One constant, in one place, so the
    /// tuning pass is a one-line edit.
    public static let defaultTimeout: Duration = .seconds(120)

    public init(timeout: Duration = ConfirmationBroker.defaultTimeout) {
        self.timeout = timeout
    }

    /// Parks `proposal` and suspends until someone decides, or the timeout
    /// expires. Returns `.busy` immediately, without parking, if another
    /// proposal is already held.
    public func request(_ proposal: PendingMutation) async -> ConfirmationDecision {
        if pending != nil { return .busy }
        pending = proposal
        publish(proposal)

        // Nothing between here and the continuation suspends, so `waiter`
        // is set before any `approve`/`cancel`/expiry can run on this
        // actor — actor reentrancy needs a suspension point to interleave,
        // and creating a Task is not one.
        let id = proposal.id
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id: id, with: .expired)
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    public func approve(id: String) { resolve(id: id, with: .approved) }
    public func cancel(id: String) { resolve(id: id, with: .cancelled) }

    /// What is parked right now, for the surface to render.
    ///
    /// `async` costs nothing on the ordinary path — `holdNextCurrentForTesting`
    /// defaults `false`, and every real caller already writes `await
    /// confirmations.current()` regardless (any actor call crossing
    /// isolation needs `await` whether or not the method itself is marked
    /// `async`). It exists so this one call can be held open on demand —
    /// see `holdNextCurrentForTesting` below.
    public func current() async -> PendingMutation? {
        if holdNextCurrentForTesting {
            holdNextCurrentForTesting = false
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                currentGateForTesting = k
            }
        }
        return pending
    }

    /// TEST-ONLY. When armed via `armHoldNextCurrentForTesting()`, the
    /// very next call to `current()` suspends here instead of answering
    /// immediately, until `releaseHeldCurrentForTesting()` resumes it.
    /// Cleared the moment it is consumed, so only the one armed call is
    /// ever held — the same one-shot shape
    /// `WindowModelTests.StubHarness.holdNextSend` uses.
    ///
    /// Built for `WindowModel.fireQueuedSwitchIfReady()`'s fix-round-2
    /// test (Task 11): that method's only suspension point is exactly
    /// `await confirmations.current()`, and proving a plain synchronous
    /// mutator (`cancelQueuedSwitch()`) can land inside that window needs
    /// the suspension held open deterministically — plain scheduling
    /// (two `async let`s, or a bare `Task.yield()`) measured unreliable
    /// once other tests were sharing the executor (see that test's own
    /// doc comment).
    private var holdNextCurrentForTesting = false
    private var currentGateForTesting: CheckedContinuation<Void, Never>?

    /// TEST-ONLY: arms the hold described above.
    func armHoldNextCurrentForTesting() {
        holdNextCurrentForTesting = true
    }

    /// TEST-ONLY: releases a `current()` call parked by the armed hold. A
    /// no-op if nothing is currently held.
    func releaseHeldCurrentForTesting() {
        currentGateForTesting?.resume()
        currentGateForTesting = nil
    }

    /// TEST-ONLY: whether a `current()` call armed by
    /// `armHoldNextCurrentForTesting()` has actually reached the hold and
    /// is parked there right now — what a test polls so it never acts on
    /// the hold before the call it is meant to catch has genuinely
    /// suspended inside it.
    func isHoldingCurrentForTesting() -> Bool {
        currentGateForTesting != nil
    }

    /// A stream of the parked proposal, or `nil` when nothing is parked.
    ///
    /// A subscriber that arrives while a proposal is already parked is
    /// caught up immediately, so it sees the proposal without having to
    /// wait for the next park/release edge. A subscriber that arrives when
    /// nothing is parked gets nothing until something actually happens —
    /// emitting an initial `nil` unconditionally would put a spurious
    /// "released" event ahead of the first real park, which is not a fact
    /// about anything that occurred.
    public func updates() -> AsyncStream<PendingMutation?> {
        AsyncStream { continuation in
            let key = UUID()
            subscribers[key] = continuation
            if let pending { continuation.yield(pending) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(key) }
            }
        }
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    /// Resolves the parked proposal, but only if `id` names it.
    ///
    /// The id check is what makes a stale decision harmless: a click on a
    /// plane that has already been dismissed, or a timeout that fires just
    /// after an approval, names a proposal that is no longer parked and is
    /// ignored — rather than approving whatever happens to be parked next.
    private func resolve(id: String, with decision: ConfirmationDecision) {
        guard let parked = pending, parked.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = waiter
        waiter = nil
        publish(nil)
        continuation?.resume(returning: decision)
    }

    private func publish(_ value: PendingMutation?) {
        for continuation in subscribers.values { continuation.yield(value) }
    }
}
