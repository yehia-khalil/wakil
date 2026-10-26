import Foundation
import Testing
@testable import WakilKit

/// The editor actions with a ticket store over `FakeTicket`, on roots `/p/api` and `/p/web`.
private struct TicketFixture {
    let editor: EditorFixture
    let ticket: FakeTicket
    let store: EditorTicketStore

    @discardableResult
    func dispatch(_ name: String, _ params: [String: JSONValue] = [:], origin: ActionOrigin = .agent,
                  caller: DispatchCaller = .test("staging"), confirmation: String? = "confirm") async throws -> JSONValue {
        try await editor.registry.dispatch(name: name, params: .object(params), origin: origin, caller: caller,
                                           confirmation: confirmation)
    }
}

private func ticketFixture() async throws -> TicketFixture {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
    let layout = LayoutStore()
    let pane = await layout.open(kind: "editor", title: "Editor").id
    let panes = PaneStore(kinds: PaneKinds.standard)
    let files = FakeFiles()
    let git = FakeGit()
    let roots = ["/p/api", "/p/web"]
    let status = GitStatus(git: git, roots: { roots })
    let ticket = FakeTicket()
    await ticket.set("ticket_branch", ticketBranchJSON())
    let store = EditorTicketStore(ticket: ticket)
    await registerEditorActions(into: registry, panes: panes, layout: layout, files: files, fileLists: nil,
                                gitStatus: status, roots: { roots }, ticket: store)
    let editor = EditorFixture(registry: registry, panes: panes, layout: layout, files: files, pane: pane, git: git, status: status)
    return TicketFixture(editor: editor, ticket: ticket, store: store)
}

private let replyParams: [String: JSONValue] = [
    "root": .string("/p/api"), "repo": .string("github.com/initech/api"), "pr": .integer(212),
    "thread": .string("T2"), "body": .string("Thanks, fixed."),
    "path": .string("src/auth/token.go"), "line": .integer(41),
]

private func isNeedsConfirmation(_ error: any Error) -> Bool {
    if case ActionError.needsConfirmation = error { return true }
    return false
}

@Suite struct EditorTicketActionsTests {
    @Test func recordUpdateCarriesOriginNotParams() async throws {
        let f = try await ticketFixture()
        await f.ticket.set("ticket_record_write", .object(["key": .string("INI-142")]))
        let params: [String: JSONValue] = ["key": .string("INI-142"), "section": .string("decisions"), "op": .string("add"),
                                           "text": .string("Keep the org in the token"), "why": .string("one read"),
                                           "by": .string("operator")]
        try await f.dispatch("ticket_record_update", params, caller: .test("staging", conversation: "c1"))
        let agent = try #require(await f.ticket.args("ticket_record_write"))
        #expect(agent["by"] == .string("agent"))
        #expect(agent["conversation"] == .string("c1"))
        #expect(agent["line"] == .object(["text": .string("Keep the org in the token"), "why": .string("one read")]))

        try await f.dispatch("ticket_record_update", params, origin: .ui, caller: .test("production"), confirmation: nil)
        let operatorArgs = try #require(await f.ticket.args("ticket_record_write"))
        #expect(operatorArgs["by"] == .string("operator"))
        #expect(operatorArgs["conversation"] == nil)
    }

    @Test func replyKeepsTheDraftWhenThePostFails() async throws {
        let f = try await ticketFixture()
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("Thanks, fixed.")])
        await f.ticket.fail("review_reply", "GitHub said: Resource not accessible by integration")
        await #expect { try await f.dispatch("review_reply_send", replyParams) } throws: { error in
            "\(error)".contains("Resource not accessible by integration")
        }
        #expect(await f.store.draft(thread: "T2") == "Thanks, fixed.")
        #expect(!(await f.store.sending(thread: "T2")))

        await f.ticket.fail("review_reply", nil)
        try await f.dispatch("review_reply_send", replyParams)
        #expect(await f.store.draft(thread: "T2") == nil)
        #expect(await f.ticket.args("review_reply") == ["root": .string("/p/api"), "thread": .string("T2"),
                                                        "body": .string("Thanks, fixed.")])
    }

    @Test(.timeLimit(.minutes(1))) func replyCannotBeSentTwice() async throws {
        let f = try await ticketFixture()
        await f.ticket.setSlowReply(true)
        let first = Task { try await f.dispatch("review_reply_send", replyParams) }
        while !(await f.store.sending(thread: "T2")) { await Task.yield() }
        await #expect { try await f.dispatch("review_reply_send", replyParams) } throws: { error in
            "\(error)".contains("a reply to this thread is already being sent")
        }
        await f.ticket.release()
        _ = try await first.value
        #expect(await f.ticket.count("review_reply") == 1)
    }

    @Test func resolveAllowsTheOperatorAndGatesTheAgent() async throws {
        let f = try await ticketFixture()
        let params: [String: JSONValue] = ["root": .string("/p/api"), "thread": .string("T2"), "resolved": .bool(true)]
        try await f.dispatch("review_resolve", params, origin: .ui, confirmation: nil)
        #expect(await f.ticket.count("review_resolve") == 1)
        await #expect { try await f.dispatch("review_resolve", params, origin: .agent, confirmation: nil) } throws: { isNeedsConfirmation($0) }
        #expect(await f.ticket.count("review_resolve") == 1)
        #expect(confirmationDescription(action: "review_resolve", params: .object(params)) == "resolve review thread T2 in api")
    }

    @Test @MainActor func replySendIsGateForTheOperatorToo() async throws {
        // The registry refuses the operator's own send without the plane...
        let f = try await ticketFixture()
        await #expect { try await f.dispatch("review_reply_send", replyParams, origin: .ui, confirmation: nil) } throws: { isNeedsConfirmation($0) }
        #expect(await f.ticket.count("review_reply") == 0)

        // ...and the window parks it there, showing where it goes and its exact text.
        let confirmations = ConfirmationBroker()
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot, confirmations: confirmations)
        let ticket = FakeTicket()
        let store = EditorTicketStore(ticket: ticket)
        await registerTicketActions(
            into: model.registryForTesting, store: store, panes: PaneStore(kinds: PaneKinds.standard), layout: nil,
            editor: EditorTicketHooks(pane: { _, _ in "editor-1" }, reply: { _ in .null },
                                      updateColumn: { _, _ in .initial }, openFile: { _, _, _ in }),
            roots: { ["/p/api"] })
        let send = Task { @MainActor in await model.dispatchFromSurface("review_reply_send", .object(replyParams)) }
        var parked: PendingMutation?
        for _ in 0..<2_000 where parked == nil {
            parked = await confirmations.all().values.first
            if parked == nil { try await Task.sleep(for: .milliseconds(1)) }
        }
        let proposal = try #require(parked)
        #expect(proposal.action == "review_reply_send")
        #expect(proposal.statement == "Reply on initech/api#212 · src/auth/token.go:41\n\nThanks, fixed.")
        #expect(await ticket.count("review_reply") == 0)
        await confirmations.cancel(id: proposal.id)
        await send.value
        #expect(await ticket.count("review_reply") == 0)
    }

    @Test func aStatementCannotNameAnotherThreadThanTheOneRead() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        var wrong = replyParams
        wrong["path"] = .string("src/auth/session.go")
        await #expect { try await f.dispatch("review_reply_send", wrong) } throws: { error in
            "\(error)".contains("is on initech/api#212 · src/auth/token.go:41")
        }
        #expect(await f.ticket.count("review_reply") == 0)
    }

    @Test func editorTreeAcceptsTicket() async throws {
        let f = try await ticketFixture()
        try await f.dispatch("editor_tree", ["pane": .string(f.editor.pane), "view": .string("ticket")])
        let c = try #require(await f.editor.snapshot().column)
        #expect(c.view == .ticket && c.shown)
        // The view is saved; the ticket picked from In flight is not.
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .string("ini-140")])
        #expect(await f.editor.snapshot().column?.ticketShown == "INI-140")
        let saved = try JSONDecoder().decode(EditorColumnState.self, from: JSONEncoder().encode(try #require(await f.editor.snapshot().column)))
        #expect(saved.view == .ticket && saved.ticketShown == nil)
        try await f.dispatch("ticket_show", ["pane": .string(f.editor.pane), "key": .null])
        #expect(await f.editor.snapshot().column?.ticketShown == nil)
    }

    @Test func reviewOpenLeavesTheColumnOnTicket() async throws {
        let f = try await ticketFixture()
        await f.editor.files.put("/p/api/src/auth/token.go", (1...50).map { "line \($0)" }.joined(separator: "\n"))
        _ = try await f.store.read(root: "/p/api")
        try await f.dispatch("editor_tree", ["pane": .string(f.editor.pane), "view": .string("ticket")])
        let before = await f.editor.snapshot().column
        try await f.dispatch("review_open", ["pane": .string(f.editor.pane), "thread": .string("T2")])
        let s = await f.editor.snapshot()
        #expect(s.column == before)
        let tab = try #require(s.active.map { s.tabs[$0] })
        #expect(tab.path == "/p/api/src/auth/token.go")
        #expect(tab.cursor.line == 41)

        // ⌥↓ from it: the next open thread across files, wrapping, the column still on Ticket.
        await f.editor.files.put("/p/api/src/auth/session.go", (1...100).map { "line \($0)" }.joined(separator: "\n"))
        let step = try await f.dispatch("review_step", ["pane": .string(f.editor.pane), "delta": .integer(1)])
        guard case .object(let o) = step else { Issue.record("no reply"); return }
        #expect(o["thread"] == .string("T1"))
        #expect(o["position"] == .string("1 of 2"))
        #expect(await f.editor.snapshot().column == before)
    }

    @Test func readPaneListsDraftsWithoutText() async throws {
        let f = try await ticketFixture()
        _ = try await f.store.read(root: "/p/api")
        try await f.dispatch("review_reply_draft", ["thread": .string("T2"), "text": .string("a secret-looking draft")])
        let read = await f.editor.panes.readPane(paneId: f.editor.pane, kind: "editor")
        guard case .object(let o) = read, case .object(let t)? = o["ticket"] else { Issue.record("no ticket key: \(read)"); return }
        #expect(t["root"] == .string("/p/api"))
        #expect(t["branch"] == .string("ini-142-login"))
        #expect(t["tickets"] == .array([.string("INI-142")]))
        #expect(t["marked"] == .string("INI-142"))
        #expect(t["prs"] == .array([.object(["number": .integer(212), "state": .string("open"), "openThreads": .integer(2)])]))
        #expect(t["drafts"] == .array([.string("T2")]))
        #expect(!"\(read)".contains("a secret-looking draft"))
    }

    @Test(.timeLimit(.minutes(1))) func pushInvalidatesTheRootsRead() async throws {
        let f = try await ticketFixture()
        await f.editor.git.set(status: "/p/api", files: [])
        _ = try await f.store.read(root: "/p/api")
        #expect(await f.ticket.count("ticket_branch") == 1)
        for name in ["editor_changes_push", "editor_changes_sync", "editor_changes_publish"] {
            let before = await f.ticket.count("ticket_branch")
            try await f.dispatch(name, ["root": .string("/p/api")])
            while await f.ticket.count("ticket_branch") == before { try await Task.sleep(for: .milliseconds(1)) }
        }
        // A fetch moves nothing on GitHub: no read.
        while await f.store.reading(root: "/p/api") { try await Task.sleep(for: .milliseconds(1)) }
        let settled = await f.ticket.count("ticket_branch")
        try await f.dispatch("editor_changes_fetch", ["root": .string("/p/api")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await f.ticket.count("ticket_branch") == settled)
    }

    @Test func everyTicketActionIsAgentReachableWithItsPrice() async throws {
        let f = try await ticketFixture()
        let all = await f.editor.registry.all()
        let kinds: [String: ActionKind] = [
            "ticket_read": .read, "ticket_refresh": .control, "ticket_show": .control, "ticket_in_flight": .read,
            "ticket_link": .mutate, "ticket_record_update": .mutate, "review_open": .control, "review_step": .control,
            "review_reply_draft": .control, "review_reply_send": .mutate, "review_resolve": .mutate,
        ]
        for (name, kind) in kinds {
            let d = try #require(all.first { $0.name == name }, "\(name) is not registered")
            #expect(d.kind == kind, "\(name)")
            #expect(d.audience == .agentReachable, "\(name)")
        }
        // Link and record lines are allowed everywhere, production included, for every channel.
        try await f.dispatch("ticket_link", ["root": .string("/p/api"), "key": .string("INI-142")],
                             caller: .test("production"), confirmation: nil)
        #expect(await f.ticket.count("ticket_link") == 1)
    }
}

/// Invariant 4: an agent session's read goes through its own place's client and answers it alone;
/// the window's cache, which holds the window's organisation, is never filled from it.
@Test func aPinnedAgentsReadNeverFillsTheWindowsCache() async throws {
    let f = try await ticketFixture()
    let agent = DispatchCaller(place: Place(organization: "umbrella", project: "api", environment: "staging"), session: "s1")
    let reply = try await f.dispatch("ticket_read", ["root": .string("/p/api")], caller: agent, confirmation: nil)
    guard case .object(let o) = reply else { Issue.record("no reply"); return }
    #expect(o["branch"] == .string("ini-142-login"))
    #expect(await f.store.branch(root: "/p/api") == nil)
    #expect(await f.ticket.count("ticket_branch") == 1)
}
