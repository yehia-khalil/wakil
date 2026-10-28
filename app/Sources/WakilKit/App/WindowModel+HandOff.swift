import Foundation

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

    /// What the Hand to agent popover opens with (Task 10): the place on screen and its provider,
    /// the organisation's Claude Code bindings, and each project's environments with their
    /// production flags — from the settings tree the window holds, read when it holds none. A tree
    /// that cannot be read leaves the lists empty: the place's own provider still defaults.
    func handOffContext() async -> TicketHandOffContext {
        var tree = settings
        if tree == nil, let result = try? await registry.dispatch(
            name: "ctx_config_tree", params: .object([:]), origin: .ui,
            caller: DispatchCaller(place: place, session: nil), confirmation: nil) {
            tree = decodeSettingsTree(fromResult: result)
        }
        let harness = ticketHandOffHarnesses[0].id
        let providers = (tree?.providers ?? []).filter { $0.kind == harness }.map { TicketHandOffProvider(id: $0.id, label: $0.label) }
        var environments: [String: [TicketHandOffEnvironment]] = [:]
        for p in tree?.projects ?? [] {
            environments[p.name] = p.environments.map { e in
                // Not known is production (`SettingsEnvironment.production`): it fails toward asking.
                TicketHandOffEnvironment(name: e.name, production: e.production ?? true)
            }
        }
        return TicketHandOffContext(screen: place, provider: providerId, providers: providers, environments: environments)
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

    /// F16: `agent` resumed a session of conversation `from` (its lineage root), and `resume` has
    /// already marked it handed with May push off. When `from` was handed, its hand-off is carried
    /// to `agent`'s id, so its git writes stay priced as handed with the stored May push; when it
    /// was not, the mark is lifted. A carry that fails leaves `agent` handed with May push off —
    /// fail closed — and says why.
    func carryHandOff(from: String, to agent: PlaceAgent, root: String) async {
        guard let ticket else { return }
        do {
            guard let (key, h) = try await ticket.carryHandoff(from: from, to: agent.id, as: handOffCaller(agent)) else {
                // Never handed: the provisional hand-off `resume` set is lifted.
                agent.handoff = nil
                return
            }
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

    /// F16: a resume could not read whose session it resumed (`why`, whole), so the conversation
    /// stays handed with May push off — it may be a handed one's — and says so.
    func noteHandOffUnknown(_ why: String, in agent: PlaceAgent) {
        noteHandOffFailure(
            "Wakil could not tell whether this session was handed to an agent (\(why)), so its push, sync, publish, merge and rebase ask you.",
            in: agent)
    }

    /// Says a hand-off's failure whole: on its chip and in its thread (Rule 8).
    func noteHandOffFailure(_ note: String, in agent: PlaceAgent) {
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
