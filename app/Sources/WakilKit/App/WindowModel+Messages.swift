import Foundation

/// Workspaces piece 4: what the window keeps for messages — each workspace's wake budget, and each
/// organisation's Settings tree as last read, for Agents woken by messages. Survives an org switch,
/// as the conversations it serves do.
final class ConversationMessageState {
    var budgets = MessageWakeBudgets()
    /// The last Settings tree read per organisation (`publishAgentInstructions`); an organisation
    /// never read uses the default, 8.
    var trees: [String: SettingsTree] = [:]
}

/// Workspaces piece 4: messages between conversations — information only, never approval
/// (decision 2). `conversation_message` parks on `ConversationBroker`; the window shows it in both
/// threads and puts it in the recipient's next input. Nothing here touches the gate, the permission
/// plane or a parked proposal: a message is text the agent reads, never a decision the window makes.
extension WindowModel {
    // MARK: The seam piece 1 replaces

    /// **SEAM — workspaces piece 1 replaces this body.** Which workspace `agent` is in, for
    /// messages: the wake budget's key and the name a message's header gives. Until piece 1
    /// gives each conversation a workspace, the workspace is its place: the key is
    /// `org/project/environment` and the name `project · environment`. Piece 1 answers with
    /// `WorkspaceStore.workspace(ofConversation:)` — the workspace id as the key, its name as the
    /// name (a child workspace its own key: call 15). Nothing else in piece 4 reads the place for this.
    func messageWorkspace(of agent: PlaceAgent) -> MessageWorkspace {
        let place = agent.place
        return MessageWorkspace(
            key: [place.organization, place.project, place.environment].joined(separator: "/"),
            name: [place.project, place.environment].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    // MARK: Delivery

    /// Agents woken by messages for `agent`: its project's override, else its organisation's, else 8.
    func messageWakesAllowance(for agent: PlaceAgent) -> Int {
        let org = agent.place.organization
        let tree = messageState.trees[org] ?? (settings?.org.id == org ? settings : nil)
        return messageWakesSetting(in: tree, project: agent.place.project)
    }

    /// `conversation_message`, drained: both threads show it, and the recipient takes it at its
    /// next input — now, as a woken turn, when it is idle and its workspace's budget allows. Never
    /// moves the screen (Rule 6).
    func deliverMessage(from: String, to: String, text: String) async {
        guard let sender = conversations[from], !closing.contains(from) else { return }
        guard let recipient = conversations[to], !closing.contains(to) else {
            // Closed between the check and the drain: said whole in the sender's thread (Rule 8).
            sender.appendRow(
                label: "message",
                detail: "Not delivered: the conversation it was for is no longer live.", isError: true)
            return
        }
        let workspace = messageWorkspace(of: sender)
        sender.appendMessageRow(.to, header: "To ‘\(recipient.title)’", text: text)
        recipient.appendMessageRow(.from, header: "From ‘\(sender.title)’ · \(workspace.name)", text: text)
        recipient.pendingMessages.append(ConversationMessage(
            from: sender.id, fromTitle: sender.title, fromWorkspace: workspace.name, text: text))
        await wakeForMessages(recipient)
    }

    /// Wakes `agent` with every message it holds, as one turn, when it can take a turn now and its
    /// workspace's budget has a wake left (decision 16). Otherwise they wait: for its turn's end
    /// (working), or for the operator ("waiting for you · N messages").
    func wakeForMessages(_ agent: PlaceAgent) async {
        guard !agent.pendingMessages.isEmpty, canBeWokenByMessages(agent) else { return }
        let key = messageWorkspace(of: agent).key
        guard messageState.budgets.takeWake(in: key, allowance: messageWakesAllowance(for: agent)),
              let harness = agent.harness else { return }
        let messages = agent.pendingMessages
        agent.pendingMessages = []
        var outgoing = conversationMessageBlock(messages)
        if let update = instructionsUpdate(for: agent) {
            outgoing = update + "\n\n" + outgoing
            agent.appendRow(label: "instructions", detail: "Instructions updated — the agent has the new ones from this turn.")
        }
        // As `send` does, before the suspension: a `.result` landing during it clears what is set.
        agent.turnInFlight = true
        agent.noteSent(spoken: false)
        agent.lastActivity = Date()
        do {
            try await harness.send(outgoing)
        } catch {
            agent.turnInFlight = false
            agent.noteResult()
            agent.pendingMessages = messages + agent.pendingMessages
            agent.appendRow(
                label: "message",
                detail: "Wakil could not wake the agent with the messages (\(error)); they wait for your next message.",
                isError: true)
        }
    }

    /// Whether `agent` can take a message-woken turn now: live, its session running and between
    /// turns, nothing of its own on the plane, no restart due. Anything else keeps the messages for
    /// its next input.
    func canBeWokenByMessages(_ agent: PlaceAgent) -> Bool {
        conversations[agent.id] === agent && !closing.contains(agent.id)
            && agent.harness != nil && agent.sessionId != nil && !agent.sessionEnded
            && !agent.turnInFlight && agent.unansweredSends == 0 && !agent.startsSession
            && !waitingConversations.contains(agent.id) && !connectionsRestartDue(agent)
    }

    /// The operator's message to `agent` (`send`): its workspace's budget is set back to the
    /// setting's value (call 15: reset, not add), and the messages it holds ride at the head of the
    /// input. `count` is how many, for `messagesDelivered` once the send succeeded.
    func messagesRidingWithOperatorTurn(to agent: PlaceAgent) -> (block: String, count: Int) {
        let key = messageWorkspace(of: agent).key
        messageState.budgets.operatorMessage(in: key, allowance: messageWakesAllowance(for: agent))
        return (conversationMessageBlock(agent.pendingMessages), agent.pendingMessages.count)
    }

    /// The operator's turn went with `count` messages: they leave the queue. Then the workspace's
    /// other conversations holding messages are woken, within the budget just reset.
    func messagesDelivered(_ count: Int, withOperatorTurnTo agent: PlaceAgent) {
        if count > 0 { agent.pendingMessages.removeFirst(min(count, agent.pendingMessages.count)) }
        let key = messageWorkspace(of: agent).key
        let held = liveConversations().filter {
            $0 !== agent && !$0.pendingMessages.isEmpty && messageWorkspace(of: $0).key == key
        }
        guard !held.isEmpty else { return }
        Task { [weak self] in
            for other in held { await self?.wakeForMessages(other) }
        }
    }

    /// TEST-ONLY: what is left of `agent`'s workspace's budget.
    func messageWakesRemainingForTesting(_ agent: PlaceAgent) -> Int {
        messageState.budgets.remaining(
            in: messageWorkspace(of: agent).key, allowance: messageWakesAllowance(for: agent))
    }
}

// MARK: - The setting (decision 16)

extension WindowModel {
    /// Saves Agents woken by messages: the organisation's when `projectPath` is nil, else that
    /// project's override (`-1` clears it back to the organisation's). Answers the refusal whole,
    /// or nil; the re-read shows disk either way.
    public func saveMessageWakes(_ value: Int, organisation: String, projectPath: String?) async -> String? {
        let (action, params): (String, [String: JSONValue]) = projectPath.map {
            ("ctx_set_project_agent_instructions", ["projectPath": .string($0), "messageWakes": .integer(Int64(value))])
        } ?? ("ctx_update_org", ["id": .string(organisation), "messageWakes": .integer(Int64(value))])
        do {
            _ = try await registry.dispatch(
                name: action, params: .object(params), origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
            await refreshSettings()
            return nil
        } catch {
            await refreshSettings()
            return statusDescribingFailure(action, error)
        }
    }
}
