import Foundation
import Testing
@testable import WakilKit

// Workspaces piece 5, the window's side: a teammate proposed, started and dismissed (decision 17);
// a crew up front (one per repo); nothing to do. Start never moves the screen (Rule 6); nothing asks.

private let org = "initech"
private let placeA = Place(organization: org, project: "api", environment: "staging")
private let roots = ["/src/api", "/src/web"]

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2 * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

private func sends(_ harness: ScriptedHarness) -> [String] {
    harness.log.filter { $0.hasPrefix("send:") }.map { String($0.dropFirst(5)) }
}

@MainActor
private struct Wired {
    let model: WindowModel
    let registry: ActionRegistry
    let sessions: Sessions
    let store: WorkspaceStore

    init() async throws {
        let sessions = Sessions()
        let dir = testScratchRoot.appendingPathComponent("crews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registry = ActionRegistry(journalDirectory: dir, sessionId: "crews")
        let panes = PaneStore()
        let layout = LayoutStore()
        let conversations = ConversationBroker()
        let lookup = LiveConversationLookup()
        await registerStandardActions(
            into: registry, context: nil, panes: panes, db: nil, resumes: ResumeBroker(), layout: layout,
            conversationRequests: conversations, liveConversations: { await lookup.live(in: $0) },
            liveOrganization: { await lookup.organization() })
        await registerLayoutActions(into: registry, layout: layout, panes: panes)
        let crew = CrewLookup()
        await registerCrewActions(into: registry, crew: crew)
        let model = WindowModel(
            registry: registry, panes: panes, layout: layout, persistence: nil, context: nil,
            harnessFactory: { place, _, socketPath in sessions.harness(place, socketPath) },
            resumes: ResumeBroker(), rootPath: "/tmp", providerId: "test-provider",
            lookupFactory: { _ in AlwaysSucceedsCredentialsLookupForTesting() },
            conversationRequests: conversations,
            agentSocketFactory: sessions.socketFactory, environment: "staging")
        model.setOrganizationForTesting(org)
        model.agentConnectionsBox = AgentConnectionsBox()
        lookup.use({ [weak model] place in await model?.liveConversationRows(in: place) ?? [] },
                   organization: { [weak model] in await model?.organization })
        model.seedForTesting(
            providerId: "test-provider", rootPath: roots[0], thoughts: 0,
            project: placeA.project, environment: placeA.environment)
        model.setRootPathsForTesting(roots)
        model.useCrew(crew)
        let store = WorkspaceStore()
        await store.ensure(org: org)
        model.useWorkspaces(WorkspaceRouter(store: store))
        self.model = model
        self.registry = registry
        self.sessions = sessions
        self.store = store
    }

    /// One idle conversation on screen, "backend work".
    func backend() async throws -> (PlaceAgent, ScriptedHarness) {
        #expect(await model.send("backend work"))
        let a = try #require(model.currentAgent)
        let h = try #require(sessions.harnesses.in(placeA).first)
        h.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { !a.turnInFlight })
        return (a, h)
    }

    func agent(_ action: String, _ params: [String: JSONValue], as a: PlaceAgent) async throws -> JSONValue {
        try await registry.dispatch(name: action, params: .object(params), origin: .agent, caller: a.caller, confirmation: nil)
    }

    func operator_(_ action: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await registry.dispatch(name: action, params: .object(params), origin: .ui,
                                    caller: DispatchCaller(place: placeA, session: nil), confirmation: nil)
    }

    func propose(_ a: PlaceAgent, repo: String = "web", brief: String = "Build the login form against POST /login.")
        async throws -> String {
        let r = try await agent("conversation_propose_teammate", ["repo": .string(repo), "brief": .string(brief)], as: a)
        guard case .object(let o) = r, case .string(let id)? = o["proposal"] else { throw CancellationError() }
        return id
    }
}

@MainActor
private func refused(_ body: @MainActor () async throws -> JSONValue) async -> String? {
    do {
        _ = try await body()
        return nil
    } catch {
        return "\(error)"
    }
}

@MainActor
struct CrewWindowTests {
    @Test func aProposalIsHeldSaidInTheThreadAndListedBySessionList() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        #expect(w.model.teammateProposals.pending(from: a.id).map(\.repo) == ["/src/web"])
        #expect(a.thoughts.last?.label == "teammate")
        #expect(a.thoughts.last?.detail.contains("Suggested a teammate for web") == true)
        #expect(w.model.teammateProposalsOnScreen.map(\.id) == [id], "the strip over the thread shows it")
        let row = try #require(w.model.liveConversationRows().first { $0.id == a.id })
        #expect(row.proposals.map(\.id) == [id])
        // A second proposal for web replaces the first, keeping its id (Rule 7).
        let again = try await w.agent("conversation_propose_teammate",
                                      ["repo": .string("/src/web"), "brief": .string("Only the form.")], as: a)
        guard case .object(let o) = again else { Issue.record("no answer"); return }
        #expect(o["replaced"] == .bool(true))
        #expect(o["proposal"] == .string(id))
        #expect(w.model.teammateProposals.all.map(\.brief) == ["Only the form."])
        // Refused, whole: a repo not the project's, an empty brief.
        let billing = await refused { try await w.agent("conversation_propose_teammate",
                                                        ["repo": .string("billing"), "brief": .string("x")], as: a) }
        #expect(billing?.contains("billing is not a repo of this project — its repos are api, web") == true)
        let empty = await refused { try await w.agent("conversation_propose_teammate",
                                                      ["repo": .string("web"), "brief": .string(" ")], as: a) }
        #expect(empty?.contains("the brief is empty") == true)
        await w.model.shutdown()
    }

    /// The home draws a proposal (spec, piece 3's card): one made in Main, in Main's block.
    @Test func theHomeDrawsAProposalMadeInMainInMainsBlock() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        let screen = await w.model.readHomeScreen(projects: [a.place.project], past: [], filter: nil)
        let main = screen.sections.first { $0.project == a.place.project }?.main
        #expect(main?.proposals.map(\.id) == [id])
        #expect(screen.teammateOffers == [id])
        await w.model.shutdown()
    }

    @Test func onlyTheOperatorStartsOrDismisses() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        for action in ["conversation_teammate_start", "conversation_teammate_dismiss"] {
            let r = await refused { try await w.agent(action, ["proposal": .string(id)], as: a) }
            #expect(r != nil)
        }
        #expect(w.model.teammateProposals.proposal(id) != nil, "the agent's attempt changed nothing")
        await w.model.shutdown()
    }

    @Test func startMakesTheCrewsWorkspaceStartsTheTeammateOffScreenAndSaysWhoHoldsWhat() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        let screen = w.model.currentAgent
        let r = try await w.operator_("conversation_teammate_start",
                                      ["proposal": .string(id), "brief": .string("Build the form; ask backend for the shape.")])
        guard case .object(let o) = r, case .string(let started)? = o["conversation"] else { Issue.record("no id"); return }
        #expect(w.model.currentAgent === screen, "Start does not move the screen (Rule 6)")
        let t = try #require(w.model.conversation(id: started))
        #expect(t.title == "web · backend work")
        #expect(t.crewRepo == "/src/web")
        let ht = try #require(w.sessions.harnesses.in(placeA).last)
        #expect(await waitUntil { !sends(ht).isEmpty })
        let first = try #require(sends(ht).first)
        #expect(first.contains("Build the form; ask backend for the shape."), "the operator's edit is the brief")
        #expect(first.contains("You work in web (/src/web)"))
        #expect(first.contains("- ‘backend work’"), "the proposer is named as its teammate")
        // One workspace for both: the proposer, in Main, moved into a record-only one.
        let ws = try #require(await w.store.workspaceId(ofConversation: a.id))
        #expect(await w.store.workspaceId(ofConversation: started) == ws)
        #expect(await w.store.workspace(ws)?.checkouts.isEmpty == true)
        #expect(w.model.teammateProposals.all.isEmpty)
        #expect(a.thoughts.last?.detail == "Started ‘web · backend work’ for web, in this workspace.")
        // session_list: the two share the workspace.
        let rows = w.model.liveConversationRows()
        #expect(rows.count == 2)
        await w.model.shutdown()
    }

    /// The home's card draws the teammate Start made beside its proposer (spec piece 3's card).
    @Test func theHomesCardDrawsTheStartedTeammateBesideItsProposer() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        let r = try await w.operator_("conversation_teammate_start", ["proposal": .string(id)])
        guard case .object(let o) = r, case .string(let started)? = o["conversation"] else { Issue.record("no id"); return }
        let ws = try #require(await w.store.workspaceId(ofConversation: a.id))
        let ht = try #require(w.sessions.harnesses.in(placeA).last)
        #expect(await waitUntil { !sends(ht).isEmpty })
        ht.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { w.model.conversation(id: started)?.turnInFlight == false })
        let screen = await w.model.readHomeScreen(projects: [a.place.project], past: [], filter: nil)
        let card = screen.sections.flatMap(\.cards).first { $0.id == ws }
        #expect(Set(card?.lines.map(\.id) ?? []) == [a.id, started])
        #expect(screen.sections.compactMap(\.main).flatMap(\.lines).isEmpty)
        await w.model.shutdown()
    }

    @Test func aDismissedProposalIsNotRepeatedInThatWorkspace() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        _ = try await w.operator_("conversation_teammate_dismiss", ["proposal": .string(id)])
        #expect(w.model.teammateProposals.all.isEmpty)
        #expect(a.thoughts.last?.detail.contains("dismissed the teammate for web") == true)
        let again = await refused { try await w.agent("conversation_propose_teammate",
                                                      ["repo": .string("web"), "brief": .string("please")], as: a) }
        #expect(again?.contains("decision 17") == true)
        let gone = await refused { try await w.operator_("conversation_teammate_start", ["proposal": .string(id)]) }
        #expect(gone?.contains("no teammate proposal") == true)
        await w.model.shutdown()
    }

    @Test func theOperatorsEditOfABriefIsKept() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.propose(a)
        _ = try await w.operator_("conversation_teammate_brief", ["proposal": .string(id), "brief": .string("Mine now.")])
        #expect(w.model.teammateProposals.proposal(id)?.brief == "Mine now.")
        await w.model.shutdown()
    }

    @Test func aProposersCloseTakesItsProposalsWithIt() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        _ = try await w.propose(a)
        await w.model.endConversation(a)
        #expect(w.model.teammateProposals.all.isEmpty)
        await w.model.shutdown()
    }

    @Test func nothingToDoReadsDoneUntilTheOperatorsNextMessage() async throws {
        let w = try await Wired()
        let (a, h) = try await w.backend()
        let r = try await w.agent("conversation_nothing_to_do", ["why": .string("the API already answers it")], as: a)
        #expect(r == .object(["state": .string("done · nothing to do: the API already answers it")]))
        let row = try #require(w.model.liveConversationRows().first { $0.id == a.id })
        #expect(row.stateWords == "done · nothing to do: the API already answers it")
        #expect(a.thoughts.last?.label == "done")
        #expect(await w.model.send("one more thing"))
        #expect(a.nothingToDo == nil)
        h.emit(.result(isError: false, text: nil))
        await w.model.shutdown()
    }

    @Test func aCrewUpFrontIsOneHandedAgentPerRepoInTheTicketsWorkspace() async throws {
        let w = try await Wired()
        let base = TicketHandOffRequest(
            key: "INI-142", pr: nil, thread: nil, brief: "Add the login rate limit.", harness: "claude-code",
            provider: "test-provider", place: placeA, root: "/src/api", branch: "INI-142-login", mayPush: false,
            title: "INI-142 · Add the login rate limit.")
        let web = TicketHandOffRequest(
            key: "INI-142", pr: nil, thread: nil, brief: "Add the login rate limit.", harness: "claude-code",
            provider: "test-provider", place: placeA, root: "/src/web", branch: "", mayPush: false,
            title: "INI-142 · Add the login rate limit.")
        let screen = w.model.currentAgent
        let ids = try await w.model.startCrew([base, web])
        #expect(ids.count == 2)
        #expect(w.model.currentAgent === screen, "the crew starts off screen (Rule 6)")
        let api = try #require(w.model.conversation(id: ids[0]))
        let fe = try #require(w.model.conversation(id: ids[1]))
        #expect(api.title == "INI-142 · api" && fe.title == "INI-142 · web")
        #expect(api.handoff?.key == "INI-142" && fe.handoff?.root == "/src/web")
        let ws = try #require(await w.store.workspaceId(ofConversation: ids[0]))
        #expect(await w.store.workspaceId(ofConversation: ids[1]) == ws)
        #expect(await w.store.workspace(ws)?.tickets == ["INI-142"])
        let harnesses = w.sessions.harnesses.in(placeA)
        #expect(await waitUntil { harnesses.allSatisfy { !sends($0).isEmpty } })
        let briefs = harnesses.compactMap { sends($0).first }
        #expect(briefs.contains { $0.contains("You work in api (/src/api)") && $0.contains("- ‘INI-142 · web’ works in web (/src/web).") })
        #expect(briefs.contains { $0.contains("You work in web (/src/web)") && $0.contains("- ‘INI-142 · api’ works in api (/src/api).") })
        await w.model.shutdown()
    }
    /// Rule 4, the window's side: a member the start no longer admits (Cancel landed) is ended
    /// before its first message and stops the crew; none after it starts.
    @Test func aCrewMemberNotAdmittedNeverStartsAndStopsTheRest() async throws {
        let w = try await Wired()
        func member(_ root: String) -> TicketHandOffRequest {
            TicketHandOffRequest(
                key: "INI-142", pr: nil, thread: nil, brief: "Add the login rate limit.", harness: "claude-code",
                provider: "test-provider", place: placeA, root: root, branch: "", mayPush: false,
                title: "INI-142 · Add the login rate limit.")
        }
        w.model.setRootPathsForTesting(roots + ["/src/core"])
        let admitted = AdmitLog(allow: 1)
        await #expect {
            _ = try await w.model.startCrew([member("/src/api"), member("/src/web"), member("/src/core")],
                                            admit: { await admitted.admit($0) })
        } throws: { "\($0)".contains("cancelled") }
        let asked = await admitted.asked
        #expect(asked.count == 2, "the third member is never reserved")
        #expect(w.model.conversation(id: asked[1]) == nil, "the refused member is ended")
        #expect(w.model.conversation(id: asked[0]) != nil, "the caller ends the ones it admitted")
        let harnesses = w.sessions.harnesses.in(placeA)
        #expect(await waitUntil { harnesses.contains { !sends($0).isEmpty } })
        #expect(harnesses.filter { !sends($0).isEmpty }.count == 1, "only the admitted member was sent its brief")
        await w.model.shutdown()
    }
}

// MARK: - Send to and Start another (item 8, 2026-10-30)

@MainActor
private func handed(_ title: String = "INI-142 · Work toward Next.") -> TicketHandOffRequest {
    TicketHandOffRequest(key: "INI-142", pr: nil, thread: nil, brief: "Work toward Next.", harness: "claude-code",
                         provider: "test-provider", place: placeA, root: "/src/api", branch: "ini-142-login", mayPush: false,
                         title: title)
}

@MainActor
struct HandOffSendToWindowTests {
    /// The popover's carriers are the window's live handed conversations, with what they carry.
    @Test func theContextListsLiveHandedConversations() async throws {
        let w = try await Wired()
        let id = try await w.model.startHandOff(handed())
        let ctx = await w.model.handOffContext()
        let c = try #require(ctx.carriers.first { $0.conversation == id })
        #expect(c.key == "INI-142" && c.root == "/src/api" && c.title == "INI-142 · Work toward Next.")
        #expect(c.working, "its first turn runs")
        await w.model.shutdown()
    }

    /// Idle: Send to starts a turn now, the brief as the operator's own message, off screen (Rule 6).
    @Test func sendToAnIdleConversationStartsItsTurnOffScreen() async throws {
        let w = try await Wired()
        let (a, _) = try await w.backend()
        let id = try await w.model.startHandOff(handed())
        let h = try #require(w.sessions.harnesses.in(placeA).last)
        h.emit(.result(isError: false, text: nil))
        let t = try #require(w.model.conversation(id: id))
        #expect(await waitUntil { !t.turnInFlight })
        #expect(try await w.model.sendToHandOff(id, text: "Also answer the second thread.") == .sent)
        #expect(await waitUntil { sends(h).last == "Also answer the second thread." })
        #expect(t.thoughts.contains { $0.label == "you" && $0.detail == "Also answer the second thread." })
        #expect(w.model.currentAgent === a, "the screen stays where it was (Rule 6)")
        await w.model.shutdown()
    }

    /// Mid-turn: queued, shown pending in its thread, delivered when the turn ends.
    @Test func sendToAWorkingConversationQueuesUntilItsTurnEnds() async throws {
        let w = try await Wired()
        let id = try await w.model.startHandOff(handed())
        let h = try #require(w.sessions.harnesses.in(placeA).last)
        let t = try #require(w.model.conversation(id: id))
        #expect(t.turnInFlight)
        let before = sends(h).count
        let out = try await w.model.sendToHandOff(id, text: "Also answer the second thread.")
        guard case .queued(let q) = out else { Issue.record("not queued: \(out)"); return }
        #expect(t.queuedTurns.map(\.id) == [q])
        #expect(t.queuedTurns.first?.text == "Also answer the second thread.")
        #expect(sends(h).count == before, "nothing goes mid-turn")
        h.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { sends(h).last == "Also answer the second thread." })
        #expect(t.queuedTurns.isEmpty)
        await w.model.shutdown()
    }

    /// Rule 4: a queued Send to is cancellable until its turn ends.
    @Test func aQueuedSendToCanBeCancelled() async throws {
        let w = try await Wired()
        let id = try await w.model.startHandOff(handed())
        let h = try #require(w.sessions.harnesses.in(placeA).last)
        guard case .queued(let q) = try await w.model.sendToHandOff(id, text: "Never mind.") else {
            Issue.record("not queued"); return
        }
        #expect(w.model.unqueueTurn(id, id: q))
        #expect(!w.model.unqueueTurn(id, id: q), "gone already")
        let t = try #require(w.model.conversation(id: id))
        #expect(t.queuedTurns.isEmpty)
        let before = sends(h).count
        h.emit(.result(isError: false, text: nil))
        #expect(await waitUntil { !t.turnInFlight })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sends(h).count == before, "nothing was sent")
        await w.model.shutdown()
    }

    /// Start another: numbered, in the carrier's workspace, holding no copy, marked to branch off.
    @Test func startAnotherIsNumberedAndJoinsTheCarriersWorkspaceMarkedToBranchOff() async throws {
        let w = try await Wired()
        let first = try await w.model.startHandOff(handed())
        let ws = await w.model.workspaceRouter!.crewWorkspace(
            ticket: "INI-142", name: "INI-142 Work toward Next.", organization: org, project: placeA.project,
            environment: placeA.environment)
        await w.model.workspaceRouter!.join(first, workspace: ws.id)
        var r = handed()
        r.number = 2
        r.branchOffFrom = first
        let second = try await w.model.startHandOff(r)
        let t = try #require(w.model.conversation(id: second))
        #expect(t.title == conversationTitle("INI-142 · Work toward Next.") + " #2")
        #expect(await w.store.workspaceId(ofConversation: second) == ws.id)
        #expect(!(await w.store.holdsAny(second)), "it holds no copy")
        #expect(await w.store.mustBranchOff(second, root: t.lineageRoot))
        #expect(!(await w.store.mustBranchOff(first, root: nil)))
        await w.model.shutdown()
    }
}

/// Admits the first `allow` members asked about, and records each.
private actor AdmitLog {
    let allow: Int
    var asked: [String] = []
    init(allow: Int) { self.allow = allow }
    func admit(_ id: String) -> Bool {
        asked.append(id)
        return asked.count <= allow
    }
}
