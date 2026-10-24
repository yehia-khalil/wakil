import Foundation

/// Where a proposal waits: a place and, for an agent's, the conversation that proposed it.
/// The operator's own proposals take the place slot (`conversation` nil).
public struct ProposalSlot: Hashable, Sendable {
    public let place: Place
    public let conversation: String?

    public init(place: Place, conversation: String?) {
        self.place = place
        self.conversation = conversation
    }
}

/// Holds at most one refused mutation per slot (`ProposalSlot`) while a human decides about it.
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
/// **Single-flight per slot.** A slot is a place and, for an agent's proposal, the conversation
/// that made it (`ProposalSlot`, `PendingMutation.slot`); the operator's own proposals take the
/// place's slot, with no conversation. Each slot holds one proposal at a time; a second in the
/// same slot is refused `.busy`. Other slots — another conversation's, another place's, the
/// operator's beside an agent's — wait side by side, and the plane draws only the screen's. A
/// queue within a slot would need an ordering rule and an answer for two confirmations that
/// contradict each other — none of it worth building.
///
/// **Only the operator's proposals expire (R1).** An agent's waits until the operator approves
/// or cancels it — Rule 4: Cancel is how a wait ends, and an agent in a place the operator is
/// not looking at would otherwise be told "nobody answered" while nobody could. A `.ui`
/// proposal keeps `timeout`.
public actor ConfirmationBroker {
    private var pending: [ProposalSlot: PendingMutation] = [:]
    private var waiters: [ProposalSlot: CheckedContinuation<ConfirmationDecision, Never>] = [:]
    private var timeoutTasks: [ProposalSlot: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<[Place: PendingMutation]>.Continuation] = [:]
    private var slotSubscribers: [UUID: AsyncStream<[ProposalSlot: PendingMutation]>.Continuation] = [:]
    private let timeout: Duration

    /// 120 seconds, for the operator's own proposals. Long enough to read a statement and
    /// decide; short enough that a plane they walked away from frees their place's slot. One
    /// constant, in one place, so the tuning pass is a one-line edit.
    public static let defaultTimeout: Duration = .seconds(120)

    public init(timeout: Duration = ConfirmationBroker.defaultTimeout) {
        self.timeout = timeout
    }

    /// Parks `proposal` in its place and suspends until someone decides, or — for a `.ui`
    /// proposal only — the timeout expires. Returns `.busy` immediately, without parking, if
    /// that place already holds one.
    public func request(_ proposal: PendingMutation) async -> ConfirmationDecision {
        let slot = proposal.slot
        if pending[slot] != nil { return .busy }
        pending[slot] = proposal
        publish()

        // Nothing between here and the continuation suspends, so the waiter
        // is set before any `approve`/`cancel`/expiry can run on this
        // actor — actor reentrancy needs a suspension point to interleave,
        // and creating a Task is not one.
        if proposal.origin != .agent {
            let id = proposal.id
            timeoutTasks[slot] = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(id: id, with: .expired)
            }
        }
        return await withCheckedContinuation { continuation in
            waiters[slot] = continuation
        }
    }

    public func approve(id: String) { resolve(id: id, with: .approved) }
    public func cancel(id: String) { resolve(id: id, with: .cancelled) }

    /// Cancels the agent's proposal parked in `place`, if one is: its session is being stopped
    /// or replaced (final review I2). An agent's never expires (R1), so one left by a session
    /// that is gone would hold the place's slot for ever, and its successor's every gated call
    /// would be `.busy`. The request returns `.cancelled` to the MCP call that is waiting on it.
    /// The operator's own proposal in that place is theirs, not the session's, and stays.
    public func cancelAgentProposal(in place: Place) {
        for (slot, parked) in pending where slot.place == place && parked.origin == .agent {
            resolve(id: parked.id, with: .cancelled)
        }
    }

    /// Cancels the agent proposal parked for conversation `id`, in whichever place holds it.
    public func cancelAgentProposal(inConversation id: String) {
        for (slot, parked) in pending where slot.conversation == id && parked.origin == .agent {
            resolve(id: parked.id, with: .cancelled)
        }
    }

    /// Cancels everything parked, in every place: the window is closing, and every request
    /// waiting here must return.
    public func cancelAll() {
        for parked in pending.values { resolve(id: parked.id, with: .cancelled) }
    }

    /// What is parked in `place`, for the plane to render when that place is on screen.
    ///
    /// A place's projection: the operator's proposal (the place slot) if one is parked, else the
    /// place's agent proposal with the lowest conversation id.
    public func current(for place: Place) async -> PendingMutation? {
        await holdIfTesting()
        return Self.project(pending)[place]
    }

    /// What is parked in exactly `slot`.
    public func current(in slot: ProposalSlot) async -> PendingMutation? {
        await holdIfTesting()
        return pending[slot]
    }

    private func holdIfTesting() async {
        if holdNextCurrent {
            holdNextCurrent = false
            await withCheckedContinuation { heldCurrent = $0 }
        }
    }

    /// One proposal per place: the place slot's, else the lowest conversation id's.
    static func project(_ slots: [ProposalSlot: PendingMutation]) -> [Place: PendingMutation] {
        var out: [Place: PendingMutation] = [:]
        var best: [Place: ProposalSlot] = [:]
        for (slot, parked) in slots {
            if let held = best[slot.place] {
                let wins: Bool
                switch (slot.conversation, held.conversation) {
                case (nil, _): wins = true
                case (_, nil): wins = false
                case let (new?, old?): wins = new < old
                }
                if !wins { continue }
            }
            out[slot.place] = parked
            best[slot.place] = slot
        }
        return out
    }

    // MARK: Test hold

    /// TEST-ONLY: set, the next `current(for:)` waits until `releaseHeldCurrentForTesting`, so a
    /// test can move the window while a caller is suspended there (`setProvider`'s guard).
    private var holdNextCurrent = false
    private var heldCurrent: CheckedContinuation<Void, Never>?

    func holdNextCurrentForTesting() { holdNextCurrent = true }
    var holdingCurrentForTesting: Bool { heldCurrent != nil }
    func releaseHeldCurrentForTesting() {
        heldCurrent?.resume()
        heldCurrent = nil
    }

    /// Everything parked, by place (the place projection; see `current(for:)`).
    public func all() -> [Place: PendingMutation] { Self.project(pending) }

    /// Everything parked, by slot.
    public func allSlots() -> [ProposalSlot: PendingMutation] { pending }

    /// `updates()`, by slot.
    public func slotUpdates() -> AsyncStream<[ProposalSlot: PendingMutation]> {
        AsyncStream { continuation in
            let key = UUID()
            slotSubscribers[key] = continuation
            if !pending.isEmpty { continuation.yield(pending) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribeSlots(key) }
            }
        }
    }

    private func unsubscribeSlots(_ key: UUID) { slotSubscribers[key] = nil }

    /// A stream of everything parked, by place, after every park and release.
    ///
    /// A subscriber that arrives while something is already parked is
    /// caught up immediately, so it sees it without having to
    /// wait for the next park/release edge. A subscriber that arrives when
    /// nothing is parked gets nothing until something actually happens —
    /// emitting an initial empty value unconditionally would put a spurious
    /// "released" event ahead of the first real park, which is not a fact
    /// about anything that occurred.
    public func updates() -> AsyncStream<[Place: PendingMutation]> {
        AsyncStream { continuation in
            let key = UUID()
            subscribers[key] = continuation
            if !pending.isEmpty { continuation.yield(Self.project(pending)) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(key) }
            }
        }
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    /// Resolves the parked proposal `id` names, in whichever place holds it.
    ///
    /// The id check is what makes a stale decision harmless: a click on a
    /// plane that has already been dismissed, or a timeout that fires just
    /// after an approval, names a proposal that is no longer parked and is
    /// ignored — rather than approving whatever happens to be parked next.
    private func resolve(id: String, with decision: ConfirmationDecision) {
        guard let slot = pending.first(where: { $0.value.id == id })?.key else { return }
        pending[slot] = nil
        timeoutTasks.removeValue(forKey: slot)?.cancel()
        let continuation = waiters.removeValue(forKey: slot)
        publish()
        continuation?.resume(returning: decision)
    }

    private func publish() {
        let byPlace = Self.project(pending)
        for continuation in subscribers.values { continuation.yield(byPlace) }
        for continuation in slotSubscribers.values { continuation.yield(pending) }
    }
}
