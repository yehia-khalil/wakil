import Foundation

/// One request to change which conversation a place shows (conversations 2 of 3).
public enum ConversationRequest: Sendable, Equatable {
    /// Put `conversation` — the operator's screen's when they asked, or nil, the screen's when
    /// this drains — into the background and show its place's Landing. One no longer on screen in
    /// its place, or a Landing's reserved id, is nothing to do.
    case new(conversation: String?)
    /// Bring back the live conversation `conversation` names, by id or by title; a title is
    /// looked up in `place` — nil, the screen's.
    case switchTo(conversation: String, place: Place?)
    /// End `conversation` — the operator's screen's when they asked, or nil, the screen's when
    /// this drains (conversations 3 of 3): `WindowModel.closeConversation`, which asks first only
    /// with work in flight. A Landing's reserved id, or one no longer live, is nothing to do.
    case close(conversation: String?)
}

/// Where a `session_new`, `session_switch` or `session_close` request waits for the window to act on it — the
/// structural counterpart of `ProviderSwitchBroker`, for the same reason: `registerStandardActions`
/// runs inside `WakilWiring.build`, before any `WindowModel` exists, so the handlers it registers
/// cannot close over a model. They park here, and the window's `conversationPump` drains it.
///
/// Both actions are operator-only (`operatorOnlyActions`): an agent must not push aside the
/// operator's conversation, so the agent never reaches `request(_:)`.
///
/// One buffered request survives a period with no subscriber, and exactly one subscriber is ever
/// allowed — see `ResumeBroker`'s doc comment for the argument, which applies unchanged: a second
/// consumer would either drop a switch (split) or perform it twice (duplicated).
public actor ConversationBroker {
    private var continuation: AsyncStream<ConversationRequest>.Continuation?
    private var buffered: [ConversationRequest] = []
    private var requestsCalled = false
    private var subscriberGone = false

    public init() {}

    public func request(_ r: ConversationRequest) {
        guard let continuation else {
            guard !subscriberGone else { return }
            buffered.append(r)
            return
        }
        continuation.yield(r)
    }

    /// Returns the stream of conversation requests. Exactly one caller may ever receive it — see
    /// `ResumeBroker.requests()` for why a second call crashes.
    public func requests() -> AsyncStream<ConversationRequest> {
        guard !requestsCalled else {
            preconditionFailure(
                "ConversationBroker.requests() was already called once on this instance; "
                    + "only a single consumer of the conversation-request stream is supported, "
                    + "because a second concurrent consumer would either drop requests (if elements "
                    + "split between the two) or switch twice (if elements duplicated to both)."
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
