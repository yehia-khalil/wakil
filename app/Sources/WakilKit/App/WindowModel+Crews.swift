import Foundation

/// Workspaces piece 5: crews and the hand-off (decision 17). An agent proposes a teammate
/// (`conversation_propose_teammate`); the operator starts it or dismisses it; a crew can also start
/// up front, one handed agent per repo, from the Hand to agent popover. A crew shares one workspace
/// and talks only through messages (decision 2), within the wake budget (decision 16). Nothing here
/// asks: proposing is Wakil's own state, and Start and Dismiss are the operator's click (Rule 1).
/// Start never moves the screen (Rule 6).
extension WindowModel {
    // MARK: The window's side of the actions

    /// Points the crew actions at this window (`WakilWiring.useActiveContext(of:)`).
    public func useCrew(_ lookup: CrewLookup) {
        lookup.use(CrewLookup.Window(
            propose: { [weak self] from, repo, brief in
                guard let self else { throw TeammateProposalRefusal(description: "no window") }
                return try await self.proposeTeammate(from: from, repo: repo, brief: brief)
            },
            start: { [weak self] id, brief in
                guard let self else { throw TeammateProposalRefusal(description: "no window") }
                return try await self.startTeammate(id, brief: brief)
            },
            dismiss: { [weak self] id in
                guard let self else { throw TeammateProposalRefusal(description: "no window") }
                return try await self.dismissTeammate(id)
            },
            edit: { [weak self] id, brief in
                guard let self else { throw TeammateProposalRefusal(description: "no window") }
                return try await self.editTeammateBrief(id, brief: brief)
            },
            nothingToDo: { [weak self] conversation, why in
                guard let self else { throw TeammateProposalRefusal(description: "no window") }
                return try await self.markNothingToDo(conversation, why: why)
            }))
    }

    // MARK: A teammate, proposed

    /// `from` proposes a teammate for `repo` in its workspace: checked whole
    /// (`checkTeammateProposal`), then held — replacing a pending one for the same repo — and said
    /// in the proposer's thread.
    func proposeTeammate(from: String?, repo: String, brief: String) async throws -> (TeammateProposal, Bool) {
        let rows = liveConversationRows()
        let agent = from.flatMap { conversations[$0] }
        let sender = agent.flatMap { a in rows.first { $0.id == a.id } }
        var roots: [String] = []
        var key = ""
        var (own, held): ([String], [String: String]) = ([], [:])
        if let agent {
            roots = await workspaceFacts(agent.id)?.mainRoots ?? []
            key = await messageWorkspace(of: agent).key
            (own, held) = await crewHolds(around: agent)
        }
        let root = try checkTeammateProposal(
            repo: repo, brief: brief, sender: sender, roots: roots, workspace: key, ownRepos: own, heldBy: held,
            proposals: teammateProposals)
        guard let agent else { throw TeammateProposalRefusal(description: "conversation_propose_teammate: no proposer") }
        let made = teammateProposals.propose(
            from: agent.id, fromTitle: agent.title, workspace: key, repo: root, brief: brief)
        agent.appendRow(
            label: "teammate",
            detail: "Suggested a teammate for \(made.proposal.repoName)\(made.replaced ? " (replacing the last suggestion)" : "")"
                + " — the operator starts it or dismisses it:\n" + brief)
        return made
    }

    /// The repos `agent` holds in its workspace, and the ones other live conversations of that
    /// workspace hold, with their titles. Main holds nothing.
    func crewHolds(around agent: PlaceAgent) async -> ([String], [String: String]) {
        guard let store = workspaceRouter?.store,
              let id = await store.workspaceId(ofConversation: agent.id, root: agent.lineageRoot) else { return ([], [:]) }
        var own: [String] = []
        var held: [String: String] = [:]
        for (hold, holder) in await store.holders() where hold.workspace == id {
            if holder == agent.id { own.append(hold.repo) }
            else if let other = conversations[holder] { held[hold.repo] = other.title }
        }
        return (own.sorted(), held)
    }

    /// Dismiss: the proposal goes, and its repo is not proposed again in its workspace.
    func dismissTeammate(_ id: String) async throws -> TeammateProposal {
        guard let p = teammateProposals.dismiss(id) else {
            throw TeammateProposalRefusal(description: "conversation_teammate_dismiss: no teammate proposal \(id) — it was "
                + "started, dismissed, or its conversation closed")
        }
        conversations[p.from]?.appendRow(
            label: "teammate", detail: "The operator dismissed the teammate for \(p.repoName); it is not proposed again here.")
        return p
    }

    /// The operator's edit of a proposal's brief, kept (Rule 2).
    func editTeammateBrief(_ id: String, brief: String) async throws -> TeammateProposal {
        guard teammateProposals.edit(id, brief: brief), let p = teammateProposals.proposal(id) else {
            throw TeammateProposalRefusal(description: "conversation_teammate_brief: no teammate proposal \(id)")
        }
        return p
    }

    /// Start: a new conversation in the proposer's place, on its provider, in its workspace — made
    /// now, a record only, when the proposer is in Main, and the proposer moved into it — for the
    /// proposal's repo, its first message the brief (the operator's edit, else the agent's) and who
    /// holds what. A handed proposer's teammate is handed on the same ticket with May push off. A
    /// start that fails puts the proposal back and says why, whole.
    func startTeammate(_ id: String, brief edited: String?) async throws -> String {
        let action = "conversation_teammate_start"
        guard let p = teammateProposals.proposal(id) else {
            throw TeammateProposalRefusal(description: "\(action): no teammate proposal \(id) — it was started, "
                + "dismissed, or its conversation closed")
        }
        let brief = edited.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? p.brief
        guard let proposer = conversations[p.from], !closing.contains(p.from) else {
            teammateProposals.drop(from: p.from)
            throw TeammateProposalRefusal(description: "\(action): ‘\(p.fromTitle)’ is no longer live, so there is no "
                + "workspace to start its teammate in")
        }
        _ = teammateProposals.take(id)
        do {
            let workspace = await crewWorkspace(joining: proposer)
            let teammates = await crewMembers(in: workspace, besides: nil)
            let title = "\(p.repoName) · \(proposer.handoff?.key ?? proposer.title)"
            let text = brief + "\n\n" + crewBriefLines(repo: p.repo, teammates: teammates)
            let started: String
            if let h = proposer.handoff {
                started = try await startHandOff(
                    TicketHandOffRequest(key: h.key, pr: h.pr, thread: nil, brief: text,
                                         harness: ticketHandOffHarnesses[0].id, provider: proposer.providerId,
                                         place: proposer.place, root: p.repo, branch: "", mayPush: false, title: title),
                    workspace: workspace, crewRepo: p.repo)
            } else {
                started = try await startCrewConversation(
                    place: proposer.place, provider: proposer.providerId, title: title, brief: text, root: p.repo,
                    workspace: workspace)
            }
            proposer.appendRow(label: "teammate", detail: "Started ‘\(title)’ for \(p.repoName), in this workspace.")
            return started
        } catch {
            _ = teammateProposals.propose(from: p.from, fromTitle: p.fromTitle, workspace: p.workspace, repo: p.repo,
                                          brief: brief)
            throw TeammateProposalRefusal(description: "\(action): the teammate for \(p.repoName) did not start: \(error)")
        }
    }

    /// The workspace `agent` works in, as an id: its own, else a record-only one made for its crew
    /// (named after its ticket, else its title) with `agent` moved in. Nil without a record.
    func crewWorkspace(joining agent: PlaceAgent) async -> String? {
        guard let router = workspaceRouter else { return nil }
        if let id = await router.store.workspaceId(ofConversation: agent.id, root: agent.lineageRoot) { return id }
        let w = await router.crewWorkspace(
            ticket: agent.handoff?.key, name: agent.title, organization: agent.place.organization,
            project: agent.place.project, environment: agent.place.environment)
        await router.join(agent.id, workspace: w.id)
        return w.id
    }

    /// Who holds what in `workspace`: each live conversation in it (but `besides`), with the repo it
    /// holds there, else the repo it was started for, else none yet.
    func crewMembers(in workspace: String?, besides: String?) async -> [CrewMember] {
        guard let workspace, let store = workspaceRouter?.store else { return [] }
        let holds = await store.holders()
        var out: [CrewMember] = []
        for id in await store.members(of: workspace) where id != besides {
            guard let agent = conversations[id] else { continue }
            let held = holds.first { $0.key.workspace == workspace && $0.value == id }?.key.repo
            out.append(CrewMember(title: agent.title, repo: held ?? agent.crewRepo ?? ""))
        }
        return out
    }

    /// A conversation started for a crew with no hand-off: off screen, as a hand-off is
    /// (`backgroundAgent`), named `title`, in `workspace` before its first message.
    func startCrewConversation(place: Place, provider: String, title: String, brief: String, root: String,
                               workspace: String?) async throws -> String {
        let agent = backgroundAgent(in: place, providerId: provider)
        agent.messageTitle = conversationTitle(title)
        agent.namingAsked = true
        agent.crewRepo = root
        if let workspace { await workspaceRouter?.join(agent.id, workspace: workspace) }
        guard await send(brief, scope: TurnScope(place: place, rootPath: root, providerId: provider, conversation: agent.id)) else {
            let why = status.isEmpty ? "the agent did not start" : status
            if conversation(id: agent.id) === agent { await endConversation(agent) }
            throw TeammateProposalRefusal(description: why)
        }
        if let workspace { await workspaceRouter?.join(agent.id, workspace: workspace) }
        return agent.id
    }

    // MARK: A crew up front

    /// One per repo (the Hand to agent popover): one handed conversation per request, all in the
    /// ticket's workspace (found by its key, else a record only), each told who holds what. A start
    /// that fails stops the rest; the ones started stay, and the error names them.
    public func startCrew(_ requests: [TicketHandOffRequest]) async throws -> [String] {
        guard let first = requests.first else { throw TicketHandOffError(description: "no repo is ticked") }
        let titles = requests.map { r in "\(r.key ?? r.title) · \((r.root as NSString).lastPathComponent)" }
        var workspace: String?
        if let router = workspaceRouter {
            workspace = await router.crewWorkspace(
                ticket: first.key, name: first.key.map { "\($0) \(first.title)" } ?? first.title,
                organization: first.place.organization, project: first.place.project,
                environment: first.place.environment).id
        }
        var started: [String] = []
        for (i, r) in requests.enumerated() {
            let teammates = requests.indices.filter { $0 != i }.map { CrewMember(title: titles[$0], repo: requests[$0].root) }
            let request = TicketHandOffRequest(
                key: r.key, pr: r.pr, thread: r.thread,
                brief: r.brief + "\n\n" + crewBriefLines(repo: r.root, teammates: teammates),
                harness: r.harness, provider: r.provider, place: r.place, root: r.root, branch: r.branch,
                mayPush: r.mayPush, repo: r.repo, title: titles[i])
            do {
                started.append(try await startHandOff(request, workspace: workspace, crewRepo: r.root))
            } catch {
                let done = started.isEmpty ? "" : " (\(started.count) of \(requests.count) started and still running)"
                throw TicketHandOffError(description: "the agent for \((r.root as NSString).lastPathComponent) did not start\(done): \(error)")
            }
        }
        return started
    }

    // MARK: Nothing to do

    /// `conversation` says its repo needs nothing: its state reads "done · nothing to do in web"
    /// until the operator's next message, and its thread says so.
    func markNothingToDo(_ conversation: String?, why: String?) async throws -> String {
        guard let conversation, let agent = conversations[conversation] else {
            throw TeammateProposalRefusal(description: "conversation_nothing_to_do: it is said by a live conversation, "
                + "and this call names none")
        }
        var repo = agent.crewRepo.map { ($0 as NSString).lastPathComponent }
        if repo == nil {
            let (own, _) = await crewHolds(around: agent)
            repo = own.first.map { ($0 as NSString).lastPathComponent }
        }
        let words = nothingToDoWords(repo: repo, why: why)
        agent.nothingToDo = words
        let reason = why.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let tail = repo != nil ? reason.map { " — \($0)" } ?? "" : ""
        agent.appendRow(label: "done", detail: words + tail + ". Close it when you have read this.")
        return words
    }

    /// The proposals of the workspace the conversation on screen is in (the strip over the thread).
    public var teammateProposalsOnScreen: [TeammateProposal] {
        guard let agent = currentAgent else { return [] }
        let key = MessageWorkspace(of: agent.workspace.map { ($0.id, $0.name) }, place: agent.place).key
        return teammateProposals.pending(in: key)
    }
}
