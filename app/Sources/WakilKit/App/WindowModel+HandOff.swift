import Foundation

/// What the operator's Start hands to an agent (ticket noticing, Task 9): the ticket key (nil for
/// a PR with no key) and its PR, the thread it is handed from (nil from the header or ⌘P), the
/// brief — its first line the conversation's title — the harness and provider Start runs, the
/// place it runs in, the root and branch it works on, and the popover's May push.
public struct TicketHandOffRequest: Sendable, Equatable {
    public let key: String?
    public let pr: Int?
    public let thread: String?
    public let brief: String
    public let harness, provider: String
    public let place: Place
    public let root, branch: String
    public let mayPush: Bool
    /// The PR's repository (`github.com/initech/api`), which keeps a hand-off from a PR with no
    /// ticket key (`pr:<repo>#<n>`); nil for a ticket's.
    public let repo: String?

    public init(key: String?, pr: Int?, thread: String?, brief: String, harness: String, provider: String,
                place: Place, root: String, branch: String, mayPush: Bool, repo: String? = nil) {
        self.key = key
        self.pr = pr
        self.thread = thread
        self.brief = brief
        self.harness = harness
        self.provider = provider
        self.place = place
        self.root = root
        self.branch = branch
        self.mayPush = mayPush
        self.repo = repo
    }

    /// The brief's first line: the conversation's title and the hand-off's.
    var firstLine: String { String(brief.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
}

/// A Start that did not start: the window's own sentence for why, whole (Rule 8).
public struct TicketHandOffError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

/// A handed conversation (spec, *Hand to agent*, *What a handed agent may do without asking*): an
/// ordinary agent conversation started off screen, through the one start path (`send`), pinned to
/// its place; its push, sync, publish, merge and rebase priced tighter (`handedAgentPrice`), May
/// push read from its stored hand-off.
extension WindowModel {
    /// Starts a hand-off: a conversation in `r.place` that no screen shows (`backgroundAgent`) —
    /// the screen, its conversation and its canvas are untouched — whose first message is the
    /// brief, sent by `send` with a scope pinned to it, so the turn lands nowhere else. `reserved`
    /// is told its id before the send, so a Cancel can name it. A send that fails closes the
    /// conversation and throws the window's status, whole. Then the hand-off is recorded
    /// (`ticket_handoff_write` `add`); a record that fails leaves the conversation running, handed
    /// with May push off, and says why on its chip and in its thread. Returns its id.
    public func startHandOff(_ r: TicketHandOffRequest, reserved: ((String) -> Void)? = nil) async throws -> String {
        let agent = backgroundAgent(in: r.place, providerId: r.provider)
        agent.handoff = PlaceAgentHandoff(key: r.key, pr: r.pr, thread: r.thread, root: r.root, branch: r.branch, mayPush: r.mayPush)
        // The chip reads well: the brief's first line, not the whole brief (conversations call 6).
        agent.title = conversationTitle(r.firstLine)
        reserved?(agent.id)
        let scope = TurnScope(place: r.place, rootPath: r.root, providerId: r.provider, conversation: agent.id)
        guard await send(r.brief, scope: scope) else {
            let why = status.isEmpty ? "the agent did not start" : status
            if conversation(id: agent.id) === agent { await endConversation(agent) }
            throw TicketHandOffError(description: why)
        }
        guard conversation(id: agent.id) === agent else {
            throw TicketHandOffError(description: "the hand-off was cancelled before it started")
        }
        guard let ticket else {
            noteHandOffFailure("The hand-off was not recorded (no ticket client), so this conversation's push and sync ask you.", in: agent)
            return agent.id
        }
        var handoff: [String: JSONValue] = [
            "conversation": .string(agent.id), "title": .string(r.firstLine), "harness": .string(r.harness),
            "provider": .string(r.provider),
            "place": .object(["organization": .string(r.place.organization), "project": .string(r.place.project),
                              "environment": .string(r.place.environment)]),
        ]
        if let thread = r.thread { handoff["thread"] = .string(thread) }
        // A PR with no ticket key is kept by its PR (`pr:<repo>#<n>`).
        let key = r.key ?? r.pr.flatMap { pr in r.repo.map { "pr:\($0)#\(pr)" } } ?? ""
        do {
            try await ticket.addHandoff(key: key, handoff: .object(handoff), mayPush: r.mayPush, as: handOffCaller(agent))
        } catch {
            noteHandOffFailure("The hand-off was not recorded (\(error)), so this conversation's push and sync ask you.", in: agent)
        }
        return agent.id
    }

    /// Cancel: ends the conversation a Start reserved, whatever its start has reached (Rule 4) —
    /// its harness is stopped and its hand-off, if recorded, ends. Asks nothing: the operator
    /// pressed Cancel.
    public func cancelHandOff(_ conversation: String) async {
        guard let agent = self.conversation(id: conversation), agent.handoff != nil else { return }
        await endConversation(agent)
    }

    /// A handed agent's turn ended: its root's ticket is read again (`ticket_branch`), then In
    /// flight — its push or its draft shows. Only for the organisation on screen: the window's
    /// store holds that one's (Invariant 4).
    func handOffTurnEnded(_ agent: PlaceAgent) async {
        guard let ticket, let h = agent.handoff, agent.place.organization == organization else { return }
        if !h.root.isEmpty { _ = try? await ticket.read(root: h.root) }
        await ticketNeedsRead(force: true)
    }

    /// The organisation's hand-offs whose conversation is not live end (`ticket_handoff_write`
    /// `end`, `keepLive`, the live ids): a quit or a switch left them with none. A failure is said
    /// whole in the window's status: no chip is left to carry it.
    func endStaleHandOffs() async {
        guard let ticket else { return }
        do {
            try await ticket.endStaleHandoffs(live: liveConversations().map(\.id))
        } catch {
            say("hand-offs not ended: \(error)")
        }
    }

    /// Ends a closed conversation's hand-off. A failure is said whole in the window's status: its
    /// chip went with it.
    func endHandOff(of agent: PlaceAgent) async {
        guard let ticket else { return }
        do {
            try await ticket.endHandoff(conversation: agent.id, as: handOffCaller(agent))
        } catch {
            say("hand-off not ended: \(error)")
        }
    }

    /// F16: `agent` resumed a session of conversation `from` (its lineage root): when `from` was
    /// handed, its hand-off is carried to `agent`'s id, so its git writes stay priced as handed. A
    /// carry that fails leaves `agent` handed with May push off — fail closed — and says why.
    func carryHandOff(from: String, to agent: PlaceAgent, root: String) async {
        guard let ticket else { return }
        do {
            guard let (key, h) = try await ticket.carryHandoff(from: from, to: agent.id, as: handOffCaller(agent)) else { return }
            let pr = parsedPRHandoffKey(key)
            agent.handoff = PlaceAgentHandoff(
                key: pr == nil ? key : nil, pr: pr?.number, thread: h["thread"].flatMap { if case .string(let t) = $0, !t.isEmpty { t } else { nil } },
                root: root, branch: "", mayPush: h["mayPush"] == .bool(true))
        } catch {
            agent.handoff = PlaceAgentHandoff(key: nil, pr: nil, thread: nil, root: root, branch: "", mayPush: false)
            noteHandOffFailure(
                "Wakil could not carry this conversation's hand-off (\(error)), so its push, sync, publish, merge and rebase ask you.",
                in: agent)
        }
    }

    /// The gate's handed lookup (`ActionRegistry.setHandedLookup`): the hand-off of the caller's
    /// conversation, with May push on only when the hand-off's own (the Start's, or the carried
    /// record's) and the stored one (`ticket_handoff_may_push`) both say on, and no spoken message
    /// is unanswered in it (Invariant 7: a spoken turn asks before every git write). Nil for a
    /// conversation not handed.
    func handedPricing(for caller: DispatchCaller) async -> PlaceAgentHandoff? {
        guard let id = caller.conversation, let agent = conversation(id: id), let h = agent.handoff else { return nil }
        guard h.mayPush, let ticket else { return h.priced(mayPush: false) }
        let stored = await ticket.handoffMayPush(conversation: id, as: handOffCaller(agent))
        return h.priced(mayPush: stored && !agent.spoken)
    }

    /// Whom a hand-off call is for: the conversation's own place, so it reaches that
    /// organisation's `wakil-ticket` wherever the screen is (`PlaceRoutedCaller`), with a session
    /// named even after its harness stopped.
    private func handOffCaller(_ agent: PlaceAgent) -> DispatchCaller {
        DispatchCaller(place: agent.place, session: agent.sessionId ?? agent.id, conversation: agent.id)
    }

    /// Says a hand-off's failure whole: on its chip and in its thread (Rule 8).
    private func noteHandOffFailure(_ note: String, in agent: PlaceAgent) {
        agent.handoffFailure = note
        agent.appendRow(label: "hand-off", detail: note, isError: true)
    }
}

/// A `pr:<repo>#<n>` hand-off key's parts, as `wakilcore.ParsePRHandoffKey` reads them; nil for a
/// ticket key.
private func parsedPRHandoffKey(_ key: String) -> (repo: String, number: Int)? {
    guard key.hasPrefix("pr:"), let hash = key.lastIndex(of: "#"),
          let n = Int(key[key.index(after: hash)...]), n > 0 else { return nil }
    let repo = String(key[key.index(key.startIndex, offsetBy: 3)..<hash])
    return repo.isEmpty ? nil : (repo, n)
}
