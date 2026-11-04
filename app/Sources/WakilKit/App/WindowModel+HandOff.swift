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
    ///
    /// Workspaces piece 5: `workspace` puts it in a crew's workspace before its first message, so
    /// its first write makes a copy there; `crewRepo` is the repo it was started for; `admit` (one
    /// per repo) hears its id before its first message — false (a Cancel landed) ends it unsent.
    public func startHandOff(_ r: TicketHandOffRequest, reserved: ((String) -> Void)? = nil,
                             admit: (@Sendable (String) async -> Bool)? = nil,
                             workspace: String? = nil, crewRepo: String? = nil) async throws -> String {
        let agent = backgroundAgent(in: r.place, providerId: r.provider)
        agent.handoff = PlaceAgentHandoff(key: r.key, pr: r.pr, thread: r.thread, root: r.root, branch: r.branch, mayPush: r.mayPush)
        agent.crewRepo = crewRepo
        if let workspace { await workspaceRouter?.join(agent.id, workspace: workspace) }
        // The chip reads well: `INI-142 · <the operator's first line>`, not the whole brief
        // (conversations call 6; walk 2026-10-28) — the first message's slot. The model never names
        // a handed conversation: its ticket names it. The operator's own name still wins (names).
        // Item 8, Start another: `<title> #2`, its number never cut by the title's length.
        agent.messageTitle = conversationTitle(r.title) + (r.number.map { " #\($0)" } ?? "")
        agent.namingAsked = true
        // …in the workspace of the conversation carrying the ticket, holding no copy, marked to
        // branch off at its first write (never taking that one's copy over). In Main, it is as any.
        var branchOffIn: String?
        if workspace == nil, let from = r.branchOffFrom, let carrier = conversation(id: from),
           let id = await workspaceRouter?.store.workspaceId(ofConversation: from, root: carrier.lineageRoot) {
            branchOffIn = id
            await workspaceRouter?.join(agent.id, workspace: id, branchOff: true)
        }
        // Start on a ticket (the umbrella, decisions 8 and 17): in that ticket's workspace, made if
        // missing — a record only, each copy coming at its first write — not in Main. A hand-off
        // with no ticket key (a PR's) stays in Main, as any conversation there.
        var workspace = workspace
        if workspace == nil, branchOffIn == nil, let key = r.key, !key.isEmpty, let router = workspaceRouter {
            // Named by the brief's first line, the key kept apart: the card draws the key before it.
            var name = r.title
            if name.hasPrefix(key) {
                name = String(name.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("·") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
            }
            let w = await router.crewWorkspace(
                ticket: key, name: name.isEmpty ? key : name, organization: r.place.organization,
                project: r.place.project, environment: r.place.environment, branch: r.branch)
            workspace = w.id
            await router.join(agent.id, workspace: w.id)
        }
        reserved?(agent.id)
        if let admit, !(await admit(agent.id)) {
            if conversation(id: agent.id) === agent { await endConversation(agent) }
            throw TicketHandOffError(description: "the hand-off was cancelled before it started")
        }
        let scope = TurnScope(place: r.place, rootPath: r.root, providerId: r.provider, conversation: agent.id)
        guard await send(r.brief, scope: scope) else {
            let why = status.isEmpty ? "the agent did not start" : status
            if conversation(id: agent.id) === agent { await endConversation(agent) }
            throw TicketHandOffError(description: why)
        }
        guard conversation(id: agent.id) === agent else {
            throw TicketHandOffError(description: "the hand-off was cancelled before it started")
        }
        // Its lineage root, minted by the send, is recorded in the crew's workspace (and a Start
        // another's mark with it, so a resume keeps it).
        if let workspace { await workspaceRouter?.join(agent.id, workspace: workspace) }
        if let branchOffIn { await workspaceRouter?.join(agent.id, workspace: branchOffIn, branchOff: true) }
        guard let ticket else {
            noteHandOffFailure("The hand-off was not recorded (no ticket client), so this conversation's push and sync ask you.", in: agent)
            return agent.id
        }
        var handoff: [String: JSONValue] = [
            "conversation": .string(agent.id), "title": .string(r.numberedTitle), "harness": .string(r.harness),
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
        return TicketHandOffContext(screen: place, provider: providerId, providers: providers, environments: environments,
                                    carriers: handOffCarriers())
    }

    // MARK: Send to (item 8, 2026-10-30)

    /// The live handed conversations, for the popover's **Send to** and Start another's number.
    func handOffCarriers() -> [TicketHandOffCarrier] {
        liveConversations().compactMap { a in
            guard let h = a.handoff, !closing.contains(a.id) else { return nil }
            return TicketHandOffCarrier(conversation: a.id, title: a.title, key: h.key, pr: h.pr, root: h.root,
                                        lastActive: a.lastActivity, working: a.turnInFlight || a.startsSession)
        }
    }

    /// **Send to**: `text` as the operator's own message to the live conversation `id` (a user turn,
    /// not `conversation_message`). Idle, its turn starts now, off screen — the screen stays where it
    /// is (Rule 6). In a turn (or with messages already queued), it is queued and goes when that turn
    /// ends, shown pending in its thread and cancellable (Rule 4). A send that fails says why, whole.
    public func sendToHandOff(_ id: String, text: String) async throws -> TicketHandOffSent {
        guard let agent = conversations[id], !closing.contains(id) else {
            throw TicketHandOffError(description: "that conversation is no longer live; nothing was sent")
        }
        if agent.turnInFlight || agent.startsSession || agent.unansweredSends > 0 || !agent.queuedTurns.isEmpty {
            let q = QueuedTurn(id: UUID().uuidString.lowercased(), text: text)
            agent.queuedTurns.append(q)
            agent.lastActivity = Date()
            return .queued(id: q.id)
        }
        guard await send(text, scope: handOffScope(agent)) else {
            throw TicketHandOffError(description: status.isEmpty ? "the message was not sent" : status)
        }
        return .sent
    }

    /// Takes back a queued Send to (Rule 4); false when it already went or is gone.
    @discardableResult
    public func unqueueTurn(_ conversation: String, id: String) -> Bool {
        guard let agent = conversations[conversation], let i = agent.queuedTurns.firstIndex(where: { $0.id == id }) else {
            return false
        }
        agent.queuedTurns.remove(at: i)
        return true
    }

    /// Its turn ended: the oldest queued message goes, as the operator's own turn. One that cannot go
    /// is put back and said whole in its thread (Rule 8); the next turn's end tries again.
    func deliverQueuedTurn(_ agent: PlaceAgent) async {
        guard conversations[agent.id] === agent, !closing.contains(agent.id), !agent.turnInFlight,
              agent.unansweredSends == 0, !agent.startsSession, let next = agent.queuedTurns.first else { return }
        agent.queuedTurns.removeFirst()
        guard await send(next.text, scope: handOffScope(agent)) else {
            if conversations[agent.id] === agent { agent.queuedTurns.insert(next, at: 0) }
            agent.appendRow(label: "queued",
                            detail: "Wakil could not send your queued message (\(status.isEmpty ? "no agent session" : status)); "
                                + "it waits for this conversation's next turn to end.", isError: true)
            return
        }
    }

    /// The turn a Send to goes in: the conversation's own place, root and provider, pinned to it.
    private func handOffScope(_ agent: PlaceAgent) -> TurnScope {
        TurnScope(place: agent.place, rootPath: agent.handoff?.root.isEmpty == false ? agent.handoff!.root : rootPath,
                  providerId: agent.providerId, conversation: agent.id)
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
    /// was not, the mark is lifted — only when `from` is a root reached through a recorded parent:
    /// a session with no recorded parent may be a handed conversation's whose parent record
    /// failed, so nothing to carry from it is not "never handed". A carry that fails, or a window
    /// with no ticket client, leaves `agent` handed with May push off — fail closed — and says why.
    func carryHandOff(from: String, to agent: PlaceAgent, root: String, recordedParent: Bool) async {
        guard let ticket else {
            noteHandOffUnknown("no ticket client", in: agent)
            return
        }
        do {
            guard let (key, h) = try await ticket.carryHandoff(from: from, to: agent.id, as: handOffCaller(agent)) else {
                guard recordedParent else {
                    noteHandOffUnknown("the session has no recorded parent, and no hand-off names it", in: agent)
                    return
                }
                // Never handed: the provisional hand-off `resume` set is lifted.
                agent.handoff = nil
                return
            }
            let pr = parsedPRHandoffKey(key)
            agent.handoff = PlaceAgentHandoff(
                key: pr == nil ? key : nil, pr: pr?.number, thread: h["thread"].flatMap { if case .string(let t) = $0, !t.isEmpty { t } else { nil } },
                root: root, branch: "", mayPush: h["mayPush"] == .bool(true))
            // Named as its chip was (`INI-142 · …`), on Running as on Continue (walk 2026-10-29).
            if case .string(let title)? = h["title"], !title.isEmpty { agent.messageTitle = conversationTitle(title) }
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
