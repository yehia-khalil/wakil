import Foundation

/// The naming quick task (names phase, spec "Calls made" 6-8): after a conversation's first clean
/// exchange the window's quick model is asked once for a name, which lands in `aiName`, goes to the
/// organisation's `conversation-names.json` under the lineage root, and is journalled. Not an action:
/// `aiName` has this one writer (Invariant 2), as the commit draft and the group names are not actions.
extension WindowModel {
    /// Asks for `agent`'s name when it is due: the switch is on, quick tasks are built, its first clean
    /// turn has ended with a first message, it was never asked (nor resumed), and it is in the window's
    /// organisation — another organisation's text never reaches these quick tasks (Invariant 4); it is
    /// asked when its own organisation's are built (`nameDueConversations`).
    func nameIfDue(_ agent: PlaceAgent) {
        guard conversationNamesEnabled, let tasks = quickTasks, agent.firstCleanTurnDone, !agent.namingAsked,
              let message = agent.firstMessage, !message.isEmpty,
              agent.place.organization == organization else { return }
        agent.namingAsked = true
        let generation = quickTasksGeneration, org = organization, id = agent.id
        let request = ConversationNames.request(firstMessage: message, replyStart: agent.replyStart)
        let chars = (min(message.count, ConversationNames.messageLimit),
                     min(agent.replyStart.count, ConversationNames.replyLimit))
        conversationNamingTasks[id] = Task { [weak self] in
            let provider = await tasks.routedId(.respond)
            let outcome: Result<String, Error>
            do {
                let reply = try await tasks.respond(request)
                do {
                    outcome = .success(try ConversationNames.parse(reply))
                } catch {
                    // The provider answered, so `run` kept no error: Settings shows this one whole.
                    await tasks.recordFailure("\(error)", for: .respond)
                    outcome = .failure(error)
                }
            } catch {
                outcome = .failure(error)
            }
            // Cancelled by an org switch, which cleared `namingAsked` and the entry itself.
            guard let self, !Task.isCancelled else { return }
            // Out of the table before anything lands: a switch from here on has nothing to undo.
            self.conversationNamingTasks[id] = nil
            guard generation == self.quickTasksGeneration, org == self.organization,
                  agent.place.organization == self.organization else {
                // Dropped. Asked again when its quick tasks are next built — or now, when they already
                // are: that rebuild's `nameDueConversations` ran while this was in flight. In another
                // organisation `nameIfDue` asks nothing; mid-rebuild it finds no quick tasks.
                agent.namingAsked = false
                self.nameIfDue(agent)
                return
            }
            let line = self.land(outcome, for: agent)
            let params: JSONValue = .object([
                "provider": provider.map(JSONValue.string) ?? .null,
                "messageChars": .integer(Int64(chars.0)), "replyChars": .integer(Int64(chars.1)),
            ])
            // Into the journal table with no suspension in between, so `settleConversationNaming` always
            // finds the one or the other (Ruling R9). The line's task leaves the table as it ends.
            let registry = self.registry, caller = agent.caller, key = UUID()
            self.conversationNamingJournals[key] = Task { [weak self] in
                try? await registry.journalQuickTask(
                    action: "conversation_named", params: params, caller: caller, outcome: line)
                self?.conversationNamingJournals[key] = nil
            }
        }
    }

    /// Asks every conversation that is due — one whose first turn ended while its organisation was
    /// not the window's, or whose reply a rebuild dropped. `rebuildQuickTasks` ends with this.
    func nameDueConversations() {
        for agent in conversations.values.sorted(by: { $0.ordinal < $1.ordinal }) { nameIfDue(agent) }
    }

    /// An organisation switch: every naming in flight is cancelled and its conversation left due, so it
    /// is asked when its organisation's quick tasks are built again.
    func cancelConversationNaming() {
        for (id, task) in conversationNamingTasks {
            conversations[id]?.namingAsked = false
            task.cancel()
        }
        conversationNamingTasks = [:]
    }

    /// TEST-ONLY: waits for every naming in flight, its journal line included.
    func settleConversationNaming() async {
        while let task = conversationNamingTasks.values.first ?? conversationNamingJournals.values.first {
            await task.value
        }
    }

    /// `conversation_rename`, drained from `ConversationBroker` (names, call 3): `name` — already
    /// cleaned, nil clears — becomes `id`'s operator name, or the screen's conversation's when `id` is
    /// nil; on a Landing, or for a conversation closed since the handler checked it, nothing. It goes
    /// to disk under the lineage root, or is held until `send` sets one. The screen never moves (Rule 6).
    public func renameConversation(_ id: String?, to name: String?) async {
        guard let agent = id.map({ conversations[$0] }) ?? currentAgent else { return }
        let name = name.flatMap(cleanConversationName)
        agent.operatorName = name
        if let root = agent.lineageRoot {
            saveNames(of: agent, root: root, operator: .some(name), ai: .none)
        } else {
            agent.namesUnsaved = true
        }
    }

    /// A name — the operator's or the model's — that landed before `agent` had a lineage root, written
    /// once it has one (`send`). Both slots are written; the root is new, so nothing on disk is lost.
    func saveUnsavedNames(of agent: PlaceAgent) {
        guard agent.namesUnsaved, let root = agent.lineageRoot else { return }
        if saveNames(of: agent, root: root, operator: .some(agent.operatorName), ai: .some(agent.aiName)) {
            agent.namesUnsaved = false
        }
    }

    /// A resume into a root `agent` did not have: names held in memory are written there first (the
    /// later value wins, Rule 7), then the root's stored names become the conversation's — a resume
    /// is the conversation it inherits. A held name whose write failed stays (its status said so); a
    /// file that cannot be read says so and changes nothing.
    func adoptStoredNames(of agent: PlaceAgent) {
        guard let root = agent.lineageRoot, let file = conversationNameFile(org: agent.place.organization) else { return }
        let held = agent.namesUnsaved && !saveNames(
            of: agent, root: root, operator: agent.operatorName.map { .some($0) } ?? .none,
            ai: agent.aiName.map { .some($0) } ?? .none)
        agent.namesUnsaved = false
        do {
            let stored = try file.read()[root]
            if held {
                agent.operatorName = agent.operatorName ?? stored?.operator
                agent.aiName = agent.aiName ?? stored?.ai
            } else {
                agent.operatorName = stored?.operator
                agent.aiName = stored?.ai
            }
        } catch {
            status = "\(error)"
        }
    }

    /// The organisation's names file, or nil without a home.
    func conversationNameFile(org: String) -> ConversationNameFile? {
        guard let browserHome, !org.isEmpty else { return nil }
        return ConversationNameFile(org: org, home: browserHome.appendingPathComponent(".wakil", isDirectory: true))
    }

    /// A reply that is still the window's: the name into `aiName` and to disk, or the failure kept (the
    /// conversation is not asked again). Answers the journal's outcome.
    private func land(_ outcome: Result<String, Error>, for agent: PlaceAgent) -> String {
        switch outcome {
        case .success(let name):
            agent.aiName = name
            if let root = agent.lineageRoot {
                saveNames(of: agent, root: root, operator: .none, ai: .some(name))
            } else {
                agent.namesUnsaved = true
            }
            return "ok: \(name)"
        case .failure(let error):
            return "\(error)"
        }
    }

    /// Written with the conversation's own organisation, never the window's (Invariant 4). A write
    /// refused over an unreadable file says so in that file's own sentence. True when it was written.
    @discardableResult
    private func saveNames(of agent: PlaceAgent, root: String, operator: String??, ai: String??) -> Bool {
        guard let file = conversationNameFile(org: agent.place.organization) else { return false }
        do {
            try file.set(root: root, operator: `operator`, ai: ai)
            return true
        } catch let error as ConversationNamesUnreadable {
            status = error.description
        } catch {
            status = "conversation names: could not save \(file.path): \(error) — the name holds until Wakil quits"
        }
        return false
    }
}
