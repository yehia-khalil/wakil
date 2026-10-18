import Foundation

/// One request to leave the current agent session and fork a past one.
public struct ResumeRequest: Sendable, Equatable {
    /// The session to fork from — the parent. The child's id is minted by
    /// whoever performs the swap, because Wakil mints every session id it
    /// runs.
    public let sessionId: String
    /// The place whose session the fork replaces: an agent caller's own (`pinnedPlace(of:)`),
    /// so an agent's `session_resume` acts where it works whatever is on screen. Nil — the
    /// operator, `--dispatch` — is the place on screen.
    public let place: Place?

    public init(sessionId: String, place: Place? = nil) {
        self.sessionId = sessionId
        self.place = place
    }
}

/// Where a resume request waits for the window to act on it.
///
/// **Deliberately not `ConfirmationBroker`, whose `request` suspends until
/// a human decides.** A resume swaps the agent process, so the MCP handler
/// that asked for it is about to be killed by its own request: a reply
/// sent after the swap can never arrive, because the shim's socket dies
/// with `claude`. So this parks and returns, the handler answers
/// immediately, and the window performs the swap on its own next turn —
/// by which time the agent has its result.
///
/// One buffered request survives a period with no subscriber: the window
/// subscribes in `init`, so in practice there always is one, but an
/// unbuffered stream would make the ordering between subscribing and the
/// first request load-bearing for no reason.
///
/// **Lifecycle: one broker per window, one subscriber, for that window's
/// whole life.** `WakilWiring.build` is the only place a shipped assembly
/// is made, and `WindowSession.start()` calls it once per window — a
/// `ResumeBroker` will be built there alongside the `ConfirmationBroker`
/// it already builds. The window's model subscribes exactly once, in its
/// own initialiser, and holds that one stream for as long as the window
/// lives; the stream terminates only when the model is torn down, at which
/// point the broker goes with it. So an instance is never shared across
/// windows and never resubscribed after its one subscriber is gone — a
/// window closing and reopening gets a new window and a new broker, not
/// this one again. That is what makes the single-consumer gate in
/// `requests()` below permanent rather than something that should reset
/// once the stream ends.
public actor ResumeBroker {
    private var continuation: AsyncStream<ResumeRequest>.Continuation?
    private var buffered: [ResumeRequest] = []
    private var requestsCalled = false
    /// Set once the sole subscriber's stream has terminated. Per the
    /// lifecycle above, that subscriber is never replaced, so from this
    /// point on the instance is permanently spent.
    private var subscriberGone = false

    public init() {}

    public func request(_ r: ResumeRequest) {
        guard let continuation else {
            // The buffer exists to bridge the gap before the one
            // subscriber has arrived. Once it has come and gone, there is
            // nothing left to bridge to — the gate never lets a
            // replacement subscriber drain it — so queueing here would
            // just hoard requests forever, silently. Drop instead.
            guard !subscriberGone else { return }
            buffered.append(r)
            return
        }
        continuation.yield(r)
    }

    /// Returns the stream of resume requests. **Exactly one caller may ever
    /// receive it.**
    ///
    /// Same guarantee as `ClaudeCodeCLIHarness.events()`, and for the same
    /// reason: measured directly on this machine, handing one `AsyncStream`
    /// to two concurrent `for await` consumers does not duplicate elements
    /// between them, it *splits* them — of 6 values yielded, one consumer
    /// saw 3 and the other saw the other 3, each permanently missing what
    /// the other got. Here a second subscriber would be wrong either way a
    /// split or a duplicate landed: split, and a resume is silently dropped
    /// on the floor; duplicated, and the window performs the same swap
    /// twice, tearing down a harness a previous iteration already replaced
    /// with a fresh one. Neither failure looks like anything at the call
    /// site — the second `requests()` call still returns a stream that
    /// looks perfectly usable. So this is enforced rather than left as a
    /// caller responsibility: a second call is a programmer error and
    /// crashes immediately via `preconditionFailure`, rather than silently
    /// handing back a stream that would cannibalise the first subscriber.
    /// The window is the only intended subscriber and subscribes once, in
    /// its initialiser, so this costs nothing today.
    public func requests() -> AsyncStream<ResumeRequest> {
        guard !requestsCalled else {
            preconditionFailure(
                "ResumeBroker.requests() was already called once on this instance; "
                    + "only a single consumer of the resume-request stream is supported, because a "
                    + "second concurrent consumer would either drop requests (if elements split "
                    + "between the two) or double-swap (if elements duplicated to both)."
            )
        }
        requestsCalled = true
        return AsyncStream { continuation in
            self.continuation = continuation
            for r in buffered {
                continuation.yield(r)
            }
            buffered.removeAll()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearContinuation() }
            }
        }
    }

    private func clearContinuation() {
        continuation = nil
        subscriberGone = true
    }

    /// How many requests are sitting in the pre-subscription buffer. Not
    /// part of the public API — `internal` by default so only
    /// `@testable import WakilKit` can see it — and exists purely so a
    /// test can observe that `request(_:)` is actually dropping rather
    /// than silently hoarding once `subscriberGone` is set, which
    /// otherwise has no externally visible effect.
    func bufferedRequestCount() -> Int { buffered.count }

    /// Whether the sole subscriber's stream has terminated. Not part of
    /// the public API; exists so a test can deterministically wait for
    /// `clearContinuation()` to actually land — it is dispatched from
    /// `onTermination` via `Task { await self?.clearContinuation() }`,
    /// which runs off this actor and is not ordered against the test's
    /// own await on the consuming task's cancellation.
    func hasLostItsSubscriber() -> Bool { subscriberGone }
}
