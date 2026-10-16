import Foundation

/// One request to switch this window's session to another provider.
public struct ProviderSwitchRequest: Sendable, Equatable {
    public let providerId: String

    public init(providerId: String) {
        self.providerId = providerId
    }
}

/// Where a `session_set_provider` request waits for the window to act on
/// it — the exact structural counterpart of `ResumeBroker`, and for the
/// same underlying reason: `registerStandardActions` runs once, inside
/// `WakilWiring.build`, strictly before any `WindowModel` exists, so the
/// handler it registers cannot close over a `model` to call
/// `setProvider` on directly. Parking a request here and draining it from
/// the window's own initialiser is what lets `session_set_provider` live
/// in the ordinary registration function anyway, beside `session_resume`
/// and `session_record_parent`.
///
/// **Not `ConfirmationBroker`.** Its `request` suspends until a human
/// decides, which is right for a mutation an operator must approve, but
/// wrong here: this is a `.control` action with a security-critical
/// property enforced elsewhere entirely (`permissionDecision`'s
/// `operatorOnlyActions` denylist keeps the agent from ever reaching this
/// broker's `request(_:)` at all — see that constant's own doc comment).
/// A ⌘K selection that dispatched this and then hung until the window's
/// own pump got around to it would be a worse UI than the pump simply
/// draining it on its own next scheduling turn, which is all `resume`'s
/// identical broker ever promises either.
///
/// One buffered request survives a period with no subscriber, and exactly
/// one subscriber is ever allowed — see `ResumeBroker`'s doc comment for
/// the full argument, which applies here unchanged: a second concurrent
/// consumer would either drop a switch on the floor (split) or perform it
/// twice (duplicated), and neither failure looks like anything at the
/// call site.
public actor ProviderSwitchBroker {
    private var continuation: AsyncStream<ProviderSwitchRequest>.Continuation?
    private var buffered: [ProviderSwitchRequest] = []
    private var requestsCalled = false
    private var subscriberGone = false

    public init() {}

    public func request(_ r: ProviderSwitchRequest) {
        guard let continuation else {
            guard !subscriberGone else { return }
            buffered.append(r)
            return
        }
        continuation.yield(r)
    }

    /// Returns the stream of provider-switch requests. Exactly one caller
    /// may ever receive it — see `ResumeBroker.requests()` for why a
    /// second call crashes rather than silently handing back a stream
    /// that would cannibalise the first subscriber.
    public func requests() -> AsyncStream<ProviderSwitchRequest> {
        guard !requestsCalled else {
            preconditionFailure(
                "ProviderSwitchBroker.requests() was already called once on this instance; "
                    + "only a single consumer of the provider-switch-request stream is supported, "
                    + "because a second concurrent consumer would either drop requests (if elements "
                    + "split between the two) or double-switch (if elements duplicated to both)."
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
}
